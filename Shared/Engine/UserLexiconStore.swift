import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Complete offline backup payload bundling SQLite personal lexicon memory (`user_phrases`, `user_bigrams`, `user_unigrams`)
/// together with adaptive 26-key `LokeyTouchCalibration` covariance state.
public struct LokeyPersonalBackup: Codable, Equatable, Sendable {
    public static let currentFormat = "lokey-personal-backup-v1"

    public struct PhraseRecord: Codable, Equatable, Sendable {
        public let surface: String
        public let compactPinyin: String
        public let spacedPinyin: String
        public let jianpin: String
        public let useCount: Int
        public let isCustom: Bool
        public let lastUsed: Int64
        public let skipCount: Int

        public init(
            surface: String,
            compactPinyin: String,
            spacedPinyin: String,
            jianpin: String,
            useCount: Int,
            isCustom: Bool,
            lastUsed: Int64,
            skipCount: Int
        ) {
            self.surface = surface
            self.compactPinyin = compactPinyin
            self.spacedPinyin = spacedPinyin
            self.jianpin = jianpin
            self.useCount = useCount
            self.isCustom = isCustom
            self.lastUsed = lastUsed
            self.skipCount = skipCount
        }
    }

    public struct BigramRecord: Codable, Equatable, Sendable {
        public let prevSurface: String
        public let nextSurface: String
        public let useCount: Int
        public let lastUsed: Int64

        public init(prevSurface: String, nextSurface: String, useCount: Int, lastUsed: Int64) {
            self.prevSurface = prevSurface
            self.nextSurface = nextSurface
            self.useCount = useCount
            self.lastUsed = lastUsed
        }
    }

    public struct UnigramRecord: Codable, Equatable, Sendable {
        public let surface: String
        public let compactPinyin: String
        public let useCount: Int
        public let lastUsed: Int64

        public init(surface: String, compactPinyin: String, useCount: Int, lastUsed: Int64) {
            self.surface = surface
            self.compactPinyin = compactPinyin
            self.useCount = useCount
            self.lastUsed = lastUsed
        }
    }

    public let format: String
    public let exportedAtISO8601: String
    public let appVersion: String
    public let touchCalibration: LokeyTouchCalibration?
    public let phrases: [PhraseRecord]
    public let bigrams: [BigramRecord]
    public let unigrams: [UnigramRecord]

    public init(
        format: String = LokeyPersonalBackup.currentFormat,
        exportedAtISO8601: String,
        appVersion: String,
        touchCalibration: LokeyTouchCalibration?,
        phrases: [PhraseRecord],
        bigrams: [BigramRecord],
        unigrams: [UnigramRecord]
    ) {
        self.format = format
        self.exportedAtISO8601 = exportedAtISO8601
        self.appVersion = appVersion
        self.touchCalibration = touchCalibration
        self.phrases = phrases
        self.bigrams = bigrams
        self.unigrams = unigrams
    }

    /// Decodes either a full `LokeyPersonalBackup` JSON file or a standalone `LokeyTouchCalibration` JSON profile.
    public static func decodeAutoDetecting(from data: Data) throws -> LokeyPersonalBackup {
        if let rawObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if rawObj["format"] is String || rawObj["phrases"] is [Any] || rawObj["bigrams"] is [Any] || rawObj["unigrams"] is [Any] {
                return try JSONDecoder().decode(LokeyPersonalBackup.self, from: data)
            }
            if rawObj["perKey"] is [String: Any] {
                let cal = try JSONDecoder().decode(LokeyTouchCalibration.self, from: data)
                return LokeyPersonalBackup(
                    format: currentFormat,
                    exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
                    appVersion: "0.8.1",
                    touchCalibration: cal,
                    phrases: [],
                    bigrams: [],
                    unigrams: []
                )
            }
        }
        throw NSError(
            domain: "com.kianuni.lokey.backup",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法识别个人备份或触控热区 JSON 格式。"]
        )
    }
}

public struct PersonalBackupRestoreSummary: Sendable, Equatable {
    public let phrasesApplied: Int
    public let bigramsApplied: Int
    public let unigramsApplied: Int
    public let calibratedKeys: Int
    public let totalCommittedTaps: Int

    public init(
        phrasesApplied: Int,
        bigramsApplied: Int,
        unigramsApplied: Int,
        calibratedKeys: Int,
        totalCommittedTaps: Int
    ) {
        self.phrasesApplied = phrasesApplied
        self.bigramsApplied = bigramsApplied
        self.unigramsApplied = unigramsApplied
        self.calibratedKeys = calibratedKeys
        self.totalCommittedTaps = totalCommittedTaps
    }
}

/// Persistent, pure-offline user phrase & dynamic frequency database backed by native SQLite3 (WAL mode),
/// paired with a write-through in-memory index so Viterbi lattice lookups run in O(1) (~0.001 ms) with zero I/O stalls.
/// Lives in the shared `App Group` container (`group.com.kianuni.lokey`) so both `Lokey` and `LokeyKeyboard`
/// share custom phrases and frequency boosts seamlessly.
public final class UserLexiconStore: @unchecked Sendable {
    public struct UserPhrase: Sendable, Equatable, Identifiable {
        public var id: String { "\(surface)|\(compactPinyin)" }
        public let surface: String
        public let pinyinNormalized: String // space-joined syllables, e.g. "lan zhou long yuan"
        public let compactPinyin: String    // concatenated, e.g. "lanzhoulongyuan"
        public let jianpin: String          // initials, e.g. "lzly"
        public let useCount: Int
        public let isCustomComposed: Bool
        public let dynamicBoostQ8: Int
        public let skipCount: Int

        public init(
            surface: String,
            pinyinNormalized: String,
            compactPinyin: String,
            jianpin: String,
            useCount: Int,
            isCustomComposed: Bool,
            dynamicBoostQ8: Int,
            skipCount: Int = 0
        ) {
            self.surface = surface
            self.pinyinNormalized = pinyinNormalized
            self.compactPinyin = compactPinyin
            self.jianpin = jianpin
            self.useCount = useCount
            self.isCustomComposed = isCustomComposed
            self.dynamicBoostQ8 = dynamicBoostQ8
            self.skipCount = skipCount
        }

        /// The standalone preference is deliberately strong. An embedded dictionary
        /// word retains its lexical cost so one selection cannot dominate a sentence.
        func embeddedScore(syllables: [String], dictionary: @autoclosure () -> [MmapLexicon.WordHit]) -> Int? {
            guard syllables.count == surface.count, syllables.joined(separator: " ") == pinyinNormalized else { return nil }
            let rawBonus = min(420, useCount > 6 ? 420 : useCount * 60)
            let skipPenalty = min(900, max(0, skipCount) * 180)
            let bonus = rawBonus - skipPenalty
            let dict = dictionary()
            if let lexical = dict.first(where: { $0.text == surface }) {
                return lexical.scoreQ8 + bonus
            }
            return (isCustomComposed || dict.isEmpty) ? -2600 + bonus : nil
        }
    }

    public struct ImportedPhraseSeed: Sendable, Equatable {
        public let surface: String
        public let syllables: [String]
        public let useCount: Int

        public init(surface: String, syllables: [String], useCount: Int) {
            self.surface = surface
            self.syllables = syllables
            self.useCount = useCount
        }
    }

    public enum ImportConflictPolicy: Sendable, Equatable {
        case skipExisting
        case mergeHigherWeight
    }

    public struct UnigramBoostEntry: Sendable, Equatable {
        public let count: Int
        public let recencyDecay: Double

        public init(count: Int, recencyDecay: Double = 1.0) {
            self.count = count
            self.recencyDecay = recencyDecay
        }
    }

    public struct DecodeSnapshot: Sendable {
        public let generation: UInt64
        public let hasAnyExactPhrases: Bool
        public let hasAnyBigrams: Bool
        public let hasAnyUnigrams: Bool
        public let syllablePrefixSet: Set<String>
        public let strictSyllablePrefixSet: Set<String>
        fileprivate let exactCache: [String: [UserPhrase]]
        fileprivate let bigramBonusCache: [String: [String: Int]]
        fileprivate let unigramCache: [String: [String: UnigramBoostEntry]]

        @inline(__always)
        public func exactSyllablePhrases(compactPinyin: String) -> [UserPhrase] {
            guard hasAnyExactPhrases, !compactPinyin.isEmpty else { return [] }
            return exactCache[compactPinyin] ?? []
        }

        @inline(__always)
        public func hasSyllablePrefix(_ spacedPrefix: String) -> Bool {
            guard hasAnyExactPhrases, !spacedPrefix.isEmpty else { return false }
            return syllablePrefixSet.contains(spacedPrefix)
        }

        @inline(__always)
        public func hasStrictSyllablePrefix(_ spacedPrefix: String) -> Bool {
            guard hasAnyExactPhrases, !spacedPrefix.isEmpty else { return false }
            return strictSyllablePrefixSet.contains(spacedPrefix)
        }

        @inline(__always)
        public func bigramBonuses(after prevSurface: String) -> [String: Int]? {
            guard hasAnyBigrams, !prevSurface.isEmpty else { return nil }
            return bigramBonusCache[prevSurface]
        }

        @inline(__always)
        public func userBigramBonus(prevSurface: String, nextSurface: String) -> Int {
            guard hasAnyBigrams, !prevSurface.isEmpty, !nextSurface.isEmpty else { return 0 }
            return bigramBonusCache[prevSurface]?[nextSurface] ?? 0
        }

        @inline(__always)
        public func unigramEntries(compactPinyin: String) -> [String: UnigramBoostEntry]? {
            guard hasAnyUnigrams, !compactPinyin.isEmpty else { return nil }
            return unigramCache[compactPinyin]
        }
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let dbQueueKey = DispatchSpecificKey<UInt8>()
    private let dbQueue = DispatchQueue(label: "com.kianuni.lokey.userLexiconSQLite", qos: .utility)
    public let databaseURL: URL
    private let broadcastChanges: Bool
    private let asyncPersistence: Bool
    private var pendingPersistenceCount = 0
    private var reloadAfterPersistence = false
    // SQLite changes this value only for commits made by other connections.
    private var loadedDataVersion: Int32?

    /// Write-through RAM caches so `lookup`, `exactSyllablePhrases`, `allPhrases`, and `learnedNextWords`
    /// run in `< 0.005 ms` with ZERO SQLite syscalls during typing.
    private var exactCache: [String: [UserPhrase]] = [:]
    private var jianpinCache: [String: [UserPhrase]] = [:]
    private var orderedPhrasesCache: [UserPhrase] = []
    private var syllablePrefixCache: Set<String> = []
    private var strictSyllablePrefixCache: Set<String> = []
    private var bigramCache: [String: [(surface: String, count: Int)]] = [:]
    private var bigramBonusCache: [String: [String: Int]] = [:]
    private var unigramCache: [String: [String: UnigramBoostEntry]] = [:]
    private var _cacheGeneration: UInt64 = 0
    private var _hasAnyExactPhrases: Bool = false
    private var _hasAnyBigrams: Bool = false
    private var _hasAnyUnigrams: Bool = false
    private var cachedSnapshot: DecodeSnapshot?

    public var cacheGeneration: UInt64 {
        lock.lock()
        let gen = _cacheGeneration
        lock.unlock()
        return gen
    }

    public var hasAnyExactPhrases: Bool {
        lock.lock()
        let flag = _hasAnyExactPhrases
        lock.unlock()
        return flag
    }

    public var hasAnyBigrams: Bool {
        lock.lock()
        let flag = _hasAnyBigrams
        lock.unlock()
        return flag
    }

    /// Returns a lock-free immutable snapshot of user phrases and bigrams in `O(1)` via copy-on-write sharing.
    public func decodeSnapshot() -> DecodeSnapshot {
        lock.lock()
        if let snap = cachedSnapshot {
            lock.unlock()
            return snap
        }
        let built = DecodeSnapshot(
            generation: _cacheGeneration,
            hasAnyExactPhrases: _hasAnyExactPhrases,
            hasAnyBigrams: _hasAnyBigrams,
            hasAnyUnigrams: _hasAnyUnigrams,
            syllablePrefixSet: syllablePrefixCache,
            strictSyllablePrefixSet: strictSyllablePrefixCache,
            exactCache: exactCache,
            bigramBonusCache: bigramBonusCache,
            unigramCache: unigramCache
        )
        cachedSnapshot = built
        lock.unlock()
        return built
    }

    private static let clauseTrailingParticles: Set<Character> = [
        "的", "地", "得", "了", "着", "过", "吗", "呢", "吧", "啊", "呀", "哦", "啦", "嘛", "呗", "哈", "呐"
    ]

    /// Valid 2-character lexical `V+得` dictionary words exempted from `clauseTrailingParticles` filtering.
    private static let lexicalVerbDeCompounds2: Set<String> = [
        "聊得", "值得", "觉得", "记得", "懂得", "舍得", "认得", "免得",
        "懒得", "显得", "难得", "获得", "取得", "使得", "不得", "省得"
    ]

    private static let clauseLeadingPronouns: Set<Character> = [
        "我", "你", "他", "她", "它", "咱", "谁"
    ]

    private static let clauseLeadingPrepositions1: Set<Character> = [
        "去", "在", "到", "给", "跟", "从", "把", "被", "让", "没", "别", "很", "更", "最", "刚"
    ]

    private static let lexicalGePrefixes2: Set<String> = [
        "个性", "个体", "个别", "个人"
    ]

    private static let twoCharConversationalClauses: Set<String> = [
        "我去", "我来", "我要", "我想", "我是", "我有", "我在", "我看", "我说",
        "你去", "你来", "你要", "你想", "你是", "你有", "你在", "你看", "你说",
        "他去", "他来", "他是", "他在", "她去", "她是", "她在"
    ]

    /// High-frequency standalone conversational words that form multi-word clauses (not single lexical compounds)
    /// whenever concatenated with another character/word into a 3+ character surface (e.g. "明天我们", "没有识别", "今天下午").
    private static let clauseBoundaryWords2: Set<String> = [
        // Personal & demonstrative pronouns
        "我们", "你们", "他们", "她们", "它们", "咱们", "大家",
        "这个", "那个", "这些", "那些", "这里", "那里", "这儿", "那儿", "这么", "那么",
        // Interrogatives
        "什么", "怎么", "怎样", "哪里", "哪儿", "哪个", "哪些",
        // Deictic / conversational time adverbs & nouns
        "今天", "明天", "昨天", "后天", "前天", "现在", "刚才", "刚刚", "马上",
        "已经", "正在", "早上", "上午", "中午", "下午", "晚上", "今晚", "明早", "昨晚",
        // Conversational copulas, negations, modals, directional complements & conjunctions
        "没有", "不是", "不会", "不能", "不要", "不用", "不管",
        "可以", "应该", "觉得", "知道", "因为", "所以", "但是", "可是",
        "如果", "虽然", "或者", "而且", "然后", "就是", "都是", "也是", "只是", "还有",
        "回家", "出门", "出去", "出来", "进来", "进去", "回来", "回去",
        "起来", "下来", "上来", "过来", "过去",
        "准备", "打算", "需要", "想要", "希望", "喜欢", "帮忙", "麻烦", "稍微", "赶紧", "一直", "一起"
    ]

    /// Returns `true` when `surface` contains syntactic particles, pronouns, or multi-word clause markers
    /// (excluding the standalone `>= 5`-character threshold so curated multi-character proper nouns can be checked separately).
    public static func hasConversationalClauseMarkers(_ surface: String) -> Bool {
        let clean = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else {
            return false
        }
        if let last = clean.last, clauseTrailingParticles.contains(last) {
            if !(clean.count == 2 && lexicalVerbDeCompounds2.contains(clean)) {
                return true
            }
        }
        if clean.count == 2 {
            return twoCharConversationalClauses.contains(clean)
        }
        if let first = clean.first, clauseLeadingPronouns.contains(first) {
            return true
        }
        let pref2 = String(clean.prefix(2))
        let suf2 = String(clean.suffix(2))
        if clauseBoundaryWords2.contains(pref2) || clauseBoundaryWords2.contains(suf2) {
            return true
        }
        let secondIdx = clean.index(after: clean.startIndex)
        if clean[secondIdx] == "个" && !lexicalGePrefixes2.contains(pref2) {
            return true
        }
        return false
    }

    /// Returns `true` when `surface` is a multi-word conversational clause or syntactic phrase
    /// (such as `"明天我们"`, `"今天下午去哪里"`, `"我们的"`, `"我今天"`, `"发个定位"`) rather than a single lexical entry.
    public static func isConversationalClauseSurface(_ surface: String) -> Bool {
        let clean = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else {
            return false
        }
        if clean.count >= 5 {
            return true
        }
        return hasConversationalClauseMarkers(clean)
    }

    /// Returns `true` when an individual segment in multi-segment Pinyin selection is a grammatical particle
    /// or standalone conversational clause word that should not fuse into a custom phrase (`is_custom = 1`).
    public static func isConversationalClauseSegment(_ segment: String) -> Bool {
        if segment.count == 1, let ch = segment.first {
            return clauseTrailingParticles.contains(ch)
        }
        if segment.count == 2 {
            return clauseBoundaryWords2.contains(segment) || twoCharConversationalClauses.contains(segment) || lexicalVerbDeCompounds2.contains(segment)
        }
        return segment.count >= 3 && isConversationalClauseSurface(segment)
    }

    /// Returns `true` when a 1-character leading segment is a conversational preposition/adverb (`去`, `在`, `给`, `把`...)
    /// that introduces a verb/prepositional phrase (`去公司`, `在学校`) rather than a custom lexical compound.
    public static func isLeadingClausePreposition(_ segment: String) -> Bool {
        guard segment.count == 1, let ch = segment.first else { return false }
        return clauseLeadingPrepositions1.contains(ch)
    }

    public convenience init() {
        self.init(
            databaseURL: LokeyAppGroup.sharedDatabaseURL(),
            broadcastChanges: true,
            asyncPersistence: true
        )
    }

    public init(databaseURL: URL, broadcastChanges: Bool = false, asyncPersistence: Bool = false) {
        self.databaseURL = databaseURL
        self.broadcastChanges = broadcastChanges
        self.asyncPersistence = asyncPersistence
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue.setSpecific(key: dbQueueKey, value: 1)
        dbQueue.sync {
            openAndMigrateOnDBQueue()
        }
    }

    deinit {
        close()
    }

    /// Explicitly drains pending async SQLite writes and closes the SQLite connection.
    public func close() {
        if DispatchQueue.getSpecific(key: dbQueueKey) != nil {
            closeOnDBQueue()
        } else {
            dbQueue.sync { closeOnDBQueue() }
        }
    }

    private func closeOnDBQueue() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func openAndMigrateOnDBQueue() {

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &db, flags, nil) != SQLITE_OK {
            closeOnDBQueue()
            return
        }
        // Wait up to 3000ms on cross-process App Group WAL locks (host app + KeyboardExtension)
        // so schema migrations and commits never silently fail with immediate SQLITE_BUSY!
        sqlite3_busy_timeout(db, 3000)

        let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS user_phrases (
            surface TEXT NOT NULL,
            compact_pinyin TEXT NOT NULL,
            spaced_pinyin TEXT NOT NULL,
            jianpin TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            is_custom INTEGER NOT NULL DEFAULT 0,
            last_used INTEGER NOT NULL,
            skip_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (surface, compact_pinyin)
        );
        CREATE INDEX IF NOT EXISTS idx_user_compact ON user_phrases(compact_pinyin);
        CREATE INDEX IF NOT EXISTS idx_user_jianpin ON user_phrases(jianpin);
        CREATE TABLE IF NOT EXISTS user_bigrams (
            prev_surface TEXT NOT NULL,
            next_surface TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            last_used INTEGER NOT NULL,
            PRIMARY KEY (prev_surface, next_surface)
        );
        CREATE INDEX IF NOT EXISTS idx_bigram_prev ON user_bigrams(prev_surface);
        CREATE TABLE IF NOT EXISTS user_unigrams (
            surface TEXT NOT NULL,
            compact_pinyin TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            last_used INTEGER NOT NULL,
            PRIMARY KEY (surface, compact_pinyin)
        );
        CREATE INDEX IF NOT EXISTS idx_unigram_compact ON user_unigrams(compact_pinyin);
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        // Atomic schema v4 hygiene migration: purge legacy whole-sentence rows (`is_custom = 0` >=4 chars,
        // >=5-char multi-segment sentences, and `is_custom = 1` conversational clauses like "明天我们" or "发个定位"
        // created by manual segment taps in v0.1..v0.3) plus >=4-char or clause-like `user_bigrams`, while preserving
        // genuine custom phrases (`is_custom = 1` such as "落键输入", "兰州陇原", "陈泽宇").
        var verStmt: OpaquePointer?
        var currentVer: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &verStmt, nil) == SQLITE_OK {
            if sqlite3_step(verStmt) == SQLITE_ROW {
                currentVer = sqlite3_column_int(verStmt, 0)
            }
            sqlite3_finalize(verStmt)
        }
        if currentVer < 5, sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK {
            var ok = true
            let baseCleanupSQL = """
            DELETE FROM user_phrases WHERE LENGTH(surface) <= 1;
            DELETE FROM user_phrases WHERE is_custom = 0 AND LENGTH(surface) >= 4;
            DELETE FROM user_phrases WHERE LENGTH(surface) >= 5;
            DELETE FROM user_bigrams WHERE LENGTH(prev_surface) >= 4 OR LENGTH(next_surface) >= 4;
            """
            if sqlite3_exec(db, baseCleanupSQL, nil, nil, nil) != SQLITE_OK {
                ok = false
            }

            if ok {
                var pollutedPhrases: [String] = []
                var scanStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT DISTINCT surface FROM user_phrases WHERE LENGTH(surface) >= 2;", -1, &scanStmt, nil) == SQLITE_OK {
                    while sqlite3_step(scanStmt) == SQLITE_ROW {
                        if let cSurf = sqlite3_column_text(scanStmt, 0) {
                            let surf = String(cString: cSurf)
                            if Self.isConversationalClauseSurface(surf) {
                                pollutedPhrases.append(surf)
                            }
                        }
                    }
                    sqlite3_finalize(scanStmt)
                } else {
                    ok = false
                }

                if ok && !pollutedPhrases.isEmpty {
                    var delPhraseStmt: OpaquePointer?
                    var delBgStmt: OpaquePointer?
                    let delP = sqlite3_prepare_v2(db, "DELETE FROM user_phrases WHERE surface = ?1;", -1, &delPhraseStmt, nil) == SQLITE_OK
                    let delB = sqlite3_prepare_v2(db, "DELETE FROM user_bigrams WHERE prev_surface = ?1 OR next_surface = ?1;", -1, &delBgStmt, nil) == SQLITE_OK
                    if delP && delB {
                        for surf in pollutedPhrases {
                            sqlite3_reset(delPhraseStmt)
                            sqlite3_bind_text(delPhraseStmt, 1, surf, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                            if sqlite3_step(delPhraseStmt) != SQLITE_DONE { ok = false; break }

                            sqlite3_reset(delBgStmt)
                            sqlite3_bind_text(delBgStmt, 1, surf, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                            if sqlite3_step(delBgStmt) != SQLITE_DONE { ok = false; break }
                        }
                    } else {
                        ok = false
                    }
                    if delP { sqlite3_finalize(delPhraseStmt) }
                    if delB { sqlite3_finalize(delBgStmt) }
                }
            }

            if ok {
                var pollutedBigramSurfs = Set<String>()
                var bgScanStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT prev_surface, next_surface FROM user_bigrams;", -1, &bgScanStmt, nil) == SQLITE_OK {
                    while sqlite3_step(bgScanStmt) == SQLITE_ROW {
                        if let cPrev = sqlite3_column_text(bgScanStmt, 0) {
                            let prevSurf = String(cString: cPrev)
                            if prevSurf.count > 3 || Self.isConversationalClauseSurface(prevSurf) {
                                pollutedBigramSurfs.insert(prevSurf)
                            }
                        }
                        if let cNext = sqlite3_column_text(bgScanStmt, 1) {
                            let nextSurf = String(cString: cNext)
                            if nextSurf.count > 3 || Self.isConversationalClauseSurface(nextSurf) {
                                pollutedBigramSurfs.insert(nextSurf)
                            }
                        }
                    }
                    sqlite3_finalize(bgScanStmt)
                } else {
                    ok = false
                }

                if ok && !pollutedBigramSurfs.isEmpty {
                    var delBgStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "DELETE FROM user_bigrams WHERE prev_surface = ?1 OR next_surface = ?1;", -1, &delBgStmt, nil) == SQLITE_OK {
                        for surf in pollutedBigramSurfs {
                            sqlite3_reset(delBgStmt)
                            sqlite3_bind_text(delBgStmt, 1, surf, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                            if sqlite3_step(delBgStmt) != SQLITE_DONE { ok = false; break }
                        }
                        sqlite3_finalize(delBgStmt)
                    } else {
                        ok = false
                    }
                }
            }

            if ok && sqlite3_exec(db, "PRAGMA user_version = 5;", nil, nil, nil) == SQLITE_OK {
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                } else {
                    currentVer = 5
                }
            } else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        if currentVer < 6, let db {
            var hasSkipColumn = false
            var infoStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(user_phrases);", -1, &infoStmt, nil) == SQLITE_OK {
                while sqlite3_step(infoStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(infoStmt, 1), String(cString: cName) == "skip_count" {
                        hasSkipColumn = true
                        break
                    }
                }
                sqlite3_finalize(infoStmt)
            }
            var migOK = true
            if !hasSkipColumn {
                migOK = sqlite3_exec(
                    db,
                    "ALTER TABLE user_phrases ADD COLUMN skip_count INTEGER NOT NULL DEFAULT 0;",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK
            }
            if migOK {
                sqlite3_exec(db, "PRAGMA user_version = 6;", nil, nil, nil)
            }
        }

        reloadCacheOnDBQueue()
    }

    private static func computeDynamicScore(
        count: Int,
        lastUsed: Double,
        now: Double,
        isCustom: Bool = false,
        skipCount: Int = 0
    ) -> Int {
        let ageDays = max(0.0, (now - lastUsed) / 86400.0)
        let decay = pow(0.5, max(0.0, ageDays) / 21.0)
        let effectiveUses = Double(max(0, count)) * (isCustom ? max(0.35, decay) : decay)
        let freqBonus = Int((log2(effectiveUses + 1.0) * 320.0).rounded())
        let recencyBonus = Int((280.0 * decay).rounded())
        let skipPenalty = min(900, max(0, skipCount) * 180)
        return min(-350, -1050 + freqBonus + recencyBonus - skipPenalty)
    }

    private static func buildSyllablePrefixSets(from ordered: [UserPhrase]) -> (all: Set<String>, strict: Set<String>) {
        var all = Set<String>()
        var strict = Set<String>()
        var phraseCount = 0
        for phrase in ordered where phrase.surface.count >= 2 && !phrase.pinyinNormalized.isEmpty {
            let parts = phrase.pinyinNormalized.split(separator: " ")
            guard parts.count >= 2 else { continue }
            var running = ""
            for (idx, part) in parts.enumerated() {
                if idx == 0 {
                    running = String(part)
                } else {
                    running += " " + part
                }
                all.insert(running)
                if idx + 1 < parts.count {
                    strict.insert(running)
                }
            }
            phraseCount += 1
            if phraseCount >= 256 || all.count >= 512 { break }
        }
        return (all, strict)
    }

    private func rebuildPhraseIndexesLocked() {
        exactCache.removeAll(keepingCapacity: true)
        jianpinCache.removeAll(keepingCapacity: true)
        _hasAnyExactPhrases = !orderedPhrasesCache.isEmpty
        for phrase in orderedPhrasesCache {
            if exactCache[phrase.compactPinyin, default: []].count < 4 {
                exactCache[phrase.compactPinyin, default: []].append(phrase)
            }
            if phrase.jianpin.count >= 2 && jianpinCache[phrase.jianpin, default: []].count < 4 {
                jianpinCache[phrase.jianpin, default: []].append(phrase)
            }
        }
        let prefixes = Self.buildSyllablePrefixSets(from: orderedPhrasesCache)
        syllablePrefixCache = prefixes.all
        strictSyllablePrefixCache = prefixes.strict
    }

    private func rebuildBigramBonusCacheLocked() {
        bigramBonusCache.removeAll(keepingCapacity: true)
        for (prev, items) in bigramCache {
            var map: [String: Int] = [:]
            map.reserveCapacity(items.count)
            for item in items {
                map[item.surface] = min(680, 380 + item.count * 60)
            }
            bigramBonusCache[prev] = map
        }
    }

    private func dataVersionOnDBQueue() -> Int32? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : nil
    }

    private func reloadCacheOnDBQueue() {
        let version = dataVersionOnDBQueue()
        var nextOrdered: [UserPhrase] = []
        var nextExact: [String: [UserPhrase]] = [:]
        var nextJianpin: [String: [UserPhrase]] = [:]
        var nextBigrams: [String: [(surface: String, count: Int)]] = [:]
        var nextUnigrams: [String: [String: UnigramBoostEntry]] = [:]
        var nextHasExact = false
        var nextHasBigrams = false
        var nextHasUnigrams = false

        if let db {
            let now = Double(Date().timeIntervalSince1970)
            let sql = """
            SELECT surface, spaced_pinyin, compact_pinyin, jianpin, use_count, is_custom, last_used, skip_count
            FROM user_phrases
            ORDER BY is_custom DESC, use_count DESC, last_used DESC
            LIMIT 8192;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cSurf = sqlite3_column_text(stmt, 0),
                          let cSpaced = sqlite3_column_text(stmt, 1),
                          let cCompact = sqlite3_column_text(stmt, 2),
                          let cJp = sqlite3_column_text(stmt, 3) else { continue }
                    let surf = String(cString: cSurf)
                    let compact = String(cString: cCompact)
                    let jp = String(cString: cJp)
                    let count = Int(sqlite3_column_int(stmt, 4))
                    let isCustom = sqlite3_column_int(stmt, 5) != 0
                    let lastUsed = Double(sqlite3_column_int64(stmt, 6))
                    let skipCount = max(0, Int(sqlite3_column_int(stmt, 7)))
                    let score = Self.computeDynamicScore(
                        count: count,
                        lastUsed: lastUsed,
                        now: now,
                        isCustom: isCustom,
                        skipCount: skipCount
                    )

                    let phrase = UserPhrase(
                        surface: surf,
                        pinyinNormalized: String(cString: cSpaced),
                        compactPinyin: compact,
                        jianpin: jp,
                        useCount: count,
                        isCustomComposed: isCustom,
                        dynamicBoostQ8: score,
                        skipCount: skipCount
                    )
                    nextOrdered.append(phrase)
                    nextHasExact = true
                    if nextExact[compact, default: []].count < 4 {
                        nextExact[compact, default: []].append(phrase)
                    }
                    if jp.count >= 2 && nextJianpin[jp, default: []].count < 4 {
                        nextJianpin[jp, default: []].append(phrase)
                    }
                }
                sqlite3_finalize(stmt)
            }

            let bgSQL = """
            SELECT prev_surface, next_surface, use_count
            FROM user_bigrams
            ORDER BY use_count DESC, last_used DESC
            LIMIT 8192;
            """
            var bgStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, bgSQL, -1, &bgStmt, nil) == SQLITE_OK {
                while sqlite3_step(bgStmt) == SQLITE_ROW {
                    guard let cPrev = sqlite3_column_text(bgStmt, 0),
                          let cNext = sqlite3_column_text(bgStmt, 1) else { continue }
                    let prev = String(cString: cPrev)
                    let next = String(cString: cNext)
                    let count = Int(sqlite3_column_int(bgStmt, 2))
                    if nextBigrams[prev, default: []].count < 8 {
                        nextBigrams[prev, default: []].append((next, count))
                        nextHasBigrams = true
                    }
                }
                sqlite3_finalize(bgStmt)
            }

            let uniSQL = """
            SELECT surface, compact_pinyin, use_count, last_used
            FROM user_unigrams
            ORDER BY use_count DESC, last_used DESC
            LIMIT 512;
            """
            var uniStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, uniSQL, -1, &uniStmt, nil) == SQLITE_OK {
                while sqlite3_step(uniStmt) == SQLITE_ROW {
                    guard let cSurf = sqlite3_column_text(uniStmt, 0),
                          let cCompact = sqlite3_column_text(uniStmt, 1) else { continue }
                    let surf = String(cString: cSurf)
                    let compact = String(cString: cCompact)
                    let count = max(1, Int(sqlite3_column_int(uniStmt, 2)))
                    let lastUsed = Double(sqlite3_column_int64(uniStmt, 3))
                    let ageDays = max(0.0, (now - lastUsed) / 86400.0)
                    let decay = pow(0.5, max(0.0, ageDays) / 21.0)
                    if nextUnigrams[compact, default: [:]].count < 8 {
                        nextUnigrams[compact, default: [:]][surf] = UnigramBoostEntry(count: count, recencyDecay: decay)
                        nextHasUnigrams = true
                    }
                }
                sqlite3_finalize(uniStmt)
            }
        }

        let nextPrefixes = Self.buildSyllablePrefixSets(from: nextOrdered)

        lock.lock()
        if pendingPersistenceCount > 0 {
            reloadAfterPersistence = true
            lock.unlock()
            return
        }
        loadedDataVersion = version
        orderedPhrasesCache = nextOrdered
        exactCache = nextExact
        jianpinCache = nextJianpin
        syllablePrefixCache = nextPrefixes.all
        strictSyllablePrefixCache = nextPrefixes.strict
        bigramCache = nextBigrams
        unigramCache = nextUnigrams
        rebuildBigramBonusCacheLocked()
        _hasAnyExactPhrases = nextHasExact
        _hasAnyBigrams = nextHasBigrams
        _hasAnyUnigrams = nextHasUnigrams
        _cacheGeneration &+= 1
        cachedSnapshot = nil
        lock.unlock()
    }

    /// Refreshes the in-memory write-through cache synchronously from disk.
    public func reloadFromDisk() {
        dbQueue.sync {
            reloadCacheOnDBQueue()
        }
    }

    /// Refreshes the in-memory cache asynchronously off the main thread ONLY when the Darwin notification
    /// originated from another process (skipping self-echoes when this store just broadcast its own commit).
    public func reloadFromDiskAsyncIfExternal(completion: (() -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self, self.dataVersionOnDBQueue() != self.loadedDataVersion else { return }
            self.reloadCacheOnDBQueue()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // Called with the RAM lock held. Enqueue in the same order as the visible mutations,
    // then release the lock before doing or waiting for any SQLite work.
    private func enqueuePersistenceAndUnlock(_ write: @escaping () -> Void) {
        pendingPersistenceCount += 1
        dbQueue.async { [self] in
            write()
            lock.lock()
            pendingPersistenceCount -= 1
            let reload = pendingPersistenceCount == 0 && reloadAfterPersistence
            if reload { reloadAfterPersistence = false }
            lock.unlock()
            if reload { reloadCacheOnDBQueue() }
        }
        lock.unlock()
        if !asyncPersistence { dbQueue.sync {} }
    }

    /// Records user selection of a candidate or newly composed multi-segment phrase.
    /// Updates RAM caches immediately (`< 0.005 ms`) and persists SQLite WAL asynchronously off the main thread when `asyncPersistence` is enabled.
    public func recordCommit(
        surface: String,
        syllables: [String],
        isCustomComposed: Bool
    ) {
        let cleanSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSurface.isEmpty, !syllables.isEmpty else { return }

        let lowerSyls = syllables.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !lowerSyls.isEmpty else { return }

        if cleanSurface.count == 1 {
            guard !isCustomComposed,
                  lowerSyls.count == 1,
                  let ch = cleanSurface.first,
                  ViterbiDecoder.isCJKIdeograph(ch),
                  !Self.clauseTrailingParticles.contains(ch) else { return }
            let compact = lowerSyls[0]
            guard !compact.isEmpty else { return }
            let now = Int64(Date().timeIntervalSince1970)
            lock.lock()
            var bucket = unigramCache[compact] ?? [:]
            let nextCount = min(32, (bucket[cleanSurface]?.count ?? 0) + 1)
            if bucket[cleanSurface] == nil && bucket.count >= 8 {
                if let minKey = bucket.min(by: { $0.value.count < $1.value.count })?.key {
                    bucket.removeValue(forKey: minKey)
                }
            }
            bucket[cleanSurface] = UnigramBoostEntry(count: nextCount, recencyDecay: 1.0)
            unigramCache[compact] = bucket
            _hasAnyUnigrams = true
            _cacheGeneration &+= 1
            cachedSnapshot = nil
            enqueuePersistenceAndUnlock { [self] in
                guard let db else { return }
                let sql = """
                INSERT INTO user_unigrams (surface, compact_pinyin, use_count, last_used)
                VALUES (?1, ?2, 1, ?3)
                ON CONFLICT(surface, compact_pinyin) DO UPDATE SET
                    use_count = MIN(32, user_unigrams.use_count + 1),
                    last_used = excluded.last_used;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, cleanSurface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(stmt, 2, compact, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int64(stmt, 3, now)
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
                if broadcastChanges {
                    LokeyIPC.postLexiconChanged()
                }
            }
            return
        }

        guard cleanSurface.count >= 2 else { return }

        let spaced = lowerSyls.joined(separator: " ")
        let compact = lowerSyls.joined()
        let jianpin = String(lowerSyls.compactMap { $0.first })
        let nowEpoch = Date().timeIntervalSince1970
        let now = Int64(nowEpoch)
        let customFlag: Int32 = isCustomComposed ? 1 : 0

        lock.lock()
        var didEvictTail = false
        if let existingIdx = orderedPhrasesCache.firstIndex(where: { $0.surface == cleanSurface && $0.compactPinyin == compact }) {
            let old = orderedPhrasesCache[existingIdx]
            let newCount = old.useCount + 1
            let newCustom = old.isCustomComposed || isCustomComposed
            let updated = UserPhrase(
                surface: cleanSurface,
                pinyinNormalized: spaced,
                compactPinyin: compact,
                jianpin: jianpin,
                useCount: newCount,
                isCustomComposed: newCustom,
                dynamicBoostQ8: Self.computeDynamicScore(
                    count: newCount,
                    lastUsed: nowEpoch,
                    now: nowEpoch,
                    isCustom: newCustom,
                    skipCount: 0
                ),
                skipCount: 0
            )
            orderedPhrasesCache.remove(at: existingIdx)
            let insertIdx = orderedPhrasesCache.firstIndex(where: { item in
                if item.isCustomComposed != updated.isCustomComposed {
                    return !item.isCustomComposed && updated.isCustomComposed
                }
                return item.useCount <= updated.useCount
            }) ?? orderedPhrasesCache.endIndex
            orderedPhrasesCache.insert(updated, at: insertIdx)
        } else {
            let created = UserPhrase(
                surface: cleanSurface,
                pinyinNormalized: spaced,
                compactPinyin: compact,
                jianpin: jianpin,
                useCount: 1,
                isCustomComposed: isCustomComposed,
                dynamicBoostQ8: Self.computeDynamicScore(
                    count: 1,
                    lastUsed: nowEpoch,
                    now: nowEpoch,
                    isCustom: isCustomComposed,
                    skipCount: 0
                ),
                skipCount: 0
            )
            let insertIdx = orderedPhrasesCache.firstIndex(where: { item in
                if item.isCustomComposed != created.isCustomComposed {
                    return !item.isCustomComposed && created.isCustomComposed
                }
                return item.useCount <= created.useCount
            }) ?? orderedPhrasesCache.endIndex
            orderedPhrasesCache.insert(created, at: insertIdx)
            if orderedPhrasesCache.count > 8192 {
                orderedPhrasesCache.removeLast()
                didEvictTail = true
            }
        }
        if didEvictTail {
            rebuildPhraseIndexesLocked()
        } else {
            _hasAnyExactPhrases = !orderedPhrasesCache.isEmpty
            var exactBucket: [UserPhrase] = []
            exactBucket.reserveCapacity(4)
            for item in orderedPhrasesCache where item.compactPinyin == compact {
                exactBucket.append(item)
                if exactBucket.count == 4 { break }
            }
            exactCache[compact] = exactBucket
            if jianpin.count >= 2 {
                var jpBucket: [UserPhrase] = []
                jpBucket.reserveCapacity(4)
                for item in orderedPhrasesCache where item.jianpin == jianpin {
                    jpBucket.append(item)
                    if jpBucket.count == 4 { break }
                }
                jianpinCache[jianpin] = jpBucket
            }
            let prefixes = Self.buildSyllablePrefixSets(from: orderedPhrasesCache)
            syllablePrefixCache = prefixes.all
            strictSyllablePrefixCache = prefixes.strict
        }
        _cacheGeneration &+= 1
        cachedSnapshot = nil
        enqueuePersistenceAndUnlock { [self] in
            guard let db else { return }
            let sql = """
            INSERT INTO user_phrases (surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used, skip_count)
            VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, 0)
            ON CONFLICT(surface, compact_pinyin) DO UPDATE SET
                use_count = user_phrases.use_count + 1,
                is_custom = MAX(user_phrases.is_custom, excluded.is_custom),
                last_used = excluded.last_used,
                skip_count = 0;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, cleanSurface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, compact, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 3, spaced, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 4, jianpin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int(stmt, 5, customFlag)
                sqlite3_bind_int64(stmt, 6, now)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if broadcastChanges {
                LokeyIPC.postLexiconChanged()
            }
        }
    }

    /// Records a consecutive Chinese word transition (`prevSurface` -> `nextSurface`) for personalized next-word association.
    /// Updates RAM bigram cache in `< 0.002 ms` and writes SQLite WAL off the main thread when `asyncPersistence` is enabled.
    public func recordBigram(prevSurface: String, nextSurface: String) {
        let prev = prevSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = nextSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty, !next.isEmpty, prev != next,
              prev.count <= 3, next.count <= 3,
              !Self.isConversationalClauseSurface(prev),
              !Self.isConversationalClauseSurface(next) else { return }

        let now = Int64(Date().timeIntervalSince1970)
        lock.lock()
        var list = bigramCache[prev] ?? []
        if let idx = list.firstIndex(where: { $0.surface == next }) {
            list[idx].count += 1
        } else {
            list.append((next, 1))
        }
        list.sort { $0.count > $1.count }
        if list.count > 8 { list.removeSubrange(8..<list.count) }
        bigramCache[prev] = list
        var bonusBucket = bigramBonusCache[prev] ?? [:]
        bonusBucket.removeAll(keepingCapacity: true)
        for entry in list {
            bonusBucket[entry.surface] = min(680, 380 + entry.count * 60)
        }
        bigramBonusCache[prev] = bonusBucket
        _hasAnyBigrams = true
        _cacheGeneration &+= 1
        cachedSnapshot = nil
        enqueuePersistenceAndUnlock { [self] in
            guard let db else { return }
            let sql = """
            INSERT INTO user_bigrams (prev_surface, next_surface, use_count, last_used)
            VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(prev_surface, next_surface) DO UPDATE SET
                use_count = user_bigrams.use_count + 1,
                last_used = excluded.last_used;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, prev, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, next, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int64(stmt, 3, now)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Pure in-memory `O(1)` lookup of personalized next-word predictions after `prevSurface`.
    public func learnedNextWords(
        after prevSurface: String,
        minCount: Int = 1,
        limit: Int = 6
    ) -> [String] {
        guard !prevSurface.isEmpty else { return [] }
        lock.lock()
        let items = bigramCache[prevSurface] ?? []
        lock.unlock()
        var out: [String] = []
        out.reserveCapacity(min(limit, items.count))
        for item in items {
            // Next-word associations strictly emit 1..3 char lexical words, never >=4-char or multi-word clauses.
            if item.surface.count > 3 || Self.isConversationalClauseSurface(item.surface) {
                continue
            }
            if item.count >= minCount {
                out.append(item.surface)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Pure in-memory `O(1)` bigram transition bonus for Viterbi decoding.
    public func userBigramBonus(prevSurface: String, nextSurface: String) -> Int {
        guard !prevSurface.isEmpty, !nextSurface.isEmpty else { return 0 }
        lock.lock()
        let bonus = _hasAnyBigrams ? (bigramBonusCache[prevSurface]?[nextSurface] ?? 0) : 0
        lock.unlock()
        return bonus
    }

    /// Pure in-memory lookup matching exact/prefix compact Pinyin or Jianpin acronym (ZERO SQLite I/O on keystrokes).
    public func lookup(query: String, limit: Int = 8) -> [UserPhrase] {
        let clean = query.lowercased().replacingOccurrences(of: "'", with: "")
        guard !clean.isEmpty else { return [] }

        lock.lock()
        if orderedPhrasesCache.isEmpty {
            lock.unlock()
            return []
        }

        var out: [UserPhrase] = []
        var seen = Set<String>()

        if let exactHits = exactCache[clean] {
            for p in exactHits where seen.insert(p.id).inserted {
                out.append(p)
            }
        }
        if clean.count >= 2, let jpHits = jianpinCache[clean] {
            for p in jpHits where seen.insert(p.id).inserted {
                out.append(p)
            }
        }
        if clean.count >= 3 {
            let maxLen = clean.count + 4
            for p in orderedPhrasesCache {
                if p.compactPinyin.count > clean.count && p.compactPinyin.count <= maxLen && p.compactPinyin.hasPrefix(clean) {
                    if seen.insert(p.id).inserted {
                        let prefixAdjusted = UserPhrase(
                            surface: p.surface,
                            pinyinNormalized: p.pinyinNormalized,
                            compactPinyin: p.compactPinyin,
                            jianpin: p.jianpin,
                            useCount: p.useCount,
                            isCustomComposed: p.isCustomComposed,
                            dynamicBoostQ8: p.dynamicBoostQ8 - 550
                        )
                        out.append(prefixAdjusted)
                        if out.count >= limit * 2 { break }
                    }
                }
            }
        }
        lock.unlock()

        out.sort { $0.dynamicBoostQ8 > $1.dynamicBoostQ8 }
        if out.count > limit {
            out.removeSubrange(limit..<out.count)
        }
        return out
    }

    /// O(1) lock-light in-memory lookup used inside the inner Viterbi lattice loop (zero SQLite I/O).
    public func exactSyllablePhrases(compactPinyin: String) -> [UserPhrase] {
        guard !compactPinyin.isEmpty else { return [] }
        lock.lock()
        let res = _hasAnyExactPhrases ? (exactCache[compactPinyin] ?? []) : []
        lock.unlock()
        return res
    }

    /// Lists learned/custom phrases in O(1) from write-through memory cache.
    public func allPhrases(limit: Int = 500) -> [UserPhrase] {
        lock.lock()
        let res = Array(orderedPhrasesCache.prefix(limit))
        lock.unlock()
        return res
    }

    /// Pure in-memory `O(1)` lookup of top user-frequent short (`1..2`-char) Chinese words
    /// for blending into the Native iOS 26 empty-field starter candidate bar (zero SQLite I/O).
    public func topFrequentStarterWords(limit: Int = 6) -> [(surface: String, isCustom: Bool)] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = orderedPhrasesCache
        lock.unlock()
        guard !snapshot.isEmpty else { return [] }

        var candidates: [(surface: String, isCustom: Bool, count: Int, boost: Int)] = []
        var seen = Set<String>()
        for p in snapshot {
            guard p.useCount >= 2,
                  p.surface.count >= 1 && p.surface.count <= 2,
                  p.surface.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }),
                  !Self.isConversationalClauseSurface(p.surface),
                  seen.insert(p.surface).inserted else {
                continue
            }
            candidates.append((p.surface, p.isCustomComposed, p.useCount, p.dynamicBoostQ8))
        }
        candidates.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.boost > $1.boost
        }
        return candidates.prefix(limit).map { ($0.surface, $0.isCustom) }
    }

    /// Records negative feedback when a user phrase candidate was surfaced ahead of the chosen item and skipped.
    public func recordExposureSkip(compactPinyin: String, skippedSurface: String) {
        let compact = compactPinyin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let surface = skippedSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty, !surface.isEmpty else { return }

        lock.lock()
        guard let existingIdx = orderedPhrasesCache.firstIndex(where: {
            $0.compactPinyin == compact && $0.surface == surface
        }) else {
            lock.unlock()
            return
        }
        let old = orderedPhrasesCache[existingIdx]
        let newSkip = min(20, old.skipCount + 1)
        let shouldPrune = !old.isCustomComposed && newSkip >= 5 && old.useCount <= 2
        if shouldPrune {
            orderedPhrasesCache.remove(at: existingIdx)
            rebuildPhraseIndexesLocked()
        } else {
            let oldPenalty = min(900, max(0, old.skipCount) * 180)
            let newPenalty = min(900, newSkip * 180)
            let updatedBoost = old.dynamicBoostQ8 + oldPenalty - newPenalty
            let updated = UserPhrase(
                surface: old.surface,
                pinyinNormalized: old.pinyinNormalized,
                compactPinyin: old.compactPinyin,
                jianpin: old.jianpin,
                useCount: old.useCount,
                isCustomComposed: old.isCustomComposed,
                dynamicBoostQ8: updatedBoost,
                skipCount: newSkip
            )
            orderedPhrasesCache[existingIdx] = updated
            rebuildPhraseIndexesLocked()
        }
        _cacheGeneration &+= 1
        cachedSnapshot = nil
        enqueuePersistenceAndUnlock { [self] in
            if let db {
                var updStmt: OpaquePointer?
                let updSQL = """
                UPDATE user_phrases
                SET skip_count = MIN(20, skip_count + 1)
                WHERE surface = ?1 AND compact_pinyin = ?2;
                """
                if sqlite3_prepare_v2(db, updSQL, -1, &updStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(updStmt, 1, surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(updStmt, 2, compact, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_step(updStmt)
                    sqlite3_finalize(updStmt)
                }
                if !old.isCustomComposed {
                    var delStmt: OpaquePointer?
                    let delSQL = """
                    DELETE FROM user_phrases
                    WHERE surface = ?1 AND compact_pinyin = ?2 AND is_custom = 0 AND skip_count >= 5 AND use_count <= 2;
                    """
                    if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(delStmt, 1, surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(delStmt, 2, compact, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_step(delStmt)
                        sqlite3_finalize(delStmt)
                    }
                }
            }
            if broadcastChanges {
                LokeyIPC.postLexiconChanged()
            }
        }
    }

    public func deletePhrase(surface: String) {
        lock.lock()
        orderedPhrasesCache.removeAll { $0.surface == surface }
        rebuildPhraseIndexesLocked()
        for k in Array(unigramCache.keys) {
            unigramCache[k]?.removeValue(forKey: surface)
            if unigramCache[k]?.isEmpty == true {
                unigramCache.removeValue(forKey: k)
            }
        }
        _hasAnyUnigrams = !unigramCache.isEmpty
        bigramCache.removeValue(forKey: surface)
        for k in Array(bigramCache.keys) {
            bigramCache[k]?.removeAll { $0.surface == surface }
            if bigramCache[k]?.isEmpty == true {
                bigramCache.removeValue(forKey: k)
            }
        }
        rebuildBigramBonusCacheLocked()
        _hasAnyBigrams = !bigramCache.isEmpty
        _cacheGeneration &+= 1
        cachedSnapshot = nil
        enqueuePersistenceAndUnlock { [self] in
            if let db {
                var stmt: OpaquePointer?
                let sql = "DELETE FROM user_phrases WHERE surface = ?1;"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
                var stmtUni: OpaquePointer?
                let sqlUni = "DELETE FROM user_unigrams WHERE surface = ?1;"
                if sqlite3_prepare_v2(db, sqlUni, -1, &stmtUni, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmtUni, 1, surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_step(stmtUni)
                    sqlite3_finalize(stmtUni)
                }
                var stmt2: OpaquePointer?
                let sql2 = "DELETE FROM user_bigrams WHERE prev_surface = ?1 OR next_surface = ?1;"
                if sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt2, 1, surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_step(stmt2)
                    sqlite3_finalize(stmt2)
                }
            }
            if broadcastChanges {
                LokeyIPC.postLexiconChanged()
            }
        }
    }

    public func totalPhraseCount() -> Int {
        lock.lock()
        let count = orderedPhrasesCache.count
        lock.unlock()
        return count
    }

    /// Queries the full SQLite table (beyond the 8,192-row RAM cache) for `"surface|compactPinyin" -> useCount`
    /// so pre-import deduplication never misses older rows.
    public func allStoredPhraseCountsByKey() -> [String: Int] {
        dbQueue.sync {
            guard let db else { return [:] }
            var result: [String: Int] = [:]
            let sql = "SELECT surface, compact_pinyin, use_count FROM user_phrases;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cSurf = sqlite3_column_text(stmt, 0),
                          let cCompact = sqlite3_column_text(stmt, 1) else { continue }
                    let key = "\(String(cString: cSurf))|\(String(cString: cCompact))"
                    let count = Int(sqlite3_column_int(stmt, 2))
                    result[key] = max(result[key] ?? 0, count)
                }
                sqlite3_finalize(stmt)
            }
            return result
        }
    }

    /// Batch-imports pre-screened custom Rime phrases into `user_phrases` inside one atomic SQLite transaction,
    /// reloads the RAM lookup cache once, and notifies keyboard extensions via Darwin IPC.
    @discardableResult
    public func importCustomPhrases(
        _ items: [ImportedPhraseSeed],
        conflictPolicy: ImportConflictPolicy = .skipExisting
    ) -> Int {
        guard !items.isEmpty else { return 0 }

        struct NormalizedSeed {
            let surface: String
            let spaced: String
            let compact: String
            let jianpin: String
            let count: Int
        }

        var dedupedByKey: [String: NormalizedSeed] = [:]
        dedupedByKey.reserveCapacity(items.count)
        var orderedKeys: [String] = []
        orderedKeys.reserveCapacity(items.count)

        for item in items {
            let cleanSurface = item.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanSurface.count >= 2 else { continue }
            let lowerSyls = item.syllables
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard lowerSyls.count == cleanSurface.count else { continue }
            let spaced = lowerSyls.joined(separator: " ")
            let compact = lowerSyls.joined()
            let jianpin = String(lowerSyls.compactMap(\.first))
            let clampedCount = min(12, max(1, item.useCount))
            let key = "\(cleanSurface)|\(compact)"
            if let existing = dedupedByKey[key] {
                if clampedCount > existing.count {
                    dedupedByKey[key] = NormalizedSeed(
                        surface: cleanSurface,
                        spaced: spaced,
                        compact: compact,
                        jianpin: jianpin,
                        count: clampedCount
                    )
                }
            } else {
                dedupedByKey[key] = NormalizedSeed(
                    surface: cleanSurface,
                    spaced: spaced,
                    compact: compact,
                    jianpin: jianpin,
                    count: clampedCount
                )
                orderedKeys.append(key)
            }
        }

        let normalized = orderedKeys.compactMap { dedupedByKey[$0] }
        guard !normalized.isEmpty else { return 0 }

        let now = Int64(Date().timeIntervalSince1970)
        let changedCount: Int = dbQueue.sync {
            guard let db else { return 0 }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                return 0
            }

            let sql: String
            switch conflictPolicy {
            case .skipExisting:
                sql = """
                INSERT OR IGNORE INTO user_phrases (surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used, skip_count)
                VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, 0);
                """
            case .mergeHigherWeight:
                sql = """
                INSERT INTO user_phrases (surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used, skip_count)
                VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, 0)
                ON CONFLICT(surface, compact_pinyin) DO UPDATE SET
                    use_count = MAX(user_phrases.use_count, excluded.use_count),
                    is_custom = 1,
                    last_used = MAX(user_phrases.last_used, excluded.last_used),
                    skip_count = 0
                WHERE excluded.use_count > user_phrases.use_count OR user_phrases.is_custom = 0;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return 0
            }

            var applied = 0
            var failed = false
            for entry in normalized {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, entry.surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, entry.compact, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 3, entry.spaced, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 4, entry.jianpin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int(stmt, 5, Int32(entry.count))
                sqlite3_bind_int64(stmt, 6, now)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    failed = true
                    break
                }
                applied += Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)

            if failed || sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return 0
            }

            reloadCacheOnDBQueue()
            return applied
        }

        if changedCount > 0 && broadcastChanges {
            LokeyIPC.postLexiconChanged()
        }
        return changedCount
    }

    public func clearAll() {
        lock.lock()
        _cacheGeneration &+= 1
        exactCache.removeAll()
        jianpinCache.removeAll()
        orderedPhrasesCache.removeAll()
        syllablePrefixCache.removeAll()
        strictSyllablePrefixCache.removeAll()
        bigramCache.removeAll()
        bigramBonusCache.removeAll()
        unigramCache.removeAll()
        _hasAnyExactPhrases = false
        _hasAnyBigrams = false
        _hasAnyUnigrams = false
        cachedSnapshot = nil
        enqueuePersistenceAndUnlock { [self] in
            if let db {
                sqlite3_exec(db, "DELETE FROM user_phrases; DELETE FROM user_bigrams; DELETE FROM user_unigrams;", nil, nil, nil)
            }
            if broadcastChanges {
                LokeyIPC.postLexiconChanged()
            }
        }
    }

    // MARK: - Full Personal Backup & Cross-Install Migration

    private static func readBackupRecords(from sqliteDB: OpaquePointer?) -> (
        phrases: [LokeyPersonalBackup.PhraseRecord],
        bigrams: [LokeyPersonalBackup.BigramRecord],
        unigrams: [LokeyPersonalBackup.UnigramRecord]
    ) {
        guard let sqliteDB else { return ([], [], []) }
        let nowSec = Int64(Date().timeIntervalSince1970)
        var phrases: [LokeyPersonalBackup.PhraseRecord] = []
        var bigrams: [LokeyPersonalBackup.BigramRecord] = []
        var unigrams: [LokeyPersonalBackup.UnigramRecord] = []

        var pStmt: OpaquePointer?
        let phraseSQL = "SELECT surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used, skip_count FROM user_phrases ORDER BY use_count DESC, surface ASC;"
        if sqlite3_prepare_v2(sqliteDB, phraseSQL, -1, &pStmt, nil) == SQLITE_OK {
            while sqlite3_step(pStmt) == SQLITE_ROW {
                guard let cSurf = sqlite3_column_text(pStmt, 0),
                      let cComp = sqlite3_column_text(pStmt, 1),
                      let cSpac = sqlite3_column_text(pStmt, 2),
                      let cJian = sqlite3_column_text(pStmt, 3) else { continue }
                let useCount = max(1, Int(sqlite3_column_int(pStmt, 4)))
                let isCustom = sqlite3_column_int(pStmt, 5) != 0
                let rawLast = sqlite3_column_int64(pStmt, 6)
                let skipCount = max(0, Int(sqlite3_column_int(pStmt, 7)))
                phrases.append(LokeyPersonalBackup.PhraseRecord(
                    surface: String(cString: cSurf),
                    compactPinyin: String(cString: cComp),
                    spacedPinyin: String(cString: cSpac),
                    jianpin: String(cString: cJian),
                    useCount: useCount,
                    isCustom: isCustom,
                    lastUsed: rawLast > 0 ? rawLast : nowSec,
                    skipCount: skipCount
                ))
            }
            sqlite3_finalize(pStmt)
        } else {
            // Legacy schema fallback (before skip_count column existed)
            var legacyStmt: OpaquePointer?
            let legacySQL = "SELECT surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used FROM user_phrases ORDER BY use_count DESC, surface ASC;"
            if sqlite3_prepare_v2(sqliteDB, legacySQL, -1, &legacyStmt, nil) == SQLITE_OK {
                while sqlite3_step(legacyStmt) == SQLITE_ROW {
                    guard let cSurf = sqlite3_column_text(legacyStmt, 0),
                          let cComp = sqlite3_column_text(legacyStmt, 1),
                          let cSpac = sqlite3_column_text(legacyStmt, 2),
                          let cJian = sqlite3_column_text(legacyStmt, 3) else { continue }
                    let rawLast = sqlite3_column_int64(legacyStmt, 6)
                    phrases.append(LokeyPersonalBackup.PhraseRecord(
                        surface: String(cString: cSurf),
                        compactPinyin: String(cString: cComp),
                        spacedPinyin: String(cString: cSpac),
                        jianpin: String(cString: cJian),
                        useCount: max(1, Int(sqlite3_column_int(legacyStmt, 4))),
                        isCustom: sqlite3_column_int(legacyStmt, 5) != 0,
                        lastUsed: rawLast > 0 ? rawLast : nowSec,
                        skipCount: 0
                    ))
                }
                sqlite3_finalize(legacyStmt)
            }
        }

        var bStmt: OpaquePointer?
        if sqlite3_prepare_v2(sqliteDB, "SELECT prev_surface, next_surface, use_count, last_used FROM user_bigrams;", -1, &bStmt, nil) == SQLITE_OK {
            while sqlite3_step(bStmt) == SQLITE_ROW {
                guard let cPrev = sqlite3_column_text(bStmt, 0),
                      let cNext = sqlite3_column_text(bStmt, 1) else { continue }
                let rawLast = sqlite3_column_int64(bStmt, 3)
                bigrams.append(LokeyPersonalBackup.BigramRecord(
                    prevSurface: String(cString: cPrev),
                    nextSurface: String(cString: cNext),
                    useCount: max(1, Int(sqlite3_column_int(bStmt, 2))),
                    lastUsed: rawLast > 0 ? rawLast : nowSec
                ))
            }
            sqlite3_finalize(bStmt)
        }

        var uStmt: OpaquePointer?
        if sqlite3_prepare_v2(sqliteDB, "SELECT surface, compact_pinyin, use_count, last_used FROM user_unigrams;", -1, &uStmt, nil) == SQLITE_OK {
            while sqlite3_step(uStmt) == SQLITE_ROW {
                guard let cSurf = sqlite3_column_text(uStmt, 0),
                      let cComp = sqlite3_column_text(uStmt, 1) else { continue }
                let rawLast = sqlite3_column_int64(uStmt, 3)
                unigrams.append(LokeyPersonalBackup.UnigramRecord(
                    surface: String(cString: cSurf),
                    compactPinyin: String(cString: cComp),
                    useCount: max(1, Int(sqlite3_column_int(uStmt, 2))),
                    lastUsed: rawLast > 0 ? rawLast : nowSec
                ))
            }
            sqlite3_finalize(uStmt)
        }

        return (phrases, bigrams, unigrams)
    }

    public func exportPersonalBackup(
        touchCalibration: LokeyTouchCalibration? = LokeyTouchCalibration.load(),
        appVersion: String = "0.8.1"
    ) -> LokeyPersonalBackup {
        let records = dbQueue.sync { Self.readBackupRecords(from: db) }
        return LokeyPersonalBackup(
            format: LokeyPersonalBackup.currentFormat,
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            touchCalibration: touchCalibration,
            phrases: records.phrases,
            bigrams: records.bigrams,
            unigrams: records.unigrams
        )
    }

    public func exportPersonalBackupJSONData(
        touchCalibration: LokeyTouchCalibration? = LokeyTouchCalibration.load(),
        appVersion: String = "0.8.1"
    ) throws -> Data {
        let backup = exportPersonalBackup(touchCalibration: touchCalibration, appVersion: appVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    public func exportRimeTabSeparatedText() -> String {
        let records = dbQueue.sync { Self.readBackupRecords(from: db).phrases }
        var lines: [String] = [
            "# Rime user dictionary exported by Lokey",
            "# format: text<TAB>pinyin<TAB>weight",
        ]
        lines.reserveCapacity(records.count + 2)
        for rec in records {
            let safeSurface = rec.surface.replacingOccurrences(of: "\t", with: " ")
            let safePinyin = (rec.spacedPinyin.isEmpty ? rec.compactPinyin : rec.spacedPinyin)
                .replacingOccurrences(of: "\t", with: " ")
            guard !safeSurface.isEmpty, !safePinyin.isEmpty else { continue }
            lines.append("\(safeSurface)\t\(safePinyin)\t\(max(1, rec.useCount))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sanitizeCalibration(_ raw: LokeyTouchCalibration) -> LokeyTouchCalibration {
        var cleaned: [String: LokeyTouchCalibration.KeyStats] = [:]
        cleaned.reserveCapacity(min(26, raw.perKey.count))
        for (rawKey, st) in raw.perKey {
            let key = rawKey.lowercased()
            guard key.count == 1, let ch = key.first, ch >= "a" && ch <= "z" else { continue }
            guard st.meanOffsetX.isFinite, st.meanOffsetY.isFinite,
                  st.varX.isFinite, st.varY.isFinite, st.covXY.isFinite else { continue }
            let clampedX = min(LokeyTouchCalibration.maxHorizontalShiftRatio, max(-LokeyTouchCalibration.maxHorizontalShiftRatio, st.meanOffsetX))
            let clampedY = min(LokeyTouchCalibration.maxVerticalShiftRatio, max(-LokeyTouchCalibration.maxVerticalShiftRatio, st.meanOffsetY))
            cleaned[key] = LokeyTouchCalibration.KeyStats(
                sampleCount: max(0, st.sampleCount),
                meanOffsetX: clampedX,
                meanOffsetY: clampedY,
                varX: max(0.0, st.varX),
                varY: max(0.0, st.varY),
                covXY: st.covXY
            )
        }
        return LokeyTouchCalibration(perKey: cleaned, totalCommittedTaps: max(0, raw.totalCommittedTaps))
    }

    @discardableResult
    public func restorePersonalBackup(
        _ backup: LokeyPersonalBackup,
        replaceExisting: Bool = false,
        restoreTouchCalibration: Bool = true,
        calibrationDefaults: UserDefaults? = nil
    ) -> PersonalBackupRestoreSummary {
        let nowSec = Int64(Date().timeIntervalSince1970)
        let validPhrases = backup.phrases.compactMap { rec -> LokeyPersonalBackup.PhraseRecord? in
            let s = rec.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = rec.compactPinyin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !s.isEmpty, !c.isEmpty else { return nil }
            let sp = rec.spacedPinyin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let jp = rec.jianpin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return LokeyPersonalBackup.PhraseRecord(
                surface: s,
                compactPinyin: c,
                spacedPinyin: sp.isEmpty ? c : sp,
                jianpin: jp,
                useCount: max(1, rec.useCount),
                isCustom: rec.isCustom,
                lastUsed: rec.lastUsed > 0 ? rec.lastUsed : nowSec,
                skipCount: max(0, rec.skipCount)
            )
        }
        let validBigrams = backup.bigrams.compactMap { rec -> LokeyPersonalBackup.BigramRecord? in
            let p = rec.prevSurface.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = rec.nextSurface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, !n.isEmpty else { return nil }
            return LokeyPersonalBackup.BigramRecord(
                prevSurface: p,
                nextSurface: n,
                useCount: max(1, rec.useCount),
                lastUsed: rec.lastUsed > 0 ? rec.lastUsed : nowSec
            )
        }
        let validUnigrams = backup.unigrams.compactMap { rec -> LokeyPersonalBackup.UnigramRecord? in
            let s = rec.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = rec.compactPinyin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !s.isEmpty, !c.isEmpty else { return nil }
            return LokeyPersonalBackup.UnigramRecord(
                surface: s,
                compactPinyin: c,
                useCount: max(1, rec.useCount),
                lastUsed: rec.lastUsed > 0 ? rec.lastUsed : nowSec
            )
        }

        let (pApplied, bApplied, uApplied): (Int, Int, Int) = dbQueue.sync {
            guard let db else { return (0, 0, 0) }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                return (0, 0, 0)
            }

            if replaceExisting {
                if sqlite3_exec(db, "DELETE FROM user_phrases; DELETE FROM user_bigrams; DELETE FROM user_unigrams;", nil, nil, nil) != SQLITE_OK {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return (0, 0, 0)
                }
            }

            var pCount = 0
            var bCount = 0
            var uCount = 0
            var ok = true

            if !validPhrases.isEmpty {
                let pSQL = """
                INSERT INTO user_phrases (surface, compact_pinyin, spaced_pinyin, jianpin, use_count, is_custom, last_used, skip_count)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(surface, compact_pinyin) DO UPDATE SET
                    spaced_pinyin = CASE WHEN length(excluded.spaced_pinyin) > length(user_phrases.spaced_pinyin) THEN excluded.spaced_pinyin ELSE user_phrases.spaced_pinyin END,
                    jianpin = CASE WHEN user_phrases.jianpin = '' THEN excluded.jianpin ELSE user_phrases.jianpin END,
                    use_count = MAX(user_phrases.use_count, excluded.use_count),
                    is_custom = MAX(user_phrases.is_custom, excluded.is_custom),
                    last_used = MAX(user_phrases.last_used, excluded.last_used),
                    skip_count = MIN(user_phrases.skip_count, excluded.skip_count);
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, pSQL, -1, &stmt, nil) == SQLITE_OK {
                    for rec in validPhrases {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        sqlite3_bind_text(stmt, 1, rec.surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(stmt, 2, rec.compactPinyin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(stmt, 3, rec.spacedPinyin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(stmt, 4, rec.jianpin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_int(stmt, 5, Int32(rec.useCount))
                        sqlite3_bind_int(stmt, 6, rec.isCustom ? 1 : 0)
                        sqlite3_bind_int64(stmt, 7, rec.lastUsed)
                        sqlite3_bind_int(stmt, 8, Int32(rec.skipCount))
                        if sqlite3_step(stmt) != SQLITE_DONE { ok = false; break }
                        pCount += 1
                    }
                    sqlite3_finalize(stmt)
                } else {
                    ok = false
                }
            }

            if ok && !validBigrams.isEmpty {
                let bSQL = """
                INSERT INTO user_bigrams (prev_surface, next_surface, use_count, last_used)
                VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(prev_surface, next_surface) DO UPDATE SET
                    use_count = MAX(user_bigrams.use_count, excluded.use_count),
                    last_used = MAX(user_bigrams.last_used, excluded.last_used);
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, bSQL, -1, &stmt, nil) == SQLITE_OK {
                    for rec in validBigrams {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        sqlite3_bind_text(stmt, 1, rec.prevSurface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(stmt, 2, rec.nextSurface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_int(stmt, 3, Int32(rec.useCount))
                        sqlite3_bind_int64(stmt, 4, rec.lastUsed)
                        if sqlite3_step(stmt) != SQLITE_DONE { ok = false; break }
                        bCount += 1
                    }
                    sqlite3_finalize(stmt)
                } else {
                    ok = false
                }
            }

            if ok && !validUnigrams.isEmpty {
                let uSQL = """
                INSERT INTO user_unigrams (surface, compact_pinyin, use_count, last_used)
                VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(surface, compact_pinyin) DO UPDATE SET
                    use_count = MAX(user_unigrams.use_count, excluded.use_count),
                    last_used = MAX(user_unigrams.last_used, excluded.last_used);
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, uSQL, -1, &stmt, nil) == SQLITE_OK {
                    for rec in validUnigrams {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        sqlite3_bind_text(stmt, 1, rec.surface, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_text(stmt, 2, rec.compactPinyin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                        sqlite3_bind_int(stmt, 3, Int32(rec.useCount))
                        sqlite3_bind_int64(stmt, 4, rec.lastUsed)
                        if sqlite3_step(stmt) != SQLITE_DONE { ok = false; break }
                        uCount += 1
                    }
                    sqlite3_finalize(stmt)
                } else {
                    ok = false
                }
            }

            if !ok || sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return (0, 0, 0)
            }

            reloadCacheOnDBQueue()
            return (pCount, bCount, uCount)
        }

        if broadcastChanges && (replaceExisting || pApplied > 0 || bApplied > 0 || uApplied > 0) {
            LokeyIPC.postLexiconChanged()
        }

        var finalCal = LokeyTouchCalibration.load(from: calibrationDefaults)
        if restoreTouchCalibration, let incomingRaw = backup.touchCalibration {
            let incoming = Self.sanitizeCalibration(incomingRaw)
            if replaceExisting || finalCal.totalCommittedTaps == 0 {
                finalCal = incoming
            } else {
                var mergedKeys = finalCal.perKey
                for (k, st) in incoming.perKey {
                    if let cur = mergedKeys[k] {
                        if st.sampleCount >= cur.sampleCount {
                            mergedKeys[k] = st
                        }
                    } else {
                        mergedKeys[k] = st
                    }
                }
                finalCal = LokeyTouchCalibration(
                    perKey: mergedKeys,
                    totalCommittedTaps: max(finalCal.totalCommittedTaps, incoming.totalCommittedTaps)
                )
            }
            finalCal.save(to: calibrationDefaults)
            if calibrationDefaults == nil {
                LokeyIPC.postSettingsChanged()
            }
        }

        return PersonalBackupRestoreSummary(
            phrasesApplied: pApplied,
            bigramsApplied: bApplied,
            unigramsApplied: uApplied,
            calibratedKeys: finalCal.calibratedKeyCount,
            totalCommittedTaps: finalCal.totalCommittedTaps
        )
    }

    /// Reads an external `user_lexicon.sqlite3` database (e.g. from an earlier installation) and restores/merges its tables.
    public func importExternalSQLiteDatabase(
        from sqliteURL: URL,
        replaceExisting: Bool = false
    ) throws -> PersonalBackupRestoreSummary {
        let headerHandle = try FileHandle(forReadingFrom: sqliteURL)
        let magicData = try headerHandle.read(upToCount: 16) ?? Data()
        try? headerHandle.close()
        let sqliteMagic = Data("SQLite format 3\0".utf8)
        guard magicData == sqliteMagic else {
            throw NSError(
                domain: "com.kianuni.lokey.backup",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "不是有效的 SQLite3 词库数据库文件。"]
            )
        }

        var srcDB: OpaquePointer?
        let rc = sqlite3_open_v2(sqliteURL.path, &srcDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, srcDB != nil else {
            if let srcDB { sqlite3_close_v2(srcDB) }
            throw NSError(
                domain: "com.kianuni.lokey.backup",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法打开 SQLite 数据库文件（错误码 \(rc)）。"]
            )
        }
        defer { sqlite3_close_v2(srcDB) }

        let records = Self.readBackupRecords(from: srcDB)
        let backup = LokeyPersonalBackup(
            format: LokeyPersonalBackup.currentFormat,
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            appVersion: "legacy-sqlite",
            touchCalibration: nil,
            phrases: records.phrases,
            bigrams: records.bigrams,
            unigrams: records.unigrams
        )
        return restorePersonalBackup(backup, replaceExisting: replaceExisting, restoreTouchCalibration: false)
    }
}
