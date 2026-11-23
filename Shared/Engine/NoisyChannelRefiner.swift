import CoreGraphics
import Foundation

/// Sentence-level noisy-channel second pass for fast two-thumb typing.
///
/// The primary `ViterbiDecoder` intentionally keeps clean, segmentable input literal (`huibuhukadun` stays
/// `会不糊卡顿`) and only repairs local typos inside its syllable lattice. Real fast typing drops whole letters
/// (`hai -> hi`, `lai -> la`, `fangan -> fangn`) or swaps two thumbs, which turns the intended pinyin into a
/// *different* valid string. This pass searches whole-input letter edits (insert / delete / neighbor substitution /
/// transposition), scores every corrected pinyin string with a unigram word lattice over the mmap trie minus an
/// explicit edit cost, and only replaces the first candidate when a corrected reading wins by a clear margin.
/// The winning pinyin is then rendered by a dedicated `ViterbiDecoder` so bigram and `LNLM-v2` context still choose
/// the characters.
///
/// All work is pure CPU over read-only mmap pages; callers run it on the candidate worker queue, never on a touch path.
public final class NoisyChannelRefiner: @unchecked Sendable {
    public struct Costs: Sendable {
        /// One omitted key (`hai -> hi`).
        public var insertion = 400
        /// One extra key. Rare in fast typing compared with omissions, and deleting keys can erase whole particles.
        public var deletion = 720
        /// A repeated key (`shii -> shi`).
        public var duplicateDeletion = 300
        /// Two thumbs landing in reverse order (`fnag -> fang`).
        public var transposition = 380
        /// Floor for a spatial neighbor substitution; the actual touch-model penalty is used when larger.
        public var substitutionFloor = 200
        /// A substitution the touch model did not consider plausible.
        public var farSubstitution = 1100
        /// Extra margin a corrected reading must win by over the decoder's own reading.
        public var acceptMargin = 120
        /// Additional margin when the typed keys already form clean pinyin with a coherent reading.
        public var cleanInputMargin = 260
        /// Per-word cost in the unigram lattice (prefers fewer, longer dictionary words).
        public var wordCost = 60
        /// Lattice-stage slack: alternatives within this distance of the acceptance line still get verified in context.
        public var verifySlack = 220
        /// Number of lattice-ranked alternatives rendered with the full contextual decoder.
        public var verifyCount = 3
        /// Horizontal-neighbor substitution inside an already-corrected reading (no touch point available).
        public var neighborSubstitution = 600
        /// When the typed keys already spell a fluent literal reading, a correction only takes slot #0 when its
        /// contextual gain is at least this plus its own edit cost; otherwise it is offered in slot #1.
        public var literalPromoteBase = 700
        public init() {}
    }

    private struct CleanScoreKey: Hashable, Comparable {
        var w0: UInt64 = 0
        var w1: UInt64 = 0
        var w2: UInt64 = 0
        var w3: UInt64 = 0
        var len: UInt8 = 0

        @inline(__always)
        init?(_ ptr: UnsafePointer<UInt8>, count n: Int) {
            guard n > 0, n <= 48 else { return nil }
            self.len = UInt8(n)
            for i in 0..<n {
                let b = ptr[i]
                guard b >= 0x61 && b <= 0x7A else { return nil }
                let code = UInt64(b - 0x60)
                let shift = (11 - (i % 12)) * 5
                switch i / 12 {
                case 0: w0 |= code << shift
                case 1: w1 |= code << shift
                case 2: w2 |= code << shift
                default: w3 |= code << shift
                }
            }
        }

        @inline(__always)
        static func < (lhs: CleanScoreKey, rhs: CleanScoreKey) -> Bool {
            if lhs.w0 != rhs.w0 { return lhs.w0 < rhs.w0 }
            if lhs.w1 != rhs.w1 { return lhs.w1 < rhs.w1 }
            if lhs.w2 != rhs.w2 { return lhs.w2 < rhs.w2 }
            if lhs.w3 != rhs.w3 { return lhs.w3 < rhs.w3 }
            return lhs.len < rhs.len
        }

        @inline(__always)
        func byte(at index: Int) -> UInt8 {
            let shift = (11 - (index % 12)) * 5
            let word: UInt64
            switch index / 12 {
            case 0: word = w0
            case 1: word = w1
            case 2: word = w2
            default: word = w3
            }
            return UInt8(truncatingIfNeeded: (word >> shift) & 0x1F) &+ 0x60
        }

        func toBytes() -> [UInt8] {
            let n = Int(len)
            var out = [UInt8]()
            out.reserveCapacity(n)
            for i in 0..<n {
                out.append(byte(at: i))
            }
            return out
        }
    }

    public let lexicon: MmapLexicon
    private let userStore: UserLexiconStore
    public var costs = Costs()
    /// Optional diagnostics sink for tuning (never set in production).
    public var trace: ((String) -> Void)?
    /// Renders the chosen pinyin. Separate from the primary decoder so its incremental caches stay intact.
    private let renderer: ViterbiDecoder
    private var scoreCache: [CleanScoreKey: Int] = [:]
    private var cachedUserGeneration: UInt64 = 0
    private var cachedWordCost: Int = 320
    private var cleanBestBuf = [Int](repeating: 0, count: 68)
    private var cleanBackStartBuf = [Int](repeating: -1, count: 68)
    private var cleanBackNodeBuf = [UInt32](repeating: 0, count: 68)
    private var cleanStackBuf: [(node: UInt32, pos: Int, depth: Int)] = []
    private var alignBuf = [Int](repeating: 0, count: 68 * 68)
    private var hypCostBuf = [Int](repeating: 0, count: 48 * 26)
    private struct RefineHistoryEntry {
        let samples: [TouchSample]
        let preedit: String
        let topCandidate: LokeyCandidate
        let precedingContext: String?
        let topicMemory: NeuralSentenceScorer.Vec32
        let settings: LokeySettings
        let result: DecodeResult
    }
    private var recentRefineHistory: [RefineHistoryEntry] = []

    public static let minimumInputLength = 8
    public static let maximumInputLength = 40

    static func prewarmStaticTables() {
        _ = qwertyAdjMask.count
        _ = qwertyNeighborTable.count
        _ = neighborTable.count
        _ = alphabet.count
    }

    public convenience init(lexicon: MmapLexicon, userStore: UserLexiconStore) {
        self.init(lexicon: lexicon, userStore: userStore, lookupCache: ViterbiDecoder.LookupCache())
    }

    init(lexicon: MmapLexicon, userStore: UserLexiconStore, lookupCache: ViterbiDecoder.LookupCache) {
        self.lexicon = lexicon
        self.userStore = userStore
        self.cachedUserGeneration = userStore.cacheGeneration
        self.cachedWordCost = self.costs.wordCost
        self.renderer = ViterbiDecoder(lexicon: lexicon, userStore: userStore, lookupCache: lookupCache)
        self.cleanStackBuf.reserveCapacity(64)
        self.scoreCache.reserveCapacity(512)
    }

    // MARK: - Public entry

    /// Convenience overload accepting a boolean `isUrgentCommit` flag.
    public func refine(
        samples: [TouchSample],
        base: DecodeResult,
        settings: LokeySettings,
        spatialModel: SpatialTouchModel,
        precedingContext: String?,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero,
        precomputedHyps: [[KeyHypothesis]]? = nil,
        isCancelled: () -> Bool = { false },
        isPastDeadline: () -> Bool = { false },
        isUrgentCommit: Bool
    ) -> DecodeResult {
        refine(
            samples: samples,
            base: base,
            settings: settings,
            spatialModel: spatialModel,
            precedingContext: precedingContext,
            topicMemory: topicMemory,
            precomputedHyps: precomputedHyps,
            isCancelled: isCancelled,
            isPastDeadline: isPastDeadline,
            isUrgentCommit: { isUrgentCommit }
        )
    }

    /// Returns `base` with a corrected sentence promoted to `#0`, or `base` unchanged.
    /// `isCancelled` aborts immediately when a newer keystroke replaces this job;
    /// `isPastDeadline` stops non-essential deeper search when Space/commit needs an immediate result.
    public func refine(
        samples: [TouchSample],
        base: DecodeResult,
        settings: LokeySettings,
        spatialModel: SpatialTouchModel,
        precedingContext: String?,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero,
        precomputedHyps: [[KeyHypothesis]]? = nil,
        isCancelled: () -> Bool = { false },
        isPastDeadline: () -> Bool = { false },
        isUrgentCommit: () -> Bool = { false }
    ) -> DecodeResult {
        guard settings.enableSpatialCorrection else { return base }
        let n = samples.count
        guard n >= Self.minimumInputLength, n <= Self.maximumInputLength else { return base }
        guard let top = base.candidates.first else { return base }
        if !isUrgentCommit(),
           let hit = recentRefineHistory.last(where: {
               $0.samples == samples
                   && $0.preedit == base.preeditDisplay
                   && $0.topCandidate == top
                   && $0.precedingContext == precedingContext
                   && $0.topicMemory == topicMemory
                   && $0.settings == settings
           }) {
            return hit.result
        }
        let refined = refineUncached(
            samples: samples,
            base: base,
            top: top,
            settings: settings,
            spatialModel: spatialModel,
            precedingContext: precedingContext,
            topicMemory: topicMemory,
            precomputedHyps: precomputedHyps,
            isCancelled: isCancelled,
            isPastDeadline: isPastDeadline,
            isUrgentCommit: isUrgentCommit
        )
        if !isCancelled() && !isUrgentCommit() {
            if let dupIdx = recentRefineHistory.firstIndex(where: {
                $0.samples == samples
                    && $0.preedit == base.preeditDisplay
                    && $0.precedingContext == precedingContext
                    && $0.topicMemory == topicMemory
            }) {
                recentRefineHistory.remove(at: dupIdx)
            } else if recentRefineHistory.count >= 24 {
                recentRefineHistory.removeFirst()
            }
            recentRefineHistory.append(
                RefineHistoryEntry(
                    samples: samples,
                    preedit: base.preeditDisplay,
                    topCandidate: top,
                    precedingContext: precedingContext,
                    topicMemory: topicMemory,
                    settings: settings,
                    result: refined
                )
            )
        }
        return refined
    }

    private func refineUncached(
        samples: [TouchSample],
        base: DecodeResult,
        top: LokeyCandidate,
        settings: LokeySettings,
        spatialModel: SpatialTouchModel,
        precedingContext: String?,
        topicMemory: NeuralSentenceScorer.Vec32,
        precomputedHyps: [[KeyHypothesis]]?,
        isCancelled: () -> Bool,
        isPastDeadline: () -> Bool,
        isUrgentCommit: () -> Bool
    ) -> DecodeResult {
        let n = samples.count
        var typed: [UInt8] = []
        typed.reserveCapacity(n)
        for s in samples {
            // Uppercase, apostrophes and anything outside a-z express explicit intent: never rewrite them.
            guard let a = s.primaryChar.asciiValue, a >= 0x61, a <= 0x7A else { return base }
            typed.append(a)
        }
        // Personal phrases, English, emoji and raw input already reflect explicit user intent.
        switch top.kind {
        case .sentence, .lexiconPhrase:
            if top.text.contains(where: { $0.isASCII && $0.isLetter }) {
                return base
            }
        default:
            return base
        }
        if isCancelled() { return base }
        let refineStartNs = DispatchTime.now().uptimeNanoseconds
        let urgentCommit = isUrgentCommit()
        let typedIsClean = typed.withUnsafeBufferPointer { buf -> Bool in
            guard let ptr = buf.baseAddress else { return false }
            return lexicon.canSegmentCleanlyPointer(ptr, count: n)
        }
        let preDecoderPinyin = top.consumedInputCount == n ? Array(top.matchedSyllables.joined().utf8) : []
        let preLiteral = top.consumedInputCount == n && (
            (typedIsClean && preDecoderPinyin == typed)
                || Self.matchesLiteralWithErhua(typed: typed, syllables: top.matchedSyllables)
        )
        #if DEBUG
        let localSoftBudgetNs: UInt64 = 400_000_000
        let localHardBudgetNs: UInt64 = 600_000_000
        #else
        let localSoftBudgetNs: UInt64 = {
            if urgentCommit { return 1_050_000 }
            if typedIsClean && preLiteral && n <= 15 { return 1_150_000 }
            if typedIsClean && preLiteral && n <= 24 { return 1_500_000 }
            if typedIsClean && n <= 15 { return 2_400_000 }
            return 4_000_000
        }()
        let localHardBudgetNs: UInt64 = {
            if urgentCommit { return 1_250_000 }
            if typedIsClean && preLiteral && n <= 15 { return 1_850_000 }
            if typedIsClean && preLiteral && n <= 24 { return 2_300_000 }
            if typedIsClean && n <= 15 { return 3_500_000 }
            return n >= 20 ? 6_000_000 : 5_200_000
        }()
        #endif
        @inline(__always)
        func softExpired() -> Bool {
            isPastDeadline() || (DispatchTime.now().uptimeNanoseconds &- refineStartNs) >= localSoftBudgetNs
        }
        @inline(__always)
        func cancelOrHardExpired() -> Bool {
            isCancelled() || (DispatchTime.now().uptimeNanoseconds &- refineStartNs) >= localHardBudgetNs
        }
        let resolvedHyps = (precomputedHyps?.count == n) ? precomputedHyps : nil
        var lazyHyps: [[KeyHypothesis]?]? = nil
        func hypAt(_ i: Int) -> [KeyHypothesis] {
            if let pre = resolvedHyps {
                return pre[i]
            }
            if let existing = lazyHyps?[i] {
                return existing
            }
            if lazyHyps == nil {
                lazyHyps = Array<[KeyHypothesis]?>(repeating: nil, count: n)
            }
            let h = spatialModel.hypotheses(
                for: samples[i],
                enabled: true,
                useAdaptiveCalibration: settings.enableAdaptiveTouchCalibration,
                maxCandidates: 7
            )
            lazyHyps?[i] = h
            return h
        }
        let preActivePrefixTail = !preLiteral
            && (!typedIsClean || n <= 13 || (n <= 16 && (preDecoderPinyin.count - n) == 1))
            && top.consumedInputCount == n
            && preDecoderPinyin.count > n
            && (preDecoderPinyin.count - n) <= 4
            && preDecoderPinyin.starts(with: typed)
        let preMixedJianpin = !preLiteral
            && !typedIsClean
            && Self.matchesMixedJianpinAlignment(typed: typed, syllables: top.matchedSyllables)
        let hasIncompleteConsonantTail: Bool = {
            guard !Self.canEndMandarinSyllable(typed[n - 1]),
                  top.consumedInputCount == n else { return false }
            if preDecoderPinyin.count > n && !preMixedJianpin {
                return true
            }
            guard n >= 8, let lastSyl = top.matchedSyllables.last, lastSyl.utf8.first == typed[n - 1] else {
                return false
            }
            if lastSyl.utf8.count >= 2 {
                return true
            }
            if top.matchedSyllables.count >= 3 {
                let prevSyl = top.matchedSyllables[top.matchedSyllables.count - 2]
                let lastChar = Character(UnicodeScalar(typed[n - 1]))
                if lexicon.prefixToSyllableIDs[prevSyl + String(lastChar)] != nil {
                    return false
                }
                let lastHyps = hypAt(n - 1)
                if lastHyps.contains(where: {
                    $0.penaltyQ8 <= 220 && lexicon.prefixToSyllableIDs[prevSyl + String($0.char)] != nil
                }) {
                    return false
                }
                let prefixClean = typed.withUnsafeBufferPointer { buf -> Bool in
                    guard let ptr = buf.baseAddress else { return false }
                    return lexicon.canSegmentCleanlyPointer(ptr, count: n - 1)
                }
                if prefixClean { return true }
            }
            return false
        }()

        let lntrActive = lexicon.neuralLM.isTypoRerankerLoaded
        let hasMidVowelIsland = top.matchedSyllables.dropFirst().contains(where: { $0 == "o" || $0 == "e" })
        let isFracturedVowelIslandLiteral = preLiteral
            && hasMidVowelIsland
            && top.matchedSyllables.count >= 4
            && top.scoreQ8 < top.matchedSyllables.count * -1420
        let effectiveLiteral = (preLiteral && !(lntrActive && isFracturedVowelIslandLiteral))
            || preActivePrefixTail
            || hasIncompleteConsonantTail
        if effectiveLiteral && n >= 22 && top.scoreQ8 >= top.matchedSyllables.count * -1820 {
            return base
        }
        if hasIncompleteConsonantTail && (hypAt(n - 1).first?.penaltyQ8 ?? 0) <= 180 {
            return base
        }
        let activePrefixGateCandidate = preActivePrefixTail && typedIsClean && top.scoreQ8 >= top.matchedSyllables.count * -1050
        let cleanLexPhraseGate = (preLiteral || (
            typedIsClean
                && top.kind == .lexiconPhrase
                && top.matchedSyllables.count >= 2
                && abs(preDecoderPinyin.count - n) <= 1
        )) && n >= 8 && top.kind == .lexiconPhrase && top.scoreQ8 >= top.matchedSyllables.count * -780
        let cleanSentenceGateCandidate = cleanLexPhraseGate || (
            preLiteral && n >= 8 && top.kind == .sentence
                && top.matchedSyllables.count >= 3
                && top.scoreQ8 >= top.matchedSyllables.count * -680
        )
        var precomputedMaxDrift: Int? = nil
        if activePrefixGateCandidate || cleanSentenceGateCandidate {
            var drift = 0
            for i in 0..<n {
                drift = max(drift, hypAt(i).first?.penaltyQ8 ?? 0)
            }
            precomputedMaxDrift = drift
            if activePrefixGateCandidate && drift <= 65 {
                return base
            }
            if cleanSentenceGateCandidate && drift <= 45 {
                return base
            }
        }

        // A second omission can leave *both* intermediate one-edit strings unsegmentable.
        // Test the compact whole-phrase inventory directly before the lattice rejects them,
        // skipping clean active syllable-prefix tails and mid-syllable bare-consonant tails.
        let skipSpokenForActiveTail = hasIncompleteConsonantTail || (
            preActivePrefixTail
                && typedIsClean
                && top.scoreQ8 >= top.matchedSyllables.count * -1250
        )
        if !skipSpokenForActiveTail,
           let spoken = spokenCorrection(typed: typed, samples: samples, top: top, preLiteral: preLiteral,
                                         spatialModel: spatialModel, hypAt: hypAt,
                                         isCancelled: { cancelOrHardExpired() || softExpired() }) {
            if isCancelled() { return base }
            return DecodeResult(preeditDisplay: base.preeditDisplay,
                                candidates: [spoken] + base.candidates.filter { $0.text != spoken.text })
        }
        guard top.consumedInputCount == n, !top.matchedSyllables.isEmpty else { return base }
        if cancelOrHardExpired() { return base }
        let currentUserGen = userStore.cacheGeneration
        if cachedUserGeneration != currentUserGen || cachedWordCost != costs.wordCost || scoreCache.count > 2048 {
            scoreCache.removeAll(keepingCapacity: true)
            cachedUserGeneration = currentUserGen
            cachedWordCost = costs.wordCost
        }

        let hyps: [[KeyHypothesis]] = resolvedHyps ?? (0..<n).map { hypAt($0) }
        buildHypCostTable(hyps: hyps)

        // Reading chosen by the primary decoder, expressed as letters and charged for the edits it implies.
        let decoderPinyin = preDecoderPinyin
        guard decoderPinyin.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return base }
        let isActivePrefixTail = preActivePrefixTail
        let decoderCost: Int
        if isActivePrefixTail {
            // Active trailing syllable prefix completion (`huangshula -> huangshulang`) is normal in-progress typing,
            // not multi-key omission typos; charge only the lightweight prefix-completion penalty.
            decoderCost = 170 + (decoderPinyin.count - n) * 35
        } else {
            decoderCost = alignmentCostFast(typed: typed, intended: decoderPinyin, hypsCount: hyps.count)
        }
        // A primary mixed-initial reading can contain a bare consonant, for which a clean
        // lattice score does not exist. Its full-input primary score already includes the
        // channel penalty; still let complete spellings compete on the worker.
        let cleanReferenceScore = cleanScore(decoderPinyin)
        let decoderLattice = cleanReferenceScore ?? (top.scoreQ8 + decoderCost)

        let literal = preLiteral && !(lntrActive && isFracturedVowelIslandLiteral)
        let maxPrimaryDrift = precomputedMaxDrift ?? hyps.reduce(0) { acc, list in
            max(acc, list.first?.penaltyQ8 ?? 0)
        }
        let zeroDriftPrimary = maxPrimaryDrift == 0 && zip(samples, hyps).allSatisfy { s, list in
            list.first?.char == s.primaryChar
        }

        let isMixedJianpinAligned = !effectiveLiteral
            && !typedIsClean
            && preMixedJianpin
        let decoderTotal = isMixedJianpinAligned
            ? max(decoderLattice - decoderCost, top.scoreQ8)
            : (decoderLattice - decoderCost)
        let inspectSpelling = !effectiveLiteral && (3...9).contains(top.text.count) && n <= 32
        let margin = costs.acceptMargin + (effectiveLiteral ? costs.cleanInputMargin : 0)
        let classicalFloor = (effectiveLiteral && n >= 18)
            ? (decoderTotal + costs.literalPromoteBase - costs.verifySlack)
            : (decoderTotal + margin - costs.verifySlack)
        let collectFloor = inspectSpelling ? (decoderTotal - 2200) : classicalFloor

        // Level 1: single edits of the typed keys and of the decoder's own reading. Search charges the
        // accumulated edit cost; exact Damerau alignment is computed only for the few verified finalists.
        var best: [CleanScoreKey: (total: Int, cost: Int)] = [:]
        let skipSubFloorLevel1 = effectiveLiteral || (urgentCommit && n > 16)
        let maxSeedCost = costs.insertion + 160
        func consider(_ candidate: UnsafeBufferPointer<UInt8>, cost: Int, isLevel2: Bool) {
            guard let ptr = candidate.baseAddress else { return }
            if candidate.count == decoderPinyin.count && candidate.elementsEqual(decoderPinyin) { return }
            guard let key = CleanScoreKey(ptr, count: candidate.count) else { return }
            if let existing = best[key], existing.cost <= cost { return }
            guard let lattice = computeCleanScorePointer(ptr, count: candidate.count, alreadySegmented: true, keyHint: key) else { return }
            let total = lattice - cost
            let mustBeatCollectFloor = isLevel2 || skipSubFloorLevel1 || cost > maxSeedCost
            if mustBeatCollectFloor && total <= collectFloor { return }
            best[key] = (total, cost)
        }
        forEachEdit(of: typed, hyps: hyps, isCancelled: cancelOrHardExpired) { alt, c in consider(alt, cost: c, isLevel2: false) }
        if isCancelled() { return base }
        if decoderPinyin != typed && decoderCost < 2 * costs.insertion + 100
            && !(isActivePrefixTail && typedIsClean) && !softExpired() && !cancelOrHardExpired() && !urgentCommit {
            forEachEdit(of: decoderPinyin, hyps: nil, isCancelled: cancelOrHardExpired) { alt, c in consider(alt, cost: decoderCost + c, isLevel2: false) }
        }
        if isCancelled() { return base }

        // Readings on either side of a word boundary can each need a missing letter.
        // Neither single repair has to yield a clean *whole* sentence.
        if !typedIsClean && !isActivePrefixTail && n <= 26 && (best.isEmpty || cleanReferenceScore == nil)
            && !cancelOrHardExpired() && (!softExpired() || best.isEmpty) {
            for (spelling, total) in splitOmissions(typed, isCancelled: cancelOrHardExpired) {
                guard let key = spelling.withUnsafeBufferPointer({ buf -> CleanScoreKey? in
                    guard let p = buf.baseAddress else { return nil }
                    return CleanScoreKey(p, count: buf.count)
                }) else { continue }
                if total > (best[key]?.total ?? Int.min) {
                    best[key] = (total, 2 * costs.insertion)
                }
            }
            if isCancelled() { return base }
        }

        // Level 2: one more edit on the strongest clean level-1 readings (two independent slips in one sentence).
        // Skip Level 2 on already-literal / active-tail clean inputs and cap seed cost to single-edit repairs (`<= insertion + 160`)
        // so 2-edit `decoderPinyin` candidates never stack into 3-edit rewrites.
        let skipLevel2PreDecodedClean = typedIsClean && n <= 15 && decoderPinyin != typed
        if !effectiveLiteral && !skipLevel2PreDecodedClean && !cancelOrHardExpired() && (!softExpired() || (urgentCommit && n <= 16)) {
            let seedCap = urgentCommit ? 2 : (typedIsClean ? 2 : (n >= 18 ? 2 : 3))
            let sortedSeeds = best.filter { $0.value.cost <= maxSeedCost && (Int($0.key.len) >= n || $0.value.cost <= costs.duplicateDeletion) }
                .sorted { $0.value.total > $1.value.total || ($0.value.total == $1.value.total && $0.key < $1.key) }
            var seeds: [(key: CleanScoreKey, bytes: [UInt8], cost: Int)] = sortedSeeds.prefix(seedCap).map {
                ($0.key, $0.key.toBytes(), $0.value.cost)
            }
            if !urgentCommit && !typedIsClean, let topSeedTotal = sortedSeeds.first?.value.total {
                let decFloor = decoderTotal > Int.min + 1300 ? decoderTotal - 1300 : Int.min
                let topFloor = topSeedTotal > Int.min + 1400 ? topSeedTotal - 1400 : Int.min
                let seedFloor = max(decFloor, topFloor)
                let maxSeedsTotal = n >= 18 ? 3 : 4
                for extra in sortedSeeds where Int(extra.key.len) == n && extra.value.cost < costs.insertion && extra.value.total >= seedFloor {
                    if seeds.count >= maxSeedsTotal { break }
                    if !seeds.contains(where: { $0.key == extra.key }) {
                        seeds.append((extra.key, extra.key.toBytes(), extra.value.cost))
                    }
                }
                var transSlotsUsed = 0
                let transCap = n >= 18 ? 1 : 2
                for extra in sortedSeeds where Int(extra.key.len) == n && extra.value.total >= seedFloor && Self.adjacentTranspositionIndex(typed, extra.key) != nil {
                    if transSlotsUsed >= transCap { break }
                    if !seeds.contains(where: { $0.key == extra.key }) {
                        seeds.append((extra.key, extra.key.toBytes(), extra.value.cost))
                        transSlotsUsed += 1
                    }
                }
            }
            for item in seeds {
                if cancelOrHardExpired() || (softExpired() && !urgentCommit) { break }
                let swapPos = Self.adjacentTranspositionIndex(typed, item.key)
                forEachEdit(
                    of: item.bytes,
                    hyps: nil,
                    transposedPairIndex: swapPos,
                    isCancelled: { cancelOrHardExpired() || (!urgentCommit && softExpired()) }
                ) { alt, c in
                    consider(alt, cost: item.cost + c, isLevel2: true)
                }
                if isCancelled() { return base }
            }
        }

        let verifyLimit: Int
        if urgentCommit {
            verifyLimit = inspectSpelling ? (typedIsClean ? 3 : 6) : 2
        } else if typedIsClean {
            verifyLimit = inspectSpelling ? (softExpired() ? 3 : 5) : costs.verifyCount
        } else {
            verifyLimit = inspectSpelling ? (softExpired() ? 4 : 5) : costs.verifyCount
        }
        var rankedList = best.filter { $0.value.total > collectFloor }
            .sorted { $0.value.total > $1.value.total || ($0.value.total == $1.value.total && $0.key < $1.key) }
        if inspectSpelling, let topLat = rankedList.first?.value.total {
            let relFloor = max(decoderTotal, topLat) - 1280
            if relFloor > collectFloor {
                rankedList.removeAll { $0.value.total < relFloor }
            }
        }
        let keepClassical = min(costs.verifyCount, rankedList.count)
        if inspectSpelling, rankedList.count > keepClassical + 1, !urgentCommit, let refPrior = lexicon.spellingLikelihood(top.text) {
            let refLen = top.text.count
            let tailEnd = min(rankedList.count, keepClassical + 24)
            var tailRescored: [(item: (key: CleanScoreKey, value: (total: Int, cost: Int)), preScore: Int)] = []
            tailRescored.reserveCapacity(tailEnd - keepClassical)
            for item in rankedList[keepClassical..<tailEnd] {
                var preScore = item.value.total
                if let (uText, uTrail) = cleanUnigramSentence(item.key.toBytes()),
                   let ll = lexicon.spellingLikelihood(uText) {
                    let delta = ll - refPrior + 850 * (uText.count - refLen)
                    let clampedDelta = max(-2200, min(2200, delta))
                    let bnd = lexicon.spellingBoundary(uText, trailingWord: uTrail)
                    let sharedBnd = uTrail.map { tw in
                        let pfx = uText.dropLast(tw.count)
                        return pfx.count >= 2 && top.text.hasPrefix(pfx)
                    } ?? false
                    let bndGain = min(1800, max(-1800, (sharedBnd ? 5 : 1) * bnd))
                    preScore += clampedDelta + bndGain
                }
                tailRescored.append((item, preScore))
            }
            tailRescored.sort {
                if $0.preScore != $1.preScore { return $0.preScore > $1.preScore }
                if $0.item.value.total != $1.item.value.total { return $0.item.value.total > $1.item.value.total }
                return $0.item.key < $1.item.key
            }
            rankedList.replaceSubrange(keepClassical..<tailEnd, with: tailRescored.map(\.item))
        }
        let ranked = rankedList.prefix(verifyLimit)
        guard inspectSpelling || !ranked.isEmpty else { return base }

        // Verify in context: render both readings with the full decoder (bigrams + LNLM-v2) on exact center taps
        // and compare sentence scores on the same scale, charged with the same channel costs.
        var cleanSettings = settings
        cleanSettings.enableSpatialCorrection = false
        cleanSettings.enableEmojiCandidates = false
        if isCancelled() { return base }

        let primaryIsJianpinSubsequence = !effectiveLiteral
            && ((decoderPinyin.count >= typed.count + 2 && Self.isSubsequence(typed, of: decoderPinyin))
                || isMixedJianpinAligned)

        // Batch-decode `decoderPinyin` (if needed) and `ranked` in lexicographical order so `renderer`'s
        // incremental prefix lattice + Viterbi DP cache shares common prefixes across consecutive spellings!
        struct VerifyTask {
            let rankIndex: Int // -1 for reference `decoderPinyin`
            let bytes: [UInt8]
            let latticeTotal: Int
        }
        var tasks: [VerifyTask] = []
        tasks.reserveCapacity(ranked.count + 1)
        var renderedRefResult: DecodeResult? = ((urgentCommit && effectiveLiteral) || (preLiteral && zeroDriftPrimary)) ? base : nil
        if cleanReferenceScore != nil && renderedRefResult == nil {
            tasks.append(VerifyTask(rankIndex: -1, bytes: decoderPinyin, latticeTotal: decoderTotal))
        }
        for (idx, item) in ranked.enumerated() {
            tasks.append(VerifyTask(rankIndex: idx, bytes: item.key.toBytes(), latticeTotal: item.value.total))
        }
        tasks.sort {
            let aPri = $0.rankIndex <= 3
            let bPri = $1.rankIndex <= 3
            if aPri != bPri { return aPri }
            return $0.bytes.lexicographicallyPrecedes($1.bytes)
        }

        var renderedByRank = Array<DecodeResult?>(repeating: nil, count: ranked.count)
        for task in tasks {
            if isCancelled() { return base }
            if cancelOrHardExpired() { continue }
            if task.rankIndex >= 1 && !urgentCommit && softExpired() { continue }
            let spelling = String(decoding: task.bytes, as: UTF8.self)
            let res = renderer.decode(
                spelling,
                settings: cleanSettings,
                precedingContext: precedingContext,
                topicMemory: topicMemory,
                fastCleanSentenceOnly: true,
                skipStage5CAssociations: true,
                isCancelled: cancelOrHardExpired,
                isUrgentCommit: { urgentCommit }
            )
            if task.rankIndex == -1 {
                renderedRefResult = res
            } else {
                renderedByRank[task.rankIndex] = res
            }
        }

        let renderedReference: LokeyCandidate? = {
            guard let r = renderedRefResult, let c = r.candidates.first,
                  c.consumedInputCount == decoderPinyin.count,
                  c.kind == .sentence || c.kind == .lexiconPhrase || c.kind == .userPhrase,
                  !c.matchedSyllables.isEmpty,
                  c.text.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else { return nil }
            return c
        }()
        let reference = renderedReference ?? top
        let rawReferenceTotal = renderedReference.map { $0.scoreQ8 - decoderCost } ?? top.scoreQ8
        let hasPrimaryGrazeDeletion = (decoderPinyin.count == n - 1)
        let referenceTotal = (isMixedJianpinAligned || hasPrimaryGrazeDeletion)
            ? max(rawReferenceTotal, top.scoreQ8)
            : rawReferenceTotal
        var incumbentTotal = referenceTotal
        var rawIncumbentTotal = referenceTotal
        var classical: (candidate: LokeyCandidate, total: Int, rawTotal: Int, cost: Int)?
        var surfaces: [String: (candidate: LokeyCandidate, score: Int, cost: Int)] = [:]
        let allowedSylSlack = (cleanReferenceScore == nil || (lntrActive && isFracturedVowelIslandLiteral)) ? 1 : 0
        var typoFeatCache: [String: [Float]] = [:]

        func typoFeatures(for cand: LokeyCandidate, readingBytes: [UInt8], cost: Int) -> [Float] {
            let cacheKey = "\(cand.text)\0\(cost)"
            if let existing = typoFeatCache[cacheKey] {
                return existing
            }
            let feat = computeTypoCandidateFeatures(
                cand: cand,
                readingBytes: readingBytes,
                cost: cost,
                typed: typed,
                hyps: hyps,
                maxPrimaryDrift: maxPrimaryDrift,
                precedingContext: precedingContext,
                topicMemory: topicMemory
            )
            typoFeatCache[cacheKey] = feat
            return feat
        }

        let refTypoFeat: [Float] = lntrActive
            ? typoFeatures(for: reference, readingBytes: decoderPinyin, cost: decoderCost)
            : []

        func collect(_ c: LokeyCandidate, score: Int, cost: Int) {
            guard inspectSpelling, c.kind == .sentence || c.kind == .lexiconPhrase,
                  c.matchedSyllables.allSatisfy({ lexicon.syllableToID[$0] != nil }),
                  c.matchedSyllables.count >= reference.matchedSyllables.count - allowedSylSlack,
                  score > (surfaces[c.text]?.score ?? Int.min) else { return }
            surfaces[c.text] = (c, score, cost)
        }

        if inspectSpelling {
            for c in base.candidates.prefix(8) where c.consumedInputCount == n {
                let reading = Array(c.matchedSyllables.joined().utf8)
                collect(c, score: c.scoreQ8, cost: alignmentCostFast(typed: typed, intended: reading, hypsCount: hyps.count))
            }
        }
        let confirmedPrimary = renderedReference?.text == top.text && decoderCost >= costs.transposition
        for (index, item) in ranked.enumerated() {
            guard let reading = renderedByRank[index] else { continue }
            let alt = item.key.toBytes()
            let cost = alignmentCostFast(typed: typed, intended: alt, hypsCount: hyps.count)
            let spelling = String(decoding: alt, as: UTF8.self)
            if let first = reading.candidates.first, index < costs.verifyCount,
               item.value.total > classicalFloor,
               first.consumedInputCount == alt.count, !first.matchedSyllables.isEmpty,
               first.kind == .sentence || first.kind == .lexiconPhrase || first.kind == .userPhrase,
               first.text.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }),
               first.matchedSyllables.count >= reference.matchedSyllables.count - allowedSylSlack {
                let lntrBonus: Int
                if lntrActive && first.text != reference.text {
                    let firstFeat = typoFeatures(for: first, readingBytes: alt, cost: cost)
                    var rawBonus = lexicon.neuralLM.scoreTypoDeltaQ8(challenger: firstFeat, incumbent: refTypoFeat)
                    if decoderCost == 0 && cost > 0 && typedIsClean && !isFracturedVowelIslandLiteral && cleanReferenceScore != nil {
                        rawBonus = min(0, rawBonus)
                    } else if rawBonus < 0, cost <= decoderCost + costs.deletion,
                              let fLL = lexicon.spellingLikelihood(first.text),
                              let rLL = lexicon.spellingLikelihood(reference.text),
                              fLL - rLL >= 1400 {
                        rawBonus = 0
                    }
                    lntrBonus = rawBonus
                } else {
                    lntrBonus = 0
                }
                let rawTotal = first.scoreQ8 - cost
                let total = rawTotal + lntrBonus
                if first.text == top.text {
                    incumbentTotal = max(incumbentTotal, total)
                    rawIncumbentTotal = max(rawIncumbentTotal, rawTotal)
                } else {
                    let extraEditOverConfirmedPrimary = confirmedPrimary && cost >= decoderCost + costs.transposition
                    let effectiveRefTotal = extraEditOverConfirmedPrimary ? max(referenceTotal, top.scoreQ8) : referenceTotal
                    if total > effectiveRefTotal + margin, total > (classical?.total ?? Int.min) {
                        if primaryIsJianpinSubsequence && !Self.isSubsequence(typed, of: alt) && total < referenceTotal + 900 {
                            // Never overwrite an exact mixed-Jianpin subsequence expansion (`yjfalexinbanle -> 已经发了新版了`)
                            // with a non-subsequence key substitution (`引发了新版了`).
                        } else {
                            classical = (first, total, rawTotal, cost)
                        }
                    }
                }
            }
            if inspectSpelling {
                if primaryIsJianpinSubsequence && !Self.isSubsequence(typed, of: alt) && alt.count != typed.count {
                    continue
                }
                for c in reading.candidates.prefix(6) where c.consumedInputCount == alt.count && c.matchedSyllables.joined() == spelling {
                    collect(c, score: c.scoreQ8 - cost, cost: cost)
                }
            }
        }
        let traditional = classical.flatMap { cand -> (candidate: LokeyCandidate, total: Int, rawTotal: Int, cost: Int)? in
            let extraEditOverConfirmedPrimary = confirmedPrimary && cand.cost >= decoderCost + costs.transposition
            let effectiveIncumbent = extraEditOverConfirmedPrimary ? max(incumbentTotal, top.scoreQ8) : incumbentTotal
            return cand.total > effectiveIncumbent + margin ? cand : nil
        }
        let promotes = traditional.map { !literal || $0.total - referenceTotal >= costs.literalPromoteBase + $0.cost } ?? false
        let promoted = promotes ? traditional : nil
        var incumbent = promoted?.candidate ?? top
        // An initial-only primary parse need not be discarded if rendering a
        // single missing letter independently reconstructs the same surface.
        // A second edit in already-explained text needs positive contextual evidence.
        if inspectSpelling, let promoted, let original = surfaces[top.text],
           original.cost <= costs.insertion, promoted.cost >= original.cost + costs.transposition,
           lexicon.spellingBoundary(promoted.candidate.text, trailingWord: promoted.candidate.trailingWord) <= costs.acceptMargin {
            incumbent = top
        }
        var out = [LokeyCandidate]()
        func append(_ c: LokeyCandidate) {
            if !out.contains(where: { $0.text == c.text }) {
                out.append(LokeyCandidate(text: c.text, consumedInputCount: n, matchedSyllables: c.matchedSyllables,
                                          scoreQ8: out.isEmpty ? max(c.scoreQ8, top.scoreQ8) + 1 : c.scoreQ8,
                                          kind: .sentence, trailingWord: c.trailingWord))
            }
        }
        if inspectSpelling, let prior = lexicon.spellingLikelihood(incumbent.text) {
            let entry = surfaces[incumbent.text]
            let baselineScore = incumbent.text == top.text ? rawIncumbentTotal : (promoted?.rawTotal ?? rawIncumbentTotal)
            let score = max(entry?.score ?? Int.min, baselineScore)
            let cost = entry?.cost ?? (promoted?.cost ?? decoderCost)
            let boundary = lexicon.spellingBoundary(incumbent.text, trailingWord: incumbent.trailingWord)
            let incReadingBytes = Array(incumbent.matchedSyllables.joined().utf8)
            let incTypoFeat: [Float] = lntrActive
                ? typoFeatures(for: incumbent, readingBytes: incReadingBytes, cost: cost)
                : []
            var alternatives: [(candidate: LokeyCandidate, gain: Int, cost: Int, boundaryGain: Int)] = []
            for (text, other) in surfaces where text != incumbent.text {
                if other.score <= score - 5200 { continue }
                guard let ll = lexicon.spellingLikelihood(text) else { continue }
                let delta = ll - prior + 850 * (text.count - incumbent.text.count)
                let evidence = lexicon.spellingBoundary(text, trailingWord: other.candidate.trailingWord)
                // If both readings retain the same multi-character prefix, word-boundary
                // evidence directly distinguishes their completions. In other positions
                // the association is only a weak cue.
                let stablePrefix = other.candidate.trailingWord.map { text.dropLast($0.count) }
                let sharedBoundary = stablePrefix.map { $0.count >= 2 && incumbent.text.hasPrefix($0) } ?? false
                let incumbentBoundaryAtSplit: Int = {
                    guard sharedBoundary, let prefix = stablePrefix else { return boundary }
                    let incTail = String(incumbent.text.dropFirst(prefix.count))
                    return incTail.count >= 2 ? lexicon.spellingBoundary(incumbent.text, trailingWord: incTail) : boundary
                }()
                let boundaryDelta = (sharedBoundary ? 5 : 1) * (evidence - incumbentBoundaryAtSplit)
                let clampedDelta = (!sharedBoundary && typedIsClean && !isFracturedVowelIslandLiteral && n <= 10 && cleanReferenceScore != nil && other.score < score + 220)
                    ? max(-2200, min(160, delta))
                    : max(-2200, min(2200, delta))
                let lntrDelta: Int
                if lntrActive {
                    let otherBytes = Array(other.candidate.matchedSyllables.joined().utf8)
                    let otherFeat = typoFeatures(for: other.candidate, readingBytes: otherBytes, cost: other.cost)
                    var rawDelta = lexicon.neuralLM.scoreTypoDeltaQ8(challenger: otherFeat, incumbent: incTypoFeat)
                    if cost == 0 && other.cost > 0 && typedIsClean && !isFracturedVowelIslandLiteral && cleanReferenceScore != nil {
                        rawDelta = min(0, rawDelta)
                    } else if other.cost <= cost + costs.deletion && (ll - prior) >= 1400 {
                        rawDelta = max(0, rawDelta)
                    }
                    lntrDelta = rawDelta
                } else {
                    lntrDelta = 0
                }
                let gain = other.score - score + clampedDelta + min(1800, max(-1800, boundaryDelta)) + lntrDelta
                if gain > -1200 { alternatives.append((other.candidate, gain, other.cost, evidence - boundary)) }
            }
            alternatives.sort { $0.gain != $1.gain ? $0.gain > $1.gain : $0.candidate.text < $1.candidate.text }
            trace?("incumbent \(incumbent.text) cost \(cost) prior \(prior) boundary \(boundary) candidates " +
                alternatives.prefix(12).map { "\($0.candidate.text):\($0.gain)/\($0.cost)/\($0.candidate.trailingWord ?? "-")" }.joined(separator: " "))
            for (altIdx, first) in alternatives.prefix(2).enumerated() {
                if altIdx == 1 {
                    guard out.isEmpty,
                          let skipped = alternatives.first,
                          skipped.candidate.text.count != incumbent.text.count,
                          skipped.candidate.text.count != top.text.count else { break }
                }
                guard first.candidate.text.count == incumbent.text.count
                        || first.candidate.text.count == top.text.count
                        || cleanReferenceScore == nil
                        || (!typedIsClean && first.gain >= 1400 && first.cost <= cost + 480)
                        || (lntrActive && isFracturedVowelIslandLiteral && first.candidate.text.count == top.text.count - 1 && first.gain >= 800),
                      first.cost <= cost + 620 else { continue }
                // When a second edit would alter a different part of the sentence,
                // require independent word-boundary support (or overwhelming >= 1800 gain
                // with strictly adjacent edits) before displacing #0.
                let firstReading = Array(first.candidate.matchedSyllables.joined().utf8)
                let incReading = Array(incumbent.matchedSyllables.joined().utf8)
                let introducesFarSub = alignmentUsesFarSubstitution(typed: typed, intended: firstReading, hypsCount: hyps.count)
                    && !alignmentUsesFarSubstitution(typed: typed, intended: incReading, hypsCount: hyps.count)
                let extraEdit = first.cost >= cost + costs.transposition
                let supportedBoundary = first.boundaryGain > costs.acceptMargin
                let strongAdjacentGain = !introducesFarSub && first.gain >= 1380
                let threshold = first.cost <= cost ? 260 : (supportedBoundary ? 550 : 800)
                let withinCostLimit = first.cost <= cost + costs.insertion || strongAdjacentGain
                if !introducesFarSub && withinCostLimit && first.gain > threshold && (!extraEdit || supportedBoundary || strongAdjacentGain) {
                    append(first.candidate)
                    break
                }
            }
            if out.isEmpty && incumbent.text == top.text { out.append(top) } else { append(incumbent) }
            for other in alternatives.prefix(3) where out.count < 4 {
                if incumbent.text.count >= 5 && other.cost > cost && other.gain < 0 { continue }
                append(other.candidate)
            }
        } else {
            if promotes { append(incumbent) } else { out.append(top) }
        }
        if let traditional { append(traditional.candidate) }
        if out.count == 1 && out[0] == top { return base }
        let inserted = Set(out.map(\.text))
        out.append(contentsOf: base.candidates.filter { !inserted.contains($0.text) })
        return DecodeResult(preeditDisplay: base.preeditDisplay, candidates: out)
    }

    @inline(__always)
    private static func canEndMandarinSyllable(_ b: UInt8) -> Bool {
        b == 0x61 || b == 0x65 || b == 0x69 || b == 0x6F || b == 0x75 || b == 0x76
            || b == 0x6E || b == 0x67 || b == 0x72
    }

    private static func isSubsequence(_ sub: [UInt8], of full: [UInt8]) -> Bool {
        guard !sub.isEmpty, sub.count <= full.count else { return false }
        var idx = 0
        for b in full {
            if b == sub[idx] {
                idx += 1
                if idx == sub.count { return true }
            }
        }
        return false
    }

    private static func matchesMixedJianpinAlignment(typed: [UInt8], syllables: [String]) -> Bool {
        let n = typed.count
        let k = syllables.count
        guard k >= 2, n >= k else { return false }
        var totalFullBytes = 0
        var hasBareInitial = false
        for syl in syllables {
            let cnt = syl.utf8.count
            if cnt == 0 { return false }
            totalFullBytes += cnt
            if cnt == 1 {
                let b0 = syl.utf8.first!
                if b0 != 0x61 && b0 != 0x65 && b0 != 0x6F { hasBareInitial = true }
            } else if cnt == 2 && (syl == "zh" || syl == "ch" || syl == "sh") {
                hasBareInitial = true
            }
        }
        // If no bare initial syllable exists and `n >= totalFullBytes`, no Jianpin initial abbreviation occurred.
        if !hasBareInitial && n >= totalFullBytes { return false }

        func step(_ sIdx: Int, _ pos: Int, _ usedInit: Bool) -> Bool {
            if sIdx == k {
                return pos == n && usedInit
            }
            let remSyls = k - sIdx
            guard n - pos >= remSyls else { return false }
            let utf8 = syllables[sIdx].utf8
            let sbCount = utf8.count
            guard let firstB = utf8.first else { return false }

            // 1. Full syllable match
            if pos + sbCount <= n {
                var idx = utf8.startIndex
                var fullMatch = true
                for off in 0..<sbCount {
                    if typed[pos + off] != utf8[idx] {
                        fullMatch = false
                        break
                    }
                    utf8.formIndex(after: &idx)
                }
                if fullMatch {
                    let isBareInit = (sbCount == 1 && firstB != 0x61 && firstB != 0x65 && firstB != 0x6F)
                        || (sbCount == 2 && (syllables[sIdx] == "zh" || syllables[sIdx] == "ch" || syllables[sIdx] == "sh"))
                    if step(sIdx + 1, pos + sbCount, usedInit || isBareInit) {
                        return true
                    }
                }
            }
            // 2. Erhua `-r`
            if sIdx >= 1 && sbCount == 2 && firstB == 0x65 && typed[pos] == 0x72 {
                let secIdx = utf8.index(after: utf8.startIndex)
                if utf8[secIdx] == 0x72, step(sIdx + 1, pos + 1, usedInit) {
                    return true
                }
            }
            // 3. 2-letter retroflex digraph initial (`zh`, `ch`, `sh`)
            if sbCount >= 2 && (firstB == 0x7A || firstB == 0x63 || firstB == 0x73) && pos + 2 <= n {
                let secIdx = utf8.index(after: utf8.startIndex)
                if utf8[secIdx] == 0x68 && typed[pos] == firstB && typed[pos + 1] == 0x68 {
                    if step(sIdx + 1, pos + 2, true) {
                        return true
                    }
                }
            }
            // 4. 1-letter initial abbreviation
            if sbCount > 1 && typed[pos] == firstB {
                if step(sIdx + 1, pos + 1, true) {
                    return true
                }
            }
            return false
        }

        return step(0, 0, false)
    }

    private static func matchesLiteralWithErhua(typed: [UInt8], syllables: [String]) -> Bool {
        guard syllables.count >= 2 else { return false }
        var pos = 0
        let n = typed.count
        for (idx, syl) in syllables.enumerated() {
            if idx >= 1 && syl == "er" {
                if pos + 1 < n && typed[pos] == 0x65 && typed[pos + 1] == 0x72 {
                    pos += 2
                    continue
                } else if pos < n && typed[pos] == 0x72 {
                    pos += 1
                    continue
                }
                return false
            }
            let utf8 = syl.utf8
            guard pos + utf8.count <= n else { return false }
            for b in utf8 {
                if typed[pos] != b { return false }
                pos += 1
            }
        }
        return pos == n
    }

    private func spokenCorrection(typed: [UInt8], samples: [TouchSample], top: LokeyCandidate, preLiteral: Bool,
                                  spatialModel: SpatialTouchModel, hypAt: (Int) -> [KeyHypothesis],
                                  isCancelled: () -> Bool) -> LokeyCandidate? {
        guard typed.count >= 2, typed.count <= 26 else { return nil }
        let spelling = String(decoding: typed, as: UTF8.self)
        let literal = preLiteral || (
            top.consumedInputCount == typed.count
                && (top.matchedSyllables.joined() == spelling || Self.matchesLiteralWithErhua(typed: typed, syllables: top.matchedSyllables))
        )
        // A full dictionary word, a long literal sentence, or a supported literal clause already explains every tap.
        if literal && (typed.count >= 16 || top.kind == .lexiconPhrase || !lexicon.lookupAssociations(after: "=" + spelling, limit: 1).isEmpty) {
            return nil
        }

        var winner: (hit: MmapLexicon.WordHit, total: Int, isRollover: Bool)?
        var runnerUp = Int.min / 4
        var currentIsRollover = false

        @inline(__always)
        func evalCost(_ missing: Int, _ reading: UnsafeBufferPointer<UInt8>) -> Int? {
            currentIsRollover = false
            if missing == 0 {
                var firstDiff = -1
                var secondDiff = -1
                for i in typed.indices where typed[i] != reading[i] {
                    if firstDiff < 0 {
                        firstDiff = i
                    } else if secondDiff < 0, i == firstDiff + 1 {
                        secondDiff = i
                    } else {
                        return nil
                    }
                }
                guard firstDiff >= 0 else { return nil }
                if secondDiff < 0 {
                    let i = firstDiff
                    guard spatialModel.areKeysAdjacentASCII(typed[i], reading[i]) else { return nil }
                    return substitutionCost(typed: typed[i], intended: reading[i], hyps: hypAt(i))
                }
                let i = firstDiff
                // Cross-hand transposed-neighbor rollover (`me -> en` in `zenenyang -> zenmeyang`):
                // one byte matches across the swap and the other is a physical keyboard neighbor.
                if reading[i] == typed[i + 1], reading[i + 1] != typed[i] {
                    guard Self.areQWERTYNeighbors(reading[i + 1], typed[i]),
                          spatialModel.areKeysAdjacentASCII(typed[i], reading[i + 1]) else { return nil }
                    currentIsRollover = true
                    return costs.transposition + substitutionCost(typed: typed[i], intended: reading[i + 1], hyps: hypAt(i))
                }
                if reading[i + 1] == typed[i], reading[i] != typed[i + 1] {
                    guard Self.areQWERTYNeighbors(reading[i], typed[i + 1]),
                          spatialModel.areKeysAdjacentASCII(typed[i + 1], reading[i]) else { return nil }
                    currentIsRollover = true
                    return costs.transposition + substitutionCost(typed: typed[i + 1], intended: reading[i], hyps: hypAt(i + 1))
                }
                return nil
            }
            var skipped = 0
            for i in typed.indices {
                while reading[i + skipped] != typed[i] {
                    skipped += 1
                    if skipped > missing { return nil }
                }
            }
            return missing * costs.insertion
        }

        @inline(__always)
        func visitHit(_ hit: MmapLexicon.WordHit, _ channel: Int) {
            let score = hit.scoreQ8 - channel
            if let existing = winner, existing.hit.text == hit.text {
                if score > existing.total {
                    winner = (hit, score, currentIsRollover)
                }
                return
            }
            if score > (winner?.total ?? Int.min) {
                runnerUp = winner?.total ?? runnerUp
                winner = (hit, score, currentIsRollover)
            } else {
                runnerUp = max(runnerUp, score)
            }
        }

        var scanned = 0
        let len0 = typed.count
        let b0 = typed[0]
        let b1 = typed[1]
        lexicon.visitSpokenReadingRange(
            length: len0, b0: b0, b1: nil, scanned: &scanned, isCancelled: isCancelled,
            cost: { evalCost(0, $0) }, visit: visitHit
        )
        for nb in Self.qwertyNeighbors(b0) {
            if isCancelled() { return nil }
            lexicon.visitSpokenReadingRange(
                length: len0, b0: nb, b1: b1, scanned: &scanned, isCancelled: isCancelled,
                cost: { evalCost(0, $0) }, visit: visitHit
            )
        }
        if !isCancelled() && b1 != b0 {
            for nb0 in Self.qwertyNeighbors(b0) where nb0 != b1 {
                if isCancelled() { return nil }
                lexicon.visitSpokenReadingRange(
                    length: len0, b0: b1, b1: nb0, scanned: &scanned, isCancelled: isCancelled,
                    cost: { evalCost(0, $0) }, visit: visitHit
                )
            }
            for nb1 in Self.qwertyNeighbors(b1) where nb1 != b0 {
                if isCancelled() { return nil }
                lexicon.visitSpokenReadingRange(
                    length: len0, b0: nb1, b1: b0, scanned: &scanned, isCancelled: isCancelled,
                    cost: { evalCost(0, $0) }, visit: visitHit
                )
            }
        }
        for missing in 1...2 {
            if isCancelled() { return nil }
            let targetLen = len0 + missing
            lexicon.visitSpokenReadingRange(
                length: targetLen, b0: b0, b1: nil, scanned: &scanned, isCancelled: isCancelled,
                cost: { evalCost(missing, $0) }, visit: visitHit
            )
            for c0 in Self.alphabet where c0 != b0 {
                if isCancelled() { return nil }
                lexicon.visitSpokenReadingRange(
                    length: targetLen, b0: c0, b1: b0, scanned: &scanned, isCancelled: isCancelled,
                    cost: { evalCost(missing, $0) }, visit: visitHit
                )
            }
            if missing == 2 {
                lexicon.visitSpokenDrop2Suffix(
                    length: targetLen,
                    typed: typed,
                    cost: 2 * costs.insertion,
                    visit: visitHit
                )
            }
        }
        if !literal && len0 >= 8 {
            for idx in 2..<(len0 - 1) where typed[idx] == 0x65 && typed[idx - 2] == 0x6E && typed[idx - 1] == 0x69 {
                let reduced = Array(typed[0..<idx]) + Array(typed[(idx + 1)..<len0])
                let rLen = reduced.count
                let rb0 = reduced[0]
                let rb1 = reduced[1]
                lexicon.visitSpokenReadingRange(
                    length: rLen, b0: rb0, b1: rb1, scanned: &scanned, isCancelled: isCancelled,
                    cost: { reading in
                        var ri = 0
                        for b in reading where b != 0x20 {
                            guard ri < rLen, b == reduced[ri] else { return nil }
                            ri += 1
                        }
                        return ri == rLen ? costs.duplicateDeletion : nil
                    },
                    visit: visitHit
                )
            }
        }
        guard let winner, winner.total - runnerUp >= costs.acceptMargin else { return nil }
        let fields = winner.hit.text.split(separator: "|", maxSplits: 1)
        guard fields.count == 2 else { return nil }
        let text = String(fields[0])
        let syllables = fields[1].split(separator: " ").map(String.init)
        guard text != top.text, text.count == syllables.count else { return nil }
        if !literal
            && syllables.count < top.matchedSyllables.count
            && top.consumedInputCount == typed.count
            && Self.matchesMixedJianpinAlignment(typed: typed, syllables: top.matchedSyllables) {
            return nil
        }
        if literal {
            // Preserve a fully spelled clause when an indexed entry just adds an entire
            // syllable (e.g. a subject, negation or particle). Letters alone cannot imply it.
            // Exception: allow `missing == 2` leading-syllable recovery (`yunbisaizhong -> 奥运比赛中`)
            // when strongly favored by the character spelling LM over an incoherent literal parse.
            var original = 0
            for syllable in syllables where original < top.matchedSyllables.count {
                if syllable == top.matchedSyllables[original] { original += 1 }
            }
            if original == top.matchedSyllables.count {
                let dropsLeadingTwoLetters = typed.count + 2 == syllables.joined().count
                    && syllables.count == top.matchedSyllables.count + 1
                    && Array(syllables.dropFirst()) == top.matchedSyllables
                    && top.scoreQ8 < -4500
                    && (lexicon.spellingLikelihood(text) ?? Int.min) >= (lexicon.spellingLikelihood(top.text) ?? Int.max) + 400
                if !dropsLeadingTwoLetters {
                    return nil
                }
            }
            // Never prepend a consonant initial onto a valid vowel-initial syllable (`e -> he` in `womenele -> 我们饿了`).
            if syllables.count == top.matchedSyllables.count {
                for (origSyl, candSyl) in zip(top.matchedSyllables, syllables) where origSyl != candSyl {
                    if let firstOrig = origSyl.utf8.first,
                       (firstOrig == 0x61 || firstOrig == 0x65 || firstOrig == 0x6F),
                       candSyl.count == origSyl.count + 1,
                       candSyl.hasSuffix(origSyl) {
                        return nil
                    }
                }
            }
        }
        let margin = literal
            ? (costs.literalPromoteBase + (winner.isRollover ? costs.cleanInputMargin : 0))
            : costs.acceptMargin
        guard winner.total >= top.scoreQ8 + margin else { return nil }
        return LokeyCandidate(text: text, consumedInputCount: typed.count, matchedSyllables: syllables,
                              scoreQ8: winner.total, kind: .sentence)
    }

    /// Compare single-omission completions for each half independently. A split is only
    /// useful when each half has a strong lexical path. Cap their cross-product before
    /// the ordinary whole-sentence contextual verification.
    private func splitOmissions(_ typed: [UInt8], isCancelled: () -> Bool) -> [([UInt8], Int)] {
        typealias Reading = (spelling: [UInt8], score: Int)
        func strongest(_ fragment: ArraySlice<UInt8>) -> [Reading] {
            var winners: [Reading] = []
            var scratch = Array(fragment) + [0]
            for i in stride(from: fragment.count, through: 0, by: -1) {
                if i < fragment.count { scratch[i + 1] = fragment[fragment.startIndex + i] }
                for b in Self.alphabet {
                    if i < fragment.count && b == scratch[i + 1] { continue }
                    scratch[i] = b
                    let scoreOpt: Int? = scratch.withUnsafeBufferPointer { buf in
                        guard let ptr = buf.baseAddress, lexicon.canSegmentCleanlyPointer(ptr, count: buf.count) else { return nil }
                        return computeCleanScorePointer(ptr, count: buf.count, alreadySegmented: true)
                    }
                    guard let score = scoreOpt else { continue }
                    if winners.count == 3 && score < winners[2].score { continue }
                    winners.append((scratch, score))
                    winners.sort { $0.score != $1.score ? $0.score > $1.score : $0.spelling.lexicographicallyPrecedes($1.spelling) }
                    if winners.count > 3 { winners.removeLast() }
                }
            }
            return winners
        }
        var full: [[UInt8]: Int] = [:]
        for split in 1..<typed.count {
            if isCancelled() { return [] }
            let left = strongest(typed[..<split])
            if left.isEmpty { continue }
            let right = strongest(typed[split...])
            for a in left {
                for b in right {
                    let spelling = a.spelling + b.spelling
                    let score = a.score + b.score - 2 * costs.insertion
                    full[spelling] = max(full[spelling] ?? Int.min, score)
                }
            }
        }
        return Array(full.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key)
        }.prefix(costs.verifyCount)).map { ($0.key, $0.value) }
    }

    // MARK: - Edits

    private static let alphabet: [UInt8] = Array(0x61...0x7A)

    /// Precomputes forward & backward exact-syllable reachability bitmasks on `ptr[0..<n]` (`n < 64`) in O(n).
    @inline(__always)
    private func computeSegmentationMasks(_ ptr: UnsafePointer<UInt8>, count n: Int) -> (prefix: UInt64, suffix: UInt64) {
        var pref: UInt64 = 1
        for i in 0..<n where (pref & (UInt64(1) << UInt64(i))) != 0 {
            let maxEnd = min(n, i + 6)
            var code: UInt32 = 0
            for end in (i + 1)...maxEnd {
                let b = ptr[end - 1]
                guard b >= 0x61 && b <= 0x7A else { break }
                code = (code << 5) | UInt32(b - 0x60)
                if lexicon.isPackedSyllable(code) {
                    pref |= (UInt64(1) << UInt64(end))
                }
            }
        }
        var suff: UInt64 = UInt64(1) << UInt64(n)
        var pos = n - 1
        while pos >= 0 {
            let maxEnd = min(n, pos + 6)
            var code: UInt32 = 0
            for end in (pos + 1)...maxEnd {
                let b = ptr[end - 1]
                guard b >= 0x61 && b <= 0x7A else { break }
                code = (code << 5) | UInt32(b - 0x60)
                if (suff & (UInt64(1) << UInt64(end))) != 0 && lexicon.isPackedSyllable(code) {
                    suff |= (UInt64(1) << UInt64(pos))
                    break
                }
            }
            pos -= 1
        }
        return (pref, suff)
    }

    /// Exact O(1) meet-in-the-middle syllable segmentation test across an edit window `editStart..<editEnd` in `outPtr[0..<m]`.
    @inline(__always)
    private func canSegmentEdited(
        _ outPtr: UnsafePointer<UInt8>,
        outCount m: Int,
        editStart: Int,
        editEnd: Int,
        delta: Int,
        prefMask: UInt64,
        suffMask: UInt64
    ) -> Bool {
        guard m > 0 && m < 64 else { return false }
        var reach = prefMask & ((UInt64(1) << UInt64(editStart + 1)) &- 1)
        if editStart == editEnd {
            let origPos = editStart - delta
            if (reach & (UInt64(1) << UInt64(editStart))) != 0 && (suffMask & (UInt64(1) << UInt64(origPos))) != 0 {
                return true
            }
        }
        let winStart = max(0, editEnd - 6)
        guard editEnd > winStart else { return false }
        let maxInitPos = min(editStart, editEnd - 1)
        guard maxInitPos >= winStart else { return false }
        let winBits = ((UInt64(1) << UInt64(maxInitPos - winStart + 1)) &- 1) << UInt64(winStart)
        if (reach & winBits) == 0 { return false }
        for pos in winStart..<editEnd {
            guard (reach & (UInt64(1) << UInt64(pos))) != 0 else { continue }
            let maxEnd = min(m, pos + 6)
            guard pos < maxEnd else { continue }
            var code: UInt32 = 0
            for end in (pos + 1)...maxEnd {
                code = (code << 5) | UInt32(outPtr[end - 1] - 0x60)
                if lexicon.isPackedSyllable(code) {
                    if end >= editEnd {
                        if (suffMask & (UInt64(1) << UInt64(end - delta))) != 0 {
                            return true
                        }
                    } else {
                        reach |= (UInt64(1) << UInt64(end))
                    }
                }
            }
        }
        return false
    }

    /// Enumerates single-letter edits with their channel cost. Substitutions of typed keys follow the touch
    /// model's neighbors and penalties; substitutions inside an already-corrected reading use horizontal neighbors.
    /// Every candidate is pre-filtered in O(1) with `canSegmentEdited` and written into one reused scratch buffer.
    private func forEachEdit(
        of s: [UInt8],
        hyps: [[KeyHypothesis]]?,
        transposedPairIndex: Int? = nil,
        isCancelled: () -> Bool = { false },
        _ body: (UnsafeBufferPointer<UInt8>, Int) -> Void
    ) {
        let n = s.count
        guard n > 0, n < 62 else { return }
        var scratch = [UInt8](repeating: 0, count: n + 1)
        scratch.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            s.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                let (prefMask, suffMask) = computeSegmentationMasks(srcBase, count: n)

                @inline(__always)
                func emitIfClean(_ length: Int, _ editStart: Int, _ editEnd: Int, _ delta: Int, _ cost: Int) {
                    if canSegmentEdited(outBase, outCount: length, editStart: editStart, editEnd: editEnd, delta: delta, prefMask: prefMask, suffMask: suffMask) {
                        body(UnsafeBufferPointer(rebasing: out[0..<length]), cost)
                    }
                }

                // Deletions:
                // 1) Repeated key (fat-finger double hit)
                for i in 0..<(n - 1) where src[i + 1] == src[i] {
                    for k in 0..<i { out[k] = src[k] }
                    for k in (i + 1)..<n { out[k - 1] = src[k] }
                    emitIfClean(n - 1, i, i, -1, costs.duplicateDeletion)
                }
                // 2) Interior QWERTY-neighbor accidental graze key on raw input (`nieshuihuiba -> nishuihuiba`)
                if hyps != nil && n >= 8 && n > 2 {
                    let srcIsClean = (prefMask & (UInt64(1) << UInt64(n))) != 0
                    for i in 1..<(n - 1) {
                        let b = src[i]
                        if b == src[i - 1] || b == src[i + 1] { continue }
                        guard Self.areQWERTYNeighbors(b, src[i - 1]) || Self.areQWERTYNeighbors(b, src[i + 1]) else { continue }
                        var grazeDelCost = costs.deletion
                        if srcIsClean && (hyps?[i].first?.penaltyQ8 ?? 0) < 65 {
                            // On already-clean input, never strip the vowel coda of clean `-ie`/`-ia`/`-uo`/`-ua` syllables
                            // (`bieshuijiao`, `bieshuiba`, `xieshuole`, `pieshuiba`, `lieshuiba`, `dieshuijiao`, `qieshuiba`).
                            // Only allow clean-input graze deletion for `ni` + grazed `'e'` (`nieshuihuiba -> nishuihuiba`)
                            // or a standalone 1-letter grazed vowel (`a`/`e`/`o`) unattached to the preceding syllable.
                            let isNiE = b == 0x65
                                && i >= 2
                                && src[i - 2] == 0x6E && src[i - 1] == 0x69
                                && (prefMask & (UInt64(1) << UInt64(i - 2))) != 0
                                && (suffMask & (UInt64(1) << UInt64(i + 1))) != 0
                            let isStandaloneVowelGraze: Bool = {
                                guard (b == 0x65 || b == 0x61 || b == 0x6F),
                                      (prefMask & (UInt64(1) << UInt64(i))) != 0,
                                      (suffMask & (UInt64(1) << UInt64(i + 1))) != 0 else { return false }
                                for prevLen in 1...min(3, i) {
                                    let s0 = i - prevLen
                                    guard (prefMask & (UInt64(1) << UInt64(s0))) != 0 else { continue }
                                    var code: UInt32 = 0
                                    for p in s0...i {
                                        code = (code << 5) | UInt32(src[p] - 0x60)
                                    }
                                    if lexicon.isPackedSyllable(code) {
                                        return false
                                    }
                                }
                                return true
                            }()
                            if !isNiE && !isStandaloneVowelGraze { continue }
                            if isNiE { grazeDelCost = costs.duplicateDeletion }
                        }
                        for k in 0..<i { out[k] = src[k] }
                        for k in (i + 1)..<n { out[k - 1] = src[k] }
                        emitIfClean(n - 1, i, i, -1, grazeDelCost)
                    }
                }
                if isCancelled() { return }
                // Insertions: include a missing opening key on the original input; later seeds already have an onset.
                for i in (hyps == nil ? 1 : 0)...n {
                    if isCancelled() { return }
                    let winStart = max(0, i - 5)
                    let reachWindow = ((UInt64(1) << UInt64(i - winStart + 1)) &- 1) << UInt64(winStart)
                    if (prefMask & reachWindow) == 0 { continue }
                    for k in 0..<i { out[k] = src[k] }
                    for k in i..<n { out[k + 1] = src[k] }
                    for c in Self.alphabet {
                        if i < n, src[i] == c { continue } // identical to inserting after the duplicate
                        out[i] = c
                        emitIfClean(n + 1, i, i + 1, 1, costs.insertion)
                    }
                }
                if isCancelled() { return }
                // Transpositions
                for k in 0..<n { out[k] = src[k] }
                for i in 0..<(n - 1) where src[i] != src[i + 1] {
                    out[i] = src[i + 1]
                    out[i + 1] = src[i]
                    emitIfClean(n, i, i + 2, 0, costs.transposition)
                    out[i] = src[i]
                    out[i + 1] = src[i + 1]
                }
                // Substitutions
                for i in 0..<n {
                    if isCancelled() { return }
                    let winStart = max(0, i - 5)
                    let reachWindow = ((UInt64(1) << UInt64(i - winStart + 1)) &- 1) << UInt64(winStart)
                    if (prefMask & reachWindow) == 0 { continue }
                    if let hyps, i < hyps.count {
                        for h in hyps[i] {
                            guard let a = h.char.asciiValue, a != src[i], a >= 0x61, a <= 0x7A else { continue }
                            out[i] = a
                            emitIfClean(n, i, i + 1, 0, max(costs.substitutionFloor, h.penaltyQ8))
                        }
                    } else {
                        let neighborList = (transposedPairIndex != nil && (i == transposedPairIndex! || i == transposedPairIndex! + 1))
                            ? Self.qwertyNeighbors(src[i])
                            : Self.horizontalNeighbors(src[i])
                        for c in neighborList {
                            out[i] = c
                            emitIfClean(n, i, i + 1, 0, costs.neighborSubstitution)
                        }
                    }
                    out[i] = src[i]
                }
            }
        }
    }

    private static let rows: [[UInt8]] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
    private static let neighborTable: [[UInt8]] = {
        var table = [[UInt8]](repeating: [], count: 26)
        for row in rows {
            for (i, c) in row.enumerated() {
                var nb: [UInt8] = []
                if i > 0 { nb.append(row[i - 1]) }
                if i + 1 < row.count { nb.append(row[i + 1]) }
                table[Int(c - 0x61)] = nb
            }
        }
        return table
    }()

    private static let qwertyAdjMask: [UInt32] = {
        var coords = [(Double, Double)](repeating: (0, 0), count: 26)
        let rowOffsets = [0.0, 0.5, 1.5]
        for (rIdx, row) in rows.enumerated() {
            for (cIdx, ch) in row.enumerated() {
                coords[Int(ch - 0x61)] = (Double(cIdx) + rowOffsets[rIdx], Double(rIdx))
            }
        }
        var masks = [UInt32](repeating: 0, count: 26)
        for a in 0..<26 {
            var m: UInt32 = 0
            for b in 0..<26 where a != b {
                let dx = abs(coords[a].0 - coords[b].0)
                let dy = abs(coords[a].1 - coords[b].1)
                if dy <= 1.01 && dx <= 1.05 {
                    m |= (UInt32(1) << UInt32(b))
                }
            }
            masks[a] = m
        }
        return masks
    }()

    private static let qwertyNeighborTable: [[UInt8]] = {
        var table = [[UInt8]](repeating: [], count: 26)
        for a in 0..<26 {
            let m = qwertyAdjMask[a]
            var nb: [UInt8] = []
            for b in 0..<26 where (m & (UInt32(1) << UInt32(b))) != 0 {
                nb.append(UInt8(0x61 + b))
            }
            table[a] = nb
        }
        return table
    }()

    @inline(__always)
    private static func areQWERTYNeighbors(_ a: UInt8, _ b: UInt8) -> Bool {
        guard a >= 0x61 && a <= 0x7A && b >= 0x61 && b <= 0x7A else { return false }
        return (qwertyAdjMask[Int(a - 0x61)] & (UInt32(1) << UInt32(b - 0x61))) != 0
    }

    private static func horizontalNeighbors(_ c: UInt8) -> [UInt8] {
        guard c >= 0x61, c <= 0x7A else { return [] }
        return neighborTable[Int(c - 0x61)]
    }

    private static func qwertyNeighbors(_ c: UInt8) -> [UInt8] {
        guard c >= 0x61, c <= 0x7A else { return [] }
        return qwertyNeighborTable[Int(c - 0x61)]
    }

    @inline(__always)
    private static func adjacentTranspositionIndex(_ a: [UInt8], _ b: CleanScoreKey) -> Int? {
        let n = a.count
        guard n == Int(b.len), n >= 2 else { return nil }
        var swapIdx = -1
        var i = 0
        while i < n {
            let bi = b.byte(at: i)
            if a[i] != bi {
                guard swapIdx < 0,
                      i + 1 < n,
                      a[i] == b.byte(at: i + 1),
                      a[i + 1] == bi else {
                    return nil
                }
                swapIdx = i
                i += 2
            } else {
                i += 1
            }
        }
        return swapIdx >= 0 ? swapIdx : nil
    }

    // MARK: - Channel cost

    private func buildHypCostTable(hyps: [[KeyHypothesis]]) {
        let count = hyps.count
        let needed = max(count, 1) * 26
        if hypCostBuf.count < needed {
            hypCostBuf = [Int](repeating: costs.farSubstitution, count: needed)
        }
        let far = costs.farSubstitution
        let floor = costs.substitutionFloor
        for idx in 0..<(count * 26) { hypCostBuf[idx] = far }
        for (i, list) in hyps.enumerated() {
            let base = i * 26
            for h in list {
                guard let a = h.char.asciiValue, a >= 0x61, a <= 0x7A else { continue }
                let col = Int(a - 0x61)
                let pen = max(floor, h.penaltyQ8)
                if pen < hypCostBuf[base + col] {
                    hypCostBuf[base + col] = pen
                }
            }
        }
    }

    /// Zero-allocation weighted Damerau-Levenshtein cost using prebuilt `hypCostBuf` and reusable `alignBuf`.
    private func alignmentCostFast(typed: [UInt8], intended: [UInt8], hypsCount: Int) -> Int {
        let n = typed.count, m = intended.count
        if n == 0 || m == 0 { return max(n, m) * costs.insertion }
        let stride = m + 1
        let needed = (n + 1) * stride
        if alignBuf.count < needed {
            alignBuf = [Int](repeating: 0, count: needed)
        }
        let insCost = costs.insertion
        let delCost = costs.deletion
        let dupDelCost = costs.duplicateDeletion
        let transCost = costs.transposition
        let nbrSubCost = costs.neighborSubstitution
        let farCost = costs.farSubstitution
        return alignBuf.withUnsafeMutableBufferPointer { d in
            d[0] = 0
            for i in 1...n { d[i * stride] = d[(i - 1) * stride] + delCost }
            for j in 1...m { d[j] = d[j - 1] + insCost }
            for i in 1...n {
                let t = typed[i - 1]
                let rowOff = i * stride
                let prevRowOff = (i - 1) * stride
                let dup = (i >= 2 && typed[i - 2] == t) || (i < n && typed[i] == t)
                let niEGraze = t == 0x65 && i >= 3 && typed[i - 3] == 0x6E && typed[i - 2] == 0x69
                let extraKeyCost = (dup || niEGraze) ? dupDelCost : delCost
                let hypBase = (i - 1 < hypsCount) ? (i - 1) * 26 : -1
                for j in 1...m {
                    let w = intended[j - 1]
                    var v: Int
                    if t == w {
                        v = d[prevRowOff + j - 1]
                    } else {
                        let subCost = (hypBase >= 0 && w >= 0x61 && w <= 0x7A)
                            ? hypCostBuf[hypBase + Int(w - 0x61)]
                            : farCost
                        v = d[prevRowOff + j - 1] + subCost
                    }
                    let delCand = d[prevRowOff + j] + extraKeyCost
                    if delCand < v { v = delCand }
                    let stepInsCost = (w == 0x67 && j >= 2 && intended[j - 2] == 0x6E && t == 0x6E)
                        ? max(240, insCost - 140)
                        : insCost
                    let insCand = d[rowOff + j - 1] + stepInsCost
                    if insCand < v { v = insCand }
                    if i >= 2, j >= 2 {
                        let tPrev = typed[i - 2]
                        let wPrev = intended[j - 2]
                        let diagPrev2 = d[(i - 2) * stride + (j - 2)]
                        if t == wPrev, tPrev == w, t != w {
                            let trCand = diagPrev2 + transCost
                            if trCand < v { v = trCand }
                        } else if t == wPrev, tPrev != w, Self.areQWERTYNeighbors(tPrev, w) {
                            let prevHypBase = (i - 2 < hypsCount) ? (i - 2) * 26 : -1
                            let subCost = (prevHypBase >= 0 && w >= 0x61 && w <= 0x7A)
                                ? hypCostBuf[prevHypBase + Int(w - 0x61)]
                                : nbrSubCost
                            let trSubCand = diagPrev2 + transCost + subCost
                            if trSubCand < v { v = trSubCand }
                        } else if tPrev == w, t != wPrev, Self.areQWERTYNeighbors(t, wPrev) {
                            let subCost = (hypBase >= 0 && wPrev >= 0x61 && wPrev <= 0x7A)
                                ? hypCostBuf[hypBase + Int(wPrev - 0x61)]
                                : nbrSubCost
                            let trSubCand = diagPrev2 + transCost + subCost
                            if trSubCand < v { v = trSubCand }
                        }
                    }
                    d[rowOff + j] = v
                }
            }
            return d[n * stride + m]
        }
    }

    private func alignmentUsesFarSubstitution(typed: [UInt8], intended: [UInt8], hypsCount: Int) -> Bool {
        let n = typed.count, m = intended.count
        if n == 0 || m == 0 { return false }
        let stride = m + 1
        let needed = (n + 1) * stride
        if alignBuf.count < needed {
            alignBuf = [Int](repeating: 0, count: needed)
        }
        let insCost = costs.insertion
        let delCost = costs.deletion
        let dupDelCost = costs.duplicateDeletion
        let transCost = costs.transposition
        let nbrSubCost = costs.neighborSubstitution
        let farCost = costs.farSubstitution
        return alignBuf.withUnsafeMutableBufferPointer { d in
            d[0] = 0
            for i in 1...n { d[i * stride] = (i * delCost) << 1 }
            for j in 1...m { d[j] = (j * insCost) << 1 }
            for i in 1...n {
                let t = typed[i - 1]
                let rowOff = i * stride
                let prevRowOff = (i - 1) * stride
                let dup = (i >= 2 && typed[i - 2] == t) || (i < n && typed[i] == t)
                let niEGraze = t == 0x65 && i >= 3 && typed[i - 3] == 0x6E && typed[i - 2] == 0x69
                let extraKeyCost = (dup || niEGraze) ? dupDelCost : delCost
                let hypBase = (i - 1 < hypsCount) ? (i - 1) * 26 : -1
                for j in 1...m {
                    let w = intended[j - 1]
                    var v: Int
                    if t == w {
                        v = d[prevRowOff + j - 1]
                    } else {
                        let subCost = (hypBase >= 0 && w >= 0x61 && w <= 0x7A)
                            ? hypCostBuf[hypBase + Int(w - 0x61)]
                            : farCost
                        let prev = d[prevRowOff + j - 1]
                        let isFar = (subCost >= farCost) ? 1 : 0
                        v = (((prev >> 1) + subCost) << 1) | ((prev & 1) | isFar)
                    }
                    let delPrev = d[prevRowOff + j]
                    let delCand = (((delPrev >> 1) + extraKeyCost) << 1) | (delPrev & 1)
                    if delCand < v { v = delCand }
                    let stepInsCost = (w == 0x67 && j >= 2 && intended[j - 2] == 0x6E && t == 0x6E)
                        ? max(240, insCost - 140)
                        : insCost
                    let insPrev = d[rowOff + j - 1]
                    let insCand = (((insPrev >> 1) + stepInsCost) << 1) | (insPrev & 1)
                    if insCand < v { v = insCand }
                    if i >= 2, j >= 2 {
                        let tPrev = typed[i - 2]
                        let wPrev = intended[j - 2]
                        let diagPrev2 = d[(i - 2) * stride + (j - 2)]
                        if t == wPrev, tPrev == w, t != w {
                            let trCand = (((diagPrev2 >> 1) + transCost) << 1) | (diagPrev2 & 1)
                            if trCand < v { v = trCand }
                        } else if t == wPrev, tPrev != w, Self.areQWERTYNeighbors(tPrev, w) {
                            let prevHypBase = (i - 2 < hypsCount) ? (i - 2) * 26 : -1
                            let subCost = (prevHypBase >= 0 && w >= 0x61 && w <= 0x7A)
                                ? hypCostBuf[prevHypBase + Int(w - 0x61)]
                                : nbrSubCost
                            let isFar = (subCost >= farCost) ? 1 : 0
                            let trSubCand = (((diagPrev2 >> 1) + transCost + subCost) << 1) | ((diagPrev2 & 1) | isFar)
                            if trSubCand < v { v = trSubCand }
                        } else if tPrev == w, t != wPrev, Self.areQWERTYNeighbors(t, wPrev) {
                            let subCost = (hypBase >= 0 && wPrev >= 0x61 && wPrev <= 0x7A)
                                ? hypCostBuf[hypBase + Int(wPrev - 0x61)]
                                : nbrSubCost
                            let isFar = (subCost >= farCost) ? 1 : 0
                            let trSubCand = (((diagPrev2 >> 1) + transCost + subCost) << 1) | ((diagPrev2 & 1) | isFar)
                            if trSubCand < v { v = trSubCand }
                        }
                    }
                    d[rowOff + j] = v
                }
            }
            return (d[n * stride + m] & 1) != 0
        }
    }

    /// Weighted Damerau-Levenshtein cost of producing `typed` when the user meant `intended`.
    func alignmentCost(typed: [UInt8], intended: [UInt8], hyps: [[KeyHypothesis]]) -> Int {
        buildHypCostTable(hyps: hyps)
        return alignmentCostFast(typed: typed, intended: intended, hypsCount: hyps.count)
    }

    private func substitutionCost(typed: UInt8, intended: UInt8, hyps: [KeyHypothesis]) -> Int {
        let target = Character(UnicodeScalar(intended))
        if let h = hyps.first(where: { $0.char == target }) {
            return max(costs.substitutionFloor, h.penaltyQ8)
        }
        return costs.farSubstitution
    }

    // MARK: - Unigram word lattice

    /// Best sum of dictionary word scores (Q8 log10) over a full clean syllable segmentation of `s`, or `nil`.
    func cleanScore(_ s: [UInt8], alreadySegmented: Bool = false) -> Int? {
        computeCleanScore(s, alreadySegmented: alreadySegmented)
    }

    private func computeCleanScore(_ s: [UInt8], alreadySegmented: Bool) -> Int? {
        s.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return nil }
            return computeCleanScorePointer(ptr, count: buf.count, alreadySegmented: alreadySegmented)
        }
    }

    /// Zero-allocation unigram word lattice using reusable `cleanBestBuf`, `cleanStackBuf`, and packed-ASCII syllable lookup.
    private func computeCleanScorePointer(
        _ ptr: UnsafePointer<UInt8>,
        count n: Int,
        alreadySegmented: Bool,
        keyHint: CleanScoreKey? = nil
    ) -> Int? {
        guard n > 0, n < 64 else { return nil }
        let wordCost = costs.wordCost
        if cachedWordCost != wordCost || scoreCache.count > 2048 {
            scoreCache.removeAll(keepingCapacity: true)
            cachedWordCost = wordCost
        }
        let cacheKey = keyHint ?? CleanScoreKey(ptr, count: n)
        if let key = cacheKey, let cached = scoreCache[key] {
            return cached == Int.min ? nil : cached
        }
        let (prefMask, suffMask) = computeSegmentationMasks(ptr, count: n)
        let validMask = prefMask & suffMask
        guard (validMask & 1) != 0, (validMask & (UInt64(1) << UInt64(n))) != 0 else {
            if let key = cacheKey {
                if scoreCache.count >= 2048 {
                    scoreCache.removeAll(keepingCapacity: true)
                }
                scoreCache[key] = Int.min
            }
            return nil
        }
        let minScore = Int.min / 4
        if cleanBestBuf.count <= n {
            cleanBestBuf = [Int](repeating: minScore, count: 68)
        }
        cleanBestBuf[0] = 0
        for idx in 1...n { cleanBestBuf[idx] = minScore }
        let root = lexicon.rootNodeIndex
        for i in 0..<n where cleanBestBuf[i] > minScore {
            let startScore = cleanBestBuf[i]
            cleanStackBuf.removeAll(keepingCapacity: true)
            cleanStackBuf.append((root, i, 0))
            while let (node, pos, depth) = cleanStackBuf.popLast() {
                let maxLen = min(6, n - pos)
                guard maxLen >= 1 else { continue }
                var packed: UInt32 = 0
                for len in 1...maxLen {
                    let b = ptr[pos + len - 1]
                    guard b >= 0x61 && b <= 0x7A else { break }
                    packed = (packed << 5) | UInt32(b - 0x60)
                    if len <= 3 && !lexicon.hasShortSyllablePrefix(packed) { break }
                    let end = pos + len
                    if (validMask & (UInt64(1) << UInt64(end))) == 0 { continue }
                    guard let sid = lexicon.canonicalSyllableID(forPackedCode: packed),
                          let hit = lexicon.stepWordAndOutgoing(from: node, syllableID: sid) else { continue }
                    if let w = hit.topWordScore {
                        let cand = startScore + w - wordCost
                        if cand > cleanBestBuf[end] { cleanBestBuf[end] = cand }
                    }
                    if depth < 5, end < n, hit.hasOutgoing {
                        cleanStackBuf.append((hit.next, end, depth + 1))
                    }
                }
            }
        }
        let result: Int? = cleanBestBuf[n] > minScore ? cleanBestBuf[n] : nil
        if let key = cacheKey {
            if scoreCache.count >= 2048 {
                scoreCache.removeAll(keepingCapacity: true)
            }
            scoreCache[key] = result ?? Int.min
        }
        return result
    }

    private func cleanUnigramSentence(_ bytes: [UInt8]) -> (text: String, trailingWord: String?)? {
        let n = bytes.count
        guard n > 0, n < 64 else { return nil }
        return bytes.withUnsafeBufferPointer { buf -> (text: String, trailingWord: String?)? in
            guard let ptr = buf.baseAddress else { return nil }
            let (prefMask, suffMask) = computeSegmentationMasks(ptr, count: n)
            let validMask = prefMask & suffMask
            guard (validMask & 1) != 0, (validMask & (UInt64(1) << UInt64(n))) != 0 else { return nil }
            let wordCost = costs.wordCost
            let minScore = Int.min / 4
            if cleanBestBuf.count <= n {
                cleanBestBuf = [Int](repeating: minScore, count: 68)
            }
            if cleanBackStartBuf.count <= n {
                cleanBackStartBuf = [Int](repeating: -1, count: 68)
                cleanBackNodeBuf = [UInt32](repeating: 0, count: 68)
            }
            cleanBestBuf[0] = 0
            cleanBackStartBuf[0] = -1
            cleanBackNodeBuf[0] = 0
            for idx in 1...n {
                cleanBestBuf[idx] = minScore
                cleanBackStartBuf[idx] = -1
                cleanBackNodeBuf[idx] = 0
            }
            let root = lexicon.rootNodeIndex
            for i in 0..<n where cleanBestBuf[i] > minScore {
                let startScore = cleanBestBuf[i]
                cleanStackBuf.removeAll(keepingCapacity: true)
                cleanStackBuf.append((root, i, 0))
                while let (node, pos, depth) = cleanStackBuf.popLast() {
                    let maxLen = min(6, n - pos)
                    guard maxLen >= 1 else { continue }
                    var packed: UInt32 = 0
                    for len in 1...maxLen {
                        let b = ptr[pos + len - 1]
                        guard b >= 0x61 && b <= 0x7A else { break }
                        packed = (packed << 5) | UInt32(b - 0x60)
                        if len <= 3 && !lexicon.hasShortSyllablePrefix(packed) { break }
                        let end = pos + len
                        if (validMask & (UInt64(1) << UInt64(end))) == 0 { continue }
                        guard let sid = lexicon.canonicalSyllableID(forPackedCode: packed),
                              let hit = lexicon.stepWordAndOutgoing(from: node, syllableID: sid) else { continue }
                        if let w = hit.topWordScore {
                            let cand = startScore + w - wordCost
                            if cand > cleanBestBuf[end] {
                                cleanBestBuf[end] = cand
                                cleanBackStartBuf[end] = i
                                cleanBackNodeBuf[end] = hit.next
                            }
                        }
                        if depth < 5, end < n, hit.hasOutgoing {
                            cleanStackBuf.append((hit.next, end, depth + 1))
                        }
                    }
                }
            }
            guard cleanBestBuf[n] > minScore else { return nil }
            var words: [String] = []
            var cur = n
            while cur > 0 {
                let prev = cleanBackStartBuf[cur]
                let node = cleanBackNodeBuf[cur]
                guard prev >= 0, prev < cur,
                      let w = lexicon.words(at: node, limit: 1).first?.text else { return nil }
                words.append(w)
                cur = prev
            }
            words.reverse()
            return (words.joined(), words.last)
        }
    }

    // MARK: - Neural Blind-Typing Typo Reranker (`LNTR-v1`) Feature Helpers

    private func segmentCandidateWords(_ text: String, syllables: [String], trailingWord: String?) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let hasMatchedSyls = (chars.count == syllables.count)
        let lockedTailLen: Int
        if let tw = trailingWord, !tw.isEmpty, tw.count < chars.count, text.hasSuffix(tw) {
            lockedTailLen = tw.count
        } else {
            lockedTailLen = 0
        }
        let bodyCount = chars.count - lockedTailLen
        var out: [String] = []
        out.reserveCapacity(max(1, chars.count / 2 + 1))
        var pos = 0
        while pos < bodyCount {
            var matchedLen = 1
            let maxLen = min(4, bodyCount - pos)
            if maxLen >= 2 {
                for len in stride(from: maxLen, through: 2, by: -1) {
                    let piece = String(chars[pos..<(pos + len)])
                    if hasMatchedSyls {
                        let subSyls = Array(syllables[pos..<(pos + len)])
                        if lexicon.lookupExactWords(forSyllables: subSyls, limit: 8).contains(where: { $0.text == piece }) {
                            matchedLen = len
                            break
                        }
                    } else if lexicon.neuralLM.lookupWordTableEmbedding(piece) != nil {
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

    private func typoAlignmentBreakdown(
        typed: [UInt8],
        intended: [UInt8],
        hyps: [[KeyHypothesis]]
    ) -> (subst: Int, omit: Int, trans: Int, del: Int, matchedGainQ8: Int) {
        let n = typed.count, m = intended.count
        guard n > 0, m > 0 else {
            return (0, m, 0, n, 0)
        }
        let stride = m + 1
        var dp = [Int](repeating: Int.max / 4, count: (n + 1) * stride)
        var backOp = [UInt8](repeating: 0, count: (n + 1) * stride) // 0=match, 1=sub, 2=ins(omit), 3=del, 4=trans
        let insCost = costs.insertion
        let delCost = costs.deletion
        let dupDelCost = costs.duplicateDeletion
        let transCost = costs.transposition
        let farCost = costs.farSubstitution

        dp[0] = 0
        for i in 1...n {
            dp[i * stride] = i * delCost
            backOp[i * stride] = 3
        }
        for j in 1...m {
            dp[j] = j * insCost
            backOp[j] = 2
        }
        for i in 1...n {
            let t = typed[i - 1]
            let dup = (i >= 2 && typed[i - 2] == t) || (i < n && typed[i] == t)
            let extraKeyCost = dup ? dupDelCost : delCost
            let hypBase = (i - 1 < hyps.count) ? (i - 1) * 26 : -1
            for j in 1...m {
                let w = intended[j - 1]
                let idx = i * stride + j
                if t == w {
                    dp[idx] = dp[(i - 1) * stride + (j - 1)]
                    backOp[idx] = 0
                } else {
                    let subCost = (hypBase >= 0 && w >= 0x61 && w <= 0x7A)
                        ? hypCostBuf[hypBase + Int(w - 0x61)]
                        : farCost
                    dp[idx] = dp[(i - 1) * stride + (j - 1)] + subCost
                    backOp[idx] = 1
                }
                let delCand = dp[(i - 1) * stride + j] + extraKeyCost
                if delCand < dp[idx] {
                    dp[idx] = delCand
                    backOp[idx] = 3
                }
                let stepInsCost = (w == 0x67 && j >= 2 && intended[j - 2] == 0x6E && t == 0x6E)
                    ? max(240, insCost - 140)
                    : insCost
                let insCand = dp[i * stride + (j - 1)] + stepInsCost
                if insCand < dp[idx] {
                    dp[idx] = insCand
                    backOp[idx] = 2
                }
                if i >= 2, j >= 2, t == intended[j - 2], typed[i - 2] == w, t != w {
                    let trCand = dp[(i - 2) * stride + (j - 2)] + transCost
                    if trCand < dp[idx] {
                        dp[idx] = trCand
                        backOp[idx] = 4
                    }
                }
            }
        }

        var subst = 0, omit = 0, trans = 0, del = 0, matchedGainQ8 = 0
        var ci = n, cj = m
        while ci > 0 || cj > 0 {
            let op = backOp[ci * stride + cj]
            switch op {
            case 0:
                if ci - 1 < hyps.count {
                    let target = Character(UnicodeScalar(intended[cj - 1]))
                    let pPen = hyps[ci - 1].first(where: { $0.char == target })?.penaltyQ8 ?? 0
                    matchedGainQ8 += max(0, 260 - pPen)
                }
                ci -= 1
                cj -= 1
            case 1:
                subst += 1
                if ci - 1 < hyps.count {
                    let target = Character(UnicodeScalar(intended[cj - 1]))
                    if let h = hyps[ci - 1].first(where: { $0.char == target }) {
                        matchedGainQ8 += max(0, 340 - h.penaltyQ8)
                    }
                }
                ci -= 1
                cj -= 1
            case 2:
                omit += 1
                cj -= 1
            case 3:
                del += 1
                ci -= 1
            case 4:
                trans += 1
                ci -= 2
                cj -= 2
            default:
                if ci > 0 { ci -= 1 }
                if cj > 0 { cj -= 1 }
            }
        }
        return (subst, omit, trans, del, matchedGainQ8)
    }

    private func computeTypoCandidateFeatures(
        cand: LokeyCandidate,
        readingBytes: [UInt8],
        cost: Int,
        typed: [UInt8],
        hyps: [[KeyHypothesis]],
        maxPrimaryDrift: Int,
        precedingContext: String?,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero
    ) -> [Float] {
        let words = segmentCandidateWords(cand.text, syllables: cand.matchedSyllables, trailingWord: cand.trailingWord)
        let stats = typoAlignmentBreakdown(typed: typed, intended: readingBytes, hyps: hyps)
        let spellingLL = lexicon.spellingLikelihood(cand.text)
        let boundaryQ8 = lexicon.spellingBoundary(cand.text, trailingWord: cand.trailingWord)
        let cleanLatQ8 = cleanScore(readingBytes) ?? (cand.scoreQ8 + cost)
        let fwdQ8 = lexicon.neuralLM.scoreWholeSentence(
            words: words,
            precedingContext: precedingContext,
            topicMemory: topicMemory
        )
        let bwdQ8 = lexicon.neuralLM.isBackwardLoaded ? lexicon.neuralLM.scoreBackwardSentence(words: words) : 0
        return lexicon.neuralLM.extractTypoFeatures(
            typedCount: typed.count,
            intendedCount: readingBytes.count,
            syllableCount: cand.matchedSyllables.count,
            alignCostQ8: cost,
            substCount: stats.subst,
            omitCount: stats.omit,
            transposeCount: stats.trans,
            deleteCount: stats.del,
            maxPrimaryDriftQ8: maxPrimaryDrift,
            matchedTouchGainQ8: stats.matchedGainQ8,
            viterbiScoreQ8: cand.scoreQ8,
            cleanLatticeQ8: cleanLatQ8,
            fwdNeuralQ8: fwdQ8,
            bwdNeuralQ8: bwdQ8,
            spellingLL: spellingLL,
            spellingBoundary: boundaryQ8,
            words: words
        )
    }
}
