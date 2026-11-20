import CommonCrypto
import Darwin
import Foundation
import os.lock

/// Zero-copy `mmap` reader for the `LKLF` v1 binary lexicon compiled by `scripts/build_lexicon.py`.
/// Uses direct raw buffer pointer loads so even Debug `-Onone` builds run in ~1 ms while keeping dirty heap near zero.
public final class MmapLexicon: @unchecked Sendable {
    public struct WordHit: Sendable, Equatable {
        public let text: String
        public let scoreQ8: Int
    }

    private let backingData: NSData
    private let rawBuffer: UnsafeRawBufferPointer
    private let syllableCount: Int
    private let syllableOffset: Int
    private let nodeCount: Int
    private let nodeOffset: Int
    private let edgeCount: Int
    private let edgeOffset: Int
    private let wordCount: Int
    private let wordOffset: Int
    private let jianpinCount: Int
    private let jianpinOffset: Int
    private let englishCount: Int
    private let englishOffset: Int
    private let stringPoolSize: Int
    private let stringPoolOffset: Int
    private let assocCount: Int
    private var spokenRecordsByLength = [[Int32]](repeating: [], count: NoisyChannelRefiner.maximumInputLength + 3)
    private var spokenPrefix2Offsets = [[Int32]](repeating: [], count: NoisyChannelRefiner.maximumInputLength + 3)
    private var spokenPrefix2Sorted = [Bool](repeating: false, count: NoisyChannelRefiner.maximumInputLength + 3)
    private var spokenDrop2Lock = os_unfair_lock()
    private var spokenDrop2BuiltLengths = [Bool](repeating: false, count: NoisyChannelRefiner.maximumInputLength + 3)
    private var spokenDrop2ByLength = [[Int32]](repeating: [], count: NoisyChannelRefiner.maximumInputLength + 3)
    private let assocOffset: Int
    private let spellingData: NSData?
    private let spellingTable: UnsafeBufferPointer<UInt64>
    private let emojiBackingData: NSData?
    private let emojiRawBuffer: UnsafeRawBufferPointer
    private let emojiRecordCount: Int
    private let emojiPoolOffset: Int
    public let neuralLM: NeuralSentenceScorer

    public private(set) var syllableToID: [String: UInt16] = [:]
    public private(set) var idToSyllable: [String] = [""]
    public private(set) var prefixToSyllableIDs: [String: [UInt16]] = [:]
    public private(set) var clippedToSyllableIDs: [String: [UInt16]] = [:]
    public private(set) var softClippedToSyllableIDs: [String: [UInt16]] = [:]
    private var packedSoftClippedToSIDs: [UInt32: [UInt16]] = [:]
    public private(set) var clippedPrefixToSyllableIDs: [String: [UInt16]] = [:]
    public private(set) var rimeToSyllableIDs: [String: [UInt16]] = [:]
    private var packedRimeToSyllableIDs: [UInt32: [UInt16]] = [:]
    private var packedVowelRimeBySID: [UInt32] = []
    private var packedHRimeBySID: [UInt32] = []
    private var syllableBestScores: [Int] = []
    private var syllableOneCharScores: [Int] = []
    private var topOneSyllableWordBySID: [WordHit?] = []
    private static let prewarmQueue = DispatchQueue(label: "com.kianuni.lokey.mmap.prewarm", qos: .userInitiated)
    private var prewarmLock = os_unfair_lock()
    private var _isMappedMemoryWarm = false
    private var _lastPrewarmUptime: TimeInterval = 0
    private var _didPrewarmOpenCC = false
    private var _prewarmPageChecksum: UInt8 = 0
    var prewarmChecksum: UInt8 {
        os_unfair_lock_lock(&prewarmLock)
        let checksum = _prewarmPageChecksum
        os_unfair_lock_unlock(&prewarmLock)
        return checksum
    }
    private var sharedCacheLock = os_unfair_lock()
    private var sharedRawAssocCache: [String: [String: Int]] = [:]
    private var rootTargetBySID: [UInt32] = []
    private var rootTopWordScoreBySID: [Int32] = []
    private var rootHasOutgoingBySID: [Bool] = []
    private var packedSyllableSet: Set<UInt32> = []
    // One entry per possible packed one-to-three-letter prefix. Zero means no
    // syllable starts here, one is a prefix, and two is also a complete syllable.
    private var shortSyllablePrefixes = [UInt8](repeating: 0, count: 1 << 15)
    private var shortCanonicalSID = [UInt16](repeating: 0, count: 1 << 15)
    private var packedSyllableOrClippedExactSet: Set<UInt32> = []
    private var packedCanonicalSyllableSet: Set<UInt32> = []
    private var packedCodeToSID: [UInt32: UInt16] = [:]
    private var packedKnownPrefixSet: Set<UInt64> = []
    private var packedClippedPrefixSet: Set<UInt64> = []
    private var rootEdgesByPrefix: [String: [InitialEdgeHit]] = [:]
    private var overlayEdges: [UInt64: UInt32] = [:]
    private var overlayHasEdgesNodes: Set<UInt32> = []
    private var overlayWordsByNode: [UInt32: [WordHit]] = [:]
    private var overlayTopScoreByNode: [UInt32: Int] = [:]
    private var overlaySubtreeByNode: [UInt32: Int] = [:]
    private var overlayNodeBits: [UInt8] = []
    public private(set) var overlayJianpinLeadMask: UInt32 = 0
    public private(set) var overlayJianpinMap: [String: [(text: String, syllables: [String], scoreQ8: Int)]] = [:]
    public private(set) var coreInitialMonosyllables: [String: [(text: String, syllable: String, scoreQ8: Int)]] = [:]
    private var enPrefix2Bitset = [UInt64](repeating: 0, count: 11)
    private var enPrefix3Bitset = [UInt64](repeating: 0, count: 275)
    private var jpPrefix2Bitset = [UInt64](repeating: 0, count: 11)
    private var jpPrefix3Bitset = [UInt64](repeating: 0, count: 275)
    private var hasNonAlphaEnglishKeys: Bool = false

    @inline(__always)
    private func hasOverlayAt(_ nodeIndex: UInt32) -> Bool {
        let byteIdx = Int(nodeIndex >> 3)
        guard byteIdx < overlayNodeBits.count else { return true }
        return (overlayNodeBits[byteIdx] & (1 &<< (nodeIndex & 7))) != 0
    }

    @inline(__always)
    private func markOverlayAt(_ nodeIndex: UInt32) {
        let byteIdx = Int(nodeIndex >> 3)
        if byteIdx < overlayNodeBits.count {
            overlayNodeBits[byteIdx] |= (1 &<< (nodeIndex & 7))
        }
    }

    public var totalWordRecords: Int { wordCount }
    public var totalSyllables: Int { syllableCount }
    public var totalEnglishWords: Int { englishCount }
    public var totalAssociationRecords: Int { assocCount }
    public var totalEmojiRecords: Int { emojiRecordCount }

    public enum LexiconError: Error {
        case fileTooSmall
        case invalidMagic
        case unsupportedVersion(UInt32)
        case outOfBoundsSection
    }

    public convenience init(contentsOf url: URL) throws {
        let mapped = try NSData(contentsOf: url, options: [.mappedIfSafe])
        let siblingEmojiURL = url.deletingLastPathComponent().appendingPathComponent("lokey_emoji.bin")
        let emojiMapped = try? NSData(contentsOf: siblingEmojiURL, options: [.mappedIfSafe])
        let spellingURL = url.deletingLastPathComponent().appendingPathComponent("lokey_spelling.bin")
        try self.init(nsData: mapped, emojiData: emojiMapped,
                      spellingData: try? NSData(contentsOf: spellingURL, options: [.mappedIfSafe]))
    }

    public convenience init(data: Data) throws {
        try self.init(nsData: data as NSData, emojiData: nil)
    }

    public init(nsData: NSData, emojiData: NSData? = nil, spellingData: NSData? = nil) throws {
        guard nsData.length >= 64 else { throw LexiconError.fileTooSmall }
        self.backingData = nsData
        let raw = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
        self.rawBuffer = raw

        let spelling = spellingData ?? Self.discoverResource("lokey_spelling")
        self.spellingData = spelling
        if let spelling, spelling.length >= 8 {
            let header = UnsafeRawBufferPointer(start: spelling.bytes, count: spelling.length)
            let count = Int(Self.loadU32(header, at: 4))
            if Self.loadU32(header, at: 0) == 0x314c4353, count == (spelling.length - 8) / 8,
               spelling.length == 8 + count * 8 {
                self.spellingTable = UnsafeBufferPointer(start: spelling.bytes.advanced(by: 8)
                    .assumingMemoryBound(to: UInt64.self), count: count)
            } else {
                self.spellingTable = UnsafeBufferPointer(start: nil, count: 0)
            }
        } else {
            self.spellingTable = UnsafeBufferPointer(start: nil, count: 0)
        }
        let resolvedEmojiData: NSData? = emojiData ?? Self.discoverResource("lokey_emoji")
        if let emData = resolvedEmojiData, emData.length >= 16 {
            let emRaw = UnsafeRawBufferPointer(start: emData.bytes, count: emData.length)
            let emMagic = Self.loadU32(emRaw, at: 0)
            let emVer = Self.loadU32(emRaw, at: 4)
            let emCount = Int(Self.loadU32(emRaw, at: 8))
            let emPool = Int(Self.loadU32(emRaw, at: 12))
            if emMagic == 0x4A4D454C && emVer == 1 && emCount >= 0 && 16 + emCount * 12 <= emPool && emPool <= emRaw.count {
                self.emojiBackingData = emData
                self.emojiRawBuffer = emRaw
                self.emojiRecordCount = emCount
                self.emojiPoolOffset = emPool
            } else {
                self.emojiBackingData = nil
                self.emojiRawBuffer = UnsafeRawBufferPointer(start: nil, count: 0)
                self.emojiRecordCount = 0
                self.emojiPoolOffset = 0
            }
        } else {
            self.emojiBackingData = nil
            self.emojiRawBuffer = UnsafeRawBufferPointer(start: nil, count: 0)
            self.emojiRecordCount = 0
            self.emojiPoolOffset = 0
        }

        let magic = Self.loadU32(raw, at: 0)
        let version = Self.loadU32(raw, at: 4)
        let aCount = (version >= 2 && raw.count >= 72) ? Int(Self.loadU32(raw, at: 64)) : 0
        let aOff = (version >= 2 && raw.count >= 72) ? Int(Self.loadU32(raw, at: 68)) : 0
        let headerVals = (
            magic,
            version,
            Int(Self.loadU32(raw, at: 8)),
            Int(Self.loadU32(raw, at: 12)),
            Int(Self.loadU32(raw, at: 16)),
            Int(Self.loadU32(raw, at: 20)),
            Int(Self.loadU32(raw, at: 24)),
            Int(Self.loadU32(raw, at: 28)),
            Int(Self.loadU32(raw, at: 32)),
            Int(Self.loadU32(raw, at: 36)),
            Int(Self.loadU32(raw, at: 40)),
            Int(Self.loadU32(raw, at: 44)),
            Int(Self.loadU32(raw, at: 48)),
            Int(Self.loadU32(raw, at: 52)),
            Int(Self.loadU32(raw, at: 56)),
            Int(Self.loadU32(raw, at: 60)),
            aCount,
            aOff
        )

        guard headerVals.0 == 0x464C4B4C else { throw LexiconError.invalidMagic }
        guard headerVals.1 == 1 || headerVals.1 == 2 else { throw LexiconError.unsupportedVersion(headerVals.1) }

        self.syllableCount = headerVals.2
        self.syllableOffset = headerVals.3
        self.nodeCount = headerVals.4
        self.nodeOffset = headerVals.5
        self.edgeCount = headerVals.6
        self.edgeOffset = headerVals.7
        self.wordCount = headerVals.8
        self.wordOffset = headerVals.9
        self.jianpinCount = headerVals.10
        self.jianpinOffset = headerVals.11
        self.englishCount = headerVals.12
        self.englishOffset = headerVals.13
        self.stringPoolSize = headerVals.14
        self.stringPoolOffset = headerVals.15
        self.assocCount = headerVals.16
        self.assocOffset = headerVals.17
        guard version != 2 || raw.count >= 72,
              syllableCount > 0, syllableCount <= Int(UInt16.max), nodeCount > 0,
              syllableOffset + (syllableCount + 1) * 16 <= raw.count,
              nodeOffset + nodeCount * 16 <= raw.count,
              edgeOffset + edgeCount * 8 <= raw.count,
              wordOffset + wordCount * 8 <= raw.count,
              jianpinOffset + jianpinCount * 16 <= raw.count,
              englishOffset + englishCount * 16 <= raw.count,
              (assocCount == 0 || assocOffset + assocCount * 16 <= raw.count),
              stringPoolOffset + stringPoolSize <= raw.count else {
            throw LexiconError.outOfBoundsSection
        }

        self.neuralLM = NeuralSentenceScorer(
            nsData: nsData,
            stringPoolOffset: headerVals.15,
            stringPoolSize: headerVals.14
        )

        // Only the existing "=" namespace contains complete spoken readings. Bucket its
        // mmap record numbers once; the keyboard does not copy the strings or the corpus.
        let spokenStart = [UInt8(0x3d)].withUnsafeBufferPointer(associationLowerBound)
        let spokenEnd = [UInt8(0x3e)].withUnsafeBufferPointer(associationLowerBound)
        for index in spokenStart..<spokenEnd {
            let rec = assocOffset + index * 16
            let length = Int(Self.loadU16(raw, at: rec + 8)) - 1
            if spokenRecordsByLength.indices.contains(length) {
                spokenRecordsByLength[length].append(Int32(index))
            }
        }
        for length in 2..<spokenRecordsByLength.count {
            let records = spokenRecordsByLength[length]
            guard !records.isEmpty else { continue }
            var offsets = [Int32](repeating: Int32(records.count), count: 26 * 26 + 1)
            var cursorBucket = 0
            var isSorted = true
            for (idx, record) in records.enumerated() {
                let rec = assocOffset + Int(record) * 16
                let offset = Int(Self.loadU32(raw, at: rec))
                guard offset >= 0, offset <= stringPoolSize, 3 <= stringPoolSize - offset else {
                    isSorted = false
                    break
                }
                let b0 = raw[stringPoolOffset + offset + 1]
                let b1 = raw[stringPoolOffset + offset + 2]
                guard b0 >= 0x61 && b0 <= 0x7A && b1 >= 0x61 && b1 <= 0x7A else {
                    isSorted = false
                    break
                }
                let bucket = Int(b0 - 0x61) * 26 + Int(b1 - 0x61)
                if bucket + 1 < cursorBucket {
                    isSorted = false
                    break
                }
                while cursorBucket <= bucket {
                    offsets[cursorBucket] = Int32(idx)
                    cursorBucket += 1
                }
            }
            if isSorted {
                spokenPrefix2Offsets[length] = offsets
                spokenPrefix2Sorted[length] = true
            }
        }

        // Load tiny ~425-entry syllable directory into RAM (< 32 KB) for O(1) lookup.
        var idList: [String] = Array(repeating: "", count: syllableCount + 1)
        var map: [String: UInt16] = [:]
        map.reserveCapacity(syllableCount + 8)
        var prefMap: [String: [UInt16]] = [:]
        prefMap.reserveCapacity(syllableCount * 2 + 64)

        if syllableCount > 0, let base = raw.baseAddress {
            for sid in 1...syllableCount {
                let recOff = syllableOffset + sid * 16
                let len = Int(raw[recOff + 9])
                guard len > 0 && len <= 8 else { continue }
                let strPtr = base.advanced(by: recOff).assumingMemoryBound(to: UInt8.self)
                let buf = UnsafeBufferPointer(start: strPtr, count: len)
                let str = String(decoding: buf, as: UTF8.self)
                let u16 = UInt16(sid)
                idList[sid] = str
                map[str] = u16
                if len > 1 {
                    for plen in 1..<len {
                        let p = String(decoding: UnsafeBufferPointer(start: strPtr, count: plen), as: UTF8.self)
                        prefMap[p, default: []].append(u16)
                    }
                }
                prefMap[str, default: []].append(u16)
            }
        }
        self.idToSyllable = idList
        self.syllableToID = map

        var packedSet = Set<UInt32>(minimumCapacity: syllableCount + 8)
        var packedCanonSet = Set<UInt32>(minimumCapacity: syllableCount + 4)
        var codeToSID: [UInt32: UInt16] = [:]
        codeToSID.reserveCapacity(syllableCount + 8)
        for (syl, sid) in map {
            if let code = Self.packSyllableU32(syl.utf8) {
                packedSet.insert(code)
                packedCanonSet.insert(code)
                codeToSID[code] = sid
                if Int(code) < shortCanonicalSID.count {
                    shortCanonicalSID[Int(code)] = sid
                }
            }
        }
        for (ortho, canon) in [("lue", "lve"), ("nue", "nve")] {
            if let code = Self.packSyllableU32(ortho.utf8) {
                packedSet.insert(code)
                if let sid = map[canon] {
                    codeToSID[code] = sid
                    if packedCanonSet.contains(code), Int(code) < shortCanonicalSID.count {
                        shortCanonicalSID[Int(code)] = sid
                    }
                }
            }
        }
        self.packedSyllableSet = packedSet
        for code in packedSet {
            var prefix = code
            while prefix != 0 {
                if prefix < shortSyllablePrefixes.count {
                    let index = Int(prefix)
                    shortSyllablePrefixes[index] = max(shortSyllablePrefixes[index], prefix == code ? 2 : 1)
                }
                prefix >>= 5
            }
        }
        self.packedCanonicalSyllableSet = packedCanonSet
        self.packedCodeToSID = codeToSID

        // Precompute root-node initial edges (`a..z`, `zh`, `ch`, `sh`), O(1) root target index,
        // per-syllable best subtree score, and per-syllable best standalone 1-char word score!
        var syllableBestScore = Array(repeating: -32000, count: syllableCount + 1)
        var syllableOneCharScore = Array(repeating: -32000, count: syllableCount + 1)
        var topOneSylWords = Array<WordHit?>(repeating: nil, count: syllableCount + 1)
        var rootTargets = Array(repeating: UInt32.max, count: syllableCount + 1)
        var rootTopScores = Array(repeating: Int32.min, count: syllableCount + 1)
        var rootHasOut = Array(repeating: false, count: syllableCount + 1)
        if nodeCount > 0 {
            var rootMap: [String: [InitialEdgeHit]] = [:]
            rootMap.reserveCapacity(32)
            let eCount = Int(Self.loadU16(raw, at: nodeOffset + 4))
            let firstEdge = Int(Self.loadU32(raw, at: nodeOffset))
            guard firstEdge + eCount <= edgeCount else { throw LexiconError.outOfBoundsSection }
            for i in 0..<eCount {
                let eOff = edgeOffset + (firstEdge + i) * 8
                let sid = Int(Self.loadU16(raw, at: eOff))
                guard sid > 0 && sid < idList.count else { continue }
                let syl = idList[sid]
                guard !syl.isEmpty else { continue }
                let firstIdx = syl.startIndex
                let firstCharKey = String(syl[firstIdx...firstIdx])
                let target = Self.loadU32(raw, at: eOff + 4)
                guard Int(target) < nodeCount else { throw LexiconError.outOfBoundsSection }
                rootTargets[sid] = target
                let tIdx = Int(target)
                let tOff = nodeOffset + tIdx * 16
                let targetECount = Int(Self.loadU16(raw, at: tOff + 4))
                rootHasOut[sid] = targetECount > 0
                let subScore = Int(Self.loadI16(raw, at: tOff + 12))
                let wCount = Int(Self.loadU16(raw, at: tOff + 6))
                if wCount > 0 {
                    let firstWord = Int(Self.loadU32(raw, at: tOff + 8))
                    guard firstWord + wCount <= wordCount else { throw LexiconError.outOfBoundsSection }
                    let wOff = wordOffset + firstWord * 8
                    let sOff = Int(Self.loadU32(raw, at: wOff))
                    let sLen = Int(Self.loadU16(raw, at: wOff + 4))
                    let topSc = Int(Self.loadI16(raw, at: wOff + 6))
                    rootTopScores[sid] = Int32(topSc)
                    syllableOneCharScore[sid] = topSc
                    let poolStart = stringPoolOffset + sOff
                    if sOff >= 0, sLen > 0, sOff <= stringPoolSize, sLen <= stringPoolSize - sOff, let base = raw.baseAddress {
                        let buf = UnsafeBufferPointer(
                            start: base.advanced(by: poolStart).assumingMemoryBound(to: UInt8.self),
                            count: sLen
                        )
                        topOneSylWords[sid] = WordHit(text: String(decoding: buf, as: UTF8.self), scoreQ8: topSc)
                    }
                }
                syllableBestScore[sid] = subScore
                let hit = InitialEdgeHit(syllable: syl, targetNode: target, subtreeScore: subScore)
                rootMap[firstCharKey, default: []].append(hit)
                if syl.hasPrefix("zh") {
                    rootMap["zh", default: []].append(hit)
                } else if syl.hasPrefix("ch") {
                    rootMap["ch", default: []].append(hit)
                } else if syl.hasPrefix("sh") {
                    rootMap["sh", default: []].append(hit)
                }
            }
            for k in rootMap.keys {
                rootMap[k]?.sort {
                    if $0.subtreeScore != $1.subtreeScore { return $0.subtreeScore > $1.subtreeScore }
                    return $0.syllable < $1.syllable
                }
            }
            self.rootEdgesByPrefix = rootMap
        }

        for p in prefMap.keys {
            prefMap[p]?.sort { a, b in
                let sa = syllableBestScore[Int(a)]
                let sb = syllableBestScore[Int(b)]
                if sa != sb { return sa > sb }
                return a < b
            }
        }
        self.prefixToSyllableIDs = prefMap
        self.syllableBestScores = syllableBestScore
        self.syllableOneCharScores = syllableOneCharScore
        self.topOneSyllableWordBySID = topOneSylWords
        self.rootTargetBySID = rootTargets
        self.rootTopWordScoreBySID = rootTopScores
        self.rootHasOutgoingBySID = rootHasOut

        var knownPref64 = Set<UInt64>(minimumCapacity: prefMap.count + 16)
        for p in prefMap.keys {
            if let c = Self.packASCII64(p.utf8) {
                knownPref64.insert(c)
            }
        }
        for ortho in ["lve", "nve", "lue", "nue"] {
            for plen in 1...ortho.count {
                if let c = Self.packASCII64(ortho.prefix(plen).utf8) {
                    knownPref64.insert(c)
                }
            }
        }
        self.packedKnownPrefixSet = knownPref64

        // Precompute deterministic O(1) 1-char-dropped rime recovery index (`tin -> [tian, ting]`, `zhon -> [zhong]`, `shung -> [shuang]`),
        // soft valid-syllable drop recovery (`kui -> [kuai]`, `ha -> [hao, hai, han]`, `shu -> [shuo, shou]`, `ze -> [zen]`, `me -> [men, mei]`),
        // and dropped-initial consonant rime index (`en -> [men, ben, fen, ...]`, `ai -> [zai, lai, kai, ...]`, `ou -> [you, hou, dou, ...]`, `i -> [yi, li, ti, ...]`).
        var clippedMap: [String: [UInt16]] = [:]
        clippedMap.reserveCapacity(420)
        var softClippedMap: [String: [UInt16]] = [:]
        softClippedMap.reserveCapacity(80)
        var rimeMap: [String: [UInt16]] = [:]
        rimeMap.reserveCapacity(96)

        @inline(__always)
        func isASCIIVowel(_ b: UInt8) -> Bool {
            b == 0x61 || b == 0x65 || b == 0x69 || b == 0x6F || b == 0x75 || b == 0x76
        }

        var bytesBuf = ContiguousArray<UInt8>()
        bytesBuf.reserveCapacity(8)
        var droppedBuf = ContiguousArray<UInt8>()
        droppedBuf.reserveCapacity(8)

        for sid in 1...syllableCount {
            let str = idList[sid]
            guard !str.isEmpty else { continue }
            let u16 = UInt16(sid)
            bytesBuf.removeAll(keepingCapacity: true)
            bytesBuf.append(contentsOf: str.utf8)
            let n = bytesBuf.count
            let isDigraph = n >= 2 && bytesBuf[1] == 0x68
                && (bytesBuf[0] == 0x7A || bytesBuf[0] == 0x63 || bytesBuf[0] == 0x73)

            // 1. Dropped-initial rime index (`woen -> women`, `xianai -> xianzai`, `meiou -> meiyou`, `kei -> keyi`, `zhiao -> zhidao`)
            if n >= 2 && n <= 6, !isASCIIVowel(bytesBuf[0]) {
                if isDigraph && n >= 3 {
                    let vowelRime = String(decoding: bytesBuf[2..<n], as: UTF8.self)
                    if !rimeMap[vowelRime, default: []].contains(u16) {
                        rimeMap[vowelRime, default: []].append(u16)
                    }
                    let hRime = String(decoding: bytesBuf[1..<n], as: UTF8.self)
                    if map[hRime] == nil && !rimeMap[hRime, default: []].contains(u16) {
                        rimeMap[hRime, default: []].append(u16)
                    }
                } else {
                    let vowelRime = String(decoding: bytesBuf[1..<n], as: UTF8.self)
                    if !rimeMap[vowelRime, default: []].contains(u16) {
                        rimeMap[vowelRime, default: []].append(u16)
                    }
                }
            }

            // 2. Hard (`map[dropped] == nil`) & soft (`map[dropped] != nil`) 1-letter rime drop indices
            guard n >= 3 && n <= 6 else { continue }
            let initLen = isDigraph ? 2 : 1
            guard initLen < n else { continue }
            for dropIdx in initLen..<n {
                droppedBuf.removeAll(keepingCapacity: true)
                for idx in 0..<n where idx != dropIdx {
                    droppedBuf.append(bytesBuf[idx])
                }
                let dCount = droppedBuf.count
                guard dCount >= 2 else { continue }
                var hasVowel = false
                for b in droppedBuf where isASCIIVowel(b) {
                    hasVowel = true
                    break
                }
                let hasNasalNgCoda = dCount >= 3
                    && droppedBuf[dCount - 2] == 0x6E
                    && droppedBuf[dCount - 1] == 0x67
                guard hasVowel || hasNasalNgCoda else { continue }
                let droppedStr = String(decoding: droppedBuf, as: UTF8.self)
                if map[droppedStr] == nil {
                    if !clippedMap[droppedStr, default: []].contains(u16) {
                        clippedMap[droppedStr, default: []].append(u16)
                    }
                }
            }
        }
        // Retroflex digraph `zh/ch/sh` leading-consonant drop on non-syllable `"hi"` (`hijian -> 时间`, `hidao -> 知道`, `hifan -> 吃饭`):
        if map["hi"] == nil {
            let hiTargets = ["shi", "zhi", "chi"].compactMap { map[$0] }
            if !hiTargets.isEmpty {
                clippedMap["hi"] = hiTargets
            }
        }

        // Curated phonological valid-syllable 1-letter missed-key pairs:
        // 1) Medial/coda vowel & open-syllable nasal `-n` drops (`kui -> kuai`, `ha -> hao`, `ze -> zen`, `me -> men`, `ka -> kan`, `xia -> xian`)
        // 2) Two-thumb retroflex digraph leading `z/c/s` drops (`he -> zhe/she/che`, `hu -> shu/zhu/chu`, `hou -> shou/zhou/chou`, etc.)
        // Avoids 1,600 brute-force collisions (`shu -X-> shou`, `xian -X-> xiang`, `ne -X-> nue`) and keeps lattice fanout minimal!
        let curatedSoftClippedPairs: [(String, [String])] = [
            // Omitted final vowel after a palatal onset. The exact syllable still competes
            // normally; the decoder guards clean words such as 习武 when building spans.
            ("ji", ["jia"]), ("qi", ["qia"]), ("xi", ["xia"]),
            ("kui", ["kuai"]),
            ("gui", ["guai"]),
            ("zhui", ["zhuai"]),
            ("chui", ["chuai"]),
            ("shui", ["shuai"]),
            ("ha", ["hao", "sha", "zha", "cha"]),
            ("ze", ["zen"]),
            ("me", ["men"]),
            ("shu", ["shuo"]),
            ("zhu", ["zhuo"]),
            ("chu", ["chuo"]),
            ("yu", ["you"]),
            // General open-syllable nasal `-n` & `-i` coda drops (`kanka -> 看看`, `wome -> 我们`, `nixiazai -> 你现在`, `shijia -> 时间`, `tida -> 替代`)
            ("ka", ["kan"]),
            ("za", ["zan"]),
            ("ca", ["can"]),
            ("sa", ["san"]),
            ("zha", ["zhan"]),
            ("cha", ["chan"]),
            ("sha", ["shan"]),
            ("ba", ["ban"]),
            ("pa", ["pan"]),
            ("ma", ["man"]),
            ("fa", ["fan"]),
            ("da", ["dan", "dai"]),
            ("ta", ["tan"]),
            ("na", ["nan"]),
            ("la", ["lan"]),
            ("ga", ["gan"]),
            ("wa", ["wan"]),
            ("ya", ["yan"]),
            ("xia", ["xian"]),
            ("jia", ["jian"]),
            ("qia", ["qian"]),
            ("hua", ["huan", "shua", "zhua"]),
            ("ke", ["ken"]),
            ("ge", ["gen"]),
            ("he", ["zhe", "she", "che", "hen"]),
            ("re", ["ren"]),
            ("zhe", ["zhen"]),
            ("che", ["chen"]),
            ("she", ["shen"]),
            // Retroflex digraph leading `z/c/s` drop (`h* -> sh*/zh*/ch*`: `hege -> 这个`, `hurifa -> 输入法`, `huqu -> 出去`, `henme -> 什么`)
            ("hai", ["shai", "zhai", "chai"]),
            ("han", ["shan", "zhan", "chan"]),
            ("hang", ["shang", "zhang", "chang"]),
            ("hao", ["shao", "zhao", "chao"]),
            ("hei", ["shei", "zhei"]),
            ("hen", ["shen", "zhen", "chen"]),
            ("heng", ["sheng", "zheng", "cheng"]),
            ("hong", ["zhong", "chong"]),
            ("hou", ["shou", "zhou", "chou"]),
            ("hu", ["shu", "chu", "zhu"]),
            ("huai", ["shuai", "zhuai", "chuai"]),
            ("huan", ["shuan", "zhuan", "chuan"]),
            ("huang", ["shuang", "zhuang", "chuang"]),
            ("hui", ["shui", "zhui", "chui"]),
            ("hun", ["shun", "zhun", "chun"]),
            ("huo", ["shuo", "zhuo", "chuo"]),
        ]
        for (shortSyl, targets) in curatedSoftClippedPairs where map[shortSyl] != nil {
            var sids: [UInt16] = softClippedMap[shortSyl] ?? []
            for t in targets {
                if let sid = map[t], !sids.contains(sid) {
                    sids.append(sid)
                }
            }
            if !sids.isEmpty {
                sids.sort { a, b in
                    let sa = syllableBestScore[Int(a)]
                    let sb = syllableBestScore[Int(b)]
                    if sa != sb { return sa > sb }
                    return a < b
                }
                softClippedMap[shortSyl] = sids
            }
        }
        for k in clippedMap.keys {
            clippedMap[k]?.sort { a, b in
                let sa = syllableBestScore[Int(a)]
                let sb = syllableBestScore[Int(b)]
                if sa != sb { return sa > sb }
                return a < b
            }
        }
        for k in rimeMap.keys {
            rimeMap[k]?.sort { a, b in
                let sa = syllableBestScore[Int(a)]
                let sb = syllableBestScore[Int(b)]
                if sa != sb { return sa > sb }
                return a < b
            }
        }
        self.clippedToSyllableIDs = clippedMap
        self.softClippedToSyllableIDs = softClippedMap
        var packedSoftMap: [UInt32: [UInt16]] = [:]
        packedSoftMap.reserveCapacity(softClippedMap.count)
        for (k, v) in softClippedMap {
            if let code = Self.packSyllableU32(k.utf8) {
                packedSoftMap[code] = v
            }
        }
        self.packedSoftClippedToSIDs = packedSoftMap
        self.rimeToSyllableIDs = rimeMap

        var clippedPrefToSIDs: [String: [UInt16]] = [:]
        clippedPrefToSIDs.reserveCapacity(clippedMap.count)
        for (k, sids) in clippedMap where k.count >= 3 {
            var endIdx = k.index(after: k.startIndex)
            for _ in 2..<k.count {
                endIdx = k.index(after: endIdx)
                let p = String(k[..<endIdx])
                guard map[p] == nil && prefMap[p] == nil else { continue }
                let existingExact = clippedMap[p]
                var bucket = clippedPrefToSIDs[p] ?? []
                for sid in sids {
                    if existingExact?.contains(sid) == true { continue }
                    if !bucket.contains(sid) {
                        bucket.append(sid)
                    }
                }
                if !bucket.isEmpty {
                    clippedPrefToSIDs[p] = bucket
                }
            }
        }
        for p in clippedPrefToSIDs.keys {
            clippedPrefToSIDs[p]?.sort { a, b in
                let sa = syllableBestScore[Int(a)]
                let sb = syllableBestScore[Int(b)]
                if sa != sb { return sa > sb }
                return a < b
            }
        }
        self.clippedPrefixToSyllableIDs = clippedPrefToSIDs

        var pRimeMap: [UInt32: [UInt16]] = [:]
        pRimeMap.reserveCapacity(rimeMap.count)
        var vowelRimeBySID = Array<UInt32>(repeating: 0, count: syllableCount + 1)
        var hRimeBySID = Array<UInt32>(repeating: 0, count: syllableCount + 1)
        for (rimeStr, sids) in rimeMap {
            if let code64 = Self.packASCII64(rimeStr.utf8), code64 <= UInt64(UInt32.max) {
                let pCode = UInt32(truncatingIfNeeded: code64)
                pRimeMap[pCode] = sids
                let isH = (rimeStr.utf8.first == 0x68)
                for sid in sids {
                    let idx = Int(sid)
                    if idx > 0 && idx <= syllableCount {
                        if isH {
                            hRimeBySID[idx] = pCode
                        } else {
                            vowelRimeBySID[idx] = pCode
                        }
                    }
                }
            }
        }
        self.packedRimeToSyllableIDs = pRimeMap
        self.packedVowelRimeBySID = vowelRimeBySID
        self.packedHRimeBySID = hRimeBySID

        var clippedPref64 = Set<UInt64>(minimumCapacity: clippedMap.count * 2 + 64)
        var sylOrClipExact32 = packedSet
        sylOrClipExact32.reserveCapacity(packedSet.count + clippedMap.count + 16)
        for k in clippedMap.keys {
            if let c32 = Self.packSyllableU32(k.utf8) {
                sylOrClipExact32.insert(c32)
            }
            var code: UInt64 = 0
            var len = 0
            for b in k.utf8 {
                guard b >= 0x61 && b <= 0x7A && len < 10 else { break }
                code = (code << 5) | UInt64(b - 0x60)
                len += 1
                clippedPref64.insert(code)
            }
        }
        for alias in ["yo", "mn", "rn", "zn", "shn", "zhn", "chn", "hn", "wn", "gn", "fn", "bn", "kn"] {
            if let c32 = Self.packSyllableU32(alias.utf8) {
                sylOrClipExact32.insert(c32)
            }
            var code: UInt64 = 0
            var len = 0
            for b in alias.utf8 {
                guard b >= 0x61 && b <= 0x7A && len < 10 else { break }
                code = (code << 5) | UInt64(b - 0x60)
                len += 1
                clippedPref64.insert(code)
            }
        }
        self.packedClippedPrefixSet = clippedPref64
        self.packedSyllableOrClippedExactSet = sylOrClipExact32
        buildNativeParityOverlay()
        buildPrefixBitsets()
    }

    private func buildPrefixBitsets() {
        let raw = rawBuffer
        for i in 0..<englishCount {
            let recOff = englishOffset + i * 16
            let lOff = Int(Self.loadU32(raw, at: recOff))
            let lLen = Int(Self.loadU16(raw, at: recOff + 8))
            if lLen < 2 { continue }
            guard lOff >= 0, lOff <= stringPoolSize, min(3, lLen) <= stringPoolSize - lOff else {
                hasNonAlphaEnglishKeys = true
                continue
            }
            let base = stringPoolOffset + lOff
            let b0 = raw[base]
            let b1 = raw[base + 1]
            guard b0 >= 0x61 && b0 <= 0x7A && b1 >= 0x61 && b1 <= 0x7A else {
                hasNonAlphaEnglishKeys = true
                continue
            }
            let idx2 = Int(b0 - 0x61) * 26 + Int(b1 - 0x61)
            enPrefix2Bitset[idx2 >> 6] |= (UInt64(1) &<< (idx2 & 63))
            if lLen >= 3 {
                let b2 = raw[base + 2]
                guard b2 >= 0x61 && b2 <= 0x7A else {
                    hasNonAlphaEnglishKeys = true
                    continue
                }
                let idx3 = idx2 * 26 + Int(b2 - 0x61)
                enPrefix3Bitset[idx3 >> 6] |= (UInt64(1) &<< (idx3 & 63))
            }
        }

        for i in 0..<jianpinCount {
            let recOff = jianpinOffset + i * 16
            let b0 = raw[recOff]
            let b1 = raw[recOff + 1]
            guard b0 >= 0x61 && b0 <= 0x7A && b1 >= 0x61 && b1 <= 0x7A else { continue }
            let idx2 = Int(b0 - 0x61) * 26 + Int(b1 - 0x61)
            jpPrefix2Bitset[idx2 >> 6] |= (UInt64(1) &<< (idx2 & 63))
            let b2 = raw[recOff + 2]
            if b2 >= 0x61 && b2 <= 0x7A {
                let idx3 = idx2 * 26 + Int(b2 - 0x61)
                jpPrefix3Bitset[idx3 >> 6] |= (UInt64(1) &<< (idx3 & 63))
            }
        }
        for key in overlayJianpinMap.keys {
            let bytes = Array(key.utf8)
            guard bytes.count >= 2 else { continue }
            let b0 = bytes[0]
            let b1 = bytes[1]
            guard b0 >= 0x61 && b0 <= 0x7A && b1 >= 0x61 && b1 <= 0x7A else { continue }
            let idx2 = Int(b0 - 0x61) * 26 + Int(b1 - 0x61)
            jpPrefix2Bitset[idx2 >> 6] |= (UInt64(1) &<< (idx2 & 63))
            if bytes.count >= 3 {
                let b2 = bytes[2]
                if b2 >= 0x61 && b2 <= 0x7A {
                    let idx3 = idx2 * 26 + Int(b2 - 0x61)
                    jpPrefix3Bitset[idx3 >> 6] |= (UInt64(1) &<< (idx3 & 63))
                }
            }
        }
    }

    @inline(__always)
    public static func packASCII64<S: Sequence>(_ utf8: S) -> UInt64? where S.Element == UInt8 {
        var code: UInt64 = 0
        var len = 0
        for b in utf8 {
            guard b >= 0x61 && b <= 0x7A && len < 10 else { return nil }
            code = (code << 5) | UInt64(b - 0x60)
            len += 1
        }
        return len > 0 ? code : nil
    }

    @inline(__always)
    public static func appendPackedASCII64(_ base: UInt64, char: Character) -> UInt64 {
        guard let ascii = char.asciiValue, ascii >= 0x61 && ascii <= 0x7A else { return 0 }
        return (base << 5) | UInt64(ascii - 0x60)
    }

    @inline(__always)
    public static func unpackASCII64(_ packedCode: UInt64) -> String {
        guard packedCode != 0 else { return "" }
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        return withUnsafeMutableBytes(of: &buf) { ptr in
            var c = packedCode
            var idx = 10
            while c != 0 && idx > 0 {
                idx -= 1
                ptr[idx] = UInt8(truncatingIfNeeded: c & 0x1F) &+ 0x60
                c >>= 5
            }
            return String(decoding: UnsafeRawBufferPointer(rebasing: ptr[idx..<10]), as: UTF8.self)
        }
    }

    @inline(__always)
    public func isKnownPrefix(_ packedCode: UInt64) -> Bool {
        packedCode != 0 && packedKnownPrefixSet.contains(packedCode)
    }

    @inline(__always)
    public func isClippedPrefix(_ packedCode: UInt64) -> Bool {
        packedCode != 0 && packedClippedPrefixSet.contains(packedCode)
    }

    @inline(__always)
    public func isPackedSyllable(_ code: UInt32) -> Bool {
        code != 0 && packedSyllableSet.contains(code)
    }

    @inline(__always)
    public func isPackedSyllableOrClippedExact(_ code: UInt32) -> Bool {
        code != 0 && packedSyllableOrClippedExactSet.contains(code)
    }

    @inline(__always)
    public func syllableBestScore(forSyllableID sid: UInt16) -> Int {
        let idx = Int(sid)
        guard idx > 0 && idx < syllableBestScores.count else { return -32000 }
        return syllableBestScores[idx]
    }

    /// Zero-`mmap` O(1) RAM lookup for the top standalone 1-syllable word matching `raw` (`< 0.2 µs`, zero cold page faults).
    @inline(__always)
    public func topOneSyllableWord(forSyllable raw: String) -> WordHit? {
        guard let sid = syllableToID[raw] else { return nil }
        let idx = Int(sid)
        guard idx > 0 && idx < topOneSyllableWordBySID.count else { return nil }
        return topOneSyllableWordBySID[idx]
    }

    public var isMappedMemoryWarm: Bool {
        os_unfair_lock_lock(&prewarmLock)
        let warm = _isMappedMemoryWarm
        os_unfair_lock_unlock(&prewarmLock)
        return warm
    }

    /// Asynchronously faults `mmap` pages into the OS page cache on a `.userInitiated` background queue so neither
    /// `.main` touch handling nor early candidate decodes stall on cold flash page faults after keyboard attach.
    public func prewarmMappedPagesAsync(includeOpenCC: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(&prewarmLock)
        let shouldPrewarmMmap = !(_lastPrewarmUptime > 0 && (now - _lastPrewarmUptime) < 45.0)
        if shouldPrewarmMmap {
            _lastPrewarmUptime = now
        }
        let shouldPrewarmOpenCC = includeOpenCC && !_didPrewarmOpenCC
        if shouldPrewarmOpenCC {
            _didPrewarmOpenCC = true
        }
        os_unfair_lock_unlock(&prewarmLock)

        if shouldPrewarmMmap {
            Self.prewarmQueue.async { [weak self] in
                guard let self else { return }
                let pageStride = 16384
                @inline(__always)
                func touchPages(_ ptr: UnsafePointer<UInt8>, start: Int, end: Int, sink: inout UInt8) {
                    var idx = start
                    while idx < end {
                        sink &+= ptr[idx]
                        idx &+= pageStride
                    }
                }
                var sink: UInt8 = 0
                if let base = self.rawBuffer.baseAddress, self.rawBuffer.count > 0 {
                    let count = self.rawBuffer.count
                    let ptr = base.assumingMemoryBound(to: UInt8.self)
                    let poolEnd = min(count, self.stringPoolOffset + self.stringPoolSize)
                    // 1. LNLM-v2 neural weights & embeddings at tail
                    if poolEnd < count {
                        _ = posix_madvise(UnsafeMutableRawPointer(mutating: base.advanced(by: poolEnd)), count - poolEnd, POSIX_MADV_WILLNEED)
                        touchPages(ptr, start: poolEnd, end: count, sink: &sink)
                    }
                    // 2. Core Trie (syllables + nodes + edges + words)
                    let trieStart = min(count, self.syllableOffset)
                    let trieEnd = min(count, self.jianpinOffset)
                    if trieStart < trieEnd {
                        touchPages(ptr, start: trieStart, end: trieEnd, sink: &sink)
                    }
                }
                if let sp = self.spellingData, sp.length > 0 {
                    _ = posix_madvise(UnsafeMutableRawPointer(mutating: sp.bytes), sp.length, POSIX_MADV_WILLNEED)
                    touchPages(sp.bytes.assumingMemoryBound(to: UInt8.self), start: 0, end: sp.length, sink: &sink)
                }
                if let base = self.rawBuffer.baseAddress, self.rawBuffer.count > 0 {
                    let count = self.rawBuffer.count
                    let ptr = base.assumingMemoryBound(to: UInt8.self)
                    // 3. Assoc / spoken / bigram table
                    if self.assocCount > 0 && self.assocOffset < self.stringPoolOffset {
                        touchPages(ptr, start: self.assocOffset, end: min(count, self.stringPoolOffset), sink: &sink)
                    }
                }
                if let emBase = self.emojiRawBuffer.baseAddress, self.emojiRawBuffer.count > 0 {
                    _ = posix_madvise(UnsafeMutableRawPointer(mutating: emBase), self.emojiRawBuffer.count, POSIX_MADV_WILLNEED)
                    touchPages(emBase.assumingMemoryBound(to: UInt8.self), start: 0, end: self.emojiRawBuffer.count, sink: &sink)
                }
                os_unfair_lock_lock(&self.prewarmLock)
                self._prewarmPageChecksum = sink
                self._isMappedMemoryWarm = true
                os_unfair_lock_unlock(&self.prewarmLock)

                self.ensureSpokenDrop2Index()

                if let base = self.rawBuffer.baseAddress, self.rawBuffer.count > 0 {
                    let count = self.rawBuffer.count
                    let ptr = base.assumingMemoryBound(to: UInt8.self)
                    // 4. Remaining lexicon sections (jianpin, english, stringPool, header)
                    let jpEnd = self.assocCount > 0 ? min(count, self.assocOffset) : min(count, self.stringPoolOffset)
                    if self.jianpinOffset < jpEnd {
                        touchPages(ptr, start: self.jianpinOffset, end: jpEnd, sink: &sink)
                    }
                    let poolEnd = min(count, self.stringPoolOffset + self.stringPoolSize)
                    if self.stringPoolOffset < poolEnd {
                        touchPages(ptr, start: self.stringPoolOffset, end: poolEnd, sink: &sink)
                    }
                    if self.syllableOffset > 0 {
                        touchPages(ptr, start: 0, end: min(count, self.syllableOffset), sink: &sink)
                    }
                }
                os_unfair_lock_lock(&self.prewarmLock)
                self._prewarmPageChecksum = sink
                os_unfair_lock_unlock(&self.prewarmLock)
            }
        }
        if shouldPrewarmOpenCC {
            Self.prewarmQueue.async {
                _ = OpenCCConverter.shared.convert("头发", modeRawValue: 1)
                _ = OpenCCConverter.shared.convert("头发", modeRawValue: 2)
            }
        }
    }

    public struct DroppedInitialEdgeHit: Sendable {
        public let syllableID: UInt16
        public let canonical: String
        public let targetNode: UInt32
        public let subtreeScore: Int
    }

    /// Resolves Trie-valid outgoing syllables from `nodeIndex > 0` whose rime equals `rime` after dropping an initial consonant/semivowel.
    public func matchDroppedInitialEdges(
        from nodeIndex: UInt32,
        rime: String,
        limit: Int = 6
    ) -> [DroppedInitialEdgeHit] {
        guard let code64 = Self.packASCII64(rime.utf8), code64 <= UInt64(UInt32.max) else {
            return []
        }
        return matchDroppedInitialEdges(
            from: nodeIndex,
            packedRime: UInt32(truncatingIfNeeded: code64),
            isHRime: rime.utf8.first == 0x68,
            limit: limit
        )
    }

    /// Zero-String-allocation overload of `matchDroppedInitialEdges` using packed 5-bit ASCII rime code and contiguous L1 edge scan on typical low-degree Trie nodes.
    public func matchDroppedInitialEdges(
        from nodeIndex: UInt32,
        packedRime: UInt32,
        isHRime: Bool,
        limit: Int = 6
    ) -> [DroppedInitialEdgeHit] {
        let idx = Int(nodeIndex)
        guard limit > 0, idx > 0, packedRime != 0,
              let candidateSIDs = packedRimeToSyllableIDs[packedRime], !candidateSIDs.isEmpty else {
            return []
        }
        let rimeBySID = isHRime ? packedHRimeBySID : packedVowelRimeBySID
        var hits: [DroppedInitialEdgeHit] = []
        hits.reserveCapacity(min(limit, candidateSIDs.count))
        if idx < nodeCount {
            let raw = rawBuffer
            let nOff = nodeOffset + idx * 16
            let eCount = Int(Self.loadU16(raw, at: nOff + 4))
            let firstEdge = Int(Self.loadU32(raw, at: nOff))
            if eCount > 0 && firstEdge + eCount <= edgeCount {
                if eCount <= 32 {
                    for i in 0..<eCount {
                        let eOff = edgeOffset + (firstEdge + i) * 8
                        let sid = Self.loadU16(raw, at: eOff)
                        let sIdx = Int(sid)
                        if sIdx > 0 && sIdx < rimeBySID.count && rimeBySID[sIdx] == packedRime {
                            let target = Self.loadU32(raw, at: eOff + 4)
                            if Int(target) < nodeCount {
                                hits.append(
                                    DroppedInitialEdgeHit(
                                        syllableID: sid,
                                        canonical: idToSyllable[sIdx],
                                        targetNode: target,
                                        subtreeScore: maxSubtreeScore(at: target)
                                    )
                                )
                            }
                        }
                    }
                } else {
                    for sid in candidateSIDs {
                        let sIdx = Int(sid)
                        guard sIdx > 0 && sIdx < rimeBySID.count && rimeBySID[sIdx] == packedRime else { continue }
                        var lo = 0
                        var hi = eCount - 1
                        var matchedTarget: UInt32? = nil
                        while lo <= hi {
                            let mid = (lo + hi) >> 1
                            let eOff = edgeOffset + (firstEdge + mid) * 8
                            let midSyl = Self.loadU16(raw, at: eOff)
                            if midSyl == sid {
                                let t = Self.loadU32(raw, at: eOff + 4)
                                matchedTarget = Int(t) < nodeCount ? t : nil
                                break
                            } else if midSyl < sid {
                                lo = mid + 1
                            } else {
                                hi = mid - 1
                            }
                        }
                        if let target = matchedTarget {
                            hits.append(
                                DroppedInitialEdgeHit(
                                    syllableID: sid,
                                    canonical: idToSyllable[sIdx],
                                    targetNode: target,
                                    subtreeScore: maxSubtreeScore(at: target)
                                )
                            )
                        }
                    }
                }
            }
        }
        if hasOverlayAt(nodeIndex) {
            for sid in candidateSIDs {
                let sIdx = Int(sid)
                guard sIdx > 0 && sIdx < rimeBySID.count && rimeBySID[sIdx] == packedRime else { continue }
                if hits.contains(where: { $0.syllableID == sid }) { continue }
                if let target = overlayEdges[(UInt64(nodeIndex) << 16) | UInt64(sid)] {
                    hits.append(
                        DroppedInitialEdgeHit(
                            syllableID: sid,
                            canonical: idToSyllable[sIdx],
                            targetNode: target,
                            subtreeScore: maxSubtreeScore(at: target)
                        )
                    )
                }
            }
        }
        if hits.count > 1 {
            hits.sort {
                if $0.subtreeScore != $1.subtreeScore { return $0.subtreeScore > $1.subtreeScore }
                return $0.syllableID < $1.syllableID
            }
        }
        if hits.count > limit {
            hits.removeSubrange(limit..<hits.count)
        }
        return hits
    }

    // MARK: - Syllable Trie Traversal

    public var rootNodeIndex: UInt32 { 0 }

    @inline(__always)
    public func isExactCanonicalPackedSyllable(_ code: UInt32) -> Bool {
        code != 0 && packedCanonicalSyllableSet.contains(code)
    }

    @inline(__always)
    public func canonicalSyllableID(forPackedCode code: UInt32) -> UInt16? {
        if code < UInt32(shortCanonicalSID.count) {
            let sid = shortCanonicalSID[Int(code)]
            return sid == 0 ? nil : sid
        }
        return packedCodeToSID[code]
    }

    @inline(__always)
    public func hasShortSyllablePrefix(_ code: UInt32) -> Bool {
        code < UInt32(shortSyllablePrefixes.count) ? shortSyllablePrefixes[Int(code)] != 0 : true
    }

    @inline(__always)
    public func isKnownSyllableOrOrthoPacked(_ code: UInt32) -> Bool {
        code != 0 && packedSyllableSet.contains(code)
    }

    @inline(__always)
    public func softClippedSyllableIDs(forPackedCode code: UInt32) -> [UInt16]? {
        code == 0 ? nil : packedSoftClippedToSIDs[code]
    }

    @inline(__always)
    public func canSegmentCleanlyASCII(_ bytes: ArraySlice<UInt8>) -> Bool {
        let count = bytes.count
        guard count >= 1 && count < 64 else { return false }
        return bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return canSegmentCleanlyPointer(base, count: count)
        }
    }

    @inline(__always)
    public func canonicalSyllableIDASCII(_ bytes: ArraySlice<UInt8>) -> UInt16? {
        let count = bytes.count
        guard count >= 1 && count <= 6 else { return nil }
        var code: UInt32 = 0
        for b in bytes {
            guard b >= 0x61 && b <= 0x7A else { return nil }
            code = (code << 5) | UInt32(b - 0x60)
        }
        guard packedCanonicalSyllableSet.contains(code) else { return nil }
        return packedCodeToSID[code]
    }

    /// Binary searches outgoing edges of `nodeIndex` for `syllableID` (`O(1)` direct array lookup at `rootNodeIndex == 0`).
    @inline(__always)
    public func step(from nodeIndex: UInt32, syllableID: UInt16) -> UInt32? {
        if nodeIndex == 0 {
            let s = Int(syllableID)
            guard s > 0 && s < rootTargetBySID.count else { return nil }
            let t = rootTargetBySID[s]
            return t == UInt32.max ? nil : t
        }
        if nodeIndex >= UInt32(nodeCount) {
            return overlayEdges[(UInt64(nodeIndex) << 16) | UInt64(syllableID)]
        }
        let idx = Int(nodeIndex)
        guard idx > 0 && idx < nodeCount else { return nil }
        let raw = rawBuffer
        let nOff = nodeOffset + idx * 16
        let firstEdge = Int(Self.loadU32(raw, at: nOff))
        let eCount = Int(Self.loadU16(raw, at: nOff + 4))
        if eCount > 0, firstEdge + eCount <= edgeCount {
            var lo = 0
            var hi = eCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let eOff = edgeOffset + (firstEdge + mid) * 8
                let midSyl = Self.loadU16(raw, at: eOff)
                if midSyl == syllableID {
                    let target = Self.loadU32(raw, at: eOff + 4)
                    return Int(target) < nodeCount ? target : nil
                } else if midSyl < syllableID {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
        }
        if hasOverlayAt(nodeIndex) {
            return overlayEdges[(UInt64(nodeIndex) << 16) | UInt64(syllableID)]
        }
        return nil
    }

    @inline(__always)
    public func stepWordAndOutgoing(from nodeIndex: UInt32, syllableID: UInt16) -> (next: UInt32, topWordScore: Int?, hasOutgoing: Bool)? {
        if nodeIndex == 0 {
            let s = Int(syllableID)
            guard s > 0 && s < rootTargetBySID.count else { return nil }
            let next = rootTargetBySID[s]
            guard next != UInt32.max else { return nil }
            if !hasOverlayAt(next) {
                let rawScore = rootTopWordScoreBySID[s]
                let topScore: Int? = rawScore == Int32.min ? nil : Int(rawScore)
                return (next, topScore, rootHasOutgoingBySID[s])
            }
        }
        guard let next = step(from: nodeIndex, syllableID: syllableID) else { return nil }
        if next >= UInt32(nodeCount) {
            return (
                next,
                overlayTopScoreByNode[next],
                overlayHasEdgesNodes.contains(next)
            )
        }
        let idx = Int(next)
        guard idx >= 0 && idx < nodeCount else { return nil }
        let raw = rawBuffer
        let nOff = nodeOffset + idx * 16
        let eCount = Self.loadU16(raw, at: nOff + 4)
        let wCount = Self.loadU16(raw, at: nOff + 6)
        var baseOpt: Int? = nil
        if wCount > 0 {
            let firstWord = Int(Self.loadU32(raw, at: nOff + 8))
            if firstWord < wordCount {
                baseOpt = Int(Self.loadI16(raw, at: wordOffset + firstWord * 8 + 6))
            }
        }
        var hasOut = eCount > 0
        if hasOverlayAt(next) {
            if let ov = overlayTopScoreByNode[next] {
                baseOpt = max(baseOpt ?? Int.min, ov)
            }
            if !hasOut && overlayHasEdgesNodes.contains(next) {
                hasOut = true
            }
        }
        return (next, baseOpt, hasOut)
    }

    public struct InitialEdgeHit: Sendable {
        public let syllable: String
        public let targetNode: UInt32
        public let subtreeScore: Int
    }

    /// Returns all cached root-node outgoing edges matching `prefix` (`"m"`, `"w"`, `"zh"`, etc.), pre-sorted by descending `subtreeScore`.
    @inline(__always)
    public func rootInitialHits(prefix: String) -> [InitialEdgeHit] {
        rootEdgesByPrefix[prefix] ?? []
    }

    /// Returns outgoing edges from `nodeIndex` matching `prefix` (`"w"`, `"y"`, `"sh"`, `"zh"`, `"ch"`, etc.),
    /// ordered by descending `maxSubtreeScore` so high-frequency syllables (`you`, `tian`, `shi`, `wo`, `ming`, `zhong`)
    /// are NEVER truncated behind low-frequency alphabetical prefixes (`ya..yin`, `ta..teng`, `sa..seng`).
    public func stepByInitialPrefix(
        from nodeIndex: UInt32,
        prefix: String,
        limit: Int = 12
    ) -> [InitialEdgeHit] {
        guard limit > 0 else { return [] }
        if nodeIndex == 0 {
            guard let cached = rootEdgesByPrefix[prefix] else { return [] }
            return cached.count <= limit ? cached : Array(cached.prefix(limit))
        }

        let idx = Int(nodeIndex)
        guard idx > 0, let initASCII = prefix.utf8.first else { return [] }
        let checkMulti = prefix.utf8.count > 1

        var hits: [InitialEdgeHit] = []
        if idx < nodeCount {
            let raw = rawBuffer
            let nOff = nodeOffset + idx * 16
            let firstEdge = Int(Self.loadU32(raw, at: nOff))
            let eCount = Int(Self.loadU16(raw, at: nOff + 4))
            if eCount > 0 && firstEdge + eCount <= edgeCount {
                // Binary search first edge with `raw[eOff + 2] >= initASCII` (edges are sorted alphabetically by `syllableID`)
                var lo = 0
                var hi = eCount
                while lo < hi {
                    let mid = (lo + hi) >> 1
                    let b = raw[edgeOffset + (firstEdge + mid) * 8 + 2]
                    if b < initASCII {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }

                var i = lo
                while i < eCount {
                    let eOff = edgeOffset + (firstEdge + i) * 8
                    if raw[eOff + 2] != initASCII { break }
                    let sid = Int(Self.loadU16(raw, at: eOff))
                    if sid > 0 && sid < idToSyllable.count {
                        let syl = idToSyllable[sid]
                        if !checkMulti || syl.hasPrefix(prefix) {
                            let target = Self.loadU32(raw, at: eOff + 4)
                            let tIdx = Int(target)
                            let subScore = (tIdx >= 0 && tIdx < nodeCount)
                                ? maxSubtreeScore(at: target)
                                : -32000
                            hits.append(InitialEdgeHit(syllable: syl, targetNode: target, subtreeScore: subScore))
                        }
                    }
                    i += 1
                }
            }
        }
        if hasOverlayAt(nodeIndex), let rootCandidates = rootEdgesByPrefix[prefix] {
            for rc in rootCandidates {
                guard let sid = syllableToID[rc.syllable] else { continue }
                if let target = overlayEdges[(UInt64(nodeIndex) << 16) | UInt64(sid)],
                   !hits.contains(where: { $0.syllable == rc.syllable }) {
                    hits.append(InitialEdgeHit(syllable: rc.syllable, targetNode: target, subtreeScore: maxSubtreeScore(at: target)))
                }
            }
        }

        if hits.count > 1 {
            hits.sort { $0.subtreeScore > $1.subtreeScore }
        }
        if hits.count > limit {
            hits.removeSubrange(limit..<hits.count)
        }
        return hits
    }

    /// Returns all outgoing edges from `nodeIndex` whose syllable starts with `initialASCII` (`'a'...'z'`).
    public func stepByInitial(from nodeIndex: UInt32, initialASCII: UInt8) -> [UInt32] {
        let idx = Int(nodeIndex)
        guard idx >= 0 && idx < nodeCount else { return [] }
        let raw = rawBuffer
        let nOff = nodeOffset + idx * 16
        let firstEdge = Int(Self.loadU32(raw, at: nOff))
        let eCount = Int(Self.loadU16(raw, at: nOff + 4))
        guard eCount > 0, firstEdge + eCount <= edgeCount else { return [] }

        var targets: [UInt32] = []
        for i in 0..<eCount {
            let eOff = edgeOffset + (firstEdge + i) * 8
            if raw[eOff + 2] == initialASCII {
                let target = Self.loadU32(raw, at: eOff + 4)
                if Int(target) < nodeCount { targets.append(target) }
            }
        }
        return targets
    }

    @inline(__always)
    public func hasOutgoingEdges(at nodeIndex: UInt32) -> Bool {
        if nodeIndex >= UInt32(nodeCount) {
            return overlayHasEdgesNodes.contains(nodeIndex)
        }
        let idx = Int(nodeIndex)
        guard idx >= 0 && idx < nodeCount else { return false }
        if Self.loadU16(rawBuffer, at: nodeOffset + idx * 16 + 4) > 0 { return true }
        return hasOverlayAt(nodeIndex) && overlayHasEdgesNodes.contains(nodeIndex)
    }

    @inline(__always)
    public func maxSubtreeScore(at nodeIndex: UInt32) -> Int {
        if nodeIndex >= UInt32(nodeCount) {
            return overlaySubtreeByNode[nodeIndex] ?? -32000
        }
        let idx = Int(nodeIndex)
        guard idx >= 0 && idx < nodeCount else { return -32000 }
        let base = Int(Self.loadI16(rawBuffer, at: nodeOffset + idx * 16 + 12))
        if hasOverlayAt(nodeIndex), let ov = overlaySubtreeByNode[nodeIndex] {
            return max(base, ov)
        }
        return base
    }

    /// Reads the top word's `scoreQ8` at `nodeIndex` in O(1) without allocating `WordHit` arrays or UTF-8 `String`s.
    @inline(__always)
    public func topWordScore(at nodeIndex: UInt32) -> Int? {
        if nodeIndex >= UInt32(nodeCount) {
            return overlayTopScoreByNode[nodeIndex]
        }
        let idx = Int(nodeIndex)
        guard idx >= 0 && idx < nodeCount else { return nil }
        let raw = rawBuffer
        let nOff = nodeOffset + idx * 16
        var baseOpt: Int? = nil
        if Self.loadU16(raw, at: nOff + 6) > 0 {
            let firstWord = Int(Self.loadU32(raw, at: nOff + 8))
            if firstWord < wordCount {
                baseOpt = Int(Self.loadI16(raw, at: wordOffset + firstWord * 8 + 6))
            }
        }
        if hasOverlayAt(nodeIndex), let ov = overlayTopScoreByNode[nodeIndex] {
            return max(baseOpt ?? Int.min, ov)
        }
        return baseOpt
    }

    /// Complete a frequent compound across one omitted syllable using two consecutive trie edges.
    func skippedSyllableWords(from node: UInt32, followedBy next: UInt16) -> [(String, WordHit)] {
        let idx = Int(node)
        guard idx > 0, idx < nodeCount else { return [] }
        let raw = rawBuffer
        let off = nodeOffset + idx * 16
        let first = Int(Self.loadU32(raw, at: off))
        let count = Int(Self.loadU16(raw, at: off + 4))
        guard count > 0, count <= 64, first + count <= edgeCount else { return [] }
        var matches: [(String, WordHit)] = []
        for i in first..<(first + count) {
            let edge = edgeOffset + i * 8
            let sid = Int(Self.loadU16(raw, at: edge))
            let child = Self.loadU32(raw, at: edge + 4)
            guard sid > 0, sid < idToSyllable.count, child != rootNodeIndex,
                  maxSubtreeScore(at: child) >= -2800,
                  let end = step(from: child, syllableID: next),
                  let score = topWordScore(at: end), score >= -2800,
                  let word = words(at: end, limit: 1).first else { continue }
            matches.append((idToSyllable[sid], word))
        }
        return matches
    }

    private static let nonBMPCJKPenaltyQ8 = 1800

    @inline(__always)
    private static func containsNonBMPUTF8(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int) -> Bool {
        guard offset >= 0, length > 0, offset + length <= raw.count else { return false }
        for i in offset..<(offset + length) {
            if raw[i] >= 0xF0 {
                return true
            }
        }
        return false
    }

    /// Reads up to `limit` words stored directly at `nodeIndex` (already pre-sorted by descending `scoreQ8`,
    /// demoting rare non-BMP CJK Ext-B..G entries below normal BMP characters).
    public func words(at nodeIndex: UInt32, limit: Int = 24) -> [WordHit] {
        guard limit > 0 else { return [] }
        if nodeIndex >= UInt32(nodeCount) {
            guard let ov = overlayWordsByNode[nodeIndex] else { return [] }
            return ov.count <= limit ? ov : Array(ov.prefix(limit))
        }
        let idx = Int(nodeIndex)
        guard idx >= 0 && idx < nodeCount else { return [] }
        let raw = rawBuffer
        let nOff = nodeOffset + idx * 16
        let totalWCount = Int(Self.loadU16(raw, at: nOff + 6))
        let wCount = min(limit, totalWCount)
        var hits: [WordHit] = []
        if wCount > 0 {
            let firstWord = Int(Self.loadU32(raw, at: nOff + 8))
            if firstWord + totalWCount <= wordCount {
                hits.reserveCapacity(wCount + 2)
                var hasNonBMP = false
                for i in 0..<wCount {
                    let wOff = wordOffset + (firstWord + i) * 8
                    let sOff = Int(Self.loadU32(raw, at: wOff))
                    let sLen = Int(Self.loadU16(raw, at: wOff + 4))
                    var score = Int(Self.loadI16(raw, at: wOff + 6))
                    let inPool = sOff >= 0 && sLen > 0 && sOff <= stringPoolSize && sLen <= stringPoolSize - sOff
                    let nonBMP = inPool && Self.containsNonBMPUTF8(raw, offset: stringPoolOffset + sOff, length: sLen)
                    if nonBMP {
                        hasNonBMP = true
                        score -= Self.nonBMPCJKPenaltyQ8
                    }
                    if inPool, let text = readPoolString(raw, offset: sOff, length: sLen) {
                        hits.append(WordHit(text: text, scoreQ8: score))
                    }
                }
                if hasNonBMP {
                    let extraEnd = min(totalWCount, wCount + 8)
                    if extraEnd > wCount {
                        for i in wCount..<extraEnd {
                            let wOff = wordOffset + (firstWord + i) * 8
                            let sOff = Int(Self.loadU32(raw, at: wOff))
                            let sLen = Int(Self.loadU16(raw, at: wOff + 4))
                            var score = Int(Self.loadI16(raw, at: wOff + 6))
                            let inPool = sOff >= 0 && sLen > 0 && sOff <= stringPoolSize && sLen <= stringPoolSize - sOff
                            if inPool && Self.containsNonBMPUTF8(raw, offset: stringPoolOffset + sOff, length: sLen) {
                                score -= Self.nonBMPCJKPenaltyQ8
                            }
                            if inPool, let text = readPoolString(raw, offset: sOff, length: sLen) {
                                hits.append(WordHit(text: text, scoreQ8: score))
                            }
                        }
                    }
                    var indexed = hits.enumerated().map { ($0.offset, $0.element) }
                    indexed.sort { a, b in
                        if a.1.scoreQ8 != b.1.scoreQ8 { return a.1.scoreQ8 > b.1.scoreQ8 }
                        return a.0 < b.0
                    }
                    hits = indexed.prefix(limit).map(\.1)
                }
            }
        }
        if hasOverlayAt(nodeIndex), let ovWords = overlayWordsByNode[nodeIndex], !ovWords.isEmpty {
            var merged = ovWords + hits
            merged.sort { $0.scoreQ8 > $1.scoreQ8 }
            var dedup: [WordHit] = []
            dedup.reserveCapacity(min(limit, merged.count))
            var seen = Set<String>()
            for item in merged where seen.insert(item.text).inserted {
                dedup.append(item)
                if dedup.count >= limit { break }
            }
            return dedup
        }
        return hits
    }

    // MARK: - Jianpin (First-Letter Acronym) O(log N) Lookup

    struct MixedMatch {
        let word: WordHit
        let syllables: [String]
        let rankScore: Int
    }

    /// Retrieve complete readings with a spelled syllable at either edge.
    /// Precompiled multiword paths and single dictionary words share the same cost units.
    func mixedInitialMatches(_ input: String) -> [MixedMatch] {
        let bytes = Array(input.utf8)
        guard (3...14).contains(bytes.count) else { return [] }
        let consonants = "bcdfghjklmnpqrstvwxyz".utf8
        let limit = 6, particleBonus = 360
        var best = [MixedMatch]()
        func record(_ word: WordHit, _ syllables: [String]) {
            let particle = word.text.hasSuffix("吗") || word.text.hasSuffix("吧")
            let rank = word.scoreQ8 + (particle ? particleBonus : 0)
            if best.count == limit && rank < best[limit - 1].rankScore { return }
            if let old = best.firstIndex(where: { $0.word.text == word.text }) {
                if best[old].rankScore >= rank { return }
                best.remove(at: old)
            }
            let index = best.firstIndex { rank > $0.rankScore || (rank == $0.rankScore && word.text < $0.word.text) } ?? best.count
            best.insert(MixedMatch(word: word, syllables: syllables, rankScore: rank), at: index)
            if best.count > limit { best.removeLast() }
        }
        func includeIndex(_ prefix: String) {
            for hit in lookupAssociations(after: prefix + input, limit: 8) {
                let entry = hit.text.split(separator: "|", maxSplits: 1)
                guard entry.count == 2 else { continue }
                let syllables = entry[1].split(separator: " ").map(String.init)
                record(WordHit(text: String(entry[0]), scoreQ8: hit.scoreQ8), syllables)
            }
        }
        // Leading initials can include a vowel (e.g. an / er). `:` keys have exact form
        // `:` + 2..7 initials + full canonical final syllable (must contain a vowel in last 4 bytes and end in vowel/n/g/r).
        if let tailB = bytes.last,
           (tailB == 0x61 || tailB == 0x65 || tailB == 0x69 || tailB == 0x6F || tailB == 0x75 || tailB == 0x76
            || tailB == 0x6E || tailB == 0x67 || tailB == 0x72),
           bytes.suffix(4).contains(where: { $0 == 0x61 || $0 == 0x65 || $0 == 0x69 || $0 == 0x6F || $0 == 0x75 || $0 == 0x76 }) {
            includeIndex(":")
        }
        var start = bytes.count
        while start > 0 && consonants.contains(bytes[start - 1]) { start -= 1 }
        guard bytes.count - start >= 2 else { return best }
        if bytes.count - start == 2 && (bytes[start] == 0x7A || bytes[start] == 0x63 || bytes[start] == 0x73) && bytes[start + 1] == 0x68 {
            return best
        }
        let first = max(2, start), last = min(7, bytes.count - 2)
        guard first <= last else { return best }
        let validSplits = (first...last).compactMap { split -> (Int, UInt16)? in
            guard let sid = canonicalSyllableIDASCII(bytes[..<split]) else { return nil }
            return (split, sid)
        }
        guard !validSplits.isEmpty else { return best }

        includeIndex("!")
        var path: [String] = []
        func visit(_ node: UInt32, _ offset: Int) {
            if offset == bytes.count {
                if path.count >= 3 {
                    for hit in words(at: node, limit: 4) { record(hit, path) }
                }
                return
            }
            guard path.count < 8 else { return }
            for width in 1...min(2, bytes.count - offset) {
                let prefix = String(decoding: bytes[offset..<offset + width], as: UTF8.self)
                if width == 2 && prefix != "zh" && prefix != "ch" && prefix != "sh" { continue }
                for hit in stepByInitialPrefix(from: node, prefix: prefix, limit: 24) {
                    if best.count == limit && hit.subtreeScore + particleBonus < best[limit - 1].rankScore { continue }
                    path.append(hit.syllable)
                    visit(hit.targetNode, offset + width)
                    path.removeLast()
                }
            }
        }
        for (split, sid) in validSplits {
            guard let node = step(from: 0, syllableID: sid) else { continue }
            path = [String(decoding: bytes[..<split], as: UTF8.self)]
            visit(node, split)
        }
        return best
    }

    /// Folds 2-letter retroflex Pinyin initials (`zh -> z`, `ch -> c`, `sh -> s`) inside Jianpin strings
    /// (`mshmwt -> msmwt`, `shm -> sm`, `wshm -> wsm`, `shrf -> srf`, `zhd -> zd`, `chf -> cf`).
    public static func foldRetroflexJianpin(_ input: String) -> String? {
        guard input.utf8.count >= 3, input.utf8.contains(where: { $0 == 0x68 || $0 == 0x48 }) else { return nil }
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        var didFold = false
        while i < bytes.count {
            let b = (bytes[i] >= 0x41 && bytes[i] <= 0x5A) ? (bytes[i] | 0x20) : bytes[i]
            if i + 1 < bytes.count {
                let nextB = (bytes[i + 1] >= 0x41 && bytes[i + 1] <= 0x5A) ? (bytes[i + 1] | 0x20) : bytes[i + 1]
                if nextB == 0x68 && (b == 0x7A || b == 0x63 || b == 0x73) {
                    out.append(b)
                    didFold = true
                    i += 2
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        guard didFold, out.count >= 2 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    public struct JianpinHit: Sendable {
        public let hit: WordHit
        public let isExact: Bool
    }

    @inline(__always)
    private func hasJianpinPrefixUTF8(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = buf.count
        guard count >= 2 else { return false }
        let r0 = (buf[0] >= 0x41 && buf[0] <= 0x5A) ? (buf[0] | 0x20) : buf[0]
        let r1 = (buf[1] >= 0x41 && buf[1] <= 0x5A) ? (buf[1] | 0x20) : buf[1]
        guard r0 >= 0x61 && r0 <= 0x7A && r1 >= 0x61 && r1 <= 0x7A else { return false }
        let idx2 = Int(r0 - 0x61) * 26 + Int(r1 - 0x61)
        if count == 2 {
            return (jpPrefix2Bitset[idx2 >> 6] & (UInt64(1) &<< (idx2 & 63))) != 0
        }
        let r2 = (buf[2] >= 0x41 && buf[2] <= 0x5A) ? (buf[2] | 0x20) : buf[2]
        guard r2 >= 0x61 && r2 <= 0x7A else { return true }
        let idx3 = idx2 * 26 + Int(r2 - 0x61)
        if (jpPrefix3Bitset[idx3 >> 6] & (UInt64(1) &<< (idx3 & 63))) != 0 {
            return true
        }
        let scanMax = min(6, count)
        var hasH = false
        for i in 0..<scanMax {
            let b = (buf[i] >= 0x41 && buf[i] <= 0x5A) ? (buf[i] | 0x20) : buf[i]
            if b < 0x61 || b > 0x7A { return true }
            if b == 0x68 { hasH = true }
        }
        guard hasH else { return false }
        var f0: UInt8 = 0, f1: UInt8 = 0, f2: UInt8 = 0
        var fCount = 0
        var i = 0
        var didFold = false
        while i < scanMax && fCount < 3 {
            let b = (buf[i] >= 0x41 && buf[i] <= 0x5A) ? (buf[i] | 0x20) : buf[i]
            if i + 1 < count {
                let nb = (buf[i + 1] >= 0x41 && buf[i + 1] <= 0x5A) ? (buf[i + 1] | 0x20) : buf[i + 1]
                if nb == 0x68 && (b == 0x7A || b == 0x63 || b == 0x73) {
                    switch fCount {
                    case 0: f0 = b
                    case 1: f1 = b
                    default: f2 = b
                    }
                    fCount += 1
                    didFold = true
                    i += 2
                    continue
                }
            }
            switch fCount {
            case 0: f0 = b
            case 1: f1 = b
            default: f2 = b
            }
            fCount += 1
            i += 1
        }
        guard didFold && fCount >= 2 else { return false }
        let fIdx2 = Int(f0 - 0x61) * 26 + Int(f1 - 0x61)
        if fCount == 2 {
            return (jpPrefix2Bitset[fIdx2 >> 6] & (UInt64(1) &<< (fIdx2 & 63))) != 0
        }
        let fIdx3 = fIdx2 * 26 + Int(f2 - 0x61)
        return (jpPrefix3Bitset[fIdx3 >> 6] & (UInt64(1) &<< (fIdx3 & 63))) != 0
    }

    /// Looks up multi-character phrases whose first-letter Pinyin initials equal `acronym` (2...8 lowercase letters).
    public func lookupJianpin(_ acronym: String, allowPrefix: Bool = false, limit: Int = 12) -> [WordHit] {
        lookupJianpinWithExactFlag(acronym, allowPrefix: allowPrefix, limit: limit).map(\.hit)
    }

    /// Single-pass Jianpin lookup returning whether each hit matched the exact acronym (`isExact`) or a prefix extension.
    public func lookupJianpinWithExactFlag(_ acronym: String, allowPrefix: Bool = false, limit: Int = 12) -> [JianpinHit] {
        guard limit > 0 else { return [] }
        var probe = acronym
        let prefixPossible = probe.withUTF8 { hasJianpinPrefixUTF8($0) }
        guard prefixPossible else { return [] }
        let lowerAcronym = acronym.lowercased()
        struct RawJpHit {
            let sOff: Int
            let sLen: Int
            let directText: String?
            let scoreQ8: Int
            let isExact: Bool
        }
        var hits: [RawJpHit] = []
        hits.reserveCapacity(32)
        let raw = rawBuffer

        func appendRawJianpinQuery(_ keyStr: String, penalty: Int) {
            if let ovHits = overlayJianpinMap[keyStr] {
                for ov in ovHits {
                    hits.append(RawJpHit(sOff: 0, sLen: 0, directText: ov.text, scoreQ8: ov.scoreQ8 - penalty, isExact: true))
                }
            }
            if allowPrefix, keyStr.count < 8 {
                for (k, ovHits) in overlayJianpinMap where k.count > keyStr.count && k.hasPrefix(keyStr) {
                    for ov in ovHits {
                        hits.append(RawJpHit(sOff: 0, sLen: 0, directText: ov.text, scoreQ8: ov.scoreQ8 - 220 - penalty, isExact: false))
                    }
                }
            }
            guard jianpinCount > 0 else { return }
            var exactKey: UInt64 = 0
            var count = 0
            for b in keyStr.utf8 {
                guard b >= 0x61 && b <= 0x7A && count < 8 else { return }
                exactKey |= UInt64(b) << ((7 - count) * 8)
                count += 1
            }
            guard count >= 2 else { return }

            let upperKey: UInt64
            if allowPrefix && count < 8 {
                var mask: UInt64 = 0
                for i in count..<8 {
                    mask |= UInt64(0xFF) << ((7 - i) * 8)
                }
                upperKey = exactKey | mask
            } else {
                upperKey = exactKey
            }

            var lo = 0
            var hi = jianpinCount
            while lo < hi {
                let mid = (lo + hi) >> 1
                let midKey = Self.loadU64BE(raw, at: jianpinOffset + mid * 16)
                if midKey < exactKey {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            var cursor = lo
            let maxScan = min(jianpinCount, lo + 96)
            while cursor < maxScan {
                let recOff = jianpinOffset + cursor * 16
                let recKey = Self.loadU64BE(raw, at: recOff)
                if recKey > upperKey { break }
                let sOff = Int(Self.loadU32(raw, at: recOff + 8))
                let sLen = Int(Self.loadU16(raw, at: recOff + 12))
                let isExact = (recKey == exactKey)
                let rawScore = Int(Self.loadI16(raw, at: recOff + 14))
                let adjusted = (isExact ? rawScore : (rawScore - 220)) - penalty
                hits.append(RawJpHit(sOff: sOff, sLen: sLen, directText: nil, scoreQ8: adjusted, isExact: isExact))
                cursor += 1
            }
        }

        appendRawJianpinQuery(lowerAcronym, penalty: 0)
        if let folded = Self.foldRetroflexJianpin(lowerAcronym) {
            appendRawJianpinQuery(folded, penalty: 40)
        }

        guard !hits.isEmpty else { return [] }
        hits.sort {
            if $0.isExact != $1.isExact { return $0.isExact && !$1.isExact }
            return $0.scoreQ8 > $1.scoreQ8
        }
        var dedup: [JianpinHit] = []
        dedup.reserveCapacity(min(limit, hits.count))
        var seen = Set<String>()
        for h in hits {
            guard let text = h.directText ?? readPoolString(raw, offset: h.sOff, length: h.sLen) else { continue }
            if seen.insert(text).inserted {
                dedup.append(JianpinHit(hit: WordHit(text: text, scoreQ8: h.scoreQ8), isExact: h.isExact))
                if dedup.count >= limit { break }
            }
        }
        return dedup
    }

    private func buildNativeParityOverlay() {
        let overlayEntries: [([String], String, Int)] = [
            // Everyday modern & domain vocabulary
            (["lou", "jian"], "漏键", -1720),
            (["ti", "gan"], "体感", -1720),
            (["duan", "ci"], "短词", -1860),
            (["zhong", "chang", "ju"], "中长句", -1840),
            (["da", "li"], "大力", -1760),
            (["da", "li"], "大理", -1820),
            (["yi", "jie", "jue"], "已解决", -1880),
            (["shou", "dao", "le"], "收到了", -1820),
            (["xin", "ban", "le"], "新版了", -1820),
            (["ji", "zhi"], "极致", -1860),
            (["zuo", "tian"], "昨天", -1660),
            (["er", "wei", "ma"], "二维码", -1720),
            (["duan", "chu"], "断触", -1960),
            (["wu", "chu"], "误触", -1960),
            (["diao", "zhen"], "掉帧", -1960),
            (["gen", "shou"], "跟手", -1980),
            (["e", "le"], "饿了", -1780),
            (["xi", "zao"], "洗澡", -1780),
            (["xi", "zao", "le"], "洗澡了", -1840),
            (["de", "kuai"], "得快", -1920),
            (["de", "hao"], "得好", -1920),
            (["de", "man"], "得慢", -1940),
            (["ji", "dian", "zhong"], "几点钟", -1720),
            (["er", "shi"], "二十", -1680),
            (["er", "shi", "fen", "zhong"], "二十分钟", -1680),
            (["shi", "fen", "zhong"], "十分钟", -1700),
            (["san", "shi", "fen", "zhong"], "三十分钟", -1700),
            // Preverbal "先" & conversational phrases
            (["wo", "xian"], "我先", -2380),
            (["ni", "xian"], "你先", -2100),
            (["xian", "fa"], "先发", -1960),
            (["xian", "mang"], "先忙", -2020),
            (["xian", "qu"], "先去", -2020),
            (["xian", "kan"], "先看", -2040),
            (["xian", "hui"], "先回", -2080),
            (["xian", "zou"], "先走", -2060),
            // Conversational reply & directional compounds
            (["hui", "ni"], "回你", -1880),
            (["hui", "wo"], "回我", -1960),
            (["zai", "hui", "ni"], "再回你", -1840),
            (["zhi", "neng", "hao"], "只能好", -1880),
            (["bu", "neng", "cha"], "不能差", -1880),
            (["fa", "guo", "lai"], "发过来", -1800),
            (["fa", "guo", "qu"], "发过去", -1860),
            (["na", "guo", "lai"], "拿过来", -1920),
            (["dai", "guo", "lai"], "带过来", -1940),
            (["chuan", "guo", "lai"], "传过来", -1960),
            (["ji", "guo", "lai"], "寄过来", -1960),
            (["zou", "guo", "lai"], "走过来", -1920),
            // Native Mandarin colloquial Erhua (-r) & temporal clock phrases
            (["yi", "hui", "er"], "一会儿", -1760),
            (["guo", "yi", "hui", "er"], "过一会儿", -1680),
            (["yi", "dian", "er"], "一点儿", -1800),
            (["qu", "na", "er"], "去哪儿", -1820),
            (["zai", "na", "er"], "在哪儿", -1840),
            (["zhe", "er"], "这儿", -1860),
            (["na", "er"], "哪儿", -1840),
            (["na", "er"], "那儿", -1880),
            (["wan", "er"], "玩儿", -1880),
            (["mei", "shi", "er"], "没事儿", -1860),
            (["hao", "wan", "er"], "好玩儿", -1900),
            (["liao", "tian", "er"], "聊天儿", -1900),
            (["yi", "kuai", "er"], "一块儿", -1880),
            (["jiu", "dian"], "九点", -1720),
            (["ba", "dian"], "八点", -1740),
            (["qi", "dian"], "七点", -1760),
            (["shi", "dian"], "十点", -1740),
            (["liu", "dian"], "六点", -1780),
            (["wu", "dian"], "五点", -1780),
            (["san", "dian"], "三点", -1760),
            (["liang", "dian"], "两点", -1760),
            // High-frequency colloquial spoken expressions & idioms
            (["suan", "le"], "算了", -1620),
            (["zou", "ba"], "走吧", -1620),
            (["jian", "ba"], "见吧", -1680),
            (["xing", "ba"], "行吧", -1680),
            (["dui", "ma"], "对吗", -1660),
            (["gei", "ji", "bai", "nian"], "给鸡拜年", -1980),
            (["huang", "shu", "lang", "gei", "ji", "bai", "nian"], "黄鼠狼给鸡拜年", -1920),
            (["jiu", "fan"], "就烦", -2080),
            (["shui", "hui"], "睡会", -2220),
            (["shui", "hui", "ba"], "睡会吧", -2120),
            (["ni", "shui", "hui", "ba"], "你睡会吧", -1920),
            (["ni", "ye", "shui", "hui", "ba"], "你也睡会吧", -2000),
        ]

        overlayNodeBits = [UInt8](repeating: 0, count: (max(1, nodeCount) + 256 + 7) >> 3)
        var nextVirtualNode = UInt32(max(1, nodeCount))
        for (syls, text, score) in overlayEntries {
            let sids = syls.compactMap { syllableToID[$0] }
            guard sids.count == syls.count, !sids.isEmpty else { continue }
            var cur: UInt32 = 0
            var visited: [UInt32] = []
            for (idx, sid) in sids.enumerated() {
                if idx > 0 {
                    overlayHasEdgesNodes.insert(cur)
                    markOverlayAt(cur)
                }
                if let next = step(from: cur, syllableID: sid) {
                    cur = next
                } else {
                    let key = (UInt64(cur) << 16) | UInt64(sid)
                    let created = nextVirtualNode
                    nextVirtualNode += 1
                    overlayEdges[key] = created
                    markOverlayAt(cur)
                    cur = created
                }
                visited.append(cur)
            }
            markOverlayAt(cur)
            var list = overlayWordsByNode[cur] ?? []
            if !list.contains(where: { $0.text == text }) {
                list.append(WordHit(text: text, scoreQ8: score))
                list.sort { $0.scoreQ8 > $1.scoreQ8 }
                overlayWordsByNode[cur] = list
            }
            overlayTopScoreByNode[cur] = max(overlayTopScoreByNode[cur] ?? Int.min, score)
            if sids.count == 1 {
                let sIdx = Int(sids[0])
                if sIdx > 0 && sIdx < topOneSyllableWordBySID.count {
                    let prevScore = topOneSyllableWordBySID[sIdx]?.scoreQ8 ?? Int.min
                    if score > prevScore {
                        topOneSyllableWordBySID[sIdx] = WordHit(text: text, scoreQ8: score)
                    }
                }
            }
            for node in visited {
                overlaySubtreeByNode[node] = max(overlaySubtreeByNode[node] ?? Int.min, score)
                markOverlayAt(node)
            }
            let firstSID = Int(sids[0])
            if firstSID > 0 && firstSID < syllableBestScores.count && score > syllableBestScores[firstSID] {
                syllableBestScores[firstSID] = score
            }
        }

        overlayJianpinMap = [
            "nh": [("你好", ["ni", "hao"], -1420)],
            "xxn": [("谢谢你", ["xie", "xie", "ni"], -1480)],
            "bj": [("北京", ["bei", "jing"], -1520), ("比较", ["bi", "jiao"], -1560), ("编辑", ["bian", "ji"], -1720)],
            "ewm": [("二维码", ["er", "wei", "ma"], -1560)],
            "msmwt": [("没什么问题", ["mei", "shen", "me", "wen", "ti"], -1580)],
            "hbhkd": [("会不会卡顿", ["hui", "bu", "hui", "ka", "dun"], -1620)],
            "znhbnc": [("只能好不能差", ["zhi", "neng", "hao", "bu", "neng", "cha"], -1660)],
            "znmy": [("怎么样", ["zen", "me", "yang"], -1600)],
            "znm": [("怎么", ["zen", "me"], -1600)],
            "yj": [("已经", ["yi", "jing"], -1580)],
            "jt": [("今天", ["jin", "tian"], -1560)],
            "mt": [("明天", ["ming", "tian"], -1580)],
            "zt": [("昨天", ["zuo", "tian"], -1640)],
            "jtxw": [("今天下午", ["jin", "tian", "xia", "wu"], -1600)],
            "mtxw": [("明天下午", ["ming", "tian", "xia", "wu"], -1620)],
            "mtzs": [("明天早上", ["ming", "tian", "zao", "shang"], -1660)],
            "jtws": [("今天晚上", ["jin", "tian", "wan", "shang"], -1640)],
            "mtws": [("明天晚上", ["ming", "tian", "wan", "shang"], -1660)],
            "zgsrf": [("这个输入法", ["zhe", "ge", "shu", "ru", "fa"], -1660)],
            "srf": [("输入法", ["shu", "ru", "fa"], -1600)],
            "wsm": [("为什么", ["wei", "shen", "me"], -1560)],
            "sm": [("什么", ["shen", "me"], -1540)],
            "zm": [("怎么", ["zen", "me"], -1560)],
            "zmy": [("怎么样", ["zen", "me", "yang"], -1580)],
            "zmb": [("怎么办", ["zen", "me", "ban"], -1580)],
            "bhys": [("不好意思", ["bu", "hao", "yi", "si"], -1580)],
            "mwt": [("没问题", ["mei", "wen", "ti"], -1600)],
            "bzd": [("不知道", ["bu", "zhi", "dao"], -1600)],
            "zd": [("知道", ["zhi", "dao"], -1600), ("真的", ["zhen", "de"], -1660)],
            "jd": [("觉得", ["jue", "de"], -1600), ("简单", ["jian", "dan"], -1760)],
            "cf": [("吃饭", ["chi", "fan"], -1620)],
            // Reduplicated tentative & conversational action verbs
            "ss": [("试试", ["shi", "shi"], -1540), ("说说", ["shuo", "shuo"], -1820), ("算算", ["suan", "suan"], -1940)],
            "ssb": [("试试吧", ["shi", "shi", "ba"], -1620), ("说说吧", ["shuo", "shuo", "ba"], -1880)],
            "kk": [("看看", ["kan", "kan"], -1540)],
            "kkb": [("看看吧", ["kan", "kan", "ba"], -1620)],
            "xx": [("想想", ["xiang", "xiang"], -1560), ("谢谢", ["xie", "xie"], -1640), ("学习", ["xue", "xi"], -1680)],
            "xxb": [("想想吧", ["xiang", "xiang", "ba"], -1640)],
            "dd": [("等等", ["deng", "deng"], -1560)],
            "ddb": [("等等吧", ["deng", "deng", "ba"], -1640)],
            "ll": [("聊聊", ["liao", "liao"], -1620), ("来了", ["lai", "le"], -1700)],
            "llb": [("聊聊吧", ["liao", "liao", "ba"], -1680)],
            "zz": [("走走", ["zou", "zou"], -1660), ("正在", ["zheng", "zai"], -1720)],
            "zzb": [("走走吧", ["zou", "zou", "ba"], -1680)],
            // Colloquial quantifiers, modals, pronouns & clause tails
            "yx": [("一下", ["yi", "xia"], -1540), ("一些", ["yi", "xie"], -1640), ("游戏", ["you", "xi"], -1680)],
            "yxb": [("一下吧", ["yi", "xia", "ba"], -1640)],
            "yd": [("一点", ["yi", "dian"], -1580), ("有点", ["you", "dian"], -1660), ("一定", ["yi", "ding"], -1700)],
            "yh": [("一会", ["yi", "hui"], -1640), ("以后", ["yi", "hou"], -1660)],
            "yhr": [("一会儿", ["yi", "hui", "er"], -1640)],
            "ky": [("可以", ["ke", "yi"], -1500)],
            "kym": [("可以吗", ["ke", "yi", "ma"], -1580)],
            "bky": [("不可以", ["bu", "ke", "yi"], -1640)],
            "xh": [("喜欢", ["xi", "huan"], -1580)],
            "bxh": [("不喜欢", ["bu", "xi", "huan"], -1660)],
            "xy": [("需要", ["xu", "yao"], -1560), ("想要", ["xiang", "yao"], -1620)],
            "bxy": [("不需要", ["bu", "xu", "yao"], -1660)],
            "zb": [("走吧", ["zou", "ba"], -1560), ("准备", ["zhun", "bei"], -1640)],
            "sl": [("算了", ["suan", "le"], -1560), ("说了", ["shuo", "le"], -1740)],
            "slb": [("算了吧", ["suan", "le", "ba"], -1600)],
            "wm": [("我们", ["wo", "men"], -1480)],
            "nm": [("你们", ["ni", "men"], -1580), ("那么", ["na", "me"], -1600)],
            "tm": [("他们", ["ta", "men"], -1560)],
            "my": [("没有", ["mei", "you"], -1520)],
            "ymy": [("有没有", ["you", "mei", "you"], -1600)],
            "hmy": [("还没有", ["hai", "mei", "you"], -1640)],
            "sbs": [("是不是", ["shi", "bu", "shi"], -1580)],
            "hbh": [("好不好", ["hao", "bu", "hao"], -1620), ("会不会", ["hui", "bu", "hui"], -1640)],
            "yb": [("要不", ["yao", "bu"], -1620), ("一般", ["yi", "ban"], -1640)],
            "lm": [("了吗", ["le", "ma"], -1560), ("里面", ["li", "mian"], -1690)],
            "jb": [("见吧", ["jian", "ba"], -1620), ("基本", ["ji", "ben"], -1690), ("加班", ["jia", "ban"], -1740)],
            "sb": [("随便", ["sui", "bian"], -1620), ("识别", ["shi", "bie"], -1650), ("是吧", ["shi", "ba"], -1680), ("设备", ["she", "bei"], -1720)],
            "wd": [("我的", ["wo", "de"], -1560)],
            "nd": [("你的", ["ni", "de"], -1620)],
            "td": [("他的", ["ta", "de"], -1640)],
            "ys": [("意思", ["yi", "si"], -1620), ("也是", ["ye", "shi"], -1660)],
            "smys": [("什么意思", ["shen", "me", "yi", "si"], -1580)],
            "hd": [("好的", ["hao", "de"], -1560)],
            "hdb": [("好的吧", ["hao", "de", "ba"], -1620)],
            "lk": [("来看", ["lai", "kan"], -1660)],
            "kb": [("看吧", ["kan", "ba"], -1660)],
            "mgx": [("没关系", ["mei", "guan", "xi"], -1620)],
            "bkq": [("不客气", ["bu", "ke", "qi"], -1640)],
        ]
        var leadMask: UInt32 = 0
        for k in overlayJianpinMap.keys {
            if let b = k.utf8.first, b >= 0x61 && b <= 0x7A {
                leadMask |= (1 &<< (b - 0x61))
            }
        }
        overlayJianpinLeadMask = leadMask

        // Precompute O(1) frequency-ranked 1-initial monosyllables (including closed-class spoken particles,
        // pronouns, negators, and core motion/action verbs that subtreeScore ranking can bury under compounds).
        let guaranteedMonosyllables: [String: [(String, String, Int)]] = [
            "a": [("啊", "a", -1520)],
            "b": [("吧", "ba", -1470), ("不", "bu", -1600), ("把", "ba", -1502), ("被", "bei", -1470)],
            "c": [("吃", "chi", -1820), ("从", "cong", -1404), ("才", "cai", -1737), ("出", "chu", -1899)],
            "ch": [("吃", "chi", -1820), ("出", "chu", -1899)],
            "d": [("的", "de", -600), ("等", "deng", -1413), ("对", "dui", -1327), ("都", "dou", -1416), ("到", "dao", -1459)],
            "g": [("个", "ge", -1548), ("给", "gei", -1579), ("过", "guo", -1700), ("更", "geng", -1668)],
            "h": [("好", "hao", -1580), ("很", "hen", -1720), ("和", "he", -1041), ("会", "hui", -1455), ("还", "hai", -1558)],
            "j": [("就", "jiu", -1314), ("见", "jian", -1880), ("去", "qu", -32000)],
            "k": [("看", "kan", -1580), ("可", "ke", -1716), ("快", "kuai", -1920)],
            "l": [("了", "le", -1082), ("来", "lai", -1470), ("啦", "la", -1820), ("里", "li", -1498)],
            "m": [("吗", "ma", -1540), ("么", "me", -1820), ("没", "mei", -1780), ("买", "mai", -1801)],
            "n": [("你", "ni", -1365), ("呢", "ne", -1505), ("那", "na", -1578), ("拿", "na", -1882), ("能", "neng", -1533)],
            "q": [("去", "qu", -1451), ("请", "qing", -1880), ("起", "qi", -2036)],
            "r": [("人", "ren", -1383), ("让", "rang", -1599)],
            "s": [("是", "shi", -1077), ("说", "shuo", -1500), ("上", "shang", -1409), ("三", "san", -1626), ("算", "suan", -1920)],
            "sh": [("是", "shi", -1077), ("说", "shuo", -1500), ("上", "shang", -1409), ("谁", "shui", -2180)],
            "t": [("他", "ta", -1382), ("她", "ta", -1587), ("它", "ta", -1581), ("太", "tai", -1880)],
            "w": [("我", "wo", -1233), ("为", "wei", -1470), ("问", "wen", -1915), ("完", "wan", -2050)],
            "x": [("先", "xian", -1720), ("想", "xiang", -1680), ("下", "xia", -1650), ("小", "xiao", -1725), ("行", "xing", -1920)],
            "y": [("有", "you", -1349), ("也", "ye", -1289), ("要", "yao", -1503), ("一", "yi", -1720), ("用", "yong", -1492)],
            "z": [("在", "zai", -1127), ("这", "zhe", -1458), ("再", "zai", -1615), ("走", "zou", -1780), ("做", "zuo", -1543)],
            "zh": [("这", "zhe", -1458), ("着", "zhe", -1904), ("真", "zhen", -1986), ("只", "zhi", -1837)],
        ]
        var monoMap: [String: [(text: String, syllable: String, scoreQ8: Int)]] = [:]
        var allPrefixes = (0..<26).map { String(UnicodeScalar(UInt8(0x61 + $0))) }
        allPrefixes.append(contentsOf: ["zh", "ch", "sh"])
        for pref in allPrefixes {
            var collected: [(text: String, syllable: String, scoreQ8: Int)] = []
            if let edges = rootEdgesByPrefix[pref] {
                for edge in edges.prefix(10) {
                    for w in words(at: edge.targetNode, limit: 2) {
                        collected.append((w.text, edge.syllable, w.scoreQ8))
                    }
                }
            }
            if let extras = guaranteedMonosyllables[pref] {
                for (txt, syl, sc) in extras where sc > -10000 {
                    collected.append((txt, syl, sc))
                }
            }
            collected.sort { $0.scoreQ8 > $1.scoreQ8 }
            var dedupMono: [(text: String, syllable: String, scoreQ8: Int)] = []
            var seenText = Set<String>()
            for item in collected where seenText.insert(item.text).inserted {
                dedupMono.append(item)
                if dedupMono.count >= 10 { break }
            }
            if !dedupMono.isEmpty {
                monoMap[pref] = dedupMono
            }
        }
        coreInitialMonosyllables = monoMap
    }

    // MARK: - English Prefix & Mixed-Input Lookup

    public struct EnglishHit: Sendable, Equatable {
        public let text: String
        public let scoreQ8: Int
        public let isExactKeyMatch: Bool
    }

    @inline(__always)
    public func hasEnglishPrefix3(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Bool {
        if hasNonAlphaEnglishKeys { return true }
        let c0 = (b0 >= 0x41 && b0 <= 0x5A) ? (b0 | 0x20) : b0
        let c1 = (b1 >= 0x41 && b1 <= 0x5A) ? (b1 | 0x20) : b1
        let c2 = (b2 >= 0x41 && b2 <= 0x5A) ? (b2 | 0x20) : b2
        guard c0 >= 0x61 && c0 <= 0x7A && c1 >= 0x61 && c1 <= 0x7A && c2 >= 0x61 && c2 <= 0x7A else {
            return false
        }
        let idx3 = (Int(c0 - 0x61) * 26 + Int(c1 - 0x61)) * 26 + Int(c2 - 0x61)
        return (enPrefix3Bitset[idx3 >> 6] & (UInt64(1) &<< (idx3 & 63))) != 0
    }

    @inline(__always)
    private func hasEnglishPrefixUTF8(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        if hasNonAlphaEnglishKeys { return true }
        let count = buf.count
        guard count >= 2 else { return false }
        let c0 = (buf[0] >= 0x41 && buf[0] <= 0x5A) ? (buf[0] | 0x20) : buf[0]
        let c1 = (buf[1] >= 0x41 && buf[1] <= 0x5A) ? (buf[1] | 0x20) : buf[1]
        guard c0 >= 0x61 && c0 <= 0x7A && c1 >= 0x61 && c1 <= 0x7A else { return false }
        let idx2 = Int(c0 - 0x61) * 26 + Int(c1 - 0x61)
        if count == 2 {
            return (enPrefix2Bitset[idx2 >> 6] & (UInt64(1) &<< (idx2 & 63))) != 0
        }
        let c2 = (buf[2] >= 0x41 && buf[2] <= 0x5A) ? (buf[2] | 0x20) : buf[2]
        guard c2 >= 0x61 && c2 <= 0x7A else { return false }
        let idx3 = idx2 * 26 + Int(c2 - 0x61)
        return (enPrefix3Bitset[idx3 >> 6] & (UInt64(1) &<< (idx3 & 63))) != 0
    }

    /// Zero-allocation `O(log N)` exact lowercase-alpha key lookup in the `mmap`'d English table.
    public func lookupExactEnglish(_ lowerKey: String) -> EnglishHit? {
        guard englishCount > 0 else { return nil }
        var key = lowerKey
        guard key.utf8.count >= 2 else { return nil }
        let raw = rawBuffer
        return key.withUTF8 { targetBuf -> EnglishHit? in
            guard hasEnglishPrefixUTF8(targetBuf) else { return nil }
            var lo = 0
            var hi = englishCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let recOff = englishOffset + mid * 16
                let lOff = Int(Self.loadU32(raw, at: recOff))
                let lLen = Int(Self.loadU16(raw, at: recOff + 8))
                let cmp = comparePoolBytes(raw, offset: lOff, length: lLen, against: targetBuf)
                if cmp == 0 {
                    let dOff = Int(Self.loadU32(raw, at: recOff + 4))
                    let dLen = Int(Self.loadU16(raw, at: recOff + 10))
                    let rawScore = Int(Self.loadI16(raw, at: recOff + 12))
                    guard let display = readPoolString(raw, offset: dOff, length: dLen) else { return nil }
                    let normalizedDisplay = (lowerKey == "bug" && display == "Bug") ? "bug" : display
                    return EnglishHit(text: normalizedDisplay, scoreQ8: rawScore, isExactKeyMatch: true)
                } else if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return nil
        }
    }

    public func lookupEnglish(prefix: String, limit: Int = 6) -> [EnglishHit] {
        guard englishCount > 0, limit > 0 else { return [] }
        var probe = prefix
        let hasPrefixMatch = probe.withUTF8 { hasEnglishPrefixUTF8($0) }
        guard hasPrefixMatch else { return [] }
        var lower = prefix.lowercased()
        guard lower.utf8.count >= 2 else { return [] }
        let isBugKey = (lower == "bug")
        let raw = rawBuffer

        return lower.withUTF8 { targetBuf -> [EnglishHit] in
            var lo = 0
            var hi = englishCount
            while lo < hi {
                let mid = (lo + hi) >> 1
                let recOff = englishOffset + mid * 16
                let lOff = Int(Self.loadU32(raw, at: recOff))
                let lLen = Int(Self.loadU16(raw, at: recOff + 8))
                if comparePoolBytes(raw, offset: lOff, length: lLen, against: targetBuf) < 0 {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            // Scan up to 320 sorted prefix entries in zero-copy mmap without allocating intermediate Strings,
            // materializing UTF-8 Strings only for the top `limit` candidates!
            var rawCandidates: [(dOff: Int, dLen: Int, scoreQ8: Int, isExact: Bool)] = []
            rawCandidates.reserveCapacity(min(limit * 2, 16))
            let maxScan = min(englishCount, lo + 320)
            var cursor = lo
            while cursor < maxScan {
                let recOff = englishOffset + cursor * 16
                let lOff = Int(Self.loadU32(raw, at: recOff))
                let lLen = Int(Self.loadU16(raw, at: recOff + 8))
                guard hasPoolPrefix(raw, offset: lOff, length: lLen, prefix: targetBuf) else { break }

                let dOff = Int(Self.loadU32(raw, at: recOff + 4))
                let dLen = Int(Self.loadU16(raw, at: recOff + 10))
                let rawScore = Int(Self.loadI16(raw, at: recOff + 12))
                let isExact = (lLen == targetBuf.count)
                let penalty = isExact ? 0 : min(600, (lLen - targetBuf.count) * 95 + 110)
                let finalScore = rawScore - penalty

                if rawCandidates.count < limit {
                    rawCandidates.append((dOff, dLen, finalScore, isExact))
                } else {
                    // Replace worst entry if strictly better (`isExact` first, then `scoreQ8`)
                    var worstIdx = 0
                    for i in 1..<rawCandidates.count {
                        let a = rawCandidates[i]
                        let b = rawCandidates[worstIdx]
                        if (!a.isExact && b.isExact) || (a.isExact == b.isExact && a.scoreQ8 < b.scoreQ8) {
                            worstIdx = i
                        }
                    }
                    let w = rawCandidates[worstIdx]
                    if (isExact && !w.isExact) || (isExact == w.isExact && finalScore > w.scoreQ8) {
                        rawCandidates[worstIdx] = (dOff, dLen, finalScore, isExact)
                    }
                }
                cursor += 1
            }

            rawCandidates.sort {
                if $0.isExact != $1.isExact { return $0.isExact && !$1.isExact }
                return $0.scoreQ8 > $1.scoreQ8
            }

            var hits: [EnglishHit] = []
            hits.reserveCapacity(rawCandidates.count)
            for rc in rawCandidates {
                if let display = readPoolString(raw, offset: rc.dOff, length: rc.dLen) {
                    let normalizedDisplay = (rc.isExact && isBugKey && display == "Bug") ? "bug" : display
                    hits.append(EnglishHit(text: normalizedDisplay, scoreQ8: rc.scoreQ8, isExactKeyMatch: rc.isExact))
                }
            }
            return hits
        }
    }

    // MARK: - Next-Word Contextual Association & Bigram Transition Lookup

    private func associationLowerBound(_ target: UnsafeBufferPointer<UInt8>) -> Int {
        var lo = 0, hi = assocCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let rec = assocOffset + mid * 16
            let offset = Int(Self.loadU32(rawBuffer, at: rec))
            let length = Int(Self.loadU16(rawBuffer, at: rec + 8))
            if comparePoolBytes(rawBuffer, offset: offset, length: length, against: target) < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Visits complete attested readings within the channel's length budget. Decode a Chinese
    /// surface only after the cheap byte alignment succeeds.
    func visitSpokenReadings(length: Int, isCancelled: () -> Bool,
                             cost: (UnsafeBufferPointer<UInt8>) -> Int?,
                             visit: (WordHit, Int) -> Void) {
        guard spokenRecordsByLength.indices.contains(length), let base = rawBuffer.baseAddress else { return }
        for (i, record) in spokenRecordsByLength[length].enumerated() {
            if (i & 31) == 0, isCancelled() { return }
            let rec = assocOffset + Int(record) * 16
            let offset = Int(Self.loadU32(rawBuffer, at: rec))
            guard offset >= 0, offset <= stringPoolSize, 1 + length <= stringPoolSize - offset else { continue }
            let ptr = base.advanced(by: stringPoolOffset + offset + 1).assumingMemoryBound(to: UInt8.self)
            guard let channel = cost(UnsafeBufferPointer(start: ptr, count: length)) else { continue }
            let v = Int(Self.loadU32(rawBuffer, at: rec + 4))
            let len = Int(Self.loadU16(rawBuffer, at: rec + 10))
            if let text = readPoolString(rawBuffer, offset: v, length: len) {
                visit(WordHit(text: text, scoreQ8: Int(Self.loadI16(rawBuffer, at: rec + 12))), channel)
            }
        }
    }

    /// Visits spoken readings of `length` restricted losslessly to `(b0, b1)` prefix buckets (`b1 == nil` scans all `b0*`).
    func visitSpokenReadingRange(
        length: Int,
        b0: UInt8,
        b1: UInt8?,
        scanned: inout Int,
        isCancelled: () -> Bool,
        cost: (UnsafeBufferPointer<UInt8>) -> Int?,
        visit: (WordHit, Int) -> Void
    ) {
        guard spokenRecordsByLength.indices.contains(length),
              let base = rawBuffer.baseAddress,
              b0 >= 0x61 && b0 <= 0x7A else { return }
        let records = spokenRecordsByLength[length]
        guard !records.isEmpty else { return }
        guard spokenPrefix2Sorted[length], !spokenPrefix2Offsets[length].isEmpty else {
            // Fallback for synthetic unsorted lexicons: scan full length only on first call
            if b1 == nil {
                visitSpokenReadings(length: length, isCancelled: isCancelled, cost: cost, visit: visit)
            }
            return
        }
        let offsets = spokenPrefix2Offsets[length]
        let b0Idx = Int(b0 - 0x61)
        let startIdx: Int
        let endIdx: Int
        if let b1 {
            guard b1 >= 0x61 && b1 <= 0x7A else { return }
            let bucket = b0Idx * 26 + Int(b1 - 0x61)
            startIdx = Int(offsets[bucket])
            endIdx = Int(offsets[bucket + 1])
        } else {
            startIdx = Int(offsets[b0Idx * 26])
            endIdx = Int(offsets[(b0Idx + 1) * 26])
        }
        guard startIdx < endIdx else { return }
        for idx in startIdx..<endIdx {
            if (scanned & 31) == 0, isCancelled() { return }
            scanned &+= 1
            let rec = assocOffset + Int(records[idx]) * 16
            let offset = Int(Self.loadU32(rawBuffer, at: rec))
            guard offset >= 0, offset <= stringPoolSize, 1 + length <= stringPoolSize - offset else { continue }
            let ptr = base.advanced(by: stringPoolOffset + offset + 1).assumingMemoryBound(to: UInt8.self)
            guard let channel = cost(UnsafeBufferPointer(start: ptr, count: length)) else { continue }
            let v = Int(Self.loadU32(rawBuffer, at: rec + 4))
            let len = Int(Self.loadU16(rawBuffer, at: rec + 10))
            if let text = readPoolString(rawBuffer, offset: v, length: len) {
                visit(WordHit(text: text, scoreQ8: Int(Self.loadI16(rawBuffer, at: rec + 12))), channel)
            }
        }
    }

    private func buildSpokenDrop2IndexLocked(forLength length: Int) {
        guard spokenDrop2BuiltLengths.indices.contains(length),
              !spokenDrop2BuiltLengths[length] else { return }
        defer { spokenDrop2BuiltLengths[length] = true }
        var recs = spokenRecordsByLength[length]
        guard !recs.isEmpty else { return }
        let raw = rawBuffer
        guard let base = raw.baseAddress else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let suffixLen = length - 2
        recs.sort { a, b in
            let recA = assocOffset + Int(a) * 16
            let recB = assocOffset + Int(b) * 16
            let offA = Int(Self.loadU32(raw, at: recA))
            let offB = Int(Self.loadU32(raw, at: recB))
            let validA = offA >= 0 && offA <= stringPoolSize && (1 + length) <= stringPoolSize - offA
            let validB = offB >= 0 && offB <= stringPoolSize && (1 + length) <= stringPoolSize - offB
            if validA != validB { return validA }
            if !validA { return a < b }
            let cmp = memcmp(
                bytes.advanced(by: stringPoolOffset + offA + 3),
                bytes.advanced(by: stringPoolOffset + offB + 3),
                suffixLen
            )
            return cmp != 0 ? (cmp < 0) : (a < b)
        }
        spokenDrop2ByLength[length] = recs
    }

    private func ensureSpokenDrop2Index() {
        for length in 4..<spokenRecordsByLength.count {
            os_unfair_lock_lock(&spokenDrop2Lock)
            buildSpokenDrop2IndexLocked(forLength: length)
            os_unfair_lock_unlock(&spokenDrop2Lock)
        }
    }

    /// Visits spoken readings of `length` whose `reading[2..<length]` equals `typed[0..<(length - 2)]` (lossless O(log N) `(0, 1)` drop coverage).
    func visitSpokenDrop2Suffix(
        length: Int,
        typed: [UInt8],
        cost: Int,
        visit: (WordHit, Int) -> Void
    ) {
        guard length >= 4,
              spokenRecordsByLength.indices.contains(length),
              typed.count == length - 2,
              let base = rawBuffer.baseAddress else { return }
        os_unfair_lock_lock(&spokenDrop2Lock)
        buildSpokenDrop2IndexLocked(forLength: length)
        let records = spokenDrop2ByLength[length]
        os_unfair_lock_unlock(&spokenDrop2Lock)
        guard !records.isEmpty else { return }
        let suffixLen = typed.count
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let t0 = typed[0]
        typed.withUnsafeBufferPointer { typedBuf in
            guard let tPtr = typedBuf.baseAddress else { return }
            var lo = 0
            var hi = records.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                let rec = assocOffset + Int(records[mid]) * 16
                let off = Int(Self.loadU32(rawBuffer, at: rec))
                if off < 0 || off > stringPoolSize || (1 + length) > stringPoolSize - off {
                    hi = mid
                    continue
                }
                let cmp = memcmp(bytes.advanced(by: stringPoolOffset + off + 3), tPtr, suffixLen)
                if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            var idx = lo
            while idx < records.count {
                let rec = assocOffset + Int(records[idx]) * 16
                let off = Int(Self.loadU32(rawBuffer, at: rec))
                guard off >= 0, off <= stringPoolSize, (1 + length) <= stringPoolSize - off else { break }
                let sPtr = bytes.advanced(by: stringPoolOffset + off + 3)
                if memcmp(sPtr, tPtr, suffixLen) != 0 { break }
                let b0 = bytes[stringPoolOffset + off + 1]
                let b1 = bytes[stringPoolOffset + off + 2]
                // Cases where `reading[0] == t0` or `reading[1] == t0` are already covered by
                // `visitSpokenReadingRange(b0: t0, b1: nil)` and `(b0: c0, b1: t0)`.
                if b0 != t0 && b1 != t0 {
                    let v = Int(Self.loadU32(rawBuffer, at: rec + 4))
                    let len = Int(Self.loadU16(rawBuffer, at: rec + 10))
                    if let text = readPoolString(rawBuffer, offset: v, length: len) {
                        visit(WordHit(text: text, scoreQ8: Int(Self.loadI16(rawBuffer, at: rec + 12))), cost)
                    }
                }
                idx += 1
            }
        }
    }

    /// Zero-copy `O(log N)` lookup for natural Chinese next-word continuations after `prefix` (e.g. `"明天"` -> `["我们", "见", ...]`).
    public func lookupAssociations(after prefix: String, limit: Int = 10) -> [WordHit] {
        guard !prefix.isEmpty, assocCount > 0, limit > 0 else { return [] }
        let raw = rawBuffer
        var query = prefix

        return query.withUTF8 { targetBuf -> [WordHit] in
            let lo = associationLowerBound(targetBuf)

            var hits: [WordHit] = []
            var cursor = lo
            let maxScan = min(assocCount, lo + 20)
            while cursor < maxScan {
                let recOff = assocOffset + cursor * 16
                let kOff = Int(Self.loadU32(raw, at: recOff))
                let kLen = Int(Self.loadU16(raw, at: recOff + 8))
                guard comparePoolBytes(raw, offset: kOff, length: kLen, against: targetBuf) == 0 else {
                    break
                }
                let vOff = Int(Self.loadU32(raw, at: recOff + 4))
                let vLen = Int(Self.loadU16(raw, at: recOff + 10))
                let score = Int(Self.loadI16(raw, at: recOff + 12))
                if let text = readPoolString(raw, offset: vOff, length: vLen) {
                    hits.append(WordHit(text: text, scoreQ8: score))
                    if hits.count >= limit { break }
                }
                cursor += 1
            }
            return hits
        }
    }

    /// Returns a map of `nextWord -> bigramBonusQ8` (`50..620` Q8 units, scaled by empirical log-weight & rank)
    /// for all compiled continuations of `prevWord` in a single `O(log N)` probe.
    public func associationBonusMap(after prevWord: String) -> [String: Int] {
        guard !prevWord.isEmpty && assocCount > 0 else { return [:] }
        let raw = rawBuffer
        var query = prevWord

        return query.withUTF8 { keyBuf -> [String: Int] in
            let lo = associationLowerBound(keyBuf)

            var bonuses: [String: Int] = [:]
            var cursor = lo
            let maxScan = min(assocCount, lo + 16)
            while cursor < maxScan {
                let recOff = assocOffset + cursor * 16
                let kOff = Int(Self.loadU32(raw, at: recOff))
                let kLen = Int(Self.loadU16(raw, at: recOff + 8))
                guard comparePoolBytes(raw, offset: kOff, length: kLen, against: keyBuf) == 0 else {
                    break
                }
                let vOff = Int(Self.loadU32(raw, at: recOff + 4))
                let vLen = Int(Self.loadU16(raw, at: recOff + 10))
                let rawScore = Int(Self.loadI16(raw, at: recOff + 12))
                let rankIdx = Int(Self.loadU16(raw, at: recOff + 14))
                if let nextText = readPoolString(raw, offset: vOff, length: vLen) {
                    let weightScaled: Int
                    if rawScore >= 2250 {
                        // Curated conversational bigrams (`2350..3000`) -> `500..620`
                        weightScaled = min(620, 500 + (rawScore - 2250) / 3)
                    } else {
                        // Empirical corpus continuations (`376..2200`) -> `60..500` proportional to log10(weight)
                        weightScaled = max(60, min(500, ((rawScore - 280) * 25) / 100))
                    }
                    bonuses[nextText] = max(50, weightScaled - rankIdx * 22)
                }
                cursor += 1
            }
            return bonuses
        }
    }

    func cachedAssociationBonusMap(after prevWord: String) -> [String: Int] {
        guard !prevWord.isEmpty && assocCount > 0 else { return [:] }
        os_unfair_lock_lock(&sharedCacheLock)
        if let cached = sharedRawAssocCache[prevWord] {
            os_unfair_lock_unlock(&sharedCacheLock)
            return cached
        }
        os_unfair_lock_unlock(&sharedCacheLock)

        let loaded = associationBonusMap(after: prevWord)
        os_unfair_lock_lock(&sharedCacheLock)
        if sharedRawAssocCache.count >= 4096 {
            sharedRawAssocCache.removeAll(keepingCapacity: true)
        }
        sharedRawAssocCache[prevWord] = loaded
        os_unfair_lock_unlock(&sharedCacheLock)
        return loaded
    }

    /// Returns a positive Viterbi transition bonus (`0`..`620` Q8 units) if `nextWord` is a frequent natural continuation of `prevWord`.
    public func bigramBonus(prevWord: String, nextWord: String) -> Int {
        associationBonusMap(after: prevWord)[nextWord] ?? 0
    }

    @inline(__always)
    private static func packSyllableU32(_ utf8: String.UTF8View) -> UInt32? {
        var code: UInt32 = 0
        var count = 0
        for b in utf8 {
            guard b >= 0x61 && b <= 0x7A && count < 6 else { return nil }
            code = (code << 5) | UInt32(b - 0x60)
            count += 1
        }
        return count > 0 ? code : nil
    }

    /// Returns true if `raw` can already be cleanly partitioned into two exact Mandarin syllables (e.g. `"quna" -> "qu" + "na"`).
    @inline(__always)
    public func isExactTwoSyllableConcat(_ raw: String) -> Bool {
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0)
        var n = 0
        for b in raw.utf8 {
            guard b >= 0x61 && b <= 0x7A && n < 12 else { return false }
            withUnsafeMutableBytes(of: &bytes) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return false }
        return withUnsafeBytes(of: &bytes) { buf in
            for split in 1..<n where split <= 6 && (n - split) <= 6 {
                var leftCode: UInt32 = 0
                for i in 0..<split { leftCode = (leftCode << 5) | UInt32(buf[i] - 0x60) }
                guard packedSyllableSet.contains(leftCode) else { continue }
                var rightCode: UInt32 = 0
                for i in split..<n { rightCode = (rightCode << 5) | UInt32(buf[i] - 0x60) }
                if packedSyllableSet.contains(rightCode) { return true }
            }
            return false
        }
    }

    /// Zero-allocation pointer-based DP: returns true if `ptr[0..<n]` (`1...63` lowercase ASCII letters)
    /// partitions 100% into exact Mandarin syllables with zero leftover letters.
    @inline(__always)
    public func canSegmentCleanlyPointer(_ ptr: UnsafePointer<UInt8>, count n: Int) -> Bool {
        guard n >= 1 && n < 64 else { return false }
        for k in 0..<n {
            let b = ptr[k]
            if b < 0x61 || b > 0x7A { return false }
        }
        let targetBit: UInt64 = UInt64(1) << UInt64(n)
        var reach: UInt64 = 1
        for i in 0..<n where (reach & (UInt64(1) << UInt64(i))) != 0 {
            let maxEnd = min(n, i + 6)
            var code: UInt32 = 0
            for end in (i + 1)...maxEnd {
                code = (code << 5) | UInt32(ptr[end - 1] - 0x60)
                let bit = UInt64(1) << UInt64(end)
                if code < shortSyllablePrefixes.count {
                    let kind = shortSyllablePrefixes[Int(code)]
                    if kind == 0 { break }
                    if kind == 2 { reach |= bit }
                } else if (reach & bit) == 0 && packedSyllableSet.contains(code) { reach |= bit }
            }
            if (reach & targetBit) != 0 { return true }
        }
        return (reach & targetBit) != 0
    }

    /// Zero-allocation stack-bitmask DP: returns true if `raw` (1...63 lowercase letters) partitions 100% into
    /// exact Mandarin syllables with zero leftover letters (`qunaa -> qu + na + a`, `haodea -> hao + de + a`).
    @inline(__always)
    public func canSegmentCleanly(_ raw: String) -> Bool {
        var buf: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in raw.utf8 {
            guard b >= 0x61 && b <= 0x7A && n < 63 else { return false }
            withUnsafeMutableBytes(of: &buf) { $0[n] = b }
            n += 1
        }
        guard n >= 1 else { return false }
        return withUnsafeBytes(of: &buf) { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return canSegmentCleanlyPointer(base, count: n)
        }
    }

    /// Returns true if `raw` segments cleanly into complete Mandarin syllables, OR (for long sentences `n >= 9`)
    /// segments cleanly up to an in-progress trailing syllable prefix (`1..3` letters in `prefixToSyllableIDs`,
    /// e.g. `"xianzaiw"`, `"xianzaiwom"`, `"wojintianxiawuyouko"`, `"wojintianxiawuyoukon"`), preventing
    /// incremental lattice cache invalidation on every consonant keystroke.
    @inline(__always)
    public func canSegmentCleanlyOrActiveTail(_ raw: String) -> Bool {
        if canSegmentCleanly(raw) { return true }
        let count = raw.utf8.count
        guard count >= 9 else { return false }
        for tailLen in 1...4 {
            let tail = String(raw.suffix(tailLen))
            guard prefixToSyllableIDs[tail] != nil else { continue }
            let head = String(raw.dropLast(tailLen))
            if canSegmentCleanly(head) {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private func bestTwoSyllableWordScoreBuffer(_ ptr: UnsafePointer<UInt8>, count n: Int) -> Int? {
        guard n >= 2 && n <= 12 else { return nil }
        var best: Int? = nil
        for split in 1..<n where split <= 6 && (n - split) <= 6 {
            var leftCode: UInt32 = 0
            for i in 0..<split {
                leftCode = (leftCode << 5) | UInt32(ptr[i] - 0x60)
            }
            guard let sid1 = packedCodeToSID[leftCode] else { continue }
            let n1 = rootTargetBySID[Int(sid1)]
            guard n1 != UInt32.max else { continue }

            var rightCode: UInt32 = 0
            for i in split..<n {
                rightCode = (rightCode << 5) | UInt32(ptr[i] - 0x60)
            }
            guard let sid2 = packedCodeToSID[rightCode],
                  let n2 = step(from: n1, syllableID: sid2) else {
                continue
            }
            if let score = topWordScore(at: n2), best == nil || score > best! {
                best = score
            }
        }
        return best
    }

    /// Zero-allocation slice overload for hot-path lattice/span construction (`filters` `0x61...0x7A` onto stack).
    @inline(__always)
    public func bestTwoSyllableWordScoreASCII(_ bytes: ArraySlice<UInt8>) -> Int? {
        var stack: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0,0,0,0,0,0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in bytes where b >= 0x61 && b <= 0x7A {
            if n >= 12 { return nil }
            withUnsafeMutableBytes(of: &stack) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return nil }
        return withUnsafeBytes(of: &stack) { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return bestTwoSyllableWordScoreBuffer(base, count: n)
        }
    }

    /// Returns the best `scoreQ8` among exact 2-syllable lexicon words matching `raw`, or `nil` if none exist.
    public func bestTwoSyllableWordScore(_ raw: String) -> Int? {
        var stack: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0,0,0,0,0,0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in raw.utf8 {
            guard b >= 0x61 && b <= 0x7A && n < 12 else { return nil }
            withUnsafeMutableBytes(of: &stack) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return nil }
        return withUnsafeBytes(of: &stack) { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return bestTwoSyllableWordScoreBuffer(base, count: n)
        }
    }

    /// Returns true if `raw` splits into two exact Mandarin syllables that form an in-lexicon 2-syllable word
    /// with `scoreQ8 >= minScoreQ8` (e.g., `"quna" -> "去哪"`, `"ali" -> "阿里"`, `"shia" -> "是啊"`).
    @inline(__always)
    public func hasCommonCleanTwoSyllablePhrase(_ raw: String, minScoreQ8: Int = -3350) -> Bool {
        if let sc = bestTwoSyllableWordScore(raw) {
            return sc >= minScoreQ8
        }
        return false
    }

    /// Zero-allocation stack-bitmask core for `startsWithCoherentCleanUnit` (`< 150 ns`, zero heap allocations).
    private func startsWithCoherentCleanUnitBuffer(_ ptr: UnsafePointer<UInt8>, count n: Int, minWordScoreQ8: Int) -> Bool {
        guard n >= 2 && n < 63 else { return false }

        // Single O(n) reverse pass computes `suffixCleanMask`: bit `k` is 1 iff `ptr[k..<n]` segments 100% cleanly!
        var suffixCleanMask: UInt64 = UInt64(1) << UInt64(n)
        var pos = n - 1
        while pos >= 0 {
            let maxEnd = min(n, pos + 6)
            var code: UInt32 = 0
            for end in (pos + 1)...maxEnd {
                code = (code << 5) | UInt32(ptr[end - 1] - 0x60)
                if (suffixCleanMask & (UInt64(1) << UInt64(end))) != 0 && packedSyllableSet.contains(code) {
                    suffixCleanMask |= (UInt64(1) << UInt64(pos))
                    break
                }
            }
            pos -= 1
        }
        guard (suffixCleanMask & 1) != 0 else { return false }

        let maxL1 = min(6, n)
        var code1: UInt32 = 0
        for l1 in 1...maxL1 {
            code1 = (code1 << 5) | UInt32(ptr[l1 - 1] - 0x60)
            guard let sid1 = packedCodeToSID[code1] else { continue }
            let s1Score = syllableOneCharScores[Int(sid1)]
            if l1 == n {
                return s1Score >= -2060
            }
            guard (suffixCleanMask & (UInt64(1) << UInt64(l1))) != 0 else { continue }

            let n1Raw = rootTargetBySID[Int(sid1)]
            let s1Core = s1Score >= -2060
            let s2CoreFloor = (s1Score >= -1950) ? -2350 : -2060
            let maxL2 = min(6, n - l1)
            var code2: UInt32 = 0
            for l2 in 1...maxL2 {
                let end2 = l1 + l2
                code2 = (code2 << 5) | UInt32(ptr[end2 - 1] - 0x60)
                guard let sid2 = packedCodeToSID[code2] else { continue }
                if end2 < n && (suffixCleanMask & (UInt64(1) << UInt64(end2))) == 0 {
                    continue
                }
                if n1Raw != UInt32.max, let node2 = step(from: n1Raw, syllableID: sid2) {
                    if let score = topWordScore(at: node2), score >= minWordScoreQ8 { return true }
                    if end2 < n && hasOutgoingEdges(at: node2) && maxSubtreeScore(at: node2) >= minWordScoreQ8 {
                        return true
                    }
                }
                if s1Core {
                    if syllableOneCharScores[Int(sid2)] >= s2CoreFloor {
                        return true
                    }
                    let node2Root = rootTargetBySID[Int(sid2)]
                    if end2 < n && node2Root != UInt32.max {
                        let maxL3 = min(6, n - end2)
                        var code3: UInt32 = 0
                        for l3 in 1...maxL3 {
                            let end3 = end2 + l3
                            code3 = (code3 << 5) | UInt32(ptr[end3 - 1] - 0x60)
                            guard let sid3 = packedCodeToSID[code3] else { continue }
                            if end3 < n && (suffixCleanMask & (UInt64(1) << UInt64(end3))) == 0 { continue }
                            if let node3 = step(from: node2Root, syllableID: sid3),
                               let score = topWordScore(at: node3), score >= minWordScoreQ8 { return true }
                        }
                    }
                }
            }
        }
        return false
    }

    @inline(__always)
    public func startsWithCoherentCleanUnitASCII(_ bytes: ArraySlice<UInt8>, minWordScoreQ8: Int = -3350) -> Bool {
        var buf: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in bytes where b >= 0x61 && b <= 0x7A {
            if n >= 62 { return false }
            withUnsafeMutableBytes(of: &buf) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return false }
        return withUnsafeBytes(of: &buf) { rawPtr in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return startsWithCoherentCleanUnitBuffer(base, count: n, minWordScoreQ8: minWordScoreQ8)
        }
    }

    /// Distinguishes genuinely coherent clean Mandarin Pinyin (`"wogangdao"`, `"baheba"`, `"wolai"`) from
    /// accidental 1-char syllable soup caused by fast-typing errors (`"hurifa" -> hu+ri+fa`, `"kuisushu" -> kui+su+shu`).
    public func startsWithCoherentCleanUnit(_ raw: String, minWordScoreQ8: Int = -3350) -> Bool {
        var buf: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in raw.utf8 {
            guard b >= 0x61 && b <= 0x7A && n < 62 else { return false }
            withUnsafeMutableBytes(of: &buf) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return false }
        return withUnsafeBytes(of: &buf) { rawPtr in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return startsWithCoherentCleanUnitBuffer(base, count: n, minWordScoreQ8: minWordScoreQ8)
        }
    }

    @inline(__always)
    private func isLocallyCleanWindowBuffer(_ ptr: UnsafePointer<UInt8>, count: Int) -> Bool {
        if startsWithCoherentCleanUnitBuffer(ptr, count: count, minWordScoreQ8: -3350) { return true }
        guard count >= 5 else { return false }
        let maxTail = min(4, count - 3)
        guard maxTail >= 1 else { return false }
        for tailLen in 1...maxTail {
            let headLen = count - tailLen
            var tailCode: UInt64 = 0
            for k in headLen..<count {
                tailCode = (tailCode << 5) | UInt64(ptr[k] - 0x60)
            }
            guard packedKnownPrefixSet.contains(tailCode) else { continue }
            if startsWithCoherentCleanUnitBuffer(ptr, count: headLen, minWordScoreQ8: -3350) {
                return true
            }
        }
        return false
    }

    @inline(__always)
    public func isLocallyCleanWindowASCII(_ bytes: ArraySlice<UInt8>) -> Bool {
        var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in bytes {
            guard b >= 0x61 && b <= 0x7A && n < 15 else { return false }
            withUnsafeMutableBytes(of: &buf) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return false }
        return withUnsafeBytes(of: &buf) { rawPtr in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isLocallyCleanWindowBuffer(base, count: n)
        }
    }

    /// Evaluates whether a local 5..7 letter window starting at `start` represents clean in-progress typing
    /// (allowing a 1..4 letter active syllable prefix right at the right edge of the window, while rejecting
    /// mid-window unsegmentable crashes like `"womenbq"` and 1-char syllable soup like `"hurifaz"`).
    @inline(__always)
    public func isLocallyCleanWindow(_ raw: String) -> Bool {
        var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        )
        var n = 0
        for b in raw.utf8 {
            guard b >= 0x61 && b <= 0x7A && n < 15 else { return false }
            withUnsafeMutableBytes(of: &buf) { $0[n] = b }
            n += 1
        }
        guard n >= 2 else { return false }
        return withUnsafeBytes(of: &buf) { rawPtr in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isLocallyCleanWindowBuffer(base, count: n)
        }
    }

    // MARK: - Zero-Copy Emoji Lookup (`LEMJ` v1)

    /// Binary-searches the `mmap`'d `lokey_emoji.bin` table in `O(log N)` (`< 0.5 µs`) for inline Emoji candidates
    /// matching `word` (e.g., `"哈哈"` -> `["😂", "🤣"]`, `"大哭"` -> `["😭", "😢"]`).
    public func lookupEmojis(forWord word: String, limit: Int = 2) -> [String] {
        guard emojiRecordCount > 0, limit > 0, !word.isEmpty,
              let base = emojiRawBuffer.baseAddress else {
            return []
        }
        var target = word
        return target.withUTF8 { queryUTF8 -> [String] in
            var lo = 0
            var hi = emojiRecordCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let recOff = 16 + mid * 12
                let kOff = emojiPoolOffset + Int(Self.loadU32(emojiRawBuffer, at: recOff))
                let kLen = Int(Self.loadU16(emojiRawBuffer, at: recOff + 4))
                guard kOff >= emojiPoolOffset, kOff + kLen <= emojiRawBuffer.count else { return [] }

                let ptr = base.advanced(by: kOff).assumingMemoryBound(to: UInt8.self)
                let common = min(kLen, queryUTF8.count)
                var cmp = 0
                for i in 0..<common {
                    let a = ptr[i]
                    let b = queryUTF8[i]
                    if a != b {
                        cmp = (a < b) ? -1 : 1
                        break
                    }
                }
                if cmp == 0 && kLen != queryUTF8.count {
                    cmp = (kLen < queryUTF8.count) ? -1 : 1
                }

                if cmp == 0 {
                    let eCount = min(limit, Int(Self.loadU16(emojiRawBuffer, at: recOff + 6)))
                    guard eCount > 0 else { return [] }
                    var cursor = emojiPoolOffset + Int(Self.loadU32(emojiRawBuffer, at: recOff + 8))
                    var out: [String] = []
                    out.reserveCapacity(eCount)
                    for _ in 0..<eCount {
                        guard cursor >= emojiPoolOffset, cursor < emojiRawBuffer.count else { break }
                        let byteLen = Int(emojiRawBuffer[cursor])
                        cursor += 1
                        guard byteLen > 0, cursor + byteLen <= emojiRawBuffer.count else { break }
                        let emBuf = UnsafeBufferPointer(
                            start: base.advanced(by: cursor).assumingMemoryBound(to: UInt8.self),
                            count: byteLen
                        )
                        out.append(String(decoding: emBuf, as: UTF8.self))
                        cursor += byteLen
                    }
                    return out
                } else if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return []
        }
    }

    private func spellingValue(_ key: UInt64) -> Int? {
        var lo = 0, hi = spellingTable.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spellingTable[mid] >> 16 < key { lo = mid + 1 } else { hi = mid }
        }
        guard lo < spellingTable.count, spellingTable[lo] >> 16 == key else { return nil }
        return Int(Int16(truncatingIfNeeded: spellingTable[lo]))
    }

    /// Learned association of the last character before a dictionary word
    /// with the first two characters of that word. The compiler shrinks rare
    /// co-occurrences; missing evidence is neutral.
    func spellingBoundary(_ text: String, trailingWord: String?) -> Int {
        guard let word = trailingWord, !word.isEmpty, text.hasSuffix(word) else { return 0 }
        func lookupTriple(_ c0: UnicodeScalar, _ c1: UnicodeScalar, _ c2: UnicodeScalar) -> Int {
            guard (0x4e00...0x9fff).contains(c0.value),
                  (0x4e00...0x9fff).contains(c1.value),
                  (0x4e00...0x9fff).contains(c2.value) else { return 0 }
            let k0 = UInt64(0xa000 + c0.value - 0x4e00)
            let key = (k0 << 32) | (UInt64(c1.value) << 16) | UInt64(c2.value)
            return spellingValue(key) ?? 0
        }
        let scalars = Array(text.unicodeScalars)
        let wScalars = Array(word.unicodeScalars)
        let prefixLen = scalars.count - wScalars.count
        var best = 0
        if wScalars.count >= 2 && prefixLen >= 1 {
            best = lookupTriple(scalars[prefixLen - 1], wScalars[0], wScalars[1])
        } else if wScalars.count == 1 && scalars.count >= 4 {
            best = lookupTriple(scalars[scalars.count - 4], scalars[scalars.count - 3], scalars[scalars.count - 2])
        }
        return best
    }

    /// Log likelihood of a short sentence, in 1/128 bits. Unseen transitions
    /// back off to the shorter context, with a penalty for each missing order.
    func spellingLikelihood(_ text: String) -> Int? {
        guard !spellingTable.isEmpty else { return nil }
        var prior: UInt64 = 1
        var total = 0
        func consume(_ char: UInt64) {
            let key = (prior << 16) | char
            let bigram = key & 0xffff_ffff
            if let probability = spellingValue(key) {
                total += probability
            } else {
                let shorter = spellingValue(bigram) ?? ((spellingValue(char) ?? -2300) - 150)
                total += shorter - (key == bigram ? 0 : 100)
            }
            prior = bigram
        }
        for char in text.unicodeScalars {
            guard char.value >= 0x4e00 && char.value <= 0x9fff else { return nil }
            consume(UInt64(char.value))
        }
        consume(2)
        return total
    }

    private static func discoverResource(_ name: String) -> NSData? {
        if let url = Bundle.main.url(forResource: name, withExtension: "bin"),
           let d = try? NSData(contentsOf: url, options: [.mappedIfSafe]) {
            return d
        }
        let clsBundle = Bundle(for: MmapLexicon.self)
        if let url = clsBundle.url(forResource: name, withExtension: "bin"),
           let d = try? NSData(contentsOf: url, options: [.mappedIfSafe]) {
            return d
        }
        if let extURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("LokeyKeyboard.appex", isDirectory: true)
            .appendingPathComponent("\(name).bin"),
           let d = try? NSData(contentsOf: extURL, options: [.mappedIfSafe]) {
            return d
        }
        let localURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Shared/Resources/\(name).bin")
        if let d = try? NSData(contentsOf: localURL, options: [.mappedIfSafe]) {
            return d
        }
        return nil
    }

    // MARK: - Low-Level Raw Pointer Helpers

    @inline(__always)
    private func readPoolString(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int) -> String? {
        guard offset >= 0,
              length > 0,
              offset <= stringPoolSize,
              length <= stringPoolSize - offset,
              let base = raw.baseAddress else { return nil }
        let buf = UnsafeBufferPointer(
            start: base.advanced(by: stringPoolOffset + offset).assumingMemoryBound(to: UInt8.self),
            count: length
        )
        return String(decoding: buf, as: UTF8.self)
    }

    @inline(__always)
    private func comparePoolBytes(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int, against rhs: UnsafeBufferPointer<UInt8>) -> Int {
        guard let base = raw.baseAddress,
              offset >= 0,
              length >= 0,
              offset <= stringPoolSize,
              length <= stringPoolSize - offset else { return -1 }
        let ptr = base.advanced(by: stringPoolOffset + offset).assumingMemoryBound(to: UInt8.self)
        let n = min(length, rhs.count)
        for i in 0..<n {
            let a = ptr[i]
            let b = rhs[i]
            if a != b { return a < b ? -1 : 1 }
        }
        if length == rhs.count { return 0 }
        return length < rhs.count ? -1 : 1
    }

    @inline(__always)
    private func hasPoolPrefix(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int, prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = raw.baseAddress,
              offset >= 0,
              length >= prefix.count,
              offset <= stringPoolSize,
              length <= stringPoolSize - offset else { return false }
        let ptr = base.advanced(by: stringPoolOffset + offset).assumingMemoryBound(to: UInt8.self)
        for i in 0..<prefix.count {
            if ptr[i] != prefix[i] { return false }
        }
        return true
    }

    public static func packCodeBE(_ bytes: [UInt8]) -> UInt64 {
        var val: UInt64 = 0
        for i in 0..<min(8, bytes.count) {
            val |= UInt64(bytes[i]) << ((7 - i) * 8)
        }
        return val
    }

    @inline(__always)
    private static func loadU16(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    private static func loadI16(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Int16 {
        Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
    }

    @inline(__always)
    private static func loadU32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    private static func loadU64BE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

// MARK: - `.lokeypack` Validation, Atomic App Group Installation & Zero-Copy Hot-Mounting

public enum LokeyLexiconPackError: LocalizedError, Equatable, Sendable {
    case fileTooSmall
    case fileTooLarge(maxMB: Int)
    case invalidMagic
    case unsupportedVersion(UInt32)
    case outOfBoundsSection
    case invalidNeuralFooter
    case invalidNeuralHeader
    case sha256Mismatch(expected: String, actual: String)
    case directoryNotSupported
    case iCloudDownloadIncomplete
    case cannotOpenFile
    case packNotFound

    public var errorDescription: String? {
        switch self {
        case .fileTooSmall:
            return "词库包文件过小，不是有效的 .lokeypack 文件。"
        case let .fileTooLarge(maxMB):
            return "词库包体积超过上限（最大支持 \(maxMB) MB）。"
        case .invalidMagic:
            return "文件头校验失败：缺少 LKLF 魔数签名，请确认选择的是有效的 .lokeypack 词库包。"
        case let .unsupportedVersion(ver):
            return "不支持的词库包格式版本（v\(ver)），当前仅支持 LKLF v2。"
        case .outOfBoundsSection:
            return "词库包内部索引段越界或文件不完整，请重新下载后重试。"
        case .invalidNeuralFooter:
            return "词库包缺少有效的 LNLM-v2 神经网络尾部签名。"
        case .invalidNeuralHeader:
            return "词库包内置的 LNLM-v2 神经网络权重头已损坏或维度不匹配。"
        case let .sha256Mismatch(expected, actual):
            return "SHA-256 校验不匹配（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .directoryNotSupported:
            return "暂不支持文件夹，请选择具体的 .lokeypack 词库包文件。"
        case .iCloudDownloadIncomplete:
            return "该词库包尚在 iCloud 云端占位中，请先在「文件」App 下载到本地后再导入。"
        case .cannotOpenFile:
            return "无法读取所选词库包文件，请检查文件权限或重新从「文件」App 导入。"
        case .packNotFound:
            return "未找到指定的已安装词库包。"
        }
    }
}

public struct LokeyLexiconPackMetadata: Codable, Sendable, Equatable, Identifiable {
    public let packId: String
    public let packName: String
    public let fileName: String
    public let wordCount: Int
    public let syllableCount: Int
    public let englishCount: Int
    public let associationCount: Int
    public let fileSizeBytes: Int64
    public let source: String
    public let sha256: String
    public let installedAt: Double

    public var id: String { fileName }
    public var sha256Prefix: String { String(sha256.prefix(12)) }

    public init(
        packId: String,
        packName: String,
        fileName: String,
        wordCount: Int,
        syllableCount: Int,
        englishCount: Int,
        associationCount: Int,
        fileSizeBytes: Int64,
        source: String,
        sha256: String,
        installedAt: Double = Date().timeIntervalSince1970
    ) {
        self.packId = packId
        self.packName = packName
        self.fileName = fileName
        self.wordCount = wordCount
        self.syllableCount = syllableCount
        self.englishCount = englishCount
        self.associationCount = associationCount
        self.fileSizeBytes = fileSizeBytes
        self.source = source
        self.sha256 = sha256
        self.installedAt = installedAt
    }
}

public struct LokeyLexiconPackActiveConfig: Codable, Sendable, Equatable {
    public let activeFileName: String
    public let sha256: String
    public let updatedAt: Double

    public init(activeFileName: String, sha256: String, updatedAt: Double = Date().timeIntervalSince1970) {
        self.activeFileName = activeFileName
        self.sha256 = sha256
        self.updatedAt = updatedAt
    }
}

public enum LokeyLexiconPackManager {
    public static let maxPackBytes = 512 * 1024 * 1024
    public static let activePackFileName = "active_pack.json"
    public static let activeDefaultsKey = "com.kianuni.lokey.activeLexiconPack.v1"

    public struct ValidatedPackSummary: Sendable, Equatable {
        public let wordCount: Int
        public let syllableCount: Int
        public let englishCount: Int
        public let associationCount: Int
        public let fileSizeBytes: Int64
        public let sha256: String
        public let lnlmWordCount: Int
        public let lnlmCharCount: Int
    }

    public enum ActiveSignature: Equatable, Sendable {
        case builtIn
        case externalPack(fileName: String, sha256: String, size: Int64, mtime: TimeInterval)
    }

    @inline(__always)
    private static func readU16(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    private static func readU32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    public static func computeSHA256(raw: UnsafeRawBufferPointer) -> String {
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        if let base = raw.baseAddress, raw.count > 0 {
            let chunkSize = 1024 * 1024
            var offset = 0
            while offset < raw.count {
                let len = min(chunkSize, raw.count - offset)
                CC_SHA256_Update(&ctx, base.advanced(by: offset), CC_LONG(len))
                offset += len
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseSHA256Text(_ text: String) -> String? {
        @inline(__always)
        func isValidHex64(_ s: String) -> Bool {
            s.count == 64 && s.unicodeScalars.allSatisfy {
                ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x66)
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // BSD tag format: `SHA256 (filename) = <64hex>` (or `SHA2-256 (filename) = <64hex>`)
            if let eqRange = trimmed.range(of: "=", options: .backwards) {
                let prefixUpper = trimmed[..<eqRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if prefixUpper.hasPrefix("SHA256") || prefixUpper.hasPrefix("SHA2-256") {
                    let afterEq = trimmed[eqRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidate = String(afterEq.split(whereSeparator: \.isWhitespace).first ?? Substring(afterEq)).lowercased()
                    return isValidHex64(candidate) ? candidate : nil
                }
            }

            guard let token = trimmed.split(whereSeparator: \.isWhitespace).first else { continue }
            let candidate = String(token).lowercased()
            return isValidHex64(candidate) ? candidate : nil
        }
        return nil
    }

    public static func hasLKLFMagic(at url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        return head == Data("LKLF".utf8)
    }

    public static func isInboxURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("-Inbox/") || path.contains("/Documents/Inbox/")
    }

    /// Copies a transient `-Inbox` or `/Documents/Inbox` file into `NSTemporaryDirectory()` and removes the Inbox original.
    /// Non-Inbox URLs are returned unchanged.
    public static func stageInboxFileIfNeeded(at url: URL) throws -> (url: URL, isTemporaryCopy: Bool) {
        guard isInboxURL(url) else {
            return (url, false)
        }
        let fm = FileManager.default
        let safeName = sanitizedPackFileName(from: url.lastPathComponent)
        let stagedURL = fm.temporaryDirectory
            .appendingPathComponent("lokeypack-preview-\(UUID().uuidString)-\(safeName)")
        try? fm.removeItem(at: stagedURL)
        try fm.copyItem(at: url, to: stagedURL)
        try? fm.removeItem(at: url)
        return (stagedURL, true)
    }

    public static func validatePack(
        nsData: NSData,
        expectedSHA256: String? = nil,
        computeHash: Bool = true,
        validateRecords: Bool = true
    ) throws -> ValidatedPackSummary {
        guard nsData.length >= 72 else {
            throw LokeyLexiconPackError.fileTooSmall
        }
        guard nsData.length <= maxPackBytes else {
            throw LokeyLexiconPackError.fileTooLarge(maxMB: maxPackBytes / (1024 * 1024))
        }
        let raw = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
        let magic = readU32(raw, at: 0)
        guard magic == 0x464C4B4C else {
            throw LokeyLexiconPackError.invalidMagic
        }
        let version = readU32(raw, at: 4)
        guard version == 2 else {
            throw LokeyLexiconPackError.unsupportedVersion(version)
        }

        let syllableCount = Int(readU32(raw, at: 8))
        let syllableOffset = Int(readU32(raw, at: 12))
        let nodeCount = Int(readU32(raw, at: 16))
        let nodeOffset = Int(readU32(raw, at: 20))
        let edgeCount = Int(readU32(raw, at: 24))
        let edgeOffset = Int(readU32(raw, at: 28))
        let wordCount = Int(readU32(raw, at: 32))
        let wordOffset = Int(readU32(raw, at: 36))
        let jianpinCount = Int(readU32(raw, at: 40))
        let jianpinOffset = Int(readU32(raw, at: 44))
        let englishCount = Int(readU32(raw, at: 48))
        let englishOffset = Int(readU32(raw, at: 52))
        let stringPoolSize = Int(readU32(raw, at: 56))
        let stringPoolOffset = Int(readU32(raw, at: 60))
        let assocCount = Int(readU32(raw, at: 64))
        let assocOffset = Int(readU32(raw, at: 68))

        let count = raw.count
        guard syllableCount > 0, syllableCount <= Int(UInt16.max),
              nodeCount > 0, wordCount > 0, stringPoolSize > 0,
              syllableOffset >= 72, syllableOffset <= count, (syllableCount + 1) * 16 <= count - syllableOffset,
              nodeOffset >= 72, nodeOffset <= count, nodeCount * 16 <= count - nodeOffset,
              edgeOffset >= 72, edgeOffset <= count, edgeCount * 8 <= count - edgeOffset,
              wordOffset >= 72, wordOffset <= count, wordCount * 8 <= count - wordOffset,
              jianpinOffset >= 72, jianpinOffset <= count, jianpinCount * 16 <= count - jianpinOffset,
              englishOffset >= 72, englishOffset <= count, englishCount * 16 <= count - englishOffset,
              stringPoolOffset >= 72, stringPoolOffset <= count, stringPoolSize <= count - stringPoolOffset,
              (assocCount == 0 || (assocOffset >= 72 && assocOffset <= count && assocCount * 16 <= count - assocOffset)) else {
            throw LokeyLexiconPackError.outOfBoundsSection
        }

        // Enforce strictly non-overlapping active LKLF sections (`>= 72`) and compute `maxSectionEnd`
        // across all active sections (including `assoc` and `stringPool`) before validating `LNLM-v2`.
        var activeSections: [(start: Int, end: Int)] = [
            (syllableOffset, syllableOffset + (syllableCount + 1) * 16),
            (nodeOffset, nodeOffset + nodeCount * 16),
            (wordOffset, wordOffset + wordCount * 8),
            (stringPoolOffset, stringPoolOffset + stringPoolSize),
        ]
        if edgeCount > 0 {
            activeSections.append((edgeOffset, edgeOffset + edgeCount * 8))
        }
        if jianpinCount > 0 {
            activeSections.append((jianpinOffset, jianpinOffset + jianpinCount * 16))
        }
        if englishCount > 0 {
            activeSections.append((englishOffset, englishOffset + englishCount * 16))
        }
        if assocCount > 0 {
            activeSections.append((assocOffset, assocOffset + assocCount * 16))
        }
        activeSections.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        for i in 1..<activeSections.count {
            if activeSections[i - 1].end > activeSections[i].start {
                throw LokeyLexiconPackError.outOfBoundsSection
            }
        }
        let maxSectionEnd = activeSections.reduce(72) { max($0, $1.end) }

        let rootFirstEdge = Int(readU32(raw, at: nodeOffset))
        let rootEdgeCount = Int(readU16(raw, at: nodeOffset + 4))
        let rootWordCount = Int(readU16(raw, at: nodeOffset + 6))
        let rootFirstWord = Int(readU32(raw, at: nodeOffset + 8))
        guard rootFirstEdge >= 0, rootEdgeCount >= 0, rootFirstEdge <= edgeCount - rootEdgeCount,
              rootFirstWord >= 0, rootWordCount >= 0, rootFirstWord <= wordCount - rootWordCount else {
            throw LokeyLexiconPackError.outOfBoundsSection
        }

        if validateRecords {
            for i in 0..<nodeCount {
                let nOff = nodeOffset + i * 16
                let firstEdge = Int(readU32(raw, at: nOff))
                let nEdgeCount = Int(readU16(raw, at: nOff + 4))
                let nWordCount = Int(readU16(raw, at: nOff + 6))
                let firstWord = Int(readU32(raw, at: nOff + 8))
                guard firstEdge >= 0, nEdgeCount >= 0, firstEdge <= edgeCount, nEdgeCount <= edgeCount - firstEdge,
                      firstWord >= 0, nWordCount >= 0, firstWord <= wordCount, nWordCount <= wordCount - firstWord else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
            for i in 0..<edgeCount {
                let eOff = edgeOffset + i * 8
                let sid = Int(readU16(raw, at: eOff))
                let target = Int(readU32(raw, at: eOff + 4))
                guard sid <= syllableCount, target < nodeCount else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
            for i in 0..<wordCount {
                let wOff = wordOffset + i * 8
                let sOff = Int(readU32(raw, at: wOff))
                let sLen = Int(readU16(raw, at: wOff + 4))
                guard sOff <= stringPoolSize, sLen <= stringPoolSize - sOff else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
            for i in 0..<jianpinCount {
                let jOff = jianpinOffset + i * 16
                let sOff = Int(readU32(raw, at: jOff + 8))
                let sLen = Int(readU16(raw, at: jOff + 12))
                guard sOff <= stringPoolSize, sLen <= stringPoolSize - sOff else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
            for i in 0..<englishCount {
                let eOff = englishOffset + i * 16
                let lOff = Int(readU32(raw, at: eOff))
                let dOff = Int(readU32(raw, at: eOff + 4))
                let lLen = Int(readU16(raw, at: eOff + 8))
                let dLen = Int(readU16(raw, at: eOff + 10))
                guard lOff <= stringPoolSize, lLen <= stringPoolSize - lOff,
                      dOff <= stringPoolSize, dLen <= stringPoolSize - dOff else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
            for i in 0..<assocCount {
                let aOff = assocOffset + i * 16
                let kOff = Int(readU32(raw, at: aOff))
                let vOff = Int(readU32(raw, at: aOff + 4))
                let kLen = Int(readU16(raw, at: aOff + 8))
                let vLen = Int(readU16(raw, at: aOff + 10))
                guard kOff <= stringPoolSize, kLen <= stringPoolSize - kOff,
                      vOff <= stringPoolSize, vLen <= stringPoolSize - vOff else {
                    throw LokeyLexiconPackError.outOfBoundsSection
                }
            }
        }

        let lnlmInfo: (offset: Int, size: Int, charCount: Int, wordCount: Int)
        do {
            lnlmInfo = try NeuralSentenceScorer.validateLNLMv2(
                in: raw,
                minimumOffset: maxSectionEnd
            )
        } catch NeuralSentenceScorer.LNLMValidationError.invalidFooter {
            throw LokeyLexiconPackError.invalidNeuralFooter
        } catch NeuralSentenceScorer.LNLMValidationError.invalidHeader {
            throw LokeyLexiconPackError.invalidNeuralHeader
        }

        let normalizedExpected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let needHash = computeHash || (normalizedExpected != nil && !normalizedExpected!.isEmpty)
        let actualHash = needHash ? computeSHA256(raw: raw) : ""
        if let expected = normalizedExpected, !expected.isEmpty, actualHash != expected {
            throw LokeyLexiconPackError.sha256Mismatch(expected: expected, actual: actualHash)
        }

        return ValidatedPackSummary(
            wordCount: wordCount,
            syllableCount: syllableCount,
            englishCount: englishCount,
            associationCount: assocCount,
            fileSizeBytes: Int64(count),
            sha256: actualHash,
            lnlmWordCount: lnlmInfo.wordCount,
            lnlmCharCount: lnlmInfo.charCount
        )
    }

    private static func mapFileWithCoordination(at url: URL) throws -> NSData {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        var isDirObjC: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirObjC)
        if (values?.isDirectory == true) || (values?.isPackage == true) || (exists && isDirObjC.boolValue) {
            throw LokeyLexiconPackError.directoryNotSupported
        }
        if let sz = values?.fileSize, sz > maxPackBytes {
            throw LokeyLexiconPackError.fileTooLarge(maxMB: maxPackBytes / (1024 * 1024))
        }
        if let attrSize = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           attrSize.int64Value > Int64(maxPackBytes) {
            throw LokeyLexiconPackError.fileTooLarge(maxMB: maxPackBytes / (1024 * 1024))
        }
        let isUbiquitous = values?.isUbiquitousItem ?? false
        if isUbiquitous && values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }

        do {
            return try NSData(contentsOf: url, options: [.mappedIfSafe])
        } catch let directError {
            var coordinated: NSData?
            var innerError: Error?
            var coordError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { coordURL in
                do {
                    if let attrSize = (try? FileManager.default.attributesOfItem(atPath: coordURL.path))?[.size] as? NSNumber,
                       attrSize.int64Value > Int64(maxPackBytes) {
                        throw LokeyLexiconPackError.fileTooLarge(maxMB: maxPackBytes / (1024 * 1024))
                    }
                    coordinated = try NSData(contentsOf: coordURL, options: [.mappedIfSafe])
                } catch {
                    innerError = error
                }
            }
            if let mapped = coordinated {
                return mapped
            }
            if let packErr = innerError as? LokeyLexiconPackError {
                throw packErr
            }
            if isUbiquitous {
                throw LokeyLexiconPackError.iCloudDownloadIncomplete
            }
            _ = coordError ?? directError
            throw LokeyLexiconPackError.cannotOpenFile
        }
    }

    public static func inspectPack(
        at sourceURL: URL,
        expectedSHA256: String? = nil
    ) throws -> ValidatedPackSummary {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let mapped = try mapFileWithCoordination(at: sourceURL)
        return try validatePack(nsData: mapped, expectedSHA256: expectedSHA256, computeHash: true)
    }

    public static func sanitizedPackFileName(from rawName: String) -> String {
        let trimmedInput = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty || trimmedInput == "." || trimmedInput == ".." || trimmedInput.hasSuffix("/") {
            return "external.lokeypack"
        }
        let rawLast = trimmedInput.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if rawLast.isEmpty || rawLast == "." || rawLast == ".." {
            return "external.lokeypack"
        }
        let base = URL(fileURLWithPath: rawLast).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." || base == ".lokeypack" {
            return "external.lokeypack"
        }
        if base.lowercased().hasSuffix(".lokeypack") {
            return base
        }
        return base + ".lokeypack"
    }

    public static func displayPackName(fromFileName fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".lokeypack") {
            return String(fileName.dropLast(".lokeypack".count))
        }
        return fileName
    }

    private static func resolveLexiconsDirectory(_ overrideDir: URL?) -> URL {
        if let overrideDir {
            try? FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
            return overrideDir
        }
        return LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: true)
    }

    private static func resolveDefaults(_ overrideDefaults: UserDefaults?) -> UserDefaults {
        overrideDefaults ?? LokeyAppGroup.sharedDefaults()
    }

    @discardableResult
    public static func installPack(
        from sourceURL: URL,
        packName: String? = nil,
        sourceLabel: String = "用户导入 (.lokeypack)",
        expectedSHA256: String? = nil,
        activate: Bool = true,
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) throws -> LokeyLexiconPackMetadata {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
            if isInboxURL(sourceURL) {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        var effectiveExpected = expectedSHA256
        if effectiveExpected == nil && !isInboxURL(sourceURL) {
            let sidecarHashURL = URL(fileURLWithPath: sourceURL.path + ".sha256")
            if let sidecarText = try? String(contentsOf: sidecarHashURL, encoding: .utf8),
               let parsed = parseSHA256Text(sidecarText) {
                effectiveExpected = parsed
            }
        }

        let mapped = try mapFileWithCoordination(at: sourceURL)
        let summary = try validatePack(nsData: mapped, expectedSHA256: effectiveExpected, computeHash: true)

        let fm = FileManager.default
        let targetDir = resolveLexiconsDirectory(lexiconsDirectory)
        let fileName = sanitizedPackFileName(from: sourceURL.lastPathComponent)
        let destPackURL = targetDir.appendingPathComponent(fileName)
        let destMetaURL = targetDir.appendingPathComponent(fileName + ".json")
        let stagingPackURL = targetDir.appendingPathComponent(".staging-\(UUID().uuidString)-\(fileName)")
        defer { try? fm.removeItem(at: stagingPackURL) }

        do {
            try mapped.write(to: stagingPackURL, options: [.atomic])
        } catch {
            throw LokeyLexiconPackError.cannotOpenFile
        }

        let stagedMapped = try NSData(contentsOf: stagingPackURL, options: [.mappedIfSafe])
        guard stagedMapped.length == Int(summary.fileSizeBytes) else {
            throw LokeyLexiconPackError.outOfBoundsSection
        }

        let resolvedName = (packName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? displayPackName(fromFileName: fileName)
        let metadata = LokeyLexiconPackMetadata(
            packId: "\(fileName)#\(summary.sha256.prefix(12))",
            packName: resolvedName,
            fileName: fileName,
            wordCount: summary.wordCount,
            syllableCount: summary.syllableCount,
            englishCount: summary.englishCount,
            associationCount: summary.associationCount,
            fileSizeBytes: summary.fileSizeBytes,
            source: sourceLabel,
            sha256: summary.sha256
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metaData = try encoder.encode(metadata)
        try metaData.write(to: destMetaURL, options: [.atomic])

        if fm.fileExists(atPath: destPackURL.path) {
            _ = try fm.replaceItemAt(destPackURL, withItemAt: stagingPackURL)
        } else {
            try fm.moveItem(at: stagingPackURL, to: destPackURL)
        }

        if activate {
            let activeCfg = LokeyLexiconPackActiveConfig(activeFileName: fileName, sha256: summary.sha256)
            let activeData = try encoder.encode(activeCfg)
            try activeData.write(to: targetDir.appendingPathComponent(activePackFileName), options: [.atomic])
            resolveDefaults(defaults).set(fileName, forKey: activeDefaultsKey)
            if lexiconsDirectory == nil {
                LokeyIPC.postBaseLexiconChanged()
            }
        }
        return metadata
    }

    public static func listInstalledPacks(in lexiconsDirectory: URL? = nil) -> [LokeyLexiconPackMetadata] {
        let fm = FileManager.default
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        var packs: [LokeyLexiconPackMetadata] = []
        for url in entries where url.lastPathComponent.hasSuffix(".lokeypack.json") {
            guard let data = try? Data(contentsOf: url),
                  let meta = try? decoder.decode(LokeyLexiconPackMetadata.self, from: data) else {
                continue
            }
            let packURL = dir.appendingPathComponent(meta.fileName)
            if fm.fileExists(atPath: packURL.path) {
                packs.append(meta)
            }
        }
        return packs.sorted { $0.installedAt > $1.installedAt }
    }

    private static func configuredActiveFileName(
        in dir: URL,
        defaults: UserDefaults? = nil
    ) -> String? {
        let activeURL = dir.appendingPathComponent(activePackFileName)
        if let data = try? Data(contentsOf: activeURL),
           let cfg = try? JSONDecoder().decode(LokeyLexiconPackActiveConfig.self, from: data),
           !cfg.activeFileName.isEmpty {
            return cfg.activeFileName
        }
        if let fallbackName = resolveDefaults(defaults).string(forKey: activeDefaultsKey),
           !fallbackName.isEmpty {
            return fallbackName
        }
        return nil
    }

    public static func activePackMetadata(
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) -> LokeyLexiconPackMetadata? {
        let fm = FileManager.default
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        guard let fileName = configuredActiveFileName(in: dir, defaults: defaults) else { return nil }
        let packURL = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: packURL.path),
              let mapped = try? NSData(contentsOf: packURL, options: [.mappedIfSafe]),
              let summary = try? validatePack(nsData: mapped, computeHash: false, validateRecords: false) else {
            return nil
        }
        let metaURL = dir.appendingPathComponent(fileName + ".json")
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(LokeyLexiconPackMetadata.self, from: metaData) {
            return meta
        }
        let sz = ((try? fm.attributesOfItem(atPath: packURL.path))?[.size] as? NSNumber)?.int64Value ?? summary.fileSizeBytes
        return LokeyLexiconPackMetadata(
            packId: fileName,
            packName: displayPackName(fromFileName: fileName),
            fileName: fileName,
            wordCount: summary.wordCount,
            syllableCount: summary.syllableCount,
            englishCount: summary.englishCount,
            associationCount: summary.associationCount,
            fileSizeBytes: sz,
            source: "外部词库包 (.lokeypack)",
            sha256: ""
        )
    }

    public static func activatePack(
        fileName: String,
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) throws {
        let dir = resolveLexiconsDirectory(lexiconsDirectory)
        let safeFile = sanitizedPackFileName(from: fileName)
        let packURL = dir.appendingPathComponent(safeFile)
        guard FileManager.default.fileExists(atPath: packURL.path) else {
            throw LokeyLexiconPackError.packNotFound
        }
        let mapped = try NSData(contentsOf: packURL, options: [.mappedIfSafe])
        let summary = try validatePack(nsData: mapped, computeHash: false)
        let metaURL = dir.appendingPathComponent(safeFile + ".json")
        let sha: String
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(LokeyLexiconPackMetadata.self, from: metaData),
           !meta.sha256.isEmpty {
            sha = meta.sha256
        } else {
            sha = computeSHA256(raw: UnsafeRawBufferPointer(start: mapped.bytes, count: mapped.length))
        }
        let cfg = LokeyLexiconPackActiveConfig(activeFileName: safeFile, sha256: sha)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cfg).write(to: dir.appendingPathComponent(activePackFileName), options: [.atomic])
        resolveDefaults(defaults).set(safeFile, forKey: activeDefaultsKey)
        _ = summary
        if lexiconsDirectory == nil {
            LokeyIPC.postBaseLexiconChanged()
        }
    }

    public static func activateBuiltInLexicon(
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) {
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        let activeURL = dir.appendingPathComponent(activePackFileName)
        try? FileManager.default.removeItem(at: activeURL)
        resolveDefaults(defaults).removeObject(forKey: activeDefaultsKey)
        if lexiconsDirectory == nil {
            LokeyIPC.postBaseLexiconChanged()
        }
    }

    public static func deletePack(
        fileName: String,
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) throws {
        let fm = FileManager.default
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        let safeFile = sanitizedPackFileName(from: fileName)
        let wasActive = configuredActiveFileName(in: dir, defaults: defaults) == safeFile
        try? fm.removeItem(at: dir.appendingPathComponent(safeFile))
        try? fm.removeItem(at: dir.appendingPathComponent(safeFile + ".json"))
        if wasActive {
            activateBuiltInLexicon(in: lexiconsDirectory, defaults: defaults)
        }
    }

    public static func currentActiveSignature(
        in lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) -> ActiveSignature {
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        let activeURL = dir.appendingPathComponent(activePackFileName)
        var st = stat()
        let hasActiveFile = activeURL.path.withCString { stat($0, &st) == 0 }
        guard hasActiveFile,
              let data = try? Data(contentsOf: activeURL),
              let cfg = try? JSONDecoder().decode(LokeyLexiconPackActiveConfig.self, from: data),
              !cfg.activeFileName.isEmpty else {
            if let fallback = resolveDefaults(defaults).string(forKey: activeDefaultsKey),
               !fallback.isEmpty {
                let packURL = dir.appendingPathComponent(fallback)
                var pst = stat()
                if packURL.path.withCString({ stat($0, &pst) == 0 }) {
                    let mtime = Double(pst.st_mtimespec.tv_sec) + Double(pst.st_mtimespec.tv_nsec) * 1e-9
                    return .externalPack(fileName: fallback, sha256: "", size: Int64(pst.st_size), mtime: mtime)
                }
            }
            return .builtIn
        }
        let packURL = dir.appendingPathComponent(cfg.activeFileName)
        var pst = stat()
        guard packURL.path.withCString({ stat($0, &pst) == 0 }) else {
            return .builtIn
        }
        let mtime = Double(pst.st_mtimespec.tv_sec) + Double(pst.st_mtimespec.tv_nsec) * 1e-9
        return .externalPack(
            fileName: cfg.activeFileName,
            sha256: cfg.sha256,
            size: Int64(pst.st_size),
            mtime: mtime
        )
    }

    public static func resolveActiveOrBuiltInLexicon(
        builtInURL: URL?,
        lexiconsDirectory: URL? = nil,
        defaults: UserDefaults? = nil
    ) -> (lexicon: MmapLexicon?, activeMetadata: LokeyLexiconPackMetadata?, didFallbackFromCorruptOrMissingPack: Bool) {
        let dir = lexiconsDirectory ?? LokeyAppGroup.sharedLexiconsDirectoryURL(createIfNeeded: false)
        let configuredFileName = configuredActiveFileName(in: dir, defaults: defaults)

        var didFallback = false
        if let fileName = configuredFileName {
            let packURL = dir.appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: packURL.path),
               let mapped = try? NSData(contentsOf: packURL, options: [.mappedIfSafe]),
               (try? validatePack(nsData: mapped, computeHash: false, validateRecords: false)) != nil,
               let externalLexicon = try? MmapLexicon(contentsOf: packURL) {
                let meta = activePackMetadata(in: lexiconsDirectory, defaults: defaults)
                return (externalLexicon, meta, false)
            }
            didFallback = true
        }

        if let builtInURL, let builtInLexicon = try? MmapLexicon(contentsOf: builtInURL) {
            return (builtInLexicon, nil, didFallback)
        }
        return (nil, nil, didFallback)
    }
}
