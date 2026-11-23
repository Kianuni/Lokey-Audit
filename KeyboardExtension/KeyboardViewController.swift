import ObjectiveC
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Passive, zero-delay root-view touch sniffer that records every physical screen touch-down
/// (`#1, #2, ...`, coordinates, multi-touch overlap, and resolved `hitTest` target) into `LokeyDiagnosticLogger`
/// without delaying, cancelling, or preventing any subview control or scroll gesture.
internal final class DiagnosticTouchSnifferGestureRecognizer: UIGestureRecognizer {
    var onScreenTouchDown: ((CGPoint, Int, UIView?, Double?) -> UInt64)?
    private var trackedTouches = Set<UITouch>()
    private let sequences = NSMapTable<UITouch, NSNumber>.weakToStrongObjects()

    private func pruneEndedTrackedTouches() {
        guard !trackedTouches.isEmpty else { return }
        var stale: [UITouch]?
        for t in trackedTouches {
            let phase = t.phase
            if phase == .ended || phase == .cancelled {
                if stale == nil { stale = [] }
                stale?.append(t)
            }
        }
        if let stale {
            for t in stale {
                if let seq = sequences.object(forKey: t)?.uint64Value, seq != 0 {
                    LokeyDiagnosticLogger.shared.recordTouchEnd(touchSeq: seq, cancelled: t.phase == .cancelled)
                }
                trackedTouches.remove(t)
                sequences.removeObject(forKey: t)
            }
        }
    }

    func resetTrackedTouches() {
        trackedTouches.removeAll(keepingCapacity: true)
        sequences.removeAllObjects()
        if state == .began || state == .changed {
            state = .cancelled
        }
    }

    // UIKit can deliver both downs together. Share the same identity even when
    // the key grid gets its callback before the root gesture recognizer.
    func sequence(for touch: UITouch, event: UIEvent?) -> UInt64 {
        guard LokeyDiagnosticLogger.shared.canRecordInteractions else { return 0 }
        if let seq = sequences.object(forKey: touch) { return seq.uint64Value }
        guard let host = view, let onScreenTouchDown else { return 0 }
        pruneEndedTrackedTouches()
        var active = 0
        if let allTouches = event?.allTouches {
            for t in allTouches {
                if t === touch {
                    active &+= 1
                } else {
                    let p = t.phase
                    if p == .moved || p == .stationary || sequences.object(forKey: t) != nil {
                        active &+= 1
                    }
                }
            }
        }
        let observed = trackedTouches.count + (trackedTouches.contains(touch) ? 0 : 1)
        let fingers = max(observed, active)
        let lag = touch.timestamp > 0 ? max(0, (ProcessInfo.processInfo.systemUptime - touch.timestamp) * 1000) : nil
        let seq = onScreenTouchDown(touch.location(in: host), fingers, touch.view, lag)
        sequences.setObject(NSNumber(value: seq), forKey: touch)
        return seq
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard LokeyDiagnosticLogger.shared.canRecordInteractions else {
            if !trackedTouches.isEmpty {
                trackedTouches.removeAll(keepingCapacity: true)
                sequences.removeAllObjects()
            }
            state = .failed
            return
        }
        pruneEndedTrackedTouches()
        if touches.count == 1, let singleTouch = touches.first {
            trackedTouches.insert(singleTouch)
            _ = sequence(for: singleTouch, event: event)
        } else if touches.count > 1 {
            for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
                trackedTouches.insert(touch)
                _ = sequence(for: touch, event: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Passive sniffer: zero work on 120Hz finger movement.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true, event: event)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool, event: UIEvent?) {
        for touch in touches {
            if let seq = sequences.object(forKey: touch)?.uint64Value, seq != 0 {
                LokeyDiagnosticLogger.shared.recordTouchEnd(touchSeq: seq, cancelled: cancelled)
                sequences.removeObject(forKey: touch)
            }
            trackedTouches.remove(touch)
        }
        let hasOtherActiveTouch = event?.allTouches?.contains(where: { t in
            guard !touches.contains(t) else { return false }
            let phase = t.phase
            return phase == .began || phase == .moved || phase == .stationary
        }) ?? false
        if trackedTouches.isEmpty && !hasOtherActiveTouch {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll(keepingCapacity: true)
        sequences.removeAllObjects()
    }
}

/// Shared read-only `mmap` lexicon holder inside the Keyboard Extension process so subsequent
/// text-field focus transitions reuse the clean mapped pages in `0 ms`, while supporting `.lokeypack` hot-reloads.
private enum SharedLexiconHolder {
    private static let lexiconLock = NSLock()
    private static var cachedLexicon: MmapLexicon?
    private static var cachedSignature: LokeyLexiconPackManager.ActiveSignature?
    private static var didStartPrewarm = false

    static func builtInLexiconURL() -> URL? {
        Bundle(for: KeyboardViewController.self)
            .url(forResource: "lokey_lexicon", withExtension: "bin")
            ?? Bundle.main.url(forResource: "lokey_lexicon", withExtension: "bin")
    }

    static func prewarmInBackground() {
        lexiconLock.lock()
        if didStartPrewarm || cachedLexicon != nil {
            lexiconLock.unlock()
            return
        }
        didStartPrewarm = true
        lexiconLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = currentLexicon()
            _ = userStore.totalPhraseCount()
        }
    }

    static func currentLexicon(
        lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) -> MmapLexicon? {
        let sig = LokeyLexiconPackManager.currentActiveSignature(in: lexiconsDirectory, defaults: defaults)
        lexiconLock.lock()
        if let cached = cachedLexicon, cachedSignature == sig {
            lexiconLock.unlock()
            return cached
        }
        lexiconLock.unlock()

        let resolved = LokeyLexiconPackManager.resolveActiveOrBuiltInLexicon(
            builtInURL: builtInLexiconURL(),
            lexiconsDirectory: lexiconsDirectory,
            defaults: defaults
        ).lexicon

        lexiconLock.lock()
        if let resolved {
            cachedLexicon = resolved
            cachedSignature = sig
        }
        lexiconLock.unlock()
        return resolved
    }

    static var lexicon: MmapLexicon? {
        currentLexicon()
    }

    static func resetForTesting() {
        lexiconLock.lock()
        cachedLexicon = nil
        cachedSignature = nil
        didStartPrewarm = false
        lexiconLock.unlock()
    }

    static let userStore = UserLexiconStore()

    private static let calibrationLock = NSLock()
    private static var cachedCalibration: LokeyTouchCalibration?
    private static var cachedCalibrationMTime: TimeInterval = -2

    static func cachedCalibrationSnapshot() -> (calibration: LokeyTouchCalibration, mtime: TimeInterval)? {
        calibrationLock.lock()
        defer { calibrationLock.unlock() }
        guard let cal = cachedCalibration else { return nil }
        return (cal, cachedCalibrationMTime)
    }

    static func loadCalibration() -> (calibration: LokeyTouchCalibration, mtime: TimeInterval) {
        let mtime = LokeyAppGroup.sharedTouchCalibrationModificationTime()
        calibrationLock.lock()
        if let hit = cachedCalibration, cachedCalibrationMTime == mtime {
            calibrationLock.unlock()
            return (hit, mtime)
        }
        calibrationLock.unlock()

        let loaded = LokeyTouchCalibration.load()
        calibrationLock.lock()
        cachedCalibration = loaded
        cachedCalibrationMTime = mtime
        calibrationLock.unlock()
        return (loaded, mtime)
    }

    static func updateCachedCalibration(_ calibration: LokeyTouchCalibration, mtime: TimeInterval) {
        calibrationLock.lock()
        cachedCalibration = calibration
        cachedCalibrationMTime = mtime
        calibrationLock.unlock()
    }
}

// MARK: - MarkedTextCoalescer (Two-Tier 120Hz ProMotion XPC Coalescing Pipeline)

/// Coordinates frame-level / runloop-turn coalescing for `textDocumentProxy.setMarkedText` XPC calls.
///
/// In-process UI (`KeyCalloutBubbleView` and `CandidateBarView`) renders synchronously at `0 ms` on `touchesBegan`.
/// Intermediate cross-process `setMarkedText` XPC calls are coalesced over an ~8 ms window (120Hz ProMotion frame),
/// eliminating main-runloop XPC stalls during 8–15 keys/sec burst typing and multi-touch rollover, while providing
/// deterministic immediate flush on all commit boundaries.
internal final class MarkedTextCoalescer {
    private var pendingMarkedText: String?
    private var pendingSelectedRange: NSRange?
    // The host may return a transient proxy. Retain it only until delivery or cancellation.
    private var pendingProxy: UITextDocumentProxy?
    private var scheduledWorkItem: DispatchWorkItem?
    private var firstPendingUptime: TimeInterval?
    private var lastDeliveryUptime = -TimeInterval.infinity
    private var lastKeyDeliveryUptime = -TimeInterval.infinity
    private var lastKeyScheduleUptime = -TimeInterval.infinity
    private var lastXPCDurationSec: TimeInterval = 0
    private var pendingKeyUptime: TimeInterval?
    private var pendingKeyTouchSeq: UInt64 = 0
    private var scheduledUptime: TimeInterval?
    private var generation: UInt64 = 0
    private(set) var lastFlushedMarkedText: String = ""
    private(set) var lastFlushedSelectedRange = NSRange(location: 0, length: 0)
    let defaultInterval: TimeInterval
    let burstInterval: TimeInterval
    let burstDetectionWindow: TimeInterval
    let burstChordWindow: TimeInterval
    let maxBatchAge: TimeInterval
    var diagnosticLogger: LokeyDiagnosticLogger = .shared

    var hasPending: Bool {
        pendingMarkedText != nil
    }

    var latestScheduledOrFlushedText: String {
        pendingMarkedText ?? lastFlushedMarkedText
    }

    var latestScheduledOrFlushedSelectedRange: NSRange {
        pendingSelectedRange ?? lastFlushedSelectedRange
    }

    /// Callback invoked whenever marked text is physically dispatched to the proxy,
    /// passing the dispatched text to keep `lastMarkedTextMutationUptime` updated.
    var onMarkedTextApplied: ((String) -> Void)?

    init(
        defaultInterval: TimeInterval = 0.008,
        burstInterval: TimeInterval = 0.0,
        burstDetectionWindow: TimeInterval = 0.055,
        burstChordWindow: TimeInterval = 0.008,
        maxBatchAge: TimeInterval = 0.048
    ) {
        self.defaultInterval = defaultInterval
        self.burstInterval = burstInterval
        self.burstDetectionWindow = burstDetectionWindow
        self.burstChordWindow = burstChordWindow
        self.maxBatchAge = maxBatchAge
    }

    /// Coalesces fresh preedit into the earliest pending delivery, bounded by `maxBatchAge`.
    /// During rapid typing bursts (`inter-key < burstDetectionWindow`), coalesces host `setMarkedText`
    /// XPC calls across `burstInterval` (with adaptive backoff when host XPC stalls) so the extension's
    /// 120Hz main RunLoop stays free to receive every overlapping `UITouch` without drops.
    func schedule(
        markedText: String,
        selectedRange: NSRange,
        proxy: UITextDocumentProxy,
        delay: TimeInterval? = nil,
        isKeyEdit: Bool = true,
        touchSeq: UInt64? = nil
    ) {
        // If `markedText` and `selectedRange` already match what is on the host proxy, cancel any unsent
        // intermediate batch and avoid an unnecessary cross-process XPC round-trip.
        if markedText == lastFlushedMarkedText && selectedRange == lastFlushedSelectedRange {
            if scheduledWorkItem != nil {
                cancel()
            }
            return
        }
        if markedText == pendingMarkedText,
           selectedRange == pendingSelectedRange,
           pendingProxy === proxy,
           delay == nil,
           scheduledWorkItem != nil {
            if isKeyEdit {
                let now = ProcessInfo.processInfo.systemUptime
                lastKeyScheduleUptime = now
                pendingKeyUptime = now
                pendingKeyTouchSeq = touchSeq ?? diagnosticLogger.currentActiveTouchSeq
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let prevKeySchedule = lastKeyScheduleUptime
        let inRapidBurst = burstInterval > 0 && (now - prevKeySchedule) < burstDetectionWindow

        if isKeyEdit {
            lastKeyScheduleUptime = now
            pendingKeyUptime = now
            pendingKeyTouchSeq = touchSeq ?? diagnosticLogger.currentActiveTouchSeq
        } else if scheduledWorkItem != nil {
            // Piggyback background syllable-spacing updates onto the already-scheduled key batch at 0 XPC cost.
            pendingMarkedText = markedText
            pendingSelectedRange = selectedRange
            pendingProxy = proxy
            return
        }

        let interval: TimeInterval
        if isKeyEdit {
            if inRapidBurst {
                let fastAsyncXPC = lastXPCDurationSec < 0.001
                let effectiveBurstFloor = fastAsyncXPC ? burstInterval : max(burstInterval, 0.032)
                let effectiveChordFloor = fastAsyncXPC ? burstChordWindow : max(burstChordWindow, 0.018)
                let adaptiveCadence = max(effectiveBurstFloor, min(0.044, lastXPCDurationSec * 2.2))
                let sinceLastKey = now - lastKeyDeliveryUptime
                interval = max(delay ?? defaultInterval, max(adaptiveCadence - sinceLastKey, effectiveChordFloor))
            } else {
                let adaptiveGap = max(1.0 / 120.0, min(0.042, lastXPCDurationSec * 2.2))
                interval = max(delay ?? defaultInterval, adaptiveGap - (now - lastKeyDeliveryUptime))
            }
        } else if burstInterval > 0 && ((now - lastKeyScheduleUptime) < burstDetectionWindow || (now - lastDeliveryUptime) < burstInterval) {
            let adaptiveSpacingGap = max(1.0 / 120.0, min(burstInterval, lastXPCDurationSec * 3.2))
            interval = max(delay ?? defaultInterval, adaptiveSpacingGap - (now - lastDeliveryUptime))
        } else {
            let lastDelivery = pendingKeyUptime != nil ? lastKeyDeliveryUptime : lastDeliveryUptime
            interval = max(delay ?? defaultInterval, 1.0 / 120.0 - (now - lastDelivery))
        }

        if firstPendingUptime == nil {
            firstPendingUptime = now
        }
        let batchAge = max(0.0, now - (firstPendingUptime ?? now))
        let effectiveDelay = min(interval, max(0.0, maxBatchAge - batchAge))

        pendingMarkedText = markedText
        pendingSelectedRange = selectedRange
        pendingProxy = proxy

        let deadline = now + effectiveDelay
        if let scheduledUptime, scheduledUptime <= deadline {
            // Keep a next-turn delivery or an earlier timer. Promote an overdue timer
            // to the main queue when the touch callback has held the run loop busy.
            if scheduledUptime == 0 || scheduledUptime > now { return }
        }

        scheduledWorkItem?.cancel()
        generation &+= 1
        let expectedGen = generation

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGen else { return }
            self.scheduledWorkItem = nil
            self.scheduledUptime = nil
            guard let proxy = self.pendingProxy,
                  let text = self.pendingMarkedText,
                  let range = self.pendingSelectedRange else { return }
            self.apply(markedText: text, selectedRange: range, proxy: proxy)
        }
        scheduledWorkItem = item

        if effectiveDelay <= 0.001 {
            scheduledUptime = 0
            DispatchQueue.main.async(execute: item)
        } else {
            scheduledUptime = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: item)
        }
    }

    /// Deterministically flushes any pending coalesced marked text mutation immediately with zero delay.
    func flushImmediately(proxy: UITextDocumentProxy) {
        generation &+= 1
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        scheduledUptime = nil
        pendingProxy = nil
        guard let text = pendingMarkedText,
              let range = pendingSelectedRange else { return }
        apply(markedText: text, selectedRange: range, proxy: proxy)
    }

    /// Cancels any scheduled mutation without pushing to the proxy.
    func cancel() {
        pendingKeyUptime = nil
        generation &+= 1
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        scheduledUptime = nil
        pendingMarkedText = nil
        pendingSelectedRange = nil
        pendingProxy = nil
        firstPendingUptime = nil
    }

    /// Clears active marked text in the host document immediately and resets coalescer state.
    func clearActiveMarkedText(proxy: UITextDocumentProxy, force: Bool = false) {
        let hadPending = (pendingMarkedText != nil)
        cancel()
        guard force || !lastFlushedMarkedText.isEmpty || hadPending else { return }
        lastFlushedMarkedText = ""
        lastFlushedSelectedRange = NSRange(location: 0, length: 0)
        let xpcStartNs = DispatchTime.now().uptimeNanoseconds
        proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        proxy.unmarkText()
        let xpcElapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- xpcStartNs) / 1_000_000.0
        lastXPCDurationSec = xpcElapsedMs / 1000.0
        lastDeliveryUptime = ProcessInfo.processInfo.systemUptime
        if xpcElapsedMs >= 5.0 {
            diagnosticLogger.recordMainThreadStall(
                touchSeq: 0,
                phase: "setMarkedText(XPC)",
                elapsedMs: xpcElapsedMs
            )
        }
        onMarkedTextApplied?("")
    }

    /// Resets recorded flushed text (e.g. after `commitTextReplacingMarkedRange` has replaced and unmarked).
    func resetFlushedMarkedText(to text: String = "", selectedRange: NSRange? = nil) {
        cancel()
        lastFlushedMarkedText = text
        lastFlushedSelectedRange = selectedRange ?? NSRange(location: text.utf16.count, length: 0)
        lastDeliveryUptime = -TimeInterval.infinity
        lastKeyDeliveryUptime = -TimeInterval.infinity
        lastKeyScheduleUptime = -TimeInterval.infinity
        lastXPCDurationSec = 0
    }

    private func apply(markedText: String, selectedRange: NSRange, proxy: UITextDocumentProxy) {
        let keyUptime = pendingKeyUptime
        let keyTouchSeq = pendingKeyTouchSeq
        pendingKeyUptime = nil
        generation &+= 1
        pendingMarkedText = nil
        pendingSelectedRange = nil
        pendingProxy = nil
        firstPendingUptime = nil
        scheduledUptime = nil
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil

        if markedText != lastFlushedMarkedText || selectedRange != lastFlushedSelectedRange {
            lastFlushedMarkedText = markedText
            lastFlushedSelectedRange = selectedRange
            let preXPCUptime = ProcessInfo.processInfo.systemUptime
            let xpcStartNs = DispatchTime.now().uptimeNanoseconds
            proxy.setMarkedText(markedText, selectedRange: selectedRange)
            let xpcElapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- xpcStartNs) / 1_000_000.0
            let postXPCUptime = ProcessInfo.processInfo.systemUptime
            lastDeliveryUptime = postXPCUptime
            if keyUptime != nil { lastKeyDeliveryUptime = postXPCUptime }
            lastXPCDurationSec = xpcElapsedMs / 1000.0
            if let keyUptime {
                let waitMs = max(0.0, (preXPCUptime - keyUptime) * 1000.0)
                if waitMs + xpcElapsedMs >= 1000.0 / 120.0 {
                    diagnosticLogger.recordPreeditDelay(touchSeq: keyTouchSeq, waitMs: waitMs, proxyMs: xpcElapsedMs)
                }
            }
            if xpcElapsedMs >= 5.0 {
                diagnosticLogger.recordMainThreadStall(
                    touchSeq: keyTouchSeq,
                    phase: "setMarkedText(XPC)",
                    elapsedMs: xpcElapsedMs
                )
            }
            onMarkedTextApplied?(markedText)
        }
    }
}

private final class WindowAttachmentObserverView: UIView {
    var onHierarchyChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onHierarchyChanged?()
        }
    }
}

private final class FallbackEmptyTextDocumentProxy: NSObject, UITextDocumentProxy {
    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    var documentContextBeforeInput: String? { nil }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { Self.zeroUUID }
    var hasText: Bool { false }
    @objc var isSecureTextEntry: Bool {
        get { false }
        set {}
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
    func insertText(_ text: String) {}
    func deleteBackward() {}
}

public final class KeyboardViewController: UIInputViewController {
    private struct PresentedCandidateItem: Equatable {
        let text: String
        let deletable: Bool
    }

    private var session: LokeySessionController?

    private let candidateBar = CandidateBarView()
    private let keyGrid = KeyGridView()
    private let expandedGrid = ExpandedCandidateGridView()
    private var emojiKeyboard: EmojiKeyboardView?
    private let calloutBubble = KeyCalloutBubbleView()
    private let windowAttachmentObserver = WindowAttachmentObserverView(frame: .zero)
    internal let diagnosticTouchSniffer = DiagnosticTouchSnifferGestureRecognizer(target: nil, action: nil)

    public override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        .all
    }

    private var heightConstraint: NSLayoutConstraint?
    private var candidateBarHeightConstraint: NSLayoutConstraint?
    private var isCandidateGridExpanded = false
    private var isEmojiKeyboardActive = false
    private var ipcTokens: [NSObjectProtocol] = []

    private static let quickNumericPunctuation: [LokeyCandidate] = [
        "，", "。", "？", "！", "、", "……"
    ].map {
        LokeyCandidate(
            text: $0,
            consumedInputCount: 0,
            matchedSyllables: [],
            scoreQ8: 0,
            kind: .lexiconPhrase
        )
    }

    private var loadingSettingsGeneration: UInt64?
    private var appearGeneration: UInt64 = 0
    private var lastCalibrationMTime: TimeInterval = -1
    private var lastSettingsGeneration: UInt64 = 0
    private var cachedHasFullAccess: Bool = false
    private var currentIdleCandidates: [LokeyCandidate] = []
    private var isShowingQuickPunctuationStrip = false
    private var contextTracker = DocumentContextTracker()
    private var contextReconcileWorkItem: DispatchWorkItem?
    internal let markedTextCoalescer = MarkedTextCoalescer(
        defaultInterval: 0,
        burstInterval: 0.016,
        burstDetectionWindow: 0.055,
        burstChordWindow: 0.008,
        maxBatchAge: 0.038
    )
    private var lastMarkedTextSent: String = ""
    private var lastMarkedTextMutationUptime: TimeInterval = 0
    private var lastPartialCommitUptime: TimeInterval = -10
    private var lastUserInteractionUptime: TimeInterval = -10
    private var lastGestureAuditBoundsSize: CGSize = .zero
    private var lastGestureAuditWindowGRCount: Int = -1
    private var lastGestureAuditAncestorGRCount: Int = -1
    private var lastDisarmedWindowID: ObjectIdentifier?
    private var lastPresentedCandidateSignature: [PresentedCandidateItem] = []
    private var lastPresentedHighlightFirst: Bool = false
    private var lastPresentedExpanded: Bool = false
    private var lastPresentedShowsAccessory: Bool = true
    private var hasValidPresentedCandidateSignature: Bool = false
    private var cachedExternalHostTopPadding: CGFloat?
    private var activeDocumentID: UUID?
    private var activeDocumentGeneration: UInt64 = 0
    private var pendingDocumentEdits: [(docGen: UInt64, isUnmarkCommit: Bool, edit: (UITextDocumentProxy) -> Void)] = []
    private var documentEditDelivery: DispatchWorkItem?
    private var candidateRefreshPending = false
    private var hasDeferredProvisionalRender = false
    private var candidateRefreshWorkItem: DispatchWorkItem?
    private var candidatePresentationPassCount: UInt64 = 0
    private var composingContextAnchor: String = ""
    private var cachedEnablesReturnKeyAutomatically: Bool = false
    private var cachedDocumentHasExternalText: Bool = false
    private var cachedNeedsGlobeKey: Bool = false
    private var hasSyncedGlobeKey: Bool = false
    private var hasSyncedTraitsForActiveDocument: Bool = false
    private var hasAppearedInHost: Bool = false
    private var pendingSelfEchoCount: Int = 0
    private var pendingSelfEchoMaySwitchField: Bool = false
    private var lastSelfHostWriteUptime: TimeInterval = -10
    private var lastTextWillChangeUptime: TimeInterval = -10
    private var pendingGlobeSwitchDeparture: Bool = false
    private var isDisappearing: Bool = false
    private var lastGlobeInteractionUptime: TimeInterval = -10
    private var didReceiveHostResignOrBackground: Bool = false
    private var lastActiveDisappearUptime: TimeInterval = -10
    private var wasVisibleBeforeDisappear: Bool = false
    private var lastLoggedGeometrySignature: GeometrySignature?
    private var lastNotifiedHostHeightMismatchSignature: String = ""
    private var isHostResizeRetryScheduled: Bool = false
    private var lastObservedScreenObjectID: ObjectIdentifier?
    private var lastObservedScreenSize: CGSize = .zero
    private var isWindowMoveFollowUpScheduled: Bool = false
    private var hasFoldedFromUnfoldedToDuoCover: Bool = false
    private var duoCoverGlobeFallbackTimer: Timer?
    private var didAdvanceInputModeForCurrentGlobeTouch: Bool = false
    private lazy var caretFeedback = UISelectionFeedbackGenerator()

    private static let systemLayoutStateLock = NSLock()
    private static var _didActivateSystemKeyboardLayoutInProcess: Bool = false
    private static var _lastControllerAppearOrLoadUptime: TimeInterval = -10
    private static var _hasObservedUnfoldedDuoInProcess: Bool = false
    internal static var didActivateSystemKeyboardLayoutInProcess: Bool {
        get {
            systemLayoutStateLock.lock()
            defer { systemLayoutStateLock.unlock() }
            return _didActivateSystemKeyboardLayoutInProcess
        }
        set {
            systemLayoutStateLock.lock()
            _didActivateSystemKeyboardLayoutInProcess = newValue
            systemLayoutStateLock.unlock()
        }
    }
    internal static var lastControllerAppearOrLoadUptime: TimeInterval {
        get {
            systemLayoutStateLock.lock()
            defer { systemLayoutStateLock.unlock() }
            return _lastControllerAppearOrLoadUptime
        }
        set {
            systemLayoutStateLock.lock()
            _lastControllerAppearOrLoadUptime = newValue
            systemLayoutStateLock.unlock()
        }
    }
    internal static var hasObservedUnfoldedDuoInProcess: Bool {
        get {
            systemLayoutStateLock.lock()
            defer { systemLayoutStateLock.unlock() }
            return _hasObservedUnfoldedDuoInProcess
        }
        set {
            systemLayoutStateLock.lock()
            _hasObservedUnfoldedDuoInProcess = newValue
            systemLayoutStateLock.unlock()
        }
    }

    internal var overrideHostTopPaddingForTesting: CGFloat?
    internal var overrideScreenSizeForTesting: CGSize?
    internal var overrideShowStarterCandidatesForTesting: Bool = false
    internal var customTextDocumentProxyForTesting: UITextDocumentProxy?
    internal var onHostInputViewLayoutInvalidatedForTesting: (() -> Void)?
    internal var onAdvanceToNextInputModeForTesting: (() -> Void)?
    internal var onSuperHandleInputModeListForTesting: ((UIView, UIEvent) -> Void)?
    internal var activeDecoderLexiconForTesting: MmapLexicon? { session?.decoder.lexicon }
    internal var activeSessionForTesting: LokeySessionController? { session }
    internal var isBaseLexiconReloadPendingForTesting: Bool { pendingBaseLexiconReload }
    internal static func resetSharedLexiconCacheForTesting() {
        SharedLexiconHolder.resetForTesting()
    }
    private var activeLexiconObjectID: ObjectIdentifier?
    private var pendingBaseLexiconReload: Bool = false
    private var pendingBaseLexiconReloadDir: URL?
    private var pendingBaseLexiconReloadDefaults: UserDefaults?
    private var cachedSupplementaryEntries: [(String, String)] = []
    private var lastSupplementaryRefreshUptime: TimeInterval = -100
    private static let extensionStateIOQueue = DispatchQueue(label: "com.kianuni.lokey.extStateIO", qos: .userInitiated)

    private var isRunningInExtensionProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            SharedLexiconHolder.prewarmInBackground()
        }
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public required init?(coder: NSCoder) {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            SharedLexiconHolder.prewarmInBackground()
        }
        super.init(coder: coder)
    }
    private static let superTextDocumentProxySelector = #selector(getter: UIInputViewController.textDocumentProxy)
    private static let fallbackEmptyTextDocumentProxy = FallbackEmptyTextDocumentProxy()

    /// Reads `UIInputViewController.textDocumentProxy` via Objective-C IMP dispatch so a transient `nil` (`0x0`)
    /// `_textDocumentInterface` during foldable display migration (`LCD-1 -> LCD`) never triggers Swift's fatal
    /// non-optional bridging `SIGTRAP`.
    private func safeSuperTextDocumentProxy() -> UITextDocumentProxy {
        typealias GetterIMP = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        guard let imp = class_getMethodImplementation(UIInputViewController.self, Self.superTextDocumentProxySelector) else {
            return Self.fallbackEmptyTextDocumentProxy
        }
        let fn = unsafeBitCast(imp, to: GetterIMP.self)
        guard let rawPtr = fn(self, Self.superTextDocumentProxySelector) else {
            return Self.fallbackEmptyTextDocumentProxy
        }
        return (Unmanaged<AnyObject>.fromOpaque(rawPtr).takeUnretainedValue() as? UITextDocumentProxy)
            ?? Self.fallbackEmptyTextDocumentProxy
    }

    public override var textDocumentProxy: UITextDocumentProxy {
        if let custom = customTextDocumentProxyForTesting {
            return custom
        }
        return safeSuperTextDocumentProxy()
    }

    deinit {
        cancelDuoCoverGlobeFallbackTimer()
        keyGrid.globeSwitchButton.removeTarget(self, action: nil, for: .allEvents)
        candidateRefreshWorkItem?.cancel()
        contextReconcileWorkItem?.cancel()
        markedTextCoalescer.cancel()
        for tok in ipcTokens {
            NotificationCenter.default.removeObserver(tok)
        }
    }

    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        CandidateBarView.clearCachesForMemoryWarning()
        KeyCalloutBubbleView.clearCachesForMemoryWarning()
        KeyboardTheme.clearCachesForMemoryWarning()
        KeyGridView.clearSymbolCacheForMemoryWarning()
        calloutBubble.clearCachedPathStateIfHidden()
        if !isCandidateGridExpanded && !expandedGrid.hasActiveInteraction {
            expandedGrid.releasePoolIfHidden()
        }
        if !candidateBar.hasActiveTouch && session?.isComposing != true {
            candidateBar.trimUnusedPoolIfIdle()
        }
        if !isEmojiKeyboardActive, let emoji = emojiKeyboard {
            emoji.cancelActiveInteractions()
            emoji.removeFromSuperview()
            emojiKeyboard = nil
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Keep root view completely transparent so iOS renders its authentic system Liquid Glass capsule underneath!
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.isMultipleTouchEnabled = true
        view.isExclusiveTouch = false
        inputView?.backgroundColor = .clear
        inputView?.clipsToBounds = false
        inputView?.isMultipleTouchEnabled = true
        inputView?.isExclusiveTouch = false
        if isRunningInExtensionProcess {
            inputView?.allowsSelfSizing = true
            Self.lastControllerAppearOrLoadUptime = ProcessInfo.processInfo.systemUptime
        }

        let canQueryHostXPCOnLoad = !isRunningInExtensionProcess || customTextDocumentProxyForTesting != nil
        if canQueryHostXPCOnLoad {
            cachedHasFullAccess = hasFullAccess
            let shortVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
            if cachedHasFullAccess {
                DispatchQueue.global(qos: .utility).async {
                    LokeyAppGroup.writeExtensionHeartbeat(hasFullAccess: true, bundleVersion: shortVer)
                }
            }
        }
        if !isRunningInExtensionProcess {
            LokeyDiagnosticLogger.shared.bootstrapFromDiskAsync()
            LokeySelectionFeedbackLogger.shared.bootstrapFromDiskAsync()
        }
        refreshCachedHostTopPadding()
        setupHierarchy()
        let initialSettings = setupEngine(
            refreshCalibration: !isRunningInExtensionProcess,
            requestSupplementary: !isRunningInExtensionProcess
        )
        setupDiagnosticTouchSniffer()
        wireCallbacks()
        markedTextCoalescer.onMarkedTextApplied = { [weak self] appliedText in
            guard let self else { return }
            self.lastMarkedTextSent = appliedText
            let now = ProcessInfo.processInfo.systemUptime
            self.lastMarkedTextMutationUptime = now
            self.noteSelfHostWrite(at: now)
        }
        keyGrid.hasFullAccessProvider = { [weak self] in
            self?.cachedHasFullAccess ?? false
        }
        observeAppGroupUpdates()
        reloadPreferencesFromAppGroup(
            refreshFullAccess: false,
            preloadedSettings: initialSettings,
            refreshCalibration: !isRunningInExtensionProcess
        )
        if isRunningInExtensionProcess {
            DispatchQueue.main.async { [weak self] in
                LokeyDiagnosticLogger.shared.bootstrapFromDiskAsync()
                LokeySelectionFeedbackLogger.shared.bootstrapFromDiskAsync()
                self?.refreshCalibrationFromDiskAsync()
                self?.refreshSupplementaryLexiconIfNeeded(force: true)
            }
        }
        composingContextAnchor = ""
        if canQueryHostXPCOnLoad {
            activeDocumentID = currentDocumentIdentifier()
            let initialBefore = textDocumentProxy.documentContextBeforeInput
            contextTracker.reset(proxyBefore: initialBefore)
            syncDocumentTraits(knownBefore: initialBefore)
        } else {
            setSecureContext(true)
            contextTracker.reset(proxyBefore: nil)
        }
        refreshCandidateUI()
        disableSystemGestureTouchDelays()
    }

    private func publishExtensionVisibility(isVisible: Bool) {
        guard cachedHasFullAccess else { return }
        let emojiActive = isVisible ? isEmojiKeyboardActive : false
        let topPad = isVisible ? Double(effectiveHostTopPadding()) : 0.0
        let reqH = isVisible ? Double(desiredKeyboardHeight()) : 0.0
        Self.extensionStateIOQueue.async {
            LokeyAppGroup.writeExtensionVisibility(
                isVisible: isVisible,
                isEmojiActive: emojiActive,
                appliedTopPadding: topPad,
                requestedHeight: reqH
            )
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDisappearing = false
        cancelDuoCoverGlobeFallbackTimer()
        didAdvanceInputModeForCurrentGlobeTouch = false
        observeDuoScreenProfileIfNeeded()
        appearGeneration &+= 1
        if isRunningInExtensionProcess {
            Self.lastControllerAppearOrLoadUptime = ProcessInfo.processInfo.systemUptime
        }
        cancelPendingDocumentEdits()
        activeDocumentGeneration &+= 1
        clearPendingSelfEcho()
        hasAppearedInHost = true
        lastNotifiedHostHeightMismatchSignature = ""
        pendingGlobeSwitchDeparture = false
        didReceiveHostResignOrBackground = false
        wasVisibleBeforeDisappear = false
        lastActiveDisappearUptime = -10
        cachedHasFullAccess = hasFullAccess
        refreshCachedHostTopPadding()
        updateKeyboardHeightConstraint(forceHostLayoutNotify: true)
        if cachedHasFullAccess {
            let shortVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
            publishExtensionVisibility(isVisible: true)
            Self.extensionStateIOQueue.async {
                LokeyAppGroup.writeExtensionHeartbeat(hasFullAccess: true, bundleVersion: shortVer)
            }
            LokeyDiagnosticLogger.shared.syncExternalClearAsync()
            LokeySelectionFeedbackLogger.shared.syncExternalClearAsync()
        }
        cachedNeedsGlobeKey = needsInputModeSwitchKey
        hasSyncedGlobeKey = true
        keyGrid.needsGlobeKey = cachedNeedsGlobeKey
        keyGrid.hasFullAccess = cachedHasFullAccess
        contextReconcileWorkItem?.cancel()
        markedTextCoalescer.cancel()
        lastMarkedTextSent = ""
        markedTextCoalescer.resetFlushedMarkedText(to: "")
        hasSyncedTraitsForActiveDocument = false
        activeDocumentID = currentDocumentIdentifier()
        composingContextAnchor = ""
        let appearBefore = textDocumentProxy.documentContextBeforeInput
        contextTracker.reset(proxyBefore: appearBefore)
        session?.resetTopicMemory()
        session?.notifyContextBreak()
        reloadPreferencesFromAppGroup(refreshFullAccess: false)
        reloadBaseLexiconIfNeeded()
        refreshSupplementaryLexiconIfNeeded()
        SharedLexiconHolder.userStore.reloadFromDiskAsyncIfExternal { [weak self] in
            guard let self, !self.candidateBar.hasActiveTouch else { return }
            self.refreshCandidateUI()
        }
        syncDocumentTraits(knownBefore: appearBefore)
        hasValidPresentedCandidateSignature = false
        refreshCandidateUI()
        disableSystemGestureTouchDelays()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isDisappearing = false
        observeDuoScreenProfileIfNeeded()
        reconcileDisplayTransitionIfNeeded()
        if hasAppearedInHost || view.window != nil {
            syncNeedsGlobeKeyIfConnected()
        }
        updateKeyboardHeightConstraint(forceHostLayoutNotify: false)
        disableSystemGestureTouchDelays()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        keyGrid.prepareHaptics()
        recordLiveGeometryIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.hasAppearedInHost,
                  !self.keyGrid.hasActiveTouches,
                  !self.candidateBar.hasActiveTouch else { return }
            self.expandedGrid.prewarmPoolIncrementallyIfNeeded(batchSize: 14) { [weak self] in
                guard let self else { return false }
                return self.hasAppearedInHost
                    && !self.keyGrid.hasActiveTouches
                    && !self.candidateBar.hasActiveTouch
                    && self.expandedGrid.isHidden
            }
            self.keyGrid.prewarmCalloutIfNeeded()
        }
    }

    internal func disableSystemGestureTouchDelays() {
        var ancestorGRCount = 0
        var cur: UIView? = view
        while let v = cur {
            if let grs = v.gestureRecognizers {
                ancestorGRCount &+= grs.count
                for gr in grs {
                    Self.disarmTouchDelaysIfSupported(gr)
                }
            }
            cur = v.superview
        }
        if let win = view.window {
            lastDisarmedWindowID = ObjectIdentifier(win)
            let winGRs = win.gestureRecognizers ?? []
            lastGestureAuditWindowGRCount = winGRs.count
            for gr in winGRs {
                Self.disarmTouchDelaysIfSupported(gr)
            }
        } else {
            lastDisarmedWindowID = nil
            lastGestureAuditWindowGRCount = 0
        }
        lastGestureAuditAncestorGRCount = ancestorGRCount
    }

    @inline(__always)
    private static func disarmTouchDelaysIfSupported(_ gr: UIGestureRecognizer) {
        guard gr.delaysTouchesBegan || gr.delaysTouchesEnded else { return }
        if NSStringFromClass(type(of: gr)).contains("SystemGestureGate") {
            return
        }
        if gr.delaysTouchesBegan { gr.delaysTouchesBegan = false }
        if gr.delaysTouchesEnded { gr.delaysTouchesEnded = false }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        isDisappearing = true
        cancelDuoCoverGlobeFallbackTimer()
        didAdvanceInputModeForCurrentGlobeTouch = false
        deliverPendingDocumentEdits()
        super.viewWillDisappear(animated)
        if isCandidateGridExpanded {
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .staticText("展开面板随键盘离开宿主"))
            setExpandedGrid(false, reason: "键盘离开宿主")
        }
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        candidateRefreshPending = false
        hasDeferredProvisionalRender = false
        hasAppearedInHost = false
        hasSyncedGlobeKey = false
        clearPendingSelfEcho()
        cachedExternalHostTopPadding = nil
        lastNotifiedHostHeightMismatchSignature = ""
        lastActiveDisappearUptime = -10
        wasVisibleBeforeDisappear = false
        pendingGlobeSwitchDeparture = false
        publishExtensionVisibility(isVisible: false)
        contextReconcileWorkItem?.cancel()
        markedTextCoalescer.cancel()
        diagnosticTouchSniffer.resetTrackedTouches()
        candidateBar.resetTouchTracking()
        keyGrid.resetTransientInteractions()
        emojiKeyboard?.cancelActiveInteractions()
        if isEmojiKeyboardActive {
            setEmojiKeyboardVisible(false, performLayout: false)
        }
        if keyGrid.page != .alphabetic {
            keyGrid.page = .alphabetic
        }
        if session?.isComposing == true {
            session?.resetComposing()
            clearActiveMarkedTextIfNeeded()
        }
        hasSyncedTraitsForActiveDocument = false
        activeDocumentID = nil
        activeDocumentGeneration &+= 1
        composingContextAnchor = ""
        contextTracker.reset(proxyBefore: nil)
        session?.resetTopicMemory()
        session?.notifyContextBreak()
        session?.decoder.spatialModel.flushCalibrationToDiskIfNeeded(force: true)
        LokeyDiagnosticLogger.shared.flushAsync()
        LokeySelectionFeedbackLogger.shared.flushAsync()
        if let cal = session?.decoder.spatialModel.calibration {
            let disappearAppearGen = appearGeneration
            SharedLexiconHolder.updateCachedCalibration(cal, mtime: -1)
            Self.extensionStateIOQueue.async { [weak self] in
                let calMTime = LokeyAppGroup.sharedTouchCalibrationModificationTime()
                SharedLexiconHolder.updateCachedCalibration(cal, mtime: calMTime)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.appearGeneration == disappearAppearGen else { return }
                    self.lastCalibrationMTime = calMTime
                }
            }
        }
        hasValidPresentedCandidateSignature = false
        refreshCandidateUI()
        LokeyHapticEngine.shared.suspend()
    }

    private func cancelDuoCoverGlobeFallbackTimer() {
        duoCoverGlobeFallbackTimer?.invalidate()
        duoCoverGlobeFallbackTimer = nil
    }

    private func observeDuoScreenProfileIfNeeded() {
        let scr = effectiveScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        let profile = KeyboardTheme.layoutProfile(forWidth: refWidth, screenSize: scr)
        if profile == .duoUnfoldedPortrait || profile == .duoUnfoldedLandscape || min(scr.width, scr.height) > 550.0 {
            Self.hasObservedUnfoldedDuoInProcess = true
            hasFoldedFromUnfoldedToDuoCover = false
        }
    }

    /// Returns `true` when running on `iPhone Duo` Outer Cover **after** the extension has observed an
    /// unfolded inner display (`LCD-1 -> LCD`). On `iPhone OS 27.2.1 (24B91034)`, calling
    /// `UIInputViewController.handleInputModeList(from:with:)` on long-press triggers an Apple `UIKitCore`
    /// use-after-free in `-[UIKeyboardMenuView supplementalVisibleFramesInView:]` (`objc_retain` on a freed
    /// `UIInputSwitcherView.referenceKey`), crashing the host app. Bypassing the HUD menu with public
    /// `advanceToNextInputMode()` completely prevents the host crash while preserving full long-press menus
    /// on regular iPhones, Unfolded `iPhone Duo`, and fresh Cover sessions.
    internal func shouldBypassInputModeListHUDForDuoFold() -> Bool {
        let scr = effectiveScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        let profile = KeyboardTheme.layoutProfile(forWidth: refWidth, screenSize: scr)
        guard profile == .duoCover else {
            return false
        }
        return hasFoldedFromUnfoldedToDuoCover || Self.hasObservedUnfoldedDuoInProcess
    }

    private func reconcileDisplayTransitionIfNeeded() {
        let currentScreenID: ObjectIdentifier? = view.window?.windowScene.map { ObjectIdentifier($0.screen) }
        let currentScreenSize = effectiveScreenSize()

        let screenIDChanged = (lastObservedScreenObjectID != nil
            && currentScreenID != nil
            && lastObservedScreenObjectID != currentScreenID)
        let screenSizeChanged = (lastObservedScreenSize.width > 0.0
            && currentScreenSize.width > 0.0
            && (abs(lastObservedScreenSize.width - currentScreenSize.width) > 1.0
                || abs(lastObservedScreenSize.height - currentScreenSize.height) > 1.0))

        let wasFoldableUnfolded = min(lastObservedScreenSize.width, lastObservedScreenSize.height) > 550.0
        let isFoldableUnfolded = min(currentScreenSize.width, currentScreenSize.height) > 550.0
        let didCrossFoldState = (lastObservedScreenSize.width > 0.0
            && currentScreenSize.width > 0.0
            && wasFoldableUnfolded != isFoldableUnfolded)
            || screenIDChanged

        if isFoldableUnfolded {
            Self.hasObservedUnfoldedDuoInProcess = true
            hasFoldedFromUnfoldedToDuoCover = false
        } else if lastObservedScreenSize.width > 0.0 && wasFoldableUnfolded && !isFoldableUnfolded {
            Self.hasObservedUnfoldedDuoInProcess = true
            hasFoldedFromUnfoldedToDuoCover = true
        }

        if let currentScreenID {
            lastObservedScreenObjectID = currentScreenID
        }
        if currentScreenSize.width > 0.0, currentScreenSize.height > 0.0 {
            lastObservedScreenSize = currentScreenSize
        }

        guard screenIDChanged || screenSizeChanged else { return }

        cancelDuoCoverGlobeFallbackTimer()
        didAdvanceInputModeForCurrentGlobeTouch = false
        diagnosticTouchSniffer.resetTrackedTouches()
        candidateBar.resetTouchTracking()
        keyGrid.resetTransientInteractions()
        emojiKeyboard?.cancelActiveInteractions()
        calloutBubble.hide()

        if didCrossFoldState && isCandidateGridExpanded {
            setExpandedGrid(false, reason: "屏幕折叠切换")
        }

        lastNotifiedHostHeightMismatchSignature = ""
        hasSyncedGlobeKey = false
        if hasAppearedInHost || view.window != nil || customTextDocumentProxyForTesting != nil {
            syncNeedsGlobeKeyIfConnected()
        }
        if didCrossFoldState {
            LokeyHapticEngine.shared.resetForDisplayTransition()
        }
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.reconcileDisplayTransitionIfNeeded()
            _ = self.syncChildHostScreenSize()
            self.updateKeyboardHeightConstraint(forceHostLayoutNotify: true)
            self.candidateBar.setNeedsLayout()
            self.keyGrid.setNeedsLayout()
            self.emojiKeyboard?.setNeedsLayout()
            self.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.reconcileDisplayTransitionIfNeeded()
            _ = self.syncChildHostScreenSize()
            if self.hasAppearedInHost || self.view.window != nil {
                self.syncNeedsGlobeKeyIfConnected()
            }
            self.updateKeyboardHeightConstraint(forceHostLayoutNotify: true)
            self.candidateBar.setNeedsLayout()
            self.keyGrid.setNeedsLayout()
            self.emojiKeyboard?.setNeedsLayout()
            self.view.layoutIfNeeded()
        })
    }

    private func syncNeedsGlobeKeyIfConnected() {
        let liveNeedsGlobe = needsInputModeSwitchKey
        if !hasSyncedGlobeKey || cachedNeedsGlobeKey != liveNeedsGlobe {
            cachedNeedsGlobeKey = liveNeedsGlobe
            hasSyncedGlobeKey = true
            if keyGrid.needsGlobeKey != liveNeedsGlobe {
                keyGrid.needsGlobeKey = liveNeedsGlobe
            }
        }
    }

    public override func viewWillLayoutSubviews() {
        observeDuoScreenProfileIfNeeded()
        reconcileDisplayTransitionIfNeeded()
        super.viewWillLayoutSubviews()
        if view.bounds.height <= 420.0 {
            updateKeyboardHeightConstraint(inLayoutPass: true)
        } else {
            _ = syncChildHostScreenSize()
        }
        let scr = effectiveScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        session?.decoder.spatialModel.isLandscapeLayout = (refWidth > 520.0)
        if !hasSyncedGlobeKey && (hasAppearedInHost || view.window != nil || customTextDocumentProxyForTesting != nil) {
            syncNeedsGlobeKeyIfConnected()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let currentWinID = view.window.map { ObjectIdentifier($0) }
        let winGRCount = view.window?.gestureRecognizers?.count ?? 0
        var ancestorGRCount = 0
        var cur: UIView? = view
        while let v = cur {
            ancestorGRCount &+= (v.gestureRecognizers?.count ?? 0)
            cur = v.superview
        }
        if view.bounds.size != lastGestureAuditBoundsSize
            || currentWinID != lastDisarmedWindowID
            || winGRCount != lastGestureAuditWindowGRCount
            || ancestorGRCount != lastGestureAuditAncestorGRCount {
            lastGestureAuditBoundsSize = view.bounds.size
            disableSystemGestureTouchDelays()
        }
        // Skip bogus transient fullscreen snapshot passes (`440x956` before clamping inputView to `197.5..268.5pt`).
        if hasAppearedInHost && view.bounds.height <= 420.0 {
            recordLiveGeometryIfNeeded()
        }
    }

    @inline(__always)
    private func clearPendingSelfEcho() {
        pendingSelfEchoCount = 0
        pendingSelfEchoMaySwitchField = false
    }

    @inline(__always)
    private func noteSelfHostWrite(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        count: Int = 1,
        mayTriggerFocusTransition: Bool = false
    ) {
        pendingSelfEchoCount = min(pendingSelfEchoCount + count, 4)
        if mayTriggerFocusTransition {
            pendingSelfEchoMaySwitchField = true
        }
        lastSelfHostWriteUptime = now
    }

    private func shouldSuppressHostChangeEcho(at now: TimeInterval) -> Bool {
        if session?.isComposing == true {
            let elapsedMarked = now - lastMarkedTextMutationUptime
            let elapsedPartial = now - lastPartialCommitUptime
            if markedTextCoalescer.hasPending
                || (elapsedMarked >= 0 && elapsedMarked <= 0.55)
                || (elapsedPartial >= 0 && elapsedPartial <= 0.55) {
                return true
            }
        }
        if pendingSelfEchoCount > 0 {
            let maxWindow = max(DocumentContextTracker.optimisticWindowSeconds, 0.38)
            let elapsedWrite = now - lastSelfHostWriteUptime
            if elapsedWrite >= 0 && elapsedWrite <= maxWindow {
                return true
            }
        }
        if contextTracker.optimisticOverride != nil {
            let elapsedSelfEdit = now - contextTracker.lastEditUptime
            if elapsedSelfEdit >= 0 && elapsedSelfEdit <= DocumentContextTracker.optimisticWindowSeconds {
                return true
            }
        }
        return false
    }

    public override func selectionWillChange(_ textInput: UITextInput?) {
        let now = ProcessInfo.processInfo.systemUptime
        if session?.isComposing == true
            || markedTextCoalescer.hasPending
            || pendingSelfEchoCount > 0
            || shouldSuppressHostChangeEcho(at: now) {
            return
        }
        super.selectionWillChange(textInput)
    }

    public override func selectionDidChange(_ textInput: UITextInput?) {
        let now = ProcessInfo.processInfo.systemUptime
        if session?.isComposing == true
            || markedTextCoalescer.hasPending
            || pendingSelfEchoCount > 0
            || shouldSuppressHostChangeEcho(at: now) {
            return
        }
        super.selectionDidChange(textInput)
        contextTracker.recordCursorMove()
        scheduleContextReconciliation(generation: contextTracker.editGeneration, delay: 0.08)
    }

    public override func textWillChange(_ textInput: UITextInput?) {
        let now = ProcessInfo.processInfo.systemUptime
        lastTextWillChangeUptime = now
        if shouldSuppressHostChangeEcho(at: now) {
            return
        }
        super.textWillChange(textInput)
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        guard hasAppearedInHost || !isRunningInExtensionProcess || customTextDocumentProxyForTesting != nil else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let priorWillChange = lastTextWillChangeUptime
        lastTextWillChangeUptime = -10
        let maxEchoAge: TimeInterval = (session?.isComposing == true)
            ? 0.55
            : (pendingSelfEchoCount > 0
                ? max(DocumentContextTracker.optimisticWindowSeconds, 0.38)
                : DocumentContextTracker.optimisticWindowSeconds)
        // Real iOS UIKit self-echoes pair `_willChangeText` -> `_didChangeText` right after
        // our own `setMarkedText` / `insertText` / `deleteBackward` XPC writes (with up to ~100ms WebKit DOM layout
        // between will/did). Suppress synchronous `documentIdentifier` and `isSecureTextEntry` XPC round-trips
        // on paired self-echoes while allowing standalone `textDidChange` responder/secure transitions immediately.
        if pendingSelfEchoCount > 0,
           (now - priorWillChange) >= 0,
           (now - priorWillChange) <= 0.12,
           (now - lastSelfHostWriteUptime) >= 0,
           (now - lastSelfHostWriteUptime) <= maxEchoAge,
           shouldSuppressHostChangeEcho(at: now) {
            if pendingSelfEchoMaySwitchField {
                let currentDocID = currentDocumentIdentifier()
                let didSwitchDoc = didSwitchDocumentIdentifier(to: currentDocID)
                let secure = textDocumentProxy.isSecureTextEntry == true
                if !didSwitchDoc && secure == session?.isSecureContext {
                    pendingSelfEchoCount -= 1
                    if pendingSelfEchoCount == 0 {
                        pendingSelfEchoMaySwitchField = false
                    }
                    return
                }
            } else {
                pendingSelfEchoCount -= 1
                return
            }
        }
        let currentDocID = currentDocumentIdentifier()
        let didSwitchDoc = didSwitchDocumentIdentifier(to: currentDocID)
        let secure = textDocumentProxy.isSecureTextEntry == true
        if didSwitchDoc || secure != session?.isSecureContext {
            // A delayed echo from the previous field must never publish its pending text in the new one.
            cancelPendingDocumentEdits()
            activeDocumentGeneration &+= 1
            clearPendingSelfEcho()
            contextReconcileWorkItem?.cancel()
            markedTextCoalescer.cancel()
            markedTextCoalescer.resetFlushedMarkedText()
            lastMarkedTextSent = ""
            composingContextAnchor = ""
            contextTracker.reset(proxyBefore: nil)
            session?.resetComposing()
            session?.resetTopicMemory()
            session?.notifyContextBreak()
            candidateBar.resetTouchTracking()
            keyGrid.resetTransientInteractions()
            if didSwitchDoc { hasSyncedTraitsForActiveDocument = false }
            flushPendingBaseLexiconReloadIfNeeded()
        }
        if let currentDocID {
            activeDocumentID = currentDocID
        } else if didSwitchDoc {
            activeDocumentID = nil
        }
        setSecureContext(secure)

        if session?.isComposing == true {
            // Fast-path: `setMarkedText` and partial `commitTextReplacingMarkedRange` trigger async `textDidChange`
            // echoes 1–3 frames later. Skip synchronous cross-process `textDocumentProxy` & `super.textDidChange` XPC calls
            // during our own active mutation window so WebKit / SwiftUI host layout never stalls incoming thumb taps!
            let elapsedMarked = now - lastMarkedTextMutationUptime
            let elapsedPartial = now - lastPartialCommitUptime
            if markedTextCoalescer.hasPending
                || (elapsedMarked >= 0 && elapsedMarked <= 0.55)
                || (elapsedPartial >= 0 && elapsedPartial <= 0.55) {
                return
            }
            let xpcStartNs = DispatchTime.now().uptimeNanoseconds
            super.textDidChange(textInput)

            let liveBefore = textDocumentProxy.documentContextBeforeInput
            let shouldReset = DocumentContextTracker.shouldResetComposingOnExternalChange(
                didSwitchDocument: didSwitchDoc,
                hasText: textDocumentProxy.hasText,
                proxyBefore: liveBefore,
                composingAnchor: composingContextAnchor,
                elapsedSinceMarkedMutation: elapsedMarked,
                hasPendingOptimisticBridge: contextTracker.optimisticOverride != nil,
                preEditProxySuffix: contextTracker.preEditProxySuffix,
                activeMarkedText: lastMarkedTextSent,
                elapsedSincePartialCommit: elapsedPartial
            )
            if shouldReset {
                markedTextCoalescer.cancel()
                if !didSwitchDoc && !lastMarkedTextSent.isEmpty {
                    clearActiveMarkedTextIfNeeded()
                } else {
                    lastMarkedTextSent = ""
                    markedTextCoalescer.resetFlushedMarkedText(to: "")
                }
                session?.resetComposing()
                composingContextAnchor = ""
                flushPendingBaseLexiconReloadIfNeeded()
            } else {
                let xpcMs = Double(DispatchTime.now().uptimeNanoseconds &- xpcStartNs) / 1_000_000.0
                if xpcMs >= 5.0 {
                    LokeyDiagnosticLogger.shared.recordMainThreadStall(
                        touchSeq: 0,
                        phase: "textDidChange(composingXPC)",
                        elapsedMs: xpcMs
                    )
                }
                return
            }
        }

        // Skip synchronous XPC re-queries on self-edit echoes (`<= optimisticWindowSeconds` after `insertText` / `unmarkText` / `deleteBackward`),
        // since UI was already refreshed optimistically in RAM and `scheduleContextReconciliation` verifies asynchronously.
        let elapsedSelfEdit = now - contextTracker.lastEditUptime
        if contextTracker.optimisticOverride != nil
            && elapsedSelfEdit >= 0
            && elapsedSelfEdit <= DocumentContextTracker.optimisticWindowSeconds {
            return
        }
        let xpcStartNs = DispatchTime.now().uptimeNanoseconds
        super.textDidChange(textInput)


        let liveBefore = textDocumentProxy.documentContextBeforeInput
        let isComposing = (session?.isComposing == true)
        let (didBreak, gen) = contextTracker.handleExternalTextDidChange(
            proxyBefore: liveBefore,
            isComposing: isComposing
        )
        if didBreak || didSwitchDoc {
            if didSwitchDoc {
                session?.resetTopicMemory()
            }
            session?.notifyContextBreak()
        }
        if !isComposing {
            scheduleContextReconciliation(generation: gen, delay: 0.18)
            if didSwitchDoc || !hasSyncedTraitsForActiveDocument {
                syncDocumentTraits(knownBefore: liveBefore, knownIsSecure: secure)
            } else {
                let proxy = textDocumentProxy
                let beforeEmpty = (liveBefore ?? "").isEmpty
                if cachedEnablesReturnKeyAutomatically {
                    cachedDocumentHasExternalText = beforeEmpty ? proxy.hasText : true
                } else {
                    cachedDocumentHasExternalText = false
                }
                syncModeUI()
            }
            if !candidateBar.hasActiveTouch {
                refreshCandidateUI()
            }
            flushPendingBaseLexiconReloadIfNeeded()
        }
        let xpcMs = Double(DispatchTime.now().uptimeNanoseconds &- xpcStartNs) / 1_000_000.0
        if xpcMs >= 5.0 {
            LokeyDiagnosticLogger.shared.recordMainThreadStall(
                touchSeq: 0,
                phase: "textDidChange(XPC)",
                elapsedMs: xpcMs
            )
        }
    }

    // MARK: - Setup

    @discardableResult
    private func setupEngine(
        lexiconOverride: MmapLexicon? = nil,
        refreshCalibration: Bool = true,
        requestSupplementary: Bool = true
    ) -> LokeySettings? {
        guard let lexicon = lexiconOverride ?? SharedLexiconHolder.currentLexicon() else { return nil }
        let prevSecure = self.session?.isSecureContext ?? false
        let prevExternalContext = self.session?.externalContextBeforeInput
        self.session?.resetTopicMemory()
        self.activeLexiconObjectID = ObjectIdentifier(lexicon)
        let cachedCal = SharedLexiconHolder.cachedCalibrationSnapshot()
        self.lastCalibrationMTime = cachedCal?.mtime ?? -2
        let decoder = ViterbiDecoder(
            lexicon: lexicon,
            spatialModel: SpatialTouchModel(calibration: cachedCal?.calibration ?? LokeyTouchCalibration()),
            userStore: SharedLexiconHolder.userStore
        )
        if !cachedSupplementaryEntries.isEmpty {
            decoder.setSupplementaryEntries(cachedSupplementaryEntries)
        }
        let loadedSettings = LokeySettings.load()
        let newSession = LokeySessionController(
            decoder: decoder,
            settings: loadedSettings,
            persistTouchCalibration: true,
            decodeCandidatesInBackground: true,
            selectionFeedbackLogger: .shared
        )
        newSession.isSecureContext = prevSecure
        newSession.externalContextBeforeInput = prevExternalContext
        newSession.resetTopicMemory()
        self.session = newSession
        self.session?.prewarmEngineAsync()
        if refreshCalibration {
            refreshCalibrationFromDiskAsync()
        }
        session?.canPublishCandidates = { [weak self] in
            guard let self else { return false }
            return !self.candidateBar.hasActiveTouch && !self.expandedGrid.hasActiveInteraction
        }
        let resumeCandidates: () -> Void = { [weak self] in self?.session?.publishReadyCandidates() }
        candidateBar.onInteractionEnded = resumeCandidates
        expandedGrid.onInteractionEnded = resumeCandidates
        session?.onCandidateDecodeReady = { [weak self] seq, elapsed in
            guard let self, let session = self.session else { return }
            if elapsed < 0 {
                // Coalesce `onProvisional` (`len >= 8`) behind a 2.5ms timer so fast refiner
                // completions (`<= 2.5ms`) render once instead of 2x on `.main`.
                if session.needsImmediateCandidateRefresh {
                    if self.isCandidateGridExpanded {
                        self.hasDeferredProvisionalRender = false
                        self.updateMarkedTextFromSession(isKeyEdit: false)
                        self.updateCandidatePresentation(preservingScrollOffset: true)
                    } else {
                        self.candidateRefreshWorkItem?.cancel()
                        self.candidateRefreshPending = true
                        self.hasDeferredProvisionalRender = true
                        let item = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.candidateRefreshWorkItem = nil
                            self.candidateRefreshPending = false
                            self.hasDeferredProvisionalRender = false
                            self.updateMarkedTextFromSession(isKeyEdit: false)
                            self.updateCandidatePresentation(preservingScrollOffset: true)
                        }
                        self.candidateRefreshWorkItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.0025, execute: item)
                    }
                }
                return
            }
            self.logDecode(session, touchSequence: seq, elapsedMs: elapsed)
            let needsProvisionalFlush = self.hasDeferredProvisionalRender
            self.hasDeferredProvisionalRender = false
            self.candidateRefreshWorkItem?.cancel()
            self.candidateRefreshWorkItem = nil
            self.candidateRefreshPending = false
            // Synchronous snapshot-hit Backspace inside `touchesBegan` triggers `applyActionResult`
            // immediately after; avoid running `updateMarkedTextFromSession` + `refreshCandidateUI` twice.
            if self.keyGrid.isHandlingTouchDown && elapsed < 0.5 && !needsProvisionalFlush {
                return
            }
            if session.needsImmediateCandidateRefresh || needsProvisionalFlush {
                self.updateMarkedTextFromSession(isKeyEdit: false)
                self.updateCandidatePresentation(preservingScrollOffset: true)
            }
        }

        if requestSupplementary {
            refreshSupplementaryLexiconIfNeeded(force: true)
        }
        return loadedSettings
    }

    private func refreshSupplementaryLexiconIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now - lastSupplementaryRefreshUptime) >= 60.0 else { return }
        lastSupplementaryRefreshUptime = now
        requestSupplementaryLexicon { [weak self] uiLexicon in
            guard unsafeBitCast(uiLexicon, to: AnyObject?.self) != nil else { return }
            let pairs = uiLexicon.entries.compactMap { entry -> (String, String)? in
                let inp = entry.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let doc = entry.documentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !doc.isEmpty else { return nil }
                return (inp, doc)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedSupplementaryEntries = pairs
                self.session?.setSupplementaryEntries(pairs)
            }
        }
    }

    private func refreshCalibrationFromDiskAsync() {
        let previousMTime = lastCalibrationMTime
        Self.extensionStateIOQueue.async { [weak self] in
            let calMTime = LokeyAppGroup.sharedTouchCalibrationModificationTime()
            guard calMTime != previousMTime || SharedLexiconHolder.cachedCalibrationSnapshot() == nil else {
                return
            }
            let (reloadedCal, newMTime) = SharedLexiconHolder.loadCalibration()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastCalibrationMTime == previousMTime else { return }
                self.lastCalibrationMTime = newMTime
                if self.session?.isComposing != true {
                    self.session?.decoder.spatialModel.setCalibration(reloadedCal)
                }
            }
        }
    }

    private func observeAppGroupUpdates() {
        LokeyIPC.startObservingIfNeeded()
        let t1 = NotificationCenter.default.addObserver(
            forName: LokeyIPC.settingsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollSettingsBeforeTouchIfNeeded()
        }
        let t2 = NotificationCenter.default.addObserver(
            forName: LokeyIPC.lexiconDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            SharedLexiconHolder.userStore.reloadFromDiskAsyncIfExternal { [weak self] in
                guard let self, !self.candidateBar.hasActiveTouch else { return }
                self.refreshCandidateUI()
            }
        }
        let t3 = NotificationCenter.default.addObserver(
            forName: LokeyIPC.diagnosticLogDidClearNotification,
            object: nil,
            queue: .main
        ) { _ in
            LokeyDiagnosticLogger.shared.syncExternalClearAsync()
        }
        let t4 = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSExtensionHostWillResignActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.didReceiveHostResignOrBackground = true
            self?.pendingGlobeSwitchDeparture = false
            LokeyDiagnosticLogger.shared.flushAsync()
            LokeySelectionFeedbackLogger.shared.flushAsync()
        }
        let t5 = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSExtensionHostDidEnterBackground,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.didReceiveHostResignOrBackground = true
            self?.pendingGlobeSwitchDeparture = false
            self?.session?.resetTopicMemory()
            self?.session?.notifyContextBreak()
            LokeyDiagnosticLogger.shared.flushAsync()
            LokeySelectionFeedbackLogger.shared.flushAsync()
        }
        let t6 = NotificationCenter.default.addObserver(
            forName: LokeyIPC.baseLexiconDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadBaseLexiconIfNeeded()
        }
        let t7 = NotificationCenter.default.addObserver(
            forName: LokeyIPC.selectionFeedbackDidClearNotification,
            object: nil,
            queue: .main
        ) { _ in
            LokeySelectionFeedbackLogger.shared.syncExternalClearAsync()
        }
        ipcTokens = [t1, t2, t3, t4, t5, t6, t7]
    }

    internal func reloadBaseLexiconIfNeeded(
        lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) {
        if session?.isComposing == true
            || keyGrid.hasActiveTouches
            || candidateBar.hasActiveTouch
            || expandedGrid.hasActiveInteraction {
            pendingBaseLexiconReload = true
            pendingBaseLexiconReloadDir = lexiconsDirectory
            pendingBaseLexiconReloadDefaults = defaults
            return
        }
        pendingBaseLexiconReload = false
        pendingBaseLexiconReloadDir = nil
        pendingBaseLexiconReloadDefaults = nil
        let currentID = activeLexiconObjectID
        Self.extensionStateIOQueue.async { [weak self] in
            guard let newLexicon = SharedLexiconHolder.currentLexicon(
                lexiconsDirectory: lexiconsDirectory,
                defaults: defaults
            ) else { return }
            let newID = ObjectIdentifier(newLexicon)
            guard newID != currentID else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.session?.isComposing == true
                    || self.keyGrid.hasActiveTouches
                    || self.candidateBar.hasActiveTouch
                    || self.expandedGrid.hasActiveInteraction {
                    self.pendingBaseLexiconReload = true
                    self.pendingBaseLexiconReloadDir = lexiconsDirectory
                    self.pendingBaseLexiconReloadDefaults = defaults
                    return
                }
                self.session?.resetTopicMemory()
                let latestSettings = self.setupEngine(lexiconOverride: newLexicon)
                self.applyPreferences(latestSettings ?? LokeySettings.load())
                self.syncModeUI()
                self.refreshCandidateUI()
            }
        }
    }

    private func flushPendingBaseLexiconReloadIfNeeded() {
        guard pendingBaseLexiconReload, session?.isComposing != true else { return }
        let dir = pendingBaseLexiconReloadDir
        let defs = pendingBaseLexiconReloadDefaults
        reloadBaseLexiconIfNeeded(lexiconsDirectory: dir, defaults: defs)
    }

    private func pollSettingsBeforeTouchIfNeeded() {
        let gen = LokeyIPC.settingsGeneration
        guard gen != lastSettingsGeneration, loadingSettingsGeneration != gen else { return }
        loadingSettingsGeneration = gen
        let previousMTime = lastCalibrationMTime
        Self.extensionStateIOQueue.async { [weak self] in
            let latest = LokeySettings.load()
            let mtime = LokeyAppGroup.sharedTouchCalibrationModificationTime()
            let calibration = mtime != previousMTime ? SharedLexiconHolder.loadCalibration() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingSettingsGeneration == gen else { return }
                self.loadingSettingsGeneration = nil
                guard gen == LokeyIPC.settingsGeneration else {
                    self.pollSettingsBeforeTouchIfNeeded()
                    return
                }
                if let (value, updatedMTime) = calibration, self.lastCalibrationMTime == previousMTime {
                    self.session?.decoder.spatialModel.setCalibration(value)
                    self.lastCalibrationMTime = updatedMTime
                }
                self.lastSettingsGeneration = gen
                self.applyPreferences(latest)
            }
        }
    }

    private func reloadPreferencesFromAppGroup(
        refreshFullAccess: Bool = true,
        preloadedSettings: LokeySettings? = nil,
        refreshCalibration: Bool = true
    ) {
        lastSettingsGeneration = LokeyIPC.settingsGeneration
        loadingSettingsGeneration = nil
        if refreshCalibration {
            refreshCalibrationFromDiskAsync()
        }

        if refreshFullAccess && (hasAppearedInHost || !isRunningInExtensionProcess || customTextDocumentProxyForTesting != nil) {
            let wasFullAccess = cachedHasFullAccess
            cachedHasFullAccess = self.hasFullAccess
            if cachedHasFullAccess && !wasFullAccess {
                let shortVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
                DispatchQueue.global(qos: .utility).async {
                    LokeyAppGroup.writeExtensionHeartbeat(hasFullAccess: true, bundleVersion: shortVer)
                }
                LokeyDiagnosticLogger.shared.bootstrapFromDiskAsync()
                LokeySelectionFeedbackLogger.shared.bootstrapFromDiskAsync()
            }
        }
        applyPreferences(preloadedSettings ?? LokeySettings.load())
    }

    private func applyPreferences(_ latest: LokeySettings) {
        let prevScriptMode = session?.settings.chineseScriptMode
        let prevScheme = session?.settings.pinyinScheme
        session?.settings = latest
        LokeyDiagnosticLogger.shared.isEnabled = latest.enableDiagnosticLogging
        LokeySelectionFeedbackLogger.shared.isEnabled = latest.enableSelectionFeedbackLogging
        keyGrid.showPeriodBesideSpace = latest.showPeriodBesideSpace
        keyGrid.spaceWatermarkTitle = latest.pinyinScheme.spaceWatermark
        keyGrid.enableTopRowNumberSwipe = latest.enableTopRowNumberSwipe
        keyGrid.hapticStrength = latest.hapticStrength
        keyGrid.hapticFeedbackIntensity = latest.hapticFeedbackIntensity
        keyGrid.isKeyClickSoundEnabled = latest.isKeyClickSoundEnabled
        keyGrid.enableComposingSpaceTrackpad = latest.enableComposingSpaceTrackpad
        keyGrid.hasFullAccess = cachedHasFullAccess
        if (session?.isComposing == true || prevScriptMode != latest.chineseScriptMode || prevScheme != latest.pinyinScheme) && !candidateBar.hasActiveTouch {
            refreshCandidateUI()
        }
    }

    private func setupHierarchy() {
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        expandedGrid.translatesAutoresizingMaskIntoConstraints = false
        calloutBubble.translatesAutoresizingMaskIntoConstraints = false

        expandedGrid.isHidden = true

        // Place `keyGrid` beneath `candidateBar` so `candidateBar.hitTest` gets first priority on visible
        // candidate buttons while passing empty/hidden top-strip taps straight through to Row 0 (`q..p`)!
        view.addSubview(windowAttachmentObserver)
        view.addSubview(keyGrid)
        view.addSubview(expandedGrid)
        view.addSubview(candidateBar)
        view.addSubview(calloutBubble)

        windowAttachmentObserver.onHierarchyChanged = { [weak self] in
            guard let self else { return }
            self.reconcileDisplayTransitionIfNeeded()
            self.disableSystemGestureTouchDelays()
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            if self.view.window != nil && !self.isDisappearing && !self.pendingGlobeSwitchDeparture {
                self.updateKeyboardHeightConstraint(forceHostLayoutNotify: false, inLayoutPass: true)
                if !self.isWindowMoveFollowUpScheduled {
                    self.isWindowMoveFollowUpScheduled = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isWindowMoveFollowUpScheduled = false
                        guard self.view.window != nil,
                              !self.isDisappearing,
                              !self.pendingGlobeSwitchDeparture else { return }
                        self.reconcileDisplayTransitionIfNeeded()
                        self.updateKeyboardHeightConstraint(forceHostLayoutNotify: true, inLayoutPass: false)
                    }
                }
            }
        }
        keyGrid.calloutBubble = calloutBubble

        let hc = view.heightAnchor.constraint(equalToConstant: desiredKeyboardHeight())
        hc.priority = UILayoutPriority(999)
        hc.isActive = true
        self.heightConstraint = hc

        let barH = desiredCandidateBarHeight()
        expandedGrid.headerBarHeight = barH
        view.insertSubview(expandedGrid, belowSubview: candidateBar)
        let cbhc = candidateBar.heightAnchor.constraint(equalToConstant: barH)
        self.candidateBarHeightConstraint = cbhc

        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: view.topAnchor),
            cbhc,

            keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            expandedGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedGrid.topAnchor.constraint(equalTo: view.topAnchor),
            expandedGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            calloutBubble.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            calloutBubble.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            calloutBubble.topAnchor.constraint(equalTo: view.topAnchor),
            calloutBubble.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupDiagnosticTouchSniffer() {
        diagnosticTouchSniffer.onScreenTouchDown = { [weak self] pt, fingerCount, resolvedTarget, dispatchLagMs in
            guard let self,
                  LokeyDiagnosticLogger.shared.canRecordInteractions else { return 0 }
            let didSeamPass = self.candidateBar.lastHitTestDidSeamPassThrough
            let targetToken = self.resolveHitTargetToken(resolvedTarget)
            return LokeyDiagnosticLogger.shared.recordScreenTouchDownFast(
                point: pt,
                activeFingerCount: fingerCount,
                target: targetToken,
                didSeamPassThrough: didSeamPass,
                dispatchLagMs: dispatchLagMs
            )
        }
        keyGrid.touchSequence = { [weak sniffer = diagnosticTouchSniffer] touch, event in
            sniffer?.sequence(for: touch, event: event) ?? 0
        }
        view.addGestureRecognizer(diagnosticTouchSniffer)
    }

    private func resolveHitTargetToken(_ hitView: UIView?) -> TouchHitTargetToken {
        guard let hitView else {
            return .nilArea
        }
        if hitView === keyGrid || hitView.isDescendant(of: keyGrid) {
            return .keyGrid
        }
        if hitView.isDescendant(of: candidateBar) || hitView === candidateBar {
            if let btn = hitView as? UIButton {
                if let title = btn.title(for: .normal), !title.isEmpty {
                    return .candidateButton(btn.tag, title)
                }
                return .candidateExpandChevron
            }
            if hitView is UIScrollView {
                return .candidateScrollContainer
            }
            return .candidateBar
        }
        if hitView === expandedGrid || hitView.isDescendant(of: expandedGrid) {
            if let btn = hitView as? UIButton, let title = btn.title(for: .normal), !title.isEmpty {
                return .expandedGridButton(title)
            }
            return .expandedGrid
        }
        if let emojiPanel = emojiKeyboard, hitView === emojiPanel || hitView.isDescendant(of: emojiPanel) {
            return .emojiPanel
        }
        return .custom(String(describing: type(of: hitView)))
    }

    private func ensureEmojiKeyboard() -> EmojiKeyboardView {
        if let existing = emojiKeyboard {
            return existing
        }
        let panel = EmojiKeyboardView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.insertSubview(panel, belowSubview: calloutBubble)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panel.onInsertEmoji = { [weak self] emoji in
            guard let self else { return }
            self.pollSettingsBeforeTouchIfNeeded()
            self.keyGrid.triggerHaptic()
            self.keyGrid.playKeySound(type: .standard)
            self.session?.notifyContextBreak()
            LokeyDiagnosticLogger.shared.recordCommitFast(
                touchSeq: 0,
                source: .staticSource("Emoji面板"),
                committedText: emoji,
                remaining: .empty
            )
            self.insertDocumentTextAndTrackContext(emoji)
            self.refreshCandidateUI()
        }
        panel.onBackspace = { [weak self] in
            self?.pollSettingsBeforeTouchIfNeeded()
            self?.keyGrid.triggerHaptic()
            self?.keyGrid.playKeySound(type: .delete)
            self?.performBackspace()
        }
        panel.onSwitchToKeyboard = { [weak self] in
            guard let self else { return }
            self.pollSettingsBeforeTouchIfNeeded()
            self.keyGrid.triggerHaptic()
            if self.keyGrid.page != .alphabetic {
                self.keyGrid.page = .alphabetic
            }
            self.setEmojiKeyboardVisible(false)
        }
        self.emojiKeyboard = panel
        return panel
    }

    private func wireCallbacks() {
        candidateBar.beforeHitTest = { [weak self] in self?.renderPendingCandidates() }
        keyGrid.onBeforeKeyTouchDown = { [weak self] in
            if self?.candidateBar.hasActiveTouch == true { self?.renderPendingCandidates() }
            self?.candidateBar.commitPendingCandidateTouchIfNeeded()
        }

        keyGrid.onActiveKeyTouchDown = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastUserInteractionUptime = now
            self.pendingGlobeSwitchDeparture = false
            self.candidateBar.lastKeyTapUptime = now
        }

        keyGrid.onTouchDownSettingsCheck = { [weak self] in
            self?.pollSettingsBeforeTouchIfNeeded()
        }

        keyGrid.onAnchorsUpdated = { [weak self] anchors in
            guard let self else { return }
            let scr = self.effectiveScreenSize()
            let refWidth = self.view.bounds.width > 0 ? self.view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
            self.session?.decoder.spatialModel.isLandscapeLayout = (refWidth > 520.0)
            self.session?.decoder.spatialModel.updateAnchors(anchors)
        }

        keyGrid.onPageChanged = { [weak self] _ in
            self?.refreshCandidateUI()
        }

        keyGrid.onLetterTap = { [weak self] ch, normPt, isShifted, seq in
            guard let self else { return }
            guard let session = self.session else {
                let s = isShifted ? String(ch.uppercased()) : String(ch)
                LokeyDiagnosticLogger.shared.recordLetterDispositionFast(
                    touchSeq: seq,
                    disposition: .engineNotLoadedDirect(ch, isShifted)
                )
                self.writeDocument { [weak self] proxy in
                    self?.noteSelfHostWrite()
                    proxy.insertText(s)
                }
                return
            }
            if !session.isComposing {
                let preCtx = self.effectiveContextBeforeInput()
                session.externalContextBeforeInput = preCtx
                self.composingContextAnchor = String(preCtx.suffix(12))
            }
            self.candidateBar.returnToLeadingCandidateForTyping()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let res = session.handleLetterTap(char: ch, normalizedPoint: normPt, isShifted: isShifted, touchSeq: seq)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
            if !session.hasPendingCandidateDecode {
                self.logDecode(session, touchSequence: seq, elapsedMs: elapsedMs)
            }
            self.applyActionResult(res, touchSeq: seq)
        }

        keyGrid.onSymbolTap = { [weak self] sym in
            guard let self else { return }
            self.lastUserInteractionUptime = ProcessInfo.processInfo.systemUptime
            self.insertSmartSymbol(sym)
        }

        keyGrid.onPeriodTap = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastUserInteractionUptime = now
            let baseBeforeFlush: String = (!self.lastMarkedTextSent.isEmpty || !self.composingContextAnchor.isEmpty)
                ? self.composingContextAnchor
                : self.contextTracker.cachedContext(at: now)
            if let flushed = self.session?.flushTopCandidateIfComposing() {
                let hadActiveMarked = !self.lastMarkedTextSent.isEmpty
                let ctxBefore = baseBeforeFlush + flushed
                let p = self.session?.smartPeriodString(contextBefore: ctxBefore) ?? "。"
                self.session?.notifyContextBreak()
                if hadActiveMarked {
                    self.commitTextReplacingMarkedRange(flushed + p)
                } else {
                    self.commitTextReplacingMarkedRange(flushed)
                    self.insertDocumentTextAndTrackContext(p)
                }
            } else {
                let ctxBefore = self.effectiveContextBeforeInput()
                let p = self.session?.smartPeriodString(contextBefore: ctxBefore) ?? "。"
                self.session?.notifyContextBreak()
                self.insertDocumentTextAndTrackContext(p)
            }
            self.syncModeUI()
            self.refreshCandidateUI()
            self.flushPendingBaseLexiconReloadIfNeeded()
        }

        keyGrid.shouldDeferLineBreakDeletion = { [weak self] in
            guard let self, self.session?.isComposing != true else { return false }
            return self.contextTracker.currentLineLength == 0 && self.contextTracker.currentLineFollowsSeparator
        }
        keyGrid.onBackspaceTap = { [weak self] in
            self?.performBackspace()
        }

        keyGrid.onBackspaceSwipeClear = { [weak self] wasComposingAtTouchDown in
            self?.performBackspaceSwipeClear(wasComposingAtTouchDown: wasComposingAtTouchDown)
        }

        keyGrid.onSpaceTap = { [weak self] in
            guard let self else { return }
            self.lastUserInteractionUptime = ProcessInfo.processInfo.systemUptime
            guard let session = self.session else {
                self.insertDocumentTextAndTrackContext(" ")
                return
            }
            let res = session.handleSpace()
            switch res {
            case .passThroughToDocument:
                session.notifyContextBreak()
                self.insertDocumentTextAndTrackContext(" ")
                if self.keyGrid.page != .alphabetic {
                    self.keyGrid.page = .alphabetic
                } else {
                    self.refreshCandidateUI()
                }
            default:
                self.applyActionResult(res)
            }
        }

        keyGrid.onReturnTap = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastUserInteractionUptime = now
            guard let session = self.session else {
                let gen = self.contextTracker.recordNewlineOrClear(now: now, insertedLineBreak: true)
                self.scheduleContextReconciliation(generation: gen)
                self.writeDocument { [weak self] proxy in
                    self?.noteSelfHostWrite(mayTriggerFocusTransition: true)
                    proxy.insertText("\n")
                }
                return
            }
            let res = session.handleReturn()
            switch res {
            case .passThroughToDocument:
                let gen = self.contextTracker.recordNewlineOrClear(now: now, insertedLineBreak: true)
                self.scheduleContextReconciliation(generation: gen)
                session.notifyContextBreak()
                self.writeDocument { [weak self] proxy in
                    self?.noteSelfHostWrite(mayTriggerFocusTransition: true)
                    proxy.insertText("\n")
                }
                self.refreshCandidateUI()
            default:
                self.applyActionResult(res)
            }
        }

        keyGrid.onMoveCursor = { [weak self] step in
            guard let self else { return }
            if let session = self.session, session.isComposing {
                let previousCaret = session.preeditCaretUTF16Offset
                _ = session.moveComposingCursor(by: step)
                if session.preeditCaretUTF16Offset != previousCaret {
                    self.updateMarkedTextFromSession(isKeyEdit: false)
                    if self.keyGrid.hapticFeedbackIntensity > 0.0 {
                        self.caretFeedback.selectionChanged()
                        self.caretFeedback.prepare()
                    }
                }
                return
            }
            self.contextReconcileWorkItem?.cancel()
            self.contextTracker.recordCursorMove()
            self.session?.notifyContextBreak()
            self.writeDocument { $0.adjustTextPosition(byCharacterOffset: step) }
        }

        keyGrid.onGlobeEvent = { [weak self] sourceView, event in
            self?.handleInputModeList(from: sourceView, with: event)
        }
        keyGrid.globeSwitchButton.addTarget(
            self,
            action: #selector(UIInputViewController.handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        // Long-press `123` (0.45s) toggles Chinese-mixed (`拼`) <-> Pure English (`space`)
        keyGrid.onOpenSettings = { [weak self] in
            guard let self, let session = self.session else { return }
            if let flushed = session.flushTopCandidateIfComposing() {
                self.commitTextReplacingMarkedRange(flushed)
            }
            session.inputMode = (session.inputMode == .chineseMixed) ? .englishASCII : .chineseMixed
            self.syncModeUI()
            self.refreshCandidateUI()
            self.flushPendingBaseLexiconReloadIfNeeded()
        }

        // Candidate bar callbacks
        candidateBar.onSelectCandidate = { [weak self] idx in
            self?.pendingGlobeSwitchDeparture = false
            self?.selectCandidate(at: idx)
        }

        candidateBar.onDeleteCandidate = { [weak self] idx in
            self?.deleteUserCandidate(at: idx)
        }

        candidateBar.onToggleExpandGrid = { [weak self] in
            guard let self else { return }
            self.pendingGlobeSwitchDeparture = false
            self.pollSettingsBeforeTouchIfNeeded()
            self.keyGrid.triggerHaptic()
            self.setExpandedGrid(!self.isCandidateGridExpanded, reason: "顶栏箭头")
        }

        // Expanded candidate grid callbacks
        expandedGrid.onSelectCandidate = { [weak self] idx in
            self?.pendingGlobeSwitchDeparture = false
            self?.selectCandidate(at: idx)
        }
        expandedGrid.onDeleteCandidate = { [weak self] idx in
            self?.deleteUserCandidate(at: idx)
        }

        // Emoji keyboard trigger (EmojiKeyboardView is instantiated lazily on first presentation)
        keyGrid.onEmojiTap = { [weak self] in
            self?.pendingGlobeSwitchDeparture = false
            self?.setEmojiKeyboardVisible(true)
        }
    }

    // MARK: - Nil-Safe Objective-C Document Identifier Bridge

    /// Safely reads `UITextDocumentProxy.documentIdentifier` via Objective-C selector dispatch so a `nil` (`0x0`)
    /// return from UIKit's XPC `_UITextDocumentInterface` during `viewDidLoad()` / early extension attach NEVER triggers
    /// Swift's fatal `UUID._unconditionallyBridgeFromObjectiveC(_:)` `SIGTRAP`.
    static func safeDocumentIdentifier(from proxy: AnyObject?) -> UUID? {
        guard let proxy else { return nil }
        let sel = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard proxy.responds(to: sel),
              let unmanaged = proxy.perform(sel) else {
            return nil
        }
        return (unmanaged.takeUnretainedValue() as? NSUUID) as UUID?
    }

    private func currentDocumentIdentifier() -> UUID? {
        Self.safeDocumentIdentifier(from: self.textDocumentProxy)
    }

    private func didSwitchDocumentIdentifier(to currentDocID: UUID?) -> Bool {
        if let prev = activeDocumentID {
            return currentDocID != prev
        }
        if currentDocID != nil, let session, session.topicMemoryVector != .zero {
            return true
        }
        return false
    }

    // MARK: - State Synchronization

    private func effectiveContextBeforeInput() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        return contextTracker.cachedContext(at: now)
    }

    private func scheduleContextReconciliation(generation: UInt64, delay: TimeInterval = 0.24) {
        contextReconcileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Never perform synchronous cross-process `textDocumentProxy` XPC calls while composing
            // or while the user's fingers are actively tapping keys / candidates!
            guard self.session?.isComposing != true else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.markedTextCoalescer.hasPending
                || self.documentEditDelivery != nil
                || self.keyGrid.hasActiveTouches
                || self.candidateBar.hasActiveTouch
                || self.expandedGrid.hasActiveInteraction
                || (now - self.lastUserInteractionUptime) < 0.45 {
                self.scheduleContextReconciliation(generation: generation, delay: 0.24)
                return
            }
            let proxy = self.textDocumentProxy
            let liveDocID = self.currentDocumentIdentifier()
            let switchedDuringEcho = self.didSwitchDocumentIdentifier(to: liveDocID)
            if let liveDocID {
                self.activeDocumentID = liveDocID
            } else if switchedDuringEcho {
                self.activeDocumentID = nil
            }
            if switchedDuringEcho {
                self.hasSyncedTraitsForActiveDocument = false
                self.session?.resetTopicMemory()
                self.session?.notifyContextBreak()
            }
            self.setSecureContext(proxy.isSecureTextEntry == true)
            let rawLiveBefore = proxy.documentContextBeforeInput
            let effectiveLiveBefore: String?
            if rawLiveBefore == nil && proxy.hasText {
                effectiveLiveBefore = self.contextTracker.cachedContext(at: now)
            } else {
                effectiveLiveBefore = rawLiveBefore
            }
            let (needsRefresh, didBreak) = self.contextTracker.reconcileAfterXPCDelay(
                generation: generation,
                proxyBefore: effectiveLiveBefore,
                isComposing: false,
                now: now
            )
            if didBreak && !switchedDuringEcho {
                self.session?.notifyContextBreak()
            }
            let beforeEmpty = (effectiveLiveBefore ?? "").isEmpty
            if self.cachedEnablesReturnKeyAutomatically && beforeEmpty {
                self.cachedDocumentHasExternalText = proxy.hasText
            } else {
                self.cachedDocumentHasExternalText = !beforeEmpty
            }
            self.updateReturnKeyEnabledState(isComposing: false)
            if needsRefresh && !self.candidateBar.hasActiveTouch {
                self.refreshCandidateUI()
            }
            if generation == self.contextTracker.editGeneration,
               let retryDelay = self.contextTracker.remainingOptimisticDelay(at: now) {
                self.scheduleContextReconciliation(generation: generation, delay: max(0.18, retryDelay))
            }
        }
        contextReconcileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // Apply session/context changes immediately. Ordered proxy mutations leave the touch
    // callback together, while unmark commits split subsequent edits into the next RunLoop turn
    // so UIKit never reorders `insertionText` ahead of `unmarkIfNecessary`.
    private func writeDocument(isUnmarkCommit: Bool = false, _ edit: @escaping (UITextDocumentProxy) -> Void) {
        if !keyGrid.isHandlingTouchDown && documentEditDelivery == nil {
            edit(textDocumentProxy)
            return
        }
        pendingDocumentEdits.append((docGen: activeDocumentGeneration, isUnmarkCommit: isUnmarkCommit, edit: edit))
        guard documentEditDelivery == nil else { return }
        let delivery = DispatchWorkItem { [weak self] in self?.deliverPendingDocumentEdits() }
        documentEditDelivery = delivery
        DispatchQueue.main.async(execute: delivery)
    }

    private func cancelPendingDocumentEdits() {
        documentEditDelivery?.cancel()
        documentEditDelivery = nil
        pendingDocumentEdits.removeAll(keepingCapacity: true)
    }

    private func deliverPendingDocumentEdits() {
        documentEditDelivery = nil
        guard !pendingDocumentEdits.isEmpty else { return }
        let currentGen = activeDocumentGeneration
        let proxy = textDocumentProxy
        var index = 0
        while index < pendingDocumentEdits.count {
            let item = pendingDocumentEdits[index]
            index += 1
            guard item.docGen == currentGen else { continue }
            item.edit(proxy)
            if item.isUnmarkCommit {
                let hasRemainingForCurrentGen = pendingDocumentEdits[index...].contains { $0.docGen == currentGen }
                if hasRemainingForCurrentGen {
                    pendingDocumentEdits.removeFirst(index)
                    let nextDelivery = DispatchWorkItem { [weak self] in self?.deliverPendingDocumentEdits() }
                    documentEditDelivery = nextDelivery
                    DispatchQueue.main.async(execute: nextDelivery)
                    return
                }
            }
        }
        pendingDocumentEdits.removeAll(keepingCapacity: true)
    }

    private func replaceAndUnmark(_ text: String) {
        writeDocument(isUnmarkCommit: true) { [weak self] proxy in
            self?.noteSelfHostWrite(count: 2)
            let start = DispatchTime.now().uptimeNanoseconds
            proxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
            proxy.unmarkText()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            if elapsed >= 5 {
                LokeyDiagnosticLogger.shared.recordMainThreadStall(phase: "setMarkedText(XPC)", elapsedMs: elapsed)
            }
        }
    }

    private func commitTextReplacingMarkedRange(_ text: String) {
        markedTextCoalescer.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let priorContext: String = (!lastMarkedTextSent.isEmpty || !composingContextAnchor.isEmpty)
            ? composingContextAnchor
            : contextTracker.cachedContext(at: now)
        let gen = contextTracker.recordInsert(
            text,
            currentProxyBefore: priorContext,
            now: now
        )
        if !lastMarkedTextSent.isEmpty {
            lastMarkedTextSent = ""
            markedTextCoalescer.resetFlushedMarkedText(to: "")
            lastMarkedTextMutationUptime = now
            replaceAndUnmark(text)
        } else {
            writeDocument { [weak self] proxy in
                self?.noteSelfHostWrite()
                proxy.insertText(text)
            }
        }
        if session?.isComposing != true {
            composingContextAnchor = ""
            scheduleContextReconciliation(generation: gen)
        }
    }

    private func insertDocumentTextAndTrackContext(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let priorContext = contextTracker.cachedContext(at: now)
        let gen = contextTracker.recordInsert(
            text,
            currentProxyBefore: priorContext,
            now: now
        )
        writeDocument { [weak self] proxy in
            self?.noteSelfHostWrite()
            proxy.insertText(text)
        }
        scheduleContextReconciliation(generation: gen)
    }

    private func deleteDocumentBackwardAndTrackContext() {
        let now = ProcessInfo.processInfo.systemUptime
        let priorContext = contextTracker.cachedContext(at: now)
        let gen = contextTracker.recordBackspacePassThrough(
            currentProxyBefore: priorContext,
            now: now
        )
        writeDocument { [weak self] proxy in
            self?.noteSelfHostWrite()
            proxy.deleteBackward()
        }
        scheduleContextReconciliation(generation: gen)
    }

    private func insertSmartSymbol(_ rawSymbol: String) {
        let wasMomentaryNumericSlide = keyGrid.isCommittingMomentaryNumericSymbol
        let now = ProcessInfo.processInfo.systemUptime
        let baseBeforeFlush: String = (!lastMarkedTextSent.isEmpty || !composingContextAnchor.isEmpty)
            ? composingContextAnchor
            : contextTracker.cachedContext(at: now)
        let flushed = session?.flushTopCandidateIfComposing()
        let ctxBefore = flushed.map { baseBeforeFlush + $0 } ?? effectiveContextBeforeInput()
        let action = session?.resolveSmartSymbol(rawSymbol, contextBefore: ctxBefore)
            ?? LokeySessionController.SmartSymbolAction(textToInsert: rawSymbol)
        let shouldAutoReturn = wasMomentaryNumericSlide || (session?.shouldAutoReturnToAlphabeticAfterSymbol(
            rawSymbol,
            resolvedText: action.textToInsert,
            contextBefore: ctxBefore
        ) ?? false)

        if let flushed {
            let hadActiveMarked = !lastMarkedTextSent.isEmpty
            let deleteInFlushed = min(flushed.count, max(0, action.deletePreviousCount))
            let trimmedFlushed = deleteInFlushed > 0 ? String(flushed.dropLast(deleteInFlushed)) : flushed
            let remainingDeletes = max(0, action.deletePreviousCount - deleteInFlushed)
            if action.textToInsert == "，" || action.textToInsert == "、" {
                session?.externalContextBeforeInput = ctxBefore
                session?.notifyClauseComma()
            } else {
                session?.notifyContextBreak()
            }
            if hadActiveMarked && remainingDeletes == 0 {
                commitTextReplacingMarkedRange(trimmedFlushed + action.textToInsert)
            } else {
                commitTextReplacingMarkedRange(trimmedFlushed)
                for _ in 0..<remainingDeletes {
                    deleteDocumentBackwardAndTrackContext()
                }
                insertDocumentTextAndTrackContext(action.textToInsert)
            }
        } else {
            if action.deletePreviousCount > 0 {
                for _ in 0..<action.deletePreviousCount {
                    deleteDocumentBackwardAndTrackContext()
                }
            }
            if action.textToInsert == "，" || action.textToInsert == "、" {
                session?.externalContextBeforeInput = effectiveContextBeforeInput()
                session?.notifyClauseComma()
            } else {
                session?.notifyContextBreak()
            }
            insertDocumentTextAndTrackContext(action.textToInsert)
        }
        syncModeUI()
        if shouldAutoReturn && keyGrid.page != .alphabetic {
            keyGrid.scheduleAutoReturnToAlphabetic()
        } else {
            refreshCandidateUI()
        }
        flushPendingBaseLexiconReloadIfNeeded()
    }

    private func performBackspace() {
        let now = ProcessInfo.processInfo.systemUptime
        lastUserInteractionUptime = now
        guard let session else {
            deleteDocumentBackwardAndTrackContext()
            return
        }
        let res = session.handleBackspace()
        switch res {
        case .passThroughToDocument:
            session.notifyContextBreak()
            deleteDocumentBackwardAndTrackContext()
            refreshCandidateUI()
        default:
            applyActionResult(res)
        }
    }

    internal func performBackspaceSwipeClear(wasComposingAtTouchDown: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lastUserInteractionUptime = now

        if wasComposingAtTouchDown || session?.isComposing == true {
            let clearedPreedit = session?.currentDecode.preeditDisplay ?? ""
            session?.resetComposing()
            session?.notifyContextBreak()
            composingContextAnchor = ""
            clearActiveMarkedTextIfNeeded()
            if isCandidateGridExpanded {
                setExpandedGrid(false, reason: "退格清空")
            }
            LokeyDiagnosticLogger.shared.recordCommitFast(
                touchSeq: 0,
                source: .staticSource("左滑退格清空"),
                committedText: "",
                remaining: .clearedPreedit(clearedPreedit)
            )
            refreshCandidateUI()
            syncModeUI()
            flushPendingBaseLexiconReloadIfNeeded()
            return
        }

        // The initial down already removed one grapheme. The optimistic length also works
        // when the host has not acknowledged that deletion yet.
        guard let remaining = contextTracker.currentLineLength, remaining > 0 else { return }
        writeDocument { [weak self] proxy in
            self?.noteSelfHostWrite()
            for _ in 0..<remaining { proxy.deleteBackward() }
        }
        let gen = contextTracker.recordNewlineOrClear(now: now)
        session?.notifyContextBreak()
        LokeyDiagnosticLogger.shared.recordCommitFast(
            touchSeq: 0,
            source: .staticSource("左滑退格清空输入框"),
            committedText: "",
            remaining: .empty
        )
        refreshCandidateUI()
        syncModeUI()
        scheduleContextReconciliation(generation: gen)
    }

    private func selectCandidate(at index: Int) {
        renderPendingCandidates()
        lastUserInteractionUptime = ProcessInfo.processInfo.systemUptime
        pollSettingsBeforeTouchIfNeeded()
        keyGrid.triggerHaptic()
        keyGrid.playKeySound(type: .standard)

        if session?.isComposing == true {
            if !candidateBar.isSelectingDisplayedCandidate && !expandedGrid.isSelectingDisplayedCandidate {
                finishCandidateDecoding()
            }
            guard let res = session?.selectCandidate(at: index) else { return }
            applyActionResult(res)
        } else if isShowingQuickPunctuationStrip {
            guard index >= 0 && index < currentIdleCandidates.count else { return }
            let chosen = currentIdleCandidates[index].text
            if isCandidateGridExpanded {
                setExpandedGrid(false, reason: "标点选中")
            }
            insertSmartSymbol(chosen)
        } else {
            guard index >= 0 && index < currentIdleCandidates.count else { return }
            let chosen = currentIdleCandidates[index].text
            session?.recordAssociationSelection(chosen)
            LokeyDiagnosticLogger.shared.recordCommitFast(
                touchSeq: 0,
                source: .association(index),
                committedText: chosen,
                remaining: .empty
            )
            insertDocumentTextAndTrackContext(chosen)
            if isCandidateGridExpanded {
                setExpandedGrid(false, reason: "联想词选中")
            }
            syncModeUI()
            refreshCandidateUI()
        }
    }

    private func deleteUserCandidate(at index: Int) {
        pollSettingsBeforeTouchIfNeeded()
        keyGrid.triggerHaptic()

        if session?.isComposing == true {
            guard let session else { return }
            _ = session.deleteUserCandidate(at: index)
        } else if index >= 0 && index < currentIdleCandidates.count {
            let item = currentIdleCandidates[index]
            if item.isDeletableUserPhrase {
                if let session {
                    session.deleteUserPhrase(displaySurface: item.text)
                } else {
                    SharedLexiconHolder.userStore.deletePhrase(surface: item.text)
                }
            }
        }
        refreshCandidateUI()
        candidateBar.flashDeletedNotice()
    }

    private func logDecode(_ session: LokeySessionController, touchSequence: UInt64, elapsedMs: Double) {
        guard LokeyDiagnosticLogger.shared.canRecordInteractions,
              session.isComposing,
              !session.isSecureContext else { return }
        LokeyDiagnosticLogger.shared.recordDecodeFast(
            touchSeq: touchSequence,
            samples: session.samples,
            preedit: session.currentDecode.preeditDisplay,
            candidates: session.currentDecode.candidates,
            elapsedMs: elapsedMs
        )
    }

    func finishCandidateDecoding() {
        session?.finishPendingCandidateDecode()
        renderPendingCandidates()
    }

    private func applyActionResult(_ result: LokeySessionController.KeyActionResult, touchSeq: UInt64? = nil) {
        switch result {
        case .composingUpdated:
            lastMarkedTextMutationUptime = ProcessInfo.processInfo.systemUptime
            updateMarkedTextFromSession(touchSeq: touchSeq)
            if session?.needsImmediateCandidateRefresh != false { refreshCandidateUI() }
        case let .commitText(text, _):
            let remainingPreedit = (session?.isComposing == true) ? (session?.currentDecode.preeditDisplay ?? "") : ""
            LokeyDiagnosticLogger.shared.recordCommitFast(
                touchSeq: touchSeq ?? 0,
                source: .staticSource("拼音上屏"),
                committedText: text,
                remaining: .text(remainingPreedit)
            )
            commitTextReplacingMarkedRange(text)
            if session?.isComposing == true {
                // Partial prefix commit (`"现在我"` selected from `"xianzaiwomendagezishishiba"`):
                // 1) Collapse expanded candidate grid back to 26-key keyboard just like Native iOS 26.
                // 2) Defer re-marking the remaining Pinyin by ~12ms (1 ProMotion frame) so SwiftUI `TextField` / `UITextView`
                //    settles the committed prefix cleanly without unmarking the remaining Pinyin!
                let now = ProcessInfo.processInfo.systemUptime
                lastPartialCommitUptime = now
                lastMarkedTextMutationUptime = now
                composingContextAnchor = String(effectiveContextBeforeInput().suffix(12))
                if isCandidateGridExpanded {
                    updateGridVisibility(false, reason: "部分选词后仍有拼音")
                }
                updateMarkedTextFromSession(delayAfterCommit: 0.012, touchSeq: touchSeq)
            } else {
                composingContextAnchor = ""
                if isCandidateGridExpanded {
                    setExpandedGrid(false, reason: "整段提交完成")
                }
                flushPendingBaseLexiconReloadIfNeeded()
            }
            refreshCandidateUI()
        case .passThroughToDocument:
            break
        }
        syncModeUI()
        flushPendingBaseLexiconReloadIfNeeded()
    }

    private func clearActiveMarkedTextIfNeeded() {
        let hadPending = markedTextCoalescer.hasPending
        let hadFlushed = !lastMarkedTextSent.isEmpty || !markedTextCoalescer.lastFlushedMarkedText.isEmpty
        markedTextCoalescer.cancel()
        guard hadFlushed || hadPending else { return }
        lastMarkedTextSent = ""
        markedTextCoalescer.resetFlushedMarkedText(to: "")
        lastMarkedTextMutationUptime = ProcessInfo.processInfo.systemUptime
        if hadFlushed { replaceAndUnmark("") }
    }

    private func updateMarkedTextFromSession(delayAfterCommit: TimeInterval? = nil, isKeyEdit: Bool = true, touchSeq: UInt64? = nil) {
        guard let session else { return }
        if session.isComposing {
            if lastMarkedTextSent.isEmpty && !markedTextCoalescer.hasPending {
                if composingContextAnchor.isEmpty {
                    composingContextAnchor = String(effectiveContextBeforeInput().suffix(12))
                }
            }
            let preedit = session.currentDecode.preeditDisplay
            let formattedPinyin = preedit.replacingOccurrences(of: "'", with: " ")
            let caretLocation = min(formattedPinyin.utf16.count, max(0, session.preeditCaretUTF16Offset))
            let range = NSRange(location: caretLocation, length: 0)
            if !isKeyEdit
                && formattedPinyin == markedTextCoalescer.latestScheduledOrFlushedText
                && range == markedTextCoalescer.latestScheduledOrFlushedSelectedRange {
                return
            }

            // Let a partial commit settle before either the next key or its background ranking re-marks the suffix.
            let sinceCommit = ProcessInfo.processInfo.systemUptime - lastPartialCommitUptime
            let delay = delayAfterCommit ?? (sinceCommit < 0.016 ? max(0.004, 0.016 - sinceCommit) : markedTextCoalescer.defaultInterval)
            markedTextCoalescer.schedule(markedText: formattedPinyin, selectedRange: range,
                                         proxy: textDocumentProxy, delay: delay, isKeyEdit: isKeyEdit, touchSeq: touchSeq)
        } else {
            composingContextAnchor = ""
            clearActiveMarkedTextIfNeeded()
        }
    }

    /// Explicitly flushes any pending coalesced marked text mutation immediately with zero delay.
    /// Used by automated unit/integration test harnesses or explicit flush checkpoints.
    public func flushPendingMarkedText() {
        deliverPendingDocumentEdits()
        finishCandidateDecoding()
        markedTextCoalescer.flushImmediately(proxy: textDocumentProxy)
    }

    public override func handleInputModeList(from view: UIView, with event: UIEvent) {
        guard !isDisappearing,
              view.window != nil,
              self.view.window != nil,
              view.bounds.width > 0.5,
              view.bounds.height > 0.5 else {
            return
        }
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        candidateRefreshPending = false
        contextReconcileWorkItem?.cancel()
        contextReconcileWorkItem = nil

        if shouldBypassInputModeListHUDForDuoFold() {
            let relevantTouches = event.touches(for: view) ?? event.allTouches
            if let touches = relevantTouches, !touches.isEmpty {
                if touches.contains(where: { $0.phase == .began }) {
                    cancelDuoCoverGlobeFallbackTimer()
                    didAdvanceInputModeForCurrentGlobeTouch = false
                    duoCoverGlobeFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.duoCoverGlobeFallbackTimer = nil
                        guard !self.didAdvanceInputModeForCurrentGlobeTouch else { return }
                        self.didAdvanceInputModeForCurrentGlobeTouch = true
                        self.advanceToNextInputMode()
                    }
                } else if touches.contains(where: { $0.phase == .cancelled }) {
                    cancelDuoCoverGlobeFallbackTimer()
                    didAdvanceInputModeForCurrentGlobeTouch = false
                } else if let endedTouch = touches.first(where: { $0.phase == .ended }) {
                    cancelDuoCoverGlobeFallbackTimer()
                    if !didAdvanceInputModeForCurrentGlobeTouch {
                        let isWithinTolerance = (endedTouch.view == nil)
                            || view.bounds.insetBy(dx: -24.0, dy: -24.0).contains(endedTouch.location(in: view))
                        if isWithinTolerance {
                            didAdvanceInputModeForCurrentGlobeTouch = true
                            advanceToNextInputMode()
                        }
                    }
                } else if let movedTouch = touches.first(where: { $0.phase == .moved }) {
                    if movedTouch.view === view
                        && !view.bounds.insetBy(dx: -32.0, dy: -32.0).contains(movedTouch.location(in: view)) {
                        cancelDuoCoverGlobeFallbackTimer()
                    }
                }
            } else {
                cancelDuoCoverGlobeFallbackTimer()
                advanceToNextInputMode()
            }
            return
        }

        if isRunningInExtensionProcess {
            pendingGlobeSwitchDeparture = true
            lastGlobeInteractionUptime = ProcessInfo.processInfo.systemUptime
        }
        if let hook = onSuperHandleInputModeListForTesting {
            hook(view, event)
            return
        }
        super.handleInputModeList(from: view, with: event)
    }

    public override func advanceToNextInputMode() {
        guard !isDisappearing, view.window != nil else {
            return
        }
        if isRunningInExtensionProcess {
            pendingGlobeSwitchDeparture = true
            lastGlobeInteractionUptime = ProcessInfo.processInfo.systemUptime
        }
        if let hook = onAdvanceToNextInputModeForTesting {
            hook()
            return
        }
        super.advanceToNextInputMode()
    }

    private func makeIdlePredictiveCandidates() -> [LokeyCandidate] {
        guard !isDisappearing, let session, session.inputMode == .chineseMixed else {
            return []
        }
        let contextBefore = effectiveContextBeforeInput()
        let contextual = session.predictNextWords(documentContextBeforeInput: contextBefore, limit: 24)
        if !contextual.isEmpty {
            return contextual
        }
        guard (hasAppearedInHost || overrideShowStarterCandidatesForTesting || view.window != nil),
              !LokeyDiagnosticLogger.shared.isSecureContext else {
            return []
        }
        return session.starterIdleCandidates(limit: 24)
    }

    private func refreshCandidateUI(preservingScrollOffset: Bool = false) {
        if keyGrid.isHandlingTouchDown && !isCandidateGridExpanded {
            guard !candidateRefreshPending else { return }
            candidateRefreshPending = true
            let item = DispatchWorkItem { [weak self] in
                self?.renderPendingCandidates()
            }
            candidateRefreshWorkItem = item
            if session?.hasPendingCandidateDecode == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.0028, execute: item)
            } else {
                DispatchQueue.main.async(execute: item)
            }
            return
        }
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        updateCandidatePresentation(preservingScrollOffset: preservingScrollOffset)
    }

    private func renderPendingCandidates() {
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        let hadPending = candidateRefreshPending || hasDeferredProvisionalRender
        let passBefore = candidatePresentationPassCount
        let canPublishNow = !candidateBar.isSelectingDisplayedCandidate
            && !expandedGrid.isSelectingDisplayedCandidate
            && (session?.canPublishCandidates?() ?? true)
        if hadPending && canPublishNow && session?.hasPendingCandidateDecode == true {
            session?.publishReadyCandidates()
        }
        if hadPending && candidatePresentationPassCount == passBefore {
            updateCandidatePresentation()
        } else {
            candidateRefreshPending = false
            hasDeferredProvisionalRender = false
        }
    }

    private func matchesPresentedCandidateSignature(_ candidates: [LokeyCandidate]) -> Bool {
        guard candidates.count == lastPresentedCandidateSignature.count else { return false }
        for i in 0..<candidates.count {
            let lhs = candidates[i]
            let rhs = lastPresentedCandidateSignature[i]
            if lhs.text != rhs.text || lhs.isDeletableUserPhrase != rhs.deletable {
                return false
            }
        }
        return true
    }

    private func recordPresentedCandidateSignature(
        _ candidates: [LokeyCandidate],
        highlightFirst: Bool,
        expanded: Bool,
        showsRightAccessory: Bool
    ) {
        hasValidPresentedCandidateSignature = true
        lastPresentedHighlightFirst = highlightFirst
        lastPresentedExpanded = expanded
        lastPresentedShowsAccessory = showsRightAccessory
        lastPresentedCandidateSignature.removeAll(keepingCapacity: true)
        if lastPresentedCandidateSignature.capacity < candidates.count {
            lastPresentedCandidateSignature.reserveCapacity(candidates.count)
        }
        for c in candidates {
            lastPresentedCandidateSignature.append(
                PresentedCandidateItem(text: c.text, deletable: c.isDeletableUserPhrase)
            )
        }
    }

    private func updateCandidatePresentation(preservingScrollOffset: Bool = false) {
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        candidateRefreshPending = false
        hasDeferredProvisionalRender = false
        candidatePresentationPassCount &+= 1
        let isComposing = (session?.isComposing == true)
        let isPinyin = ((session?.inputMode ?? .chineseMixed) == .chineseMixed)
        let activeCandidates: [LokeyCandidate]
        let highlightFirst: Bool
        let showsRightAccessory: Bool

        if isComposing {
            isShowingQuickPunctuationStrip = false
            activeCandidates = session?.currentDecode.candidates ?? []
            highlightFirst = true
            showsRightAccessory = true
        } else if isPinyin && keyGrid.page != .alphabetic {
            isShowingQuickPunctuationStrip = true
            currentIdleCandidates = Self.quickNumericPunctuation
            activeCandidates = Self.quickNumericPunctuation
            highlightFirst = false
            showsRightAccessory = false
            if isCandidateGridExpanded {
                updateGridVisibility(false, reason: "切换数字或符号页")
            }
        } else {
            isShowingQuickPunctuationStrip = false
            let idle = makeIdlePredictiveCandidates()
            currentIdleCandidates = idle
            activeCandidates = idle
            highlightFirst = false
            showsRightAccessory = true
        }

        if activeCandidates.isEmpty && isCandidateGridExpanded {
            updateGridVisibility(false, reason: "候选列表为空")
        }

        let barScroll = candidateBar.candidateScrollView
        let isBarAtRestingStart = abs(barScroll.contentOffset.x + barScroll.contentInset.left) <= 0.5
        let canSkipRedundantBarUpdate = hasValidPresentedCandidateSignature
            && lastPresentedHighlightFirst == highlightFirst
            && lastPresentedExpanded == isCandidateGridExpanded
            && lastPresentedShowsAccessory == showsRightAccessory
            && (preservingScrollOffset || isBarAtRestingStart)
            && (!isCandidateGridExpanded || preservingScrollOffset)
            && matchesPresentedCandidateSignature(activeCandidates)

        if !canSkipRedundantBarUpdate {
            recordPresentedCandidateSignature(
                activeCandidates,
                highlightFirst: highlightFirst,
                expanded: isCandidateGridExpanded,
                showsRightAccessory: showsRightAccessory
            )
            candidateBar.update(
                candidates: activeCandidates,
                highlightFirst: highlightFirst,
                expanded: isCandidateGridExpanded,
                showsRightAccessory: showsRightAccessory,
                preservingScrollOffset: preservingScrollOffset
            )
            if isCandidateGridExpanded {
                expandedGrid.update(candidates: activeCandidates, highlightFirst: highlightFirst,
                                    preservingScrollOffset: preservingScrollOffset)
            }
        }

        keyGrid.isComposing = isComposing
        keyGrid.isPinyinMode = isPinyin
        keyGrid.spaceTitle = isPinyin ? "" : "space"
        updateReturnKeyEnabledState(isComposing: isComposing)
        emojiKeyboard?.switchButtonTitle = isPinyin ? "拼音" : "ABC"
    }

    private func updateGridVisibility(_ open: Bool, reason: String) {
        guard open != isCandidateGridExpanded else { return }
        if open {
            expandedGrid.headerBarHeight = desiredCandidateBarHeight()
            expandedGrid.beginOpenTrace(start: candidateBar.arrowDownTime)
        } else {
            expandedGrid.finishOpenTrace(reason: reason)
        }
        isCandidateGridExpanded = open
        lastPresentedExpanded = open
        expandedGrid.isHidden = !open
        if !isEmojiKeyboardActive {
            keyGrid.isHidden = open
        }
        candidateBar.setGridExpanded(open)
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            event: .expandedPanelState(open: open, reason: reason, inWindow: expandedGrid.window != nil)
        )
    }

    private func setExpandedGrid(_ open: Bool, reason: String) {
        if open {
            renderPendingCandidates()
            candidateBar.resetTouchTracking()
            keyGrid.resetTransientInteractions()
            if isEmojiKeyboardActive {
                setEmojiKeyboardVisible(false)
            }
        }
        let displayed = candidateBar.displayedCandidates
        guard !open || !displayed.isEmpty else { return }
        updateGridVisibility(open, reason: reason)
        if open {
            expandedGrid.update(candidates: displayed, highlightFirst: session?.isComposing == true)
            // A result held during a strip gesture can replace the displayed list
            // after opening. A finger already down keeps its original selection.
            DispatchQueue.main.async { [weak self] in self?.session?.publishReadyCandidates() }
        }
    }

    private func setEmojiKeyboardVisible(_ visible: Bool, performLayout: Bool = true) {
        isEmojiKeyboardActive = visible
        if visible {
            candidateBar.resetTouchTracking()
            keyGrid.resetTransientInteractions()
            if let flushed = session?.flushTopCandidateIfComposing() {
                commitTextReplacingMarkedRange(flushed)
            }
            if isCandidateGridExpanded {
                setExpandedGrid(false, reason: "切换表情")
            }
            let panel = ensureEmojiKeyboard()
            panel.switchButtonTitle = (session?.inputMode == .englishASCII) ? "ABC" : "拼音"
            panel.prepareForDisplay()
            candidateBar.isHidden = true
            keyGrid.isHidden = true
            expandedGrid.isHidden = true
            panel.isHidden = false
            updateKeyboardHeightConstraint()
            flushPendingBaseLexiconReloadIfNeeded()
        } else {
            emojiKeyboard?.cancelActiveInteractions()
            emojiKeyboard?.isHidden = true
            candidateBar.isHidden = false
            if performLayout {
                updateKeyboardHeightConstraint()
                if view.window != nil {
                    view.layoutIfNeeded()
                }
                keyGrid.isHidden = false
                refreshCandidateUI()
            } else {
                keyGrid.isHidden = false
            }
        }
        if hasAppearedInHost {
            publishExtensionVisibility(isVisible: true)
        }
    }

    private func updateReturnKeyEnabledState(isComposing: Bool) {
        if !cachedEnablesReturnKeyAutomatically {
            keyGrid.isReturnKeyEnabled = true
        } else {
            keyGrid.isReturnKeyEnabled = isComposing
                || !effectiveContextBeforeInput().isEmpty
                || cachedDocumentHasExternalText
        }
    }

    private func syncModeUI() {
        let mode = session?.inputMode ?? .chineseMixed
        let isPinyin = (mode == .chineseMixed)
        let isCN = isPinyin && (session?.lastCommittedWasChinese ?? true)
        let composing = (session?.isComposing == true)
        keyGrid.isPinyinMode = isPinyin
        keyGrid.isChineseContext = isCN
        keyGrid.isComposing = composing
        keyGrid.spaceTitle = isPinyin ? "" : "space"
        updateReturnKeyEnabledState(isComposing: composing)
        emojiKeyboard?.switchButtonTitle = isPinyin ? "拼音" : "ABC"
    }

    private func setSecureContext(_ secure: Bool) {
        if let session, secure != session.isSecureContext {
            activeDocumentGeneration &+= 1
            clearPendingSelfEcho()
            markedTextCoalescer.cancel()
            markedTextCoalescer.resetFlushedMarkedText()
            lastMarkedTextSent = ""
            composingContextAnchor = ""
        }
        LokeyDiagnosticLogger.shared.isSecureContext = secure
        LokeySelectionFeedbackLogger.shared.isSecureContext = secure
        session?.isSecureContext = secure
    }

    internal func syncDocumentTraits(knownBefore: String? = nil, knownIsSecure: Bool? = nil) {
        hasSyncedTraitsForActiveDocument = true
        let proxy = textDocumentProxy
        let isSecure = knownIsSecure ?? (proxy.isSecureTextEntry == true)
        setSecureContext(isSecure)
        if let knownBefore { contextTracker.observeLine(before: knownBefore) }
        keyGrid.returnKeyType = proxy.returnKeyType ?? .default
        cachedEnablesReturnKeyAutomatically = (proxy.enablesReturnKeyAutomatically == true)
        if cachedEnablesReturnKeyAutomatically {
            let before = knownBefore ?? proxy.documentContextBeforeInput
            let beforeEmpty = (before ?? "").isEmpty
            cachedDocumentHasExternalText = beforeEmpty ? proxy.hasText : true
        } else {
            cachedDocumentHasExternalText = false
        }

        if let kbType = proxy.keyboardType {
            switch kbType {
            case .numberPad, .decimalPad, .phonePad, .numbersAndPunctuation:
                if session?.isComposing == false {
                    keyGrid.page = .numeric
                }
            case .URL, .emailAddress:
                if session?.isComposing == false {
                    session?.inputMode = .englishASCII
                }
            default:
                break
            }
        }
        syncModeUI()
    }

    internal static func resolveExternalHostTopPadding(
        from hostSnap: LokeyHostGeometrySnapshot?,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CGFloat? {
        guard let hostSnap, hostSnap.isHostActive else { return nil }
        let age = nowUptime - hostSnap.updatedAtUptime
        guard age >= -1.0 && age < 12.0 else { return nil }
        return min(max(CGFloat(hostSnap.hostTopPadding), 0.0), KeyboardTheme.iOS26RoundedHostTopPadding)
    }

    private func refreshCachedHostTopPadding() {
        cachedExternalHostTopPadding = nil
    }

    internal static func resolveEffectiveHostTopPadding(
        override: CGFloat?,
        isExtensionProcess: Bool,
        referenceWidth: CGFloat,
        cachedExternalPadding: CGFloat?,
        didActivateSystemKeyboardLayout: Bool = false,
        isiOS26OrNewer: Bool
    ) -> CGFloat {
        if let override {
            return min(max(override, 0.0), KeyboardTheme.iOS26RoundedHostTopPadding)
        }
        return 0.0
    }

    private func effectiveHostTopPadding() -> CGFloat {
        let scr = effectiveScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        let isiOS26OrNewer: Bool
        if #available(iOS 26.0, *) {
            isiOS26OrNewer = true
        } else {
            isiOS26OrNewer = false
        }
        return Self.resolveEffectiveHostTopPadding(
            override: overrideHostTopPaddingForTesting,
            isExtensionProcess: isRunningInExtensionProcess,
            referenceWidth: refWidth,
            cachedExternalPadding: cachedExternalHostTopPadding,
            didActivateSystemKeyboardLayout: Self.didActivateSystemKeyboardLayoutInProcess,
            isiOS26OrNewer: isiOS26OrNewer
        )
    }

    internal func effectiveScreenSize() -> CGSize {
        if let overrideScreenSizeForTesting {
            return overrideScreenSizeForTesting
        }
        if let winScreen = view.window?.windowScene?.screen.bounds.size,
           winScreen.width > 0.0,
           winScreen.height > 0.0 {
            return winScreen
        }
        if isRunningInExtensionProcess || view.window != nil {
            return UIScreen.main.bounds.size
        }
        return .zero
    }

    @discardableResult
    private func syncChildHostScreenSize() -> CGSize {
        let scr = effectiveScreenSize()
        keyGrid.hostScreenSize = scr
        candidateBar.hostScreenSize = scr
        return scr
    }

    private func desiredCandidateBarHeight() -> CGFloat {
        let scr = syncChildHostScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        return KeyboardTheme.portraitCandidateBarHeight(
            forWidth: refWidth,
            hostTopPadding: effectiveHostTopPadding(),
            screenSize: scr
        )
    }

    private func desiredKeyboardHeight() -> CGFloat {
        let scr = syncChildHostScreenSize()
        let refWidth = view.bounds.width > 0 ? view.bounds.width : (scr.width > 0 ? scr.width : UIScreen.main.bounds.width)
        let profile = KeyboardTheme.layoutProfile(forWidth: refWidth, screenSize: scr)
        let isLandscape = (profile == .regularLandscape)
        let topPad = effectiveHostTopPadding()
        if isEmojiKeyboardActive {
            return KeyboardTheme.emojiKeyboardHeight(
                forWidth: refWidth,
                isLandscape: isLandscape,
                hostTopPadding: topPad,
                screenSize: scr
            )
        }
        return KeyboardTheme.portraitKeyboardHeight(
            forWidth: refWidth,
            hostTopPadding: topPad,
            screenSize: scr
        )
    }

    private func updateKeyboardHeightConstraint(forceHostLayoutNotify: Bool = false, inLayoutPass: Bool = false) {
        var didMutate = false
        let target = desiredKeyboardHeight()
        if let hc = heightConstraint, abs(hc.constant - target) > 0.25 {
            hc.constant = target
            didMutate = true
        }
        let targetBarH = desiredCandidateBarHeight()
        expandedGrid.headerBarHeight = targetBarH
        if let cbhc = candidateBarHeightConstraint, abs(cbhc.constant - targetBarH) > 0.25 {
            cbhc.constant = targetBarH
            didMutate = true
        }

        let vb = view.bounds
        let hasHeightMismatch = vb.width > 40.0
            && vb.height > 40.0
            && vb.height <= 360.0
            && abs(vb.height - target) > 1.5
        let mismatchSig = hasHeightMismatch
            ? String(format: "%.1fx%.1f->%.1f|win=%d", vb.width, vb.height, target, view.window != nil ? 1 : 0)
            : ""
        let shouldNotifyForMismatch: Bool
        if hasHeightMismatch && mismatchSig != lastNotifiedHostHeightMismatchSignature {
            lastNotifiedHostHeightMismatchSignature = mismatchSig
            shouldNotifyForMismatch = true
        } else {
            if !hasHeightMismatch {
                lastNotifiedHostHeightMismatchSignature = ""
            }
            shouldNotifyForMismatch = false
        }

        if didMutate || forceHostLayoutNotify || shouldNotifyForMismatch {
            candidateBar.setNeedsLayout()
            keyGrid.setNeedsLayout()
            view.setNeedsUpdateConstraints()
            view.setNeedsLayout()

            let canNotifyHostWindow = view.window != nil || onHostInputViewLayoutInvalidatedForTesting != nil
            if canNotifyHostWindow && (isRunningInExtensionProcess || shouldNotifyForMismatch || forceHostLayoutNotify) {
                inputView?.invalidateIntrinsicContentSize()
                inputView?.setNeedsUpdateConstraints()
                inputView?.setNeedsLayout()
                onHostInputViewLayoutInvalidatedForTesting?()
            }

            if (isRunningInExtensionProcess || onHostInputViewLayoutInvalidatedForTesting != nil)
                && shouldNotifyForMismatch
                && canNotifyHostWindow
                && !isHostResizeRetryScheduled
                && !isDisappearing
                && !pendingGlobeSwitchDeparture {
                isHostResizeRetryScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isHostResizeRetryScheduled = false
                    guard (self.view.window != nil || self.onHostInputViewLayoutInvalidatedForTesting != nil),
                          !self.isDisappearing,
                          !self.pendingGlobeSwitchDeparture else { return }
                    let retryTarget = self.desiredKeyboardHeight()
                    if self.view.bounds.width > 40.0,
                       self.view.bounds.height > 40.0,
                       self.view.bounds.height <= 360.0,
                       abs(self.view.bounds.height - retryTarget) > 1.5 {
                        self.heightConstraint?.constant = retryTarget
                        self.view.setNeedsUpdateConstraints()
                        self.view.setNeedsLayout()
                        self.inputView?.invalidateIntrinsicContentSize()
                        self.inputView?.setNeedsUpdateConstraints()
                        self.inputView?.setNeedsLayout()
                        self.onHostInputViewLayoutInvalidatedForTesting?()
                    }
                }
            }
        }
    }

    private func recordLiveGeometryIfNeeded() {
        guard LokeyDiagnosticLogger.shared.canRecordInteractions else {
            return
        }
        let vb = view.bounds
        guard vb.height <= 420.0 else { return }
        let cb = candidateBar.frame
        let kg = keyGrid.frame
        let pad = effectiveHostTopPadding()
        let sig = GeometrySignature(
            viewSize: vb.size,
            barHeight: cb.height,
            gridHeight: kg.height,
            hostTopPadding: pad
        )
        guard sig != lastLoggedGeometrySignature else { return }
        lastLoggedGeometrySignature = sig
        let screenRect: CGRect = if let win = view.window {
            view.convert(vb, to: win.windowScene?.screen.coordinateSpace ?? win.screen.coordinateSpace)
        } else {
            .zero
        }
        LokeyDiagnosticLogger.shared.recordLayoutGeometryFast(
            signature: sig,
            screenMinY: screenRect.minY,
            screenMaxY: screenRect.maxY
        )
    }
}

// MARK: - UIInputViewAudioFeedback Adoption

extension KeyboardViewController: UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool {
        true
    }
}
