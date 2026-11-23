import CoreGraphics
import Foundation
import os.lock

// All mutable lattice and spatial caches on this decoder belong exclusively to its serial queue.
private final class CandidateDecodeWorker {
    let queue = OperationQueue()
    let decoder: ViterbiDecoder
    /// Sentence-level second pass for dropped / swapped keys. Owns its own render decoder, same queue.
    let refiner: NoisyChannelRefiner
    var spatialGeneration: UInt64?
    var supplementaryGeneration: UInt64?
    private var generationLock = os_unfair_lock()
    private var _latestGeneration: UInt64 = 0

    init(source: ViterbiDecoder) {
        queue.name = "com.kianuni.lokey.candidates"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        decoder = ViterbiDecoder(lexicon: source.lexicon, userStore: source.userStore)
        refiner = NoisyChannelRefiner(lexicon: source.lexicon, userStore: source.userStore, lookupCache: decoder.lookupCache)
        source.lexicon.prewarmMappedPagesAsync()
    }

    @discardableResult
    func advanceGeneration() -> UInt64 {
        os_unfair_lock_lock(&generationLock)
        _latestGeneration &+= 1
        let gen = _latestGeneration
        os_unfair_lock_unlock(&generationLock)
        return gen
    }

    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        os_unfair_lock_lock(&generationLock)
        let match = (_latestGeneration == generation)
        os_unfair_lock_unlock(&generationLock)
        return match
    }
}

private final class CandidateDecodeOperation: Operation, @unchecked Sendable {
    /// Receives cancellation & deadline probes so long refinement work stops immediately when superseded
    /// or when Space/commit needs an instant result, plus a sink for the primary decoder's ranking.
    let compute: (_ isCancelled: () -> Bool, _ isPastDeadline: () -> Bool, _ isUrgentCommit: () -> Bool, _ provisional: (DecodeResult) -> Void) -> DecodeResult
    let touchSequence: UInt64
    /// Called on the worker queue with the primary decoder's result before refinement starts. Set before enqueueing.
    var onProvisional: ((DecodeResult) -> Void)?
    private var stateLock = os_unfair_lock()
    private var _provisionalResult: DecodeResult?
    private var _deadlineNs: UInt64 = .max
    private var _urgentCommit = false
    private let provisionalSemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private(set) var result: DecodeResult?
    private(set) var elapsedMs = 0.0

    var provisionalResult: DecodeResult? {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return _provisionalResult
    }

    func tightenDeadline(to deadlineNs: UInt64, urgentCommit: Bool = true) {
        os_unfair_lock_lock(&stateLock)
        if deadlineNs < _deadlineNs {
            _deadlineNs = deadlineNs
        }
        if urgentCommit {
            _urgentCommit = true
        }
        os_unfair_lock_unlock(&stateLock)
    }

    var isUrgentCommit: Bool {
        os_unfair_lock_lock(&stateLock)
        let urgent = _urgentCommit
        os_unfair_lock_unlock(&stateLock)
        return urgent
    }

    var isPastDeadline: Bool {
        os_unfair_lock_lock(&stateLock)
        let limit = _deadlineNs
        os_unfair_lock_unlock(&stateLock)
        return limit != .max && DispatchTime.now().uptimeNanoseconds >= limit
    }

    func wait(timeoutNs: UInt64) -> Bool {
        if isFinished { return true }
        let ok = finishedSemaphore.wait(timeout: .now() + .nanoseconds(Int(timeoutNs))) == .success
        if ok {
            finishedSemaphore.signal()
            waitUntilFinished()
        }
        return ok
    }

    func waitForProvisional(timeoutNs: UInt64) -> Bool {
        if isFinished || provisionalResult != nil { return true }
        let ok = provisionalSemaphore.wait(timeout: .now() + .nanoseconds(Int(timeoutNs))) == .success
        if ok {
            provisionalSemaphore.signal()
        }
        return ok || isFinished || provisionalResult != nil
    }

    init(touchSequence: UInt64, compute: @escaping (_ isCancelled: () -> Bool, _ isPastDeadline: () -> Bool, _ isUrgentCommit: () -> Bool, _ provisional: (DecodeResult) -> Void) -> DecodeResult) {
        self.touchSequence = touchSequence
        self.compute = compute
    }

    override func main() {
        var didSignalProvisional = false
        defer {
            if !didSignalProvisional {
                provisionalSemaphore.signal()
            }
            finishedSemaphore.signal()
        }
        guard !isCancelled else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let sink = onProvisional
        result = compute(
            { [unowned self] in self.isCancelled },
            { [unowned self] in self.isPastDeadline },
            { [unowned self] in self.isUrgentCommit },
            { [unowned self] base in
                os_unfair_lock_lock(&self.stateLock)
                self._provisionalResult = base
                os_unfair_lock_unlock(&self.stateLock)
                if !didSignalProvisional {
                    didSignalProvisional = true
                    self.provisionalSemaphore.signal()
                }
                sink?(base)
            }
        )
        elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

/// Top-level orchestrator of the **落墨 · Inkstone** (`Lokey Inkstone`) input engine shared by the Keyboard Extension and unit tests.
/// Coordinates spatial touch buffering (`SpatialTouchModel`), incremental Viterbi lattice decoding (`ViterbiDecoder` + `LNLM-v2`),
/// background sentence-level noisy-channel refinement (`NoisyChannelRefiner`), multi-segment partial commits, and SQLite custom phrase learning.
public final class LokeySessionController {
    public static let engineDisplayName = "落墨 · Inkstone"
    public static let engineIdentifier = "Lokey Inkstone"

    public enum InputMode: Sendable, Equatable {
        case chineseMixed   // Default: 26-key Full Pinyin + Jianpin + Seamless English Mixed Input
        case englishASCII   // Direct English ASCII pass-through
    }

    public enum KeyActionResult: Sendable, Equatable {
        /// Composing buffer updated; nothing committed to `textDocumentProxy` yet.
        case composingUpdated(DecodeResult)
        /// Commit `text` to `textDocumentProxy`, and continue composing with `remaining` (empty if session finished).
        case commitText(String, remaining: DecodeResult)
        /// Composing buffer was already empty; caller should perform normal document action (e.g., deleteBackward, insert space/newline).
        case passThroughToDocument
    }

    private struct ComposedSegment {
        let text: String
        let syllables: [String]
        let rawInputSlice: String
    }

    private struct UtteranceFeedbackState {
        struct DeferredStepMismatch {
            let context: String
            let rawSlice: String
            let matchedPinyin: String
            let top1: String
            let chosen: String
            let index: Int
            let preview: [String]
        }

        var precedingContext: String
        var initialRawInput: String
        var initialTop1Text: String
        var initialTop1ConsumedAll: Bool
        var initialFirstPickIndex: Int
        var initialTopCandidates: [String]
        var didAppendLettersAfterPartialCommit: Bool = false
        var deferredStepMismatches: [DeferredStepMismatch] = []
    }

    private struct CompletedPrefixSnapshot {
        let samples: [TouchSample]
        let contextSeed: String?
        let topicMemory: NeuralSentenceScorer.Vec32
        let settings: LokeySettings
        let rawResult: DecodeResult
    }

    public let decoder: ViterbiDecoder
    public var settings: LokeySettings {
        didSet {
            if settings != oldValue {
                if settings.chineseScriptMode != oldValue.chineseScriptMode {
                    displayToCanonicalSurface.removeAll(keepingCapacity: true)
                    if settings.chineseScriptMode != .simplified {
                        decoder.lexicon.prewarmMappedPagesAsync(includeOpenCC: true)
                    }
                    if !samples.isEmpty, let raw = lastRawSimplifiedDecode {
                        installDecode(raw)
                    }
                }
                if !samples.isEmpty {
                    redecode(deferCandidates: true)
                }
            }
        }
    }
    public var inputMode: InputMode = .chineseMixed {
        didSet {
            if inputMode == .englishASCII && !samples.isEmpty {
                resetComposing()
            }
        }
    }

    public private(set) var samples: [TouchSample] = []
    public private(set) var composingCaretIndex: Int = 0
    public private(set) var currentDecode = DecodeResult(preeditDisplay: "", candidates: [])
    private var lastRawSimplifiedDecode: DecodeResult?
    private var lastAppliedScriptMode: ChineseScriptMode = .simplified
    private var canonicalCurrentCandidates: [LokeyCandidate] = []
    private var displayToCanonicalSurface: [String: String] = [:]
    private var recentCommittedDisplayToCanonical: [(display: String, canonical: String)] = []
    private var pendingSegments: [ComposedSegment] = []
    private var utteranceFeedbackState: UtteranceFeedbackState?
    private var completedPrefixSnapshots: [CompletedPrefixSnapshot] = []
    public var selectionFeedbackLogger: LokeySelectionFeedbackLogger?

    private var candidateWorker: CandidateDecodeWorker?
    private var _commitRefiner: NoisyChannelRefiner?
    private var commitRefiner: NoisyChannelRefiner {
        if let existing = _commitRefiner { return existing }
        let created = NoisyChannelRefiner(
            lexicon: decoder.lexicon,
            userStore: decoder.userStore,
            lookupCache: decoder.lookupCache
        )
        _commitRefiner = created
        return created
    }
    // Both deferred publications belong to the current operation. Only the main
    // queue touches this slot. Replacing or cancelling the operation invalidates it.
    private var deferredPrimary: DecodeResult?
    private var pendingDecode: CandidateDecodeOperation? {
        didSet { deferredPrimary = nil }
    }
    var hasPendingCandidateDecode: Bool { pendingDecode != nil }
    private var hasPublishedRanking = false
    private(set) var needsImmediateCandidateRefresh = true
    var canPublishCandidates: (() -> Bool)?
    var onCandidateDecodeReady: ((UInt64, Double) -> Void)?

    /// Tracks whether the last committed character was CJK / Chinese context so `.` can smartly emit `。` or `.`.
    public private(set) var lastCommittedWasChinese: Bool = true

    /// Tracks the last committed Chinese word within the current clause for automatic user-bigram learning & association fallback.
    public private(set) var lastCommittedChineseWord: String = ""

    /// Soft semantic context (up to 6 trailing Han characters) preserved across `，` / `、` pauses without chaining cross-comma bigrams.
    public private(set) var lastClauseContextSuffix: String = ""

    /// Cross-sentence exponentially decaying 32-dim semantic topic memory (`LNS6-v1`).
    /// Zeroed immediately whenever `isSecureContext` is toggled or `resetTopicMemory()` is called.
    public private(set) var topicMemoryVector: NeuralSentenceScorer.Vec32 = .zero

    /// Live document text immediately preceding the composing insertion point, supplied by `KeyboardViewController`.
    public var externalContextBeforeInput: String? = nil

    /// Password fields: no learning, no prediction, no diagnostics. Toggling resets composition and topic memory.
    public var isSecureContext = false {
        didSet {
            if isSecureContext != oldValue {
                topicMemoryVector = .zero
                resetComposing()
                notifyContextBreak()
            }
        }
    }

    public func resetTopicMemory() {
        topicMemoryVector = .zero
        completedPrefixSnapshots.removeAll(keepingCapacity: true)
    }

    /// Runs `NoisyChannelRefiner` after each background decode (dropped / swapped / neighbor keys across the
    /// whole sentence). Only applies to the background candidate worker so it never adds main-thread latency.
    public var refinesNoisyInput = true

    /// Whether confirmed touch alignments should be periodically flushed to the shared `App Group` container.
    public var persistTouchCalibration: Bool

    public var isComposing: Bool {
        !samples.isEmpty
    }

    private static let prewarmQueue = DispatchQueue(label: "com.kianuni.lokey.engine.prewarm", qos: .userInitiated)
    private var didPrewarmWorkerEngine = false

    /// Triggers non-blocking background prewarming of `mmap` lexicon pages and engine static/worker caches
    /// so early touch/decode paths never stall on cold flash page faults or `swift_once` initialization.
    public func prewarmEngineAsync() {
        let includeOpenCC = settings.chineseScriptMode != .simplified
        decoder.lexicon.prewarmMappedPagesAsync(includeOpenCC: includeOpenCC)
        if !didPrewarmWorkerEngine {
            didPrewarmWorkerEngine = true
            Self.prewarmQueue.async { [weak lexicon = decoder.lexicon] in
                ViterbiDecoder.prewarmStaticTables()
                NoisyChannelRefiner.prewarmStaticTables()
                guard let neural = lexicon?.neuralLM else { return }
                for token in ["我", "你", "他", "的", "了", "是", "在", "不", "有", "和", "就", "都", "要", "会", "去", "来", "说", "看", "好", "吗"] {
                    _ = neural.wordRecord(for: token)
                }
            }
        }
    }

    public init(
        decoder: ViterbiDecoder,
        settings: LokeySettings = LokeySettings.load(),
        persistTouchCalibration: Bool = false,
        decodeCandidatesInBackground: Bool = false,
        selectionFeedbackLogger: LokeySelectionFeedbackLogger? = nil
    ) {
        self.decoder = decoder
        self.settings = settings
        self.persistTouchCalibration = persistTouchCalibration
        self.selectionFeedbackLogger = selectionFeedbackLogger
        if decodeCandidatesInBackground {
            candidateWorker = CandidateDecodeWorker(source: decoder)
            if settings.chineseScriptMode != .simplified {
                decoder.lexicon.prewarmMappedPagesAsync(includeOpenCC: true)
            }
        }
    }

    deinit {
        // A torn-down keyboard must not keep refining stale buffers on the worker queue.
        candidateWorker?.queue.cancelAllOperations()
    }

    // MARK: - Key Input Handling

    /// Feeds a 26-key alphabetic tap (with optional normalized touch coordinate) or apostrophe separator `'`.
    @discardableResult
    public func handleLetterTap(
        char: Character,
        normalizedPoint: CGPoint? = nil,
        isShifted: Bool = false,
        touchSeq: UInt64 = 0
    ) -> KeyActionResult {
        let effectiveChar: Character = isShifted
            ? Character(char.uppercased())
            : Character(char.lowercased())

        func appendLetter() {
            let insertAt = min(max(0, composingCaretIndex), samples.count)
            let sample = TouchSample(primaryChar: effectiveChar, normalizedPoint: normalizedPoint)
            if insertAt == samples.count {
                samples.append(sample)
            } else {
                samples.insert(sample, at: insertAt)
            }
            composingCaretIndex = insertAt + 1
            if !pendingSegments.isEmpty {
                utteranceFeedbackState?.didAppendLettersAfterPartialCommit = true
            }
            if !isSecureContext && LokeyDiagnosticLogger.shared.canRecordInteractions {
                LokeyDiagnosticLogger.shared.recordLetterDispositionFast(
                    touchSeq: touchSeq,
                    enteredPinyin: true,
                    disposition: .enteredPinyin(effectiveChar, insertAt + 1)
                )
            }
        }

        if inputMode == .englishASCII {
            if !isSecureContext && LokeyDiagnosticLogger.shared.canRecordInteractions {
                LokeyDiagnosticLogger.shared.recordLetterDispositionFast(
                    touchSeq: touchSeq,
                    disposition: .englishDirect(effectiveChar)
                )
            }
            lastCommittedWasChinese = false
            return .commitText(String(effectiveChar), remaining: currentDecode)
        }

        // Apostrophe is only meaningful inside an active Pinyin buffer
        if effectiveChar == "'" && samples.isEmpty {
            if !isSecureContext && LokeyDiagnosticLogger.shared.canRecordInteractions {
                LokeyDiagnosticLogger.shared.recordLetterDispositionFast(
                    touchSeq: touchSeq,
                    disposition: .apostropheDirect
                )
            }
            return .commitText("'", remaining: currentDecode)
        }

        // Cap single composing buffer at 64 letters; on overflow, commit only the leading word prefix
        // (keeping the trailing >= 12 letters active) so mid-word syllables at the cursor are never split!
        if samples.count >= 64 {
            finishPendingCandidateDecodeForCommit()
            let maxPrefixConsume = samples.count - 12
            if let prefixIdx = currentDecode.candidates.firstIndex(where: {
                $0.consumedInputCount >= 2 && $0.consumedInputCount <= maxPrefixConsume
            }) {
                let prefixCand = currentDecode.candidates[prefixIdx]
                let canonicalPrefix = canonicalCandidate(at: prefixIdx) ?? prefixCand
                recordTouchCalibrationIfEligible(
                    consumedSamples: Array(samples.prefix(prefixCand.consumedInputCount)),
                    matchedSyllables: canonicalPrefix.matchedSyllables
                )
                pendingSegments.removeAll(keepingCapacity: true)
                utteranceFeedbackState = nil
                samples.removeFirst(prefixCand.consumedInputCount)
                composingCaretIndex = max(0, min(samples.count, composingCaretIndex - prefixCand.consumedInputCount))
                appendLetter()
                recordCommittedSurfaceForBigram(
                    canonicalPrefix.text,
                    kind: canonicalPrefix.kind,
                    trailingWord: canonicalPrefix.trailingWord
                )
                recordCommittedDisplayMapping(display: prefixCand.text, canonical: canonicalPrefix.text)
                updateChineseContextFlag(for: prefixCand.text)
                externalContextBeforeInput = canonicalPrefix.text
                redecode(touchSeq: touchSeq)
                return .commitText(prefixCand.text, remaining: currentDecode)
            } else if let commitRes = commitCandidate(at: 0) {
                appendLetter()
                redecode(touchSeq: touchSeq)
                if case let .commitText(committed, _) = commitRes {
                    return .commitText(committed, remaining: currentDecode)
                }
            }
        }

        appendLetter()
        redecode(deferCandidates: true, touchSeq: touchSeq)
        return .composingUpdated(currentDecode)
    }

    /// Handles Backspace (`⌫`). Deletes from composing buffer first; passes through when idle.
    @discardableResult
    public func handleBackspace() -> KeyActionResult {
        guard !samples.isEmpty else {
            composingCaretIndex = 0
            pendingSegments.removeAll()
            completedPrefixSnapshots.removeAll(keepingCapacity: true)
            return .passThroughToDocument
        }
        guard composingCaretIndex > 0 else {
            return .composingUpdated(currentDecode)
        }
        let bsStartNs = DispatchTime.now().uptimeNanoseconds
        let delIdx = min(composingCaretIndex, samples.count) - 1
        let deletedFromEnd = (delIdx == samples.count - 1)
        samples.remove(at: delIdx)
        composingCaretIndex = delIdx
        if samples.isEmpty {
            resetComposing()
        } else {
            if !pendingSegments.isEmpty {
                utteranceFeedbackState?.didAppendLettersAfterPartialCommit = true
            }
            if !deletedFromEnd {
                completedPrefixSnapshots.removeAll(keepingCapacity: true)
            }
            let ctx = currentContextSeed()
            let activeTopic = isSecureContext ? NeuralSentenceScorer.Vec32.zero : topicMemoryVector
            if let snapIdx = completedPrefixSnapshots.lastIndex(where: {
                $0.samples == samples && $0.contextSeed == ctx && $0.topicMemory == activeTopic && $0.settings == settings
            }) {
                pendingDecode?.cancel()
                pendingDecode = nil
                _ = candidateWorker?.advanceGeneration()
                let snap = completedPrefixSnapshots[snapIdx].rawResult
                completedPrefixSnapshots.removeSubrange((snapIdx + 1)..<completedPrefixSnapshots.count)
                installDecode(snap)
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- bsStartNs) / 1_000_000.0
                let seq = LokeyDiagnosticLogger.shared.isEnabled ? LokeyDiagnosticLogger.shared.currentActiveTouchSeq : 0
                onCandidateDecodeReady?(seq, elapsedMs)
            } else {
                redecode(deferCandidates: true)
            }
        }
        return .composingUpdated(currentDecode)
    }

    /// Handles Spacebar: commits top candidate `#0` when composing, or inserts space when idle.
    @discardableResult
    public func handleSpace() -> KeyActionResult {
        guard !samples.isEmpty else {
            return .passThroughToDocument
        }
        finishPendingCandidateDecodeForCommit()
        if let res = commitCandidate(at: 0) {
            return res
        }
        let raw = String(samples.map(\.primaryChar))
        resetComposing()
        return .commitText(raw, remaining: currentDecode)
    }

    /// Handles Return key: native iOS Pinyin commits raw English letters when composing, or newline/submit when idle.
    @discardableResult
    public func handleReturn() -> KeyActionResult {
        guard !samples.isEmpty else {
            return .passThroughToDocument
        }
        let raw = String(samples.map(\.primaryChar))
        resetComposing()
        lastCommittedWasChinese = false
        return .commitText(raw, remaining: currentDecode)
    }

    /// Commits a specific candidate by index from `currentDecode.candidates`.
    /// Supports both full-buffer commits and partial prefix commits (remembering composed phrases in SQLite).
    @discardableResult
    public func selectCandidate(at index: Int) -> KeyActionResult? {
        commitCandidate(at: index)
    }

    /// Deletes a user-learned phrase from SQLite and refreshes the candidate bar immediately.
    @discardableResult
    public func deleteUserCandidate(at index: Int) -> DecodeResult {
        guard index >= 0 && index < currentDecode.candidates.count else {
            return currentDecode
        }
        let cand = currentDecode.candidates[index]
        guard cand.isDeletableUserPhrase else {
            return currentDecode
        }
        let canonicalSurface = canonicalCandidate(at: index)?.text ?? cand.text
        decoder.userStore.deletePhrase(surface: canonicalSurface)
        redecode()
        return currentDecode
    }

    /// Deletes an idle or predictive user-learned phrase by its display surface, mapping Traditional output back to canonical Simplified.
    public func deleteUserPhrase(displaySurface: String) {
        let canonical = displayToCanonicalSurface[displaySurface] ?? canonicalizeContext(displaySurface)
        decoder.userStore.deletePhrase(surface: canonical)
    }

    /// Flushes any active composing state (e.g., before inserting punctuation) and returns text to commit before punctuation.
    public func flushTopCandidateIfComposing() -> String? {
        guard !samples.isEmpty else { return nil }
        finishPendingCandidateDecodeForCommit()
        if let res = commitCandidate(at: 0), case let .commitText(text, _) = res {
            return text
        }
        let raw = String(samples.map(\.primaryChar))
        resetComposing()
        return raw
    }

    public struct SmartSymbolAction: Sendable, Equatable {
        public let deletePreviousCount: Int
        public let textToInsert: String

        public init(deletePreviousCount: Int = 0, textToInsert: String) {
            self.deletePreviousCount = deletePreviousCount
            self.textToInsert = textToInsert
        }
    }

    /// Resolves context-aware punctuation on the Chinese numeric/symbolic pages so typing times (`12:00`, `09:30:00`),
    /// decimals (`3.14`), ratios (`16:9`), and URL schemes (`http://`) automatically emit halfwidth ASCII punctuation
    /// while preserving Chinese fullwidth punctuation after CJK text (`时间是：12:00`, `我有100。`).
    public func resolveSmartSymbol(_ symbol: String, contextBefore: String?) -> SmartSymbolAction {
        guard inputMode == .chineseMixed else {
            updateChineseContextFlag(for: symbol)
            return SmartSymbolAction(textToInsert: symbol)
        }

        let ctx = contextBefore ?? ""

        // 1. Forward rule: Chinese colon `：` immediately after an ASCII digit (`12` + `：` -> `12:`)
        if symbol == "：", let last = ctx.last, Self.isASCIIDigit(last) {
            lastCommittedWasChinese = false
            return SmartSymbolAction(textToInsert: ":")
        }

        // 2. Retroactive numeric/port/version rule: ASCII digit typed right after `<ASCII alnum>：` or `<ASCII alnum>。`
        // (`12：` + `0` -> `12:0`, `localhost：` + `8` -> `localhost:8`, `3。` + `1` -> `3.1`, `v1。` + `0` -> `v1.0`)
        if symbol.count == 1, let digit = symbol.first, Self.isASCIIDigit(digit), ctx.count >= 2,
           let last = ctx.last, let prev = ctx.dropLast().last,
           (Self.isASCIIDigit(prev) || Self.isASCIILetter(prev)) {
            if last == "：" {
                lastCommittedWasChinese = false
                return SmartSymbolAction(deletePreviousCount: 1, textToInsert: ":" + symbol)
            }
            if last == "。" {
                lastCommittedWasChinese = false
                return SmartSymbolAction(deletePreviousCount: 1, textToInsert: "." + symbol)
            }
        }

        // 3. Retroactive URL scheme / domain rule: `/` after `<ASCII letter>：` (`http：` + `/` -> `http:/`)
        // or ASCII letter after `<ASCII alnum>。` (`www。` + `b` -> `www.b`)
        if symbol == "/", ctx.count >= 2, ctx.last == "：",
           let prev = ctx.dropLast().last, Self.isASCIILetter(prev) {
            lastCommittedWasChinese = false
            return SmartSymbolAction(deletePreviousCount: 1, textToInsert: ":/")
        }
        if symbol.count == 1, let ch = symbol.first, Self.isASCIILetter(ch), ctx.count >= 2,
           ctx.last == "。", let prev = ctx.dropLast().last,
           (Self.isASCIILetter(prev) || Self.isASCIIDigit(prev)) {
            lastCommittedWasChinese = false
            return SmartSymbolAction(deletePreviousCount: 1, textToInsert: "." + symbol)
        }

        updateChineseContextFlag(for: symbol)
        return SmartSymbolAction(textToInsert: symbol)
    }

    /// Native iOS 26 Chinese Pinyin `123` / `#+=` auto-return rule:
    /// - Digits `0-9` stay on `.numeric` so multi-digit numbers can be typed continuously.
    /// - Numeric/URL connectors (`:`/`：`, `.`/`。`, `-`, `/`, `_`, `@`) immediately following an ASCII digit/letter/scheme
    ///   stay on `.numeric` so `12:00`, `3.14`, `2026-11-10`, `localhost:8080`, and `http://` flow without extra taps.
    /// - All other punctuation and symbols (e.g. `，`, `。`, `？`, `！`, `、`, `；`, `“`, `”`, `（`, `）`, `¥`, `……`, `#`, `%`, `【`, `】`)
    ///   automatically switch the keyboard back to the 26-key Pinyin page.
    public func shouldAutoReturnToAlphabeticAfterSymbol(
        _ rawSymbol: String,
        resolvedText: String,
        contextBefore: String?
    ) -> Bool {
        guard inputMode == .chineseMixed else { return false }
        if rawSymbol.count == 1, let ch = rawSymbol.first, Self.isASCIIDigit(ch) {
            return false
        }
        if let prev = contextBefore?.last,
           (Self.isASCIIDigit(prev) || Self.isASCIILetter(prev) || prev == ":" || prev == "：" || prev == "/") {
            if resolvedText == ":" || resolvedText == ":/" || resolvedText == "."
                || rawSymbol == "：" || rawSymbol == "."
                || (Self.isASCIIDigit(prev) && rawSymbol == "。")
                || rawSymbol == "-" || rawSymbol == "/" || rawSymbol == "_" || rawSymbol == "@" {
                return false
            }
            if Self.isASCIIDigit(prev),
               rawSymbol == "+" || rawSymbol == "*" || rawSymbol == "=" || rawSymbol == "^" || rawSymbol == "～" || rawSymbol == "~" {
                return false
            }
        }
        return true
    }

    /// Smart period string (`。` vs `.`) for the optional period key beside Space.
    public func smartPeriodString(contextBefore: String? = nil) -> String {
        if inputMode == .englishASCII {
            return "."
        }
        if let ctx = contextBefore {
            if let last = ctx.last {
                if Self.isASCIIDigit(last) || Self.isASCIILetter(last) {
                    return "."
                }
                if Self.isCJKOrFullwidth(last) {
                    return "。"
                }
            } else {
                return "。"
            }
        }
        return lastCommittedWasChinese ? "。" : "."
    }

    private static func isASCIIDigit(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return v >= 0x30 && v <= 0x39
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }

    private static func isCJKOrFullwidth(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x3000 && v <= 0x303F)
            || (v >= 0xFF00 && v <= 0xFFEF)
    }

    /// Records selection of an idle predictive/association candidate so consecutive chain-taps also learn personal bigrams.
    public func recordAssociationSelection(_ text: String) {
        let canonical = displayToCanonicalSurface[text] ?? canonicalizeContext(text)
        recordCommittedSurfaceForBigram(canonical, kind: .lexiconPhrase)
        recordCommittedDisplayMapping(display: text, canonical: canonical)
        updateChineseContextFlag(for: text)
    }

    /// Clears clause-level word history when punctuation, space, newline, or cursor jump breaks continuity,
    /// while applying sentence-boundary exponential decay to `topicMemoryVector` (or zeroing in secure contexts).
    public func notifyContextBreak() {
        lastCommittedChineseWord = ""
        lastClauseContextSuffix = ""
        externalContextBeforeInput = nil
        recentCommittedDisplayToCanonical.removeAll(keepingCapacity: true)
        if isSecureContext {
            topicMemoryVector = .zero
        } else if topicMemoryVector != .zero && decoder.lexicon.neuralLM.isSemantic64Loaded {
            topicMemoryVector = decoder.lexicon.neuralLM.decayTopicMemory(
                topicMemoryVector,
                committedWords: [],
                isSentenceBreak: true
            )
        }
    }

    /// Called on pause punctuation (`，` / `、`): clears immediate bigram chaining so
    /// cross-comma word pairs are never learned as `user_bigrams`, while keeping up to 6
    /// trailing Han characters from the finished clause as soft semantic fallback context.
    public func notifyClauseComma() {
        let ext = canonicalizeContext(externalContextBeforeInput ?? "")
        let rawClauseSource: String
        if !ext.isEmpty {
            if !lastCommittedChineseWord.isEmpty && !ext.hasSuffix(lastCommittedChineseWord) {
                rawClauseSource = ext + lastCommittedChineseWord
            } else {
                rawClauseSource = ext
            }
        } else if !lastCommittedChineseWord.isEmpty {
            rawClauseSource = lastCommittedChineseWord
        } else {
            rawClauseSource = ""
        }
        var reversedHan: [Character] = []
        reversedHan.reserveCapacity(6)
        for ch in rawClauseSource.reversed() {
            if ViterbiDecoder.isCJKIdeograph(ch) {
                reversedHan.append(ch)
                if reversedHan.count >= 6 { break }
            } else if ch == "，" || ch == "、" || ch == "," || ch == " " || ch == "\u{3000}" {
                if !reversedHan.isEmpty { break }
            } else {
                break
            }
        }
        if !reversedHan.isEmpty {
            lastClauseContextSuffix = String(reversedHan.reversed())
        }
        lastCommittedChineseWord = ""
        externalContextBeforeInput = nil
    }

    /// Maps `composingCaretIndex` (an index into `samples`) to a UTF-16 offset in
    /// `currentDecode.preeditDisplay`, skipping decoder-inserted `'` separators while
    /// preserving any user-typed `'` characters present in `samples`.
    public var preeditCaretUTF16Offset: Int {
        guard !samples.isEmpty else { return 0 }
        let preedit = currentDecode.preeditDisplay
        let target = min(max(0, composingCaretIndex), samples.count)
        guard target > 0 else { return 0 }
        if preedit.isEmpty {
            return target
        }
        var sampleIdx = 0
        var utf16Pos = 0
        for ch in preedit {
            if sampleIdx >= target { break }
            let isAutoSeparator = (ch == "'" && samples[sampleIdx].primaryChar != "'")
            utf16Pos += ch.utf16.count
            if !isAutoSeparator {
                sampleIdx += 1
            }
        }
        return utf16Pos
    }

    @discardableResult
    public func moveComposingCursor(by delta: Int) -> DecodeResult {
        guard !samples.isEmpty else {
            composingCaretIndex = 0
            return currentDecode
        }
        composingCaretIndex = min(samples.count, max(0, composingCaretIndex + delta))
        return currentDecode
    }

    public func setSupplementaryEntries(_ entries: [(shortcut: String, phrase: String)]) {
        decoder.setSupplementaryEntries(entries)
    }

    public func setComposingCursor(utf16OffsetInPreedit: Int) {
        guard !samples.isEmpty else {
            composingCaretIndex = 0
            return
        }
        let preedit = currentDecode.preeditDisplay
        let targetUTF16 = max(0, utf16OffsetInPreedit)
        if targetUTF16 == 0 || preedit.isEmpty {
            composingCaretIndex = 0
            return
        }
        var utf16Pos = 0
        var sampleIdx = 0
        for ch in preedit {
            if utf16Pos >= targetUTF16 { break }
            let nextPos = utf16Pos + ch.utf16.count
            let isAutoSeparator = (ch == "'" && sampleIdx < samples.count && samples[sampleIdx].primaryChar != "'")
            if !isAutoSeparator && sampleIdx < samples.count {
                sampleIdx += 1
            }
            utf16Pos = nextPos
        }
        composingCaretIndex = min(samples.count, max(0, sampleIdx))
    }

    /// Returns contextual next-word associations (`联想词`) for the idle candidate bar.
    /// When `documentContextBeforeInput` is explicitly provided (including `""` for an empty/cleared field),
    /// uses it authoritatively without resurrecting stale `lastCommittedChineseWord`.
    public func predictNextWords(documentContextBeforeInput: String? = nil, limit: Int = 18) -> [LokeyCandidate] {
        guard !isSecureContext, inputMode == .chineseMixed else { return [] }
        let effectiveContext: String
        if let doc = documentContextBeforeInput {
            effectiveContext = canonicalizeContext(doc)
        } else {
            effectiveContext = lastCommittedChineseWord
        }
        let committedTail: String? = (!lastCommittedChineseWord.isEmpty && effectiveContext.hasSuffix(lastCommittedChineseWord))
            ? lastCommittedChineseWord
            : nil
        let rawList = decoder.predictNextWords(
            afterContext: effectiveContext,
            committedTailWord: committedTail,
            limit: limit
        )
        return convertAuxiliaryCandidates(rawList)
    }

    /// Native iOS 26 Chinese Pinyin empty-field starter candidate sequence.
    public static let defaultStarterIdleWords: [String] = [
        "我", "你", "在", "这", "不", "是", "一", "好", "他", "那",
        "了", "就", "有", "都", "也", "要", "会", "去", "说", "看",
        "我们", "什么", "没有", "可以"
    ]

    /// Returns Native iOS 26 starter candidates when the text field has no preceding Chinese context,
    /// anchoring `"我"`, `"你"` first, blending top user-frequent short words, and filling with `defaultStarterIdleWords`.
    public func starterIdleCandidates(limit: Int = 24) -> [LokeyCandidate] {
        guard !isSecureContext, inputMode == .chineseMixed, limit > 0 else { return [] }
        var out: [LokeyCandidate] = []
        out.reserveCapacity(limit)
        var seen = Set<String>()

        func appendWord(_ text: String, kind: LokeyCandidate.Kind, isDeletable: Bool) {
            guard out.count < limit, seen.insert(text).inserted else { return }
            out.append(
                LokeyCandidate(
                    text: text,
                    consumedInputCount: 0,
                    matchedSyllables: [],
                    scoreQ8: -(out.count * 10),
                    kind: kind,
                    isDeletableUserPhrase: isDeletable
                )
            )
        }

        for lead in Self.defaultStarterIdleWords.prefix(2) {
            appendWord(lead, kind: .lexiconPhrase, isDeletable: false)
        }
        for userItem in decoder.userStore.topFrequentStarterWords(limit: 4) {
            appendWord(userItem.surface, kind: .userPhrase, isDeletable: userItem.isCustom)
        }
        for word in Self.defaultStarterIdleWords {
            appendWord(word, kind: .lexiconPhrase, isDeletable: false)
        }
        return convertAuxiliaryCandidates(out)
    }

    public func resetComposing() {
        pendingDecode?.cancel()
        pendingDecode = nil
        _ = candidateWorker?.advanceGeneration()
        hasPublishedRanking = false
        needsImmediateCandidateRefresh = true
        samples.removeAll(keepingCapacity: true)
        composingCaretIndex = 0
        pendingSegments.removeAll(keepingCapacity: true)
        utteranceFeedbackState = nil
        completedPrefixSnapshots.removeAll(keepingCapacity: true)
        lastRawSimplifiedDecode = nil
        canonicalCurrentCandidates.removeAll(keepingCapacity: true)
        currentDecode = DecodeResult(preeditDisplay: "", candidates: [])
    }

    /// Releases transient decode, neural, and noisy-channel caches without disturbing active composing state.
    public func purgeTransientCaches(releaseCapacity: Bool = false) {
        decoder.purgeTransientCaches(releaseCapacity: releaseCapacity)
        decoder.lexicon.purgeTransientCaches(releaseCapacity: releaseCapacity)
        if releaseCapacity {
            _commitRefiner = nil
        } else {
            _commitRefiner?.purgeTransientCaches(releaseCapacity: false)
        }
        if samples.isEmpty {
            completedPrefixSnapshots.removeAll(keepingCapacity: !releaseCapacity)
            displayToCanonicalSurface.removeAll(keepingCapacity: !releaseCapacity)
        }
        if let worker = candidateWorker {
            worker.queue.addOperation { [weak worker] in
                guard let worker else { return }
                worker.decoder.purgeTransientCaches(releaseCapacity: releaseCapacity)
                worker.refiner.purgeTransientCaches(releaseCapacity: releaseCapacity)
            }
        }
    }

    /// Cancels background worker operations and releases transient caches immediately without retaining worker closures.
    public func prepareForDeallocation() {
        pendingDecode?.cancel()
        pendingDecode = nil
        _commitRefiner = nil
        if let worker = candidateWorker {
            _ = worker.advanceGeneration()
            worker.queue.cancelAllOperations()
            candidateWorker = nil
        }
        completedPrefixSnapshots.removeAll(keepingCapacity: false)
        displayToCanonicalSurface.removeAll(keepingCapacity: false)
        decoder.purgeTransientCaches(releaseCapacity: true)
        decoder.lexicon.purgeTransientCaches(releaseCapacity: true)
    }

    // MARK: - Internal Helpers

    func publishReadyCandidates() {
        guard let job = pendingDecode, canPublishCandidates?() != false else { return }
        if job.isFinished {
            finishPendingCandidateDecode()
        } else if let primary = deferredPrimary {
            deferredPrimary = nil
            installDecode(primary)
            onCandidateDecodeReady?(job.touchSequence, -1)
        }
    }

    @discardableResult
    func finishPendingCandidateDecode() -> Bool {
        guard let job = pendingDecode else { return false }
        job.waitUntilFinished()
        guard let result = job.result else { return false }
        pendingDecode = nil
        // A refinement often returns the already displayed primary ranking unchanged.
        // Still signal completion so timing and idle panel preparation observe the job.
        if hasPublishedRanking && lastRawSimplifiedDecode == result && lastAppliedScriptMode == settings.chineseScriptMode {
            needsImmediateCandidateRefresh = false
        } else {
            installDecode(result)
        }
        onCandidateDecodeReady?(job.touchSequence, job.elapsedMs)
        return true
    }

    /// Time-budgeted completion path for synchronous main-thread commits (`handleSpace`, punctuation flush).
    /// Tightens the worker's deadline so `NoisyChannelRefiner` skips deep Level-2 tails, waits up to `budgetNs`
    /// (`1.15ms`), and falls back cleanly to the worker's already-decoded primary `ViterbiDecoder` ranking if
    /// refinement exceeds the budget — strictly preventing `5–35ms` main-thread stalls!
    @discardableResult
    private func finishPendingCandidateDecodeForCommit(budgetNs: UInt64 = 1_150_000) -> Bool {
        guard let job = pendingDecode else { return false }
        if job.isFinished {
            return finishPendingCandidateDecode()
        }
        let waitStart = DispatchTime.now().uptimeNanoseconds
        var rawLowerBytes: [UInt8] = []
        rawLowerBytes.reserveCapacity(samples.count)
        var hasApostrophe = false
        var allASCII = true
        for s in samples {
            guard let ascii = s.primaryChar.asciiValue else {
                allASCII = false
                break
            }
            if ascii == 0x27 { hasApostrophe = true }
            let lower = (ascii >= 0x41 && ascii <= 0x5A) ? (ascii &+ 32) : ascii
            rawLowerBytes.append(lower)
        }
        let rawLower = allASCII
            ? String(decoding: rawLowerBytes, as: UTF8.self)
            : String(samples.map { Character($0.primaryChar.lowercased()) })
        let hasSep = allASCII ? hasApostrophe : rawLower.contains("'")
        let isClean: Bool
        if settings.pinyinScheme == .quanpin {
            isClean = !hasSep && decoder.lexicon.canSegmentCleanly(rawLower)
        } else {
            isClean = !hasSep
                && allASCII
                && PinyinSyllableAutomaton.canSegmentShuangpinCleanly(
                    rawLowerBytes[...],
                    scheme: settings.pinyinScheme,
                    in: decoder.lexicon
                )
        }
        let isExactEnglish = !hasSep
            && samples.count >= 2
            && decoder.lexicon.lookupExactEnglish(rawLower) != nil
        let isShortUnsegmentedNoisy = !isClean && !isExactEnglish && samples.count <= 16
        if job.provisionalResult != nil || deferredPrimary != nil {
            #if DEBUG
            job.tightenDeadline(to: waitStart + 200_000_000, urgentCommit: false)
            if job.wait(timeoutNs: 250_000_000) {
                return finishPendingCandidateDecode()
            }
            #else
            if isShortUnsegmentedNoisy {
                job.tightenDeadline(to: waitStart + 7_000_000, urgentCommit: false)
                if job.wait(timeoutNs: 7_300_000) {
                    return finishPendingCandidateDecode()
                }
            } else {
                let provTop = (job.provisionalResult ?? deferredPrimary)?.candidates.first
                let nonLiteralCleanWorker = isClean && samples.count >= 10
                    && settings.pinyinScheme == .quanpin
                    && samples.allSatisfy { $0.normalizedPoint == nil }
                    && provTop.map { $0.consumedInputCount == samples.count && $0.matchedSyllables.joined() != rawLower } ?? false
                if !nonLiteralCleanWorker {
                    job.tightenDeadline(to: waitStart + 800_000, urgentCommit: true)
                    if job.wait(timeoutNs: 750_000) {
                        return finishPendingCandidateDecode()
                    }
                }
            }
            #endif
        } else {
            #if DEBUG
            if job.waitForProvisional(timeoutNs: 150_000_000) {
                if job.isFinished {
                    return finishPendingCandidateDecode()
                }
                job.tightenDeadline(to: waitStart + 200_000_000, urgentCommit: false)
                if job.wait(timeoutNs: 150_000_000) {
                    return finishPendingCandidateDecode()
                }
            }
            #else
            if isShortUnsegmentedNoisy {
                job.tightenDeadline(to: waitStart + 7_000_000, urgentCommit: false)
                if job.waitForProvisional(timeoutNs: 5_200_000) {
                    if job.isFinished {
                        return finishPendingCandidateDecode()
                    }
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- waitStart
                    if elapsedNs < 7_300_000, job.wait(timeoutNs: 7_300_000 &- elapsedNs) {
                        return finishPendingCandidateDecode()
                    }
                }
            } else if !((isClean && samples.count >= 10) || isExactEnglish) {
                job.tightenDeadline(to: waitStart + 950_000, urgentCommit: true)
                if job.waitForProvisional(timeoutNs: 220_000) {
                    if job.isFinished {
                        return finishPendingCandidateDecode()
                    }
                    if job.wait(timeoutNs: 500_000) {
                        return finishPendingCandidateDecode()
                    }
                }
            }
            #endif
        }
        #if DEBUG
        let fallbackPrimary = job.provisionalResult ?? deferredPrimary
        #else
        let fallbackRaw = job.provisionalResult ?? deferredPrimary
        let nonLiteralCleanFallback = isClean && samples.count >= 10
            && settings.pinyinScheme == .quanpin
            && samples.allSatisfy { $0.normalizedPoint == nil }
            && (fallbackRaw?.candidates.first.map {
                $0.consumedInputCount == samples.count && $0.matchedSyllables.joined() != rawLower
            } ?? false)
        let fallbackPrimary = nonLiteralCleanFallback ? nil : fallbackRaw
        #endif
        let seq = job.touchSequence
        job.cancel()
        pendingDecode = nil
        let contextSeed = currentContextSeed()
        var result: DecodeResult
        if let primary = fallbackPrimary {
            result = primary
        } else {
            #if DEBUG
            let commitCeilingNs: UInt64 = waitStart + 400_000_000
            let baseDecodeDeadline: UInt64 = waitStart + 350_000_000
            #else
            let commitCeilingNs: UInt64 = waitStart + 7_400_000
            let baseDecodeDeadline: UInt64 = waitStart + 7_200_000
            #endif
            let nowBeforeBase = DispatchTime.now().uptimeNanoseconds
            if nowBeforeBase + 250_000 >= commitCeilingNs {
                if let existingFull = currentDecode.candidates.first(where: { $0.consumedInputCount == samples.count }) {
                    result = DecodeResult(preeditDisplay: currentDecode.preeditDisplay, candidates: [existingFull])
                } else {
                    result = DecodeResult(preeditDisplay: String(samples.map(\.primaryChar)), candidates: [])
                }
            } else {
                var urgentSettings = settings
                var cleanFastOnly = false
                if isClean && samples.count >= 10 {
                    urgentSettings.enableSpatialCorrection = false
                    urgentSettings.enableEmojiCandidates = false
                    cleanFastOnly = true
                }
                let activeTopicMemory = isSecureContext ? NeuralSentenceScorer.Vec32.zero : topicMemoryVector
                result = decoder.decode(
                    samples: samples,
                    settings: urgentSettings,
                    precedingContext: contextSeed,
                    topicMemory: activeTopicMemory,
                    fastCleanSentenceOnly: cleanFastOnly,
                    isCancelled: { DispatchTime.now().uptimeNanoseconds >= baseDecodeDeadline },
                    isUrgentCommit: { !isShortUnsegmentedNoisy || (DispatchTime.now().uptimeNanoseconds &- waitStart) >= 3_800_000 }
                )
            }
        }
        let nowAfterBase = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        let hardDeadline = isShortUnsegmentedNoisy ? (nowAfterBase + 400_000_000) : (waitStart + 150_000_000)
        let softMargin: UInt64 = isShortUnsegmentedNoisy ? 10_000_000 : 5_000_000
        let minSoftBudgetNs: UInt64 = 1_000_000
        #else
        let hardDeadline = isShortUnsegmentedNoisy ? min(nowAfterBase + 1_700_000, waitStart + 7_350_000) : (waitStart + 1_360_000)
        let softMargin: UInt64 = isShortUnsegmentedNoisy ? 400_000 : 120_000
        let minSoftBudgetNs: UInt64 = isShortUnsegmentedNoisy ? 200_000 : 80_000
        #endif
        if refinesNoisyInput && !isSecureContext
            && settings.pinyinScheme == .quanpin
            && samples.count >= NoisyChannelRefiner.minimumInputLength
            && samples.count <= 20
            && !result.candidates.isEmpty
            && nowAfterBase + softMargin + minSoftBudgetNs < hardDeadline {
            let softDeadline = hardDeadline - softMargin
            let activeTopicForRefine = isSecureContext ? NeuralSentenceScorer.Vec32.zero : topicMemoryVector
            result = commitRefiner.refine(
                samples: samples,
                base: result,
                settings: settings,
                spatialModel: decoder.spatialModel,
                precedingContext: contextSeed,
                topicMemory: activeTopicForRefine,
                precomputedHyps: decoder.fullHypothesesIfMatching(samples: samples, settings: settings),
                isCancelled: { DispatchTime.now().uptimeNanoseconds >= hardDeadline },
                isPastDeadline: { DispatchTime.now().uptimeNanoseconds >= softDeadline },
                isUrgentCommit: { !isShortUnsegmentedNoisy }
            )
        }
        installDecode(result)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - waitStart) / 1_000_000
        onCandidateDecodeReady?(seq, elapsed)
        return true
    }

    private func currentContextSeed() -> String? {
        if let lastPending = pendingSegments.last {
            return lastPending.text
        } else if let ext = externalContextBeforeInput, !ext.isEmpty {
            let lastIsPause = (ext.last == "，" || ext.last == "、" || ext.last == ",")
            if lastIsPause, !lastClauseContextSuffix.isEmpty {
                return lastClauseContextSuffix
            }
            return canonicalizeContext(ext)
        } else if !lastCommittedChineseWord.isEmpty {
            return lastCommittedChineseWord
        } else if !lastClauseContextSuffix.isEmpty {
            return lastClauseContextSuffix
        } else {
            return nil
        }
    }

    private func redecode(deferCandidates: Bool = false, touchSeq: UInt64? = nil) {
        pendingDecode?.cancel()
        pendingDecode = nil
        let contextSeed = currentContextSeed()
        let activeTopicMemory = isSecureContext ? NeuralSentenceScorer.Vec32.zero : topicMemoryVector
        if deferCandidates, let worker = candidateWorker {
            let samples = self.samples, settings = self.settings
            let model = decoder.spatialModel
            let anchors = model.anchors, calibration = model.calibration, landscape = model.isLandscapeLayout
            let spatialGeneration = model.modelGeneration
            let rawSupplementary = decoder.rawSupplementaryEntries, supplementaryGeneration = decoder.supplementaryGeneration
            let refinesNoisyInput = self.refinesNoisyInput && !isSecureContext && settings.pinyinScheme == .quanpin
            let resolvedTouchSeq = touchSeq ?? (LokeyDiagnosticLogger.shared.isEnabled ? LokeyDiagnosticLogger.shared.currentActiveTouchSeq : 0)
            let jobGen = worker.advanceGeneration()
            let job = CandidateDecodeOperation(touchSequence: resolvedTouchSeq) { isCancelled, isPastDeadline, isUrgentCommit, provisional in
                guard worker.isCurrentGeneration(jobGen), !isCancelled() else {
                    return DecodeResult(preeditDisplay: "", candidates: [])
                }
                if worker.spatialGeneration != spatialGeneration {
                    worker.decoder.spatialModel.updateAnchors(anchors)
                    worker.decoder.spatialModel.setCalibration(calibration)
                    worker.decoder.spatialModel.isLandscapeLayout = landscape
                    worker.spatialGeneration = spatialGeneration
                }
                if worker.supplementaryGeneration != supplementaryGeneration {
                    worker.decoder.setSupplementaryEntries(rawSupplementary)
                    worker.supplementaryGeneration = supplementaryGeneration
                }
                let base = worker.decoder.decode(
                    samples: samples,
                    settings: settings,
                    precedingContext: contextSeed,
                    topicMemory: activeTopicMemory,
                    isCancelled: { isCancelled() || !worker.isCurrentGeneration(jobGen) },
                    isUrgentCommit: isUrgentCommit
                )
                guard !isCancelled(), worker.isCurrentGeneration(jobGen) else { return base }
                guard refinesNoisyInput,
                      samples.count >= NoisyChannelRefiner.minimumInputLength,
                      !(samples.count >= 22 && isUrgentCommit()) else { return base }
                // Show the primary ranking now; the sentence-level pass only replaces it if it finds a better reading.
                provisional(base)
                return worker.refiner.refine(
                    samples: samples,
                    base: base,
                    settings: settings,
                    spatialModel: worker.decoder.spatialModel,
                    precedingContext: contextSeed,
                    topicMemory: activeTopicMemory,
                    precomputedHyps: worker.decoder.fullHypothesesIfMatching(samples: samples, settings: settings),
                    isCancelled: { isCancelled() || !worker.isCurrentGeneration(jobGen) },
                    isPastDeadline: isPastDeadline,
                    isUrgentCommit: isUrgentCommit
                )
            }
            job.onProvisional = { [weak self, weak job] base in
                guard worker.isCurrentGeneration(jobGen) else { return }
                DispatchQueue.main.async { [weak self, weak job] in
                    guard let self, let job, self.pendingDecode === job else { return }
                    self.deferredPrimary = base
                    self.publishReadyCandidates()
                }
            }
            job.completionBlock = { [weak self, weak job] in
                guard worker.isCurrentGeneration(jobGen) else { return }
                DispatchQueue.main.async { [weak self, weak job] in
                    guard let self, let job, self.pendingDecode === job else { return }
                    self.publishReadyCandidates()
                }
            }
            pendingDecode = job
            worker.queue.addOperation(job)

            let raw = String(samples.map(\.primaryChar))
            needsImmediateCandidateRefresh = !hasPublishedRanking || currentDecode.candidates.contains {
                $0.consumedInputCount > samples.count
            }
            var visible = currentDecode.candidates
            var canonicalVisible = canonicalCurrentCandidates
            if canonicalVisible.count != visible.count {
                canonicalVisible = visible
            }
            if needsImmediateCandidateRefresh {
                var keptDisplay: [LokeyCandidate] = []
                var keptCanonical: [LokeyCandidate] = []
                keptDisplay.reserveCapacity(visible.count)
                keptCanonical.reserveCapacity(visible.count)
                for idx in visible.indices where visible[idx].consumedInputCount <= samples.count {
                    keptDisplay.append(visible[idx])
                    keptCanonical.append(canonicalVisible[idx])
                }
                visible = keptDisplay
                canonicalVisible = keptCanonical
            }
            if samples.count <= 5, canPublishCandidates?() != false, let immediateCanonical = exactShortCandidate(raw) {
                let immediateDisplay = convertedCandidate(immediateCanonical)
                if visible.first?.text != immediateDisplay.text || visible.first?.consumedInputCount != samples.count {
                    var nextDisplay: [LokeyCandidate] = [immediateDisplay]
                    var nextCanonical: [LokeyCandidate] = [immediateCanonical]
                    for idx in visible.indices where visible[idx].text != immediateDisplay.text {
                        nextDisplay.append(visible[idx])
                        nextCanonical.append(canonicalVisible[idx])
                    }
                    visible = nextDisplay
                    canonicalVisible = nextCanonical
                    needsImmediateCandidateRefresh = true
                }
            } else if visible.isEmpty {
                let rawCand = LokeyCandidate(
                    text: raw,
                    consumedInputCount: samples.count,
                    matchedSyllables: [],
                    scoreQ8: 0,
                    kind: .rawInput
                )
                visible.append(rawCand)
                canonicalVisible.append(rawCand)
            }
            let previous = currentDecode.preeditDisplay
            let plain = previous.replacingOccurrences(of: "'", with: "")
            let extendsSegmentedPrefix = composingCaretIndex == samples.count
                && !raw.contains("'")
                && !plain.isEmpty
                && raw.hasPrefix(plain)
            let preedit = extendsSegmentedPrefix ? previous + raw.dropFirst(plain.count) : raw
            canonicalCurrentCandidates = canonicalVisible
            currentDecode = DecodeResult(preeditDisplay: preedit, candidates: visible)
            return
        }
        installDecode(decoder.decode(samples: samples, settings: settings, precedingContext: contextSeed, topicMemory: activeTopicMemory))
    }

    // Show an exact one- or two-syllable word before the full spatial/LM ranking arrives.
    // 1-syllable hits use pre-cached RAM (`topOneSyllableWord`, zero `mmap` page faults);
    // 2-syllable probes run only once `mmap` pages are warm (or when synchronous mode is used).
    private func exactShortCandidate(_ raw: String) -> LokeyCandidate? {
        let lexicon = decoder.lexicon
        var best: LokeyCandidate?
        if let oneSyl = lexicon.topOneSyllableWord(forSyllable: raw) {
            best = LokeyCandidate(text: oneSyl.text, consumedInputCount: samples.count,
                                  matchedSyllables: [raw], scoreQ8: oneSyl.scoreQ8, kind: .lexiconPhrase)
        }
        guard candidateWorker == nil || lexicon.isMappedMemoryWarm else {
            lexicon.prewarmMappedPagesAsync()
            return best
        }
        func consider(_ node: UInt32, _ syllables: [String]) {
            guard let word = lexicon.words(at: node, limit: 1).first,
                  best == nil || word.scoreQ8 > best!.scoreQ8 else { return }
            best = LokeyCandidate(text: word.text, consumedInputCount: samples.count,
                                  matchedSyllables: syllables, scoreQ8: word.scoreQ8, kind: .lexiconPhrase)
        }
        for split in raw.indices.dropFirst() {
            let left = String(raw[..<split]), right = String(raw[split...])
            if let a = lexicon.syllableToID[left], let b = lexicon.syllableToID[right],
               let prefix = lexicon.step(from: 0, syllableID: a),
               let node = lexicon.step(from: prefix, syllableID: b) { consider(node, [left, right]) }
        }
        return best
    }

    private func installDecode(_ rawResult: DecodeResult) {
        lastRawSimplifiedDecode = rawResult
        lastAppliedScriptMode = settings.chineseScriptMode
        let mapped = applyScriptConversion(to: rawResult)
        currentDecode = mapped.display
        canonicalCurrentCandidates = mapped.canonicals
        hasPublishedRanking = true
        needsImmediateCandidateRefresh = true
        if !isSecureContext, settings.enableDiagnosticLogging,
           samples.count == 8,
           String(samples.map(\.primaryChar)) == "lokeylog" {
            let diagCand = LokeyCandidate(
                text: "📋输出诊断日志",
                consumedInputCount: 8,
                matchedSyllables: [],
                scoreQ8: 900_000,
                kind: .lexiconPhrase
            )
            var augmented = currentDecode.candidates
            augmented.insert(diagCand, at: 0)
            canonicalCurrentCandidates.insert(diagCand, at: 0)
            currentDecode = DecodeResult(preeditDisplay: "lokeylog", candidates: augmented)
        } else if !isSecureContext, settings.enableSelectionFeedbackLogging,
                  samples.count == 8,
                  String(samples.map(\.primaryChar)) == "lokeytsv" {
            let tsvCand = LokeyCandidate(
                text: "📋输出选词样本",
                consumedInputCount: 8,
                matchedSyllables: [],
                scoreQ8: 900_000,
                kind: .lexiconPhrase
            )
            var augmented = currentDecode.candidates
            augmented.insert(tsvCand, at: 0)
            canonicalCurrentCandidates.insert(tsvCand, at: 0)
            currentDecode = DecodeResult(preeditDisplay: "lokeytsv", candidates: augmented)
        }
        if !samples.isEmpty && samples.count <= 36 {
            let ctx = currentContextSeed()
            let activeTopic = isSecureContext ? NeuralSentenceScorer.Vec32.zero : topicMemoryVector
            if let existingIdx = completedPrefixSnapshots.firstIndex(where: {
                $0.samples == samples && $0.contextSeed == ctx && $0.topicMemory == activeTopic && $0.settings == settings
            }) {
                completedPrefixSnapshots.remove(at: existingIdx)
            } else if completedPrefixSnapshots.count >= 24 {
                completedPrefixSnapshots.removeFirst()
            }
            completedPrefixSnapshots.append(
                CompletedPrefixSnapshot(
                    samples: samples,
                    contextSeed: ctx,
                    topicMemory: activeTopic,
                    settings: settings,
                    rawResult: rawResult
                )
            )
        }
    }

    private func commitCandidate(at index: Int) -> KeyActionResult? {
        guard index >= 0 && index < currentDecode.candidates.count else {
            return nil
        }
        let cand = currentDecode.candidates[index]
        let canonical = canonicalCandidate(at: index) ?? cand
        if !isSecureContext, cand.text == "📋输出诊断日志" && cand.consumedInputCount == 8 {
            let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
            let report = LokeyDiagnosticLogger.formatPlainTextReport(
                snapshot: LokeyDiagnosticLogger.shared.currentSnapshot(),
                appVersion: ver
            )
            resetComposing()
            return .commitText(report, remaining: currentDecode)
        }
        if !isSecureContext, cand.text == "📋输出选词样本" && cand.consumedInputCount == 8 {
            let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
            let snap = (selectionFeedbackLogger ?? LokeySelectionFeedbackLogger.shared).currentSnapshot()
            let report = LokeySelectionFeedbackLogger.formatTSVReport(snapshot: snap, appVersion: ver)
            resetComposing()
            return .commitText(report, remaining: currentDecode)
        }
        if index >= 1 && !isSecureContext {
            let skipWindowEnd = min(index, 2)
            for skippedIdx in 0..<skipWindowEnd {
                let skipped = currentDecode.candidates[skippedIdx]
                let skippedCanonical = canonicalCandidate(at: skippedIdx) ?? skipped
                guard skippedCanonical.kind == .userPhrase,
                      skippedCanonical.consumedInputCount == canonical.consumedInputCount,
                      skippedCanonical.text != canonical.text else {
                    continue
                }
                let compactPinyin: String
                if !skippedCanonical.matchedSyllables.isEmpty {
                    compactPinyin = skippedCanonical.matchedSyllables.joined().lowercased()
                } else {
                    compactPinyin = String(samples.prefix(skippedCanonical.consumedInputCount).map { $0.primaryChar })
                        .lowercased()
                        .filter { $0 >= "a" && $0 <= "z" }
                }
                if !compactPinyin.isEmpty {
                    decoder.userStore.recordExposureSkip(
                        compactPinyin: compactPinyin,
                        skippedSurface: skippedCanonical.text
                    )
                }
            }
        }
        let consume = max(1, min(samples.count, cand.consumedInputCount))
        let committedSamples = Array(samples.prefix(consume))
        let rawSlice = String(committedSamples.map(\.primaryChar))
        recordTouchCalibrationIfEligible(
            consumedSamples: committedSamples,
            matchedSyllables: canonical.matchedSyllables
        )

        let top0Canonical = canonicalCandidate(at: 0)
        let shouldTrackFeedback: Bool = {
            guard let logger = selectionFeedbackLogger,
                  !isSecureContext,
                  settings.enableSelectionFeedbackLogging,
                  logger.canRecord else { return false }
            if canonical.kind == .emoji { return false }
            if canonical.kind == .rawInput && (top0Canonical?.kind == .rawInput || canonicalCurrentCandidates.isEmpty) {
                return false
            }
            return true
        }()

        if consume < samples.count {
            // Partial commit: user picked a prefix word/char; keep remaining Pinyin active!
            if shouldTrackFeedback, !canonical.matchedSyllables.isEmpty {
                let preview = topCanonicalPreview(from: canonicalCurrentCandidates)
                if pendingSegments.isEmpty {
                    utteranceFeedbackState = UtteranceFeedbackState(
                        precedingContext: sanitizedFeedbackContext(currentContextSeed()),
                        initialRawInput: String(samples.map(\.primaryChar)),
                        initialTop1Text: top0Canonical?.text ?? "",
                        initialTop1ConsumedAll: top0Canonical?.consumedInputCount == samples.count,
                        initialFirstPickIndex: index,
                        initialTopCandidates: preview
                    )
                }
                if index >= 1,
                   let skippedSameSpan = (0..<index).lazy.compactMap({ self.canonicalCandidate(at: $0) }).first(where: {
                       $0.consumedInputCount == consume && $0.text != canonical.text
                   }) {
                    utteranceFeedbackState?.deferredStepMismatches.append(
                        UtteranceFeedbackState.DeferredStepMismatch(
                            context: sanitizedFeedbackContext(currentContextSeed()),
                            rawSlice: rawSlice,
                            matchedPinyin: canonical.matchedSyllables.joined(separator: " "),
                            top1: skippedSameSpan.text,
                            chosen: canonical.text,
                            index: index,
                            preview: preview
                        )
                    )
                }
            }

            if !isSecureContext, !canonical.matchedSyllables.isEmpty {
                pendingSegments.append(ComposedSegment(text: canonical.text, syllables: canonical.matchedSyllables, rawInputSlice: rawSlice))
            } else {
                pendingSegments.removeAll()
                utteranceFeedbackState = nil
            }
            samples.removeFirst(consume)
            composingCaretIndex = max(0, min(samples.count, composingCaretIndex - consume))
            completedPrefixSnapshots.removeAll(keepingCapacity: true)
            redecode()
            recordCommittedSurfaceForBigram(canonical.text, kind: canonical.kind, trailingWord: canonical.trailingWord)
            recordCommittedDisplayMapping(display: cand.text, canonical: canonical.text)
            updateChineseContextFlag(for: cand.text)
            return .commitText(cand.text, remaining: currentDecode)
        } else {
            // Final commit consuming the rest of the buffer!
            if shouldTrackFeedback, let logger = selectionFeedbackLogger {
                if pendingSegments.isEmpty {
                    let top0 = top0Canonical ?? canonical
                    if index == 0 || canonical.text == top0.text {
                        logger.recordTop1Hit()
                    } else {
                        logger.recordMismatch(
                            kind: .nonTopSelect,
                            pinyinScheme: settings.pinyinScheme.rawValue,
                            precedingContext: sanitizedFeedbackContext(currentContextSeed()),
                            rawInput: rawSlice,
                            matchedPinyin: canonical.matchedSyllables.joined(separator: " "),
                            top1Predicted: top0.text,
                            userChosen: canonical.text,
                            selectedIndex: index,
                            topCandidatesPreview: topCanonicalPreview(from: canonicalCurrentCandidates),
                            alsoCountCommit: true
                        )
                    }
                } else if let uState = utteranceFeedbackState, !canonical.matchedSyllables.isEmpty {
                    if !uState.didAppendLettersAfterPartialCommit {
                        let assembledText = (pendingSegments.map(\.text) + [canonical.text]).joined()
                        let assembledPinyin = (pendingSegments.flatMap(\.syllables) + canonical.matchedSyllables).joined(separator: " ")
                        if uState.initialTop1ConsumedAll && assembledText == uState.initialTop1Text {
                            logger.recordTop1Hit()
                        } else if !uState.initialTop1Text.isEmpty && assembledText != uState.initialTop1Text {
                            logger.recordMismatch(
                                kind: .stepwiseCompose,
                                pinyinScheme: settings.pinyinScheme.rawValue,
                                precedingContext: uState.precedingContext,
                                rawInput: uState.initialRawInput,
                                matchedPinyin: assembledPinyin,
                                top1Predicted: uState.initialTop1Text,
                                userChosen: assembledText,
                                selectedIndex: uState.initialFirstPickIndex,
                                topCandidatesPreview: uState.initialTopCandidates,
                                alsoCountCommit: true
                            )
                        } else {
                            logger.recordTop1Hit()
                        }
                    } else {
                        var stepMismatches = uState.deferredStepMismatches
                        if index >= 1, let top0 = top0Canonical, top0.text != canonical.text {
                            stepMismatches.append(
                                UtteranceFeedbackState.DeferredStepMismatch(
                                    context: sanitizedFeedbackContext(currentContextSeed()),
                                    rawSlice: rawSlice,
                                    matchedPinyin: canonical.matchedSyllables.joined(separator: " "),
                                    top1: top0.text,
                                    chosen: canonical.text,
                                    index: index,
                                    preview: topCanonicalPreview(from: canonicalCurrentCandidates)
                                )
                            )
                        }
                        if stepMismatches.isEmpty {
                            logger.recordTop1Hit()
                        } else {
                            for (offset, step) in stepMismatches.enumerated() {
                                logger.recordMismatch(
                                    kind: .nonTopSelect,
                                    pinyinScheme: settings.pinyinScheme.rawValue,
                                    precedingContext: step.context,
                                    rawInput: step.rawSlice,
                                    matchedPinyin: step.matchedPinyin,
                                    top1Predicted: step.top1,
                                    userChosen: step.chosen,
                                    selectedIndex: step.index,
                                    topCandidatesPreview: step.preview,
                                    alsoCountCommit: offset == 0
                                )
                            }
                        }
                    }
                }
            }

            if !isSecureContext, !pendingSegments.isEmpty && !canonical.matchedSyllables.isEmpty {
                let allSegments = pendingSegments + [ComposedSegment(text: canonical.text, syllables: canonical.matchedSyllables, rawInputSlice: rawSlice)]
                let fullSurface = allSegments.map(\.text).joined()
                let fullSyllables = allSegments.flatMap(\.syllables)
                if shouldLearnComposedCustomPhrase(
                    segments: allSegments,
                    fullSurface: fullSurface,
                    fullSyllables: fullSyllables
                ) {
                    decoder.userStore.recordCommit(
                        surface: fullSurface,
                        syllables: fullSyllables,
                        isCustomComposed: true
                    )
                }
            } else if !isSecureContext, !canonical.matchedSyllables.isEmpty && (
                canonical.kind == .userPhrase || (
                    index > 0
                        && canonical.kind == .lexiconPhrase
                        && canonical.text.count <= 3
                        && !UserLexiconStore.isConversationalClauseSurface(canonical.text)
                )
            ) {
                // Boost explicitly chosen non-default <=3-char dictionary candidate or existing user phrase in SQLite.
                // Never auto-save whole-buffer `.sentence` or >=4-char phrase commits into `user_phrases`!
                decoder.userStore.recordCommit(
                    surface: canonical.text,
                    syllables: canonical.matchedSyllables,
                    isCustomComposed: false
                )
            }

            if !isSecureContext, canonical.kind == .emoji {
                LokeyRecentEmojis.recordUsage(canonical.text)
            }
            recordCommittedSurfaceForBigram(canonical.text, kind: canonical.kind, trailingWord: canonical.trailingWord)
            recordCommittedDisplayMapping(display: cand.text, canonical: canonical.text)
            updateChineseContextFlag(for: cand.text)
            resetComposing()
            return .commitText(cand.text, remaining: currentDecode)
        }
    }

    // MARK: - OpenCC Display / Canonical Simplified Split

    private func canonicalCandidate(at index: Int) -> LokeyCandidate? {
        guard index >= 0 && index < canonicalCurrentCandidates.count else { return nil }
        return canonicalCurrentCandidates[index]
    }

    private static func shouldConvertCandidateToScript(_ cand: LokeyCandidate, mode: ChineseScriptMode) -> Bool {
        guard mode != .simplified else { return false }
        switch cand.kind {
        case .rawInput, .emoji:
            return false
        case .english:
            return !cand.text.utf8.allSatisfy { $0 < 0x80 }
        case .sentence, .lexiconPhrase, .userPhrase, .jianpin:
            if cand.text == "📋输出诊断日志" || cand.text == "📋输出选词样本" { return false }
            return !cand.text.utf8.allSatisfy { $0 < 0x80 }
        }
    }

    private func sanitizedFeedbackContext(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.suffix(10))
    }

    private func topCanonicalPreview(from candidates: [LokeyCandidate], limit: Int = 5) -> [String] {
        var out: [String] = []
        out.reserveCapacity(limit)
        var seen = Set<String>()
        for c in candidates {
            guard c.kind != .emoji,
                  c.text != "📋输出诊断日志",
                  c.text != "📋输出选词样本",
                  !c.text.isEmpty,
                  seen.insert(c.text).inserted else { continue }
            out.append(c.text)
            if out.count >= limit { break }
        }
        return out
    }

    private func convertedCandidate(_ cand: LokeyCandidate, converter: OpenCCConverter? = nil) -> LokeyCandidate {
        guard Self.shouldConvertCandidateToScript(cand, mode: settings.chineseScriptMode) else {
            return cand
        }
        let conv = converter ?? .shared
        let convertedText = conv.convert(cand.text, mode: settings.chineseScriptMode)
        guard convertedText != cand.text else { return cand }
        return LokeyCandidate(
            text: convertedText,
            consumedInputCount: cand.consumedInputCount,
            matchedSyllables: cand.matchedSyllables,
            scoreQ8: cand.scoreQ8,
            kind: cand.kind,
            isDeletableUserPhrase: cand.isDeletableUserPhrase,
            trailingWord: cand.trailingWord
        )
    }

    private func applyScriptConversion(to rawResult: DecodeResult) -> (display: DecodeResult, canonicals: [LokeyCandidate]) {
        guard settings.chineseScriptMode != .simplified, !rawResult.candidates.isEmpty else {
            return (rawResult, rawResult.candidates)
        }
        var converter: OpenCCConverter?
        var displayList: [LokeyCandidate] = []
        var canonicalList: [LokeyCandidate] = []
        displayList.reserveCapacity(rawResult.candidates.count)
        canonicalList.reserveCapacity(rawResult.candidates.count)
        var seenDisplayTexts = Set<String>()
        for rawCand in rawResult.candidates {
            if converter == nil && Self.shouldConvertCandidateToScript(rawCand, mode: settings.chineseScriptMode) {
                converter = .shared
            }
            let disp = convertedCandidate(rawCand, converter: converter)
            guard seenDisplayTexts.insert(disp.text).inserted else { continue }
            displayList.append(disp)
            canonicalList.append(rawCand)
        }
        return (DecodeResult(preeditDisplay: rawResult.preeditDisplay, candidates: displayList), canonicalList)
    }

    private func convertAuxiliaryCandidates(_ rawList: [LokeyCandidate]) -> [LokeyCandidate] {
        guard settings.chineseScriptMode != .simplified, !rawList.isEmpty else { return rawList }
        var converter: OpenCCConverter?
        if displayToCanonicalSurface.count > 256 {
            displayToCanonicalSurface.removeAll(keepingCapacity: true)
        }
        var out: [LokeyCandidate] = []
        out.reserveCapacity(rawList.count)
        var seen = Set<String>()
        for raw in rawList {
            if converter == nil && Self.shouldConvertCandidateToScript(raw, mode: settings.chineseScriptMode) {
                converter = .shared
            }
            let disp = convertedCandidate(raw, converter: converter)
            guard seen.insert(disp.text).inserted else { continue }
            if disp.text != raw.text {
                displayToCanonicalSurface[disp.text] = raw.text
            }
            out.append(disp)
        }
        return out
    }

    private func recordCommittedDisplayMapping(display: String, canonical: String) {
        guard display != canonical, !display.isEmpty, !canonical.isEmpty else { return }
        if displayToCanonicalSurface.count > 256 {
            displayToCanonicalSurface.removeAll(keepingCapacity: true)
        }
        displayToCanonicalSurface[display] = canonical
        if let idx = recentCommittedDisplayToCanonical.lastIndex(where: { $0.display == display }) {
            recentCommittedDisplayToCanonical.remove(at: idx)
        }
        recentCommittedDisplayToCanonical.append((display: display, canonical: canonical))
        if recentCommittedDisplayToCanonical.count > 16 {
            recentCommittedDisplayToCanonical.removeFirst()
        }
    }

    private func canonicalizeContext(_ text: String) -> String {
        guard !text.isEmpty, !recentCommittedDisplayToCanonical.isEmpty else { return text }
        var remaining = text
        var canonicalTail = ""
        var steps = 0
        while !remaining.isEmpty && steps < 6 {
            guard let match = recentCommittedDisplayToCanonical.reversed().first(where: {
                !$0.display.isEmpty && $0.display != $0.canonical && remaining.hasSuffix($0.display)
            }) else {
                break
            }
            remaining.removeLast(match.display.count)
            canonicalTail = match.canonical + canonicalTail
            steps += 1
        }
        return canonicalTail.isEmpty ? text : (remaining + canonicalTail)
    }

    private func recordTouchCalibrationIfEligible(
        consumedSamples: [TouchSample],
        matchedSyllables: [String]
    ) {
        guard !isSecureContext, settings.enableSpatialCorrection,
              settings.enableAdaptiveTouchCalibration,
              !matchedSyllables.isEmpty,
              !consumedSamples.isEmpty else {
            return
        }
        let calibrationSyllables: [String]
        if settings.pinyinScheme == .quanpin {
            calibrationSyllables = matchedSyllables
        } else {
            let mapped = matchedSyllables.compactMap {
                PinyinSyllableAutomaton.primaryShuangpinCode(forCanonicalSyllable: $0, scheme: settings.pinyinScheme)
            }
            guard mapped.count == matchedSyllables.count,
                  mapped.reduce(0, { $0 + $1.count }) == consumedSamples.count else {
                return
            }
            calibrationSyllables = mapped
        }
        let learned = decoder.spatialModel.recordConfirmedAlignment(
            samples: consumedSamples,
            intendedSyllables: calibrationSyllables
        )
        if learned > 0 && persistTouchCalibration {
            decoder.spatialModel.flushCalibrationToDiskIfNeeded(force: false)
        }
    }

    private func shouldLearnComposedCustomPhrase(
        segments: [ComposedSegment],
        fullSurface: String,
        fullSyllables: [String]
    ) -> Bool {
        guard segments.count >= 2,
              fullSyllables.count >= 2 && fullSyllables.count <= 4,
              fullSurface.count == fullSyllables.count,
              fullSurface.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }),
              !UserLexiconStore.isConversationalClauseSurface(fullSurface),
              !segments.contains(where: { UserLexiconStore.isConversationalClauseSegment($0.text) }) else {
            return false
        }

        // Reject preposition/adverb + noun phrase clauses (e.g., "去" + "公司", "在" + "学校", "给" + "老板")
        if fullSyllables.count >= 3, let firstSeg = segments.first,
           UserLexiconStore.isLeadingClausePreposition(firstSeg.text) {
            return false
        }

        // Skip cluttering `is_custom = 1` if `fullSurface` is already the #1 built-in word for `fullSyllables`.
        var node = decoder.lexicon.rootNodeIndex
        var matchedAll = true
        for syl in fullSyllables {
            guard let sid = decoder.lexicon.syllableToID[syl.lowercased()], sid > 0,
                  let next = decoder.lexicon.step(from: node, syllableID: sid) else {
                matchedAll = false
                break
            }
            node = next
        }
        if matchedAll, decoder.lexicon.words(at: node, limit: 1).first?.text == fullSurface {
            return false
        }
        return true
    }

    private func segmentCommittedWordsForTopicMemory(_ text: String, trailingWord: String?) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let lockedTailLen: Int
        if let tw = trailingWord, !tw.isEmpty, tw.count < chars.count, text.hasSuffix(tw) {
            lockedTailLen = tw.count
        } else {
            lockedTailLen = 0
        }
        let bodyCount = chars.count - lockedTailLen
        var out: [String] = []
        out.reserveCapacity(min(8, max(1, chars.count / 2 + 1)))
        var pos = max(0, bodyCount - 16)
        while pos < bodyCount && out.count < 8 {
            var matchedLen = 1
            let maxLen = min(4, bodyCount - pos)
            if maxLen >= 2 {
                for len in stride(from: maxLen, through: 2, by: -1) {
                    let piece = String(chars[pos..<(pos + len)])
                    if decoder.lexicon.neuralLM.lookupWordTableEmbedding(piece) != nil {
                        matchedLen = len
                        break
                    }
                }
            }
            out.append(String(chars[pos..<(pos + matchedLen)]))
            pos += matchedLen
        }
        if lockedTailLen > 0, let tw = trailingWord {
            out.append(tw)
        }
        return out
    }

    private func recordCommittedSurfaceForBigram(
        _ text: String,
        kind: LokeyCandidate.Kind,
        trailingWord: String? = nil
    ) {
        if !text.isEmpty {
            lastClauseContextSuffix = ""
        }
        guard !isSecureContext, !text.isEmpty, text.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else {
            lastCommittedChineseWord = ""
            if isSecureContext {
                topicMemoryVector = .zero
            }
            return
        }

        if decoder.lexicon.neuralLM.isSemantic64Loaded {
            let topicWords = segmentCommittedWordsForTopicMemory(text, trailingWord: trailingWord)
            if !topicWords.isEmpty {
                topicMemoryVector = decoder.lexicon.neuralLM.decayTopicMemory(
                    topicMemoryVector,
                    committedWords: topicWords,
                    isSentenceBreak: false
                )
            }
        }

        if kind != .sentence
            && text.count <= 3
            && !UserLexiconStore.isConversationalClauseSurface(text) {
            if !lastCommittedChineseWord.isEmpty {
                decoder.userStore.recordBigram(prevSurface: lastCommittedChineseWord, nextSurface: text)
            }
            lastCommittedChineseWord = text
        } else if let tw = trailingWord,
                  !tw.isEmpty,
                  tw.count <= 3,
                  tw.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }),
                  !UserLexiconStore.isConversationalClauseSurface(tw) {
            lastCommittedChineseWord = tw
        } else {
            let tail2 = String(text.suffix(min(2, text.count)))
            if !UserLexiconStore.isConversationalClauseSurface(tail2) {
                lastCommittedChineseWord = tail2
            } else {
                lastCommittedChineseWord = ""
            }
        }
    }

    private func updateChineseContextFlag(for text: String) {
        if let lastScalar = text.unicodeScalars.last {
            lastCommittedWasChinese = (lastScalar.value >= 0x4E00 && lastScalar.value <= 0x9FFF)
                || (lastScalar.value >= 0x3000 && lastScalar.value <= 0x303F)
                || (lastScalar.value >= 0xFF00 && lastScalar.value <= 0xFFEF)
        }
    }
}

/// Deterministic, zero-lag document context tracker bridging `UITextDocumentProxy` async XPC round-trips
/// without ever retaining stale optimistic associations when the host app clears or submits the text field.
public struct DocumentContextTracker: Sendable {
    public static let optimisticWindowSeconds: TimeInterval = 0.24

    public private(set) var optimisticOverride: String?
    // Host context may be truncated. Only delete the characters the host actually exposed.
    public private(set) var currentLineLength: Int?
    public private(set) var currentLineFollowsSeparator = false
    public mutating func observeLine(before text: String?) {
        guard let text else {
            currentLineLength = nil
            currentLineFollowsSeparator = false
            return
        }
        let start = text.lastIndex(where: { $0.isNewline })
        currentLineFollowsSeparator = start != nil
        currentLineLength = text.distance(from: start.map { text.index(after: $0) } ?? text.startIndex, to: text.endIndex)
    }

    public private(set) var preEditProxySuffix: String = ""
    public private(set) var lastEditUptime: TimeInterval = 0
    public private(set) var lastKnownProxySuffix: String = ""
    public private(set) var editGeneration: UInt64 = 0

    public init() {}

    public mutating func reset(proxyBefore: String?) {
        observeLine(before: proxyBefore)
        optimisticOverride = nil
        preEditProxySuffix = ""
        lastEditUptime = 0
        lastKnownProxySuffix = String((proxyBefore ?? "").suffix(12))
        editGeneration &+= 1
    }

    /// Returns the in-memory optimistic context without querying XPC when an edit was just performed (`<= maxAge`).
    public func recentOptimisticContext(at now: TimeInterval, maxAge: TimeInterval = 0.08) -> String? {
        guard let override = optimisticOverride,
              now >= lastEditUptime,
              (now - lastEditUptime) <= min(maxAge, Self.optimisticWindowSeconds) else {
            return nil
        }
        return override
    }

    /// Zero-XPC in-memory context snapshot for ultra-low-latency touch handlers (`< 0.001 ms`).
    /// Prefers `optimisticOverride` whenever unreconciled edits are still pending async XPC confirmation,
    /// falling back to `lastKnownProxySuffix` once `reconcileAfterXPCDelay` / `textDidChange` settles.
    public func cachedContext(at now: TimeInterval) -> String {
        if let override = optimisticOverride {
            return override
        }
        return lastKnownProxySuffix
    }

    /// Resolves the live context before the cursor, bridging the async XPC gap (`<= 240ms`)
    /// right after `insertText` / `deleteBackward` when no external `textDidChange` has intervened.
    public mutating func resolveContext(
        proxyBefore: String?,
        now: TimeInterval
    ) -> (context: String, brokeContext: Bool) {
        let live = proxyBefore ?? ""
        if let override = optimisticOverride {
            if Self.isSynced(override: override, liveProxy: live, preEditProxySuffix: preEditProxySuffix) {
                optimisticOverride = nil
                preEditProxySuffix = ""
                lastKnownProxySuffix = String(live.suffix(12))
                return (live, false)
            }
            if now - lastEditUptime < Self.optimisticWindowSeconds {
                return (override, false)
            }
            optimisticOverride = nil
            preEditProxySuffix = ""
            lastKnownProxySuffix = String(live.suffix(12))
            return (live, true)
        }
        return (live, false)
    }

    @discardableResult
    public mutating func recordInsert(
        _ text: String,
        currentProxyBefore: String?,
        now: TimeInterval
    ) -> UInt64 {
        let liveSuffix = String((currentProxyBefore ?? "").suffix(12))
        let base: String
        if let override = optimisticOverride {
            base = override
        } else {
            base = currentProxyBefore ?? ""
            preEditProxySuffix = liveSuffix
        }
        if text.contains(where: { $0.isNewline }) {
            observeLine(before: text)
        } else if let currentLineLength {
            self.currentLineLength = currentLineLength + text.count
        }
        let merged = base + text
        optimisticOverride = String(merged.suffix(12))
        lastEditUptime = now
        editGeneration &+= 1
        return editGeneration
    }

    @discardableResult
    public mutating func recordBackspacePassThrough(
        currentProxyBefore: String?,
        now: TimeInterval
    ) -> UInt64 {
        let liveSuffix = String((currentProxyBefore ?? "").suffix(12))
        let base: String
        if let override = optimisticOverride {
            base = override
        } else {
            base = currentProxyBefore ?? ""
            preEditProxySuffix = liveSuffix
        }
        if let currentLineLength {
            self.currentLineLength = currentLineLength > 0 ? currentLineLength - 1 : nil
            if currentLineLength == 0 { currentLineFollowsSeparator = false }
        }
        optimisticOverride = base.isEmpty ? "" : String(base.dropLast())
        lastEditUptime = now
        editGeneration &+= 1
        return editGeneration
    }

    @discardableResult
    public mutating func recordNewlineOrClear(now: TimeInterval, insertedLineBreak: Bool = false) -> UInt64 {
        if insertedLineBreak { currentLineFollowsSeparator = true }
        currentLineLength = 0
        optimisticOverride = ""
        preEditProxySuffix = ""
        lastEditUptime = now
        lastKnownProxySuffix = ""
        editGeneration &+= 1
        return editGeneration
    }

    public mutating func recordCursorMove() {
        currentLineLength = nil
        optimisticOverride = nil
        preEditProxySuffix = ""
        lastEditUptime = 0
        editGeneration &+= 1
    }

    /// Handles UIKit `textDidChange(_:)`, which fires on external host mutations (e.g. tapping "清空" or "发送",
    /// cursor jumps, paste). Immediately invalidates any optimistic override so cleared fields never retain stale associations.
    @discardableResult
    public mutating func handleExternalTextDidChange(
        proxyBefore: String?,
        isComposing: Bool
    ) -> (didBreakContext: Bool, generation: UInt64) {
        let live = proxyBefore ?? ""
        observeLine(before: proxyBefore)
        let curSuffix = String(live.suffix(12))
        editGeneration &+= 1

        if let override = optimisticOverride {
            let synced = Self.isSynced(override: override, liveProxy: live, preEditProxySuffix: preEditProxySuffix)
            optimisticOverride = nil
            preEditProxySuffix = ""
            lastKnownProxySuffix = curSuffix
            return (!synced && !isComposing, editGeneration)
        }

        if curSuffix != lastKnownProxySuffix && !isComposing {
            lastKnownProxySuffix = curSuffix
            return (true, editGeneration)
        }
        return (false, editGeneration)
    }

    /// Reconciles passive XPC updates after self-edits or `textDidChange`.
    /// When `now` is still within `optimisticWindowSeconds` and `proxyBefore` is unchanged from `preEditProxySuffix`
    /// (slow XPC rich-text host taking 100–200ms to reflect `insertText`), retains `optimisticOverride` until
    /// the window expires so associations do not prematurely vanish, while silent host clears settle once the window ends.
    public mutating func reconcileAfterXPCDelay(
        generation: UInt64,
        proxyBefore: String?,
        isComposing: Bool,
        now: TimeInterval? = nil
    ) -> (needsRefresh: Bool, didBreakContext: Bool) {
        guard generation == editGeneration else {
            return (false, false)
        }
        let live = proxyBefore ?? ""
        let curSuffix = String(live.suffix(12))

        if let override = optimisticOverride {
            let synced = Self.isSynced(override: override, liveProxy: live, preEditProxySuffix: preEditProxySuffix)
            if synced {
                observeLine(before: proxyBefore)
                optimisticOverride = nil
                preEditProxySuffix = ""
                lastKnownProxySuffix = curSuffix
                return (false, false)
            }
            if let currentUptime = now,
               currentUptime - lastEditUptime < Self.optimisticWindowSeconds,
               curSuffix == preEditProxySuffix {
                return (false, false)
            }
            optimisticOverride = nil
            preEditProxySuffix = ""
            lastKnownProxySuffix = curSuffix
            observeLine(before: proxyBefore)
            if !isComposing {
                return (true, true)
            }
            return (false, false)
        }

        observeLine(before: proxyBefore)
        if curSuffix != lastKnownProxySuffix && !isComposing {
            lastKnownProxySuffix = curSuffix
            return (true, false)
        }
        return (false, false)
    }

    /// Returns the remaining duration (plus 10ms margin) if an optimistic bridge is still waiting on slow XPC.
    public func remainingOptimisticDelay(at now: TimeInterval) -> TimeInterval? {
        guard optimisticOverride != nil else { return nil }
        let rem = Self.optimisticWindowSeconds - (now - lastEditUptime)
        return rem > 0 ? (rem + 0.01) : 0.01
    }

    /// Deterministic rule deciding whether `KeyboardViewController.textDidChange(_:)` should reset active Pinyin composing.
    /// Immediately resets (`0ms`) on responder switches, cleared/submitted empty documents (`!hasText`), or prefix anchor changes,
    /// while preserving active preedit across:
    /// 1) Asynchronous rich-text / custom `UITextInput` `setMarkedText` echoes (`<= 250ms`),
    /// 2) `UITextView` hosts where `documentContextBeforeInput` includes `activeMarkedText` before the caret, and
    /// 3) Multi-segment partial prefix commits (`elapsedSincePartialCommit <= 0.35s`) where `unmarkText` echoes arrive while
    ///    the remaining Pinyin suffix is still actively composing!
    public static func shouldResetComposingOnExternalChange(
        didSwitchDocument: Bool,
        hasText: Bool,
        proxyBefore: String?,
        composingAnchor: String,
        elapsedSinceMarkedMutation: TimeInterval,
        hasPendingOptimisticBridge: Bool = false,
        preEditProxySuffix: String = "",
        activeMarkedText: String = "",
        elapsedSincePartialCommit: TimeInterval = .infinity
    ) -> Bool {
        if didSwitchDocument {
            return true
        }
        if !hasText {
            return elapsedSincePartialCommit > 0.35
        }
        if elapsedSincePartialCommit <= 0.35 {
            return false
        }
        let liveBefore = proxyBefore ?? ""
        let liveSuffix = String(liveBefore.suffix(12))
        let anchorWithMarkedSuffix = activeMarkedText.isEmpty
            ? composingAnchor
            : String((composingAnchor + activeMarkedText).suffix(12))
        if liveSuffix == composingAnchor || liveSuffix == anchorWithMarkedSuffix {
            return false
        }
        if isInFlightMarkedEcho(
            liveBefore: liveBefore,
            composingAnchor: composingAnchor,
            activeMarkedText: activeMarkedText
        ) {
            return false
        }
        if hasPendingOptimisticBridge && liveSuffix == preEditProxySuffix && elapsedSinceMarkedMutation <= 0.45 {
            return false
        }
        return true
    }

    /// Detects asynchronous `UITextView` / WebKit `textDidChange` echoes where `documentContextBeforeInput`
    /// contains `composingAnchor` plus an in-flight prefix (or 1–2 keystroke lag) of `activeMarkedText`.
    private static func isInFlightMarkedEcho(
        liveBefore: String,
        composingAnchor: String,
        activeMarkedText: String
    ) -> Bool {
        guard !activeMarkedText.isEmpty else { return false }
        let normMarked = normalizeMarkedComparison(activeMarkedText)
        guard !normMarked.isEmpty else { return false }
        let normLive = normalizeMarkedComparison(String(liveBefore.suffix(64)))
        let normAnchor = normalizeMarkedComparison(composingAnchor)

        if normAnchor.isEmpty {
            return normLive.isEmpty || normMarked.hasPrefix(normLive) || normLive.hasPrefix(normMarked)
        }
        if let anchorRange = normLive.range(of: normAnchor, options: .backwards) {
            let tail = String(normLive[anchorRange.upperBound...])
            return tail.isEmpty || normMarked.hasPrefix(tail) || tail.hasPrefix(normMarked)
        }
        return false
    }

    private static func normalizeMarkedComparison(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() {
            if ch == " " || ch == "\u{00A0}" || ch == "'" {
                continue
            }
            out.append(ch)
        }
        return out
    }

    private static func isSynced(override: String, liveProxy: String, preEditProxySuffix: String) -> Bool {
        let curSuffix = String(liveProxy.suffix(12))
        if curSuffix == preEditProxySuffix && override != preEditProxySuffix {
            return false
        }
        if override.isEmpty {
            return liveProxy.isEmpty || liveProxy.hasSuffix("\n")
        }
        return liveProxy == override || liveProxy.hasSuffix(override)
    }
}

