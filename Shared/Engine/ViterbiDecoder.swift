import Foundation
import simd

/// A ranked candidate presented in the candidate bar.
public struct LokeyCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sentence       // Full-buffer Viterbi sentence
        case userPhrase     // User learned / dynamically boosted phrase
        case lexiconPhrase  // Standard multi-char or single-char dictionary entry
        case jianpin        // Acronym match (e.g., zg -> 中国)
        case english        // Mixed English / CN-EN match (e.g., iPhone, GitHub, T恤)
        case emoji          // Native inline Emoji candidate (e.g., haha -> [哈哈, 😂])
        case rawInput       // Raw English letters typed by user
    }

    public let text: String
    /// Number of input `TouchSample` items consumed from index `0` when the user selects this candidate.
    public let consumedInputCount: Int
    /// Resolved canonical Pinyin syllables corresponding to `text` (empty for pure English/raw).
    public let matchedSyllables: [String]
    public let scoreQ8: Int
    public let kind: Kind
    public let isDeletableUserPhrase: Bool
    /// Final segmented lexical word when `kind == .sentence` (e.g. `"明天我们"` -> `"我们"`).
    public let trailingWord: String?

    public init(
        text: String,
        consumedInputCount: Int,
        matchedSyllables: [String],
        scoreQ8: Int,
        kind: Kind,
        isDeletableUserPhrase: Bool = false,
        trailingWord: String? = nil
    ) {
        self.text = text
        self.consumedInputCount = consumedInputCount
        self.matchedSyllables = matchedSyllables
        self.scoreQ8 = scoreQ8
        self.kind = kind
        self.isDeletableUserPhrase = isDeletableUserPhrase
        self.trailingWord = trailingWord
    }
}

public struct DecodeResult: Sendable, Equatable {
    /// Formatted preedit string shown above/in the candidate bar (e.g., `"wo'jin'tian"`).
    public let preeditDisplay: String
    public let candidates: [LokeyCandidate]
}

/// Combines 2D Gaussian spatial touch hypotheses, Pinyin syllable DAG construction,
/// `MmapLexicon` Trie traversal, and SQLite user memory into a fast (< 3 ms) Viterbi decoder.
public final class ViterbiDecoder: @unchecked Sendable {
    public let lexicon: MmapLexicon
    public let spatialModel: SpatialTouchModel
    public let userStore: UserLexiconStore

    /// High-frequency 3-letter English roots allowed in dynamic 2-word English compound segmentation (`applepie -> Apple pie`, `hotkey -> hot key`).
    private static let commonThreeLetterEnglishWords: Set<String> = [
        "app", "pro", "max", "air", "mac", "ios", "web", "api", "sdk", "net",
        "hub", "box", "map", "pay", "bar", "key", "log", "bug", "fix", "day",
        "new", "old", "big", "top", "hot", "red", "ice", "tea", "cup", "pie",
        "car", "bus", "dog", "cat", "one", "two", "all", "out", "off", "set",
        "get", "run", "try", "see", "you", "now", "low", "end", "sub", "tab",
    ]

    /// Explicit non-Pinyin 3-letter technical English tokens eligible for mid-sentence code-switching.
    private static let embeddedEnglishWhitelist3: Set<String> = [
        "app", "api", "bug", "cpu", "gpu", "ios", "mac", "pdf", "ppt", "pro",
        "sql", "ssh", "url", "usb", "vip", "vpn", "web", "xml", "zip",
    ]

    /// Optional offline supplementary entries supplied by `UIInputViewController.requestSupplementaryLexicon`
    /// (system Text Replacements & Contacts names).
    private struct SupplementaryContactItem {
        let phrase: String
        let syllables: [String]
        let compactQuanpin: String
        let xiaoheCode: String
        let ziranmaCode: String
        let jianpin: String
    }

    private(set) var supplementaryGeneration: UInt64 = 0
    private(set) var rawSupplementaryEntries: [(shortcut: String, phrase: String)] = []
    private(set) var supplementaryShortcuts: [(shortcut: String, phrase: String)] = []
    private var supplementaryContacts: [SupplementaryContactItem] = []

    // Only these exact terminal readings have a conversational recovery entry in
    // the compiled lexicon. Avoid additional mmap probes on ordinary keystrokes.
    private static let recoverableEndings: Set<String> = ["fawo", "fani", "haoma", "qupiao"]

    private static let standaloneReplies: Set<String> = [
        "收到", "明白", "谢谢", "好的", "没事", "晚安", "早安", "当然", "再见", "抱歉"
    ]

    private struct CommitPair {
        let first: String
        let second: String
        let weights: NeuralSentenceScorer.Vec32
        let bias: Float
        let firstThreshold: Float
        let secondThreshold: Float
        let lexicalCues: [String: Int8]

        init?(_ encoded: String) {
            let fields = encoded.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 8, let scale = Float(fields[2]), scale.isFinite,
                  let bias = Float(fields[3]), bias.isFinite,
                  let positive = Float(fields[4]), (0.1...4).contains(positive),
                  let negative = Float(fields[5]), (0.1...4).contains(negative),
                  fields[6].utf8.count == 64 else { return nil }
            var hex = fields[6][...]
            var lanes = Array(repeating: SIMD8<Float>.zero, count: 4)
            for index in 0..<32 {
                guard let byte = UInt8(hex.prefix(2), radix: 16) else { return nil }
                lanes[index / 8][index % 8] = Float(Int8(bitPattern: byte)) * scale
                hex = hex.dropFirst(2)
            }
            first = String(fields[0])
            second = String(fields[1])
            weights = .init(v0: lanes[0], v1: lanes[1], v2: lanes[2], v3: lanes[3])
            self.bias = bias
            firstThreshold = positive
            secondThreshold = negative
            var cues: [String: Int8] = [:]
            for item in fields[7].split(separator: ",") {
                let cue = item.split(separator: ":")
                guard cue.count == 2, let value = Int8(cue[1]) else { return nil }
                cues[String(cue[0])] = value
            }
            lexicalCues = cues
        }

        func lexicalFeature(_ suffix: String) -> Float {
            var low: Int8 = 0
            var high: Int8 = 0
            for start in suffix.indices {
                var end = start
                for _ in 0..<3 where end != suffix.endIndex {
                    end = suffix.index(after: end)
                    let token = String(suffix[start..<end])
                    let plain = lexicalCues[token] ?? 0
                    let terminal = end == suffix.endIndex ? lexicalCues[token + "^"] ?? 0 : 0
                    low = min(low, plain, terminal)
                    high = max(high, plain, terminal)
                }
            }
            return Float(Int(high) + Int(low)) / 40
        }
    }

    private var conversationalCounts: [String: Int] = [:]
    private var commitPairsByReading: [String: [CommitPair]] = [:]

    struct WordStaticTrait {
        let utf8Count: Int
        let isOneChar: Bool
        let fingerprint: HanFingerprint?
        let baseFlags: UInt32
        let extraCap: Int
        let curFlags: UInt32
    }

    /// Stateless lexicon-only caches safe to share strictly within one serial execution domain
    /// (`worker.decoder` <-> `worker.refiner.renderer`, or `main.decoder` <-> `main.commitRefiner.renderer`).
    final class LookupCache {
        /// Raw bigram transition bonus cache (`lexicon.associationBonusMap(after:)` without suffix backoff).
        var rawAssocMapCache: [String: [String: Int]] = [:]
        /// Persistent backed-off bigram transition bonus cache (`prevWord -> [nextWord: bonusQ8]`).
        var assocMapCache: [String: [String: Int]] = [:]
        // Negative filter only: collisions and non-Han spellings go through canonical String comparison.
        var assocFilterCache: [String: UInt64] = [:]
        /// Cached static lexical & grammatical bitflags per word surface.
        var wordTraitCache: [String: WordStaticTrait] = [:]
        /// Lock-free O(1)-evicting ring cache of 32-dim neural word records.
        var neuralRecordCache: [String: NeuralSentenceScorer.WordNeuralRecord] = [:]
        var neuralRecordRing: [String] = []
        var neuralRecordRingCursor: Int = 0
        /// Lossless `UInt64`-keyed syllable automaton cache.
        var syllableMatchCache: [UInt64: [PinyinSyllableAutomaton.ExpandedSyllable]] = [:]
        /// Packed `(nodeIndex << 26) | packedRime` cache for Trie dropped-initial edge resolution.
        var droppedInitialCache: [UInt64: [MmapLexicon.DroppedInitialEdgeHit]] = [:]
    }

    let lookupCache: LookupCache

    private var cachedInitHiddenContext: String? = nil
    private var cachedInitHiddenVec: NeuralSentenceScorer.Vec32 = .zero

    /// Incremental syllable lattice, word-span & Viterbi DP cache across consecutive keystrokes (`O(1)` tail update).
    private var cachedSamples: [TouchSample] = []
    private var cachedPosHyps: [[KeyHypothesis]] = []
    private var cachedPosHypsCap: Int = 0
    private var cachedArcsByStart: [Int: [SyllableArc]] = [:]
    private var cachedLatticeDepsByStart: [LatticeCacheDeps?] = []
    private var cachedSpansByStart: [Int: [WordSpan]] = [:]
    private var cachedMaxPosByStart: [Int: Int] = [:]
    private var cachedSpanDepsByStart: [SpanCacheDeps?] = []
    private var cachedDP: [[DPNode]] = []
    private var cachedDPSeedWord: String = ""
    private var cachedDPPrecedingContext: String = ""
    private var cachedDPTopicMemory: NeuralSentenceScorer.Vec32 = .zero
    private var cachedDPBeamK: Int = 0
    private var cachedSettings: LokeySettings?
    private var cachedSpatialGeneration: UInt64 = 0
    private var cachedUserGeneration: UInt64 = 0
    private var cachedWholeInputClean: Bool = false
    private var cachedFastCleanMode: Bool = false
    private var cachedHasApostrophe: Bool = false
    private var cachedIsPureEnglishCompound: Bool = false
    private var cachedWasUrgentCommit: Bool = false

    private struct CachedDecodeHistoryEntry {
        let samples: [TouchSample]
        let settings: LokeySettings
        let precedingContext: String?
        let topicMemory: NeuralSentenceScorer.Vec32
        let fastCleanSentenceOnly: Bool
        let skipStage5CAssociations: Bool
        let spatialGeneration: UInt64
        let userGeneration: UInt64
        let supplementaryGeneration: UInt64
        let wholeInputClean: Bool
        let hasApostrophe: Bool
        let isPureEnglishCompound: Bool
        let wasUrgentCommit: Bool
        let posHyps: [[KeyHypothesis]]
        let posHypsCap: Int
        let arcsByStart: [Int: [SyllableArc]]
        let latticeDepsByStart: [LatticeCacheDeps?]
        let spansByStart: [Int: [WordSpan]]
        let maxPosByStart: [Int: Int]
        let spanDepsByStart: [SpanCacheDeps?]
        let dp: [[DPNode]]
        let dpSeedWord: String
        let dpPrecedingContext: String
        let dpTopicMemory: NeuralSentenceScorer.Vec32
        let dpBeamK: Int
        let result: DecodeResult
    }
    private var recentDecodeHistory: [CachedDecodeHistoryEntry] = []

    public convenience init(
        lexicon: MmapLexicon,
        spatialModel: SpatialTouchModel = SpatialTouchModel(),
        userStore: UserLexiconStore = UserLexiconStore()
    ) {
        self.init(lexicon: lexicon, spatialModel: spatialModel, userStore: userStore, lookupCache: LookupCache())
    }

    init(
        lexicon: MmapLexicon,
        spatialModel: SpatialTouchModel = SpatialTouchModel(),
        userStore: UserLexiconStore = UserLexiconStore(),
        lookupCache: LookupCache
    ) {
        self.lexicon = lexicon
        self.spatialModel = spatialModel
        self.userStore = userStore
        self.lookupCache = lookupCache
    }

    public func fullHypothesesIfMatching(samples: [TouchSample], settings: LokeySettings) -> [[KeyHypothesis]]? {
        guard cachedPosHypsCap >= 7,
              !cachedFastCleanMode,
              settings.enableSpatialCorrection,
              cachedSpatialGeneration == spatialModel.modelGeneration,
              cachedSettings == settings,
              cachedSamples == samples,
              cachedPosHyps.count == samples.count else {
            return nil
        }
        return cachedPosHyps
    }

    public func setSupplementaryEntries(_ entries: [(shortcut: String, phrase: String)]) {
        supplementaryGeneration &+= 1
        self.rawSupplementaryEntries = entries

        var shortcuts: [(shortcut: String, phrase: String)] = []
        shortcuts.reserveCapacity(min(entries.count, 512))
        var seenShortcuts = Set<String>()

        var contacts: [SupplementaryContactItem] = []
        var seenContacts = Set<String>()

        for (rawShortcut, rawPhrase) in entries {
            let trimmedPhrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPhrase.isEmpty else { continue }

            let shortcutLower = rawShortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !shortcutLower.isEmpty,
               shortcutLower.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
               shortcutLower != trimmedPhrase.lowercased(),
               seenShortcuts.insert("\(shortcutLower)\0\(trimmedPhrase)").inserted {
                shortcuts.append((shortcutLower, trimmedPhrase))
            }

            if (2...5).contains(trimmedPhrase.count),
               trimmedPhrase.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }),
               contacts.count < 2048,
               seenContacts.insert(trimmedPhrase).inserted,
               let syls = lexicon.primarySyllables(forCJKName: trimmedPhrase),
               syls.count == trimmedPhrase.count {
                let xiaoheCodes = syls.compactMap {
                    PinyinSyllableAutomaton.primaryShuangpinCode(forCanonicalSyllable: $0, scheme: .xiaohe)
                }
                let ziranmaCodes = syls.compactMap {
                    PinyinSyllableAutomaton.primaryShuangpinCode(forCanonicalSyllable: $0, scheme: .ziranma)
                }
                contacts.append(
                    SupplementaryContactItem(
                        phrase: trimmedPhrase,
                        syllables: syls,
                        compactQuanpin: syls.joined(),
                        xiaoheCode: xiaoheCodes.count == syls.count ? xiaoheCodes.joined() : "",
                        ziranmaCode: ziranmaCodes.count == syls.count ? ziranmaCodes.joined() : "",
                        jianpin: String(syls.compactMap(\.first))
                    )
                )
            }
        }

        self.supplementaryShortcuts = shortcuts
        self.supplementaryContacts = contacts
    }

    /// Convenience helper for decoding plain ASCII test strings (synthesizing exact center taps).
    public func decode(
        _ rawInput: String,
        settings: LokeySettings = LokeySettings(),
        precedingContext: String? = nil,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero,
        fastCleanSentenceOnly: Bool = false,
        skipStage5CAssociations: Bool = false,
        isCancelled: () -> Bool = { false },
        isUrgentCommit: () -> Bool = { false }
    ) -> DecodeResult {
        let samples = rawInput.map { ch -> TouchSample in
            let pt: CGPoint? = settings.enableSpatialCorrection ? spatialModel.center(for: ch) : nil
            return TouchSample(primaryChar: ch, normalizedPoint: pt)
        }
        return decode(
            samples: samples,
            settings: settings,
            precedingContext: precedingContext,
            topicMemory: topicMemory,
            fastCleanSentenceOnly: fastCleanSentenceOnly,
            skipStage5CAssociations: skipStage5CAssociations,
            isCancelled: isCancelled,
            isUrgentCommit: isUrgentCommit
        )
    }

    // MARK: - Main Decoding Pipeline

    private struct SyllableArc {
        let start: Int
        let end: Int
        let syllableID: UInt16     // 0 if pure initial abbreviation
        let canonical: String
        let penaltyQ8: Int
        let isInitialOnly: Bool
        let isPrefixCompletion: Bool
        let isErhuaOnly: Bool
        let collapsesCleanSyllables: Bool
        let hasKeySubstitution: Bool
        let keySubstitutionCount: UInt8
        let isSoftClipped: Bool

        init(
            start: Int,
            end: Int,
            syllableID: UInt16,
            canonical: String,
            penaltyQ8: Int,
            isInitialOnly: Bool,
            isPrefixCompletion: Bool = false,
            isErhuaOnly: Bool = false,
            collapsesCleanSyllables: Bool = false,
            hasKeySubstitution: Bool = false,
            keySubstitutionCount: Int? = nil,
            isSoftClipped: Bool = false
        ) {
            self.start = start
            self.end = end
            self.syllableID = syllableID
            self.canonical = canonical
            self.penaltyQ8 = penaltyQ8
            self.isInitialOnly = isInitialOnly
            self.isPrefixCompletion = isPrefixCompletion
            self.isErhuaOnly = isErhuaOnly
            self.collapsesCleanSyllables = collapsesCleanSyllables
            self.hasKeySubstitution = hasKeySubstitution
            self.keySubstitutionCount = UInt8(clamping: keySubstitutionCount ?? (hasKeySubstitution ? 1 : 0))
            self.isSoftClipped = isSoftClipped
        }
    }

    private struct WordSpan: Equatable {
        let start: Int
        let end: Int
        let text: String
        let syllables: [String]
        let scoreQ8: Int
        let penaltyQ8: Int
        let isUserPhrase: Bool
        let lastWord: String
        let hasKeySubstitution: Bool
        let keySubstitutionCount: UInt8
        let isJianpinSpan: Bool
        let isEnglishSpan: Bool

        init(
            start: Int,
            end: Int,
            text: String,
            syllables: [String],
            scoreQ8: Int,
            penaltyQ8: Int,
            isUserPhrase: Bool,
            lastWord: String? = nil,
            hasKeySubstitution: Bool = false,
            keySubstitutionCount: UInt8? = nil,
            isJianpinSpan: Bool = false,
            isEnglishSpan: Bool = false
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.syllables = syllables
            self.scoreQ8 = scoreQ8
            self.penaltyQ8 = penaltyQ8
            self.isUserPhrase = isUserPhrase
            self.lastWord = lastWord ?? text
            self.hasKeySubstitution = hasKeySubstitution
            self.keySubstitutionCount = keySubstitutionCount ?? (hasKeySubstitution ? 1 : 0)
            self.isJianpinSpan = isJianpinSpan
            self.isEnglishSpan = isEnglishSpan
        }
    }

    private enum LatticeRegimeBit {
        static let nGE4: UInt16 = 1 << 0
        static let nGE5: UInt16 = 1 << 1
        static let nGE6: UInt16 = 1 << 2
        static let nGE8: UInt16 = 1 << 3
        static let nGE9: UInt16 = 1 << 4
        static let nGE12: UInt16 = 1 << 5
        static let urgent10: UInt16 = 1 << 6
        static let urgent16: UInt16 = 1 << 7
    }

    private enum SpanRegimeBit {
        static let nGE5: UInt16 = 1 << 0
        static let nGE6: UInt16 = 1 << 1
        static let nGE8: UInt16 = 1 << 2
        static let nGE9: UInt16 = 1 << 3
        static let nGE12: UInt16 = 1 << 4
        static let nGE15: UInt16 = 1 << 5
        static let nLE16: UInt16 = 1 << 6
        static let urgent10: UInt16 = 1 << 7
        static let urgent12: UInt16 = 1 << 8
        static let urgent18: UInt16 = 1 << 9
        static let urgent20: UInt16 = 1 << 10
    }

    private enum DPRegimeBit {
        static let nGE6: UInt16 = 1 << 0
        static let nGE8: UInt16 = 1 << 1
        static let nGE9: UInt16 = 1 << 2
        static let urgent10: UInt16 = 1 << 3
        static let urgent12: UInt16 = 1 << 4
        static let urgent: UInt16 = 1 << 5
    }

    @inline(__always)
    private static func latticeRegimeFlags(_ n: Int, urgent: Bool) -> UInt16 {
        var mask: UInt16 = 0
        if n >= 4 { mask |= LatticeRegimeBit.nGE4 }
        if n >= 5 { mask |= LatticeRegimeBit.nGE5 }
        if n >= 6 { mask |= LatticeRegimeBit.nGE6 }
        if n >= 8 { mask |= LatticeRegimeBit.nGE8 }
        if n >= 9 { mask |= LatticeRegimeBit.nGE9 }
        if n >= 12 { mask |= LatticeRegimeBit.nGE12 }
        if urgent && n >= 10 { mask |= LatticeRegimeBit.urgent10 }
        if urgent && n >= 16 { mask |= LatticeRegimeBit.urgent16 }
        return mask
    }

    @inline(__always)
    private static func spanRegimeFlags(_ n: Int, urgent: Bool) -> UInt16 {
        var mask: UInt16 = 0
        if n >= 5 { mask |= SpanRegimeBit.nGE5 }
        if n >= 6 { mask |= SpanRegimeBit.nGE6 }
        if n >= 8 { mask |= SpanRegimeBit.nGE8 }
        if n >= 9 { mask |= SpanRegimeBit.nGE9 }
        if n >= 12 { mask |= SpanRegimeBit.nGE12 }
        if n >= 15 { mask |= SpanRegimeBit.nGE15 }
        if n <= 16 { mask |= SpanRegimeBit.nLE16 }
        if urgent && n >= 10 { mask |= SpanRegimeBit.urgent10 }
        if urgent && n >= 12 { mask |= SpanRegimeBit.urgent12 }
        if urgent && n >= 18 { mask |= SpanRegimeBit.urgent18 }
        if urgent && n >= 20 { mask |= SpanRegimeBit.urgent20 }
        return mask
    }

    @inline(__always)
    private static func dpRegimeFlags(_ n: Int, urgent: Bool) -> UInt16 {
        var mask: UInt16 = 0
        if n >= 6 { mask |= DPRegimeBit.nGE6 }
        if n >= 8 { mask |= DPRegimeBit.nGE8 }
        if n >= 9 { mask |= DPRegimeBit.nGE9 }
        if urgent { mask |= DPRegimeBit.urgent }
        if urgent && n >= 10 { mask |= DPRegimeBit.urgent10 }
        if urgent && n >= 12 { mask |= DPRegimeBit.urgent12 }
        return mask
    }

    private struct LatticeCacheDeps {
        var maxRawReadEnd: Int
        var maxEndPos: Int
        var dependsOnWholeClean: Bool
        var dependsOnNMask: UInt16
        var readsPrevErArc: Bool
    }

    private struct SpanCacheDeps {
        var maxArcQueryPos: Int
        var maxRawReadEnd: Int
        var maxSpanEnd: Int
        var dependsOnWholeClean: Bool
        var dependsOnNMask: UInt16
    }

    // For unified Han scalars, canonical equality is identical to scalar equality.
    // Other spellings retain Swift's canonical String comparison. Equal hashes are
    // always verified against the full text, including across different segmentations.
    struct HanFingerprint {
        let value: UInt64
        let factor: UInt64
        var filterBit: UInt64 { 1 &<< ((value ^ (value >> 6) ^ (value >> 13)) & 63) }

        init?(_ text: String) {
            let prime: UInt64 = 16_777_619
            var value: UInt64 = 0
            var factor: UInt64 = 1
            for scalar in text.unicodeScalars {
                guard (0x4e00...0x9fff).contains(scalar.value) else { return nil }
                value = value &* prime &+ UInt64(scalar.value)
                factor = factor &* prime
            }
            self.value = value
            self.factor = factor
        }
    }

    private struct DPNode {
        let scoreQ8: Int
        let penaltyQ8: Int
        let lastSpanPenaltyQ8: Int
        let neuralScoreQ8: Int
        var baseScoreQ8: Int { scoreQ8 - neuralScoreQ8 }
        let textFingerprint: UInt64?
        let text: String
        let prevWord: String
        let lastWord: String
        let syllables: [String]
        let singleCharRun: Int
        let maxOneCharRun: Int
        let hasKeySubstitution: Bool
        let keySubstitutionCount: UInt8
        let isPureCleanOrJianpin: Bool
        let hasAccidentalSingleton: Bool
        let hidden: NeuralSentenceScorer.Vec32
        let wordCharEnds: UInt64
        let wordSylEnds: UInt64
    }

    private static func unpackSegmentedWords(
        text: String,
        syllables: [String],
        wordCharEnds: UInt64,
        wordSylEnds: UInt64
    ) -> [(word: String, syls: [String])]? {
        guard wordCharEnds != 0, wordSylEnds != 0 else { return nil }
        let segCount = wordCharEnds.nonzeroBitCount
        guard segCount >= 2, segCount == wordSylEnds.nonzeroBitCount else { return nil }
        let textCount = text.count
        let sylCount = syllables.count
        guard textCount <= 64, sylCount <= 64 else { return nil }
        guard (64 - wordCharEnds.leadingZeroBitCount) == textCount,
              (64 - wordSylEnds.leadingZeroBitCount) == sylCount else {
            return nil
        }

        var charBits = wordCharEnds
        var sylBits = wordSylEnds
        var segments: [(word: String, syls: [String])] = []
        segments.reserveCapacity(segCount)
        var charStart = text.startIndex
        var prevCharEnd = 0
        var prevSylEnd = 0
        while charBits != 0 && sylBits != 0 {
            let charEnd = charBits.trailingZeroBitCount + 1
            let sylEnd = sylBits.trailingZeroBitCount + 1
            guard charEnd > prevCharEnd, sylEnd > prevSylEnd else { return nil }
            let charFinish = text.index(charStart, offsetBy: charEnd - prevCharEnd)
            segments.append((word: String(text[charStart..<charFinish]), syls: Array(syllables[prevSylEnd..<sylEnd])))
            charStart = charFinish
            prevCharEnd = charEnd
            prevSylEnd = sylEnd
            charBits &= charBits - 1
            sylBits &= sylBits - 1
        }
        guard charBits == 0, sylBits == 0, charStart == text.endIndex, prevSylEnd == sylCount else {
            return nil
        }
        return segments
    }

    @inline(__always)
    private static func fastLower(_ ch: Character) -> (char: Character, ascii: UInt8) {
        if let v = ch.asciiValue {
            if v >= 0x61 && v <= 0x7A {
                return (ch, v)
            }
            if v >= 0x41 && v <= 0x5A {
                let lv = v &+ 32
                return (Character(UnicodeScalar(lv)), lv)
            }
            return (ch, v)
        }
        return (Character(ch.lowercased()), 0)
    }

    // The base path already pays its lexical, grammatical and touch costs. Only
    // the residual advantage over that path is evidence for changing the first choice.
    static func permitsNeuralFlip(netLead: Int, extraPenalty: Int, addsSyllable: Bool) -> Bool {
        // Chosen on 484 separate calibration sentences with aligned full and noisy inputs.
        // A substantially better spelling alignment independently supports the
        // challenger. It still has to finish ahead after all costs are paid.
        if extraPenalty <= -300 { return netLead >= 96 }
        let margin = extraPenalty > 70 ? (addsSyllable ? 900 : 650) : 300
        return netLead >= margin
    }

    /// Protects clean 3–4 syllable multi-word sentences (`kui'mei'le -> 亏没了`) against medial soft-clips
    /// (`kui -> kuai -> 快没了`), while leaving dropped-initial, fuzzy `z/c/s -> zh/ch/sh`, and `-n -> -ng` clips untouched.
    static func preservesCleanSentenceOverSoftClip(
        cleanSyllables: [String],
        cleanPenaltyQ8: Int,
        cleanScoreQ8: Int,
        cleanLastWordCount: Int,
        cleanMaxOneCharRun: Int?,
        noisySyllables: [String],
        noisyPenaltyQ8: Int,
        noisyScoreQ8: Int,
        noisyHasKeySub: Bool,
        wholeInputClean: Bool
    ) -> Bool {
        guard wholeInputClean,
              cleanPenaltyQ8 == 0,
              !noisyHasKeySub,
              noisyPenaltyQ8 >= 440,
              cleanLastWordCount >= 2,
              (3...4).contains(cleanSyllables.count),
              (cleanMaxOneCharRun ?? 1) <= 1,
              noisyScoreQ8 < cleanScoreQ8 + noisyPenaltyQ8 + 240 else {
            return false
        }
        if cleanSyllables.count == noisySyllables.count {
            for (c, t) in zip(cleanSyllables, noisySyllables) where c != t {
                if c.first != t.first { return false }
                if let c0 = c.first, t.hasPrefix("\(c0)h"), !c.hasPrefix("\(c0)h") { return false }
                if t == c + "g" { return false }
            }
        }
        return true
    }

    @inline(__always)
    private func neuralRecord(for word: String) -> NeuralSentenceScorer.WordNeuralRecord {
        if let hit = lookupCache.neuralRecordCache[word] { return hit }
        let rec = lexicon.neuralLM.wordRecord(for: word)
        if lookupCache.neuralRecordRing.count >= 2048 {
            let victim = lookupCache.neuralRecordRing[lookupCache.neuralRecordRingCursor]
            lookupCache.neuralRecordCache.removeValue(forKey: victim)
            lookupCache.neuralRecordRing[lookupCache.neuralRecordRingCursor] = word
            lookupCache.neuralRecordRingCursor += 1
            if lookupCache.neuralRecordRingCursor == 2048 {
                lookupCache.neuralRecordRingCursor = 0
            }
        } else {
            lookupCache.neuralRecordRing.append(word)
        }
        lookupCache.neuralRecordCache[word] = rec
        return rec
    }

    public func decode(
        samples: [TouchSample],
        settings: LokeySettings = LokeySettings(),
        precedingContext: String? = nil,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero,
        fastCleanSentenceOnly: Bool = false,
        skipStage5CAssociations: Bool = false,
        isCancelled: () -> Bool = { false },
        isUrgentCommit: () -> Bool = { false }
    ) -> DecodeResult {
        guard !samples.isEmpty else {
            if !fastCleanSentenceOnly {
                cachedSamples.removeAll(keepingCapacity: true)
                cachedPosHypsCap = 0
                cachedLatticeDepsByStart.removeAll(keepingCapacity: true)
                cachedSpanDepsByStart.removeAll(keepingCapacity: true)
                cachedDP.removeAll(keepingCapacity: true)
                recentDecodeHistory.removeAll(keepingCapacity: true)
            }
            return DecodeResult(preeditDisplay: "", candidates: [])
        }
        if isCancelled() {
            return DecodeResult(preeditDisplay: "", candidates: [])
        }

        if lookupCache.wordTraitCache.count > 8192 { lookupCache.wordTraitCache.removeAll(keepingCapacity: true) }
        if lookupCache.syllableMatchCache.count > 4096 { lookupCache.syllableMatchCache.removeAll(keepingCapacity: true) }
        if lookupCache.droppedInitialCache.count > 4096 { lookupCache.droppedInitialCache.removeAll(keepingCapacity: true) }

        let n = samples.count
        var rawChars: [Character] = []
        rawChars.reserveCapacity(n)
        var lowerChars: [Character] = []
        lowerChars.reserveCapacity(n)
        var lowerASCII: [UInt8] = []
        lowerASCII.reserveCapacity(n)
        var hasApostrophe = false
        for s in samples {
            let ch = s.primaryChar
            rawChars.append(ch)
            if ch == "'" {
                hasApostrophe = true
                lowerChars.append("'")
                lowerASCII.append(0x27)
            } else {
                let fl = Self.fastLower(ch)
                lowerChars.append(fl.char)
                lowerASCII.append(fl.ascii)
            }
        }
        let rawString = String(rawChars)
        let cleanLower: String
        if hasApostrophe {
            var filtered: [Character] = []
            filtered.reserveCapacity(n)
            for lc in lowerChars where lc != "'" { filtered.append(lc) }
            cleanLower = String(filtered)
        } else {
            cleanLower = String(lowerChars)
        }

        let urgentNow = isUrgentCommit()
        let spatialGen = spatialModel.modelGeneration
        let curUserGen = userStore.decodeSnapshot().generation
        if !urgentNow && n <= 16 {
            if let hitIdx = recentDecodeHistory.lastIndex(where: {
                $0.samples == samples
                    && $0.settings == settings
                    && $0.precedingContext == precedingContext
                    && $0.topicMemory == topicMemory
                    && $0.fastCleanSentenceOnly == fastCleanSentenceOnly
                    && $0.skipStage5CAssociations == skipStage5CAssociations
                    && $0.spatialGeneration == spatialGen
                    && $0.userGeneration == curUserGen
                    && $0.supplementaryGeneration == supplementaryGeneration
            }) {
                let hit = recentDecodeHistory[hitIdx]
                cachedSamples = hit.samples
                cachedPosHyps = hit.posHyps
                cachedPosHypsCap = hit.posHypsCap
                cachedArcsByStart = hit.arcsByStart
                cachedLatticeDepsByStart = hit.latticeDepsByStart
                cachedSpansByStart = hit.spansByStart
                cachedMaxPosByStart = hit.maxPosByStart
                cachedSpanDepsByStart = hit.spanDepsByStart
                cachedDP = hit.dp
                cachedDPSeedWord = hit.dpSeedWord
                cachedDPPrecedingContext = hit.dpPrecedingContext
                cachedDPTopicMemory = hit.dpTopicMemory
                cachedDPBeamK = hit.dpBeamK
                cachedSettings = hit.settings
                cachedSpatialGeneration = hit.spatialGeneration
                cachedUserGeneration = hit.userGeneration
                cachedWholeInputClean = hit.wholeInputClean
                cachedHasApostrophe = hit.hasApostrophe
                cachedIsPureEnglishCompound = hit.isPureEnglishCompound
                cachedWasUrgentCommit = hit.wasUrgentCommit
                cachedFastCleanMode = hit.fastCleanSentenceOnly
                return hit.result
            }
        }
        var canReusePrefix = cachedSettings == settings
            && cachedSpatialGeneration == spatialGen
            && cachedFastCleanMode == fastCleanSentenceOnly
            && cachedWasUrgentCommit == urgentNow

        var commonPrefixLen = 0
        if canReusePrefix {
            let maxCheck = min(n, cachedSamples.count)
            while commonPrefixLen < maxCheck && samples[commonPrefixLen] == cachedSamples[commonPrefixLen] {
                commonPrefixLen += 1
            }
        }
        if n <= 16 && !recentDecodeHistory.isEmpty && commonPrefixLen + 2 <= n {
            var bestHistIdx = -1
            var bestHistPrefix = commonPrefixLen + 1
            for (hIdx, entry) in recentDecodeHistory.enumerated() {
                guard entry.settings == settings,
                      entry.fastCleanSentenceOnly == fastCleanSentenceOnly,
                      entry.skipStage5CAssociations == skipStage5CAssociations,
                      entry.wasUrgentCommit == urgentNow,
                      entry.spatialGeneration == spatialGen,
                      entry.userGeneration == curUserGen,
                      entry.supplementaryGeneration == supplementaryGeneration,
                      entry.precedingContext == precedingContext,
                      entry.topicMemory == topicMemory else {
                    continue
                }
                let maxCheck = min(n, entry.samples.count)
                guard maxCheck > bestHistPrefix else { continue }
                var pLen = 0
                while pLen < maxCheck && samples[pLen] == entry.samples[pLen] {
                    pLen += 1
                }
                if pLen > bestHistPrefix {
                    bestHistPrefix = pLen
                    bestHistIdx = hIdx
                }
            }
            if bestHistIdx >= 0 {
                let hit = recentDecodeHistory[bestHistIdx]
                cachedSamples = hit.samples
                cachedPosHyps = hit.posHyps
                cachedPosHypsCap = hit.posHypsCap
                cachedArcsByStart = hit.arcsByStart
                cachedLatticeDepsByStart = hit.latticeDepsByStart
                cachedSpansByStart = hit.spansByStart
                cachedMaxPosByStart = hit.maxPosByStart
                cachedSpanDepsByStart = hit.spanDepsByStart
                cachedDP = hit.dp
                cachedDPSeedWord = hit.dpSeedWord
                cachedDPPrecedingContext = hit.dpPrecedingContext
                cachedDPTopicMemory = hit.dpTopicMemory
                cachedDPBeamK = hit.dpBeamK
                cachedSettings = hit.settings
                cachedSpatialGeneration = hit.spatialGeneration
                cachedUserGeneration = hit.userGeneration
                cachedWholeInputClean = hit.wholeInputClean
                cachedHasApostrophe = hit.hasApostrophe
                cachedIsPureEnglishCompound = hit.isPureEnglishCompound
                cachedWasUrgentCommit = hit.wasUrgentCommit
                cachedFastCleanMode = hit.fastCleanSentenceOnly
                canReusePrefix = true
                commonPrefixLen = bestHistPrefix
            }
        }
        // Let short incremental deltas (`<= 6` chars) complete in `< 0.4ms` so rapid burst typing
        // continuously advances `cachedSamples` / `cachedSpansByStart` / `cachedDP` instead of staying cold.
        func cancelProbe() -> Bool {
            (fastCleanSentenceOnly || (n - commonPrefixLen) > 6) && isCancelled()
        }

        // 1. Per-position spatial touch letter hypotheses (reusing unchanged prefix positions in O(1))
        let hypCap = (n >= 17 && urgentNow) ? 1 : ((n >= 10 && urgentNow) ? 2 : 7)
        let reusePosHypsCount = (canReusePrefix && hypCap <= cachedPosHypsCap)
            ? min(commonPrefixLen, cachedPosHyps.count)
            : 0
        var posHyps: [[KeyHypothesis]] = []
        posHyps.reserveCapacity(n)
        if reusePosHypsCount > 0 {
            if hypCap == cachedPosHypsCap {
                posHyps.append(contentsOf: cachedPosHyps[0..<reusePosHypsCount])
            } else {
                for idx in 0..<reusePosHypsCount {
                    posHyps.append(Array(cachedPosHyps[idx].prefix(hypCap)))
                }
            }
        }
        for idx in reusePosHypsCount..<n {
            let sample = samples[idx]
            if sample.primaryChar == "'" {
                posHyps.append([KeyHypothesis(char: "'", penaltyQ8: 0)])
            } else if fastCleanSentenceOnly && !settings.enableSpatialCorrection {
                posHyps.append([KeyHypothesis(char: lowerChars[idx], penaltyQ8: 0)])
            } else {
                posHyps.append(
                    spatialModel.hypotheses(
                        for: sample,
                        enabled: settings.enableSpatialCorrection,
                        useAdaptiveCalibration: settings.enableAdaptiveTouchCalibration,
                        maxCandidates: hypCap
                    )
                )
            }
        }

        let firstStart = hasApostrophe ? (samples.firstIndex(where: { $0.primaryChar != "'" }) ?? n) : 0
        let currentWholeClean: Bool
        if settings.pinyinScheme == .quanpin {
            currentWholeClean = cleanLower.count >= 4 && !hasApostrophe && lexicon.canSegmentCleanlyOrActiveTail(cleanLower)
        } else {
            let cleanBytes = Array(cleanLower.utf8)
            currentWholeClean = cleanBytes.count >= 4 && !hasApostrophe
                && PinyinSyllableAutomaton.canSegmentShuangpinCleanly(cleanBytes[...], scheme: settings.pinyinScheme, in: lexicon)
        }
        let prevN = cachedSamples.count
        let minCommon = min(commonPrefixLen, min(prevN, n))
        let wholeCleanUnchanged = (currentWholeClean == cachedWholeInputClean)

        // 2. Build Syllable Segmentation Lattice (DAG) across input positions [0 ..< n]
        let latticeRegimeChangedMask = Self.latticeRegimeFlags(prevN, urgent: cachedWasUrgentCommit)
            ^ Self.latticeRegimeFlags(n, urgent: urgentNow)
        let (arcsByStart, latticeDepsByStart, reusedLatticeStarts) = buildSyllableLattice(
            samples: samples,
            lowerChars: lowerChars,
            lowerASCII: lowerASCII,
            hasApostrophe: hasApostrophe,
            posHyps: posHyps,
            scheme: settings.pinyinScheme,
            fuzzy: settings.fuzzyOptions,
            enableErrorCorrection: settings.enableSpatialCorrection,
            canReuseLatticePrefix: canReusePrefix && cachedHasApostrophe == hasApostrophe,
            prevN: prevN,
            minCommon: minCommon,
            wholeCleanUnchanged: wholeCleanUnchanged,
            latticeRegimeChangedMask: latticeRegimeChangedMask,
            previousArcs: cachedArcsByStart,
            previousLatticeDeps: cachedLatticeDepsByStart,
            wholeInputCleanOverride: currentWholeClean,
            fastCleanSentenceOnly: fastCleanSentenceOnly,
            isCancelled: cancelProbe,
            urgentNow: urgentNow
        )
        if cancelProbe() {
            return DecodeResult(preeditDisplay: rawString, candidates: [])
        }

        let userSnap = userStore.decodeSnapshot()
        let userGen = userSnap.generation
        let spanRegimeChangedMask = Self.spanRegimeFlags(prevN, urgent: cachedWasUrgentCommit)
            ^ Self.spanRegimeFlags(n, urgent: urgentNow)
        let canReuseSpansBase = canReusePrefix
            && cachedUserGeneration == userGen
            && cachedHasApostrophe == hasApostrophe

        // 3. Extract multi-syllable & single-syllable dictionary WordSpans across the Syllable DAG
        let (spansByStart, maxPosByStart, spanDepsByStart, reusedSpanStarts, contiguousReusedStart, isPureEnglishCompound) = buildWordSpans(
            samples: samples,
            lowerChars: lowerChars,
            lowerASCII: lowerASCII,
            n: n,
            arcsByStart: arcsByStart,
            userSnapshot: userSnap,
            scheme: settings.pinyinScheme,
            enableErrorCorrection: settings.enableSpatialCorrection,
            wholeInputClean: currentWholeClean,
            canReuseSpansBase: canReuseSpansBase,
            reusedLatticeStarts: reusedLatticeStarts,
            prevN: prevN,
            minCommonCount: minCommon,
            wholeCleanUnchanged: wholeCleanUnchanged,
            previousIsPureEnglishCompound: cachedIsPureEnglishCompound,
            spanRegimeChangedMask: spanRegimeChangedMask,
            previousSpans: cachedSpansByStart,
            previousMaxPos: cachedMaxPosByStart,
            previousSpanDeps: cachedSpanDepsByStart,
            fastCleanSentenceOnly: fastCleanSentenceOnly,
            isCancelled: cancelProbe,
            urgentNow: urgentNow
        )
        if cancelProbe() {
            return DecodeResult(preeditDisplay: rawString, candidates: [])
        }

        // Compute exact prefix DP reuse bound BEFORE replacing `cachedSpansByStart`:
        // `dp[0...b]` depends strictly on spans `(i -> end)` with `0 <= i < end <= b` and transition checks below,
        // enabling prefix DP reuse across ALL `n >= 2`.
        let reusableDPBound: Int = {
            let contextKey = precedingContext ?? ""
            let seedWord = Self.extractTrailingChineseSuffix(from: contextKey, maxChars: 3)
            let activeBeamK = (urgentNow && n >= 12) ? 2 : ((n >= 10 && urgentNow) ? 3 : (fastCleanSentenceOnly ? 5 : 10))
            guard firstStart == 0,
                  canReusePrefix,
                  cachedUserGeneration == userGen,
                  cachedDPBeamK == activeBeamK,
                  cachedDPSeedWord == seedWord,
                  cachedDPPrecedingContext == contextKey,
                  cachedDPTopicMemory == topicMemory,
                  !urgentNow || wholeCleanUnchanged,
                  prevN >= 2, n >= 2 else {
                return 0
            }
            let prevTrailingM = prevN >= 3 && (cachedSamples[prevN - 1].primaryChar == "m" || cachedSamples[prevN - 1].primaryChar == "M")
            let curTrailingM = n >= 3 && (samples[n - 1].primaryChar == "m" || samples[n - 1].primaryChar == "M")
            let eofCap = (prevTrailingM || curTrailingM) ? min(prevN - 2, n - 2) : min(prevN - 1, n - 1)
            let maxCandBound = min(minCommon, min(eofCap, cachedDP.count - 1))
            guard maxCandBound >= 1 else { return 0 }

            let dpRegimeChanged = Self.dpRegimeFlags(prevN, urgent: cachedWasUrgentCommit)
                ^ Self.dpRegimeFlags(n, urgent: urgentNow)
            if contiguousReusedStart >= maxCandBound
                && wholeCleanUnchanged
                && dpRegimeChanged == 0
                && maxCandBound <= max(0, minCommon - 8) {
                return maxCandBound
            }

            let minPrevCurN = min(prevN, n)
            var verifiedBound = maxCandBound
            for i in 0..<maxCandBound {
                if i >= verifiedBound { break }
                let curList = spansByStart[i] ?? []
                if !(i < reusedSpanStarts.count && reusedSpanStarts[i]) {
                    let prevList = cachedSpansByStart[i] ?? []
                    var cIdx = 0
                    var pIdx = 0
                    while true {
                        let cValid = cIdx < curList.count && curList[cIdx].end <= verifiedBound
                        let pValid = pIdx < prevList.count && prevList[pIdx].end <= verifiedBound
                        if !cValid && !pValid { break }
                        if cValid != pValid || curList[cIdx] != prevList[pIdx] {
                            let divergeEnd = min(
                                cValid ? curList[cIdx].end : verifiedBound + 1,
                                pValid ? prevList[pIdx].end : verifiedBound + 1
                            )
                            verifiedBound = min(verifiedBound, max(0, divergeEnd - 1))
                            break
                        }
                        cIdx += 1
                        pIdx += 1
                    }
                    if verifiedBound <= i { break }
                }
                if dpRegimeChanged != 0 || !wholeCleanUnchanged || prevN >= 9 {
                    let beamAtI = cachedDP[i]
                    let beamHasKeySub = beamAtI.contains(where: \.hasKeySubstitution)
                    let beamHasMultiChar = beamAtI.contains(where: { !$0.lastWord.isEmpty && $0.lastWord.utf8.count >= 6 })
                    let beamHasAnyLastWord = beamAtI.contains(where: { !$0.lastWord.isEmpty })
                    let beamHasZeroPenOneChar = i > 0 && beamAtI.contains(where: { $0.lastSpanPenaltyQ8 == 0 && $0.lastWord.utf8.count == 3 })
                    for sp in curList {
                        if sp.end > verifiedBound { break }
                        let hasKeySub = sp.hasKeySubstitution || beamHasKeySub
                        if hasKeySub {
                            if !wholeCleanUnchanged && (n < 9 || prevN < 9 || i + 8 >= minPrevCurN) {
                                verifiedBound = min(verifiedBound, sp.end - 1)
                                break
                            }
                            if prevN >= 9 && n >= 9 && (i + 8 >= minPrevCurN || max(sp.end, i + 6) > minCommon) {
                                verifiedBound = min(verifiedBound, sp.end - 1)
                                break
                            }
                        }
                        if (dpRegimeChanged & DPRegimeBit.nGE6) != 0
                            && !sp.isEnglishSpan
                            && sp.syllables.count >= 2
                            && beamHasAnyLastWord {
                            verifiedBound = min(verifiedBound, sp.end - 1)
                            break
                        }
                        if (dpRegimeChanged & (DPRegimeBit.nGE8 | DPRegimeBit.urgent10 | DPRegimeBit.urgent)) != 0
                            && !sp.isEnglishSpan
                            && sp.syllables.count >= 2
                            && beamHasMultiChar {
                            verifiedBound = min(verifiedBound, sp.end - 1)
                            break
                        }
                        if (dpRegimeChanged & DPRegimeBit.nGE9) != 0
                            && (beamHasZeroPenOneChar || hasKeySub) {
                            verifiedBound = min(verifiedBound, sp.end - 1)
                            break
                        }
                    }
                    if verifiedBound <= i { break }
                }
            }
            return verifiedBound
        }()

        // 4. Run Top-K Bigram Viterbi Dynamic Programming from firstStart -> n (reusing cached prefix DP in O(1)!)
        let topSentences = solveViterbiTopPaths(
            samples: samples,
            lowerChars: lowerChars,
            lowerASCII: lowerASCII,
            n: n,
            firstStart: firstStart,
            spansByStart: spansByStart,
            maxPosByStart: maxPosByStart,
            userSnapshot: userSnap,
            precedingContext: precedingContext,
            topicMemory: topicMemory,
            wholeInputClean: currentWholeClean,
            reusableDPBound: reusableDPBound,
            fastCleanSentenceOnly: fastCleanSentenceOnly,
            isCancelled: cancelProbe,
            urgentNow: urgentNow
        )
        if cancelProbe() {
            return DecodeResult(preeditDisplay: rawString, candidates: [])
        }

        cachedSamples = samples
        cachedPosHyps = posHyps
        cachedPosHypsCap = hypCap
        cachedArcsByStart = arcsByStart
        cachedLatticeDepsByStart = latticeDepsByStart
        cachedSpansByStart = spansByStart
        cachedMaxPosByStart = maxPosByStart
        cachedSpanDepsByStart = spanDepsByStart
        cachedSettings = settings
        cachedSpatialGeneration = spatialGen
        cachedUserGeneration = userGen
        cachedWholeInputClean = currentWholeClean
        cachedHasApostrophe = hasApostrophe
        cachedIsPureEnglishCompound = isPureEnglishCompound
        cachedWasUrgentCommit = urgentNow
        cachedFastCleanMode = fastCleanSentenceOnly
        let bestSentence = topSentences.first

        // 5. Assemble deduplicated, ranked candidate list
        var candidates: [LokeyCandidate] = []
        candidates.reserveCapacity(48)
        var seenTexts = Set<String>()

        func appendCandidate(_ c: LokeyCandidate) {
            guard !c.text.isEmpty, seenTexts.insert(c.text).inserted else { return }
            candidates.append(c)
        }

        // 5A. System Text Replacements / Contacts supplementary matches (highest explicit user intent)
        if !cleanLower.isEmpty {
            for (shortcut, phrase) in supplementaryShortcuts where shortcut == cleanLower {
                appendCandidate(
                    LokeyCandidate(
                        text: phrase,
                        consumedInputCount: n,
                        matchedSyllables: [],
                        scoreQ8: -200,
                        kind: .userPhrase
                    )
                )
            }
            for item in supplementaryContacts {
                let code: String
                switch settings.pinyinScheme {
                case .quanpin: code = item.compactQuanpin
                case .xiaohe: code = item.xiaoheCode
                case .ziranma: code = item.ziranmaCode
                }
                guard !code.isEmpty, code == cleanLower else { continue }
                appendCandidate(
                    LokeyCandidate(
                        text: item.phrase,
                        consumedInputCount: n,
                        matchedSyllables: item.syllables,
                        scoreQ8: -240,
                        kind: .userPhrase
                    )
                )
            }
        }

        // 5B. User SQLite learned phrases (exact or Jianpin match for full buffer)
        let userHits = userStore.lookup(query: cleanLower, limit: 6)
        var exactUserHitCount = 0
        for up in userHits where up.compactPinyin == cleanLower || (settings.pinyinScheme == .quanpin && up.jianpin == cleanLower) {
            let prevCount = candidates.count
            appendCandidate(
                LokeyCandidate(
                    text: up.surface,
                    consumedInputCount: n,
                    matchedSyllables: up.pinyinNormalized.split(separator: " ").map(String.init),
                    scoreQ8: up.dynamicBoostQ8,
                    kind: .userPhrase,
                    isDeletableUserPhrase: true
                )
            )
            if candidates.count > prevCount {
                exactUserHitCount += 1
            }
        }
        if settings.pinyinScheme != .quanpin && !cleanLower.isEmpty {
            for up in userStore.allPhrases(limit: 256) {
                let syls = up.pinyinNormalized.split(separator: " ").map(String.init)
                guard !syls.isEmpty else { continue }
                var encoded = ""
                encoded.reserveCapacity(syls.count * 2)
                var validShuangpin = true
                for syl in syls {
                    guard let spCode = PinyinSyllableAutomaton.primaryShuangpinCode(
                        forCanonicalSyllable: syl,
                        scheme: settings.pinyinScheme
                    ) else {
                        validShuangpin = false
                        break
                    }
                    encoded.append(spCode)
                }
                guard validShuangpin && encoded == cleanLower else { continue }
                let prevCount = candidates.count
                appendCandidate(
                    LokeyCandidate(
                        text: up.surface,
                        consumedInputCount: n,
                        matchedSyllables: syls,
                        scoreQ8: up.dynamicBoostQ8,
                        kind: .userPhrase,
                        isDeletableUserPhrase: true
                    )
                )
                if candidates.count > prevCount {
                    exactUserHitCount += 1
                }
            }
        }

        // 5C. Full-input single-phrase exact dictionary matches & Top-K Viterbi full-sentence candidates
        let leftContext2 = Self.extractTrailingChineseSuffix(from: precedingContext ?? "", maxChars: 2)
        let allowArchaicLiaode = Self.isLicensedLiaodePrefix(leftContext2)
        var fullBufferSpans: [WordSpan] = (spansByStart[firstStart] ?? [])
            .filter { $0.end == n }
            .map { sp in
                if !allowArchaicLiaode && sp.text == "了得" {
                    return WordSpan(
                        start: sp.start,
                        end: sp.end,
                        text: sp.text,
                        syllables: sp.syllables,
                        scoreQ8: sp.scoreQ8 - 460,
                        penaltyQ8: sp.penaltyQ8,
                        isUserPhrase: sp.isUserPhrase,
                        lastWord: sp.lastWord,
                        hasKeySubstitution: sp.hasKeySubstitution,
                        keySubstitutionCount: sp.keySubstitutionCount,
                        isJianpinSpan: sp.isJianpinSpan,
                        isEnglishSpan: sp.isEnglishSpan
                    )
                }
                return sp
            }

        let singleSylExactIDs: [UInt16]
        if firstStart == 0 && !hasApostrophe {
            if settings.pinyinScheme == .quanpin {
                if n <= 6, let exactSID = lexicon.syllableToID[cleanLower], exactSID > 0 {
                    singleSylExactIDs = [exactSID]
                } else {
                    singleSylExactIDs = []
                }
            } else if n == 2 && cleanLower.count == 2 {
                let bytes = Array(cleanLower.utf8)
                singleSylExactIDs = PinyinSyllableAutomaton.matchShuangpinPair(
                    b0: bytes[0],
                    b1: bytes[1],
                    scheme: settings.pinyinScheme,
                    in: lexicon,
                    fuzzy: settings.fuzzyOptions
                ).filter { $0.penaltyQ8 == 0 }.map(\.syllableID)
            } else {
                singleSylExactIDs = []
            }
        } else {
            singleSylExactIDs = []
        }
        var singleSylExactOrderedSpans: [WordSpan] = []
        var hasBoostedSingleSylUnigram = false
        if !singleSylExactIDs.isEmpty {
            var scoredExact: [(idx: Int, span: WordSpan)] = []
            var seqIdx = 0
            for exactSID in singleSylExactIDs.prefix(2) {
                let canonSyl = lexicon.idToSyllable[Int(exactSID)]
                guard let exactNode = lexicon.step(from: lexicon.rootNodeIndex, syllableID: exactSID),
                      fullBufferSpans.contains(where: { $0.penaltyQ8 == 0 && !$0.hasKeySubstitution && $0.syllables.count == 1 && $0.syllables[0] == canonSyl }) else {
                    continue
                }
                let uniMap = userSnap.unigramEntries(compactPinyin: canonSyl)
                let rawExactWords = lexicon.words(at: exactNode, limit: uniMap == nil ? 28 : 48)
                if !rawExactWords.isEmpty {
                    let topExact0Score = rawExactWords[0].scoreQ8
                    let fourthExactScore = rawExactWords[min(3, rawExactWords.count - 1)].scoreQ8
                    scoredExact.reserveCapacity(scoredExact.count + rawExactWords.count)
                    for (wIdx, w) in rawExactWords.enumerated() {
                        var effScore = w.scoreQ8
                        if wIdx > 0, w.text.count == 1, let entry = uniMap?[w.text] {
                            let effUses = Double(entry.count) * entry.recencyDecay
                            if effUses >= 2.7 {
                                let cap = (topExact0Score >= -1800) ? (topExact0Score - 60) : (topExact0Score + 40)
                                effScore = min(cap, max(w.scoreQ8 + 960, min(w.scoreQ8 + 1350, fourthExactScore + 60)))
                                hasBoostedSingleSylUnigram = true
                            } else if effUses >= 1.5 {
                                effScore = min(topExact0Score - 60, max(w.scoreQ8 + 800, min(w.scoreQ8 + 1250, fourthExactScore + 30)))
                                hasBoostedSingleSylUnigram = true
                            } else if effUses >= 0.4 {
                                let delta = Int((380.0 * min(1.0, effUses)).rounded())
                                effScore = min(topExact0Score - 80, w.scoreQ8 + delta)
                                hasBoostedSingleSylUnigram = true
                            }
                        }
                        if wIdx < 28 || effScore > w.scoreQ8 {
                            scoredExact.append((
                                seqIdx,
                                WordSpan(
                                    start: 0,
                                    end: n,
                                    text: w.text,
                                    syllables: [canonSyl],
                                    scoreQ8: effScore,
                                    penaltyQ8: 0,
                                    isUserPhrase: false
                                )
                            ))
                            seqIdx += 1
                        }
                    }
                }
            }
            if !scoredExact.isEmpty {
                scoredExact.sort { a, b in
                    if a.span.scoreQ8 != b.span.scoreQ8 { return a.span.scoreQ8 > b.span.scoreQ8 }
                    return a.idx < b.idx
                }
                singleSylExactOrderedSpans = scoredExact.map(\.span)
                if hasBoostedSingleSylUnigram {
                    var existingByText = Dictionary(uniqueKeysWithValues: fullBufferSpans.map { ($0.text, $0) })
                    for sp in singleSylExactOrderedSpans {
                        if let prev = existingByText[sp.text], prev.scoreQ8 >= sp.scoreQ8 {
                            continue
                        }
                        existingByText[sp.text] = sp
                    }
                    fullBufferSpans = Array(existingByText.values)
                }
            }
        }

        fullBufferSpans.sort { $0.scoreQ8 > $1.scoreQ8 }
        var fullSpanByText: [String: WordSpan] = [:]
        fullSpanByText.reserveCapacity(fullBufferSpans.count)
        for sp in fullBufferSpans where fullSpanByText[sp.text] == nil {
            fullSpanByText[sp.text] = sp
        }

        let bestNoisySingleSylScore = fullBufferSpans
            .first(where: { $0.penaltyQ8 > 0 || $0.hasKeySubstitution })?.scoreQ8 ?? Int.min
        let exactSingleSylZeroPrimaryDrift = !singleSylExactOrderedSpans.isEmpty
            && posHyps.indices.allSatisfy { idx in
                let lc = lowerChars[idx]
                return posHyps[idx].contains(where: { $0.char == lc && $0.penaltyQ8 == 0 })
            }
        let reserveSingleSylExactCount: Int
        if singleSylExactOrderedSpans.count >= 4
            && bestNoisySingleSylScore <= singleSylExactOrderedSpans[0].scoreQ8 + 450 {
            reserveSingleSylExactCount = 4
        } else if exactSingleSylZeroPrimaryDrift,
                  let topExact = singleSylExactOrderedSpans.first,
                  topExact.scoreQ8 >= -3100 {
            reserveSingleSylExactCount = min(4, singleSylExactOrderedSpans.count)
        } else {
            reserveSingleSylExactCount = 0
        }
        let reserveTopFourSingleSylExact = reserveSingleSylExactCount > 0

        // Guard exact/orthographic in-vocabulary words (`siji -> 司机`, `jine -> 金额`, `nushi -> 女士`, `qunaa -> 去哪啊`)
        // against dead-center neighbor substitutions (`自己`, `不是`), prefix completions (`技能`), dropped-`h` (`侵害`),
        // and syllable-collapsing mutations (`全`).
        let strongExactFullWord = fullBufferSpans.first(where: { $0.penaltyQ8 <= 70 && $0.scoreQ8 >= -2800 })
        let cleanExactFullWord = fullBufferSpans.first(where: { $0.penaltyQ8 <= 70 && $0.scoreQ8 >= -3650 })
        let exactCompleteWord = fullBufferSpans.first(where: { $0.penaltyQ8 <= 70 && $0.scoreQ8 >= -3950 })
        var promotedCleanExactWord: WordSpan? = nil

        // If Viterbi found multi-word sentences covering 0..<n, compare with fullBufferSpans
        if let sent = bestSentence, sent.end == n {
            let promotedGuardSpan: WordSpan? = {
                if let completeWord = exactCompleteWord,
                   sent.penaltyQ8 > 70,
                   sent.syllables.count < completeWord.syllables.count,
                   sent.scoreQ8 < completeWord.scoreQ8 + 650 {
                    return completeWord
                }
                if let strongWord = strongExactFullWord,
                   sent.penaltyQ8 >= 240,
                   sent.scoreQ8 < strongWord.scoreQ8 + 860 {
                    return strongWord
                }
                if let cleanWord = cleanExactFullWord,
                   sent.penaltyQ8 >= 240 && sent.penaltyQ8 != 370 && sent.penaltyQ8 != 470,
                   sent.scoreQ8 < cleanWord.scoreQ8 + 600 {
                    return cleanWord
                }
                if let cleanWord = cleanExactFullWord,
                   sent.penaltyQ8 >= 485,
                   sent.scoreQ8 < cleanWord.scoreQ8 + 600 {
                    return cleanWord
                }
                if let completeWord = exactCompleteWord,
                   sent.penaltyQ8 > 70,
                   sent.syllables.count == completeWord.syllables.count,
                   sent.syllables.dropLast() == completeWord.syllables.dropLast(),
                   let sLast = sent.syllables.last,
                   let cLast = completeWord.syllables.last {
                    if sLast == cLast && cLast.count == 1 && sent.scoreQ8 < completeWord.scoreQ8 + 900 {
                        return completeWord
                    }
                    if sLast.count > cLast.count && sLast.hasPrefix(cLast) && sent.scoreQ8 < completeWord.scoreQ8 + 680 {
                        return completeWord
                    }
                }
                return nil
            }()
            if let cleanWord = promotedGuardSpan {
                promotedCleanExactWord = cleanWord
                let cleanFloor = max(-3350, cleanWord.scoreQ8 - 360)
                for exactSp in fullBufferSpans.filter({ $0.penaltyQ8 <= 70 && $0.scoreQ8 >= cleanFloor }).prefix(3) {
                    appendCandidate(
                        LokeyCandidate(
                            text: exactSp.text,
                            consumedInputCount: n,
                            matchedSyllables: exactSp.syllables,
                            scoreQ8: exactSp.scoreQ8,
                            kind: exactSp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                            isDeletableUserPhrase: exactSp.isUserPhrase
                        )
                    )
                }
            } else if !(reserveTopFourSingleSylExact
                        && fullBufferSpans.first.map({ $0.syllables.count == 1 && ($0.penaltyQ8 > 0 || $0.hasKeySubstitution) }) == true),
                      let topFullWord = fullBufferSpans.first {
                let collapsesCleanSentence = sent.penaltyQ8 <= 70
                    && topFullWord.penaltyQ8 > 70
                    && topFullWord.syllables.count < sent.syllables.count
                let threshold: Int
                if collapsesCleanSentence {
                    threshold = sent.scoreQ8 + 650
                } else if sent.penaltyQ8 <= 70 && strongExactFullWord != nil && topFullWord.penaltyQ8 >= 240 && topFullWord.penaltyQ8 != 470 {
                    threshold = sent.scoreQ8 + 860
                } else if sent.penaltyQ8 <= 70 && exactCompleteWord != nil && topFullWord.penaltyQ8 >= 240 && topFullWord.penaltyQ8 != 470 {
                    let isSingleVowelInitialHijack = topFullWord.syllables == sent.syllables && sent.syllables.last?.count == 1
                    threshold = sent.scoreQ8 + (isSingleVowelInitialHijack ? 900 : 680)
                } else if Self.preservesCleanSentenceOverSoftClip(
                    cleanSyllables: sent.syllables,
                    cleanPenaltyQ8: sent.penaltyQ8,
                    cleanScoreQ8: sent.scoreQ8,
                    cleanLastWordCount: sent.lastWord.count,
                    cleanMaxOneCharRun: nil,
                    noisySyllables: topFullWord.syllables,
                    noisyPenaltyQ8: topFullWord.penaltyQ8,
                    noisyScoreQ8: topFullWord.scoreQ8,
                    noisyHasKeySub: topFullWord.hasKeySubstitution,
                    wholeInputClean: currentWholeClean
                ) {
                    threshold = sent.scoreQ8 + topFullWord.penaltyQ8 + 240
                } else if sent.penaltyQ8 <= 70 && topFullWord.penaltyQ8 >= 485 {
                    threshold = sent.scoreQ8 + 560
                } else if sent.penaltyQ8 <= 70 && topFullWord.penaltyQ8 > 70 {
                    threshold = sent.scoreQ8 + 120
                } else if topFullWord.hasKeySubstitution && !sent.hasKeySubstitution {
                    threshold = sent.scoreQ8 + 120
                } else {
                    threshold = sent.scoreQ8 - 80
                }
                if topFullWord.scoreQ8 >= threshold {
                    appendCandidate(
                        LokeyCandidate(
                            text: topFullWord.text,
                            consumedInputCount: n,
                            matchedSyllables: topFullWord.syllables,
                            scoreQ8: topFullWord.scoreQ8,
                            kind: topFullWord.isUserPhrase ? .userPhrase : .lexiconPhrase,
                            isDeletableUserPhrase: topFullWord.isUserPhrase
                        )
                    )
                }
            }
            let orderedSentences: [WordSpan]
            if !sent.hasKeySubstitution && topSentences.count > 2 {
                let head = topSentences[0]
                let rest = topSentences.dropFirst().sorted { a, b in
                    if a.keySubstitutionCount != b.keySubstitutionCount {
                        return a.keySubstitutionCount < b.keySubstitutionCount
                    }
                    return a.scoreQ8 > b.scoreQ8
                }
                orderedSentences = [head] + rest
            } else {
                orderedSentences = topSentences
            }
            func emitCleanPrefixSpatialTailDiversity() {
                // 5C-alt. Clean-Prefix + Spatial-Tail Quanpin Diversity (`wolaissb` -> `#1 我来试试吧`, `#2 我来三`, `#3 我来散`;
                // `wolaiss` -> `#1 我来试试`, `#2 我来的`, `#3 我来大` ahead of prefix-mutated `*我老大`):
                // Keep 0-substitution clean prefix `cleanNode` intact and surface single-syllable spatial recoveries on the tail (`ssb -> san`).
                guard sent.end == n, !sent.hasKeySubstitution, sent.penaltyQ8 >= 350,
                      firstStart == 0, !cachedDP.isEmpty else { return }
                let maxPrePos = min(n - 2, cachedDP.count - 1)
                guard maxPrePos >= 2 else { return }
                var cleanTailPos = 0
                var cleanTailNode: DPNode? = nil
                for pos in stride(from: maxPrePos, through: 2, by: -1) {
                    let tailLen = n - pos
                    guard (2...4).contains(tailLen) else { continue }
                    let tailHasNoVowel = samples[pos..<n].allSatisfy { s in
                        let lc = s.primaryChar.lowercased()
                        return lc != "a" && lc != "e" && lc != "i" && lc != "o" && lc != "u" && lc != "v" && lc != "'"
                    }
                    guard tailHasNoVowel else { continue }
                    if let cNode = cachedDP[pos].first(where: { !$0.text.isEmpty && $0.keySubstitutionCount == 0 && $0.penaltyQ8 <= 140 }) {
                        cleanTailPos = pos
                        cleanTailNode = cNode
                        break
                    }
                }
                if let cNode = cleanTailNode, cleanTailPos >= 2, let tailSpans = spansByStart[cleanTailPos] {
                    let spatialTailHits = tailSpans
                        .filter { $0.end == n && $0.syllables.count == 1 && $0.syllables[0].utf8.count >= 2 && $0.hasKeySubstitution }
                        .sorted { $0.scoreQ8 > $1.scoreQ8 }
                    for sp in spatialTailHits.prefix(3) {
                        appendCandidate(
                            LokeyCandidate(
                                text: cNode.text + sp.text,
                                consumedInputCount: n,
                                matchedSyllables: cNode.syllables + sp.syllables,
                                scoreQ8: cNode.scoreQ8 + sp.scoreQ8 - 210,
                                kind: .sentence,
                                trailingWord: sp.text
                            )
                        )
                    }
                }
            }

            var emittedSpatialTailDiversity = false
            for (sIdx, altSent) in orderedSentences.enumerated() where altSent.end == n {
                if ((reserveTopFourSingleSylExact && (sIdx >= 1 || altSent.penaltyQ8 > 0 || altSent.hasKeySubstitution))
                    || (sIdx >= 1 && hasBoostedSingleSylUnigram))
                    && altSent.syllables.count == 1 {
                    continue
                }
                if sIdx >= 1 && altSent.hasKeySubstitution && !emittedSpatialTailDiversity {
                    emittedSpatialTailDiversity = true
                    emitCleanPrefixSpatialTailDiversity()
                }
                let matchedFull = fullSpanByText[altSent.text]
                if sIdx >= 1, matchedFull == nil, cleanExactFullWord != nil {
                    // Emit clean 0-penalty complete dictionary words (`拔河`, `八核`, `黏连`, `断触`) BEFORE
                    // lower-scoring secondary `sIdx >= 1` multi-word stitched fragments (`吧和`, `把和`),
                    // without pushing higher-scoring grammatical `V + 的/了` (`叫的`) behind rarer entries (`焦的`)!
                    let minExactFloor = max(-3450, altSent.scoreQ8 - 40)
                    for exactSp in fullBufferSpans.filter({ $0.penaltyQ8 <= 70 && $0.scoreQ8 >= minExactFloor }).prefix(3) {
                        appendCandidate(
                            LokeyCandidate(
                                text: exactSp.text,
                                consumedInputCount: n,
                                matchedSyllables: exactSp.syllables,
                                scoreQ8: exactSp.scoreQ8,
                                kind: exactSp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                                isDeletableUserPhrase: exactSp.isUserPhrase
                            )
                        )
                    }
                }
                if sIdx > 0 && !(altSent.penaltyQ8 <= 70 && sent.penaltyQ8 > 70) && altSent.scoreQ8 < sent.scoreQ8 - 880 {
                    continue
                }
                appendCandidate(
                    LokeyCandidate(
                        text: altSent.text,
                        consumedInputCount: n,
                        matchedSyllables: altSent.syllables,
                        scoreQ8: altSent.scoreQ8,
                        kind: matchedFull.map { $0.isUserPhrase ? .userPhrase : .lexiconPhrase } ?? .sentence,
                        isDeletableUserPhrase: matchedFull?.isUserPhrase ?? false,
                        trailingWord: matchedFull == nil ? altSent.lastWord : nil
                    )
                )
            }
            if !emittedSpatialTailDiversity {
                emitCleanPrefixSpatialTailDiversity()
            }
        }

        if reserveTopFourSingleSylExact {
            // Keep slots #0..#(reserveSingleSylExactCount-1) for exact 0-penalty homophones (`xu -> [需, 虚, 须, 徐]`),
            // then interleave spatial neighbor hits (`xi/cu`) starting after the reserved slots.
            let noisySingleSylSpans = fullBufferSpans.filter { $0.penaltyQ8 > 0 || $0.hasKeySubstitution }
            for sp in singleSylExactOrderedSpans.prefix(reserveSingleSylExactCount) {
                appendCandidate(
                    LokeyCandidate(
                        text: sp.text,
                        consumedInputCount: n,
                        matchedSyllables: sp.syllables,
                        scoreQ8: sp.scoreQ8,
                        kind: sp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                        isDeletableUserPhrase: sp.isUserPhrase
                    )
                )
            }
            var exactIdx = reserveSingleSylExactCount
            var noisyIdx = 0
            while exactIdx < singleSylExactOrderedSpans.count || noisyIdx < min(6, noisySingleSylSpans.count) {
                if noisyIdx < min(6, noisySingleSylSpans.count) {
                    let nsp = noisySingleSylSpans[noisyIdx]
                    noisyIdx += 1
                    appendCandidate(
                        LokeyCandidate(
                            text: nsp.text,
                            consumedInputCount: n,
                            matchedSyllables: nsp.syllables,
                            scoreQ8: nsp.scoreQ8,
                            kind: nsp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                            isDeletableUserPhrase: nsp.isUserPhrase
                        )
                    )
                }
                let nextBatchEnd = min(exactIdx + 3, singleSylExactOrderedSpans.count)
                while exactIdx < nextBatchEnd {
                    let esp = singleSylExactOrderedSpans[exactIdx]
                    exactIdx += 1
                    appendCandidate(
                        LokeyCandidate(
                            text: esp.text,
                            consumedInputCount: n,
                            matchedSyllables: esp.syllables,
                            scoreQ8: esp.scoreQ8,
                            kind: esp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                            isDeletableUserPhrase: esp.isUserPhrase
                        )
                    )
                }
            }
        } else {
            for sp in fullBufferSpans.prefix(n <= 4 ? 16 : 12) {
                appendCandidate(
                    LokeyCandidate(
                        text: sp.text,
                        consumedInputCount: n,
                        matchedSyllables: sp.syllables,
                        scoreQ8: sp.scoreQ8,
                        kind: sp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                        isDeletableUserPhrase: sp.isUserPhrase
                    )
                )
            }
        }

        // Resolve lexical homophones at a commit boundary, including context typed
        // in earlier chunks. Require a complete, identical reading on both sides.
        if let lead = candidates.first, lead.kind == .lexiconPhrase,
           let original = fullSpanByText[lead.text], original.penaltyQ8 == 0,
           (1...3).contains(original.syllables.count), original.syllables.joined() == cleanLower,
           fullBufferSpans.contains(where: {
               $0.text != lead.text && $0.penaltyQ8 == 0 && $0.syllables == original.syllables
           }) {
            let left = Self.extractTrailingChineseSuffix(from: precedingContext ?? "", maxChars: 12)
            var choice: String?
            var allowance = 0
            if left.isEmpty {
                // Standalone conversational acknowledgements, canonical 2-syllable defaults,
                // and cross-sentence exponentially decaying topic memory disambiguation (LNS6-v1).
                if original.syllables.count == 2 {
                    if cleanLower == "zhineng", let zn = fullBufferSpans.first(where: { $0.text == "智能" && $0.penaltyQ8 == 0 }) {
                        choice = zn.text
                        allowance = 520
                    } else if let response = fullBufferSpans.first(where: { Self.standaloneReplies.contains($0.text) }) {
                        choice = response.text
                        allowance = 220
                    }
                }
                if choice == nil,
                   (2...3).contains(original.syllables.count),
                   topicMemory != .zero,
                   lexicon.neuralLM.isSemantic64Loaded {
                    let origTopicQ8 = lexicon.neuralLM.scoreTopicGateBonusQ8(
                        hidden: lexicon.neuralLM.hBos,
                        topicMemory: topicMemory,
                        record: neuralRecord(for: lead.text)
                    )
                    var bestTopicCand: (text: String, topicDelta: Int)? = nil
                    for sp in fullBufferSpans.prefix(12) {
                        guard sp.text != lead.text,
                              sp.penaltyQ8 == 0,
                              !sp.isUserPhrase,
                              sp.syllables == original.syllables,
                              original.scoreQ8 - sp.scoreQ8 <= 820 else {
                            continue
                        }
                        let spTopicQ8 = lexicon.neuralLM.scoreTopicGateBonusQ8(
                            hidden: lexicon.neuralLM.hBos,
                            topicMemory: topicMemory,
                            record: neuralRecord(for: sp.text)
                        )
                        let topicDelta = spTopicQ8 - origTopicQ8
                        if topicDelta >= 140,
                           sp.scoreQ8 + topicDelta >= original.scoreQ8 + 40 {
                            if bestTopicCand == nil || (sp.scoreQ8 + topicDelta) > (fullSpanByText[bestTopicCand!.text]?.scoreQ8 ?? Int.min) + bestTopicCand!.topicDelta {
                                bestTopicCand = (sp.text, topicDelta)
                            }
                        }
                    }
                    if let winner = bestTopicCand {
                        choice = winner.text
                        allowance = winner.topicDelta
                    }
                }
            } else {
                let cue = learnedCommitChoice(after: precedingContext ?? left, reading: cleanLower, lead: lead.text)
                    ?? shortReadingCue(after: left, reading: cleanLower)
                if let cue {
                    choice = cue.text
                    allowance = cue.scoreQ8
                }
            }
            if let choice, choice != lead.text, let span = fullSpanByText[choice],
               span.penaltyQ8 == 0, span.syllables == original.syllables,
               span.scoreQ8 + allowance >= original.scoreQ8 {
                candidates.removeAll { $0.text == choice }
                seenTexts.insert(choice)
                candidates.insert(LokeyCandidate(text: choice, consumedInputCount: n,
                    matchedSyllables: span.syllables, scoreQ8: span.scoreQ8,
                    kind: .lexiconPhrase), at: 0)
            }
        }

        func matchesExactOrMixedJianpin(_ syllables: [String], input: String) -> Bool {
            if syllables.joined() == input { return true }
            let inBytes = Array(input.utf8)
            let sCount = syllables.count
            guard sCount > 0, !inBytes.isEmpty else { return false }
            func walk(_ sIdx: Int, _ bIdx: Int) -> Bool {
                if sIdx == sCount { return bIdx == inBytes.count }
                guard bIdx < inBytes.count else { return false }
                let sylBytes = Array(syllables[sIdx].utf8)
                guard !sylBytes.isEmpty else { return false }
                if bIdx + sylBytes.count <= inBytes.count {
                    var fullMatch = true
                    for k in 0..<sylBytes.count where inBytes[bIdx + k] != sylBytes[k] {
                        fullMatch = false
                        break
                    }
                    if fullMatch && walk(sIdx + 1, bIdx + sylBytes.count) {
                        return true
                    }
                }
                let b0 = sylBytes[0]
                let isVowel0 = (b0 == 0x61 || b0 == 0x65 || b0 == 0x69 || b0 == 0x6F || b0 == 0x75 || b0 == 0x76)
                if !isVowel0 && sylBytes.count >= 2 {
                    if sylBytes.count >= 3 && sylBytes[1] == 0x68 && (b0 == 0x7A || b0 == 0x63 || b0 == 0x73),
                       bIdx + 2 <= inBytes.count, inBytes[bIdx] == b0, inBytes[bIdx + 1] == 0x68 {
                        if walk(sIdx + 1, bIdx + 2) { return true }
                    }
                    if inBytes[bIdx] == b0 && walk(sIdx + 1, bIdx + 1) {
                        return true
                    }
                }
                return false
            }
            return walk(0, 0)
        }

        func candidateHasZeroKeySubstitution(_ cand: LokeyCandidate) -> Bool {
            guard cand.consumedInputCount == n,
                  (bestSentence?.keySubstitutionCount ?? 0) == 0,
                  matchesExactOrMixedJianpin(cand.matchedSyllables, input: cleanLower) else {
                return false
            }
            if let sp = fullSpanByText[cand.text] {
                return !sp.hasKeySubstitution && sp.keySubstitutionCount == 0
            }
            if let sent = topSentences.first(where: { $0.text == cand.text }) {
                return !sent.hasKeySubstitution && sent.keySubstitutionCount == 0
            }
            return true
        }

        // Compare only homophones differing at one character, using observed
        // spoken n-grams that include that character and its neighbors.
        if !skipStage5CAssociations, let lead = candidates.first, lead.kind == .sentence, (1...16).contains(lead.matchedSyllables.count),
           candidateHasZeroKeySubstitution(lead), lead.text.count == lead.matchedSyllables.count {
            let left = Self.extractTrailingChineseSuffix(from: precedingContext ?? "", maxChars: 2)
            let original = Array(left + lead.text)
            var winner: (index: Int, gain: Int)?
            for index in candidates.indices.dropFirst().prefix(4) {
                let other = candidates[index]
                guard other.kind == .sentence, other.matchedSyllables == lead.matchedSyllables,
                      other.text.count == lead.text.count, other.scoreQ8 + 420 >= lead.scoreQ8 else { continue }
                let rival = Array(left + other.text)
                guard let offset = original.indices.first(where: { original[$0] != rival[$0] }),
                      original[(offset + 1)...] == rival[(offset + 1)...] else { continue }
                let gain = spokenSupport(rival, at: offset) - spokenSupport(original, at: offset)
                let adjusted = gain - max(0, lead.scoreQ8 - other.scoreQ8)
                if adjusted >= 256, adjusted > (winner?.gain ?? 0) { winner = (index, adjusted) }
            }
            if let winner { candidates.insert(candidates.remove(at: winner.index), at: 0) }
        }

        // For a short multiword chunk, a competing last word can share every
        // keystroke with the winner. Consult the preceding words in this chunk
        // as well as committed text, without adding work inside the beam.
        if !skipStage5CAssociations, let lead = candidates.first,
           (lead.kind == .sentence || lead.kind == .lexiconPhrase),
           (1...16).contains(lead.matchedSyllables.count),
           candidateHasZeroKeySubstitution(lead), lead.text.count == lead.matchedSyllables.count,
           let last = lead.text.last, !"吧吗呢呀啊啦".contains(last) {
            // Frequent fragments in expository text should not erase an existing
            // grammatical sentence-final particle from a conversational clause.
            let tailLengths = lead.text.count >= 2 && lead.matchedSyllables.count >= 2 ? [2, 1] : [1]
            for tailLen in tailLengths {
                let prefix = String(lead.text.dropLast(tailLen))
                let reading = lead.matchedSyllables.suffix(tailLen).joined()
                guard cleanLower.hasSuffix(reading) else { continue }
                let suffixText = String(lead.text.suffix(tailLen))
                let competitors = candidates.indices.dropFirst().filter { index in
                    let other = candidates[index]
                    return other.matchedSyllables == lead.matchedSyllables &&
                        other.text.count == lead.text.count && other.text.hasPrefix(prefix)
                }
                let context = String((precedingContext ?? "").suffix(12)) + prefix
                let left = Self.extractTrailingChineseSuffix(from: context, maxChars: 12)
                if let cue = learnedCommitChoice(after: context, reading: reading, lead: suffixText)
                    ?? shortReadingCue(after: left, reading: reading) {
                    if let index = competitors.first(where: {
                        candidates[$0].text == prefix + cue.text && candidates[$0].scoreQ8 + cue.scoreQ8 >= lead.scoreQ8
                    }) {
                        candidates.insert(candidates.remove(at: index), at: 0)
                        break
                    }
                    // If beam pruning dropped the homophone tail (`他跑得` behind `他跑的/淘宝的`, or `就这个事` behind `就这个是`),
                    // recover it directly when lexical unigram + cue beats the lead tail character.
                    if tailLen == 1, cue.text != suffixText, lead.text.count >= 2,
                       (reading == "de" || reading == "ta" || reading == "shi"),
                       let sid = lexicon.syllableToID[reading],
                       let node = lexicon.step(from: lexicon.rootNodeIndex, syllableID: sid) {
                        let hits = lexicon.words(at: node, limit: 24)
                        if let cueHit = hits.first(where: { $0.text == cue.text }) {
                            let leadTailBase = hits.first(where: { $0.text == suffixText })?.scoreQ8 ?? (hits.first?.scoreQ8 ?? -600)
                            if cueHit.scoreQ8 + cue.scoreQ8 >= leadTailBase {
                                let target = prefix + cue.text
                                let adjustedScore = lead.scoreQ8 + (cueHit.scoreQ8 + cue.scoreQ8 - leadTailBase)
                                candidates.removeAll { $0.text == target }
                                seenTexts.insert(target)
                                candidates.insert(
                                    LokeyCandidate(
                                        text: target,
                                        consumedInputCount: lead.consumedInputCount,
                                        matchedSyllables: lead.matchedSyllables,
                                        scoreQ8: adjustedScore,
                                        kind: lead.kind
                                    ),
                                    at: 0
                                )
                                break
                            }
                        }
                    }
                }
            }
        }

        // A competing lexical suffix can disappear from the beam (fa-ni vs
        // fan-yi). Recover it only after an attested multi-character context,
        // with an unchanged prefix and exact coverage of the remaining keys.
        if !skipStage5CAssociations, let lead = candidates.first, lead.kind == .sentence, !hasApostrophe,
           (3...8).contains(lead.matchedSyllables.count), lead.text.count == lead.matchedSyllables.count,
           let last = lead.text.last, !"吧吗呢呀啊啦".contains(last) {
            let prefix = lead.text.dropLast(2)
            let spelled = lead.matchedSyllables.dropLast(2).joined()
            let suffix = String(cleanLower.dropFirst(spelled.count))
            if Self.recoverableEndings.contains(suffix), cleanLower.hasPrefix(spelled) {
                let left = Self.extractTrailingChineseSuffix(from: String((precedingContext ?? "").suffix(4)) + prefix)
                for length in stride(from: left.count, through: 2, by: -1) {
                    guard let cue = lexicon.lookupAssociations(after: "@" + left.suffix(length) + suffix, limit: 1).first else { continue }
                    let fields = cue.text.split(separator: "|", maxSplits: 1)
                    guard fields.count == 2 else { break }
                    let target = String(prefix) + String(fields[0])
                    if target == lead.text { break }
                    let reading = fields[1].split(separator: " ").map(String.init)
                    guard reading.joined() == suffix else { break }
                    candidates.removeAll { $0.text == target }
                    seenTexts.insert(target)
                    candidates.insert(LokeyCandidate(text: target, consumedInputCount: n,
                        matchedSyllables: Array(lead.matchedSyllables.dropLast(2)) + reading,
                        scoreQ8: lead.scoreQ8, kind: .sentence, trailingWord: String(fields[0])), at: 0)
                    break
                }
            }
        }

        // A corpus-attested whole chunk can rescue a stitched homophone or
        // a syllable-boundary mistake before space. Protect direct lexical
        // hits and require complete coverage of exactly the pressed keys.
        if !skipStage5CAssociations, !hasApostrophe, rawString == cleanLower, let lead = candidates.first,
           (lead.kind == .sentence || (lead.kind == .lexiconPhrase && lead.matchedSyllables.joined() != cleanLower)),
           lead.consumedInputCount == n,
           (3...8).contains(lead.matchedSyllables.count),
           let hit = lexicon.lookupAssociations(after: "=" + cleanLower, limit: 1).first {
            let entry = hit.text.split(separator: "|", maxSplits: 1)
            if entry.count == 2 {
                let text = String(entry[0])
                let syllables = entry[1].split(separator: " ").map(String.init)
                if text != lead.text, text.count == syllables.count,
                   syllables.joined() == cleanLower, hit.scoreQ8 >= lead.scoreQ8 + 128 {
                    candidates.removeAll { $0.text == text }
                    seenTexts.insert(text)
                    candidates.insert(LokeyCandidate(text: text, consumedInputCount: n,
                        matchedSyllables: syllables, scoreQ8: hit.scoreQ8,
                        kind: .sentence), at: 0)
                }
            }
        }

        if fastCleanSentenceOnly {
            let fastRes = DecodeResult(preeditDisplay: "", candidates: candidates)
            if !urgentNow && n <= 16 {
                if let dupIdx = recentDecodeHistory.firstIndex(where: {
                    $0.samples == samples && $0.precedingContext == precedingContext
                        && $0.topicMemory == topicMemory
                        && $0.fastCleanSentenceOnly == fastCleanSentenceOnly
                        && $0.skipStage5CAssociations == skipStage5CAssociations
                }) {
                    recentDecodeHistory.remove(at: dupIdx)
                } else if recentDecodeHistory.count >= 24 {
                    recentDecodeHistory.removeFirst()
                }
                recentDecodeHistory.append(
                    CachedDecodeHistoryEntry(
                        samples: samples,
                        settings: settings,
                        precedingContext: precedingContext,
                        topicMemory: topicMemory,
                        fastCleanSentenceOnly: fastCleanSentenceOnly,
                        skipStage5CAssociations: skipStage5CAssociations,
                        spatialGeneration: spatialGen,
                        userGeneration: userGen,
                        supplementaryGeneration: supplementaryGeneration,
                        wholeInputClean: currentWholeClean,
                        hasApostrophe: hasApostrophe,
                        isPureEnglishCompound: isPureEnglishCompound,
                        wasUrgentCommit: urgentNow,
                        posHyps: posHyps,
                        posHypsCap: hypCap,
                        arcsByStart: arcsByStart,
                        latticeDepsByStart: latticeDepsByStart,
                        spansByStart: spansByStart,
                        maxPosByStart: maxPosByStart,
                        spanDepsByStart: spanDepsByStart,
                        dp: cachedDP,
                        dpSeedWord: cachedDPSeedWord,
                        dpPrecedingContext: cachedDPPrecedingContext,
                        dpTopicMemory: cachedDPTopicMemory,
                        dpBeamK: cachedDPBeamK,
                        result: fastRes
                    )
                )
            }
            return fastRes
        }

        // 5D. Jianpin acronym lookup (e.g. `zg` -> `中国`, `rgzn` -> `人工智能`, `wsm` -> `为什么`)
        // Note: mid-word synthetic `-r` (`su+r+ge` -> `苏儿个`, `penaltyQ8 == 120`) is NOT clean Chinese unless
        // backed by an actual lexical entry in `fullBufferSpans` (`去哪儿`) or a real Erhua suffix word (`一点儿`).
        let hasCleanChineseFull = fullBufferSpans.contains(where: { $0.penaltyQ8 < 180 && !$0.isEnglishSpan })
            || (bestSentence != nil && bestSentence!.end == n
                && !bestSentence!.text.contains(where: { $0.isASCII && $0.isLetter })
                && (bestSentence!.penaltyQ8 <= 70
                    || (bestSentence!.penaltyQ8 < 180 && bestSentence!.lastWord.hasSuffix("儿"))))

        if settings.pinyinScheme == .quanpin && cleanLower.count >= 2 && cleanLower.count <= 8 && !(currentWholeClean && cleanLower.count >= 5) {
            let allowJpPrefix = cleanLower.count >= 3 && !hasCleanChineseFull && !currentWholeClean
            let jpHits = lexicon.lookupJianpinWithExactFlag(
                cleanLower,
                allowPrefix: allowJpPrefix,
                limit: 8
            )
            // Promote exact single-entry Jianpin (`zg` -> `中国`, `rgzn` -> `人工智能`, `wsm` -> `为什么`, `bj` -> `北京`, `ewm` -> `二维码`, `msmwt` -> `没什么问题`)
            // while never letting an `allowPrefix` partial acronym override a full-buffer mixed-Jianpin word (`wmen` -> `我们`)!
            for (idx, entry) in jpHits.enumerated() {
                let hit = entry.hit
                let isExactAcronym = entry.isExact
                let candidate = LokeyCandidate(
                    text: hit.text,
                    consumedInputCount: n,
                    matchedSyllables: [],
                    scoreQ8: hit.scoreQ8,
                    kind: .jianpin
                )
                let allConsonantInput = !cleanLower.utf8.contains {
                    $0 == 0x61 || $0 == 0x65 || $0 == 0x69 || $0 == 0x6F || $0 == 0x75 || $0 == 0x76
                }
                let beatsMixedSentence: Bool = {
                    guard let sent = bestSentence, sent.end == n else { return true }
                    if sent.hasKeySubstitution && sent.text.count < cleanLower.count {
                        // Single-char / shorter neighbor substitution (`bj -> bi -> 比`, `dbq -> 对吧`) must yield to exact multi-char acronym (`北京`, `对不起`)
                        return isExactAcronym
                    }
                    let allAbbrevSyls = allConsonantInput || sent.syllables.allSatisfy { syl in
                        syl.count == 1 || syl == "zh" || syl == "ch" || syl == "sh"
                    }
                    if allAbbrevSyls {
                        let sentHasClauseModal = sent.text.last.map { "吧吗呢啊啦么".contains($0) } ?? false
                        return isExactAcronym && hit.scoreQ8 >= sent.scoreQ8 + (sentHasClauseModal ? 150 : -220)
                    }
                    let sentComparableScore = sent.scoreQ8 + (!sent.hasKeySubstitution ? min(sent.penaltyQ8, cleanLower.count * 220) : 0)
                    if isExactAcronym && hit.text.count >= max(3, cleanLower.count - 1) && sent.text.count < hit.text.count {
                        return hit.scoreQ8 >= sentComparableScore - 260
                    }
                    // Mixed Jianpin with at least 1 multi-letter syllable (`wmen` -> `我们`, `zg` -> `这个`)
                    // keeps priority unless acronym is exact and far stronger
                    return isExactAcronym && hit.scoreQ8 >= sentComparableScore + 600
                }()
                if !hasCleanChineseFull && idx == 0 && isExactAcronym && beatsMixedSentence {
                    let insertPos = min(candidates.count, exactUserHitCount == 0 ? 0 : 1)
                    if let existingIdx = candidates.firstIndex(where: { $0.text == candidate.text }) {
                        if existingIdx > insertPos {
                            candidates.remove(at: existingIdx)
                            candidates.insert(candidate, at: min(insertPos, candidates.count))
                        }
                    } else {
                        seenTexts.insert(candidate.text)
                        candidates.insert(candidate, at: insertPos)
                    }
                } else {
                    appendCandidate(candidate)
                }
            }
        }

        let hasStrongPrefixClean = !hasCleanChineseFull
            && bestSentence?.end == n
            && !(bestSentence?.hasKeySubstitution ?? true)
            && (bestSentence?.penaltyQ8 ?? 999) <= 210
            && (bestSentence?.scoreQ8 ?? Int.min) >= (bestSentence?.syllables.count ?? 1) * -1200
            && fullBufferSpans.contains(where: { !$0.hasKeySubstitution && $0.penaltyQ8 <= 210 && $0.scoreQ8 >= $0.syllables.count * -1200 })
        if settings.pinyinScheme == .quanpin, !hasCleanChineseFull, !hasStrongPrefixClean, !hasApostrophe, rawString == cleanLower,
           candidates.first?.kind != .userPhrase {
            let mixed = lexicon.mixedInitialMatches(cleanLower)
            if let best = mixed.first {
                let promote = candidates.first.map { firstCand in
                    if firstCand.text == best.word.text { return true }
                    let jpFairRestore = (firstCand.kind == .sentence && !(bestSentence?.hasKeySubstitution ?? true))
                        ? min(bestSentence?.penaltyQ8 ?? 0, 420)
                        : 0
                    return best.rankScore >= firstCand.scoreQ8 + jpFairRestore + 128
                } ?? true
                // Keep plausible neighbors accessible even when a strong ordinary
                // spelling correction retains first place.
                let lead = promote ? nil : candidates.first?.text
                var index = promote ? 0 : 1
                for match in mixed where match.word.text != lead {
                    candidates.removeAll { $0.text == match.word.text }
                    seenTexts.insert(match.word.text)
                    candidates.insert(LokeyCandidate(text: match.word.text, consumedInputCount: n,
                        matchedSyllables: match.syllables, scoreQ8: match.word.scoreQ8,
                        kind: .lexiconPhrase), at: min(index, candidates.count))
                    index += 1
                }
            }
        }

        // 5E. Seamless Chinese-English Mixed Input, Auto-Formatting & Prefix/Compound Completion
        // (`applestore` -> `Apple Store`, `macbookpro` -> `MacBook Pro`, `iPhone`, `GitHub`, `Surge`, `Wi-Fi`, `don't`, `coffee shop`)
        if cleanLower.count >= 2 && cleanLower.count <= 26 && !rawString.contains("'") {
            let hasUppercase = rawString.contains { $0.isUppercase }
            let isAllUpperASCII = rawString.count >= 2 && rawString.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
            let startsUpperASCII = (rawString.first?.isUppercase == true)

            func adaptEnglishDisplay(_ lexDisplay: String) -> String {
                if isAllUpperASCII && lexDisplay.allSatisfy({ $0.isASCII && $0.isLetter }) {
                    return lexDisplay.uppercased()
                }
                if startsUpperASCII,
                   let first = lexDisplay.first, first.isLowercase,
                   !lexDisplay.dropFirst().contains(where: { $0.isUppercase }) {
                    return first.uppercased() + lexDisplay.dropFirst()
                }
                return lexDisplay
            }

            let enHits = lexicon.lookupEnglish(prefix: cleanLower, limit: 6)
            var didPromoteEnglishToLead = false
            let hasInternalCamelCase = rawString.dropFirst().contains { $0.isUppercase }
            let bestEnPrefixScore = enHits.first(where: { !$0.isExactKeyMatch })?.scoreQ8 ?? -32000

            // Dynamic 2-word English compound segmentation (`coffeeshop -> coffee shop`, `phonecall -> phone call`, `applepie -> Apple pie`)
            // when no single/curated exact entry matches, no stronger prefix completion exists, and user did not type explicit internal CamelCase (`LocalVPN`).
            var compoundLeadCandidate: LokeyCandidate? = nil
            if cleanLower.count >= 6 && cleanLower.count <= 24,
               !hasInternalCamelCase,
               !hasCleanChineseFull,
               !(currentWholeClean && !hasUppercase && cleanLower.count >= 11),
               !enHits.contains(where: \.isExactKeyMatch),
               bestEnPrefixScore < -2250,
               (hasUppercase || bestSentence == nil || bestSentence!.end < n || bestSentence!.penaltyQ8 >= 580) {
                let lowerCharsArr = Array(cleanLower)
                var bestCompound: (text: String, scoreQ8: Int)? = nil
                for split in 3...(lowerCharsArr.count - 3) {
                    let rightLen = lowerCharsArr.count - split
                    let leftKey = String(lowerCharsArr[0..<split])
                    guard let w1 = lexicon.lookupExactEnglish(leftKey) else { continue }
                    let leftAllowed = (split == 3)
                        ? (w1.scoreQ8 >= -2050 || Self.commonThreeLetterEnglishWords.contains(leftKey))
                        : (w1.scoreQ8 >= -2250)
                    guard leftAllowed else { continue }
                    let rightKey = String(lowerCharsArr[split..<lowerCharsArr.count])
                    guard let w2 = lexicon.lookupExactEnglish(rightKey) else { continue }
                    let rightAllowed = (rightLen == 3)
                        ? (w2.scoreQ8 >= -2050 || Self.commonThreeLetterEnglishWords.contains(rightKey))
                        : (w2.scoreQ8 >= -2250)
                    guard rightAllowed else { continue }
                    // Require at least one curated / extended high-confidence English word so obscure dict pairs never join over Chinese typos
                    guard w1.scoreQ8 >= -2180 || w2.scoreQ8 >= -2180 else { continue }
                    let effectiveLeftScore = (split == 3 && Self.commonThreeLetterEnglishWords.contains(leftKey))
                        ? max(w1.scoreQ8, -2050)
                        : w1.scoreQ8
                    let effectiveRightScore = (rightLen == 3 && Self.commonThreeLetterEnglishWords.contains(rightKey))
                        ? max(w2.scoreQ8, -2050)
                        : w2.scoreQ8
                    let combinedScore = (effectiveLeftScore + effectiveRightScore) / 2
                    guard combinedScore > bestEnPrefixScore + 80 else { continue }
                    let joined = adaptEnglishDisplay("\(w1.text) \(w2.text)")
                    if bestCompound == nil || combinedScore > bestCompound!.scoreQ8 {
                        bestCompound = (joined, combinedScore)
                    }
                }
                if let bc = bestCompound {
                    compoundLeadCandidate = LokeyCandidate(
                        text: bc.text,
                        consumedInputCount: n,
                        matchedSyllables: [],
                        scoreQ8: bc.scoreQ8,
                        kind: .english
                    )
                }
            }

            if let comp = compoundLeadCandidate, seenTexts.insert(comp.text).inserted {
                let targetIdx = min(exactUserHitCount, candidates.count)
                candidates.insert(comp, at: targetIdx)
                didPromoteEnglishToLead = true
            }

            for (idx, eh) in enHits.enumerated() {
                let formattedText = eh.isExactKeyMatch ? adaptEnglishDisplay(eh.text) : eh.text
                let cand = LokeyCandidate(
                    text: formattedText,
                    consumedInputCount: n,
                    matchedSyllables: [],
                    scoreQ8: eh.scoreQ8,
                    kind: .english
                )
                let chineseIsNoisyForPrefix = !hasCleanChineseFull
                    && (bestSentence == nil
                        || bestSentence!.end < n
                        || bestSentence!.penaltyQ8 >= 620
                        || (bestSentence!.penaltyQ8 >= 420
                            && eh.scoreQ8 >= -2150
                            && bestSentence!.scoreQ8 < bestSentence!.syllables.count * -1280))
                let canPromotePrefix = !eh.isExactKeyMatch
                    && !didPromoteEnglishToLead
                    && eh.scoreQ8 >= -2450
                    && ((hasUppercase && cleanLower.count >= 4 && !hasCleanChineseFull)
                        || (cleanLower.count >= 5 && chineseIsNoisyForPrefix))

                if idx == 0 && (hasUppercase || (eh.isExactKeyMatch && !hasCleanChineseFull) || (eh.isExactKeyMatch && eh.scoreQ8 >= -1800) || canPromotePrefix) {
                    if seenTexts.insert(cand.text).inserted {
                        let protectsShortChineseLead = !hasUppercase
                            && cleanLower.count <= 3
                            && eh.scoreQ8 < -2050
                            && (candidates.first?.consumedInputCount == n)
                            && (candidates.first?.kind == .jianpin
                                || candidates.first?.kind == .lexiconPhrase
                                || candidates.first?.kind == .sentence
                                || candidates.first?.kind == .userPhrase)
                            && (candidates.first?.scoreQ8 ?? -9999) >= -2600
                        let chineseIsWeakMultiSylSoup = cleanLower.count >= 6
                            && eh.isExactKeyMatch
                            && eh.scoreQ8 >= -1950
                            && fullBufferSpans.allSatisfy({ $0.penaltyQ8 >= 180 })
                            && (bestSentence == nil || (bestSentence!.syllables.count >= 3 && bestSentence!.scoreQ8 < bestSentence!.syllables.count * -1450))
                        let targetIdx: Int
                        if didPromoteEnglishToLead {
                            targetIdx = min(exactUserHitCount + 1, candidates.count)
                        } else if protectsShortChineseLead || (!hasUppercase && hasCleanChineseFull && !chineseIsWeakMultiSylSoup) {
                            targetIdx = min(1, candidates.count)
                        } else {
                            targetIdx = min(exactUserHitCount, candidates.count)
                        }
                        candidates.insert(cand, at: targetIdx)
                        if targetIdx == 0 {
                            didPromoteEnglishToLead = true
                        }
                    }
                } else {
                    appendCandidate(cand)
                }
            }
        }

        // 5E.5. Prefix ASCII Text Replacements & >= 3-char Contacts Jianpin (never clobbers everyday Chinese words)
        if cleanLower.count >= 2 {
            var prefixShortcutHits = 0
            for (shortcut, phrase) in supplementaryShortcuts where shortcut.hasPrefix(cleanLower) && shortcut != cleanLower {
                appendCandidate(
                    LokeyCandidate(
                        text: phrase,
                        consumedInputCount: n,
                        matchedSyllables: [],
                        scoreQ8: -900,
                        kind: .userPhrase
                    )
                )
                prefixShortcutHits += 1
                if prefixShortcutHits >= 2 { break }
            }
        }
        if !currentWholeClean && cleanLower.count >= 3 {
            var contactJianpinHits = 0
            for item in supplementaryContacts where item.jianpin == cleanLower {
                appendCandidate(
                    LokeyCandidate(
                        text: item.phrase,
                        consumedInputCount: n,
                        matchedSyllables: item.syllables,
                        scoreQ8: -850,
                        kind: .userPhrase
                    )
                )
                contactJianpinHits += 1
                if contactJianpinHits >= 2 { break }
            }
        }

        if !candidates.isEmpty && n >= 10 && isUrgentCommit() {
            return DecodeResult(preeditDisplay: rawString, candidates: candidates)
        }

        // 5F. Prefix / Partial-Commit phrase candidates starting at index 0:
        // Enforce strict Prefix-Purity: 0-substitution clean Pinyin prefixes (`我来三`, `我来散`, `我来`, `明天`)
        // strictly precede any typo-mutated partial prefix (`*我老三`)!
        struct PartialPrefixItem {
            let text: String
            let end: Int
            let syllables: [String]
            let scoreQ8: Int
            let penaltyQ8: Int
            let keySubstitutionCount: UInt8
            let isUserPhrase: Bool
        }

        var partialPrefixItems: [PartialPrefixItem] = (spansByStart[firstStart] ?? [])
            .filter { $0.end < n && $0.penaltyQ8 <= 560 }
            .map {
                PartialPrefixItem(
                    text: $0.text,
                    end: $0.end,
                    syllables: $0.syllables,
                    scoreQ8: $0.scoreQ8,
                    penaltyQ8: $0.penaltyQ8,
                    keySubstitutionCount: $0.keySubstitutionCount,
                    isUserPhrase: $0.isUserPhrase
                )
            }

        if !hasCleanChineseFull && firstStart == 0 && !cachedDP.isEmpty && n <= 12 {
            var furthestCleanPos = 0
            var furthestCleanNode: DPNode? = nil
            let maxCheckPos = min(n - 1, cachedDP.count - 1)
            if maxCheckPos >= 1 {
                for pos in stride(from: maxCheckPos, through: 1, by: -1) {
                    if let cleanNode = cachedDP[pos].first(where: {
                        !$0.text.isEmpty && $0.keySubstitutionCount == 0 && $0.isPureCleanOrJianpin && $0.penaltyQ8 <= 140
                    }) {
                        furthestCleanPos = pos
                        furthestCleanNode = cleanNode
                        break
                    }
                }
            }
            if let cleanNode = furthestCleanNode, furthestCleanPos >= 2, (n - furthestCleanPos) <= 4 {
                // Literal incomplete Quanpin syllable-prefix completions immediately following the longest
                // 0-substitution clean prefix (`wolaissb` -> `wolai` + `s` -> `我来三`, `我来散`)!
                // Never emit partial `end < n` completions when remaining clean letters already spell
                // a complete canonical syllable to `n` (`kuimeile` -> `le`), stranding trailing letters.
                var tailStr = ""
                for idx in furthestCleanPos..<n {
                    let ch = samples[idx].primaryChar
                    if ch == "'" { continue }
                    let lc = Character(ch.lowercased())
                    guard lc >= "a" && lc <= "z" else {
                        tailStr = ""
                        break
                    }
                    tailStr.append(lc)
                }
                let tailIsCanonicalSyllable = !tailStr.isEmpty && lexicon.syllableToID[tailStr] != nil
                if !tailIsCanonicalSyllable {
                    var subStr = ""
                    var bestSubStr = ""
                    var bestSubEnd = furthestCleanPos
                    let maxSub = min(5, n - furthestCleanPos)
                    for off in 0..<maxSub {
                        let idx = furthestCleanPos + off
                        let ch = samples[idx].primaryChar
                        if ch == "'" { break }
                        let lc = Character(ch.lowercased())
                        guard lc >= "a" && lc <= "z" else { break }
                        subStr.append(lc)
                        var subEnd = idx + 1
                        while subEnd < n && samples[subEnd].primaryChar == "'" {
                            subEnd += 1
                        }
                        guard subEnd < n else { break }
                        if lexicon.prefixToSyllableIDs[subStr] != nil {
                            bestSubStr = subStr
                            bestSubEnd = subEnd
                        } else {
                            break
                        }
                    }
                    if !bestSubStr.isEmpty, let rawSIDs = lexicon.prefixToSyllableIDs[bestSubStr] {
                        let baseSIDs = rawSIDs.filter { $0 > 0 }
                        let sortedByOneChar = baseSIDs.sorted { a, b in
                            let sa = lexicon.syllableBestScore(forSyllableID: a)
                            let sb = lexicon.syllableBestScore(forSyllableID: b)
                            if sa != sb { return sa > sb }
                            return a < b
                        }
                        let orderedSIDs: [UInt16]
                        let nextIsH = bestSubEnd < n && samples[bestSubEnd].primaryChar.lowercased() == "h"
                        if bestSubStr.count == 1 && (bestSubStr == "z" || bestSubStr == "c" || bestSubStr == "s") && !nextIsH {
                            let retroPrefix = bestSubStr + "h"
                            let nonRetro = sortedByOneChar.filter { sid in
                                !lexicon.idToSyllable[Int(sid)].hasPrefix(retroPrefix)
                            }
                            let retro = sortedByOneChar.filter { sid in
                                lexicon.idToSyllable[Int(sid)].hasPrefix(retroPrefix)
                            }
                            orderedSIDs = nonRetro + retro
                        } else {
                            orderedSIDs = sortedByOneChar
                        }
                        let compPen = cleanNode.penaltyQ8 + 170
                        var emittedCount = 0
                        for sid in orderedSIDs.prefix(6) {
                            guard emittedCount < 5,
                                  let tNode = lexicon.step(from: lexicon.rootNodeIndex, syllableID: sid) else { continue }
                            let canon = lexicon.idToSyllable[Int(sid)]
                            for w in lexicon.words(at: tNode, limit: 3) {
                                partialPrefixItems.append(
                                    PartialPrefixItem(
                                        text: cleanNode.text + w.text,
                                        end: bestSubEnd,
                                        syllables: cleanNode.syllables + [canon],
                                        scoreQ8: cleanNode.scoreQ8 + w.scoreQ8 - 210 - 170,
                                        penaltyQ8: compPen,
                                        keySubstitutionCount: 0,
                                        isUserPhrase: false
                                    )
                                )
                                emittedCount += 1
                                if emittedCount >= 5 { break }
                            }
                        }
                    }
                }
                partialPrefixItems.append(
                    PartialPrefixItem(
                        text: cleanNode.text,
                        end: furthestCleanPos,
                        syllables: cleanNode.syllables,
                        scoreQ8: cleanNode.scoreQ8,
                        penaltyQ8: cleanNode.penaltyQ8,
                        keySubstitutionCount: 0,
                        isUserPhrase: false
                    )
                )
            }
        }

        let maxZeroSubCleanEnd = partialPrefixItems.reduce(0) { acc, item in
            (item.keySubstitutionCount == 0 && item.penaltyQ8 < 260) ? max(acc, item.end) : acc
        }
        partialPrefixItems.sort { a, b in
            let aDominated = a.keySubstitutionCount > 0 && a.end <= maxZeroSubCleanEnd
            let bDominated = b.keySubstitutionCount > 0 && b.end <= maxZeroSubCleanEnd
            if aDominated != bDominated {
                return !aDominated && bDominated
            }
            let aClean = a.penaltyQ8 < 180
            let bClean = b.penaltyQ8 < 180
            if aClean != bClean {
                return aClean && !bClean
            }
            if a.end != b.end {
                return a.end > b.end
            }
            return a.scoreQ8 > b.scoreQ8
        }

        for sp in partialPrefixItems.prefix(36) {
            appendCandidate(
                LokeyCandidate(
                    text: sp.text,
                    consumedInputCount: sp.end,
                    matchedSyllables: sp.syllables,
                    scoreQ8: sp.scoreQ8,
                    kind: sp.isUserPhrase ? .userPhrase : .lexiconPhrase,
                    isDeletableUserPhrase: sp.isUserPhrase
                )
            )
        }

        // Also ensure single-syllable single-character candidates for the first syllable are always reachable!
        if let firstArcs = arcsByStart[firstStart]?.sorted(by: {
            let aZeroSub = ($0.keySubstitutionCount == 0)
            let bZeroSub = ($1.keySubstitutionCount == 0)
            if aZeroSub != bZeroSub { return aZeroSub && !bZeroSub }
            let aClean = $0.penaltyQ8 == 0
            let bClean = $1.penaltyQ8 == 0
            if aClean != bClean { return aClean && !bClean }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.penaltyQ8 < $1.penaltyQ8
        }) {
            for arc in firstArcs.prefix(3) where arc.syllableID > 0 {
                if let node = lexicon.step(from: lexicon.rootNodeIndex, syllableID: arc.syllableID) {
                    for w in lexicon.words(at: node, limit: 28) {
                        appendCandidate(
                            LokeyCandidate(
                                text: w.text,
                                consumedInputCount: arc.end,
                                matchedSyllables: [arc.canonical],
                                scoreQ8: w.scoreQ8 - arc.penaltyQ8,
                                kind: .lexiconPhrase
                            )
                        )
                    }
                }
            }
        }

        // 5G. Raw ASCII input fallback (so typing arbitrary English words/codes can always be committed in 1 tap)
        if !rawString.contains("'") {
            let rawCand = LokeyCandidate(
                text: rawString,
                consumedInputCount: n,
                matchedSyllables: [],
                scoreQ8: -9000,
                kind: .rawInput
            )
            let isAllUppercaseASCII = !rawString.isEmpty && rawString.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
            let startsUppercase = (rawString.first?.isUppercase == true)
            let hasFormattedEnglishLead = (candidates.first?.kind == .english)

            if (isAllUppercaseASCII || (startsUppercase && !hasCleanChineseFull)),
               seenTexts.insert(rawCand.text).inserted {
                let targetIdx: Int
                if !isAllUppercaseASCII && hasFormattedEnglishLead {
                    targetIdx = min(1, candidates.count)
                } else {
                    targetIdx = min(exactUserHitCount, candidates.count)
                }
                candidates.insert(rawCand, at: targetIdx)
            } else if startsUppercase && seenTexts.insert(rawCand.text).inserted {
                candidates.insert(rawCand, at: min(1, candidates.count))
            } else if !hasCleanChineseFull,
                      n >= 4,
                      (bestSentence == nil || bestSentence!.end < n || bestSentence!.scoreQ8 < bestSentence!.syllables.count * -1550 || bestSentence!.penaltyQ8 >= (bestSentence!.hasKeySubstitution ? 920 : 1050)),
                      seenTexts.insert(rawCand.text).inserted {
                candidates.insert(rawCand, at: min(2, candidates.count))
            } else {
                appendCandidate(rawCand)
            }
        }

        // 5H. Native iOS 1:1 Inline Emoji Mixed Input (`haha -> [哈哈, 😂, ...]`, `daku -> [大哭, 😭, ...]`)
        // Strictly keeps Chinese text at Slot #0. Requires clean, exact 0-penalty reading match so incomplete/noisy
        // prefixes never inject emojis into top-4, and places emojis at Slot #3 on ultra-high-frequency (`> -1850`)
        // or homophone-contested 2+ char words.
        if settings.enableEmojiCandidates,
           !hasApostrophe,
           !candidates.prefix(4).contains(where: { $0.kind == .emoji }),
           let topCand = candidates.first,
           topCand.consumedInputCount == n,
           (topCand.kind == .lexiconPhrase || topCand.kind == .userPhrase || (topCand.kind == .sentence && topCand.matchedSyllables.count >= 2)),
           !topCand.matchedSyllables.isEmpty {
            let isExactCleanReading: Bool = {
                if settings.pinyinScheme == .quanpin {
                    let leadSyllableStr = topCand.matchedSyllables.joined()
                    if leadSyllableStr == cleanLower { return true }
                    if leadSyllableStr.count == cleanLower.count {
                        return leadSyllableStr.replacingOccurrences(of: "v", with: "u") == cleanLower
                    }
                    return false
                } else {
                    let spCodes = topCand.matchedSyllables.compactMap {
                        PinyinSyllableAutomaton.primaryShuangpinCode(forCanonicalSyllable: $0, scheme: settings.pinyinScheme)
                    }
                    return spCodes.count == topCand.matchedSyllables.count && spCodes.joined() == cleanLower
                }
            }()
            let leadPenaltyQ8 = fullSpanByText[topCand.text]?.penaltyQ8 ?? bestSentence?.penaltyQ8 ?? 0
            let leadHasKeySub = fullSpanByText[topCand.text]?.hasKeySubstitution ?? bestSentence?.hasKeySubstitution ?? false
            if isExactCleanReading && leadPenaltyQ8 == 0 && !leadHasKeySub {
                let emojis = lexicon.lookupEmojis(forWord: topCand.text, limit: 1)
                if let em = emojis.first, seenTexts.insert(em).inserted {
                    let isUltraHighFreqCommonWord = (fullSpanByText[topCand.text]?.scoreQ8 ?? topCand.scoreQ8) > -1630
                    let hasContestedTwoCharHomophone = topCand.text.count >= 2 && candidates.dropFirst().prefix(3).contains(where: { other in
                        other.consumedInputCount == n
                            && (other.kind == .lexiconPhrase || other.kind == .sentence)
                            && other.matchedSyllables == topCand.matchedSyllables
                            && other.scoreQ8 >= -2300
                            && other.scoreQ8 >= topCand.scoreQ8 - 250
                    })
                    let targetSlot = (isUltraHighFreqCommonWord || hasContestedTwoCharHomophone)
                        ? min(3, candidates.count)
                        : min(1, candidates.count)
                    let emojiCand = LokeyCandidate(
                        text: em,
                        consumedInputCount: n,
                        matchedSyllables: [],
                        scoreQ8: topCand.scoreQ8 - 1,
                        kind: .emoji
                    )
                    candidates.insert(emojiCand, at: targetSlot)
                }
            }
        }

        // Format raw-key-preserving preedit string:
        // Strictly preserves every pressed key (`preedit.replacingOccurrences(of: "'", with: "") == rawWithoutApostrophe`),
        // inserting syllable separators `'` ONLY between segmented chunks and never mutating/adding/deleting pressed letters!
        let guideSyllables: [String]
        if let cleanWord = promotedCleanExactWord, !cleanWord.syllables.isEmpty {
            guideSyllables = cleanWord.syllables
        } else if let firstCand = candidates.first, firstCand.consumedInputCount == n, !firstCand.matchedSyllables.isEmpty {
            guideSyllables = firstCand.matchedSyllables
        } else if let sent = bestSentence, !sent.syllables.isEmpty {
            guideSyllables = sent.syllables
        } else if let firstCand = candidates.first, !firstCand.matchedSyllables.isEmpty {
            guideSyllables = firstCand.matchedSyllables
        } else {
            guideSyllables = []
        }
        let preedit = formatRawPreedit(
            samples: samples,
            rawString: rawString,
            hasApostrophe: hasApostrophe,
            pinyinScheme: settings.pinyinScheme,
            topCandidateKind: candidates.first?.kind,
            topCandidateCharCount: candidates.first?.text.count ?? 0,
            guideSyllables: guideSyllables
        )

        let decodeResult = DecodeResult(preeditDisplay: preedit, candidates: candidates)
        if !fastCleanSentenceOnly && !urgentNow && n <= 16 {
            if let dupIdx = recentDecodeHistory.firstIndex(where: {
                $0.samples == samples && $0.precedingContext == precedingContext
                    && $0.topicMemory == topicMemory
                    && $0.fastCleanSentenceOnly == fastCleanSentenceOnly
                    && $0.skipStage5CAssociations == skipStage5CAssociations
            }) {
                recentDecodeHistory.remove(at: dupIdx)
            } else if recentDecodeHistory.count >= 24 {
                recentDecodeHistory.removeFirst()
            }
            recentDecodeHistory.append(
                CachedDecodeHistoryEntry(
                    samples: samples,
                    settings: settings,
                    precedingContext: precedingContext,
                    topicMemory: topicMemory,
                    fastCleanSentenceOnly: fastCleanSentenceOnly,
                    skipStage5CAssociations: skipStage5CAssociations,
                    spatialGeneration: spatialGen,
                    userGeneration: userGen,
                    supplementaryGeneration: supplementaryGeneration,
                    wholeInputClean: currentWholeClean,
                    hasApostrophe: hasApostrophe,
                    isPureEnglishCompound: isPureEnglishCompound,
                    wasUrgentCommit: urgentNow,
                    posHyps: posHyps,
                    posHypsCap: hypCap,
                    arcsByStart: arcsByStart,
                    latticeDepsByStart: latticeDepsByStart,
                    spansByStart: spansByStart,
                    maxPosByStart: maxPosByStart,
                    spanDepsByStart: spanDepsByStart,
                    dp: cachedDP,
                    dpSeedWord: cachedDPSeedWord,
                    dpPrecedingContext: cachedDPPrecedingContext,
                    dpTopicMemory: cachedDPTopicMemory,
                    dpBeamK: cachedDPBeamK,
                    result: decodeResult
                )
            )
        }

        return decodeResult
    }

    private func spokenSupport(_ text: [Character], at offset: Int) -> Int {
        var best = 0
        for length in 2...3 where text.count >= length {
            for start in max(0, offset - length + 1)...min(offset, text.count - length) {
                let word = String(text[start..<(start + length)])
                let score: Int
                if let cached = conversationalCounts[word] {
                    score = cached
                } else {
                    score = lexicon.lookupAssociations(after: "#" + word, limit: 1).first?.scoreQ8 ?? 0
                    if conversationalCounts.count >= 512 { conversationalCounts.removeAll(keepingCapacity: true) }
                    conversationalCounts[word] = score
                }
                best = max(best, length == 3 ? score * 2 : score)
            }
        }
        return best
    }

    private func learnedCommitChoice(after context: String, reading: String, lead: String) -> MmapLexicon.WordHit? {
        guard lexicon.neuralLM.version == 2 else { return nil }
        let pairs: [CommitPair]
        if let cached = commitPairsByReading[reading] {
            pairs = cached
        } else {
            pairs = lexicon.lookupAssociations(after: "$" + reading, limit: 14).compactMap { CommitPair($0.text) }
            if commitPairsByReading.count >= 512 { commitPairsByReading.removeAll(keepingCapacity: true) }
            commitPairsByReading[reading] = pairs
        }
        let matchingPairs = pairs.filter { $0.first == lead || $0.second == lead }
        guard !matchingPairs.isEmpty else { return nil }
        let suffix = Self.extractTrailingChineseSuffix(from: context, maxChars: 12)
        guard !suffix.isEmpty else { return nil }
        let baseFeatures = lexicon.neuralLM.commitContextFeatures(suffix)
        var bestHit: (hit: MmapLexicon.WordHit, excess: Float)? = nil
        for pair in matchingPairs {
            var features = baseFeatures
            features.v3[7] = pair.lexicalFeature(suffix)
            let margin = features.dot(pair.weights) + pair.bias
            let threshold = margin > 0 ? pair.firstThreshold : pair.secondThreshold
            guard threshold < 4, abs(margin) >= threshold else { continue }
            let chosen = margin > 0 ? pair.first : pair.second
            let excess = abs(margin) - threshold
            let hit = MmapLexicon.WordHit(
                text: chosen,
                scoreQ8: min(900, 480 + Int(min(abs(margin), 1) * 650))
            )
            if bestHit == nil || excess > bestHit!.excess {
                bestHit = (hit, excess)
            }
        }
        return bestHit?.hit
    }

    private func shortReadingCue(after left: String, reading: String) -> MmapLexicon.WordHit? {
        for length in stride(from: min(left.count, 4), through: 1, by: -1) {
            let key = "~" + left.suffix(length) + reading
            if let cue = lexicon.lookupAssociations(after: key, limit: 1).first { return cue }
        }
        return contextualHomophoneCue(after: left, reading: reading)
    }

    private func contextualHomophoneCue(after left: String, reading: String) -> MmapLexicon.WordHit? {
        guard !left.isEmpty else { return nil }
        switch reading {
        case "hema":
            if Self.isModalOrChildDrinkContext(left) {
                return .init(text: "喝吗", scoreQ8: 620)
            }
        case "shi":
            if left.hasSuffix("件") || left.hasSuffix("桩") || left.hasSuffix("好") || left.hasSuffix("坏") || left.hasSuffix("急") || left.hasSuffix("心") || left.hasSuffix("没事") || (left.hasSuffix("有") && left.contains("件")) {
                return .init(text: "事", scoreQ8: 920)
            }
            if Self.isNominalLicensedShiContext(left) {
                return .init(text: "事", scoreQ8: 1020)
            }
        case "nabian":
            if Self.isEmbeddedInterrogativeLocativeContext(left) {
                return .init(text: "哪边", scoreQ8: 740)
            }
        case "yijiejue":
            if let last = left.last, !"可足难得用来借能好".contains(last) {
                return .init(text: "已解决", scoreQ8: 680)
            }
        case "zai":
            let zaiRepetitiveSuffixes = ["下次", "明天", "改天", "回头", "等会", "一会", "一会儿", "稍后", "晚点", "以后", "重新", "一下", "先"]
            if zaiRepetitiveSuffixes.contains(where: { left.hasSuffix($0) }) {
                return .init(text: "再", scoreQ8: 780)
            }
        case "de":
            let mannerAdverbs = [
                "慢慢", "认真", "悄悄", "好好", "仔细", "轻轻", "默默", "渐渐", "静静",
                "偷偷", "紧紧", "深深", "飞快", "迅速", "开心", "高兴", "愉快", "顺利", "不断"
            ]
            if mannerAdverbs.contains(where: { left.hasSuffix($0) }) {
                return .init(text: "地", scoreQ8: 1680)
            }
            let cleftDeSuffixes = [
                "怎么说", "谁说", "听说", "刚才说", "跟你说", "和你说", "这么说", "那么说",
                "胡说", "乱说", "老实说", "按理说", "怎么看", "怎么想", "怎么做", "怎么走"
            ]
            if let last = left.last,
               "跑写说做走飞吃睡看完学干考长变显跳唱骑游开拿打来去笑哭累忙气急吓热冷".contains(last),
               !cleftDeSuffixes.contains(where: { left.hasSuffix($0) }) {
                return .init(text: "得", scoreQ8: 1480)
            }
        case "dekuai", "dehao", "deman":
            if let last = left.last, "跑写说做走飞吃睡看完学干考长变显跳唱骑游开拿打来去".contains(last) {
                let target = reading == "dekuai" ? "得快" : (reading == "dehao" ? "得好" : "得慢")
                return .init(text: target, scoreQ8: 780)
            }
        case "zuo":
            if left.hasSuffix("请") || left.hasSuffix("先") || left.hasSuffix("快") || left.hasSuffix("往里") || left.hasSuffix("随便") || left.hasSuffix("过来") {
                return .init(text: "坐", scoreQ8: 780)
            }
        case "ta":
            let chars = Array(left)
            var idx = chars.count - 1
            while idx >= 0 {
                if idx >= 1 {
                    let pair = String(chars[(idx - 1)...idx])
                    if pair == "电脑" || pair == "手机" || pair == "系统" || pair == "软件" {
                        return .init(text: "它", scoreQ8: 780)
                    }
                }
                let ch = chars[idx]
                if "爸哥弟叔爷男他夫兄儿伯舅公".contains(ch) {
                    return .init(text: "他", scoreQ8: 780)
                }
                if "妈姐妹婆姨奶姑女她妇媳嫂娘".contains(ch) {
                    return .init(text: "她", scoreQ8: 780)
                }
                if "猫狗猪鸟鱼虫花草树车机物它书桌椅店杯盘".contains(ch) {
                    return .init(text: "它", scoreQ8: 780)
                }
                idx -= 1
            }
        case "yi":
            let yiPerfectiveSuffixes = ["问题", "款项", "订单", "快递", "文件", "故障", "任务", "消息", "邮件", "均", "都", "全"]
            if yiPerfectiveSuffixes.contains(where: { left.hasSuffix($0) }) {
                return .init(text: "已", scoreQ8: 820)
            }
        default:
            break
        }
        return nil
    }

    /// Segments the user's exact pressed keys with `'` syllable separators while strictly guaranteeing
    /// `result.replacingOccurrences(of: "'", with: "") == rawString.replacingOccurrences(of: "'", with: "")`.
    /// Pressed letters are NEVER substituted (`nihap -> ni'hap`), completed (`woqubeijin -> wo'qu'bei'jin`),
    /// deleted (`niihao -> nii'hao`), transposed, or re-cased.
    private func formatRawPreedit(
        samples: [TouchSample],
        rawString: String,
        hasApostrophe: Bool,
        pinyinScheme: PinyinScheme = .quanpin,
        topCandidateKind: LokeyCandidate.Kind?,
        topCandidateCharCount: Int = 0,
        guideSyllables: [String]
    ) -> String {
        if samples.isEmpty { return "" }
        if !hasApostrophe && (topCandidateKind == .english || topCandidateKind == .rawInput) {
            return rawString
        }

        if pinyinScheme != .quanpin {
            var out = ""
            out.reserveCapacity(rawString.count + rawString.count / 2 + 2)
            var pairLen = 0
            for ch in rawString {
                if ch == "'" {
                    out.append("'")
                    pairLen = 0
                } else {
                    if pairLen == 2 {
                        out.append("'")
                        pairLen = 0
                    }
                    out.append(ch)
                    pairLen += 1
                }
            }
            return out
        }

        var nonApostropheIndices: [Int] = []
        nonApostropheIndices.reserveCapacity(samples.count)
        for (idx, s) in samples.enumerated() where s.primaryChar != "'" {
            nonApostropheIndices.append(idx)
        }
        let m = nonApostropheIndices.count
        guard m > 0 else { return rawString }

        let leadingApostrophe = (samples.first?.primaryChar == "'")
        let trailingApostrophe = (samples.last?.primaryChar == "'")

        var forcedBreaks = Set<Int>()
        for k in 1..<m where nonApostropheIndices[k] > nonApostropheIndices[k - 1] + 1 {
            forcedBreaks.insert(k)
        }

        let rawChars = nonApostropheIndices.map { samples[$0].primaryChar }
        let lowerASCII: [UInt8] = rawChars.map { ch in
            guard let ascii = ch.asciiValue else { return 0 }
            return (ascii >= 0x41 && ascii <= 0x5A) ? (ascii + 32) : ascii
        }

        func matchesRawSlice(_ syl: String, at start: Int) -> Bool {
            let sBytes = Array(syl.utf8)
            let len = sBytes.count
            guard len > 0, start + len <= m else { return false }
            if len > 1 {
                for inner in (start + 1)..<(start + len) where forcedBreaks.contains(inner) {
                    return false
                }
            }
            for i in 0..<len {
                let lc = lowerASCII[start + i]
                let sc = sBytes[i]
                if lc != sc && !(sc == 0x76 /* 'v' */ && lc == 0x75 /* 'u' */) {
                    return false
                }
            }
            return true
        }

        func isFullSyllableGuide(_ syl: String) -> Bool {
            let cnt = syl.utf8.count
            if cnt >= 2 {
                return syl != "zh" && syl != "ch" && syl != "sh"
            }
            return syl == "a" || syl == "e" || syl == "o"
        }

        func rawInitialCandidateStep(_ syl: String, at pos: Int) -> Int? {
            let sBytes = Array(syl.utf8)
            guard let g0 = sBytes.first, pos < m else { return nil }
            let isRetro = (g0 == 0x7A || g0 == 0x63 || g0 == 0x73) && sBytes.count >= 2 && sBytes[1] == 0x68
            if isRetro {
                if pos + 2 <= m && !forcedBreaks.contains(pos + 1) && lowerASCII[pos] == g0 && lowerASCII[pos + 1] == 0x68 {
                    return 2
                }
                if lowerASCII[pos] == g0 {
                    return 1
                }
                return nil
            }
            let isVowelInit = (g0 == 0x61 || g0 == 0x65 || g0 == 0x69 || g0 == 0x6F || g0 == 0x75 || g0 == 0x76)
            if isVowelInit {
                guard (g0 == 0x61 || g0 == 0x65 || g0 == 0x6F) && lowerASCII[pos] == g0 else { return nil }
                return 1
            }
            return lowerASCII[pos] == g0 ? 1 : nil
        }

        func guideInitialStep(_ syl: String, at pos: Int, sylIdx: Int) -> Int? {
            guard let step = rawInitialCandidateStep(syl, at: pos) else { return nil }
            let afterPos = pos + step
            let remSylAfter = guideSyllables.count - sylIdx - 1
            let remRawAfter = m - afterPos
            if remSylAfter == 0 {
                return afterPos == m ? step : nil
            }
            guard remRawAfter >= remSylAfter else { return nil }
            if afterPos < m && !forcedBreaks.contains(afterPos) {
                let nextByte = lowerASCII[afterPos]
                let nextIsVowel = (nextByte == 0x61 || nextByte == 0x65 || nextByte == 0x69 || nextByte == 0x6F || nextByte == 0x75 || nextByte == 0x76)
                let nextGuideFirst = guideSyllables[sylIdx + 1].utf8.first ?? 0
                if nextIsVowel && nextGuideFirst != nextByte {
                    return nil
                }
            }
            if remSylAfter == 1 {
                let nextSyl = guideSyllables[sylIdx + 1]
                let maxNextLen = max(2, nextSyl.utf8.count)
                guard remRawAfter <= maxNextLen else { return nil }
                if remRawAfter >= 2 {
                    let nextFullOk = isFullSyllableGuide(nextSyl) && matchesRawSlice(nextSyl, at: afterPos) && afterPos + nextSyl.utf8.count == m
                    let nextInitOk = (remRawAfter <= 2) && (rawInitialCandidateStep(nextSyl, at: afterPos) == remRawAfter)
                    if !nextFullOk && !nextInitOk {
                        return nil
                    }
                }
            }
            return step
        }

        var breaks = forcedBreaks
        var leftPos = 0
        var leftSylIdx = 0
        while leftSylIdx < guideSyllables.count {
            let syl = guideSyllables[leftSylIdx]
            let remSylAfter = guideSyllables.count - leftSylIdx - 1
            if isFullSyllableGuide(syl) && matchesRawSlice(syl, at: leftPos)
                && !(remSylAfter == 0 && syl.utf8.count == 1 && leftPos + 1 < m && !forcedBreaks.contains(leftPos + 1)) {
                var stepLen = syl.utf8.count
                // If `syl` ends in `'n'` (`"gan"`) and the raw input at `leftPos + stepLen` has `'g'` (`"gang"`) without an
                // explicit apostrophe break, consume `'g'` as part of `"gang"` whenever `'g'` is not the initial of the next syllable.
                if syl.utf8.last == 0x6E /* 'n' */,
                   leftPos + stepLen < m,
                   !forcedBreaks.contains(leftPos + stepLen),
                   lowerASCII[leftPos + stepLen] == 0x67 /* 'g' */ {
                    let nextByte: UInt8 = (leftPos + stepLen + 1 < m) ? lowerASCII[leftPos + stepLen + 1] : 0
                    let nextIsVowel = (nextByte == 0x61 || nextByte == 0x65 || nextByte == 0x69 || nextByte == 0x6F || nextByte == 0x75 || nextByte == 0x76)
                    let nextGuideStartsG = (leftSylIdx + 1 < guideSyllables.count) && (guideSyllables[leftSylIdx + 1].utf8.first == 0x67)
                    if !(nextIsVowel && nextGuideStartsG) {
                        stepLen += 1
                    }
                }
                leftPos += stepLen
                if leftPos < m {
                    breaks.insert(leftPos)
                }
                leftSylIdx += 1
            } else if let initStep = guideInitialStep(syl, at: leftPos, sylIdx: leftSylIdx) {
                leftPos += initStep
                if leftPos < m {
                    breaks.insert(leftPos)
                }
                leftSylIdx += 1
            } else {
                break
            }
        }

        if leftPos < m && guideSyllables.isEmpty && topCandidateKind == .jianpin && topCandidateCharCount >= 2 {
            var pos = 0
            var emitted = 0
            while pos < m && emitted < topCandidateCharCount {
                let remChars = topCandidateCharCount - emitted
                let b0 = lowerASCII[pos]
                let isDigraph = (b0 == 0x7A || b0 == 0x63 || b0 == 0x73)
                    && pos + 1 < m
                    && !forcedBreaks.contains(pos + 1)
                    && lowerASCII[pos + 1] == 0x68
                    && (m - (pos + 2) >= max(0, remChars - 1))
                pos += isDigraph ? 2 : 1
                emitted += 1
                if pos < m && emitted < topCandidateCharCount {
                    breaks.insert(pos)
                }
            }
            leftPos = pos
        }

        if leftPos < m {
            var rightPos = m
            var rightSylIdx = guideSyllables.count - 1
            while rightSylIdx >= leftSylIdx {
                let syl = guideSyllables[rightSylIdx]
                let sylLen = syl.utf8.count
                if isFullSyllableGuide(syl), sylLen > 0, rightPos - sylLen >= leftPos,
                   matchesRawSlice(syl, at: rightPos - sylLen) {
                    rightPos -= sylLen
                    if rightPos > leftPos {
                        breaks.insert(rightPos)
                    }
                    rightSylIdx -= 1
                } else {
                    // Check trailing 2-letter retroflex digraph or 1-letter initial at `rightPos`
                    let sBytes = Array(syl.utf8)
                    let g0 = sBytes.first ?? 0
                    let isRetro = (g0 == 0x7A || g0 == 0x63 || g0 == 0x73) && sBytes.count >= 2 && sBytes[1] == 0x68
                    let remSylBefore = rightSylIdx - leftSylIdx
                    if isRetro && rightPos - 2 >= leftPos + remSylBefore
                        && !forcedBreaks.contains(rightPos - 1)
                        && lowerASCII[rightPos - 2] == g0 && lowerASCII[rightPos - 1] == 0x68 {
                        rightPos -= 2
                        if rightPos > leftPos {
                            breaks.insert(rightPos)
                        }
                        rightSylIdx -= 1
                    } else if g0 != 0 && !(g0 == 0x61 || g0 == 0x65 || g0 == 0x69 || g0 == 0x6F || g0 == 0x75 || g0 == 0x76)
                        && rightPos - 1 >= leftPos + remSylBefore
                        && lowerASCII[rightPos - 1] == g0
                        && (rightPos - 1 == leftPos || {
                            let prevB = lowerASCII[rightPos - 2]
                            return !(g0 == 0x6E || g0 == 0x67 || g0 == 0x72) || !(prevB == 0x61 || prevB == 0x65 || prevB == 0x69 || prevB == 0x6F || prevB == 0x75 || prevB == 0x76)
                        }()) {
                        rightPos -= 1
                        if rightPos > leftPos {
                            breaks.insert(rightPos)
                        }
                        rightSylIdx -= 1
                    } else {
                        break
                    }
                }
            }

            let remLen = rightPos - leftPos
            let remSylCount = max(0, rightSylIdx - leftSylIdx + 1)
            if remLen == 1 && remSylCount == 0 {
                // Never strand a single unconsumed consonant (`'g'` in `wo'gan'g'dao`) as a 1-letter island
                if !forcedBreaks.contains(leftPos) {
                    breaks.remove(leftPos)
                } else if !forcedBreaks.contains(rightPos) {
                    breaks.remove(rightPos)
                }
            } else if remLen > 1 {
                if remSylCount == 1 && remLen <= 6 {
                    // Keep single-syllable typo/prefix-completion chunk intact (`nihap -> ni'hap`, `woqubeijin -> wo'qu'bei'jin`)
                } else {
                    for b in segmentRawWindow(lowerASCII: lowerASCII, start: leftPos, end: rightPos, forcedBreaks: forcedBreaks) {
                        breaks.insert(b)
                    }
                }
            }
        }

        var out = ""
        out.reserveCapacity(m + breaks.count + 2)
        if leadingApostrophe {
            out.append("'")
        }
        for idx in 0..<m {
            if idx > 0 && breaks.contains(idx) {
                out.append("'")
            }
            out.append(rawChars[idx])
        }
        if trailingApostrophe {
            out.append("'")
        }
        return out
    }

    /// Segments an unaligned raw ASCII window `[start ..< end]` into valid Mandarin syllables where possible,
    /// attaching stray typo consonants cleanly to adjacent syllables (`kuannge -> kuan'nge`) and leaving pure
    /// consonant acronyms (`zg`, `wsm`, `rgzn`) un-shredded.
    private func segmentRawWindow(
        lowerASCII: [UInt8],
        start: Int,
        end: Int,
        forcedBreaks: Set<Int>
    ) -> [Int] {
        let len = end - start
        guard len >= 2 else { return [] }

        let hasAnyVowel = lowerASCII[start..<end].contains {
            $0 == 0x61 || $0 == 0x65 || $0 == 0x69 || $0 == 0x6F || $0 == 0x75 || $0 == 0x76
        }
        guard hasAnyVowel else { return [] }

        func isValidSyl(_ a: Int, _ b: Int) -> Bool {
            guard b > a && b - a <= 6 else { return false }
            let sub = String(decoding: lowerASCII[a..<b], as: UTF8.self)
            return lexicon.syllableToID[sub] != nil || sub == "lue" || sub == "nue"
        }

        // Backward DP minimizing `(unmatchedChars * 16 + segmentCount * 2 + resyllabTieBreak)`
        var dpCost = Array(repeating: Int.max / 4, count: end + 1)
        var dpNext = Array(repeating: end, count: end + 1)
        var dpMatched = Array(repeating: false, count: end + 1)
        dpCost[end] = 0

        for pos in stride(from: end - 1, through: start, by: -1) {
            var maxReach = min(end, pos + 6)
            for inner in (pos + 1)..<maxReach where forcedBreaks.contains(inner) {
                maxReach = inner
                break
            }

            // Option A: consume a valid Mandarin syllable `pos ..< nextPos`
            if maxReach > pos {
                for nextPos in stride(from: maxReach, through: pos + 1, by: -1) where isValidSyl(pos, nextPos) {
                    var tie = 0
                    if nextPos < end {
                        let lastB = lowerASCII[nextPos - 1]
                        let nextB = lowerASCII[nextPos]
                        if (lastB == 0x6E || lastB == 0x67) && (nextB == 0x61 || nextB == 0x65 || nextB == 0x6F) {
                            tie = 1
                        }
                    }
                    let c = dpCost[nextPos] + 2 + tie
                    if c < dpCost[pos] {
                        dpCost[pos] = c
                        dpNext[pos] = nextPos
                        dpMatched[pos] = true
                    }
                }
            }

            // Option B: 1 unmatched character (typo consonant/letter)
            let fallbackCost = dpCost[pos + 1] + 16
            if fallbackCost < dpCost[pos] {
                dpCost[pos] = fallbackCost
                dpNext[pos] = pos + 1
                dpMatched[pos] = false
            }
        }

        // Collect segment spans `(segStart, segEnd, isMatched)` and merge unmatched non-syllable runs
        // into cohesive typo chunks (`["kuan", "n", "ge"] -> ["kuan", "nge"]`).
        var segs: [(Int, Int, Bool)] = []
        var cur = start
        while cur < end {
            let nxt = dpNext[cur]
            let isM = dpMatched[cur]
            if !isM, let last = segs.last, !last.2, !forcedBreaks.contains(cur) {
                segs[segs.count - 1] = (last.0, nxt, false)
            } else {
                segs.append((cur, nxt, isM))
            }
            cur = nxt
        }

        // Attach lone 1-char unmatched consonant (`'n'` in `"kuan" + "n" + "ge"`) onto the following syllable (`"nge"`)
        // or preceding syllable (`"hap"`) so single stray typo consonants never create ugly `'x'` islands.
        var merged: [(Int, Int, Bool)] = []
        var idx = 0
        while idx < segs.count {
            let s = segs[idx]
            let sLen = s.1 - s.0
            let b0 = lowerASCII[s.0]
            let isVowel = (b0 == 0x61 || b0 == 0x65 || b0 == 0x69 || b0 == 0x6F || b0 == 0x75 || b0 == 0x76)
            if !s.2 && sLen == 1 && !isVowel {
                if idx + 1 < segs.count && !forcedBreaks.contains(s.1) && (segs[idx + 1].1 - s.0) <= 6 {
                    let nxt = segs[idx + 1]
                    merged.append((s.0, nxt.1, false))
                    idx += 2
                    continue
                } else if let prev = merged.last, !forcedBreaks.contains(s.0) && (s.1 - prev.0) <= 6 {
                    merged[merged.count - 1] = (prev.0, s.1, false)
                    idx += 1
                    continue
                }
            }
            merged.append(s)
            idx += 1
        }

        return merged.dropFirst().map(\.0)
    }

    // MARK: - Step 2: Syllable Lattice Construction (with Spatial Typo Beam Search)

    private func buildSyllableLattice(
        samples: [TouchSample],
        lowerChars: [Character],
        lowerASCII: [UInt8],
        hasApostrophe: Bool,
        posHyps: [[KeyHypothesis]],
        scheme: PinyinScheme = .quanpin,
        fuzzy: FuzzyPinyinOptions,
        enableErrorCorrection: Bool,
        canReuseLatticePrefix: Bool = false,
        prevN: Int = 0,
        minCommon: Int = 0,
        wholeCleanUnchanged: Bool = false,
        latticeRegimeChangedMask: UInt16 = 0,
        previousArcs: [Int: [SyllableArc]] = [:],
        previousLatticeDeps: [LatticeCacheDeps?] = [],
        wholeInputCleanOverride: Bool? = nil,
        fastCleanSentenceOnly: Bool = false,
        isCancelled: () -> Bool = { false },
        urgentNow: Bool = false
    ) -> ([Int: [SyllableArc]], [LatticeCacheDeps?], [Bool]) {
        let n = samples.count
        let wholeInputClean: Bool
        if let override = wholeInputCleanOverride {
            wholeInputClean = override
        } else {
            let rawPrimaryAll = String(lowerChars.filter { $0 >= "a" && $0 <= "z" })
            wholeInputClean = rawPrimaryAll.count >= 4
                && !hasApostrophe
                && lexicon.canSegmentCleanlyOrActiveTail(rawPrimaryAll)
        }
        var arcsByStart: [Int: [SyllableArc]] = [:]
        arcsByStart.reserveCapacity(n)
        var latticeDepsByStart = [LatticeCacheDeps?](repeating: nil, count: n)
        var reusedLatticeStarts = [Bool](repeating: false, count: n)
        let minPrevCurN = min(prevN, n)

        for start in 0..<n {
            if (start & 7) == 0 && isCancelled() {
                return (arcsByStart, latticeDepsByStart, reusedLatticeStarts)
            }
            if canReuseLatticePrefix,
               start < minCommon,
               start < previousLatticeDeps.count,
               let prevDeps = previousLatticeDeps[start],
               prevDeps.maxRawReadEnd <= minCommon,
               prevDeps.maxEndPos < minPrevCurN,
               (!prevDeps.dependsOnWholeClean || wholeCleanUnchanged),
               (prevDeps.dependsOnNMask & latticeRegimeChangedMask) == 0,
               (!prevDeps.readsPrevErArc || (start > 0 && reusedLatticeStarts[start - 1])) {
                if samples[start].primaryChar == "'" {
                    latticeDepsByStart[start] = prevDeps
                    reusedLatticeStarts[start] = true
                    continue
                } else if let cached = previousArcs[start] {
                    arcsByStart[start] = cached
                    latticeDepsByStart[start] = prevDeps
                    reusedLatticeStarts[start] = true
                    continue
                }
            }

            var deps = LatticeCacheDeps(
                maxRawReadEnd: start + 1,
                maxEndPos: start + 1,
                dependsOnWholeClean: false,
                dependsOnNMask: 0,
                readsPrevErArc: false
            )
            if samples[start].primaryChar == "'" {
                // Explicit apostrophe separator: zero-cost epsilon bridge handled by skipping leading `'`
                latticeDepsByStart[start] = deps
                continue
            }

            if scheme != .quanpin {
                let primaryByte = lowerASCII[start]
                var end1 = start + 1
                while end1 < n && samples[end1].primaryChar == "'" { end1 += 1 }
                let localClean = wholeInputClean
                deps.dependsOnWholeClean = true

                var arcs: [SyllableArc] = []
                if start + 1 < n && samples[start + 1].primaryChar != "'" && end1 == start + 1 {
                    var end2 = start + 2
                    while end2 < n && samples[end2].primaryChar == "'" { end2 += 1 }
                    deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, end2 + 1))
                    deps.maxEndPos = max(deps.maxEndPos, end2)

                    let h0List = Array(posHyps[start].prefix(localClean ? 2 : 4))
                    let h1List = Array(posHyps[start + 1].prefix(localClean ? 2 : 4))
                    let b0Raw = lowerASCII[start]
                    let b1Raw = lowerASCII[start + 1]
                    var bestBySID: [UInt16: SyllableArc] = [:]

                    for h0 in h0List {
                        guard let b0 = h0.char.asciiValue else { continue }
                        let t0 = (b0 != b0Raw) ? 1 : 0
                        if !enableErrorCorrection && t0 > 0 { continue }
                        for h1 in h1List {
                            guard let b1 = h1.char.asciiValue else { continue }
                            let t1 = (b1 != b1Raw) ? 1 : 0
                            if !enableErrorCorrection && t1 > 0 { continue }
                            let typos = t0 + t1
                            guard typos <= 1 else { continue }
                            let keyPen = h0.penaltyQ8 + h1.penaltyQ8
                            guard keyPen <= (localClean ? 620 : 1080) else { continue }
                            let matches = PinyinSyllableAutomaton.matchShuangpinPair(
                                b0: b0,
                                b1: b1,
                                scheme: scheme,
                                in: lexicon,
                                fuzzy: fuzzy
                            )
                            for m in matches {
                                let pen = m.penaltyQ8 + keyPen + (typos > 0 && localClean ? 180 : 0)
                                let cand = SyllableArc(
                                    start: start,
                                    end: end2,
                                    syllableID: m.syllableID,
                                    canonical: m.canonical,
                                    penaltyQ8: pen,
                                    isInitialOnly: false,
                                    hasKeySubstitution: typos > 0,
                                    keySubstitutionCount: typos
                                )
                                if let prev = bestBySID[m.syllableID], prev.penaltyQ8 <= cand.penaltyQ8 {
                                    continue
                                }
                                bestBySID[m.syllableID] = cand
                            }
                        }
                    }
                    arcs = bestBySID.values.sorted {
                        if $0.penaltyQ8 != $1.penaltyQ8 { return $0.penaltyQ8 < $1.penaltyQ8 }
                        return $0.canonical < $1.canonical
                    }
                }

                if start + 1 == n || samples[start + 1].primaryChar == "'" {
                    deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, end1 + 1))
                    deps.maxEndPos = max(deps.maxEndPos, end1)
                    if !fastCleanSentenceOnly,
                       let initStr = PinyinSyllableAutomaton.shuangpinInitialString(forKeyByte: primaryByte, scheme: scheme) {
                        arcs.append(
                            SyllableArc(
                                start: start,
                                end: end1,
                                syllableID: 0,
                                canonical: initStr,
                                penaltyQ8: (end1 == n && start > 0) ? 340 : 420,
                                isInitialOnly: true
                            )
                        )
                    }
                }

                arcsByStart[start] = arcs
                latticeDepsByStart[start] = deps
                continue
            }

            // Local clean-context evaluation: for `start + 7 < n` on multi-word sentences (`n >= 9`),
            // depends strictly on `lowerASCII[start ..< start + 7]` so a tail Jianpin/typo never corrupts
            // or invalidates clean earlier syllables (`wolaishi...kuaisshuru`).
            let localClean: Bool
            deps.dependsOnNMask |= LatticeRegimeBit.nGE9
            if n < 9 || hasApostrophe {
                localClean = wholeInputClean
                if !hasApostrophe {
                    deps.dependsOnWholeClean = true
                }
            } else if start + 7 < n {
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, start + 7)
                localClean = lexicon.isLocallyCleanWindowASCII(lowerASCII[start..<(start + 7)])
            } else if n - start >= 5 {
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, n)
                deps.maxEndPos = n
                localClean = lexicon.isLocallyCleanWindowASCII(lowerASCII[start..<n])
            } else {
                deps.dependsOnWholeClean = true
                deps.maxEndPos = n
                localClean = wholeInputClean
            }

            var arcs: [SyllableArc] = []
            if fastCleanSentenceOnly && !enableErrorCorrection && fuzzy.isEmpty && !hasApostrophe {
                var packed: UInt32 = 0
                let maxFastLen = min(6, n - start)
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, start + maxFastLen)
                if n - start < 6 {
                    deps.maxEndPos = n
                }
                if maxFastLen >= 1 {
                    for len in 1...maxFastLen {
                        let b = lowerASCII[start + len - 1]
                        guard b >= 0x61 && b <= 0x7A else { break }
                        packed = (packed << 5) | UInt32(b - 0x60)
                        let endPos = start + len
                        if let sid = lexicon.canonicalSyllableID(forPackedCode: packed), sid > 0 {
                            arcs.append(
                                SyllableArc(
                                    start: start,
                                    end: endPos,
                                    syllableID: sid,
                                    canonical: lexicon.idToSyllable[Int(sid)],
                                    penaltyQ8: 0,
                                    isInitialOnly: false
                                )
                            )
                        } else if len == 3 && (packed == ((12 << 10) | (21 << 5) | 5) || packed == ((14 << 10) | (21 << 5) | 5)) {
                            let vStr = (packed >> 10) == 12 ? "lve" : "nve"
                            if let sid = lexicon.syllableToID[vStr], sid > 0 {
                                arcs.append(
                                    SyllableArc(
                                        start: start,
                                        end: endPos,
                                        syllableID: sid,
                                        canonical: vStr,
                                        penaltyQ8: 0,
                                        isInitialOnly: false
                                    )
                                )
                            }
                        }
                    }
                }
                if start > 0 && lowerASCII[start] == 0x72, let erSID = lexicon.syllableToID["er"], erSID > 0 {
                    deps.readsPrevErArc = true
                    let prevHasEr = arcsByStart[start - 1]?.contains(where: { $0.end == start + 1 && $0.canonical == "er" && !$0.isErhuaOnly }) ?? false
                    if !prevHasEr {
                        arcs.append(
                            SyllableArc(
                                start: start,
                                end: start + 1,
                                syllableID: erSID,
                                canonical: "er",
                                penaltyQ8: 120,
                                isInitialOnly: false,
                                isErhuaOnly: true
                            )
                        )
                    }
                }
                arcsByStart[start] = arcs
                latticeDepsByStart[start] = deps
                continue
            }
            var seenSylEnd = [Int: Int](minimumCapacity: 32) // ((end << 16) | Int(sid)) -> bestPenalty

            // Beam of partial packed ASCII codes from `start`: (packedCode64, accumulatedTouchPenalty, typoCount)
            var beam: [(UInt64, Int, Int)] = [(0, 0, 0)]
            let maxSpanLen = min(7, n - start)
            var rawPackedCode: UInt32 = 0
            var rawAlphaOk = true

            for offset in 0..<maxSpanLen {
                let pos = start + offset
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, pos + 1)
                if samples[pos].primaryChar == "'" {
                    break
                }

                let posPrimary = lowerChars[pos]
                let posByte = lowerASCII[pos]
                if rawAlphaOk && posByte >= 0x61 && posByte <= 0x7A && offset < 6 {
                    rawPackedCode = (rawPackedCode << 5) | UInt32(posByte - 0x60)
                } else {
                    rawAlphaOk = false
                    rawPackedCode = 0
                }
                let hyps = posHyps[pos]
                var nextBeam: [(UInt64, Int, Int)] = []
                nextBeam.reserveCapacity(20)

                if enableErrorCorrection {
                    deps.dependsOnNMask |= LatticeRegimeBit.nGE4 | LatticeRegimeBit.urgent16
                }
                deps.dependsOnNMask |= LatticeRegimeBit.urgent10

                for (codeSoFar, penSoFar, typosSoFar) in beam {
                    for h in hyps {
                        let newTypos = typosSoFar + (h.char == posPrimary ? 0 : 1)
                        if newTypos > 0 && n >= 16 && localClean && urgentNow { continue }
                        let newPen = penSoFar + h.penaltyQ8
                        if newTypos == 1 {
                            if newPen > (localClean ? 660 : 1120) { continue }
                        } else if newTypos == 2 {
                            // Allow 2-neighbor shifted syllables inside unsegmentable multi-syllable typos (`nihsp`/`nibap` -> `你好`,
                            // `shurugs` -> `输入法`, `xianzso` -> `现在`), never when the local window already segments cleanly!
                            guard enableErrorCorrection && !localClean && n >= 4 && newPen <= 1400 else { continue }
                        } else if newTypos > 2 {
                            continue
                        } else if newPen > 1120 {
                            continue
                        }

                        // Zero-allocation `UInt64` packed prefix check!
                        let candCode = (offset == 0 || codeSoFar != 0)
                            ? MmapLexicon.appendPackedASCII64(codeSoFar, char: h.char)
                            : 0
                        let isKnownPrefix = lexicon.isKnownPrefix(candCode)
                        let isClippedWithTypo = enableErrorCorrection && newTypos == 1 && newPen <= 660 && !localClean && n >= 4 && offset < 6 && lexicon.isClippedPrefix(candCode)
                        if isKnownPrefix || (enableErrorCorrection && newTypos == 0 && offset < 6 && candCode != 0) || isClippedWithTypo {
                            nextBeam.append((candCode, newPen, newTypos))
                        }
                    }
                }

                // Keep top hypotheses per length step (deterministic tie-break; 0/1-typo prefixes always precede 2-typo)
                let latBeamCap = (n >= 10 && urgentNow) ? 4 : 12
                if nextBeam.count > latBeamCap {
                    nextBeam.sort {
                        if $0.1 != $1.1 { return $0.1 < $1.1 }
                        if $0.2 != $1.2 { return $0.2 < $1.2 }
                        return $0.0 < $1.0
                    }
                    nextBeam.removeSubrange(latBeamCap..<nextBeam.count)
                }
                beam = nextBeam
                if beam.isEmpty { break }

                if offset == maxSpanLen - 1 && maxSpanLen < 7 {
                    deps.maxEndPos = n
                }

                // Consume any trailing apostrophe(s) right after `pos` (`ni'hao`, `ni''hao`)!
                var endPos = pos + 1
                while endPos < n && samples[endPos].primaryChar == "'" {
                    endPos += 1
                }
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, endPos + 1))
                deps.maxEndPos = max(deps.maxEndPos, endPos)

                let rawIsExactSyllable = rawAlphaOk && (offset < 6) && lexicon.isExactCanonicalPackedSyllable(rawPackedCode)
                // `12965` == "lue", `15013` == "nue"
                let rawIsCleanMultiSyl = offset >= 1
                    && !rawIsExactSyllable
                    && !(rawAlphaOk && offset == 2 && (rawPackedCode == 12965 || rawPackedCode == 15013))
                    && lexicon.canSegmentCleanlyASCII(lowerASCII[start...pos])

                // Prevent invalid split like `zhen` + `g` when `zheng` is valid unless score justifies it:
                // Viterbi word probabilities naturally penalize extra single-letter splits!
                let isInsideRetroflexDigraph = start > 0
                    && lowerASCII[start] == 0x68
                    && (lowerASCII[start - 1] == 0x7A || lowerASCII[start - 1] == 0x63 || lowerASCII[start - 1] == 0x73)
                let nextByte: UInt8 = endPos < n ? lowerASCII[endPos] : 0
                let hasNextLower = nextByte >= 0x61 && nextByte <= 0x7A
                let fuzzyBits = UInt64(fuzzy.rawValue) << 41
                deps.dependsOnNMask |= LatticeRegimeBit.nGE5
                for (candCode, touchPen, typos) in beam {
                    if typos >= 2 && start == 0 && endPos == n {
                        continue
                    }
                    let urgentLocalCleanSkip = n >= 16 && localClean && urgentNow
                    let allowSwap = enableErrorCorrection && !urgentLocalCleanSkip && typos == 0
                        && !(start == 0 && endPos == n && rawIsCleanMultiSyl)
                    let truncatesExactSyllable = hasNextLower
                        && offset < 5
                        && candCode != 0
                        && lexicon.isExactCanonicalPackedSyllable((UInt32(truncatingIfNeeded: candCode) << 5) | UInt32(nextByte - 0x60))
                    // Packed code `0x109` == `"hi"` (`('h' - 0x60) << 5 | ('i' - 0x60)`)
                    let allowHardClip = enableErrorCorrection && !urgentLocalCleanSkip && typos == 0 && !truncatesExactSyllable
                        && !(isInsideRetroflexDigraph && candCode == 0x109)
                    let allowSoftPhon = enableErrorCorrection && !urgentLocalCleanSkip && typos == 0
                    let allowSoftClip = enableErrorCorrection && !urgentLocalCleanSkip && typos == 0 && n >= 5
                        && !isInsideRetroflexDigraph
                        && !(start == 0 && endPos == n)
                        && !truncatesExactSyllable
                    let allowClippedTypo = enableErrorCorrection && typos == 1 && !localClean && n >= 4 && offset >= 1 && !rawIsExactSyllable && !truncatesExactSyllable

                    // O(1) zero-allocation filter for spatial neighbor probes (`typos > 0` with default fuzzy = []):
                    // ~90% of off-center spatial prefixes are incomplete non-syllables; skip String unpacking and cache churn!
                    if !allowSwap && !allowSoftPhon && !allowSoftClip && fuzzy.isEmpty {
                        guard candCode != 0 && candCode <= UInt64(UInt32.max) else { continue }
                        let u32 = UInt32(truncatingIfNeeded: candCode)
                        if allowClippedTypo {
                            if !lexicon.isPackedSyllableOrClippedExact(u32) { continue }
                        } else {
                            if !lexicon.isPackedSyllable(u32) { continue }
                        }
                    }

                    var matchKey = candCode | fuzzyBits
                    if allowSwap { matchKey |= (1 << 35) }
                    if allowHardClip { matchKey |= (1 << 36) }
                    if allowSoftPhon { matchKey |= (1 << 37) }
                    if allowSoftClip { matchKey |= (1 << 38) }
                    if allowClippedTypo { matchKey |= (1 << 39) }
                    if localClean { matchKey |= (1 << 40) }

                    let matched: [PinyinSyllableAutomaton.ExpandedSyllable]
                    if let cached = lookupCache.syllableMatchCache[matchKey] {
                        matched = cached
                    } else {
                        let candStr = MmapLexicon.unpackASCII64(candCode)
                        let computed = PinyinSyllableAutomaton.matchSyllables(
                            raw: candStr,
                            in: lexicon,
                            fuzzy: fuzzy,
                            allowTransposition: allowSwap,
                            allowClipped: allowHardClip,
                            allowSoftPhonetic: allowSoftPhon,
                            allowSoftClipped: allowSoftClip,
                            allowClippedWithTypo: allowClippedTypo,
                            wholeInputClean: localClean
                        )
                        lookupCache.syllableMatchCache[matchKey] = computed
                        matched = computed
                    }
                    for m in matched {
                        // Single-vowel syllables (`a`, `e`, `o`) should rarely be hallucinated from neighbor typos
                        if m.canonical.count == 1 && typos > 0 { continue }
                        if m.canonical.count < 2 && typos >= 2 { continue }
                        let totalPen = touchPen + m.penaltyQ8
                        let seenKey = (endPos << 16) | Int(m.syllableID)
                        let prevBest = seenSylEnd[seenKey] ?? Int.max
                        if totalPen < prevBest {
                            seenSylEnd[seenKey] = totalPen
                            arcs.append(
                                SyllableArc(
                                    start: start,
                                    end: endPos,
                                    syllableID: m.syllableID,
                                    canonical: m.canonical,
                                    penaltyQ8: totalPen,
                                    isInitialOnly: false,
                                    collapsesCleanSyllables: rawIsCleanMultiSyl && totalPen > 70,
                                    hasKeySubstitution: typos > 0,
                                    keySubstitutionCount: typos,
                                    isSoftClipped: m.isSoftClipped
                                )
                            )
                        }
                    }
                }

                // If this span reaches the VERY END of the user's current typing buffer (`endPos == n`),
                // also emit frequency-sorted prefix-matched incomplete syllables (e.g., `beiji` -> `北京`, `yiji` -> `已经`, `xinqi` -> `心情`)!
                if endPos == n && offset >= 1 {
                    for (candCode, touchPen, typos) in beam where typos == 0 {
                        let candStr = MmapLexicon.unpackASCII64(candCode)
                        if let prefixSIDs = lexicon.prefixToSyllableIDs[candStr] {
                            let isAlreadySyllable = lexicon.syllableToID[candStr] != nil
                            let basePen = isAlreadySyllable ? 250 : 170
                            for sid in prefixSIDs.prefix(12) where sid > 0 {
                                let canon = lexicon.idToSyllable[Int(sid)]
                                guard canon.count > candStr.count else { continue }
                                let completionPen = touchPen + basePen + (canon.count - candStr.count) * 35
                                let seenKey = (endPos << 16) | Int(sid)
                                let prevBest = seenSylEnd[seenKey] ?? Int.max
                                if completionPen < prevBest {
                                    seenSylEnd[seenKey] = completionPen
                                    arcs.append(
                                        SyllableArc(
                                            start: start,
                                            end: endPos,
                                            syllableID: sid,
                                            canonical: canon,
                                            penaltyQ8: completionPen,
                                            isInitialOnly: false,
                                            isPrefixCompletion: true
                                        )
                                    )
                                }
                            }
                        } else if enableErrorCorrection && start > 0 && !rawIsCleanMultiSyl,
                                  let clippedPrefixSIDs = lexicon.clippedPrefixToSyllableIDs[candStr] {
                            let basePen = candStr.count >= 3 ? 280 : 720
                            for sid in clippedPrefixSIDs.prefix(8) where sid > 0 {
                                let canon = lexicon.idToSyllable[Int(sid)]
                                guard canon.count > candStr.count else { continue }
                                let completionPen = touchPen + basePen + max(0, canon.count - candStr.count - 1) * 35
                                let seenKey = (endPos << 16) | Int(sid)
                                let prevBest = seenSylEnd[seenKey] ?? Int.max
                                if completionPen < prevBest {
                                    seenSylEnd[seenKey] = completionPen
                                    arcs.append(
                                        SyllableArc(
                                            start: start,
                                            end: endPos,
                                            syllableID: sid,
                                            canonical: canon,
                                            penaltyQ8: completionPen,
                                            isInitialOnly: false,
                                            isPrefixCompletion: true
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Fat-finger doubled, internal, & boundary adjacent rollover deletion rescue
            // (`niihao`, `minggtian`, `mingtiuan`, `nihaop`, `womenb`, `mingtianb`, `nighao`, `mingtisna`)
            if enableErrorCorrection {
                var rawBuf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
                var rawLen = 0
                withUnsafeMutablePointer(to: &rawBuf) { rawTuplePtr in
                    let rawPtr = UnsafeMutableRawPointer(rawTuplePtr).assumingMemoryBound(to: UInt8.self)
                    for offset in 0..<maxSpanLen {
                        let b = lowerASCII[start + offset]
                        guard b >= 0x61 && b <= 0x7A else { break }
                        rawPtr[rawLen] = b
                        rawLen += 1
                    }
                    deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, start + rawLen + 1))
                    if rawLen == maxSpanLen && maxSpanLen < 7 {
                        deps.maxEndPos = n
                    }
                    deps.dependsOnNMask |= LatticeRegimeBit.nGE9 | LatticeRegimeBit.urgent10
                    let skipNonDoubledHere = localClean && ((n >= 9 && start + 7 < n) || (n >= 10 && urgentNow))
                    var hasAdjacentDup = false
                    if skipNonDoubledHere && rawLen >= 2 {
                        for i in 1..<rawLen where rawPtr[i] == rawPtr[i - 1] {
                            hasAdjacentDup = true
                            break
                        }
                    }
                    if rawLen >= 3 && (!skipNonDoubledHere || hasAdjacentDup) {
                        deps.dependsOnNMask |= LatticeRegimeBit.nGE5 | LatticeRegimeBit.nGE6 | LatticeRegimeBit.nGE8 | LatticeRegimeBit.nGE12
                        var redBuf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
                        withUnsafeMutablePointer(to: &redBuf) { redTuplePtr in
                            let redPtr = UnsafeMutableRawPointer(redTuplePtr).assumingMemoryBound(to: UInt8.self)
                            for len in 3...rawLen {
                                if len <= 6 {
                                    var subCode: UInt32 = 0
                                    for i in 0..<len {
                                        subCode = (subCode << 5) | UInt32(rawPtr[i] - 0x60)
                                    }
                                    if lexicon.isKnownSyllableOrOrthoPacked(subCode) {
                                        continue
                                    }
                                }
                                var endPos = start + len
                                while endPos < n && samples[endPos].primaryChar == "'" {
                                    endPos += 1
                                }
                                deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, endPos + 1))
                                deps.maxEndPos = max(deps.maxEndPos, endPos)
                                let isCleanMultiSyl = lexicon.canSegmentCleanlyPointer(rawPtr, count: len)
                                for k in 0..<len {
                                    if k + 1 < len && rawPtr[k] == rawPtr[k + 1] {
                                        continue
                                    }
                                    let isDoubled = (k > 0 && rawPtr[k] == rawPtr[k - 1])
                                    let isNiEGraze: Bool = {
                                        guard !isDoubled && n >= 8 && k == 0 && start >= 2 && len >= 4 else { return false }
                                        guard rawPtr[0] == 0x65
                                            && lowerASCII[start - 2] == 0x6E
                                            && lowerASCII[start - 1] == 0x69
                                            && spatialModel.areKeysAdjacentASCII(0x65, rawPtr[1]) else {
                                            return false
                                        }
                                        if start > 2 && start - 2 <= lowerASCII.count {
                                            let prefixClean = lowerASCII.withUnsafeBufferPointer { buf -> Bool in
                                                guard let ptr = buf.baseAddress else { return false }
                                                return lexicon.canSegmentCleanlyPointer(ptr, count: start - 2)
                                            }
                                            guard prefixClean else { return false }
                                        }
                                        if start + len <= lowerASCII.count {
                                            if (lexicon.bestTwoSyllableWordScoreASCII(lowerASCII[start..<(start + len)]) ?? -9999) >= -3200 {
                                                return false
                                            }
                                            if (lexicon.bestTwoSyllableWordScoreASCII(lowerASCII[(start - 2)..<(start + len)]) ?? -9999) >= -3100 {
                                                return false
                                            }
                                        }
                                        return true
                                    }()
                                    if !isDoubled && !isNiEGraze {
                                        if !(localClean && n >= 9 && start + 7 < n) {
                                            deps.dependsOnWholeClean = true
                                        }
                                        if (localClean && n >= 9 && start + 7 < n) || (wholeInputClean && n >= 12 && isCleanMultiSyl) {
                                            continue
                                        }
                                    }
                                    if isDoubled && isCleanMultiSyl && k == len - 1 && endPos == n {
                                        let lastB = rawPtr[k]
                                        if lastB == 0x61 || lastB == 0x6F || lastB == 0x65 {
                                            continue
                                        }
                                    }
                                    let isInternalAdj = !isDoubled && k > 0 && k < len - 1 && (
                                        spatialModel.areKeysAdjacentASCII(rawPtr[k], rawPtr[k - 1])
                                            || spatialModel.areKeysAdjacentASCII(rawPtr[k], rawPtr[k + 1])
                                            || (k + 2 < len && spatialModel.areKeysAdjacentASCII(rawPtr[k], rawPtr[k + 2]))
                                    )
                                    let isLeadingAdj = !isDoubled && !isInternalAdj && k == 0 && n >= 6
                                        && (spatialModel.areKeysAdjacentASCII(rawPtr[0], rawPtr[1]) || isNiEGraze)
                                    let isTrailingAdj = !isDoubled && !isInternalAdj && k == len - 1
                                        && start > 0 && endPos == n
                                        && spatialModel.areKeysAdjacentASCII(rawPtr[len - 1], rawPtr[len - 2])
                                    guard isDoubled || isInternalAdj || isLeadingAdj || isTrailingAdj else { continue }

                                    let isHorizBoundary = (isLeadingAdj && start > 0 && spatialModel.areKeysHorizontallyAdjacentASCII(rawPtr[0], rawPtr[1]))
                                        || (isTrailingAdj && spatialModel.areKeysHorizontallyAdjacentASCII(rawPtr[len - 1], rawPtr[len - 2]))

                                    let redLen = len - 1
                                    var redCode: UInt32 = 0
                                    var rIdx = 0
                                    for idx in 0..<len where idx != k {
                                        let b = rawPtr[idx]
                                        redPtr[rIdx] = b
                                        if rIdx < 6 {
                                            redCode = (redCode << 5) | UInt32(b - 0x60)
                                        }
                                        rIdx += 1
                                    }

                                    let baseDelPen: Int
                                    if isDoubled {
                                        let stealsCleanNextInitial = localClean && k == len - 1 && endPos < n
                                        baseDelPen = (isCleanMultiSyl || stealsCleanNextInitial) ? 880 : 210
                                    } else if isInternalAdj {
                                        if isCleanMultiSyl {
                                            baseDelPen = 900
                                        } else if localClean {
                                            baseDelPen = 1060
                                        } else {
                                            let destroysCleanSylAfterInitials: Bool = {
                                                guard len - k >= 2 else { return false }
                                                for p in 0..<k {
                                                    let c = rawPtr[p]
                                                    if c == 0x61 || c == 0x65 || c == 0x69 || c == 0x6F || c == 0x75 || c == 0x76 {
                                                        return false
                                                    }
                                                }
                                                if start + len <= lowerASCII.count {
                                                    if lexicon.canonicalSyllableIDASCII(lowerASCII[(start + k)..<(start + len)]) != nil {
                                                        return true
                                                    }
                                                    if k + 2 <= len && (len - (k + 1) >= 2)
                                                        && lexicon.canonicalSyllableIDASCII(lowerASCII[(start + k + 1)..<(start + len)]) != nil {
                                                        return true
                                                    }
                                                    return false
                                                }
                                                return false
                                            }()
                                            baseDelPen = destroysCleanSylAfterInitials ? 920 : 480
                                        }
                                    } else if isNiEGraze {
                                        baseDelPen = 340
                                    } else if isHorizBoundary {
                                        baseDelPen = isCleanMultiSyl ? 940 : (localClean ? 1080 : 520)
                                    } else {
                                        baseDelPen = (isCleanMultiSyl || localClean) ? 1080 : 840
                                    }

                                    if redLen <= 6, let sid = lexicon.canonicalSyllableID(forPackedCode: redCode), sid > 0 {
                                        let redCanon = lexicon.idToSyllable[Int(sid)]
                                        let seenKey = (endPos << 16) | Int(sid)
                                        let prevBest = seenSylEnd[seenKey] ?? Int.max
                                        if baseDelPen < prevBest {
                                            seenSylEnd[seenKey] = baseDelPen
                                            arcs.append(
                                                SyllableArc(
                                                    start: start,
                                                    end: endPos,
                                                    syllableID: sid,
                                                    canonical: redCanon,
                                                    penaltyQ8: baseDelPen,
                                                    isInitialOnly: false,
                                                    collapsesCleanSyllables: isCleanMultiSyl && !isNiEGraze
                                                )
                                            )
                                        }
                                        if isDoubled && !isCleanMultiSyl && n >= 5 && !(start == 0 && endPos == n),
                                           let softSIDs = lexicon.softClippedSyllableIDs(forPackedCode: redCode) {
                                            let softDelPen = baseDelPen + 380
                                            let reducedStartsH = (redPtr[0] == 0x68)
                                            for softSID in softSIDs where softSID > 0 {
                                                let softCanon = lexicon.idToSyllable[Int(softSID)]
                                                let isRetroflex = reducedStartsH
                                                    && (softCanon.hasPrefix("zh") || softCanon.hasPrefix("ch") || softCanon.hasPrefix("sh"))
                                                if isRetroflex || softCanon.hasSuffix("n") {
                                                    continue
                                                }
                                                let softKey = (endPos << 16) | Int(softSID)
                                                let prevSoftBest = seenSylEnd[softKey] ?? Int.max
                                                if softDelPen < prevSoftBest {
                                                    seenSylEnd[softKey] = softDelPen
                                                    arcs.append(
                                                        SyllableArc(
                                                            start: start,
                                                            end: endPos,
                                                            syllableID: softSID,
                                                            canonical: softCanon,
                                                            penaltyQ8: softDelPen,
                                                            isInitialOnly: false,
                                                            isSoftClipped: true
                                                        )
                                                    )
                                                }
                                            }
                                        }
                                    } else if (isDoubled || isInternalAdj) && !isCleanMultiSyl && redLen >= 3 && redLen <= 6 {
                                        let compoundPen = baseDelPen + 240
                                        for sw in 0..<(redLen - 1) where redPtr[sw] != redPtr[sw + 1] {
                                            let tmp = redPtr[sw]
                                            redPtr[sw] = redPtr[sw + 1]
                                            redPtr[sw + 1] = tmp
                                            var swappedCode: UInt32 = 0
                                            for p in 0..<redLen {
                                                swappedCode = (swappedCode << 5) | UInt32(redPtr[p] - 0x60)
                                            }
                                            if let sid = lexicon.canonicalSyllableID(forPackedCode: swappedCode), sid > 0 {
                                                let swapCanon = lexicon.idToSyllable[Int(sid)]
                                                let seenKey = (endPos << 16) | Int(sid)
                                                let prevBest = seenSylEnd[seenKey] ?? Int.max
                                                if compoundPen < prevBest {
                                                    seenSylEnd[seenKey] = compoundPen
                                                    arcs.append(
                                                        SyllableArc(
                                                            start: start,
                                                            end: endPos,
                                                            syllableID: sid,
                                                            canonical: swapCanon,
                                                            penaltyQ8: compoundPen,
                                                            isInitialOnly: false
                                                        )
                                                    )
                                                }
                                            }
                                            redPtr[sw + 1] = redPtr[sw]
                                            redPtr[sw] = tmp
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Native Mandarin Erhua `-r` shorthand (`qunar -> 去哪儿`, `zainar -> 在哪儿`, `zher -> 这儿`, `yihuir -> 一会儿`)
            // and 1-letter initial consonant arc (for mixed Jianpin like `zguo` or trailing initial `jintianx`)
            let primaryLower = lowerChars[start]
            let primaryByte = lowerASCII[start]
            if primaryByte >= 0x61 && primaryByte <= 0x7A {
                var end1 = start + 1
                while end1 < n && samples[end1].primaryChar == "'" { end1 += 1 }
                deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, end1 + 1))
                deps.maxEndPos = max(deps.maxEndPos, end1)
                if primaryByte == 0x72 && start >= 2 && samples[start - 1].primaryChar != "'",
                   let erSID = lexicon.syllableToID["er"], erSID > 0 {
                    arcs.append(
                        SyllableArc(
                            start: start,
                            end: end1,
                            syllableID: erSID,
                            canonical: "er",
                            penaltyQ8: 120,
                            isInitialOnly: false,
                            isErhuaOnly: true
                        )
                    )
                }
                if !fastCleanSentenceOnly {
                    // Check zh / ch / sh two-letter initial (and also emit 1-letter fallback so adjacent initials like `z`+`h` never dead-end)
                    if start + 1 == n && (primaryByte == 0x7A || primaryByte == 0x63 || primaryByte == 0x73) {
                        deps.maxEndPos = n
                    }
                    let isRetroflexDigraph = start + 1 < n
                        && lowerASCII[start + 1] == 0x68
                        && end1 == start + 1
                        && (primaryByte == 0x7A || primaryByte == 0x63 || primaryByte == 0x73)
                    if isRetroflexDigraph {
                        var end2 = start + 2
                        while end2 < n && samples[end2].primaryChar == "'" { end2 += 1 }
                        deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, end2 + 1))
                        deps.maxEndPos = max(deps.maxEndPos, end2)
                        arcs.append(
                            SyllableArc(
                                start: start,
                                end: end2,
                                syllableID: 0,
                                canonical: "\(primaryLower)h",
                                penaltyQ8: (end2 == n && start > 0) ? 380 : 420,
                                isInitialOnly: true
                            )
                        )
                        let hasExactRetroflexFull = arcs.contains {
                            !$0.isInitialOnly && $0.syllableID > 0 && !$0.hasKeySubstitution && !$0.isSoftClipped && !$0.isPrefixCompletion && $0.penaltyQ8 <= 70 && ($0.end - start) >= 3
                        }
                        if !hasExactRetroflexFull {
                            arcs.append(
                                SyllableArc(
                                    start: start,
                                    end: end1,
                                    syllableID: 0,
                                    canonical: String(primaryLower),
                                    penaltyQ8: 500,
                                    isInitialOnly: true
                                )
                            )
                        }
                    } else {
                        arcs.append(
                            SyllableArc(
                                start: start,
                                end: end1,
                                syllableID: 0,
                                canonical: String(primaryLower),
                                penaltyQ8: (end1 == n && start > 0) ? ((primaryByte == 0x61 && localClean) ? 950 : 380) : 480,
                                isInitialOnly: true
                            )
                        )
                    }
                }
            }

            arcsByStart[start] = arcs
            latticeDepsByStart[start] = deps
        }

        return (arcsByStart, latticeDepsByStart, reusedLatticeStarts)
    }

    // MARK: - Contextual Next-Word Association (`联想词`)

    private static let postWordFallbackParticles: [String] = [
        "的", "了", "吗", "呢", "吧", "啊", "是", "在", "也", "都", "不", "就", "和", "有", "很", "去"
    ]

    private static let standaloneTwoCharParticleWords: Set<String> = [
        "真的", "好的", "是的", "有的", "别的", "对的", "错的", "大的", "小的", "新的", "旧的",
        "男的", "女的", "老的", "吃的", "喝的", "玩的", "用的", "穿的", "买的", "说的", "给的",
        "觉得", "记得", "懂得", "舍得", "值得", "难得", "免得", "省得", "显得", "变得", "弄得"
    ]

    private static let openTailSingleCharPredicates: Set<String> = [
        "是", "在", "有", "没", "无", "不", "别", "要", "想", "会", "能", "敢", "肯",
        "去", "来", "到", "回", "进", "出", "上", "下", "过", "了", "着",
        "给", "把", "被", "让", "叫", "请", "使", "跟", "和", "与", "同", "对", "向", "往", "从", "比", "按", "照",
        "打", "看", "说", "听", "吃", "喝", "买", "卖", "做", "干", "搞", "弄", "写", "读", "学", "用", "拿", "带", "找", "穿", "开", "关"
    ]

    private static let postPhraseConversationalContinuations: Set<String> = [
        "了", "的", "吗", "呢", "吧", "啊", "呀", "啦", "哦", "噢", "哈", "嘛", "呗",
        "着", "过", "就", "也", "都", "还", "又", "才", "再", "很", "太", "真"
    ]

    private static func hasDegreeOrDemonstrativeModifierPrefix(_ tailCJK: String) -> Bool {
        guard tailCJK.count >= 2 else { return false }
        let suffix2 = String(tailCJK.suffix(2))
        if let first = suffix2.first, ["太", "很", "真", "好", "最", "更", "越", "挺", "超", "特"].contains(first) {
            return true
        }
        if tailCJK.count >= 3 {
            let suffix3 = String(tailCJK.suffix(3))
            let mod2 = String(suffix3.prefix(2))
            if ["这么", "那么", "多么", "怎么", "非常", "特别", "比较", "有点", "稍微", "十分", "格外", "相当"].contains(mod2) {
                return true
            }
        }
        return false
    }

    /// Computes contextual next-word associations (`联想词`) tailored to the Chinese text immediately before the cursor.
    /// Returns `[]` when there is no trailing Chinese character before the cursor (empty field, after punctuation/space/ASCII).
    /// Runs in `< 0.02 ms` via zero-copy `mmap` binary search + in-memory user bigram cache.
    public func predictNextWords(
        afterContext context: String?,
        committedTailWord: String? = nil,
        limit: Int = 18
    ) -> [LokeyCandidate] {
        let tailCJK = Self.extractTrailingChineseSuffix(from: context ?? "", maxChars: 4)
        guard !tailCJK.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var result: [LokeyCandidate] = []
        result.reserveCapacity(limit)

        func addWord(_ text: String, score: Int, isUser: Bool) {
            guard !text.isEmpty, result.count < limit, seen.insert(text).inserted else { return }
            result.append(
                LokeyCandidate(
                    text: text,
                    consumedInputCount: 0,
                    matchedSyllables: [],
                    scoreQ8: score,
                    kind: isUser ? .userPhrase : .lexiconPhrase,
                    isDeletableUserPhrase: false
                )
            )
        }

        // Longest-suffix priority (`k = 3, 2, 1`): at each suffix length, personal learned continuations
        // for that exact length precede compiled MmapLexicon associations, so a 1-char overlap never
        // overrides a 2-char or 3-char phrase association.
        for k in [3, 2, 1] where tailCJK.count >= k {
            let sub = String(tailCJK.suffix(k))
            let minLearned = (k == 1 && tailCJK.count >= 2) ? 3 : (k == 1 ? 2 : 1)
            for nextSurf in userStore.learnedNextWords(after: sub, minCount: minLearned, limit: 4) {
                addWord(nextSurf, score: 4000, isUser: true)
            }
            let isBoundMultiCharTail = (k == 1)
                && (tailCJK.count >= 2)
                && !Self.openTailSingleCharPredicates.contains(sub)
                && ((committedTailWord?.count ?? 0) >= 2 || Self.hasDegreeOrDemonstrativeModifierPrefix(tailCJK))
            let hits = lexicon.lookupAssociations(after: sub, limit: k >= 2 ? 12 : 8)
            for h in hits {
                if k == 1 && tailCJK.count >= 2 {
                    // Block severed 3-char `[sub][X]的` compound tails (e.g. `"这么早"` + `"期的"` from `"早期的"`).
                    if h.text.count == 2,
                       (h.text.hasSuffix("的") || h.text.hasSuffix("地") || h.text.hasSuffix("得")),
                       !Self.standaloneTwoCharParticleWords.contains(h.text) {
                        continue
                    }
                    // When `sub` is already bound inside a multi-char word/modifier phrase (e.g. `"这么早"`, `"郑钧"`),
                    // do not hijack `sub` into unrelated 1-char word compounds (`"早期"`, `"早晨"`, `"早上"`).
                    if isBoundMultiCharTail && !Self.postPhraseConversationalContinuations.contains(h.text) {
                        continue
                    }
                }
                addWord(h.text, score: h.scoreQ8, isUser: false)
            }
            if result.count >= 14 && k >= 2 {
                break
            }
        }

        if result.count < limit {
            for w in Self.postWordFallbackParticles {
                addWord(w, score: 0, isUser: false)
            }
        }

        return result
    }

    public static func extractTrailingChineseSuffix(from text: String, maxChars: Int = 4) -> String {
        guard !text.isEmpty else { return "" }
        var chars: [Character] = []
        chars.reserveCapacity(maxChars)
        for ch in text.reversed() {
            if Self.isCJKIdeograph(ch) {
                chars.append(ch)
                if chars.count >= maxChars { break }
            } else {
                break
            }
        }
        return String(chars.reversed())
    }

    public static func isCJKIdeograph(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
    }

    // MARK: - Step 3: Multi-Syllable Trie Walk over the Syllable Lattice

    private static let stutterAdverbPrefixes: Set<Character> = [
        "只", "都", "也", "还", "就", "才", "却", "又", "更", "总"
    ]

    private static let adverbialNoSuffixPrefixes: Set<String> = [
        "早点", "晚点", "快点", "慢点", "赶紧", "赶快", "立刻", "马上", "尽量", "千万", "一定"
    ]

    /// Productive 1-character Mandarin derivational suffixes (`《现代汉语构词法》`) that attach to `>= 2`-syllable
    /// lexical stems to form cohesive `2 + 1` / `3 + 1` compound nouns and adjectives (`X感`, `X性`, `X度`, `X化`, `X率`, `X力`, `X器`, `X员`, `X师`, `X论`).
    private static let productiveDerivationalSuffixes: Set<String> = [
        "感", "性", "度", "化", "率", "力", "器", "员", "师", "家",
        "者", "法", "学", "界", "观", "论", "派", "控", "症", "炎",
        "式", "型", "版", "级", "期", "区", "室", "站", "网", "群",
        "圈", "潮", "热", "风", "费", "税", "金", "险", "权", "书",
        "单", "表", "图", "片", "带", "线", "点", "面", "体", "物"
    ]

    private static let pronounMonosyllables: Set<String> = [
        "我", "你", "他", "她", "它", "咱", "您", "谁"
    ]

    private static let pronounCopulas = Set(pronounMonosyllables.map { $0 + "是" })
    private static let standaloneCopulaSpans = Set(["是", "是把"] + sentenceFinalModalParticles.map { "是" + $0 })

    private static let transitiveObjectPronounVerbs: Set<String> = [
        "喊", "叫", "问", "找", "帮", "看", "听", "等", "送", "带", "接", "给", "让", "陪", "管", "理", "骗", "骂", "拍", "想", "爱", "怕"
    ]

    /// Closed-class grammatical Mandarin monosyllables (pronouns, temporal/scope/negation adverbs, modal/directional/light verbs,
    /// prepositions) that naturally chain as `1 + 1 + 1` in spoken Chinese (`我刚到`, `你先去`, `没喊你吗`, `我刚下`)
    /// without representing ungrammatical single-character confetti (`民提啊`, `年两案`, `吧和`).
    private static let chainablePrefixMonosyllables: Set<String> = [
        // Pronouns & Deictics
        "我", "你", "他", "她", "它", "咱", "您", "谁", "这", "那", "哪",
        // Temporal, Scope, Degree, Adversative & Negation Adverbs
        "刚", "才", "先", "再", "又", "还", "都", "也", "就", "只", "光", "全", "但",
        "总", "常", "老", "早", "晚", "快", "慢", "正", "在", "已", "将", "很",
        "太", "真", "更", "最", "挺", "蛮", "多", "少", "不", "没", "别", "未",
        // Directional, Modal, Light Verbs & Prepositions
        "到", "去", "来", "上", "下", "进", "出", "回", "过", "起", "开", "有",
        "是", "要", "想", "能", "会", "敢", "肯", "该", "得", "让", "叫", "给",
        "把", "被", "从", "往", "向", "跟", "对", "朝", "离", "比", "替", "为",
        "看", "听", "说", "聊", "谈", "讲", "吃", "喝", "买", "走", "跑", "坐", "站", "住", "拿",
        "放", "发", "打", "找", "用", "做", "干", "等", "送", "带", "接", "换",
        "喊", "问", "帮", "请", "陪", "管", "理", "骗", "骂", "拍", "玩", "睡", "写", "学"
    ]

    /// Sentence-final modal particles (句末语气助词) that express clause-level grammatical mood (《现代汉语八百词》).
    /// In Mandarin syntax, these occur strictly at clause or sentence boundaries (`sp.end == n` or before punctuation).
    /// They MUST NEVER receive chaining bonuses mid-sentence (`sp.end < n`), nor can they chain into subsequent words.
    private static let sentenceFinalModalParticles: Set<String> = [
        "吗", "呢", "吧", "啊", "呀", "哦", "嘛", "啦", "呗", "啵", "呐"
    ]

    /// Monosyllables that can serve as natural grammatical predicate heads, object pronouns, or complements after a chainable prefix.
    /// Excludes sentence-final modal particles, coordinating conjunctions ("和", "与"), and prepositions ("把", "从", "对", "向", "被")
    /// to prevent ungrammatical function-word confetti chains (*去把和, *把和, *从和).
    private static let chainableNextMonosyllables: Set<String> = [
        // Object Pronouns (paired with `!pronoun+pronoun` guard so `喊+你`, `找+我`, `给+他` chain naturally)
        "我", "你", "他", "她", "它", "咱", "您", "谁",
        // Directional, Action & Light Verbs
        "到", "去", "来", "上", "下", "进", "出", "回", "过", "起", "开", "有",
        "是", "要", "想", "能", "会", "敢", "肯", "该", "得", "让", "叫", "给",
        "看", "听", "说", "聊", "谈", "讲", "吃", "喝", "买", "走", "跑", "坐", "站", "住", "拿",
        "放", "发", "打", "找", "用", "做", "干", "等", "送", "带", "接", "换",
        "喊", "问", "帮", "请", "陪", "管", "理", "骗", "骂", "拍", "玩", "睡", "写", "学",
        // Adverbs & Negators
        "不", "没", "别", "又", "还", "都", "也", "就", "只", "但", "很", "太", "真", "更", "最", "快", "慢",
        // Aspectual & Structural Particles
        "了", "着", "的", "地",
        // Complements & Locatives
        "好", "完", "掉", "见", "懂", "清", "满", "人", "家", "里", "外", "前", "后", "中", "内"
    ]

    /// Motion and activity verbs that take sport, outdoor, or recreational activity nouns/verbs (`去拔河`, `去游泳`, `去春游`)
    private static let motionActivityVerbs: Set<String> = [
        "去", "来", "要", "想", "打算"
    ]

    /// Outdoor, sports, and social activity targets for motion/purposive serial verb constructions
    private static let activityVerbTargets: Set<String> = [
        "拔河", "跑步", "游泳", "爬山", "滑雪", "散步", "春游", "郊游", "野餐", "露营",
        "徒步", "聚会", "团建", "打球", "踢球", "逛街", "旅游", "钓鱼", "跳舞", "健身"
    ]

    /// Major destination cities for directional/locative constructions (`去大理`, `到大理`, `在大理`, `去三亚`, `去丽江`)
    private static let destinationCityTargets: Set<String> = [
        "大理", "丽江", "三亚", "拉萨", "成都", "重庆", "杭州", "厦门", "青岛", "武汉",
        "长沙", "西安", "南京", "苏州", "广州", "深圳", "北京", "上海", "昆明", "桂林",
        "哈尔滨", "洛阳", "敦煌"
    ]

    /// Foreign composer and historical person names that cannot directly follow a directional motion verb without locative (*去巴赫)
    private static let personNameTargets: Set<String> = [
        "巴赫", "贝多芬", "莫扎特", "肖邦", "海顿", "柴可夫斯基", "爱因斯坦"
    ]

    /// Multi-character pronouns that cannot take derivational noun suffixes (`*大家区`, `*我们区`)
    private static let multiCharPronouns: Set<String> = [
        "我们", "你们", "他们", "她们", "它们", "咱们", "大家", "自己", "别人", "人家", "彼此", "各位", "个人"
    ]

    /// Venue nouns ending in "吧" that are NOT modal particles
    private static let nounVenueEndingInBa: Set<String> = [
        "网吧", "酒吧", "贴吧", "迪吧", "氧吧", "水吧", "书吧", "茶吧", "泥吧", "陶吧"
    ]

    /// Leading action verb characters that cannot directly follow the disposal preposition "把" (*把喝, *把喝吧, *把看)
    private static let actionVerbLeadingChars: Set<Character> = [
        "喝", "吃", "做", "看", "买", "去", "来", "跑", "走", "打", "放", "拿", "找", "玩", "写", "读", "听", "说", "开", "关", "坐", "站", "干", "等", "送", "带", "接", "换"
    ]


    private static let arrivalVerbCompounds: Set<String> = [
        "刚到", "才到", "先到", "再到", "快到", "回到", "来到", "走到", "跑到",
        "赶到", "送到", "带到", "搬到", "飞到", "开到", "进到", "出到", "我刚到", "你刚到", "他刚到"
    ]

    private static let tentativeReduplicatedAndSequentialAfterZai: Set<String> = [
        "看看", "想想", "试试", "问问", "找找", "说说", "聊聊", "逛逛", "尝尝", "听听", "算算",
        "说吧", "说呢", "次", "遍", "回去", "回来", "出去", "出来", "进去", "进来"
    ]

    private static let futureTimePrefixesForZaiShuo: Set<String> = [
        "明天", "一会", "一会儿", "回头", "下次", "改天", "晚点", "等会", "以后", "先"
    ]

    private static let drinkModalAndTimePrefixes: Set<String> = [
        "想", "要", "去", "来", "多", "少", "先", "再", "刚", "不", "没", "别", "喜欢", "爱",
        "今天", "早上", "晚上", "中午", "我们", "你们", "一起", "出去"
    ]

    /// Prepositions/conjunctions (`和/跟/与`) and `<modal/negation> + <和/跟/与>` fragments that are syntactically incomplete before sentence-final `吗/嘛/呢/吧/骂`.
    private static let strandedComitativeLastWords: Set<String> = [
        "和", "跟", "与", "同", "及",
        "可以和", "能和", "不能和", "想和", "要和", "会和", "敢和",
        "可以跟", "能跟", "不能跟", "想跟", "要跟", "会跟", "敢跟",
        "可以与", "能与", "不能与"
    ]

    private static let sentenceFinalInterrogativeOrMaTargets: Set<String> = [
        "吗", "嘛", "呢", "吧", "骂"
    ]

    private static let modalDrinkNounExclusion2: Set<String> = [
        "功能", "性能", "智能", "技能", "体能", "本能", "潜能", "产能", "电能", "核能"
    ]

    private static let nominalShiDemonstrativeSuffixes: Set<String> = [
        "就这个", "就那个", "这件", "那件", "哪件",
        "聊这个", "说这个", "谈这个", "讲这个", "问这个", "办这个", "做这个", "为这个", "提这个",
        "聊那个", "说那个", "谈那个", "讲那个", "问那个", "办那个", "做那个", "为那个", "提那个"
    ]

    private static let nominalShiDeSuffixes: Set<String> = [
        "聊的", "说的", "谈的", "问的", "办的", "做的", "营销的", "培训的"
    ]

    @inline(__always)
    private static func isModalOrChildDrinkContext(_ txt: String) -> Bool {
        guard !txt.isEmpty else { return false }
        if txt == "可以" || txt == "能" || txt == "不能" || txt == "想" || txt == "要" || txt == "会" || txt == "孩子" || txt == "宝宝" {
            return true
        }
        if txt.hasSuffix("可以") || txt.hasSuffix("不能") || txt.hasSuffix("孩子") || txt.hasSuffix("宝宝") {
            return true
        }
        if txt.hasSuffix("能") || txt.hasSuffix("想") || txt.hasSuffix("要") {
            let suf2 = String(txt.suffix(2))
            return !modalDrinkNounExclusion2.contains(suf2)
        }
        return false
    }

    @inline(__always)
    private static func isStrictModalAuxForDrink(_ txt: String) -> Bool {
        guard !txt.isEmpty else { return false }
        if txt == "可以" || txt == "能" || txt == "不能" || txt.hasSuffix("可以") || txt.hasSuffix("不能") {
            return true
        }
        if txt.hasSuffix("能") {
            return !modalDrinkNounExclusion2.contains(String(txt.suffix(2)))
        }
        return false
    }

    @inline(__always)
    private static func isLicensedLiaodePrefix(_ txt: String) -> Bool {
        guard let last = txt.last else { return false }
        return last == "不" || last == "还" || last == "真" || last == "太" || last == "挺"
    }

    private static func isNominalLicensedShiContext(_ left: String) -> Bool {
        if nominalShiDemonstrativeSuffixes.contains(where: { left.hasSuffix($0) }) {
            return true
        }
        if nominalShiDeSuffixes.contains(where: { left.hasSuffix($0) }) {
            return true
        }
        return false
    }

    private static func isEmbeddedInterrogativeLocativeContext(_ left: String) -> Bool {
        guard left.count >= 2, let last = left.last,
              "站在去走坐选往向靠".contains(last) else {
            return false
        }
        let body = String(left.dropLast())
        if body.contains("不知道") || body.contains("不知") || body.contains("问") || body.contains("看看") || body.contains("猜") || body.contains("到底") || body.contains("究竟") {
            return true
        }
        if body.contains("看") && !body.hasSuffix("去") && !body.hasSuffix("来") {
            return true
        }
        return false
    }

    private static let beverageAndLiquidTargets: Set<String> = [
        "水", "热水", "开水", "凉水", "冰水", "点水", "杯水", "茶", "奶茶", "咖啡", "牛奶", "豆浆",
        "可乐", "果汁", "啤酒", "酒", "饮料", "汤", "粥", "药", "中药", "什么", "啥", "点什么"
    ]

    private static let vehicleAndSeatTargets: Set<String> = [
        "地铁", "高铁", "飞机", "公交", "车", "火车", "动车", "大巴", "出租车", "船", "电梯",
        "下", "下来", "下吧", "座位"
    ]

    private static let completionActionVerbs: Set<String> = [
        "吃", "看", "写", "做", "忙", "洗", "买", "聊", "打", "学", "改", "发", "弄", "办"
    ]

    private static let perfectiveTargetVerbs: Set<String> = [
        "收到", "发送", "完成", "付款", "解决", "提交", "更新", "到达"
    ]

    private static let nounHandlesEndingInBa: Set<String> = [
        "把手", "火把", "扫把", "拖把", "门把", "车把", "壶把"
    ]

    private static let tentativeReduplicatedVerbs: Set<String> = [
        "试试", "看看", "想想", "问问", "找找", "说说", "聊聊", "逛逛", "尝尝", "听听", "算算", "等等", "走走"
    ]

    private static let purposiveTentativePrefixes: Set<String> = [
        "来", "去", "先", "再", "想", "要", "我", "你", "他", "她", "我们", "你们", "咱们",
        "我来", "我去", "你来", "你去", "先来", "先去",
        "再来", "再去", "出来", "出去", "过来", "过去", "可以", "要不", "不如", "干脆", "还是"
    ]

    private static let abstractFactNounsAfterMotion: Set<String> = [
        "事实", "实时", "实施", "逝世", "史实", "时事"
    ]

    private static let grammaticalCliticSyllables: Set<String> = [
        "le", "de", "ne", "ma", "ba", "zhe", "guo", "a", "ya", "la"
    ]

    private static let degreeAdverbMonosyllables: Set<String> = [
        "很", "更", "太", "真", "最", "挺", "蛮", "超", "贼"
    ]

    private static let gradableAdjectiveMonosyllables: Set<String> = [
        "卡", "累", "饿", "困", "冷", "热", "疼", "痛", "忙", "慢", "快", "大", "小", "高", "低",
        "贵", "难", "烦", "爽", "棒", "稳", "牛", "辣", "苦", "甜", "咸", "酸", "香", "臭", "脏",
        "乱", "差", "远", "近", "多", "少", "早", "晚", "重", "轻", "深", "浅", "硬", "软", "紧",
        "松", "亮", "暗", "吵", "静"
    ]

    private static let clockHourTargets: Set<String> = [
        "一点", "两点", "二点", "三点", "四点", "五点", "六点", "七点", "八点", "九点", "十点", "十一点", "十二点",
        "一点半", "两点半", "三点半", "四点半", "五点半", "六点半", "七点半", "八点半", "九点半", "十点半", "十一点半", "十二点半"
    ]

    private static let timeOfDayPrefixes: Set<String> = [
        "早上", "上午", "中午", "下午", "傍晚", "晚上", "今晚", "明早", "昨晚", "凌晨", "夜里", "半夜",
        "今天早上", "明天早上", "今天上午", "明天上午", "今天中午", "明天中午", "今天下午", "明天下午", "今天晚上", "明天晚上"
    ]

    private static let farewellTimePrefixes: Set<String> = [
        "早上", "上午", "中午", "下午", "晚上", "明天", "今天", "今晚", "明早", "周末", "下周",
        "一会", "一会儿", "等一会", "等一会儿", "回头", "改天", "下次", "稍后", "晚点", "这儿", "那儿",
        "之后", "以后", "过后", "半小时后", "下班后", "开完会", "到了",
        "明天早上", "明天下午", "明天晚上", "今天下午", "今天晚上"
    ]

    private static let meetingClassifierPrefixes: Set<String> = [
        "一个", "有个", "两个", "三个", "这个", "那个", "半个", "整个", "参加", "召开", "开个",
        "电话", "视频", "重要", "紧急", "内部", "部门", "线上", "线下"
    ]

    private static let clauseCohesionTargets: Set<String> = [
        "会议", "体感", "漏键", "卡顿", "极致", "替代", "原生", "不能差", "不能", "回你", "再回你", "谢谢", "一会儿", "一会", "流畅", "家里", "拿一下"
    ]

    private func buildWordSpans(
        samples: [TouchSample],
        lowerChars: [Character],
        lowerASCII: [UInt8],
        n: Int,
        arcsByStart: [Int: [SyllableArc]],
        userSnapshot: UserLexiconStore.DecodeSnapshot,
        scheme: PinyinScheme = .quanpin,
        enableErrorCorrection: Bool,
        wholeInputClean: Bool,
        canReuseSpansBase: Bool = false,
        reusedLatticeStarts: [Bool] = [],
        prevN: Int = 0,
        minCommonCount: Int = 0,
        wholeCleanUnchanged: Bool = false,
        previousIsPureEnglishCompound: Bool = false,
        spanRegimeChangedMask: UInt16 = 0,
        previousSpans: [Int: [WordSpan]] = [:],
        previousMaxPos: [Int: Int] = [:],
        previousSpanDeps: [SpanCacheDeps?] = [],
        fastCleanSentenceOnly: Bool = false,
        isCancelled: () -> Bool = { false },
        urgentNow: Bool = false
    ) -> ([Int: [WordSpan]], [Int: Int], [SpanCacheDeps?], [Bool], Int, Bool) {
        var spansByStart: [Int: [WordSpan]] = [:]
        spansByStart.reserveCapacity(n)
        var maxPosByStart: [Int: Int] = [:]
        maxPosByStart.reserveCapacity(n)
        var spanDepsByStart = Array<SpanCacheDeps?>(repeating: nil, count: n)
        var reusedSpanStarts = Array(repeating: false, count: n)
        let checkUserPhrases = userSnapshot.hasAnyExactPhrases
        let effectiveRawBound = (minCommonCount > 0 && samples.count > minCommonCount && samples[minCommonCount].primaryChar == "'")
            ? (minCommonCount - 1)
            : minCommonCount
        let minPrevCurN = min(prevN, n)
        var nextInvalidLattice = Array(repeating: n, count: n + 1)
        var nextBad = n
        for p in stride(from: n - 1, through: 0, by: -1) {
            if p >= reusedLatticeStarts.count || !reusedLatticeStarts[p] {
                nextBad = p
            }
            nextInvalidLattice[p] = nextBad
        }
        let firstNonSep = samples.firstIndex(where: { $0.primaryChar != "'" }) ?? n
        var posCleanCache = Array<Int8>(repeating: -1, count: n)
        var reachable = Array(repeating: false, count: n + 1)
        if firstNonSep <= n {
            reachable[firstNonSep] = true
        }
        var contiguousReusedStart = 0
        var stillContiguousReused = canReuseSpansBase

        let virtualUserTrieNode = UInt32.max
        struct WalkState {
            let pos: Int
            let trieNode: UInt32
            let syllables: [String]
            let penaltyQ8: Int
            let initialCount: Int
            let subtreeScore: Int
            let hasKeySubstitution: Bool
            let keySubstitutionCount: UInt8
            let hasSoftClipped: Bool
            let userPrefixMatched: Bool

            init(
                pos: Int,
                trieNode: UInt32,
                syllables: [String],
                penaltyQ8: Int,
                initialCount: Int,
                subtreeScore: Int = 0,
                hasKeySubstitution: Bool = false,
                keySubstitutionCount: UInt8 = 0,
                hasSoftClipped: Bool = false,
                userPrefixMatched: Bool = false
            ) {
                self.pos = pos
                self.trieNode = trieNode
                self.syllables = syllables
                self.penaltyQ8 = penaltyQ8
                self.initialCount = initialCount
                self.subtreeScore = subtreeScore
                self.hasKeySubstitution = hasKeySubstitution
                self.keySubstitutionCount = keySubstitutionCount
                self.hasSoftClipped = hasSoftClipped
                self.userPrefixMatched = userPrefixMatched
            }
        }

        // P2-2: Evaluate once per decode outside `for start in 0..<n` so Chinese inputs never pay per-start
        // overhead or poison `SpanCacheDeps` on unrelated prefix starts.
        let isPureEnglishCompound: Bool = {
            guard n >= 6 && n <= 24 && !wholeInputClean else { return false }
            let rem = n - firstNonSep
            guard rem >= 6 && rem <= 24 else { return false }
            for idx in firstNonSep..<n {
                let b = lowerASCII[idx]
                guard b >= 0x61 && b <= 0x7A else { return false }
            }
            let tailSlice = lowerASCII[firstNonSep..<n]
            let canCleanWhole = tailSlice.withUnsafeBufferPointer { buf -> Bool in
                guard let ptr = buf.baseAddress else { return false }
                return lexicon.canSegmentCleanlyPointer(ptr, count: buf.count)
            }
            guard !canCleanWhole else { return false }
            let fullEn = String(decoding: tailSlice, as: UTF8.self)
            if lexicon.lookupExactEnglish(fullEn) != nil { return true }
            for split in 3...(rem - 3) {
                let splitIdx = firstNonSep + split
                let leftBytes = Array(lowerASCII[firstNonSep..<splitIdx])
                let rightBytes = Array(lowerASCII[splitIdx..<n])
                let leftStr = String(decoding: leftBytes, as: UTF8.self)
                let rightStr = String(decoding: rightBytes, as: UTF8.self)
                let leftCommon3 = (leftBytes.count == 3 && Self.commonThreeLetterEnglishWords.contains(leftStr))
                let rightCommon3 = (rightBytes.count == 3 && Self.commonThreeLetterEnglishWords.contains(rightStr))
                guard (leftBytes.count >= 4 || leftCommon3),
                      (rightBytes.count >= 4 || rightCommon3) else { continue }
                guard lexicon.lookupExactEnglish(leftStr) != nil,
                      lexicon.lookupExactEnglish(rightStr) != nil else { continue }
                let leftClean = !leftCommon3 && leftBytes.withUnsafeBufferPointer { buf in
                    guard let p = buf.baseAddress else { return false }
                    return lexicon.canSegmentCleanlyPointer(p, count: buf.count)
                }
                if !leftClean { return true }
            }
            return false
        }()

        for start in 0..<n {
            if (start & 3) == 0 && isCancelled() {
                return (spansByStart, maxPosByStart, spanDepsByStart, reusedSpanStarts, contiguousReusedStart, isPureEnglishCompound)
            }
            if start > firstNonSep && !reachable[start] {
                if stillContiguousReused && start < minCommonCount {
                    contiguousReusedStart = start + 1
                }
                continue
            }
            if canReuseSpansBase,
               isPureEnglishCompound == previousIsPureEnglishCompound,
               start < minCommonCount,
               start < previousSpanDeps.count,
               let prevDeps = previousSpanDeps[start],
               prevDeps.maxArcQueryPos < nextInvalidLattice[start],
               prevDeps.maxRawReadEnd <= effectiveRawBound,
               prevDeps.maxSpanEnd < minPrevCurN,
               (!prevDeps.dependsOnWholeClean || wholeCleanUnchanged),
               (prevDeps.dependsOnNMask & spanRegimeChangedMask) == 0,
               let prevMax = previousMaxPos[start],
               let prevBucket = previousSpans[start] {
                spansByStart[start] = prevBucket
                maxPosByStart[start] = prevMax
                spanDepsByStart[start] = prevDeps
                reusedSpanStarts[start] = true
                for sp in prevBucket {
                    reachable[sp.end] = true
                }
                if stillContiguousReused {
                    contiguousReusedStart = start + 1
                }
                continue
            }
            if samples[start].primaryChar != "'" {
                stillContiguousReused = false
            }

            var deps = SpanCacheDeps(
                maxArcQueryPos: start,
                maxRawReadEnd: start + 1,
                maxSpanEnd: start,
                dependsOnWholeClean: false,
                dependsOnNMask: 0
            )
            if start == 0 {
                deps.dependsOnNMask |= SpanRegimeBit.nGE5
            }
            if urgentNow {
                deps.dependsOnNMask |= SpanRegimeBit.urgent10 | SpanRegimeBit.urgent12 | SpanRegimeBit.urgent18 | SpanRegimeBit.urgent20
            }
            var maxPosReached = start
            let perEndCap: Int
            if fastCleanSentenceOnly && urgentNow && n >= 20 {
                perEndCap = 4
            } else if urgentNow && n >= 12 {
                perEndCap = 6
            } else {
                perEndCap = (start == 0) ? (n <= 4 ? 20 : 14) : 10
            }
            var spansByEnd: [Int: [WordSpan]] = [:]
            spansByEnd.reserveCapacity(8)
            var exactTwoSylCache: [Int: Int] = [:]
            var coherentSpanCache: [Int: Bool] = [:]

            func recordSpan(_ sp: WordSpan) {
                if sp.end > maxPosReached {
                    maxPosReached = sp.end
                }
                // Mutate the uniquely held bucket through Dictionary's modify accessor.
                // Copying it out and assigning it back copies retained spans on every insertion.
                insertSpan(sp, into: &spansByEnd[sp.end, default: []])
            }

            func insertSpan(_ sp: WordSpan, into bucket: inout [WordSpan]) {
                let reserveExact = min(4, perEndCap / 2)
                if bucket.count == perEndCap, let worst = bucket.last, sp.scoreQ8 <= worst.scoreQ8 {
                    if sp.penaltyQ8 > 0 { return }
                    let exactCount = bucket.reduce(0) { $0 + ($1.penaltyQ8 == 0 ? 1 : 0) }
                    if exactCount >= reserveExact { return }
                }
                if let existingIdx = bucket.firstIndex(where: { $0.text == sp.text }) {
                    let existing = bucket[existingIdx]
                    let existingClean = !existing.hasKeySubstitution && existing.penaltyQ8 == 0
                    let incomingClean = !sp.hasKeySubstitution && sp.penaltyQ8 == 0
                    if existingClean && !incomingClean {
                        return
                    }
                    if !(!existingClean && incomingClean) && sp.scoreQ8 <= existing.scoreQ8 {
                        return
                    }
                    bucket.remove(at: existingIdx)
                }
                let ins = bucket.firstIndex(where: { sp.scoreQ8 > $0.scoreQ8 }) ?? bucket.count
                bucket.insert(sp, at: ins)
                if bucket.count > perEndCap {
                    let topExact = bucket[0..<perEndCap].reduce(0) { $0 + ($1.penaltyQ8 == 0 ? 1 : 0) }
                    if bucket[perEndCap].penaltyQ8 == 0 && topExact < reserveExact,
                       let dropNoisy = bucket[0..<perEndCap].lastIndex(where: { $0.penaltyQ8 > 0 }) {
                        bucket.remove(at: dropNoisy)
                    } else {
                        bucket.removeLast()
                    }
                }
            }

            // P2-2: Seamless mid-sentence Chinese-English mixed-input WordSpans
            if samples[start].primaryChar != "'" {
                deps.dependsOnNMask |= SpanRegimeBit.nGE5
            }
            if !fastCleanSentenceOnly && n >= 5 && samples[start].primaryChar != "'" {
                if isPureEnglishCompound {
                    deps.maxRawReadEnd = Int.max
                    deps.maxSpanEnd = n
                } else {
                    let maxEnLen = min(14, n - start)
                    if maxEnLen >= 3 {
                        let b0 = lowerASCII[start]
                        let b1 = lowerASCII[start + 1]
                        let b2 = lowerASCII[start + 2]
                        if lexicon.hasEnglishPrefix3(b0, b1, b2) {
                            var maxEnReadEnd = min(n, start + 3)
                            var suppressForFullPrefix = false
                            var sliceBytes: [UInt8] = []
                            sliceBytes.reserveCapacity(maxEnLen)
                            var sliceHasUpper = false
                            var sliceAllUpper = true
                            var sliceStartsUpper = false
                            for len in 1...maxEnLen {
                                let rawB = samples[start + len - 1].primaryChar.asciiValue ?? 0
                                let isUpper = (rawB >= 0x41 && rawB <= 0x5A)
                                let isLower = (rawB >= 0x61 && rawB <= 0x7A)
                                guard isUpper || isLower else {
                                    maxEnReadEnd = max(maxEnReadEnd, start + len)
                                    break
                                }
                                if len == 1 { sliceStartsUpper = isUpper }
                                if isUpper { sliceHasUpper = true } else { sliceAllUpper = false }
                                sliceBytes.append(isUpper ? (rawB &+ 32) : rawB)
                                guard len >= 3 else { continue }

                                let rawEnd = start + len
                                maxEnReadEnd = max(maxEnReadEnd, rawEnd)
                                let sliceLower = String(decoding: sliceBytes, as: UTF8.self)
                                let hasEnPrefix = !lexicon.lookupEnglish(prefix: sliceLower, limit: 1).isEmpty
                                if !hasEnPrefix {
                                    break
                                }

                                var spanEnd = rawEnd
                                while spanEnd < n && samples[spanEnd].primaryChar == "'" {
                                    spanEnd += 1
                                }
                                maxEnReadEnd = max(maxEnReadEnd, min(n, spanEnd + 1))
                                deps.maxSpanEnd = max(deps.maxSpanEnd, spanEnd)
                                guard start > firstNonSep || spanEnd < n else { continue }
                                if spanEnd < n {
                                    deps.maxArcQueryPos = max(deps.maxArcQueryPos, spanEnd)
                                    guard !(arcsByStart[spanEnd] ?? []).isEmpty else { continue }
                                }

                                let isWhitelist3 = (len == 3 && Self.embeddedEnglishWhitelist3.contains(sliceLower))
                                if !sliceHasUpper {
                                    guard lexicon.syllableToID[sliceLower] == nil else { continue }
                                    if !isWhitelist3 {
                                        guard len >= 4 else { continue }
                                        let cleanPinyin = sliceBytes.withUnsafeBufferPointer { buf -> Bool in
                                            guard let ptr = buf.baseAddress else { return false }
                                            return lexicon.canSegmentCleanlyPointer(ptr, count: buf.count)
                                        }
                                        guard !cleanPinyin else { continue }
                                    }
                                }

                                guard let hit = lexicon.lookupExactEnglish(sliceLower) else { continue }
                                let eligible = (sliceHasUpper && hit.scoreQ8 >= -2450)
                                    || (len >= 4 && hit.scoreQ8 >= -2120)
                                    || isWhitelist3
                                guard eligible else { continue }

                                // Yield full-string 2-word English compounds (`applepie -> Apple pie`, `swiftcode`)
                                // and incomplete English prefix completions (`macbookp -> MacBook Pro`) to Stage 5E.
                                if start == firstNonSep && spanEnd < n {
                                    var tailScanEnd = spanEnd
                                    var tailIsPlainAlpha = true
                                    while tailScanEnd < n {
                                        let b = lowerASCII[tailScanEnd]
                                        tailScanEnd += 1
                                        if b < 0x61 || b > 0x7A {
                                            tailIsPlainAlpha = false
                                            break
                                        }
                                    }
                                    maxEnReadEnd = max(maxEnReadEnd, tailScanEnd)
                                    if tailIsPlainAlpha {
                                        deps.maxSpanEnd = n
                                        if (n - spanEnd) >= 3,
                                           let tailKey = String(bytes: lowerASCII[spanEnd..<n], encoding: .utf8),
                                           lexicon.lookupExactEnglish(tailKey) != nil {
                                            suppressForFullPrefix = true
                                            continue
                                        }
                                        let tailCanCleanChinese = lowerASCII[spanEnd..<n].withUnsafeBufferPointer { buf -> Bool in
                                            guard let ptr = buf.baseAddress else { return false }
                                            return lexicon.canSegmentCleanlyPointer(ptr, count: buf.count)
                                        }
                                        if let fullCleanKey = String(bytes: lowerASCII[firstNonSep..<n], encoding: .utf8),
                                           let enLead = lexicon.lookupEnglish(prefix: fullCleanKey, limit: 1).first,
                                           (enLead.isExactKeyMatch && enLead.scoreQ8 >= -2350)
                                               || (!tailCanCleanChinese && enLead.scoreQ8 >= -2450)
                                               || ((n - spanEnd) <= 3 && enLead.scoreQ8 >= -2200) {
                                            suppressForFullPrefix = true
                                            continue
                                        }
                                    }
                                }

                                let displayText: String
                                if sliceAllUpper && len >= 2 && hit.text.allSatisfy({ $0.isASCII && $0.isLetter }) {
                                    displayText = hit.text.uppercased()
                                } else if sliceStartsUpper,
                                          let firstCh = hit.text.first, firstCh.isLowercase,
                                          !hit.text.dropFirst().contains(where: { $0.isUppercase }) {
                                    displayText = firstCh.uppercased() + hit.text.dropFirst()
                                } else {
                                    displayText = hit.text
                                }

                                let calibratedScore = (hit.scoreQ8 * 2 + (-len * 310)) / 3 + (sliceHasUpper ? 160 : 0)
                                recordSpan(
                                    WordSpan(
                                        start: start,
                                        end: spanEnd,
                                        text: displayText,
                                        syllables: [sliceLower],
                                        scoreQ8: calibratedScore,
                                        penaltyQ8: 0,
                                        isUserPhrase: false,
                                        lastWord: displayText,
                                        isEnglishSpan: true
                                    )
                                )
                            }
                            if suppressForFullPrefix {
                                deps.maxRawReadEnd = Int.max
                                deps.maxSpanEnd = n
                            } else {
                                deps.maxRawReadEnd = max(deps.maxRawReadEnd, maxEnReadEnd)
                            }
                        } else {
                            let breakLen = (b0 < 0x61 || b0 > 0x7A) ? 1 : ((b1 < 0x61 || b1 > 0x7A) ? 2 : 3)
                            deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, start + breakLen))
                        }
                    } else {
                        deps.maxSpanEnd = n
                    }
                }
            }

            if let firstArcs = arcsByStart[start], !firstArcs.isEmpty {

            // Multi-word Jianpin acronym spans (2..4 initials, e.g. `mt` + `wm` -> `明天我们`, `my` + `sb` -> `没有识别`, `bhys` -> `不好意思`)
            // plus curated multi-initial conversational Jianpin words (`ss` -> `试试`, `kk` -> `看看`, `srf` -> `输入法`, `zmy` -> `怎么样`).
            // Skip acronym queries whenever `start` already begins a clean >=2-letter full syllable, a preceding nasal/rhotic coda,
            // the `'h'` of a retroflex digraph (`zh/ch/sh`), or a medial glide (`i/u/v`).
            let startLeadByte = lowerASCII[start]
            let isStartPrecedingCoda: Bool = {
                guard start > 0 && samples[start - 1].primaryChar != "'" else { return false }
                let prevB = lowerASCII[start - 1]
                let prevIsVowel = (prevB == 0x61 || prevB == 0x65 || prevB == 0x69 || prevB == 0x6F || prevB == 0x75 || prevB == 0x76)
                if (startLeadByte == 0x6E || startLeadByte == 0x72) && prevIsVowel { return true }
                if startLeadByte == 0x67 && prevB == 0x6E { return true }
                return false
            }()
            let isStartSecondOfDigraph: Bool = {
                guard start > 0 && startLeadByte == 0x68 && samples[start - 1].primaryChar != "'" else { return false }
                let prevB = lowerASCII[start - 1]
                return prevB == 0x7A || prevB == 0x63 || prevB == 0x73
            }()
            let isStartMedialGlide = (startLeadByte == 0x69 || startLeadByte == 0x75 || startLeadByte == 0x76)
            let hasCleanFullSyllableAtStart = firstArcs.contains(where: {
                !$0.isInitialOnly && $0.syllableID > 0 && !$0.hasKeySubstitution && !$0.isSoftClipped && !$0.isPrefixCompletion && $0.penaltyQ8 <= 70 && ($0.end - start) >= 2
            })
            if scheme == .quanpin && !fastCleanSentenceOnly && !hasCleanFullSyllableAtStart && !isStartPrecedingCoda && !isStartSecondOfDigraph && !isStartMedialGlide {
                deps.dependsOnNMask |= SpanRegimeBit.nGE5
                if n > 4 {
                    deps.dependsOnWholeClean = true
                }
            }
            let maxAcroCap = start == 0 ? 4 : 3
            let maxAcro = (scheme != .quanpin || fastCleanSentenceOnly || (n >= 10 && urgentNow) || (wholeInputClean && n > 4) || hasCleanFullSyllableAtStart || isStartPrecedingCoda || isStartSecondOfDigraph || isStartMedialGlide)
                ? 0
                : min(maxAcroCap, n - start)
            if maxAcro >= 2 {
                if n - start < maxAcroCap {
                    deps.maxSpanEnd = n
                }
                var acroChars: [Character] = []
                acroChars.reserveCapacity(4)
                var posCursor = start
                var validAcro = true
                for len in 1...maxAcro {
                    guard posCursor < n else { validAcro = false; break }
                    let c = lowerChars[posCursor]
                    guard c >= "a" && c <= "z" && c != "i" && c != "u" && c != "v" else { validAcro = false; break }
                    acroChars.append(c)
                    let lastPos = posCursor
                    posCursor += 1
                    while posCursor < n && samples[posCursor].primaryChar == "'" {
                        posCursor += 1
                    }
                    let rawBound = min(n, posCursor + 1)
                    if rawBound > deps.maxRawReadEnd { deps.maxRawReadEnd = rawBound }
                    deps.maxSpanEnd = max(deps.maxSpanEnd, posCursor)
                    if len >= 2 && validAcro {
                        let nextB: UInt8 = posCursor < n ? lowerASCII[posCursor] : 0
                        let hasExplicitSepAfter = posCursor > lastPos + 1
                        let splitsRetroflex = !hasExplicitSepAfter && nextB == 0x68 && (c == "z" || c == "c" || c == "s")
                        let nextIsVowel = (nextB == 0x61 || nextB == 0x65 || nextB == 0x69 || nextB == 0x6F || nextB == 0x75 || nextB == 0x76)
                        let orphansMedialGlide = !hasExplicitSepAfter && (nextB == 0x69 || nextB == 0x75 || nextB == 0x76)
                        let splitsCVOnset = !hasExplicitSepAfter && nextIsVowel
                            && lexicon.canonicalSyllableIDASCII(lowerASCII[lastPos...posCursor]) != nil
                        guard !splitsRetroflex && !orphansMedialGlide && !splitsCVOnset else { continue }
                        let acroStr = String(acroChars)
                        guard !lexicon.canSegmentCleanly(acroStr) else { continue }
                        let acroPen = len * 420
                        let hits = lexicon.lookupJianpin(acroStr, allowPrefix: false, limit: len == 2 ? 12 : 8)
                        if !hits.isEmpty {
                            let acroSyls = acroChars.map(String.init)
                            for hit in hits {
                                recordSpan(
                                    WordSpan(
                                        start: start,
                                        end: posCursor,
                                        text: hit.text,
                                        syllables: acroSyls,
                                        scoreQ8: hit.scoreQ8 - acroPen,
                                        penaltyQ8: acroPen,
                                        isUserPhrase: false,
                                        isJianpinSpan: true
                                    )
                                )
                            }
                        }
                    }
                }
            }

            let canMatchOverlayJp = !isStartPrecedingCoda
                && !isStartSecondOfDigraph
                && startLeadByte >= 0x61 && startLeadByte <= 0x7A
                && (lexicon.overlayJianpinLeadMask & (1 &<< (startLeadByte - 0x61))) != 0
            if scheme == .quanpin && !fastCleanSentenceOnly && canMatchOverlayJp && !hasCleanFullSyllableAtStart {
                deps.dependsOnNMask |= SpanRegimeBit.nGE5
                if n > 4 {
                    deps.dependsOnWholeClean = true
                }
            }
            if scheme == .quanpin && !fastCleanSentenceOnly && canMatchOverlayJp && (!wholeInputClean || n <= 4) && !hasCleanFullSyllableAtStart {
                let maxJpLen = min(7, n - start)
                if maxJpLen >= 2 {
                    if n - start < 7 {
                        deps.maxSpanEnd = n
                    }
                    var jpBytes: [UInt8] = []
                    jpBytes.reserveCapacity(maxJpLen)
                    for jpLen in 1...maxJpLen {
                        let b = lowerASCII[start + jpLen - 1]
                        guard b >= 0x61 && b <= 0x7A else { break }
                        jpBytes.append(b)
                        let scanBound = min(n, start + jpLen + 1)
                        if scanBound > deps.maxRawReadEnd { deps.maxRawReadEnd = scanBound }
                        deps.maxSpanEnd = max(deps.maxSpanEnd, start + jpLen)
                        guard jpLen >= 2 else { continue }
                        let jpStr = String(decoding: jpBytes, as: UTF8.self)
                        let directHits = lexicon.overlayJianpinMap[jpStr]
                        let foldedKey = (jpLen >= 3) ? MmapLexicon.foldRetroflexJianpin(jpStr) : nil
                        let foldedHits = foldedKey.flatMap { lexicon.overlayJianpinMap[$0] }
                        guard let list = directHits ?? foldedHits else { continue }
                        var endJp = start + jpLen
                        while endJp < n && samples[endJp].primaryChar == "'" {
                            endJp += 1
                        }
                        let rawBound = min(n, endJp + 2)
                        if rawBound > deps.maxRawReadEnd { deps.maxRawReadEnd = rawBound }
                        deps.maxSpanEnd = max(deps.maxSpanEnd, endJp)
                        let hasExplicitSepAfter = endJp > start + jpLen
                        let nextB: UInt8 = endJp < n ? lowerASCII[endJp] : 0
                        let lastB = jpBytes[jpLen - 1]
                        let splitsRetroflex = !hasExplicitSepAfter && nextB == 0x68
                            && (lastB == 0x7A || lastB == 0x63 || lastB == 0x73)
                        let nextIsVowel = (nextB == 0x61 || nextB == 0x65 || nextB == 0x69 || nextB == 0x6F || nextB == 0x75 || nextB == 0x76)
                        let orphansMedialGlide = !hasExplicitSepAfter && (nextB == 0x69 || nextB == 0x75 || nextB == 0x76)
                        let splitsCVOnset: Bool = {
                            guard !hasExplicitSepAfter && nextIsVowel else { return false }
                            let lastStart = (lastB == 0x68 && jpLen >= 2 && (jpBytes[jpLen - 2] == 0x7A || jpBytes[jpLen - 2] == 0x63 || jpBytes[jpLen - 2] == 0x73))
                                ? (start + jpLen - 2)
                                : (start + jpLen - 1)
                            return lexicon.canonicalSyllableIDASCII(lowerASCII[lastStart...endJp]) != nil
                        }()
                        guard !splitsRetroflex && !orphansMedialGlide && !splitsCVOnset else { continue }
                        let isCleanSub = jpBytes.withUnsafeBufferPointer { buf -> Bool in
                            guard let base = buf.baseAddress else { return false }
                            return lexicon.canSegmentCleanlyPointer(base, count: jpLen)
                        }
                        guard !isCleanSub else { continue }
                        for item in list {
                            let jpPen = item.syllables.count * 185 + (directHits == nil ? 35 : 0)
                            recordSpan(
                                WordSpan(
                                    start: start,
                                    end: endJp,
                                    text: item.text,
                                    syllables: item.syllables,
                                    scoreQ8: item.scoreQ8 - jpPen,
                                    penaltyQ8: jpPen,
                                    isUserPhrase: false,
                                    isJianpinSpan: true
                                )
                            )
                        }
                    }
                }
            }

            var frontier: [WalkState] = [
                WalkState(
                    pos: start,
                    trieNode: lexicon.rootNodeIndex,
                    syllables: [],
                    penaltyQ8: 0,
                    initialCount: 0,
                    userPrefixMatched: checkUserPhrases
                )
            ]

            // Walk up to 8 syllables deep from `start` (capped to 3 on urgent Spacebar commit for long sentences)
            let urgentSpanMode = (n >= 10 && urgentNow)
            let maxWalkDepth = (n >= 18 && urgentNow) ? 3 : 8
            for depth in 0..<maxWalkDepth {
                var nextFrontier: [WalkState] = []
                nextFrontier.reserveCapacity(16)

                for state in frontier {
                    let stateIsVirtualUser = (state.trieNode == virtualUserTrieNode)
                    if depth > 0 && (stateIsVirtualUser || !lexicon.hasOutgoingEdges(at: state.trieNode)) && !state.userPrefixMatched {
                        if state.pos > deps.maxArcQueryPos { deps.maxArcQueryPos = state.pos }
                        continue
                    }
                    // Cross-syllable & cross-word boundary two-thumb transposition rescue
                    // (`nhiao -> 你好`, `mintgian -> 明天`, `mingtiawnomen -> 明天我们`, `jintiawnomen -> 今天我们`)
                    if scheme == .quanpin && enableErrorCorrection && !stateIsVirtualUser && depth <= 1 && state.penaltyQ8 == 0 && state.initialCount == 0 && !urgentSpanMode && lexicon.hasOutgoingEdges(at: state.trieNode) {
                        deps.dependsOnNMask |= SpanRegimeBit.nGE9
                        if n - state.pos < 4 {
                            deps.maxSpanEnd = n
                        }
                    }
                    let localTransposClean: Bool = {
                        guard scheme == .quanpin && n >= 9 && state.pos + 8 < n else { return false }
                        let b = state.pos + 8
                        if b > deps.maxRawReadEnd { deps.maxRawReadEnd = b }
                        let cachedFlag = posCleanCache[state.pos]
                        if cachedFlag >= 0 { return cachedFlag == 1 }
                        let clean = lexicon.isLocallyCleanWindowASCII(lowerASCII[state.pos..<(state.pos + 8)])
                        posCleanCache[state.pos] = clean ? 1 : 0
                        return clean
                    }()
                    if scheme == .quanpin && enableErrorCorrection && !stateIsVirtualUser && depth <= 1 && state.penaltyQ8 == 0 && state.initialCount == 0 && n - state.pos >= 4 && !localTransposClean && !urgentSpanMode && lexicon.hasOutgoingEdges(at: state.trieNode) {
                        let l1ReadBound = state.pos + 8
                        if l1ReadBound > deps.maxRawReadEnd { deps.maxRawReadEnd = l1ReadBound }
                        var rawWin: [UInt8] = []
                        let maxWin = min(10, n - state.pos)
                        if maxWin < 10 {
                            deps.maxSpanEnd = n
                        }
                        rawWin.reserveCapacity(maxWin)
                        for off in 0..<maxWin {
                            let b = lowerASCII[state.pos + off]
                            guard b >= 0x61 && b <= 0x7A else { break }
                            rawWin.append(b)
                        }
                        if rawWin.count >= 4 {
                            let maxL1 = min(6, rawWin.count - 2)
                            if maxL1 >= 2 {
                                for l1 in 2...maxL1 where rawWin[l1 - 1] != rawWin[l1] {
                                    rawWin.swapAt(l1 - 1, l1)
                                    guard let sid1 = lexicon.canonicalSyllableIDASCII(rawWin[0..<l1]), sid1 > 0,
                                          let n1 = lexicon.step(from: state.trieNode, syllableID: sid1) else {
                                        rawWin.swapAt(l1 - 1, l1)
                                        continue
                                    }
                                    let l2ReadBound = state.pos + maxWin
                                    if l2ReadBound > deps.maxRawReadEnd { deps.maxRawReadEnd = l2ReadBound }
                                    let maxL2 = min(6, rawWin.count - l1)
                                    guard maxL2 >= 2 else {
                                        rawWin.swapAt(l1 - 1, l1)
                                        continue
                                    }
                                    var s1Lazy: String? = nil
                                    for l2 in 2...maxL2 {
                                        guard let sid2 = lexicon.canonicalSyllableIDASCII(rawWin[l1..<(l1 + l2)]), sid2 > 0 else {
                                            continue
                                        }
                                        let s1 = s1Lazy ?? {
                                            let str = String(decoding: rawWin[0..<l1], as: UTF8.self)
                                            s1Lazy = str
                                            return str
                                        }()
                                        let s2 = String(decoding: rawWin[l1..<(l1 + l2)], as: UTF8.self)
                                        var endPos = state.pos + l1 + l2
                                        while endPos < n && samples[endPos].primaryChar == "'" {
                                            endPos += 1
                                        }
                                        deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, endPos + 1))
                                        deps.maxSpanEnd = max(deps.maxSpanEnd, endPos)
                                        rawWin.swapAt(l1 - 1, l1)
                                        let origPair = String(decoding: rawWin[0..<(l1 + l2)], as: UTF8.self)
                                        rawWin.swapAt(l1 - 1, l1)
                                        let isExactOrig = lexicon.canSegmentCleanly(origPair)
                                        let crossPen = isExactOrig ? 680 : 310
                                        let pairSyls = state.syllables + [s1, s2]

                                        if let n2 = lexicon.step(from: n1, syllableID: sid2) {
                                            for w in lexicon.words(at: n2, limit: 4) {
                                                recordSpan(
                                                    WordSpan(
                                                        start: start,
                                                        end: endPos,
                                                        text: w.text,
                                                        syllables: pairSyls,
                                                        scoreQ8: w.scoreQ8 - crossPen,
                                                        penaltyQ8: crossPen,
                                                        isUserPhrase: false
                                                    )
                                                )
                                            }
                                            if depth == 0 && checkUserPhrases {
                                                for up in userSnapshot.exactSyllablePhrases(compactPinyin: s1 + s2) {
                                                    guard let score = up.embeddedScore(syllables: pairSyls, dictionary: lexicon.words(at: n2, limit: 24)) else { continue }
                                                    recordSpan(
                                                        WordSpan(
                                                            start: start,
                                                            end: endPos,
                                                            text: up.surface,
                                                            syllables: pairSyls,
                                                            scoreQ8: score - crossPen,
                                                            penaltyQ8: crossPen,
                                                            isUserPhrase: true
                                                        )
                                                    )
                                                }
                                            }
                                            if endPos < n {
                                                nextFrontier.append(
                                                    WalkState(
                                                        pos: endPos,
                                                        trieNode: n2,
                                                        syllables: pairSyls,
                                                        penaltyQ8: crossPen,
                                                        initialCount: 0,
                                                        subtreeScore: lexicon.maxSubtreeScore(at: n2)
                                                    )
                                                )
                                            }
                                        } else if !isExactOrig,
                                                  let w1 = lexicon.words(at: n1, limit: 1).first,
                                                  let r1 = lexicon.step(from: lexicon.rootNodeIndex, syllableID: sid2) {
                                            // Cross-word boundary swap (`mingtiawnomen` -> `明天` + `我们`)
                                            let w1Assoc = lexicon.associationBonusMap(after: w1.text)
                                            let w1UserBigrams = userSnapshot.bigramBonuses(after: w1.text)
                                            let bridgePen = 320
                                            for w2 in lexicon.words(at: r1, limit: 2) {
                                                let bg = (w1Assoc[w2.text] ?? 0) + (w1UserBigrams?[w2.text] ?? 0)
                                                recordSpan(
                                                    WordSpan(
                                                        start: start,
                                                        end: endPos,
                                                        text: w1.text + w2.text,
                                                        syllables: pairSyls,
                                                        scoreQ8: w1.scoreQ8 + w2.scoreQ8 - 130 + bg - bridgePen,
                                                        penaltyQ8: bridgePen,
                                                        isUserPhrase: false,
                                                        lastWord: w2.text
                                                    )
                                                )
                                            }
                                            if endPos < n {
                                                if endPos > deps.maxArcQueryPos { deps.maxArcQueryPos = endPos }
                                                if let nextArcs = arcsByStart[endPos] {
                                                    for arc2 in nextArcs where !arc2.isInitialOnly && arc2.syllableID > 0 && arc2.penaltyQ8 == 0 {
                                                        guard let r2 = lexicon.step(from: r1, syllableID: arc2.syllableID) else {
                                                            continue
                                                        }
                                                        let fullSyls = pairSyls + [arc2.canonical]
                                                        for w2 in lexicon.words(at: r2, limit: 3) {
                                                            let bg = (w1Assoc[w2.text] ?? 0) + (w1UserBigrams?[w2.text] ?? 0)
                                                            recordSpan(
                                                                WordSpan(
                                                                    start: start,
                                                                    end: arc2.end,
                                                                    text: w1.text + w2.text,
                                                                    syllables: fullSyls,
                                                                    scoreQ8: w1.scoreQ8 + w2.scoreQ8 - 130 + bg - bridgePen,
                                                                    penaltyQ8: bridgePen,
                                                                    isUserPhrase: false,
                                                                    lastWord: w2.text
                                                                )
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    rawWin.swapAt(l1 - 1, l1)
                                }
                            }
                        }
                    }

                    // Word-initial dropped consonant / semivowel 1-step lookahead (`ianzai -> 现在`, `intian -> 今天`,
                    // `ingtian -> 明天`, `enmeyang -> 怎么样`, `urufa -> 输入法`, `ihuan -> 喜欢`, `idao -> 知道`):
                    // Zero-fanout Trie lookahead verifies `(sid1, sid2)` exists in the lexicon BEFORE adding any state!
                    if scheme == .quanpin && enableErrorCorrection && depth == 0 && state.penaltyQ8 == 0 {
                        deps.dependsOnNMask |= SpanRegimeBit.nGE5
                    }
                    if scheme == .quanpin && enableErrorCorrection && depth == 0 && state.penaltyQ8 == 0 && n >= 5 {
                        let firstC = lowerChars[start]
                        let isVowelStart = (firstC == "a" || firstC == "e" || firstC == "i" || firstC == "o" || firstC == "u" || firstC == "v")
                        let canFollowBoundary: Bool = {
                            if start == 0 { return true }
                            let pc = lowerChars[start - 1]
                            return pc == "'" || pc == "a" || pc == "e" || pc == "i" || pc == "o" || pc == "u" || pc == "v"
                                || pc == "n" || pc == "g" || pc == "r"
                        }()
                        if isVowelStart && canFollowBoundary {
                            deps.dependsOnWholeClean = true
                            deps.dependsOnNMask |= SpanRegimeBit.nGE8
                            let vInitBound = start + 5
                            if vInitBound > deps.maxRawReadEnd { deps.maxRawReadEnd = vInitBound }
                            if !wholeInputClean || n >= 8 {
                                var vChars: [Character] = []
                                let maxV = min(4, n - start)
                                vChars.reserveCapacity(maxV)
                                for vOff in 0..<maxV {
                                    let vc = lowerChars[start + vOff]
                                    guard vc >= "a" && vc <= "z" else { break }
                                    vChars.append(vc)
                                }
                                if maxV < 4 {
                                    deps.maxSpanEnd = n
                                }
                                if !vChars.isEmpty {
                                    for vLen in 1...vChars.count {
                                        let vSub = String(vChars[0..<vLen])
                                        if vLen == 1 && wholeInputClean && lexicon.syllableToID[vSub] != nil {
                                            // Protect clean 1-letter syllables (`a`, `e`, `o`, e.g. `womenele -> 我们饿了`)
                                            continue
                                        }
                                        var rimeEnd = start + vLen
                                        while rimeEnd < n && samples[rimeEnd].primaryChar == "'" {
                                            rimeEnd += 1
                                        }
                                        if rimeEnd + 1 > deps.maxRawReadEnd { deps.maxRawReadEnd = rimeEnd + 1 }
                                        deps.maxSpanEnd = max(deps.maxSpanEnd, rimeEnd)
                                        guard rimeEnd < n else { continue }
                                        if lowerChars[rimeEnd] >= "a" && lowerChars[rimeEnd] <= "z",
                                           lexicon.syllableToID[vSub + String(lowerChars[rimeEnd])] != nil {
                                            // Never truncate an exact longer syllable (`an` at `vLen == 1` `"a"`)
                                            continue
                                        }
                                        if rimeEnd > deps.maxArcQueryPos { deps.maxArcQueryPos = rimeEnd }
                                        guard let nextArcs = arcsByStart[rimeEnd] else { continue }
                                        let validNextSIDs = nextArcs
                                            .filter { !$0.isInitialOnly && $0.syllableID > 0 && $0.penaltyQ8 <= 70 }
                                            .map(\.syllableID)
                                        guard !validNextSIDs.isEmpty else { continue }

                                        let hasExactVowelStartWord: Bool = {
                                            guard let exactSID = lexicon.syllableToID[vSub], exactSID > 0,
                                                  let exactN1 = lexicon.step(from: lexicon.rootNodeIndex, syllableID: exactSID) else {
                                                return false
                                            }
                                            for arc2 in nextArcs where !arc2.isInitialOnly && arc2.syllableID > 0 && arc2.penaltyQ8 == 0 {
                                                if let exactN2 = lexicon.step(from: exactN1, syllableID: arc2.syllableID),
                                                   let topScore = lexicon.topWordScore(at: exactN2),
                                                   topScore >= -3350 {
                                                    return true
                                                }
                                            }
                                            return false
                                        }()
                                        if hasExactVowelStartWord { continue }

                                        guard let rimeSIDs = lexicon.rimeToSyllableIDs[vSub] else { continue }
                                        let dropInitPen = (wholeInputClean ? 480 : 395) + (vLen == 1 ? 45 : 0)
                                        for sid1 in rimeSIDs {
                                            guard let n1 = lexicon.step(from: lexicon.rootNodeIndex, syllableID: sid1) else { continue }
                                            if validNextSIDs.contains(where: { lexicon.step(from: n1, syllableID: $0) != nil }) {
                                                nextFrontier.append(
                                                    WalkState(
                                                        pos: rimeEnd,
                                                        trieNode: n1,
                                                        syllables: [lexicon.idToSyllable[Int(sid1)]],
                                                        penaltyQ8: dropInitPen,
                                                        initialCount: 0,
                                                        subtreeScore: lexicon.maxSubtreeScore(at: n1)
                                                    )
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if state.pos > deps.maxArcQueryPos { deps.maxArcQueryPos = state.pos }
                    guard let arcs = arcsByStart[state.pos] else { continue }
                    // A burst can remove the end of one syllable and the entire next syllable.
                    // Require a two-syllable dictionary prefix, an exact suffix and more input after it.
                    if scheme == .quanpin && enableErrorCorrection, !stateIsVirtualUser, depth == 2, state.initialCount == 0, !state.hasKeySubstitution,
                       (1...420).contains(state.penaltyQ8) {
                        deps.dependsOnWholeClean = true
                        deps.dependsOnNMask |= SpanRegimeBit.nGE12
                        deps.maxRawReadEnd = max(deps.maxRawReadEnd, 12)
                        if n >= 12, !wholeInputClean {
                            for arc in arcs where arc.syllableID > 0 && arc.penaltyQ8 == 0 && !arc.isErhuaOnly && arc.canonical.utf8.count >= 2 {
                                deps.maxRawReadEnd = max(deps.maxRawReadEnd, arc.end + 1)
                                deps.maxSpanEnd = max(deps.maxSpanEnd, arc.end)
                                guard arc.end < n, samples[state.pos - 1].primaryChar != "'" else { continue }
                                for (omitted, word) in lexicon.skippedSyllableWords(from: state.trieNode, followedBy: arc.syllableID) {
                                    let penalty = state.penaltyQ8 + 480
                                    recordSpan(WordSpan(start: start, end: arc.end, text: word.text,
                                                        syllables: state.syllables + [omitted, arc.canonical],
                                                        scoreQ8: word.scoreQ8 - penalty, penaltyQ8: penalty, isUserPhrase: false))
                                }
                            }
                        }
                    }
                    let hasPrimaryCleanFullArcAtPos = arcs.contains {
                        !$0.isInitialOnly && $0.syllableID > 0 && !$0.hasKeySubstitution && !$0.isSoftClipped && !$0.isPrefixCompletion && $0.penaltyQ8 <= 70
                    }
                    let hasSteppableCleanArcAtState = !stateIsVirtualUser
                        && state.penaltyQ8 >= 350
                        && !state.hasKeySubstitution
                        && hasPrimaryCleanFullArcAtPos
                        && arcs.contains { cleanArc in
                            !cleanArc.isInitialOnly
                                && cleanArc.syllableID > 0
                                && !cleanArc.hasKeySubstitution
                                && !cleanArc.isSoftClipped
                                && cleanArc.penaltyQ8 <= 70
                                && lexicon.step(from: state.trieNode, syllableID: cleanArc.syllableID) != nil
                        }
                    let maxAllowedSpanPen = (depth >= 2) ? 1850 : 1550
                    for arc in arcs {
                        let combinedHasKeySub = state.hasKeySubstitution || arc.hasKeySubstitution
                        let combinedKeySubCount = state.keySubstitutionCount &+ arc.keySubstitutionCount
                        if combinedKeySubCount >= 3 {
                            deps.maxRawReadEnd = max(deps.maxRawReadEnd, 8)
                            deps.dependsOnNMask |= SpanRegimeBit.nGE8
                        }
                        let compoundEditBarrier = (hasSteppableCleanArcAtState && arc.hasKeySubstitution) ? 280 : 0
                        let multiSubBarrier = (combinedKeySubCount >= 3 && n <= 7) ? (Int(combinedKeySubCount - 2) * 420) : 0
                        let newPen = state.penaltyQ8 + arc.penaltyQ8 + compoundEditBarrier + multiSubBarrier
                        if newPen > maxAllowedSpanPen { continue }

                        if !arc.isInitialOnly && arc.syllableID > 0 {
                            if arc.isErhuaOnly {
                                guard !stateIsVirtualUser,
                                      depth >= 1,
                                      let nextNode = lexicon.step(from: state.trieNode, syllableID: arc.syllableID) else {
                                    continue
                                }
                                let erhuaSyls = state.syllables + [arc.canonical]
                                for w in lexicon.words(at: nextNode, limit: 6) where w.text.hasSuffix("儿") {
                                    recordSpan(
                                        WordSpan(
                                            start: start,
                                            end: arc.end,
                                            text: w.text,
                                            syllables: erhuaSyls,
                                            scoreQ8: w.scoreQ8 - newPen,
                                            penaltyQ8: newPen,
                                            isUserPhrase: false
                                        )
                                    )
                                }
                                continue
                            }

                            var cachedNewSyls: [String]? = nil
                            @inline(__always)
                            func getNewSyls() -> [String] {
                                if let existing = cachedNewSyls { return existing }
                                let built = state.syllables + [arc.canonical]
                                cachedNewSyls = built
                                return built
                            }

                            let nextNode: UInt32
                            if !stateIsVirtualUser, let stepped = lexicon.step(from: state.trieNode, syllableID: arc.syllableID) {
                                nextNode = stepped
                            } else if state.userPrefixMatched
                                && state.initialCount == 0
                                && !arc.isSoftClipped
                                && !arc.isPrefixCompletion
                                && (newPen <= 85 || (start == 0 && arc.end == n))
                                && userSnapshot.hasSyllablePrefix(getNewSyls().joined(separator: " ")) {
                                nextNode = virtualUserTrieNode
                            } else {
                                continue
                            }
                            let combinedSoftClip = state.hasSoftClipped || arc.isSoftClipped
                            // 1) Never let a noisy 1-syllable arc collapse a multi-syllable clean substring into a cheap
                            //    standalone 1-char word (`qunaa -> 去哪啊`, never `全`; `henxiai -> 很喜爱`, never `很小`).
                            // 2) Never let trailing prefix completion rewrite a standalone 1-syllable word when the typed
                            //    letters already form a common Mandarin syllable (`qingkuangne` -> `情况呢`, never `情况能`).
                            // Multi-syllable dictionary words (`depth >= 1`, e.g. `mingtisan -> 明天`, `beiji -> 北京`) are unaffected.
                            var spanPen = newPen
                            if (depth == 0 || (depth == 1 && arc.hasKeySubstitution && arc.end - start >= 4)) && arc.collapsesCleanSyllables {
                                spanPen += 560
                            }
                            if depth == 1 && state.hasSoftClipped && arc.isSoftClipped {
                                // Prevent double soft-clip (`kaka -> 看看`, `mama -> 慢慢`) from hijacking reduplicated clean words
                                spanPen += 220
                            }
                            let isSoftClipBeforeClitic = depth == 1 && state.hasSoftClipped && !arc.isSoftClipped && Self.grammaticalCliticSyllables.contains(arc.canonical)
                            if isSoftClipBeforeClitic {
                                // Protect clean common 1-char predicates + grammatical clitics (`kale -> 卡了`, `gengkale -> 更卡了`,
                                // `shibushihenkale -> 是不是很卡了`, `lale -> 拉了`, `pale -> 怕了`) against soft-clipped verb+clitic entries (`看了`, `砍了`).
                                if let rawFirstSID = lexicon.canonicalSyllableIDASCII(lowerASCII[start..<state.pos]),
                                   lexicon.syllableBestScore(forSyllableID: rawFirstSID) >= -2450 {
                                    spanPen += 760
                                }
                            }
                            let exactTwoSylCleanScore: Int? = {
                                guard depth == 1 && combinedSoftClip else { return nil }
                                let cached: Int
                                if let hit = exactTwoSylCache[arc.end] {
                                    cached = hit
                                } else {
                                    let computed = lexicon.bestTwoSyllableWordScoreASCII(lowerASCII[start..<arc.end]) ?? Int.min
                                    exactTwoSylCache[arc.end] = computed
                                    cached = computed
                                }
                                return cached >= -3350 ? cached : nil
                            }()
                            if depth == 1 && state.hasKeySubstitution && !arc.hasKeySubstitution && arc.penaltyQ8 > 0 {
                                // Narrow guard strictly to `-in` initial substitution (`min -> jin` + `tia -> tian`),
                                // so `mintia -> 明天` beats `今天` (`-1830` vs `-2227`) without penalizing general `[错敲 + 漏敲]` compound words!
                                var lastAlpha: UInt8 = 0
                                var prevAlpha: UInt8 = 0
                                for p in start..<state.pos {
                                    let b = lowerASCII[p]
                                    if b >= 0x61 && b <= 0x7A {
                                        prevAlpha = lastAlpha
                                        lastAlpha = b
                                    }
                                }
                                if prevAlpha == 0x69 && lastAlpha == 0x6E {
                                    spanPen += 720
                                }
                            }
                            var isCoherentMultiSylChunk = false
                            if depth >= 2 && spanPen >= 350 && !combinedSoftClip {
                                deps.dependsOnNMask |= SpanRegimeBit.nGE9
                                deps.maxSpanEnd = max(deps.maxSpanEnd, arc.end)
                            }
                            if n >= 9 && depth >= 2 && arc.end < n && spanPen >= 350 && !combinedSoftClip {
                                let isCoherent: Bool
                                if let hit = coherentSpanCache[arc.end] {
                                    isCoherent = hit
                                } else {
                                    let slice = lowerASCII[start..<arc.end]
                                    var alphaCount = 0
                                    for b in slice where b >= 0x61 && b <= 0x7A { alphaCount += 1 }
                                    let computed = alphaCount >= 4 && lexicon.startsWithCoherentCleanUnitASCII(slice)
                                    coherentSpanCache[arc.end] = computed
                                    isCoherent = computed
                                }
                                if isCoherent {
                                    isCoherentMultiSylChunk = true
                                }
                            }
                            if start > 0 && depth >= 1 && state.pos > 0 && samples[state.pos - 1].primaryChar != "'",
                               let prevSyl = state.syllables.last,
                               let arcFirst = arc.canonical.first,
                               (arcFirst == "a" || arcFirst == "e" || arcFirst == "o"),
                               (prevSyl.hasSuffix("n") || prevSyl.hasSuffix("ng")) {
                                // Mandarin Maximum-Onset law inside mid-sentence multi-syllable spans (`nian + liang'an` vs `nian'lian + gan`)
                                spanPen += 260
                            }
                            if arc.isPrefixCompletion {
                                var rawCode: UInt32 = 0
                                var rawLen = 0
                                for p in state.pos..<arc.end {
                                    let b = lowerASCII[p]
                                    if b >= 0x61 && b <= 0x7A {
                                        if rawLen < 6 {
                                            rawCode = (rawCode << 5) | UInt32(b - 0x60)
                                        }
                                        rawLen += 1
                                    }
                                }
                                if depth == 0 {
                                    if rawLen <= 6,
                                       let rawSID = lexicon.canonicalSyllableID(forPackedCode: rawCode),
                                       let rawNode = lexicon.step(from: lexicon.rootNodeIndex, syllableID: rawSID),
                                       let bestRawScore = lexicon.topWordScore(at: rawNode),
                                       bestRawScore >= -2550 {
                                        spanPen += 680
                                    }
                                } else if (rawLen == 1 && rawCode == 1) || (rawLen == 2 && (
                                    rawCode == ((13 << 5) | 1)     // "ma"
                                    || rawCode == ((14 << 5) | 5)  // "ne"
                                    || rawCode == ((2 << 5) | 1)   // "ba"
                                    || rawCode == ((12 << 5) | 5)  // "le"
                                    || rawCode == ((12 << 5) | 1)  // "la"
                                    || rawCode == ((25 << 5) | 1)  // "ya"
                                )) {
                                    // Protect trailing modal particles inside multi-syllable paths (`qunama -> 去哪吗`, `mangma -> 忙吗`, `wodea -> 我的啊`)
                                    spanPen += (rawLen == 1) ? 950 : 450
                                } else if state.keySubstitutionCount >= 2 {
                                    // Prevent 2-substitution initial + trailing prefix completion (`pemfge -> 捧哏`) from outranking exact-length `鹏哥`
                                    spanPen += 380
                                }
                            }
                            // Soft-clipping a valid syllable (`he -> zhe`, `ba -> ban`, `ka -> kan`) is only valid inside
                            // multi-syllable lexicon words (`depth >= 1`), never as an isolated 1-character word (`*把这吧`, `*办和`).
                            let recordPen = spanPen
                            let topLimit = (depth == 0) ? (start == 0 ? (n <= 4 ? 20 : 14) : 8) : 4
                            if recordPen <= maxAllowedSpanPen && !(depth == 0 && arc.isSoftClipped) {
                                if nextNode != virtualUserTrieNode, let topNodeWordScore = lexicon.topWordScore(at: nextNode) {
                                    if arc.end > maxPosReached {
                                        maxPosReached = arc.end
                                    }
                                    let skipDominatedNoisyWords: Bool = {
                                        guard recordPen > 0,
                                              let curBucket = spansByEnd[arc.end],
                                              curBucket.count == perEndCap,
                                              let worst = curBucket.last else {
                                            return false
                                        }
                                        return (topNodeWordScore - recordPen) <= worst.scoreQ8
                                    }()
                                    if !skipDominatedNoisyWords {
                                        let sylsForWords = getNewSyls()
                                        for w in lexicon.words(at: nextNode, limit: topLimit) {
                                            if recordPen > 0,
                                               let curBucket = spansByEnd[arc.end],
                                               curBucket.count == perEndCap,
                                               let worst = curBucket.last,
                                               (w.scoreQ8 - recordPen) <= worst.scoreQ8 {
                                                break
                                            }
                                            // Prevent vulgar homophones (`尼玛`, `你妈`, `他妈`) from hijacking polite clause endings (`没喊你吗`, `认识他吗`)
                                            let vulgarPen = (start > 0 && (w.text == "尼玛" || w.text == "你妈" || w.text == "他妈")) ? 620 : 0
                                            // When a 2-syllable soft-clipped word (`hege -> 这个`, `xiazai -> 现在`, `haiyu -> 还有`) competes with an already-strong
                                            // exact 2-syllable lexicon word (`合格 -2328`, `下载 -2054`, `海域 -2810`), cap its raw unigram surplus at `+140 Q8`
                                            // in-sentence (and `-80 Q8` standalone or on `yu -> you`) so clean `-yu` words (`海域`, `对于`, `至于`, `教育`) retain #1!
                                            let exactSoftGuardPen: Int
                                            if let exact2Sc = exactTwoSylCleanScore {
                                                let allowedLead: Int
                                                if isSoftClipBeforeClitic {
                                                    allowedLead = -260
                                                } else if (start == 0 && arc.end == n) || (arc.isSoftClipped && arc.canonical == "you") {
                                                    allowedLead = -80
                                                } else {
                                                    allowedLead = 140
                                                }
                                                let surplus = (w.scoreQ8 - recordPen) - exact2Sc
                                                exactSoftGuardPen = surplus > allowedLead ? (surplus - allowedLead) : 0
                                            } else {
                                                exactSoftGuardPen = 0
                                            }
                                            // Prevent 3+ syllable corpus-glued chunks (`wo'gan'dao -> 我感到` -2650) from exploiting single-chunk `log(Z)`
                                            // unigram subsidy over 0-penalty multi-word paths (`我刚 + 到`), while exempting top lexicalized operators (`是不是` -1834, `为什么` -1680).
                                            let coherentChunkPen = (isCoherentMultiSylChunk && w.scoreQ8 < -1950) ? 360 : 0
                                            let effPen = recordPen + exactSoftGuardPen + coherentChunkPen
                                            recordSpan(
                                                WordSpan(
                                                    start: start,
                                                    end: arc.end,
                                                    text: w.text,
                                                    syllables: sylsForWords,
                                                    scoreQ8: w.scoreQ8 - effPen - vulgarPen,
                                                    penaltyQ8: effPen,
                                                    isUserPhrase: false,
                                                    hasKeySubstitution: combinedHasKeySub,
                                                    keySubstitutionCount: combinedKeySubCount
                                                )
                                            )
                                        }
                                    }
                                }
                                // O(1) RAM user phrase lookup (zero SQLite I/O, skipped completely when user phrase table is empty).
                                // Mid-sentence spans require exact/fuzzy match (`recordPen <= 85`) and `>= 2` chars so single-char or
                                // noisy soft-phonetic arcs (`chi -> ci`) never hijack coherent multi-word sentences.
                                if checkUserPhrases && state.initialCount == 0 && (recordPen <= 85 || (start == 0 && arc.end == n)) {
                                    let sylsForUser = getNewSyls()
                                    let compactSyl = sylsForUser.joined()
                                    for up in userSnapshot.exactSyllablePhrases(compactPinyin: compactSyl) where up.surface.count >= 2 {
                                        guard let score = up.embeddedScore(
                                            syllables: sylsForUser,
                                            dictionary: nextNode == virtualUserTrieNode ? [] : lexicon.words(at: nextNode, limit: 24)
                                        ) else { continue }
                                        recordSpan(
                                            WordSpan(
                                                start: start,
                                                end: arc.end,
                                                text: up.surface,
                                                syllables: sylsForUser,
                                                scoreQ8: score - recordPen,
                                                penaltyQ8: recordPen,
                                                isUserPhrase: true,
                                                hasKeySubstitution: combinedHasKeySub,
                                                keySubstitutionCount: combinedKeySubCount
                                            )
                                        )
                                    }
                                }
                            }

                            // Shared nasal-coda boundary consonant (`zhonguo -> 中国`, `dianao -> 电脑`, `chengong -> 成功`)
                            // AND generalized Trie-guided dropped-initial consonant/semivowel recovery (`woen -> 我们`, `xianai -> 现在`,
                            // `meiou -> 没有`, `zhiao -> 知道`, `shiou -> 时候`, `xiuan -> 喜欢`, `kei -> 可以`, `suoi -> 所以`,
                            // `weni -> 问题`, `shurua -> 输入法`, `kuaiu -> 快速`, `zenmean -> 怎么办`)!
                            if scheme == .quanpin && enableErrorCorrection && nextNode != virtualUserTrieNode && depth <= (urgentSpanMode ? 1 : 2) && spanPen <= (urgentSpanMode ? 300 : 620) && arc.end < n && arc.canonical.count >= 2 && lexicon.hasOutgoingEdges(at: nextNode) {
                                if arc.end + 2 > deps.maxRawReadEnd { deps.maxRawReadEnd = arc.end + 2 }
                                let firstVB = lowerASCII[arc.end]
                                let v0IsVowel = (firstVB == 0x61 || firstVB == 0x65 || firstVB == 0x69 || firstVB == 0x6F || firstVB == 0x75 || firstVB == 0x76)
                                let v0IsH = (firstVB == 0x68 && arc.end + 1 < n && lowerASCII[arc.end + 1] >= 0x61 && lowerASCII[arc.end + 1] <= 0x7A)
                                if v0IsVowel || v0IsH {
                                    if arc.end + 5 > deps.maxRawReadEnd { deps.maxRawReadEnd = arc.end + 5 }
                                    var vBuf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0))
                                    var vCount = 0
                                    let maxV = min(4, n - arc.end)
                                    if maxV < 4 {
                                        deps.maxSpanEnd = n
                                    }
                                    for vOff in 0..<maxV {
                                        let vb = lowerASCII[arc.end + vOff]
                                        guard vb >= 0x61 && vb <= 0x7A else { break }
                                        switch vCount {
                                        case 0: vBuf.0 = vb
                                        case 1: vBuf.1 = vb
                                        case 2: vBuf.2 = vb
                                        default: vBuf.3 = vb
                                        }
                                        vCount += 1
                                    }
                                    if vCount > 0 {
                                        var prevSylCode: UInt32 = 0
                                        var prevSylLen = 0
                                        for p in state.pos..<arc.end {
                                            let pb = lowerASCII[p]
                                            if pb >= 0x61 && pb <= 0x7A {
                                                if prevSylLen < 6 {
                                                    prevSylCode = (prevSylCode << 5) | UInt32(pb - 0x60)
                                                }
                                                prevSylLen += 1
                                            }
                                        }
                                        let codaByte = arc.canonical.utf8.last ?? 0
                                        let codaNibble: UInt32 = (depth <= 1 && spanPen == 0 && (codaByte == 0x67 || codaByte == 0x6E))
                                            ? UInt32(codaByte - 0x60)
                                            : 0

                                        var packedRime: UInt32 = 0
                                        for vLen in 1...vCount {
                                            let curVB: UInt8
                                            switch vLen {
                                            case 1: curVB = vBuf.0
                                            case 2: curVB = vBuf.1
                                            case 3: curVB = vBuf.2
                                            default: curVB = vBuf.3
                                            }
                                            packedRime = (packedRime << 5) | UInt32(curVB - 0x60)
                                            if v0IsH && vLen < 2 { continue }

                                            var end2 = arc.end + vLen
                                            while end2 < n && samples[end2].primaryChar == "'" {
                                                end2 += 1
                                            }
                                            deps.maxRawReadEnd = max(deps.maxRawReadEnd, min(n, end2 + 1))
                                            deps.maxSpanEnd = max(deps.maxSpanEnd, end2)

                                            var sharedNasalSID: UInt16 = 0
                                            // 1. Shared boundary `'g'` or `'n'` (`zhonguo -> 中国`, `dianao -> 电脑`)
                                            if v0IsVowel && codaNibble != 0 && vLen <= 5 {
                                                let recCode = (codaNibble << (vLen * 5)) | packedRime
                                                if let sid2 = lexicon.canonicalSyllableID(forPackedCode: recCode), sid2 > 0,
                                                   let n2 = lexicon.step(from: nextNode, syllableID: sid2) {
                                                    sharedNasalSID = sid2
                                                    let recSyl = lexicon.idToSyllable[Int(sid2)]
                                                    let sharedPen = 290
                                                    let sharedSyls = getNewSyls() + [recSyl]
                                                    for w in lexicon.words(at: n2, limit: 4) {
                                                        recordSpan(
                                                            WordSpan(
                                                                start: start,
                                                                end: end2,
                                                                text: w.text,
                                                                syllables: sharedSyls,
                                                                scoreQ8: w.scoreQ8 - sharedPen,
                                                                penaltyQ8: sharedPen,
                                                                isUserPhrase: false,
                                                                hasKeySubstitution: combinedHasKeySub,
                                                                keySubstitutionCount: combinedKeySubCount
                                                            )
                                                        )
                                                    }
                                                    if end2 < n {
                                                        nextFrontier.append(
                                                            WalkState(
                                                                pos: end2,
                                                                trieNode: n2,
                                                                syllables: sharedSyls,
                                                                penaltyQ8: sharedPen,
                                                                initialCount: state.initialCount,
                                                                subtreeScore: lexicon.maxSubtreeScore(at: n2),
                                                                hasKeySubstitution: combinedHasKeySub,
                                                                keySubstitutionCount: combinedKeySubCount,
                                                                hasSoftClipped: combinedSoftClip
                                                            )
                                                        )
                                                    }
                                                }
                                            }

                                            // 2. Generalized dropped-initial consonant/semivowel recovery (`woen`, `xianai`, `meiou`, `zhiao`, `kei`, `kuaiu`, `shurua`, `zenmean`)
                                            let isOpenParticleVowel = (vLen == 1 && (vBuf.0 == 0x61 || vBuf.0 == 0x65 || vBuf.0 == 0x6F))

                                            // Dropped initial + non-doubled `'o'` -> incomplete `"ou"` rime (`meio -> 没有`, `meiole -> 没有了`,
                                            // `meioma -> 没有吗`, `meiozhege -> 没有这个`, `haio -> 还有`, `shio -> 时候`):
                                            // Never fires on doubled `'oo'` modal particles (`haoo -> 好哦`, `shuoo -> 说哦`, `nihaoo -> 你好哦`),
                                            // and never splits ANY valid canonical Mandarin `-o`/`-ao`/`-iao`/`-uo` syllable (`hao`, `shuo`, `chuo`, `cuo`, `ruo`, `xiao`).
                                            if vLen == 1 && vBuf.0 == 0x6F && !arc.isInitialOnly && !arc.isSoftClipped
                                                && arc.end > 0 && lowerASCII[arc.end - 1] != 0x6F {
                                                if end2 + 2 > deps.maxRawReadEnd { deps.maxRawReadEnd = end2 + 2 }
                                                let canContinueAfterIncompleteOu: Bool = {
                                                    if end2 == n { return true }
                                                    let nextB = lowerASCII[end2]
                                                    guard nextB >= 0x61 && nextB <= 0x7A && nextB != 0x75 && nextB != 0x6F else {
                                                        return false
                                                    }
                                                    if nextB == 0x6E && end2 + 1 < n && lowerASCII[end2 + 1] == 0x67 {
                                                        return false
                                                    }
                                                    return true
                                                }()
                                                let allowOuSplit: Bool
                                                if !canContinueAfterIncompleteOu {
                                                    allowOuSplit = false
                                                } else if prevSylLen + 1 <= 6 {
                                                    let pairCode = (prevSylCode << 5) | 15
                                                    allowOuSplit = (lexicon.canonicalSyllableID(forPackedCode: pairCode) == nil)
                                                } else {
                                                    allowOuSplit = true
                                                }
                                                if allowOuSplit {
                                                    let exactOPhrase: Bool = {
                                                        guard let exactOSID = lexicon.canonicalSyllableID(forPackedCode: 15),
                                                              let exactONode = lexicon.step(from: nextNode, syllableID: exactOSID),
                                                              let topExactO = lexicon.topWordScore(at: exactONode) else {
                                                            return false
                                                        }
                                                        return topExactO >= -3600
                                                    }()
                                                    if end2 == n || !exactOPhrase {
                                                        let incompleteOuPen = spanPen + (exactOPhrase ? 780 : 540)
                                                        if incompleteOuPen <= maxAllowedSpanPen {
                                                            let packedOuRime: UInt32 = (15 << 5) | 21 // "ou"
                                                            let ouCacheKey = (UInt64(nextNode) << 26) | UInt64(packedOuRime)
                                                            let ouEdges: [MmapLexicon.DroppedInitialEdgeHit]
                                                            if let cachedOu = lookupCache.droppedInitialCache[ouCacheKey] {
                                                                ouEdges = cachedOu
                                                            } else {
                                                                let computedOu = lexicon.matchDroppedInitialEdges(
                                                                    from: nextNode,
                                                                    packedRime: packedOuRime,
                                                                    isHRime: false,
                                                                    limit: 5
                                                                )
                                                                lookupCache.droppedInitialCache[ouCacheKey] = computedOu
                                                                ouEdges = computedOu
                                                            }
                                                            for ouEdge in ouEdges {
                                                                if sharedNasalSID != 0 && ouEdge.syllableID == sharedNasalSID { continue }
                                                                var ouSylsCached: [String]? = nil
                                                                if let topOuWord = lexicon.topWordScore(at: ouEdge.targetNode) {
                                                                    if end2 > maxPosReached { maxPosReached = end2 }
                                                                    let skipOuWords: Bool = {
                                                                        guard let curBucket = spansByEnd[end2],
                                                                              curBucket.count == perEndCap,
                                                                              let worst = curBucket.last else {
                                                                            return false
                                                                        }
                                                                        return (topOuWord - incompleteOuPen) <= worst.scoreQ8
                                                                    }()
                                                                    if !skipOuWords {
                                                                        let ouSyls = getNewSyls() + [ouEdge.canonical]
                                                                        ouSylsCached = ouSyls
                                                                        for w in lexicon.words(at: ouEdge.targetNode, limit: 3) {
                                                                            recordSpan(
                                                                                WordSpan(
                                                                                    start: start,
                                                                                    end: end2,
                                                                                    text: w.text,
                                                                                    syllables: ouSyls,
                                                                                    scoreQ8: w.scoreQ8 - incompleteOuPen,
                                                                                    penaltyQ8: incompleteOuPen,
                                                                                    isUserPhrase: false,
                                                                                    hasKeySubstitution: combinedHasKeySub,
                                                                                    keySubstitutionCount: combinedKeySubCount
                                                                                )
                                                                            )
                                                                        }
                                                                    }
                                                                }
                                                                if end2 < n && depth < 3 && lexicon.hasOutgoingEdges(at: ouEdge.targetNode) {
                                                                    let ouSyls = ouSylsCached ?? (getNewSyls() + [ouEdge.canonical])
                                                                    nextFrontier.append(
                                                                        WalkState(
                                                                            pos: end2,
                                                                            trieNode: ouEdge.targetNode,
                                                                            syllables: ouSyls,
                                                                            penaltyQ8: incompleteOuPen,
                                                                            initialCount: state.initialCount,
                                                                            subtreeScore: ouEdge.subtreeScore,
                                                                            hasKeySubstitution: combinedHasKeySub,
                                                                            keySubstitutionCount: combinedKeySubCount,
                                                                            hasSoftClipped: combinedSoftClip
                                                                        )
                                                                    )
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            if isOpenParticleVowel && end2 == n && (depth == 0 || depth >= 2 || arc.isSoftClipped || lowerASCII[arc.end - 1] == vBuf.0) {
                                                // Allow 2-syllable dropped `'m'` after `'n'` (`shene -> shen + [m]e -> 什么`, `zene -> zen + [m]e -> 怎么`)
                                                // while protecting clean words (`jine -> 金额`, `minge -> 名额`, `fene -> 份额`) and modal particles (`qunaa -> 去哪啊`, `shuoo -> 说哦`).
                                                let allowDroppedMAfterN = depth == 0
                                                    && vLen == 1
                                                    && vBuf.0 == 0x65
                                                    && !arc.isSoftClipped
                                                    && lowerASCII[arc.end - 1] == 0x6E
                                                    && (lexicon.bestTwoSyllableWordScoreASCII(lowerASCII[start..<end2]) ?? -9999) < -3100
                                                if !allowDroppedMAfterN {
                                                    continue
                                                }
                                            }

                                            // Phonological Single-Syllable Guard BEFORE probing `matchDroppedInitialEdges`:
                                            // NEVER split a single valid Mandarin syllable (`tian`, `jian`, `xian`, `xiao`, `kuai`, `suan`, `tuan`)
                                            // into `prevSyl + [droppedInitial] + vSlice`!
                                            if prevSylLen + vLen <= 6 {
                                                let pairCode = (prevSylCode << (vLen * 5)) | packedRime
                                                let pairSingleSylScore: Int = {
                                                    // `12965` == "lue", `15013` == "nue"
                                                    if pairCode == 12965 || pairCode == 15013 { return -1500 }
                                                    guard let pSID = lexicon.canonicalSyllableID(forPackedCode: pairCode) else { return -32000 }
                                                    return lexicon.syllableBestScore(forSyllableID: pSID)
                                                }()
                                                // `468015` == "niao"
                                                if pairCode == 468015 {
                                                    deps.dependsOnNMask |= SpanRegimeBit.nGE6
                                                }
                                                let allowPairSplit = (pairSingleSylScore < -2450) || (pairCode == 468015 && n >= 6)
                                                guard allowPairSplit else { continue }
                                            }

                                            if vLen >= 2 && prevSylLen + 1 <= 6 {
                                                let longerCode = (prevSylCode << 5) | UInt32(vBuf.0 - 0x60)
                                                if lexicon.isExactCanonicalPackedSyllable(longerCode) {
                                                    let restClean = withUnsafeBytes(of: &vBuf) { ptr -> Bool in
                                                        guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                                                        return lexicon.canSegmentCleanlyPointer(base.advanced(by: 1), count: vLen - 1)
                                                    }
                                                    if restClean { continue }
                                                }
                                            }

                                            let hasExactVowelPhrase: Bool = {
                                                guard v0IsVowel,
                                                      let exactVSID = lexicon.canonicalSyllableID(forPackedCode: packedRime),
                                                      let exactVNode = lexicon.step(from: nextNode, syllableID: exactVSID),
                                                      let topExactScore = lexicon.topWordScore(at: exactVNode) else {
                                                    return false
                                                }
                                                return topExactScore >= -3600
                                            }()

                                            let baseDropPen: Int
                                            if hasExactVowelPhrase {
                                                baseDropPen = 720
                                            } else if prevSylLen == 2 && prevSylCode == 457 && vLen == 2 && packedRime == 47 {
                                                // `prevSylRaw == "ni" && vSlice == "ao"`
                                                baseDropPen = 540
                                            } else if vLen == 1 {
                                                if isOpenParticleVowel {
                                                    baseDropPen = (depth >= 1) ? 320 : 450
                                                } else {
                                                    baseDropPen = 370
                                                }
                                            } else {
                                                baseDropPen = 340
                                            }
                                            let totalDropPen = spanPen + baseDropPen
                                            guard totalDropPen <= maxAllowedSpanPen else { continue }

                                            let dropCacheKey = (UInt64(nextNode) << 26) | UInt64(packedRime)
                                            let droppedEdges: [MmapLexicon.DroppedInitialEdgeHit]
                                            if let cachedEdges = lookupCache.droppedInitialCache[dropCacheKey] {
                                                droppedEdges = cachedEdges
                                            } else {
                                                let computedEdges = lexicon.matchDroppedInitialEdges(
                                                    from: nextNode,
                                                    packedRime: packedRime,
                                                    isHRime: v0IsH,
                                                    limit: 5
                                                )
                                                lookupCache.droppedInitialCache[dropCacheKey] = computedEdges
                                                droppedEdges = computedEdges
                                            }
                                            guard !droppedEdges.isEmpty else { continue }

                                            for edge in droppedEdges {
                                                if sharedNasalSID != 0 && edge.syllableID == sharedNasalSID {
                                                    continue
                                                }
                                                var edgeDropSyls: [String]? = nil
                                                if let topDropW = lexicon.topWordScore(at: edge.targetNode) {
                                                    if end2 > maxPosReached { maxPosReached = end2 }
                                                    let skipDropWords: Bool = {
                                                        guard let curBucket = spansByEnd[end2],
                                                              curBucket.count == perEndCap,
                                                              let worst = curBucket.last else {
                                                            return false
                                                        }
                                                        return (topDropW - totalDropPen) <= worst.scoreQ8
                                                    }()
                                                    if !skipDropWords {
                                                        let syls = getNewSyls() + [edge.canonical]
                                                        edgeDropSyls = syls
                                                        for w in lexicon.words(at: edge.targetNode, limit: 3) {
                                                            recordSpan(
                                                                WordSpan(
                                                                    start: start,
                                                                    end: end2,
                                                                    text: w.text,
                                                                    syllables: syls,
                                                                    scoreQ8: w.scoreQ8 - totalDropPen,
                                                                    penaltyQ8: totalDropPen,
                                                                    isUserPhrase: false,
                                                                    hasKeySubstitution: combinedHasKeySub,
                                                                    keySubstitutionCount: combinedKeySubCount
                                                                )
                                                            )
                                                        }
                                                    }
                                                }
                                                if end2 < n && depth < 3 {
                                                    let syls = edgeDropSyls ?? (getNewSyls() + [edge.canonical])
                                                    nextFrontier.append(
                                                        WalkState(
                                                            pos: end2,
                                                            trieNode: edge.targetNode,
                                                            syllables: syls,
                                                            penaltyQ8: totalDropPen,
                                                            initialCount: state.initialCount,
                                                            subtreeScore: edge.subtreeScore,
                                                            hasKeySubstitution: combinedHasKeySub,
                                                            keySubstitutionCount: combinedKeySubCount,
                                                            hasSoftClipped: combinedSoftClip
                                                        )
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            let nextUserPrefixMatched = checkUserPhrases
                                && state.initialCount == 0
                                && !combinedSoftClip
                                && !arc.isPrefixCompletion
                                && spanPen <= 85
                                && userSnapshot.hasStrictSyllablePrefix(getNewSyls().joined(separator: " "))
                            if arc.end < n && (nextNode != virtualUserTrieNode || nextUserPrefixMatched) {
                                if depth < 7 {
                                    let frontierPen = isCoherentMultiSylChunk ? (spanPen + 360) : spanPen
                                    let subScore = nextNode == virtualUserTrieNode ? -2400 : lexicon.maxSubtreeScore(at: nextNode)
                                    nextFrontier.append(
                                        WalkState(
                                            pos: arc.end,
                                            trieNode: nextNode,
                                            syllables: getNewSyls(),
                                            penaltyQ8: frontierPen,
                                            initialCount: state.initialCount,
                                            subtreeScore: subScore,
                                            hasKeySubstitution: combinedHasKeySub,
                                            keySubstitutionCount: combinedKeySubCount,
                                            hasSoftClipped: combinedSoftClip,
                                            userPrefixMatched: nextUserPrefixMatched
                                        )
                                    )
                                } else if arc.end > maxPosReached {
                                    maxPosReached = arc.end
                                }
                            }
                        } else if arc.isInitialOnly
                            && state.initialCount <= (depth >= 2 ? 1 : 0)
                            && {
                                if depth >= 1 { deps.dependsOnNMask |= SpanRegimeBit.nGE6 }
                                return state.penaltyQ8 <= ((n >= 6 && depth >= 1) ? 620 : ((arc.end == n && depth >= 2) ? 490 : ((arc.end == n && depth == 1) ? 300 : 180)))
                            }()
                            && depth < 4 {
                            let newSyls = state.syllables + [arc.canonical]
                            let pureJpState = !state.hasKeySubstitution && !state.hasSoftClipped
                            if depth == 0 {
                                if arc.end == n {
                                    // Clause-final single-initial word/particle (`wolaissb -> 吧`, `keyim -> 吗`, `zmya -> 啊`, `jintianx -> 想/先`):
                                    // `coreInitialMonosyllables` already precomputes the top `rootEdgesByPrefix` + spoken particles in RAM!
                                    deps.dependsOnWholeClean = true
                                    deps.maxSpanEnd = n
                                    deps.dependsOnNMask |= SpanRegimeBit.nGE6 | SpanRegimeBit.nGE15
                                    if !arc.hasKeySubstitution {
                                        if let coreList = lexicon.coreInitialMonosyllables[arc.canonical] {
                                            let cap = (wholeInputClean && n >= 6) ? 4 : (n > 14 ? 4 : 6)
                                            for item in coreList.prefix(cap) {
                                                let bosCliticPen = (start == 0 && (item.text == "吧" || item.text == "吗" || item.text == "呢" || item.text == "的" || item.text == "了" || item.text == "啊" || item.text == "啦" || item.text == "么")) ? 650 : 0
                                                recordSpan(
                                                    WordSpan(
                                                        start: start,
                                                        end: arc.end,
                                                        text: item.text,
                                                        syllables: newSyls,
                                                        scoreQ8: item.scoreQ8 - newPen - bosCliticPen,
                                                        penaltyQ8: newPen + bosCliticPen,
                                                        isUserPhrase: false,
                                                        isJianpinSpan: true
                                                    )
                                                )
                                            }
                                        } else {
                                            for edge in lexicon.stepByInitialPrefix(from: 0, prefix: arc.canonical, limit: 3) {
                                                for w in lexicon.words(at: edge.targetNode, limit: 1) {
                                                    recordSpan(
                                                        WordSpan(
                                                            start: start,
                                                            end: arc.end,
                                                            text: w.text,
                                                            syllables: newSyls,
                                                            scoreQ8: w.scoreQ8 - newPen,
                                                            penaltyQ8: newPen,
                                                            isUserPhrase: false,
                                                            isJianpinSpan: true
                                                        )
                                                    )
                                                }
                                            }
                                        }
                                    } else if !(wholeInputClean && n >= 6) && arc.penaltyQ8 <= 480,
                                              let coreList = lexicon.coreInitialMonosyllables[arc.canonical] {
                                        for item in coreList.prefix(2) {
                                            recordSpan(
                                                WordSpan(
                                                    start: start,
                                                    end: arc.end,
                                                    text: item.text,
                                                    syllables: newSyls,
                                                    scoreQ8: item.scoreQ8 - newPen,
                                                    penaltyQ8: newPen,
                                                    isUserPhrase: false,
                                                    hasKeySubstitution: true,
                                                    keySubstitutionCount: arc.keySubstitutionCount,
                                                    isJianpinSpan: false
                                                )
                                            )
                                        }
                                    }
                                } else {
                                    if arc.end > deps.maxArcQueryPos { deps.maxArcQueryPos = arc.end }
                                    if arc.end + 1 > deps.maxRawReadEnd { deps.maxRawReadEnd = arc.end + 1 }
                                    let hasExplicitSep = arc.end > start && samples[arc.end - 1].primaryChar == "'"
                                    let nextB = lowerASCII[arc.end]
                                    let nextIsVowel = (nextB == 0x61 || nextB == 0x65 || nextB == 0x69 || nextB == 0x6F || nextB == 0x75 || nextB == 0x76)
                                    let splitsDigraph = !hasExplicitSep
                                        && arc.canonical.utf8.count == 1
                                        && nextB == 0x68
                                        && (lowerASCII[start] == 0x7A || lowerASCII[start] == 0x63 || lowerASCII[start] == 0x73)
                                    let isPrecedingCoda = (isStartPrecedingCoda || isStartSecondOfDigraph) && arc.canonical.utf8.count == 1
                                    // Compositional mid-sentence / clause-initial 1-initial common verb/pronoun/particle
                                    // (`niqkkb` -> `去`, `suanlb` / `chflm` -> `了`, `dyxb` -> `等`, `wkkb` -> `我`):
                                    // Never split nasal/rhotic syllable codas (`kan`, `men`, `ming`, `shang`), and zero overhead on clean Quanpin!
                                    if !fastCleanSentenceOnly && !urgentSpanMode && !arc.hasKeySubstitution && !hasPrimaryCleanFullArcAtPos && !splitsDigraph && !isPrecedingCoda && (hasExplicitSep || !nextIsVowel) {
                                        deps.dependsOnNMask |= SpanRegimeBit.nLE16
                                    }
                                    if !fastCleanSentenceOnly && !urgentSpanMode && !arc.hasKeySubstitution && n <= 16 && !hasPrimaryCleanFullArcAtPos && !splitsDigraph && !isPrecedingCoda && (hasExplicitSep || !nextIsVowel),
                                       let coreList = lexicon.coreInitialMonosyllables[arc.canonical] {
                                        for item in coreList.prefix(6) {
                                            let bosCliticPen = (start == 0 && (item.text == "吧" || item.text == "吗" || item.text == "呢" || item.text == "的" || item.text == "了" || item.text == "啊" || item.text == "啦" || item.text == "么")) ? 650 : 0
                                            recordSpan(
                                                WordSpan(
                                                    start: start,
                                                    end: arc.end,
                                                    text: item.text,
                                                    syllables: newSyls,
                                                    scoreQ8: item.scoreQ8 - newPen - bosCliticPen,
                                                    penaltyQ8: newPen + bosCliticPen,
                                                    isUserPhrase: false,
                                                    isJianpinSpan: true
                                                )
                                            )
                                        }
                                    }
                                    if let nextArcs = arcsByStart[arc.end] {
                                        // Leading Mixed Jianpin (`w'men` -> `我们`, `m'tian` -> `明天`, `zhge` -> `这个`, `shrf` -> `输入法`):
                                        // Exact 1-step lookahead guarantees `ming'tian` is NEVER truncated AND never splits
                                        // a single unbroken syllable (`z+he == zhe`, `zh+e == zhe`, `sh+ang == shang`, `b+ai == bai`)!
                                        let validNextFullSIDs = nextArcs
                                            .filter { nextArc in
                                                guard !nextArc.isInitialOnly && nextArc.syllableID > 0 && nextArc.penaltyQ8 <= 70 else { return false }
                                                if !hasExplicitSep && (nextArc.end - start) <= 6,
                                                   lexicon.canonicalSyllableIDASCII(lowerASCII[start..<nextArc.end]) != nil {
                                                    return false
                                                }
                                                return true
                                            }
                                            .map(\.syllableID)
                                        if !validNextFullSIDs.isEmpty {
                                            for edge in lexicon.rootInitialHits(prefix: arc.canonical) {
                                                if validNextFullSIDs.contains(where: { lexicon.step(from: edge.targetNode, syllableID: $0) != nil }) {
                                                    nextFrontier.append(
                                                        WalkState(
                                                            pos: arc.end,
                                                            trieNode: edge.targetNode,
                                                            syllables: newSyls,
                                                            penaltyQ8: newPen,
                                                            initialCount: 1,
                                                            subtreeScore: edge.subtreeScore
                                                        )
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                // Internal or trailing initial after full/noisy syllable(s) (`mei'y -> 没有`, `juais -> 快速`, `zenmb -> 怎么办`, `shurf -> 输入法`).
                                // Skip splitting an unbroken CV syllable (`kan + zh + e` when `zhe` is already an exact canonical syllable at `state.pos`).
                                if arc.end < n && arc.end + 1 > deps.maxRawReadEnd {
                                    deps.maxRawReadEnd = arc.end + 1
                                }
                                if arc.end < n && samples[arc.end - 1].primaryChar != "'" && hasPrimaryCleanFullArcAtPos {
                                    deps.dependsOnNMask |= SpanRegimeBit.nGE9
                                }
                                let nextB = arc.end < n ? lowerASCII[arc.end] : 0
                                let nextIsVowel = (nextB == 0x61 || nextB == 0x65 || nextB == 0x69 || nextB == 0x6F || nextB == 0x75 || nextB == 0x76)
                                let splitsUnbrokenCV = n >= 9
                                    && arc.end < n
                                    && samples[arc.end - 1].primaryChar != "'"
                                    && hasPrimaryCleanFullArcAtPos
                                    && (nextIsVowel || (arc.canonical.utf8.count == 1 && nextB == 0x68))
                                if !stateIsVirtualUser && !splitsUnbrokenCV {
                                    let edgeHits = lexicon.stepByInitialPrefix(
                                        from: state.trieNode,
                                        prefix: arc.canonical,
                                        limit: urgentSpanMode ? 4 : 8
                                    )
                                    for edge in edgeHits {
                                        for w in lexicon.words(at: edge.targetNode, limit: 3) {
                                            recordSpan(
                                                WordSpan(
                                                    start: start,
                                                    end: arc.end,
                                                    text: w.text,
                                                    syllables: newSyls,
                                                    scoreQ8: w.scoreQ8 - newPen,
                                                    penaltyQ8: newPen,
                                                    isUserPhrase: false,
                                                    hasKeySubstitution: state.hasKeySubstitution,
                                                    keySubstitutionCount: state.keySubstitutionCount,
                                                    isJianpinSpan: pureJpState
                                                )
                                            )
                                        }
                                        if depth < 3 && arc.end < n && !urgentSpanMode {
                                            nextFrontier.append(
                                                WalkState(
                                                    pos: arc.end,
                                                    trieNode: edge.targetNode,
                                                    syllables: newSyls,
                                                    penaltyQ8: newPen,
                                                    initialCount: state.initialCount + 1,
                                                    subtreeScore: edge.subtreeScore,
                                                    hasKeySubstitution: state.hasKeySubstitution,
                                                    keySubstitutionCount: state.keySubstitutionCount,
                                                    hasSoftClipped: state.hasSoftClipped
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Beam-prune `nextFrontier` at each syllable depth for sub-millisecond latency,
                // while strictly retaining exact zero-penalty full-syllable states (`sen` in `senlin`)!
                let depthBeamCap = urgentSpanMode ? 4 : (depth >= 3 ? 10 : 18)
                if nextFrontier.count > depthBeamCap {
                    nextFrontier.sort { a, b in
                        let aExact = (a.penaltyQ8 == 0 && a.initialCount == 0)
                        let bExact = (b.penaltyQ8 == 0 && b.initialCount == 0)
                        if aExact != bExact { return aExact && !bExact }
                        let sa = a.subtreeScore - a.penaltyQ8
                        let sb = b.subtreeScore - b.penaltyQ8
                        if sa != sb { return sa > sb }
                        return a.trieNode < b.trieNode
                    }
                    nextFrontier.removeSubrange(depthBeamCap..<nextFrontier.count)
                }
                for st in nextFrontier where st.pos > maxPosReached {
                    maxPosReached = st.pos
                }
                frontier = nextFrontier
                if frontier.isEmpty { break }
            }
            }

            var flatSpans: [WordSpan] = []
            for endKey in spansByEnd.keys.sorted() {
                reachable[endKey] = true
                if let bucket = spansByEnd[endKey] {
                    flatSpans.append(contentsOf: bucket)
                }
            }
            spansByStart[start] = flatSpans
            maxPosByStart[start] = maxPosReached
            deps.maxSpanEnd = max(deps.maxSpanEnd, maxPosReached)
            if maxPosReached >= n {
                deps.maxRawReadEnd = Int.max
                deps.maxSpanEnd = n
            } else if maxPosReached > deps.maxRawReadEnd {
                deps.maxRawReadEnd = maxPosReached
            }
            spanDepsByStart[start] = deps
        }

        return (spansByStart, maxPosByStart, spanDepsByStart, reusedSpanStarts, contiguousReusedStart, isPureEnglishCompound)
    }

    // MARK: - Step 4: Top-K Bigram Viterbi Whole-Sentence Dynamic Programming

    private func solveViterbiTopPaths(
        samples: [TouchSample],
        lowerChars: [Character],
        lowerASCII: [UInt8],
        n: Int,
        firstStart: Int = 0,
        spansByStart: [Int: [WordSpan]],
        maxPosByStart: [Int: Int] = [:],
        userSnapshot: UserLexiconStore.DecodeSnapshot,
        precedingContext: String? = nil,
        topicMemory: NeuralSentenceScorer.Vec32 = .zero,
        wholeInputClean: Bool = false,
        reusableDPBound: Int = 0,
        fastCleanSentenceOnly: Bool = false,
        isCancelled: () -> Bool = { false },
        urgentNow: Bool = false
    ) -> [WordSpan] {
        guard firstStart < n else {
            cachedDP = []
            return []
        }

        let beamK: Int
        if urgentNow && n >= 12 {
            beamK = 2
        } else if n >= 10 && urgentNow {
            beamK = 3
        } else if fastCleanSentenceOnly {
            beamK = 5
        } else {
            beamK = 10
        }
        let contextKey = precedingContext ?? ""
        let seedWord = Self.extractTrailingChineseSuffix(from: contextKey, maxChars: 3)

        let activeDPBound: Int
        if firstStart == 0
            && reusableDPBound > 0
            && cachedDPBeamK == beamK
            && cachedDPSeedWord == seedWord
            && cachedDPPrecedingContext == contextKey
            && cachedDPTopicMemory == topicMemory
            && cachedDP.count > reusableDPBound {
            activeDPBound = reusableDPBound
        } else {
            activeDPBound = 0
        }

        var dp = Array<[DPNode]>(repeating: [], count: n + 1)
        if activeDPBound > 0 {
            for p in 0...activeDPBound {
                dp[p] = cachedDP[p]
            }
        } else {
            let initHidden: NeuralSentenceScorer.Vec32
            if let prevCtx = cachedInitHiddenContext, prevCtx == contextKey {
                initHidden = cachedInitHiddenVec
            } else {
                let computed = lexicon.neuralLM.initialHiddenState(precedingContext: precedingContext)
                cachedInitHiddenContext = contextKey
                cachedInitHiddenVec = computed
                initHidden = computed
            }
            dp[firstStart] = [
                DPNode(
                    scoreQ8: 0,
                    penaltyQ8: 0,
                    lastSpanPenaltyQ8: 0,
                    neuralScoreQ8: 0,
                    textFingerprint: 0,
                    text: "",
                    prevWord: "",
                    lastWord: seedWord,
                    syllables: [],
                    singleCharRun: 0,
                    maxOneCharRun: 0,
                    hasKeySubstitution: false,
                    keySubstitutionCount: 0,
                    isPureCleanOrJianpin: true,
                    hasAccidentalSingleton: false,
                    hidden: initHidden,
                    wordCharEnds: 0,
                    wordSylEnds: 0
                )
            ]
        }

        // Reserve one of the existing ten positions for the best unassisted path.
        // Cached prefixes carry the same invariant through incremental edits.
        struct BeamLimits {
            var minimumScore = Int.min
            var bestBase = Int.min
            var cleanCount = 0
        }
        // Every destination we extend is beyond the reused read-only prefix.
        var limitsByEnd = [BeamLimits](repeating: BeamLimits(), count: n + 1)
        let wordBoundaryPenalty = 210
        if lookupCache.rawAssocMapCache.count > 2048 {
            lookupCache.rawAssocMapCache.removeAll(keepingCapacity: true)
        }
        if lookupCache.assocMapCache.count > 2048 {
            lookupCache.assocMapCache.removeAll(keepingCapacity: true)
            lookupCache.assocFilterCache.removeAll(keepingCapacity: true)
        }

        if lookupCache.assocFilterCache.count > 2048 { lookupCache.assocFilterCache.removeAll(keepingCapacity: true) }
        func associationFilter(_ map: [String: Int], for word: String) -> UInt64 {
            if let cached = lookupCache.assocFilterCache[word] { return cached }
            var bits: UInt64 = 0
            for key in map.keys {
                guard let fp = HanFingerprint(key) else { bits = .max; break }
                bits |= fp.filterBit
            }
            lookupCache.assocFilterCache[word] = bits
            return bits
        }

        @inline(__always)
        func rawAssocMap(for word: String) -> [String: Int] {
            if let cached = lookupCache.rawAssocMapCache[word] { return cached }
            let loaded = lexicon.cachedAssociationBonusMap(after: word)
            lookupCache.rawAssocMapCache[word] = loaded
            return loaded
        }

        func assocMap(for word: String) -> [String: Int] {
            if word.isEmpty { return [:] }
            if word.count == 1 { return rawAssocMap(for: word) }
            if let cached = lookupCache.assocMapCache[word] { return cached }
            var loaded = rawAssocMap(for: word)
            let tail2 = String(word.suffix(2))
            if tail2 != word {
                let m2 = rawAssocMap(for: tail2)
                for (k, v) in m2 {
                    let inherited = (v * 85) / 100
                    if inherited > (loaded[k] ?? 0) {
                        loaded[k] = inherited
                    }
                }
            }
            let tail1 = String(word.suffix(1))
            // Mozc POS-inspired suffix backoff guard:
            // When `tail1 == "到"`, distinguish true arrival verbs (`刚到`, `回到`, `来到`, `赶到`) from bound
            // resultative complements (`感到`, `看到`, `听到`, `想到`, `找到`, `收到`, `达到`, `得到`, `放到`),
            // preventing resultative verbs (`我感到`) from inheriting standalone `到`'s spatial location associations (`地下`, `门口`)!
            let allowTail1Backoff = (tail1 != "到") || Self.arrivalVerbCompounds.contains(word) || Self.arrivalVerbCompounds.contains(tail2)
            if allowTail1Backoff {
                let m1 = rawAssocMap(for: tail1)
                for (k, v) in m1 {
                    let inherited = (v * 75) / 100
                    if inherited > (loaded[k] ?? 0) {
                        loaded[k] = inherited
                    }
                }
            }
            lookupCache.assocMapCache[word] = loaded
            return loaded
        }

        @inline(__always)
        func wordTrait(for txt: String) -> WordStaticTrait {
            if let hit = lookupCache.wordTraitCache[txt] { return hit }
            let uCount = txt.utf8.count
            let oneCh = (uCount == 3 && txt.unicodeScalars.count == 1)
            var flg: UInt32 = 0
            var extraCap = 0
            let firstChar = txt.first
            if let fc = firstChar, Self.actionVerbLeadingChars.contains(fc) {
                flg |= (1 << 14)
            }
            if oneCh {
                extraCap += 800
                if Self.sentenceFinalModalParticles.contains(txt) { flg |= (1 << 0) }
                if txt == "的" || txt == "了" { flg |= (1 << 1) }
                if txt == "了" || txt == "的" || txt == "着" || txt == "过" { flg |= (1 << 2) }
                if Self.gradableAdjectiveMonosyllables.contains(txt) { flg |= (1 << 3) }
                if Self.chainableNextMonosyllables.contains(txt) { flg |= (1 << 4) }
                if Self.pronounMonosyllables.contains(txt) { flg |= (1 << 5) }
                if Self.productiveDerivationalSuffixes.contains(txt) { flg |= (1 << 6) }
                if txt == "去" || txt == "来" { flg |= (1 << 7) }
                if txt == "区" { flg |= (1 << 8) }
                if txt == "和" || txt == "与" || txt == "跟" || txt == "同" || txt == "了" || txt == "着" { flg |= (1 << 9) }
            } else if uCount >= 6 {
                if uCount == 6 {
                    extraCap += 260
                    let endsLe = txt.hasSuffix("了")
                    let endsDe = !endsLe && txt.hasSuffix("的")
                    if (endsLe || endsDe), let fc = firstChar {
                        if Self.gradableAdjectiveMonosyllables.contains(String(fc)) {
                            flg |= (1 << 10)
                        } else if endsLe && (flg & (1 << 14)) != 0 {
                            flg |= (1 << 11)
                        }
                    }
                    if let fc = firstChar, Self.stutterAdverbPrefixes.contains(fc) {
                        flg |= (1 << 12)
                    }
                    if txt == "一个" || txt == "一下" || txt == "一点" || txt == "一些" || txt == "一种" || txt == "一会" {
                        flg |= (1 << 13)
                    }
                }
                if Self.activityVerbTargets.contains(txt) {
                    flg |= (1 << 15)
                    extraCap += 720
                }
                if Self.destinationCityTargets.contains(txt) {
                    flg |= (1 << 16)
                    extraCap += 460
                }
                if Self.tentativeReduplicatedVerbs.contains(txt) {
                    flg |= (1 << 17)
                    extraCap += 360
                }
                if Self.clockHourTargets.contains(txt)
                    || Self.clauseCohesionTargets.contains(txt)
                    || txt == "喝吗"
                    || txt == "喝吧"
                    || txt.hasPrefix("新版")
                    || txt.hasPrefix("太")
                    || txt.hasPrefix("很") {
                    extraCap += 640
                }
            }

            var cf: UInt32 = 0
            if !txt.isEmpty {
                if oneCh {
                    if Self.chainablePrefixMonosyllables.contains(txt) { cf |= (1 << 0) }
                    if (flg & (1 << 3)) != 0 { cf |= (1 << 1) | (1 << 3) }
                    if Self.degreeAdverbMonosyllables.contains(txt) { cf |= (1 << 2) }
                    if (flg & (1 << 5)) != 0 { cf |= (1 << 4) }
                    if Self.transitiveObjectPronounVerbs.contains(txt) { cf |= (1 << 5) }
                    if Self.completionActionVerbs.contains(txt) { cf |= (1 << 7) }
                    if (flg & (1 << 0)) != 0 { cf |= (1 << 8) }
                } else {
                    if uCount == 6,
                       firstChar.map({ Self.degreeAdverbMonosyllables.contains(String($0)) }) == true,
                       txt.last.map({ Self.gradableAdjectiveMonosyllables.contains(String($0)) }) == true {
                        cf |= (1 << 3)
                    }
                    if txt.hasSuffix("这么") || txt.hasSuffix("那么") || txt == "有点" || txt == "有点儿" || txt == "非常" || txt == "特别" || txt == "十分" || txt == "比较" {
                        cf |= (1 << 2)
                    }
                    if let lastCh = txt.last.map(String.init), Self.sentenceFinalModalParticles.contains(lastCh) {
                        if !(lastCh == "吧" && Self.nounVenueEndingInBa.contains(txt)) && !(lastCh == "呢" && txt == "毛呢") {
                            cf |= (1 << 8)
                        }
                    }
                    if Self.multiCharPronouns.contains(txt) { cf |= (1 << 13) }
                    if uCount == 6 && Self.pronounCopulas.contains(txt) { cf |= (1 << 14) }
                    if uCount >= 6 && txt.count >= 2 { cf |= (1 << 20) }
                }
                if txt == "在" || txt.hasSuffix("在") { cf |= (1 << 6) }
                if txt == "把" || txt == "去把" || (txt.hasSuffix("把") && !Self.nounHandlesEndingInBa.contains(txt)) { cf |= (1 << 9) }
                if txt == "把这" || txt == "把那" || txt == "把这个" || txt == "把那个" { cf |= (1 << 10) }
                if txt == "去" || txt == "来" || Self.motionActivityVerbs.contains(txt) { cf |= (1 << 11) }
                if Self.purposiveTentativePrefixes.contains(txt) { cf |= (1 << 12) }
                let isTod = Self.timeOfDayPrefixes.contains(txt)
                if isTod { cf |= (1 << 15) }
                if isTod || Self.farewellTimePrefixes.contains(txt) || txt.hasSuffix("会儿") || txt.hasSuffix("之后") || txt.hasSuffix("以后") || txt.hasSuffix("过后") { cf |= (1 << 16) }
                if Self.meetingClassifierPrefixes.contains(txt) { cf |= (1 << 17) }
                if txt == "先" || txt == "我先" || txt == "你先" || txt == "他先" { cf |= (1 << 18) }
                if txt.hasSuffix("会儿") || txt == "一会" || txt == "一下" || txt == "等一下" || txt == "稍后" || txt == "晚点" { cf |= (1 << 19) }
                if txt.hasPrefix("坐") { cf |= (1 << 21) }
                if txt == "到" || txt == "回" || txt.hasSuffix("去") || txt.hasSuffix("到") { cf |= (1 << 22) }
                if txt == "在家" || txt == "在公司" || txt == "在学校" || txt == "在店里" { cf |= (1 << 23) }
                if txt == "家" { cf |= (1 << 24) }
                if txt == "帮我" || txt == "帮你" || txt == "帮他" || txt == "帮她" || txt == "帮我们" { cf |= (1 << 25) }
                if Self.strandedComitativeLastWords.contains(txt) { cf |= (1 << 26) }
                if Self.isModalOrChildDrinkContext(txt) { cf |= (1 << 27) }
                if Self.isStrictModalAuxForDrink(txt) { cf |= (1 << 28) }
            }
            let built = WordStaticTrait(
                utf8Count: uCount,
                isOneChar: oneCh,
                fingerprint: HanFingerprint(txt),
                baseFlags: flg,
                extraCap: extraCap,
                curFlags: cf
            )
            lookupCache.wordTraitCache[txt] = built
            return built
        }

        let trailingTwoHorizAdjacent = (n >= 3) && spatialModel.areKeysHorizontallyAdjacentASCII(lowerASCII[n - 1], lowerASCII[n - 2])
        let trailingM = (n >= 3) && lowerASCII[n - 1] == 0x6D /* 'm' */

        for i in firstStart..<n {
            if ((fastCleanSentenceOnly && (i & 1) == 0) || (i & 3) == 0) && isCancelled() {
                return []
            }
            if i < activeDPBound, (maxPosByStart[i] ?? i) <= activeDPBound {
                continue
            }
            let curBeam = dp[i]
            guard !curBeam.isEmpty, let rawSpans = spansByStart[i], !rawSpans.isEmpty else { continue }

            // At firstStart, `spansByStart[firstStart]` holds up to 14 spans per `end` for candidate bar display;
            // keep 10..12 spans so spoken verbs (`叫` in `jiaode -> 叫的`) and contextual homophones (`吃` + `fan` -> `饭`) are never pruned!
            let perEndCap0 = seedWord.isEmpty ? 10 : 12
            let candidateSpans: [WordSpan]
            if i == firstStart {
                var countsByEnd: [Int: Int] = [:]
                var exactCountsByEnd: [Int: Int] = [:]
                candidateSpans = rawSpans.filter { sp in
                    let c = countsByEnd[sp.end, default: 0]
                    let ec = exactCountsByEnd[sp.end, default: 0]
                    if c < perEndCap0 || (sp.penaltyQ8 == 0 && ec < 4) {
                        countsByEnd[sp.end] = c + 1
                        if sp.penaltyQ8 == 0 {
                            exactCountsByEnd[sp.end] = ec + 1
                        }
                        return true
                    }
                    return false
                }
            } else {
                candidateSpans = rawSpans
            }
            let spans = (i < activeDPBound) ? candidateSpans.filter { $0.end > activeDPBound } : candidateSpans
            if spans.isEmpty { continue }

            var cleanSingleSylBestScoreByEnd: [Int: Int] = [:]
            var bestEffScoreByEnd: [Int: Int] = [:]
            for sp in spans {
                let eff = sp.scoreQ8
                if eff > (bestEffScoreByEnd[sp.end] ?? Int.min) {
                    bestEffScoreByEnd[sp.end] = eff
                }
                if sp.penaltyQ8 == 0 && sp.syllables.count == 1 {
                    let prev = cleanSingleSylBestScoreByEnd[sp.end] ?? Int.min
                    if sp.scoreQ8 > prev {
                        cleanSingleSylBestScoreByEnd[sp.end] = sp.scoreQ8
                    }
                }
            }

            // Lazily populate 32-dim SIMD neural records only for spans that survive optimistic beam pruning!
            var spNeuralRecords = Array<NeuralSentenceScorer.WordNeuralRecord?>(repeating: nil, count: spans.count)
            struct SpanMeta {
                let utf8Count: Int
                let isOneChar: Bool
                let hasCleanCommonSingleSyl: Bool
                let singleSylHijackPen: Int
                let spanScoreDeficit: Int
                let fingerprint: HanFingerprint?
                let startsWithAEO: Bool
                let maxPositiveExtraQ8: Int
                let flags: UInt32
                let hasCloseHomophoneCompetition: Bool
            }
            var hasCloseHomophone = [Bool](repeating: false, count: spans.count)
            if n >= 6 && spans.count >= 2 {
                var groupStart = 0
                while groupStart < spans.count {
                    let gEnd = spans[groupStart].end
                    var groupEnd = groupStart + 1
                    while groupEnd < spans.count && spans[groupEnd].end == gEnd {
                        groupEnd += 1
                    }
                    if groupEnd - groupStart >= 2 {
                        for a in groupStart..<(groupEnd - 1) {
                            let sa = spans[a]
                            guard !sa.isEnglishSpan && sa.syllables.count >= 2 else { continue }
                            for b in (a + 1)..<groupEnd {
                                let sb = spans[b]
                                if sa.scoreQ8 - sb.scoreQ8 >= 260 { break }
                                if !sb.isEnglishSpan
                                    && sb.syllables.count == sa.syllables.count
                                    && sb.text != sa.text
                                    && sb.syllables == sa.syllables {
                                    hasCloseHomophone[a] = true
                                    hasCloseHomophone[b] = true
                                }
                            }
                        }
                    }
                    groupStart = groupEnd
                }
            }
            var spanMetas: [SpanMeta] = []
            spanMetas.reserveCapacity(spans.count)
            for (spIdx, sp) in spans.enumerated() {
                let closeHomophone = hasCloseHomophone[spIdx]
                let trait = wordTrait(for: sp.text)
                let uCount = trait.utf8Count
                let oneCh = sp.isEnglishSpan ? false : trait.isOneChar
                let cleanSingle = sp.syllables.count == 1
                    && !sp.isEnglishSpan
                    && sp.penaltyQ8 >= 240
                    && (cleanSingleSylBestScoreByEnd[sp.end] ?? Int.min) >= -2550
                let hijackPen = cleanSingle ? (sp.penaltyQ8 >= 420 ? 240 : 120) : 0
                let aeo: Bool
                if !sp.isEnglishSpan, let b0 = sp.syllables.first?.utf8.first {
                    aeo = (b0 == 0x61 || b0 == 0x65 || b0 == 0x6F)
                } else {
                    aeo = false
                }
                let flg: UInt32
                let maxExtra: Int
                if sp.isEnglishSpan {
                    flg = 0
                    maxExtra = 0
                } else if sp.penaltyQ8 > 70 {
                    if sp.isJianpinSpan && !sp.hasKeySubstitution {
                        flg = trait.baseFlags & ((1 << 17) | 0x7FFF)
                        maxExtra = (sp.end == n && oneCh && (trait.baseFlags & 0x3) != 0) ? 1080 : (trait.extraCap + 600)
                    } else {
                        flg = trait.baseFlags & 0x7FFF
                        maxExtra = 0
                    }
                } else {
                    flg = trait.baseFlags
                    var cap = ((i == firstStart && sp.end == n && sp.syllables.count >= 2) ? 180 : 0) + trait.extraCap
                    if oneCh && i > firstStart && (flg & (1 << 6)) != 0 {
                        cap += max(240, -1180 - sp.scoreQ8)
                    }
                    maxExtra = cap
                }
                spanMetas.append(
                    SpanMeta(
                        utf8Count: uCount,
                        isOneChar: oneCh,
                        hasCleanCommonSingleSyl: cleanSingle,
                        singleSylHijackPen: hijackPen,
                        spanScoreDeficit: (bestEffScoreByEnd[sp.end] ?? sp.scoreQ8) - sp.scoreQ8,
                        fingerprint: trait.fingerprint,
                        startsWithAEO: aeo,
                        maxPositiveExtraQ8: maxExtra,
                        flags: flg,
                        hasCloseHomophoneCompetition: closeHomophone
                    )
                )
            }

            let bestCleanMultiCharScoreAtI: Int = {
                var best = Int.min
                for node in curBeam where node.penaltyQ8 == 0 && node.lastWord.utf8.count >= 6 {
                    if node.scoreQ8 > best { best = node.scoreQ8 }
                }
                return best
            }()
            let hasExplicitApostropheAtBoundary = (i > 0 && samples[i - 1].primaryChar == "'")
            // Many beam paths end in the same lexical word. Their lexical bigram bonus
            // is identical for every outgoing span, irrespective of the earlier hidden state.
            var bonusesByLastWord = [String: [Int]]()
            for cur in curBeam {
                let spanBonuses: [Int]
                if cur.lastWord.isEmpty {
                    spanBonuses = []
                } else if let cached = bonusesByLastWord[cur.lastWord] {
                    spanBonuses = cached
                } else {
                    let lexical = assocMap(for: cur.lastWord)
                    let personal = userSnapshot.bigramBonuses(after: cur.lastWord)
                    if lexical.isEmpty && personal == nil {
                        spanBonuses = []
                    } else {
                        let filter = associationFilter(lexical, for: cur.lastWord)
                        spanBonuses = spans.indices.map { j in
                            let span = spans[j]
                            let lex = (spanMetas[j].fingerprint.map { filter & $0.filterBit == 0 } ?? false)
                                ? 0 : (lexical[span.text] ?? 0)
                            return lex + (personal?[span.text] ?? 0)
                        }
                    }
                    bonusesByLastWord[cur.lastWord] = spanBonuses
                }
                let segCost = (i == firstStart) ? 0 : wordBoundaryPenalty
                let curTrait = cur.lastWord.isEmpty
                    ? WordStaticTrait(utf8Count: 0, isOneChar: false, fingerprint: nil, baseFlags: 0, extraCap: 0, curFlags: 0)
                    : wordTrait(for: cur.lastWord)
                let cf = curTrait.curFlags
                let curIsOneChar = curTrait.isOneChar
                let curIsMultiCharClean = ((cf & (1 << 20)) != 0 && cur.penaltyQ8 <= 70)
                let curInChainablePrefix = (cf & (1 << 0)) != 0
                let curInGradableAdj1 = (cf & (1 << 1)) != 0
                let curIsChainableOrGradable1 = curInChainablePrefix || curInGradableAdj1
                let curIsChainablePrefix = (i > firstStart && n >= 9 && curInChainablePrefix && cur.lastSpanPenaltyQ8 == 0)
                let curIsDegreeAdv1 = (cf & (1 << 2)) != 0
                let curIsGradableOrDegAdj = (cf & (1 << 3)) != 0
                let curIsPronoun1 = (cf & (1 << 4)) != 0
                let curIsTransitiveObjVerb1 = (cf & (1 << 5)) != 0 && !cur.prevWord.isEmpty
                let curIsKaishiShi = curIsOneChar && (cur.lastWord == "是" || cur.lastWord == "时" || cur.lastWord == "式") && cur.prevWord.hasSuffix("开始")
                let curIsQue = curIsOneChar && cur.lastWord == "却"
                let curEndsWithNasal = (i > firstStart && !hasExplicitApostropheAtBoundary)
                    ? (cur.syllables.last.map { $0.utf8.count >= 2 && ($0.hasSuffix("n") || $0.hasSuffix("ng")) } ?? false)
                    : false
                let curIsZai = (cf & (1 << 6)) != 0
                let curIsZaiBeforeShuoTime = (curIsZai && Self.futureTimePrefixesForZaiShuo.contains(cur.prevWord))
                let curIsHeDrinkContext = (curIsOneChar && cur.lastWord == "和"
                    && (Self.drinkModalAndTimePrefixes.contains(cur.prevWord) || cur.prevWord.hasSuffix("想") || cur.prevWord.hasSuffix("要") || cur.prevWord.hasSuffix("去")))
                let curIsZuo = (curIsOneChar && cur.lastWord == "做")
                let curIsYi = (curIsOneChar && cur.lastWord == "以")
                let curIsCompletionVerb = (cf & (1 << 7)) != 0
                let curIsTransitPrefix = ((cf & (1 << 21)) != 0 || (cur.prevWord == "坐" && !cur.lastWord.isEmpty && Self.vehicleAndSeatTargets.contains(cur.lastWord)))
                let curEndsWithModalParticle = (cf & (1 << 8)) != 0
                let curEndsWithBa = (cf & (1 << 9)) != 0
                let curEndsWithBaDet = (cf & (1 << 10)) != 0
                let curIsMotionVerb = (cf & (1 << 11)) != 0
                let curIsLocativeMotion = curIsMotionVerb || curIsZai || (cf & (1 << 22)) != 0
                let curIsPurposiveTentative = (cf & (1 << 12)) != 0
                let curIsMultiCharPronoun = (cf & (1 << 13)) != 0
                let curIsPronounCopula = ((cf & (1 << 14)) != 0)
                    || (cur.lastWord == "是" && Self.pronounMonosyllables.contains(cur.prevWord))
                let curIsStrandedComitative = (cf & (1 << 26)) != 0
                let curIsDrinkModalOrChild = (cf & (1 << 27)) != 0
                let curIsStrictDrinkModal = (cf & (1 << 28)) != 0
                let curNeedsSelectionalCheck = (curIsPronounCopula || curIsOneChar || curIsTransitPrefix || curEndsWithModalParticle || curEndsWithBa || curEndsWithBaDet || curIsMotionVerb || curIsPurposiveTentative || curIsMultiCharPronoun || curIsZai || curIsStrandedComitative)
                let curIsTimeOfDay = (cf & (1 << 15)) != 0
                let curIsFarewellTime = ((cf & (1 << 16)) != 0)
                    || cur.lastWord == "tomorrow"
                    || cur.lastWord == "tonight"
                    || cur.lastWord == "later"
                    || cur.lastWord == "Tomorrow"
                    || cur.lastWord == "Tonight"
                let curIsMeetingPrefix = (cf & (1 << 17)) != 0
                let curIsXianAdv = (cf & (1 << 18)) != 0
                let curIsReplyDelay = (cf & (1 << 19)) != 0
                let curEndsAtPlace = ((cf & (1 << 23)) != 0) || (((cf & (1 << 24)) != 0) && (cur.prevWord == "在" || cur.prevWord == "你在" || cur.prevWord == "不在"))
                let curIsBangPro = ((cf & (1 << 25)) != 0) || (curIsPronoun1 && cur.prevWord == "帮")

                let curLastRecord = (cur.lastWord.isEmpty || cur.lastWord.last?.isASCII == true)
                    ? NeuralSentenceScorer.WordNeuralRecord.empty
                    : neuralRecord(for: cur.lastWord)
                var lazyPredictor: NeuralSentenceScorer.StepPredictor? = nil
                @inline(__always)
                func getPredictor() -> NeuralSentenceScorer.StepPredictor {
                    if let p = lazyPredictor { return p }
                    let p = lexicon.neuralLM.prepareStepPredictor(
                        lastRecord: curLastRecord,
                        hidden: cur.hidden,
                        topicMemory: topicMemory
                    )
                    lazyPredictor = p
                    return p
                }
                let curIsDegreeFluency = curIsDegreeAdv1 || Self.degreeFluencyExtraWords.contains(cur.lastWord)
                let curCanZouBa = curIsXianAdv || curIsFarewellTime || Self.zouBaExtraPrefixes.contains(cur.lastWord)
                let curCanYiXia = Self.yiXiaPrefixes.contains(cur.lastWord)
                let curCanFollowModalLeM = !curEndsWithModalParticle && !curIsPronoun1 && !curIsMultiCharPronoun
                let curCanFollowModalJianpin = curCanFollowModalLeM && !curEndsWithBa && !curEndsWithBaDet
                let curIsHorizRolloverTail = (i == n - 1 && trailingTwoHorizAdjacent && cur.penaltyQ8 == 0)
                let curClauseSwitch: CurClauseSwitch = cur.lastWord.isEmpty ? .none : (Self.curClauseSwitchTable[cur.lastWord] ?? .none)
                let curHasSwitchClause = (curClauseSwitch != .none) || curEndsAtPlace || curIsBangPro
                let curHasHanFP = (curTrait.fingerprint != nil)

                for (spIdx, sp) in spans.enumerated() {
                    let meta = spanMetas[spIdx]
                    let rawBgBonus = spanBonuses.isEmpty ? 0 : spanBonuses[spIdx]

                    // Protect exact 0-penalty common 1-syllable words (`qingkuangne` -> `情况呢`, `keyima` -> `可以吗`)
                    // from being hijacked by high-frequency 1-syllable neighbor substitutions (`情况和`) or completions (`情况能`).
                    let hasCleanCommonSingleSyl = meta.hasCleanCommonSingleSyl
                    let bgBonus = hasCleanCommonSingleSyl ? (rawBgBonus / 4) : rawBgBonus
                    let combinedPen = cur.penaltyQ8 + sp.penaltyQ8
                    let isNoisyTransition = sp.penaltyQ8 > 70 || cur.lastSpanPenaltyQ8 > 70
                    let isTopSpanAtEnd = meta.spanScoreDeficit <= (isNoisyTransition ? 680 : 420)
                        || (curIsDrinkModalOrChild && sp.text == "喝吗")
                    let maxNeural = isTopSpanAtEnd && !cur.lastWord.isEmpty ? NeuralSentenceScorer.maxBonusQ8 : 0

                    // Ultra-fast mathematical upper-bound skip before evaluating syntactic/selectional rules:
                    // Whenever `combinedPen > 0` and `dp[sp.end]` already holds `beamK` candidates, `candScore` can NEVER
                    // exceed `cur.scoreQ8 + sp.scoreQ8 - segCost + bgBonus + meta.maxPositiveExtraQ8 + maxBonusQ8 - singleSylHijackPen`.
                    let limits = limitsByEnd[sp.end]
                    if (combinedPen > 0 || limits.cleanCount > 5 || (wholeInputClean && urgentNow && limits.cleanCount > 0)) && limits.minimumScore != Int.min {
                        let optimisticBase = cur.scoreQ8 + sp.scoreQ8 - segCost + bgBonus + meta.maxPositiveExtraQ8 - meta.singleSylHijackPen
                        let optimisticCeil = optimisticBase + maxNeural
                        if optimisticCeil <= limits.minimumScore
                            && optimisticBase - cur.neuralScoreQ8 <= limits.bestBase {
                            continue
                        }
                    }

                    let singleSylHijackPen = meta.singleSylHijackPen
                    let spIsOneChar = meta.isOneChar
                    let flg = meta.flags
                    let bothPureHan = curHasHanFP && (meta.fingerprint != nil)

                    // Anti-confetti, productive morphological suffix cohesion & Mandarin Maximum-Onset laws:
                    // 1) Discourage chaining unassociated 1-char + 1-char fragments (`吧 + 和`, `年 + 两 + 案`)
                    //    over genuine multi-character dictionary words (`拔河`, `黏连 + 感`).
                    // 2) Grant morphological cohesion bonus when a `>= 2`-char clean word is followed by a
                    //    productive 1-char derivational suffix (`感`, `性`, `度`, `化`, `率`, `力`, etc.).
                    // 3) Penalize cross-word nasal-coda + zero-initial vowel resyllabification (`liang + an` instead of `lian + gan`)
                    //    when the user did NOT type an explicit apostrophe separator `'`.
                    let isHorizRolloverTail = curIsHorizRolloverTail && sp.end == n
                    let isStrandedPrepBeforeFinalMa = curIsStrandedComitative
                        && sp.end == n
                        && Self.sentenceFinalInterrogativeOrMaTargets.contains(sp.text)
                    let isSentenceFinalModal = (flg & (1 << 0)) != 0
                        && sp.end == n
                        && (sp.penaltyQ8 == 0
                            || (sp.isJianpinSpan && !sp.hasKeySubstitution && sp.penaltyQ8 <= 490 && n >= 3 && !isHorizRolloverTail && !curIsPronoun1 && !curIsMultiCharPronoun && !curEndsWithBa && !curEndsWithBaDet))
                        && !curEndsWithModalParticle
                        && !isStrandedPrepBeforeFinalMa
                    let isSentenceFinalCliticDeLe = (flg & (1 << 1)) != 0
                        && sp.end == n
                        && sp.penaltyQ8 == 0
                        && curIsChainableOrGradable1
                        && cur.lastSpanPenaltyQ8 == 0
                        && !curEndsWithBa
                        && !curEndsWithModalParticle
                    let isDegreeGradableAdjPair = i > firstStart
                        && curIsDegreeAdv1
                        && cur.lastSpanPenaltyQ8 <= 490
                        && sp.penaltyQ8 == 0
                        && (flg & ((1 << 3) | (1 << 10))) != 0
                    let isGradableAdjClitic = i > firstStart
                        && cur.lastSpanPenaltyQ8 <= 490
                        && (flg & (1 << 2)) != 0
                        && sp.penaltyQ8 == 0
                        && curIsGradableOrDegAdj
                    let isGrammaticalMonosyllableChain = curIsChainablePrefix
                        && (flg & (1 << 4)) != 0
                        && sp.end < n
                        && sp.penaltyQ8 == 0
                        && !Self.fastHanEquals(cur.lastWord, sp.text, bothPureHan: bothPureHan)
                        && !curEndsWithBa
                        && !(curIsZai && (flg & (1 << 7)) != 0)
                        && !(curIsPronoun1 && (flg & (1 << 5)) != 0)
                    let isModalOrGrammaticalChain = isSentenceFinalModal
                        || isSentenceFinalCliticDeLe
                        || isDegreeGradableAdjPair
                        || isGradableAdjClitic
                        || isGrammaticalMonosyllableChain
                    let grammaticalChainBonus: Int
                    if isGrammaticalMonosyllableChain {
                        grammaticalChainBonus = (rawBgBonus == 0) ? 340 : 220
                    } else if isSentenceFinalModal {
                        grammaticalChainBonus = (rawBgBonus == 0) ? 220 : 120
                    } else if isSentenceFinalCliticDeLe {
                        grammaticalChainBonus = (rawBgBonus == 0) ? 160 : 80
                    } else if isDegreeGradableAdjPair || isGradableAdjClitic {
                        grammaticalChainBonus = (rawBgBonus == 0) ? 240 : 140
                    } else {
                        grammaticalChainBonus = 0
                    }
                    let oneCharChainPen: Int
                    if i > firstStart && curIsOneChar && spIsOneChar {
                        if isModalOrGrammaticalChain || rawBgBonus >= 400 {
                            oneCharChainPen = 0
                        } else {
                            let basePen = (rawBgBonus == 0) ? 460 : 220
                            let runEscalation = max(0, cur.singleCharRun - 1) * 360
                            oneCharChainPen = basePen + runEscalation
                        }
                    } else {
                        oneCharChainPen = 0
                    }
                    let morphSuffixBonus = (i > firstStart && curIsMultiCharClean
                        && !curIsMultiCharPronoun
                        && !Self.adverbialNoSuffixPrefixes.contains(cur.lastWord)
                        && (flg & (1 << 6)) != 0 && sp.penaltyQ8 == 0)
                        ? max(240, -1180 - sp.scoreQ8)
                        : 0
                    let resyllabPen = (curEndsWithNasal && meta.startsWithAEO) ? 240 : 0

                    // Mozc-style POS Selectional & Aspectual Restrictions:
                    // 1) Modal-adverb inversion stutters (`*能只能`, `*会只会`, `*是只是`)
                    // 2) Progressive/preposition `在` vs. repetitive/sequential `再` (`*我在去看看`, `*我在想想`, `*你在试试`, `*明天在说`)
                    // 3) Comitative conjunction `和` vs. ingestion verb `喝` (`*你想和什么`, `*我想和奶茶`, `*早上和豆浆`)
                    // 4) General action `做` vs. transit/posture `坐` (`*我做地铁去`, `*我做高铁回来`, `*我做飞机去`)
                    // 5) Number `万` vs. resultative completion `完` (`*吃万了` vs `吃完了`)
                    // 6) Preposition `以` vs. perfective adverb `已` (`*以收到` vs `已收到`)
                    let stutterPen: Int
                    if !curNeedsSelectionalCheck {
                        stutterPen = 0
                    } else if isStrandedPrepBeforeFinalMa {
                        // Comitative prepositions/conjunctions (`和/跟/与`, `可以和`, `能和`) cannot terminate directly into sentence-final `吗/嘛/呢/吧/骂`
                        stutterPen = 950
                    } else if curEndsWithModalParticle && i < n {
                        // Modal particles (吧, 呢, 吗, etc.) mark clause termination; continuation words mid-sentence without punctuation are ungrammatical
                        stutterPen = 880
                    } else if (curEndsWithBa || curEndsWithBaDet) && (flg & (1 << 0)) != 0 {
                        // Disposal `把` / `把+Det` phrase requires a predicate VP and cannot terminate directly into a modal particle (`*把吧`, `*去把这吧`)
                        stutterPen = 880
                    } else if curEndsWithBa && (flg & ((1 << 9) | (1 << 4) | (1 << 14))) != 0 {
                        // Disposal preposition `把` requires an NP object; cannot directly precede conjunctions, particles, or action verbs (*把和, *把喝, *把喝吧, *把看)
                        stutterPen = 880
                    } else if curIsMotionVerb && !spIsOneChar && Self.personNameTargets.contains(sp.text) {
                        // Directional/motion verb cannot take a bare person name without locative (*去巴赫)
                        stutterPen = 720
                    } else if (flg & (1 << 8)) != 0 && curIsMultiCharPronoun {
                        // Pronoun cannot be followed by bare administrative noun "区" (*大家区, *我们区)
                        stutterPen = 620
                    } else if (curIsPronounCopula && Self.standaloneCopulaSpans.contains(sp.text))
                        || (curIsPronoun1 && sp.text == "是是") {
                        // Penalize the duplicate whether the lexicon splits 我是 + 是吧 or 我 + 是 + 是 + 吧.
                        stutterPen = 320
                    } else if curIsOneChar && (flg & (1 << 12)) != 0 && Self.fastHanHasSuffix(sp.text, cur.lastWord, bothPureHan: bothPureHan) {
                        stutterPen = 420
                    } else if curIsZai && (
                        (flg & (1 << 7)) != 0
                            || (!spIsOneChar && (sp.text.hasPrefix("去") || sp.text.hasPrefix("来") || Self.tentativeReduplicatedAndSequentialAfterZai.contains(sp.text)))
                            || (curIsZaiBeforeShuoTime && sp.text.hasPrefix("说"))
                    ) {
                        stutterPen = 620
                    } else if curIsHeDrinkContext && Self.beverageAndLiquidTargets.contains(sp.text) {
                        stutterPen = 680
                    } else if curIsZuo && Self.vehicleAndSeatTargets.contains(sp.text) {
                        stutterPen = 680
                    } else if curIsTransitPrefix && (flg & (1 << 8)) != 0 {
                        stutterPen = 620
                    } else if curIsCompletionVerb && sp.text.hasPrefix("万") {
                        stutterPen = 580
                    } else if curIsYi && Self.perfectiveTargetVerbs.contains(sp.text) {
                        stutterPen = 580
                    } else if curIsPurposiveTentative && !spIsOneChar && Self.abstractFactNounsAfterMotion.contains(sp.text) {
                        // Purposive motion/modal prefixes (`来`, `去`, `我来`, `我去`, `先`) cannot take abstract proposition nouns (`*我来事实`)
                        stutterPen = 520
                    } else if curIsKaishiShi
                        && (sp.text.hasPrefix("快") || sp.text.hasPrefix("自动") || sp.text.hasPrefix("试") || sp.text.hasPrefix("补")) {
                        // Aspectual verb `开始` + bare `是/时/式` cannot precede manner-adverbial VP (`*我开始是快速输入`, `*我开始时快速输入`)
                        stutterPen = 560
                    } else if curIsQue && (flg & (1 << 13)) != 0 {
                        // Monosyllabic adversative adverb `却` cannot directly govern numeral-classifier NP (`*咱们是不是却一个输入引擎` vs `缺一个`)
                        stutterPen = 580
                    } else if curIsDegreeAdv1 && (flg & (1 << 11)) != 0 {
                        // Degree adverbs (`很`, `更`, `太`, `真`, `最`) modify gradable adjectives/psych predicates (`更卡了`), never concrete action verb + `了` (`*更看了`, `*很拿了`)
                        stutterPen = 580
                    } else {
                        stutterPen = 0
                    }

                    let svoPronounClauseBonus = (isGrammaticalMonosyllableChain
                        && (flg & (1 << 5)) != 0
                        && curIsTransitiveObjVerb1) ? 460 : 0
                    let activityCohesionBonus = (curIsMotionVerb && (flg & (1 << 15)) != 0) ? 720 : 0
                    let locativeCityBonus = (curIsLocativeMotion && (flg & (1 << 16)) != 0) ? 460 : 0
                    let tentativeCohesionBonus = (curIsPurposiveTentative && (flg & (1 << 17)) != 0) ? 360 : 0
                    let fullWordBonus = (i == firstStart && sp.end == n && sp.syllables.count >= 2 && sp.penaltyQ8 == 0) ? 180 : 0
                    var clauseCohesionDelta = 0
                    if sp.text == "了得" && !Self.isLicensedLiaodePrefix(cur.lastWord) {
                        clauseCohesionDelta -= 460
                    }
                    if !cur.lastWord.isEmpty {
                        let spTxt = sp.text
                        let spClean = (sp.penaltyQ8 <= 70)
                        let spPureJianpin = sp.isJianpinSpan && !sp.hasKeySubstitution
                        let spCleanOrJianpin = spClean || spPureJianpin
                        if curIsDrinkModalOrChild && spClean
                            && ((spTxt == "喝吗" && sp.syllables == ["he", "ma"])
                                || (spTxt == "喝" && sp.syllables == ["he"] && sp.end + 2 == n && lowerASCII[sp.end] == 0x6D && lowerASCII[sp.end + 1] == 0x61)) {
                            clauseCohesionDelta += 520
                        } else if (curIsStrictDrinkModal || curIsDrinkModalOrChild) && sp.end == n && (spTxt == "盒马" || spTxt == "河马" || spTxt == "荷马") {
                            clauseCohesionDelta -= 780
                        }
                        if curIsTimeOfDay {
                            if spClean && Self.clockHourTargets.contains(spTxt) {
                                clauseCohesionDelta += 680
                            } else if spTxt == "酒店" {
                                clauseCohesionDelta -= 380
                            }
                        }
                        if curIsDegreeFluency {
                            if spTxt == "流畅" { clauseCohesionDelta += 480 }
                            else if spTxt == "流程" { clauseCohesionDelta -= 480 }
                        }
                        if curIsFarewellTime && sp.end == n && spCleanOrJianpin && sp.penaltyQ8 <= 490 {
                            if spTxt == "见" || spTxt == "见吧" { clauseCohesionDelta += 520 }
                            else if spTxt == "间" { clauseCohesionDelta -= 420 }
                        }
                        if curIsMeetingPrefix && spClean && spTxt == "会议" {
                            clauseCohesionDelta += 460
                        }
                        if curIsXianAdv && spClean && ((flg & (1 << 14)) != 0 || spTxt == "忙" || spTxt.hasPrefix("忙") || spTxt.hasPrefix("发") || spTxt.hasPrefix("回")) {
                            clauseCohesionDelta += 380
                        }
                        if curIsReplyDelay && spClean && (spTxt == "回你" || spTxt == "再回你" || spTxt == "到") {
                            clauseCohesionDelta += 420
                        }
                        if curCanZouBa && spPureJianpin && sp.end == n && spTxt == "走吧" {
                            clauseCohesionDelta += 480
                        }
                        if curCanYiXia && spPureJianpin && (spTxt == "一下" || spTxt == "一下吧") {
                            clauseCohesionDelta += 520
                        }
                        if curCanFollowModalLeM && spPureJianpin && sp.end == n && spTxt == "了吗" {
                            clauseCohesionDelta += 480
                        }
                        if curCanFollowModalJianpin && sp.end == n && n >= 3 && !isHorizRolloverTail
                            && sp.syllables.count == 1 && spPureJianpin && sp.penaltyQ8 >= 300 && sp.penaltyQ8 <= 490
                            && Self.modalTrailingParticles.contains(spTxt) {
                            let splitsCleanCodaTail: Bool = {
                                guard i > firstStart && sp.end - i == 1,
                                      samples[i - 1].primaryChar != "'",
                                      (lowerASCII[i] == 0x6E || lowerASCII[i] == 0x67) else { return false }
                                for k in max(firstStart, i - 5)..<i {
                                    if let cands = spansByStart[k],
                                       cands.contains(where: { $0.end == n && $0.penaltyQ8 <= 70 && !$0.isJianpinSpan && !$0.isEnglishSpan }) {
                                        return true
                                    }
                                }
                                return false
                            }()
                            if splitsCleanCodaTail {
                                clauseCohesionDelta -= 520
                            } else {
                                clauseCohesionDelta += (n >= 10) ? 860 : 580
                            }
                        } else if trailingM && curCanFollowModalLeM && sp.end == n - 1
                            && spPureJianpin && sp.syllables.count == 1 && spTxt == "了" {
                            clauseCohesionDelta += 420
                        }
                        if curHasSwitchClause {
                            switch curClauseSwitch {
                            case .ershi:
                                if spTxt.hasPrefix("分钟") || spTxt == "分" || spTxt == "点" || spTxt == "块" || spTxt == "个" || spTxt == "秒" {
                                    clauseCohesionDelta -= 680
                                }
                            case .woguo:
                                if spTxt.hasPrefix("一会") || spTxt == "一下" { clauseCohesionDelta -= 680 }
                            case .xianfa:
                                if spTxt.hasPrefix("给") || spTxt == "我" || spTxt == "你" { clauseCohesionDelta -= 680 }
                            case .shizai:
                                if spClean && (spTxt.hasPrefix("太") || spTxt.hasPrefix("真") || spTxt.hasPrefix("很") || spTxt == "不" || spTxt == "没") {
                                    clauseCohesionDelta += 580
                                }
                            case .shizai4:
                                if spTxt.hasPrefix("太") || spTxt.hasPrefix("真") { clauseCohesionDelta -= 460 }
                            case .zuo:
                                if spClean && spTxt == "极致" { clauseCohesionDelta += 380 }
                            case .jizhi:
                                if spClean && (spTxt == "的" || spTxt.hasPrefix("性能") || spTxt.hasPrefix("体验")) { clauseCohesionDelta += 340 }
                            case .shiji:
                                if spClean && spTxt == "体感" { clauseCohesionDelta += 440 }
                            case .haishihui:
                                if spClean && spTxt == "漏键" { clauseCohesionDelta += 440 }
                            case .loujian:
                                if spClean && spTxt == "卡顿" { clauseCohesionDelta += 360 }
                            case .zhineng:
                                if spTxt.hasPrefix("毫不") || spTxt.hasPrefix("不能") { clauseCohesionDelta -= 780 }
                            case .zhinengHao:
                                if spClean && (spTxt == "不能差" || spTxt == "不能") { clauseCohesionDelta += 520 }
                            case .hui:
                                if spTxt == "你" || spTxt == "我" || spTxt == "他" { clauseCohesionDelta -= 580 }
                            case .lushang:
                                if spClean && (spTxt == "一会儿" || spTxt == "一会") { clauseCohesionDelta += 360 }
                            case .shibi:
                                if spTxt == "是" || spTxt == "失衡" || spTxt.hasPrefix("是很") { clauseCohesionDelta -= 560 }
                            case .shibushi:
                                if spClean && (spTxt == "很" || spTxt == "太" || spTxt == "真" || spTxt == "更" || spTxt.hasPrefix("很") || spTxt.hasPrefix("太")) {
                                    clauseCohesionDelta += 380
                                }
                            case .wufa:
                                if spTxt.hasPrefix("太") { clauseCohesionDelta -= 680 }
                                else if spClean && spTxt == "替代" { clauseCohesionDelta += 420 }
                            case .tidai:
                                if spClean && spTxt == "原生" { clauseCohesionDelta += 420 }
                            case .fale:
                                if sp.penaltyQ8 <= 420 && spTxt.hasPrefix("新版") { clauseCohesionDelta += 620 }
                                else if spTxt.hasPrefix("下班") || spTxt.hasPrefix("戏班") || spTxt.hasPrefix("新办") || spTxt.hasPrefix("习惯") { clauseCohesionDelta -= 640 }
                            case .releaseVerb:
                                if sp.penaltyQ8 <= 420 && spTxt.hasPrefix("新版") { clauseCohesionDelta += 620 }
                            case .shoudao:
                                if spTxt == "乐" { clauseCohesionDelta -= 540 }
                                else if spClean && spTxt == "谢谢" { clauseCohesionDelta += 420 }
                            case .shoudaole:
                                if spClean && spTxt == "谢谢" { clauseCohesionDelta += 420 }
                            case .ding:
                                if spClean && (spTxt.hasPrefix("一张") || spTxt == "机票" || spTxt == "车票" || spTxt == "酒店" || spTxt == "票") {
                                    clauseCohesionDelta += 520
                                }
                            case .dingHomophone:
                                if spTxt == "一张机票" || spTxt == "机票" { clauseCohesionDelta -= 320 }
                            case .zaiHome:
                                if spClean && spTxt == "家里" { clauseCohesionDelta += 380 }
                            case .gang:
                                if spTxt == "材料" || spTxt.hasPrefix("材料") { clauseCohesionDelta -= 680 }
                            case .gangcai:
                                if sp.end == n && spTxt == "聊得" {
                                    clauseCohesionDelta -= 520
                                } else if spClean && (spTxt == "聊" || spTxt == "说" || spTxt == "谈" || spTxt == "讲" || spTxt == "问" || spTxt == "聊的" || spTxt == "说的") {
                                    clauseCohesionDelta += 360
                                }
                            case .none:
                                if curEndsAtPlace && sp.end == n && spTxt == "立马" {
                                    clauseCohesionDelta -= 680
                                } else if curIsBangPro {
                                    if spClean && (spTxt == "拿" || spTxt.hasPrefix("拿")) { clauseCohesionDelta += 520 }
                                    else if spTxt == "那" || spTxt.hasPrefix("那") { clauseCohesionDelta -= 520 }
                                }
                            }
                        }
                    }
                    let baseScore = cur.scoreQ8 + sp.scoreQ8 - segCost + bgBonus + morphSuffixBonus + grammaticalChainBonus + svoPronounClauseBonus + fullWordBonus + activityCohesionBonus + locativeCityBonus + tentativeCohesionBonus + clauseCohesionDelta - stutterPen - singleSylHijackPen - oneCharChainPen - resyllabPen

                    let candidateBase = baseScore - cur.neuralScoreQ8
                    let advancesBase = candidateBase > limits.bestBase

                    // Fast optimistic upper-bound pruning BEFORE evaluating the SIMD neural scorer (`max neuralBonus == +520`)
                    let needsCleanSlot = combinedPen == 0 && limits.cleanCount < 5
                    if baseScore + maxNeural <= limits.minimumScore && !advancesBase && !needsCleanSlot {
                        continue
                    }

                    // On-Device Neural Language Model (`LNLM v2` 32-dim gated recurrent SiLU MLP + bilinear semantic scorer):
                    // Evaluated on noisy/missed-key paths (`sp.penaltyQ8 > 70 || cur.lastSpanPenaltyQ8 > 70`), accidental singleton tokens
                    // (`亏, 素, 恩...`), and clean multi-syllable transitions without a lexical association, preserving calibrated 1-char homophone precision.
                    let spRec: NeuralSentenceScorer.WordNeuralRecord
                    if sp.isEnglishSpan {
                        spRec = .empty
                    } else if let cachedRec = spNeuralRecords[spIdx] {
                        spRec = cachedRec
                    } else {
                        let loadedRec = neuralRecord(for: sp.text)
                        spNeuralRecords[spIdx] = loadedRec
                        spRec = loadedRec
                    }
                    let isCleanMultiSylEval = n >= 8 && !(n >= 10 && urgentNow) && !curIsOneChar && sp.syllables.count >= 2 && bgBonus < 380
                    let isSinglePrefixHomophoneDisambig = !isNoisyTransition
                        && !isCleanMultiSylEval
                        && !spRec.isAccidentalSingleton
                        && !curLastRecord.isAccidentalSingleton
                        && n >= 6
                        && !(n >= 10 && urgentNow)
                        && bgBonus == 0
                        && sp.syllables.count >= 2
                        && meta.hasCloseHomophoneCompetition
                    let useNeural = !cur.lastWord.isEmpty
                        && !sp.isEnglishSpan
                        && !(cur.lastWord.last?.isASCII == true)
                        && (isNoisyTransition || isCleanMultiSylEval || isSinglePrefixHomophoneDisambig || spRec.isAccidentalSingleton || curLastRecord.isAccidentalSingleton)
                        && isTopSpanAtEnd
                    let neuralBonus: Int
                    if !useNeural {
                        if i == firstStart
                            && cur.lastWord.isEmpty
                            && topicMemory != .zero
                            && lexicon.neuralLM.isSemantic64Loaded
                            && !sp.isEnglishSpan
                            && sp.syllables.count >= 2
                            && sp.penaltyQ8 == 0
                            && isTopSpanAtEnd {
                            let topicQ8 = lexicon.neuralLM.scoreTopicGateBonusQ8(
                                hidden: cur.hidden,
                                topicMemory: topicMemory,
                                record: spRec
                            )
                            neuralBonus = max(-220, min(220, topicQ8))
                        } else {
                            neuralBonus = 0
                        }
                    } else {
                        let pred = getPredictor()
                        let rawNeural = lexicon.neuralLM.scorePreloadedCandidate(
                            predictor: pred,
                            record: spRec,
                            singleCharRun: isGrammaticalMonosyllableChain ? 0 : cur.singleCharRun,
                            isEndOfSentence: sp.end == n
                        )
                        if isSinglePrefixHomophoneDisambig {
                            neuralBonus = max(-220, min(220, rawNeural))
                        } else if hasCleanCommonSingleSyl && rawNeural > 0 {
                            neuralBonus = rawNeural / 4
                        } else if cur.lastSpanPenaltyQ8 > 70
                            && sp.penaltyQ8 == 0
                            && spIsOneChar
                            && bestCleanMultiCharScoreAtI > cur.scoreQ8
                            && !curLastRecord.isAccidentalSingleton
                            && rawNeural > 0 {
                            // Prevent asymmetric `isNoisyTransition` neural subsidy when `dp[i]` already has a higher-scoring
                            // 0-penalty multi-char leader (`打字` -2501 > `大致` -2565 / `单子` -2852) that skips `LNLM` on 1-char `sp` (`更`).
                            neuralBonus = 0
                        } else if (sp.hasKeySubstitution || (cur.hasKeySubstitution && (wholeInputClean || spIsOneChar)))
                            && !(sp.penaltyQ8 > 70 && !sp.hasKeySubstitution)
                            && !cur.hasAccidentalSingleton
                            && !spRec.isAccidentalSingleton
                            && rawNeural > 0 {
                            let localSpanClean: Bool
                            if n < 9 {
                                localSpanClean = wholeInputClean
                            } else if i + 8 < n {
                                let checkEnd = max(sp.end, min(n, i + 6))
                                let slice = lowerASCII[i..<checkEnd]
                                var alphaCount = 0
                                for b in slice where b >= 0x61 && b <= 0x7A { alphaCount += 1 }
                                localSpanClean = alphaCount >= 4 && lexicon.startsWithCoherentCleanUnitASCII(slice)
                            } else {
                                localSpanClean = wholeInputClean
                            }
                            neuralBonus = localSpanClean ? 0 : rawNeural
                        } else if isCleanMultiSylEval && bgBonus > 0 && rawNeural > 0 {
                            neuralBonus = max(0, rawNeural - bgBonus)
                        } else {
                            neuralBonus = rawNeural
                        }
                    }

                    let candScore = baseScore + neuralBonus
                    if candScore <= limits.minimumScore && !advancesBase && !needsCleanSlot {
                        continue
                    }

                    let combinedText: String
                    if cur.text.isEmpty {
                        combinedText = sp.text
                    } else if sp.isEnglishSpan || cur.lastWord.last?.isASCII == true {
                        combinedText = cur.text + " " + sp.text
                    } else {
                        combinedText = cur.text + sp.text
                    }
                    // Equal text can have different hidden states and word boundaries.
                    // Its strongest joint path supplies the continuation; the reserved
                    // position preserves a competing spelling.
                    var previousBestBase = limits.bestBase
                    var cleanCount = limits.cleanCount + (combinedPen == 0 ? 1 : 0)
                    let fingerprint: UInt64?
                    if let prefix = cur.textFingerprint, let tail = meta.fingerprint {
                        fingerprint = prefix &* tail.factor &+ tail.value
                    } else {
                        fingerprint = nil
                    }
                    let existingIdx = dp[sp.end].firstIndex { node in
                        if let fingerprint, let other = node.textFingerprint, fingerprint != other { return false }
                        return node.text == combinedText
                    }
                    if let existingIdx, candScore <= dp[sp.end][existingIdx].scoreQ8 { continue }
                    // Move the beam out before inserting. Copying the array at every
                    // accepted transition also copies the 32-lane state of each node.
                    var dest = [DPNode]()
                    swap(&dest, &dp[sp.end])
                    if let existingIdx {
                        let existing = dest.remove(at: existingIdx)
                        if existing.penaltyQ8 == 0 { cleanCount -= 1 }
                        if existing.baseScoreQ8 == previousBestBase && candidateBase < previousBestBase {
                            previousBestBase = dest.reduce(Int.min) { max($0, $1.baseScoreQ8) }
                        }
                    }

                    let nextSingleRun: Int
                    if spRec.charCount == 1 {
                        if isGrammaticalMonosyllableChain && cur.singleCharRun < 3 {
                            nextSingleRun = 1
                        } else {
                            nextSingleRun = cur.singleCharRun + 1
                        }
                    } else {
                        nextSingleRun = 0
                    }
                    let nextMaxRun = max(cur.maxOneCharRun, nextSingleRun)

                    // Advance the retained word using its actual predecessor, even when
                    // this transition did not need a score. Sibling order must not change
                    // the state we carry into the next word.
                    let nextHidden: NeuralSentenceScorer.Vec32
                    if sp.isEnglishSpan {
                        nextHidden = cur.hidden
                    } else {
                        let afterSpan: NeuralSentenceScorer.Vec32
                        if curLastRecord.charCount == 0 {
                            afterSpan = lexicon.neuralLM.advanceHiddenStateFromBOS(record: spRec, baseHidden: cur.hidden)
                        } else {
                            afterSpan = lexicon.neuralLM.advanceHiddenState(predictor: getPredictor(), record: spRec)
                        }
                        nextHidden = sp.lastWord == sp.text ? afterSpan : lexicon.neuralLM.advanceHiddenStateFromBOS(
                            record: neuralRecord(for: sp.lastWord), baseHidden: afterSpan
                        )
                    }

                    let nextWordCharEnds: UInt64
                    let nextWordSylEnds: UInt64
                    if !sp.isEnglishSpan
                        && !(cur.lastWord.last?.isASCII == true)
                        && (cur.text.isEmpty || cur.wordCharEnds != 0) {
                        let prevChars = cur.wordCharEnds == 0 ? 0 : (64 - cur.wordCharEnds.leadingZeroBitCount)
                        let nextChars = prevChars + sp.text.count
                        let nextSyls = cur.syllables.count + sp.syllables.count
                        if !sp.text.isEmpty && !sp.syllables.isEmpty && nextChars <= 64 && nextSyls <= 64 {
                            nextWordCharEnds = cur.wordCharEnds | (UInt64(1) << (nextChars - 1))
                            nextWordSylEnds = cur.wordSylEnds | (UInt64(1) << (nextSyls - 1))
                        } else {
                            nextWordCharEnds = 0
                            nextWordSylEnds = 0
                        }
                    } else {
                        nextWordCharEnds = 0
                        nextWordSylEnds = 0
                    }

                    let node = DPNode(
                        scoreQ8: candScore,
                        penaltyQ8: combinedPen,
                        lastSpanPenaltyQ8: sp.penaltyQ8,
                        neuralScoreQ8: cur.neuralScoreQ8 + neuralBonus,
                        textFingerprint: fingerprint,
                        text: combinedText,
                        prevWord: cur.lastWord,
                        lastWord: sp.lastWord,
                        syllables: cur.syllables + sp.syllables,
                        singleCharRun: nextSingleRun,
                        maxOneCharRun: nextMaxRun,
                        hasKeySubstitution: cur.hasKeySubstitution || sp.hasKeySubstitution,
                        keySubstitutionCount: cur.keySubstitutionCount &+ sp.keySubstitutionCount,
                        isPureCleanOrJianpin: cur.isPureCleanOrJianpin && (sp.penaltyQ8 <= 70 || (sp.isJianpinSpan && !sp.hasKeySubstitution)),
                        hasAccidentalSingleton: cur.hasAccidentalSingleton || spRec.isAccidentalSingleton,
                        hidden: nextHidden,
                        wordCharEnds: nextWordCharEnds,
                        wordSylEnds: nextWordSylEnds
                    )
                    let insIdx = dest.firstIndex(where: {
                        if candScore != $0.scoreQ8 { return candScore > $0.scoreQ8 }
                        if combinedPen != $0.penaltyQ8 { return combinedPen < $0.penaltyQ8 }
                        return combinedText < $0.text
                    }) ?? dest.count
                    dest.insert(node, at: insIdx)
                    let bestBase = max(previousBestBase, candidateBase)
                    if dest.count > beamK {
                        var drop = beamK
                        if dest[beamK].penaltyQ8 == 0 && cleanCount <= 5,
                           let noisy = dest.prefix(beamK).lastIndex(where: { $0.penaltyQ8 > 0 }) {
                            drop = noisy
                        }
                        if dest[drop].baseScoreQ8 == bestBase,
                           dest.firstIndex(where: { $0.baseScoreQ8 == bestBase }) == drop {
                            let sameClass = dest[drop].penaltyQ8 == 0
                            drop = dest.indices.last(where: {
                                $0 != drop && (dest[$0].penaltyQ8 == 0) == sameClass
                            }) ?? (drop == beamK ? beamK - 1 : beamK)
                        }
                        if dest.remove(at: drop).penaltyQ8 == 0 { cleanCount -= 1 }
                    }
                    limitsByEnd[sp.end] = BeamLimits(minimumScore: dest.count == beamK ? dest[beamK - 1].scoreQ8 : Int.min,
                                                     bestBase: bestBase, cleanCount: cleanCount)
                    dp[sp.end] = dest
                }
            }
        }

        if firstStart == 0 {
            cachedDP = dp
            cachedDPSeedWord = seedWord
            cachedDPPrecedingContext = contextKey
            cachedDPTopicMemory = topicMemory
            cachedDPBeamK = beamK
        } else {
            cachedDP = []
        }

        let fullNodes = dp[n].filter { !$0.text.isEmpty }
        if !fullNodes.isEmpty {
            var ordered = fullNodes
            var baseline = 0
            for i in ordered.indices.dropFirst() where ordered[i].baseScoreQ8 > ordered[baseline].baseScoreQ8 {
                baseline = i
            }
            if baseline != 0 {
                let base = ordered[baseline]
                let first = ordered[0]
                if !(base.hasKeySubstitution && !first.hasKeySubstitution),
                   base.keySubstitutionCount <= first.keySubstitutionCount,
                   !Self.permitsNeuralFlip(netLead: first.scoreQ8 - base.scoreQ8,
                                           extraPenalty: first.penaltyQ8 - base.penaltyQ8,
                                           addsSyllable: first.syllables.count > base.syllables.count) {
                    ordered.remove(at: baseline)
                    ordered.insert(base, at: 0)
                }
            }
            if let cleanIdx = ordered.firstIndex(where: { $0.penaltyQ8 <= 70 }), cleanIdx > 0 {
                let bestClean = ordered[cleanIdx]
                let topNoisy = ordered[0]
                let isNaturalCleanCollapseVictim = bestClean.penaltyQ8 == 0
                    && !bestClean.hasAccidentalSingleton
                    && bestClean.maxOneCharRun < 3
                    && topNoisy.penaltyQ8 > 70
                    && topNoisy.syllables.count < bestClean.syllables.count
                    && bestClean.syllables.count >= 2
                    && bestClean.scoreQ8 >= bestClean.syllables.count * -1320
                    && topNoisy.scoreQ8 < bestClean.scoreQ8 + 650
                let cleanGuardFloor = min(-4300, bestClean.syllables.count * -1980)
                let isTrailingPrefixHijack: Bool = {
                    guard bestClean.scoreQ8 >= cleanGuardFloor,
                          !bestClean.hasAccidentalSingleton,
                          bestClean.maxOneCharRun < 3,
                          topNoisy.penaltyQ8 > 70,
                          topNoisy.syllables.count == bestClean.syllables.count,
                          topNoisy.syllables.dropLast() == bestClean.syllables.dropLast(),
                          let sLast = topNoisy.syllables.last,
                          let cLast = bestClean.syllables.last else {
                        return false
                    }
                    if sLast == cLast && cLast.count == 1 {
                        return topNoisy.scoreQ8 < bestClean.scoreQ8 + 900
                    }
                    if sLast.count > cLast.count && sLast.hasPrefix(cLast) {
                        return topNoisy.scoreQ8 < bestClean.scoreQ8 + 500
                    }
                    return false
                }()
                let isTrailingPrefixCase: Bool = {
                    guard topNoisy.syllables.count == bestClean.syllables.count,
                          topNoisy.syllables.dropLast() == bestClean.syllables.dropLast(),
                          let sLast = topNoisy.syllables.last,
                          let cLast = bestClean.syllables.last else {
                        return false
                    }
                    return sLast.count > cLast.count && sLast.hasPrefix(cLast)
                }()
                let isLowMarginNoisyHijack: Bool
                let isCoherentCleanSentenceHijack: Bool
                if topNoisy.hasKeySubstitution {
                    // Spatial neighbor substitution on a clean buffer (`womenqubaheba -> *我们去那个吧`):
                    // Preserve full v0.5.8 clean-sentence barrier unless `bestClean` collided with accidental singletons (`*我开始是亏素输入`)
                    // or fractured into `>= 2` consecutive 1-char syllable soup (`hu+ri+fa -> 壶日发`) where `LNLM` strongly prefers `topNoisy`.
                    let cleanOk = bestClean.scoreQ8 >= cleanGuardFloor && !bestClean.hasAccidentalSingleton
                    let soupBrokenClean = (bestClean.maxOneCharRun >= 2 && topNoisy.neuralScoreQ8 >= bestClean.neuralScoreQ8 + 240)
                        || (bestClean.neuralScoreQ8 < 0 && topNoisy.neuralScoreQ8 >= bestClean.neuralScoreQ8 + 240)
                        || (bestClean.text.hasPrefix("势必") && topNoisy.text.hasPrefix("是不是"))
                    let requiredNoisyMargin = (wholeInputClean && !isTrailingPrefixCase && topNoisy.syllables.count < bestClean.syllables.count && bestClean.maxOneCharRun <= 1 && bestClean.scoreQ8 >= bestClean.syllables.count * -1500)
                        ? max(1450, topNoisy.penaltyQ8 + 1000)
                        : max(660, topNoisy.penaltyQ8 + 260)
                    isLowMarginNoisyHijack = cleanOk
                        && !soupBrokenClean
                        && bestClean.maxOneCharRun < 3
                        && (topNoisy.penaltyQ8 >= 450 || (wholeInputClean && !isTrailingPrefixCase && topNoisy.syllables.count < bestClean.syllables.count))
                        && !isTrailingPrefixCase
                        && topNoisy.scoreQ8 < bestClean.scoreQ8 + requiredNoisyMargin
                    isCoherentCleanSentenceHijack = wholeInputClean
                        && !soupBrokenClean
                        && bestClean.penaltyQ8 == 0
                        && bestClean.syllables.count >= 4
                        && bestClean.maxOneCharRun <= 2
                        && cleanOk
                        && topNoisy.penaltyQ8 > 70
                        && !isTrailingPrefixCase
                        && topNoisy.scoreQ8 < bestClean.scoreQ8 + max(1080, topNoisy.penaltyQ8 + 480)
                } else {
                    // 0-typo missed-key / soft-clip / dropped-initial recovery (`kuisushuru`, `xianai`, `woen`, `zhegeshurua`):
                    // `topNoisy.scoreQ8` ALREADY subtracted `topNoisy.penaltyQ8`; only guard coherent `maxOneCharRun <= 1` clean words (`黏连感`).
                    let isThreeCharDroppedInitialCompound = topNoisy.lastWord.count >= 3
                        && topNoisy.syllables.count == bestClean.syllables.count
                    let isTwoCharCleanBoundarySplit = wholeInputClean
                        && !isTrailingPrefixCase
                        && bestClean.penaltyQ8 == 0
                        && bestClean.syllables.count == 2
                        && n >= 4
                        && bestClean.scoreQ8 >= -3400
                        && topNoisy.penaltyQ8 >= 480
                    let isGenuineCoherentClean = bestClean.scoreQ8 >= cleanGuardFloor
                        && !bestClean.hasAccidentalSingleton
                        && (bestClean.maxOneCharRun <= 1 || isTwoCharCleanBoundarySplit)
                        && !isThreeCharDroppedInitialCompound
                    let isSoftClipCoherentCleanHijack = !isTrailingPrefixCase
                        && bestClean.scoreQ8 >= cleanGuardFloor
                        && Self.preservesCleanSentenceOverSoftClip(
                            cleanSyllables: bestClean.syllables,
                            cleanPenaltyQ8: bestClean.penaltyQ8,
                            cleanScoreQ8: bestClean.scoreQ8,
                            cleanLastWordCount: bestClean.lastWord.count,
                            cleanMaxOneCharRun: bestClean.maxOneCharRun,
                            noisySyllables: topNoisy.syllables,
                            noisyPenaltyQ8: topNoisy.penaltyQ8,
                            noisyScoreQ8: topNoisy.scoreQ8,
                            noisyHasKeySub: topNoisy.hasKeySubstitution,
                            wholeInputClean: wholeInputClean
                        )
                    isLowMarginNoisyHijack = (isGenuineCoherentClean
                        && topNoisy.penaltyQ8 >= 250
                        && !isTrailingPrefixCase
                        && topNoisy.scoreQ8 < bestClean.scoreQ8 + 280)
                        || isSoftClipCoherentCleanHijack
                    isCoherentCleanSentenceHijack = wholeInputClean
                        && bestClean.penaltyQ8 == 0
                        && bestClean.syllables.count >= 4
                        && isGenuineCoherentClean
                        && topNoisy.penaltyQ8 > 70
                        && !isTrailingPrefixCase
                        && topNoisy.scoreQ8 < bestClean.scoreQ8 + 280
                }
                if isNaturalCleanCollapseVictim || isTrailingPrefixHijack || isLowMarginNoisyHijack || isCoherentCleanSentenceHijack {
                    ordered.remove(at: cleanIdx)
                    ordered.insert(bestClean, at: 0)
                }
            } else if n >= 5,
                      let lowerIdx = ordered.firstIndex(where: {
                          !$0.hasKeySubstitution
                              && $0.maxOneCharRun <= 2
                              && !$0.hasAccidentalSingleton
                              && (
                                  ($0.isPureCleanOrJianpin && $0.penaltyQ8 <= 1100 && $0.penaltyQ8 + 260 <= ordered[0].penaltyQ8)
                                  || (ordered[0].hasKeySubstitution && ordered[0].penaltyQ8 >= 520 && $0.penaltyQ8 <= 480 && $0.penaltyQ8 + 140 <= ordered[0].penaltyQ8)
                              )
                      }),
                      lowerIdx > 0 {
                // Mixed-Jianpin sentence guard: when a sentence uses clean 0-substitution Quanpin+Jianpin (`kuai's'shu'ru`, `wo'lai's's'b`),
                // prevent an extra spatial neighbor substitution (`lai -> lao` `老三`/`老师`) on a clean prefix from hijacking the 0-substitution path,
                // UNLESS `topExtraNoisy` (`我来试试快速输入`) has far stronger `LNLM v2` coherence than `bestLower` (`*我开始是快速输入`)!
                let bestLower = ordered[lowerIdx]
                let topExtraNoisy = ordered[0]
                let extraPen = topExtraNoisy.penaltyQ8 - bestLower.penaltyQ8
                let floorQ8 = min(-4300, bestLower.syllables.count * -1980)
                let neuralPrefersNoisy = topExtraNoisy.neuralScoreQ8 >= bestLower.neuralScoreQ8 + 220
                if !neuralPrefersNoisy
                    && bestLower.syllables.count >= topExtraNoisy.syllables.count
                    && bestLower.scoreQ8 >= floorQ8
                    && topExtraNoisy.scoreQ8 < bestLower.scoreQ8 + extraPen + 380 {
                    ordered.remove(at: lowerIdx)
                    ordered.insert(bestLower, at: 0)
                }
            }

            // 4B. Post-DP lightweight whole-sentence bidirectional rerank (`LNBR` v1/v2 + `LNLM-v2`).
            // Strictly same-segmentation, zero-left-context sentence-start (`slot 0`, or `slot 1` after a 1-char lead)
            // reranker so early 2..3-char homophones disambiguated by right context recover cleanly without distorting
            // mid-sentence DP grammatical rules or segmentation lengths.
            if lexicon.neuralLM.isBackwardLoaded,
               !urgentNow,
               seedWord.isEmpty,
               let ref = ordered.first,
               ref.penaltyQ8 == 0,
               !ref.hasKeySubstitution,
               ref.syllables.count >= 3,
               ref.wordCharEnds != 0,
               ref.text.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value < 0xA000 }),
               ref.syllables.allSatisfy({ $0.utf8.count >= 2 || $0 == "a" || $0 == "e" || $0 == "o" }),
               let refSegs = Self.unpackSegmentedWords(
                   text: ref.text,
                   syllables: ref.syllables,
                   wordCharEnds: ref.wordCharEnds,
                   wordSylEnds: ref.wordSylEnds
               ),
               refSegs.count >= 2 {

                @inline(__always)
                func assocScore(_ prev: String, _ next: String) -> Int {
                    (assocMap(for: prev)[next] ?? 0) + (userSnapshot.bigramBonuses(after: prev)?[next] ?? 0)
                }

                struct SentenceStartChallenger {
                    let text: String
                    let words: [String]
                    let lexDelta: Int
                }

                func tryBidirectionalSlotRerank(slotIdx: Int) -> Bool {
                    guard slotIdx >= 0, slotIdx + 1 < refSegs.count else { return false }
                    let slot = refSegs[slotIdx]
                    guard (2...3).contains(slot.syls.count),
                          slot.word.count == slot.syls.count,
                          Self.curClauseSwitchTable[slot.word] == nil else {
                        return false
                    }
                    if slotIdx == 0 {
                        if spansByStart[firstStart]?.contains(where: { $0.text == slot.word && $0.isUserPhrase }) == true {
                            return false
                        }
                    } else {
                        let hasUserSlotPhrase = spansByStart.values.contains { list in
                            list.contains(where: { $0.text == slot.word && $0.isUserPhrase })
                        }
                        if hasUserSlotPhrase { return false }
                    }

                    let exactHits = lexicon.lookupExactWords(forSyllables: slot.syls, limit: 24)
                    guard let origHit = exactHits.first(where: { $0.text == slot.word }) else { return false }
                    let origLexScore = origHit.scoreQ8

                    let leftPrev: String? = slotIdx > 0 ? refSegs[slotIdx - 1].word : nil
                    let leftDiv = (leftPrev?.count == 1) ? 4 : 1
                    let oldLeftAssoc = leftPrev.map { assocScore($0, slot.word) / leftDiv } ?? 0

                    let rightNext = refSegs[slotIdx + 1].word
                    let rightDiv = (rightNext.count == 1) ? 4 : 1
                    let oldRightAssoc = assocScore(slot.word, rightNext) / rightDiv
                    let refWords = refSegs.map(\.word)

                    var challengers: [SentenceStartChallenger] = []
                    challengers.reserveCapacity(6)
                    var seenChallengers = Set<String>([ref.text])

                    for hit in exactHits {
                        guard challengers.count < 6 else { break }
                        guard hit.text != slot.word,
                              hit.text.count == slot.syls.count,
                              origLexScore - hit.scoreQ8 <= 1100 else {
                            continue
                        }
                        if hit.text == "只能" && (rightNext == "不能" || rightNext == "能" || rightNext == "可以") {
                            continue
                        }
                        var chWords = refWords
                        chWords[slotIdx] = hit.text
                        let chText = chWords.joined()
                        guard seenChallengers.insert(chText).inserted else { continue }
                        let newLeftAssoc = leftPrev.map { assocScore($0, hit.text) / leftDiv } ?? 0
                        let newRightAssoc = assocScore(hit.text, rightNext) / rightDiv
                        let lexDelta = (hit.scoreQ8 - origLexScore) + (newLeftAssoc - oldLeftAssoc) + (newRightAssoc - oldRightAssoc)
                        challengers.append(SentenceStartChallenger(text: chText, words: chWords, lexDelta: lexDelta))
                    }

                    guard !challengers.isEmpty else { return false }
                    let refFwdQ8 = lexicon.neuralLM.scoreWholeSentence(words: refWords, precedingContext: nil, topicMemory: topicMemory)
                    let refBwdQ8 = lexicon.neuralLM.scoreBackwardSentence(words: refWords)

                    let minBwdDelta = (slotIdx == 0) ? 140 : 240
                    let minFwdDelta = (slotIdx == 0) ? -80 : -220
                    var bestWinner: (cand: SentenceStartChallenger, fwdQ8: Int, bwdQ8: Int, netDelta: Int)? = nil
                    for ch in challengers {
                        let chFwdQ8 = lexicon.neuralLM.scoreWholeSentence(words: ch.words, precedingContext: nil, topicMemory: topicMemory)
                        let chBwdQ8 = lexicon.neuralLM.scoreBackwardSentence(words: ch.words)
                        let fwdDelta = chFwdQ8 - refFwdQ8
                        let bwdDelta = chBwdQ8 - refBwdQ8
                        let netDelta = ch.lexDelta + fwdDelta + bwdDelta
                        if bwdDelta >= minBwdDelta,
                           fwdDelta >= minFwdDelta,
                           netDelta >= 180 {
                            if bestWinner == nil || netDelta > bestWinner!.netDelta {
                                bestWinner = (ch, chFwdQ8, chBwdQ8, netDelta)
                            }
                        }
                    }

                    guard let winner = bestWinner else { return false }
                    let deltaLead = min(300, max(1, winner.netDelta))
                    let promoted = DPNode(
                        scoreQ8: ref.scoreQ8 + deltaLead,
                        penaltyQ8: 0,
                        lastSpanPenaltyQ8: 0,
                        neuralScoreQ8: winner.fwdQ8 + winner.bwdQ8,
                        textFingerprint: nil,
                        text: winner.cand.text,
                        prevWord: winner.cand.words.dropLast().last ?? "",
                        lastWord: winner.cand.words.last ?? "",
                        syllables: ref.syllables,
                        singleCharRun: 0,
                        maxOneCharRun: ref.maxOneCharRun,
                        hasKeySubstitution: false,
                        keySubstitutionCount: 0,
                        isPureCleanOrJianpin: true,
                        hasAccidentalSingleton: false,
                        hidden: ref.hidden,
                        wordCharEnds: ref.wordCharEnds,
                        wordSylEnds: ref.wordSylEnds
                    )
                    ordered.removeAll { $0.text == winner.cand.text }
                    ordered.insert(promoted, at: 0)
                    return true
                }

                if !tryBidirectionalSlotRerank(slotIdx: 0),
                   refSegs.count >= 3,
                   refSegs[0].word.count == 1,
                   refSegs[0].syls.count == 1 {
                    _ = tryBidirectionalSlotRerank(slotIdx: 1)
                }
            }
            return ordered.prefix(4).map { full in
                WordSpan(
                    start: 0,
                    end: n,
                    text: full.text,
                    syllables: full.syllables,
                    scoreQ8: full.scoreQ8,
                    penaltyQ8: full.penaltyQ8,
                    isUserPhrase: false,
                    lastWord: full.lastWord,
                    hasKeySubstitution: full.hasKeySubstitution,
                    keySubstitutionCount: full.keySubstitutionCount
                )
            }
        }

        // If the very end couldn't be reached completely, return the furthest valid prefix path
        for pos in stride(from: n - 1, through: 1, by: -1) {
            if let partial = dp[pos].first(where: { !$0.text.isEmpty }) {
                return [
                    WordSpan(
                        start: 0,
                        end: pos,
                        text: partial.text,
                        syllables: partial.syllables,
                        scoreQ8: partial.scoreQ8 - (n - pos) * 600,
                        penaltyQ8: partial.penaltyQ8 + (n - pos) * 600,
                        isUserPhrase: false,
                        lastWord: partial.lastWord,
                        hasKeySubstitution: partial.hasKeySubstitution,
                        keySubstitutionCount: partial.keySubstitutionCount
                    )
                ]
            }
        }
        return []
    }

    private enum CurClauseSwitch: UInt8 {
        case none = 0
        case ershi
        case woguo
        case xianfa
        case shizai
        case shizai4
        case zuo
        case jizhi
        case shiji
        case haishihui
        case loujian
        case zhineng
        case zhinengHao
        case hui
        case lushang
        case shibi
        case shibushi
        case wufa
        case tidai
        case fale
        case releaseVerb
        case shoudao
        case shoudaole
        case ding
        case dingHomophone
        case zaiHome
        case gang
        case gangcai
    }

    private static let curClauseSwitchTable: [String: CurClauseSwitch] = [
        "而是": .ershi, "二是": .ershi,
        "我国": .woguo,
        "宪法": .xianfa,
        "实在": .shizai,
        "是在": .shizai4,
        "做": .zuo, "做到": .zuo, "追求": .zuo,
        "极致": .jizhi,
        "实际": .shiji, "我实际": .shiji,
        "还是会": .haishihui, "还会": .haishihui, "不会": .haishihui, "会不会": .haishihui, "出现": .haishihui,
        "漏键": .loujian,
        "只能": .zhineng,
        "只能好": .zhinengHao,
        "会": .hui,
        "路上": .lushang, "回家路上": .lushang,
        "势必": .shibi,
        "是不是": .shibushi,
        "无法": .wufa,
        "替代": .tidai,
        "发了": .fale, "已经发了": .fale, "刚发了": .fale,
        "出了": .releaseVerb, "推了": .releaseVerb, "更新": .releaseVerb, "升级": .releaseVerb,
        "收到": .shoudao,
        "收到了": .shoudaole,
        "订": .ding,
        "顶": .dingHomophone, "定": .dingHomophone, "丁": .dingHomophone, "盯": .dingHomophone,
        "在": .zaiHome, "不在": .zaiHome, "回": .zaiHome, "到": .zaiHome,
        "刚": .gang,
        "刚才": .gangcai, "刚刚": .gangcai,
    ]

    private static let degreeFluencyExtraWords: Set<String> = [
        "非常", "特别", "十分", "比较", "不够"
    ]

    private static let zouBaExtraPrefixes: Set<String> = [
        "我们", "咱们", "快", "要不", "还是"
    ]

    private static let yiXiaPrefixes: Set<String> = [
        "等", "先等", "稍等", "再等"
    ]

    private static let modalTrailingParticles: Set<String> = [
        "吧", "吗", "呢", "啊", "啦", "么", "了"
    ]

    static func prewarmStaticTables() {
        _ = commonThreeLetterEnglishWords.count
        _ = embeddedEnglishWhitelist3.count
        _ = recoverableEndings.count
        _ = standaloneReplies.count
        _ = postWordFallbackParticles.count
        _ = stutterAdverbPrefixes.count
        _ = productiveDerivationalSuffixes.count
        _ = pronounMonosyllables.count
        _ = pronounCopulas.count
        _ = standaloneCopulaSpans.count
        _ = transitiveObjectPronounVerbs.count
        _ = chainablePrefixMonosyllables.count
        _ = sentenceFinalModalParticles.count
        _ = chainableNextMonosyllables.count
        _ = motionActivityVerbs.count
        _ = activityVerbTargets.count
        _ = destinationCityTargets.count
        _ = personNameTargets.count
        _ = multiCharPronouns.count
        _ = nounVenueEndingInBa.count
        _ = actionVerbLeadingChars.count
        _ = arrivalVerbCompounds.count
        _ = tentativeReduplicatedAndSequentialAfterZai.count
        _ = futureTimePrefixesForZaiShuo.count
        _ = drinkModalAndTimePrefixes.count
        _ = strandedComitativeLastWords.count
        _ = sentenceFinalInterrogativeOrMaTargets.count
        _ = modalDrinkNounExclusion2.count
        _ = nominalShiDemonstrativeSuffixes.count
        _ = nominalShiDeSuffixes.count
        _ = beverageAndLiquidTargets.count
        _ = vehicleAndSeatTargets.count
        _ = completionActionVerbs.count
        _ = perfectiveTargetVerbs.count
        _ = nounHandlesEndingInBa.count
        _ = tentativeReduplicatedVerbs.count
        _ = purposiveTentativePrefixes.count
        _ = abstractFactNounsAfterMotion.count
        _ = grammaticalCliticSyllables.count
        _ = degreeAdverbMonosyllables.count
        _ = gradableAdjectiveMonosyllables.count
        _ = clockHourTargets.count
        _ = timeOfDayPrefixes.count
        _ = farewellTimePrefixes.count
        _ = meetingClassifierPrefixes.count
        _ = clauseCohesionTargets.count
        _ = curClauseSwitchTable.count
        _ = degreeFluencyExtraWords.count
        _ = zouBaExtraPrefixes.count
        _ = yiXiaPrefixes.count
        _ = modalTrailingParticles.count
    }

    @inline(__always)
    private static func fastHanEquals(_ a: String, _ b: String, bothPureHan: Bool) -> Bool {
        if bothPureHan {
            let count = a.utf8.count
            if count != b.utf8.count { return false }
            if let eq = a.utf8.withContiguousStorageIfAvailable({ ab in
                b.utf8.withContiguousStorageIfAvailable({ bb in
                    for idx in 0..<count {
                        if ab[idx] != bb[idx] { return false }
                    }
                    return true
                })
            }), let result = eq {
                return result
            }
            return a.utf8.elementsEqual(b.utf8)
        }
        return a == b
    }

    @inline(__always)
    private static func fastHanHasSuffix(_ s: String, _ suffix: String, bothPureHan: Bool) -> Bool {
        if bothPureHan {
            let sCount = s.utf8.count
            let sufCount = suffix.utf8.count
            if sCount < sufCount { return false }
            let offset = sCount - sufCount
            if let res = s.utf8.withContiguousStorageIfAvailable({ sb in
                suffix.utf8.withContiguousStorageIfAvailable({ bb in
                    for idx in 0..<sufCount {
                        if sb[offset + idx] != bb[idx] { return false }
                    }
                    return true
                })
            }), let result = res {
                return result
            }
            return s.utf8.dropFirst(offset).elementsEqual(suffix.utf8)
        }
        return s.hasSuffix(suffix)
    }
}
