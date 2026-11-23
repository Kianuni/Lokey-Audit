import Foundation
import Accelerate
import simd

/// Pure-offline, zero-network On-Device Neural Language Model (`LNLM v2`).
/// Evaluates whole-sentence syntactic & semantic coherence using 32-dimensional dual embeddings
/// (`v_ctx`, `v_tgt`, `e_ctx`, `e_tgt`) and a 2-layer gated recurrent SiLU MLP + bilinear transition network
/// accelerated with Apple Silicon `SIMD8<Float> x 4` vector registers (`< 15 ns` per inner-loop transition).
public final class NeuralSentenceScorer: @unchecked Sendable {
    /// 32-dimensional vector stored across four `SIMD8<Float>` Apple Silicon NEON/AMX registers.
    @frozen public struct Vec32: Sendable, Equatable {
        public var v0: SIMD8<Float>
        public var v1: SIMD8<Float>
        public var v2: SIMD8<Float>
        public var v3: SIMD8<Float>

        public static let zero = Vec32(v0: .zero, v1: .zero, v2: .zero, v3: .zero)

        @inline(__always)
        public init(v0: SIMD8<Float>, v1: SIMD8<Float>, v2: SIMD8<Float>, v3: SIMD8<Float>) {
            self.v0 = v0
            self.v1 = v1
            self.v2 = v2
            self.v3 = v3
        }

        @inline(__always)
        public static func + (lhs: Vec32, rhs: Vec32) -> Vec32 {
            Vec32(v0: lhs.v0 + rhs.v0, v1: lhs.v1 + rhs.v1, v2: lhs.v2 + rhs.v2, v3: lhs.v3 + rhs.v3)
        }

        @inline(__always)
        public static func - (lhs: Vec32, rhs: Vec32) -> Vec32 {
            Vec32(v0: lhs.v0 - rhs.v0, v1: lhs.v1 - rhs.v1, v2: lhs.v2 - rhs.v2, v3: lhs.v3 - rhs.v3)
        }

        @inline(__always)
        public static func * (lhs: Vec32, rhs: Vec32) -> Vec32 {
            Vec32(v0: lhs.v0 * rhs.v0, v1: lhs.v1 * rhs.v1, v2: lhs.v2 * rhs.v2, v3: lhs.v3 * rhs.v3)
        }

        @inline(__always)
        public static func * (scalar: Float, rhs: Vec32) -> Vec32 {
            Vec32(v0: scalar * rhs.v0, v1: scalar * rhs.v1, v2: scalar * rhs.v2, v3: scalar * rhs.v3)
        }

        @inline(__always)
        public func dot(_ other: Vec32) -> Float {
            let s01 = v0 * other.v0 + v1 * other.v1
            let s23 = v2 * other.v2 + v3 * other.v3
            return (s01 + s23).sum()
        }
    }

    public struct EmbeddingPair: Sendable {
        public let ctx: Vec32
        public let tgt: Vec32

        public static let zero = EmbeddingPair(ctx: .zero, tgt: .zero)
    }

    /// Pre-bundled neural embeddings for a lexical word so Viterbi inner loops run 100% lock-free in SIMD registers.
    /// Left-context matrix projections (`W_ctx * ctx`, `B_direct * ctx`, `W_char * lastCharCtx`, `W_sem * semCtx`)
    /// are computed lazily only when a word survives beam pruning to act as a predecessor context.
    public struct WordNeuralRecord: Sendable {
        public let ctx: Vec32
        public let tanhCtx: Vec32
        public let tgt: Vec32
        public let firstCharTgt: Vec32
        public let eosCtxScore: Float
        public let charCount: Int
        public let isAccidentalSingleton: Bool
        /// Asymmetric 64-dim semantic upper-half (`dims[32..<64]`).
        public let semCtx: Vec32
        public let semTgt: Vec32
        fileprivate let cacheId: UInt32
        fileprivate let lastCharScalar: UInt32

        @inline(__always)
        public init(
            ctx: Vec32,
            tanhCtx: Vec32,
            tgt: Vec32,
            firstCharTgt: Vec32,
            wx: Vec32 = .zero,
            bd: Vec32 = .zero,
            cp: Vec32 = .zero,
            eosCtxScore: Float,
            charCount: Int,
            isAccidentalSingleton: Bool,
            semCtx: Vec32 = .zero,
            semTgt: Vec32 = .zero,
            semPred: Vec32 = .zero
        ) {
            _ = wx
            _ = bd
            _ = cp
            _ = semPred
            self.ctx = ctx
            self.tanhCtx = tanhCtx
            self.tgt = tgt
            self.firstCharTgt = firstCharTgt
            self.eosCtxScore = eosCtxScore
            self.charCount = charCount
            self.isAccidentalSingleton = isAccidentalSingleton
            self.semCtx = semCtx
            self.semTgt = semTgt
            self.cacheId = 0
            self.lastCharScalar = 0
        }

        @inline(__always)
        fileprivate init(
            ctx: Vec32,
            tanhCtx: Vec32,
            tgt: Vec32,
            firstCharTgt: Vec32,
            eosCtxScore: Float,
            charCount: Int,
            isAccidentalSingleton: Bool,
            semCtx: Vec32,
            semTgt: Vec32,
            cacheId: UInt32,
            lastCharScalar: UInt32
        ) {
            self.ctx = ctx
            self.tanhCtx = tanhCtx
            self.tgt = tgt
            self.firstCharTgt = firstCharTgt
            self.eosCtxScore = eosCtxScore
            self.charCount = charCount
            self.isAccidentalSingleton = isAccidentalSingleton
            self.semCtx = semCtx
            self.semTgt = semTgt
            self.cacheId = cacheId
            self.lastCharScalar = lastCharScalar
        }

        public static let empty = WordNeuralRecord(
            ctx: .zero,
            tanhCtx: .zero,
            tgt: .zero,
            firstCharTgt: .zero,
            eosCtxScore: 0.0,
            charCount: 0,
            isAccidentalSingleton: false,
            semCtx: .zero,
            semTgt: .zero,
            cacheId: 0,
            lastCharScalar: 0
        )
    }

    private struct ContextProjectionSlot {
        var cacheId: UInt32
        var wx: Vec32
        var bd: Vec32
        var cp: Vec32
        var semPred: Vec32

        static let empty = ContextProjectionSlot(cacheId: 0, wx: .zero, bd: .zero, cp: .zero, semPred: .zero)
    }

    public struct StepPredictor: Sendable {
        public let wordPred: Vec32
        public let charPred: Vec32
        public let z: Vec32
        public let prevHidden: Vec32
        public let lastCtx: Vec32
        public let hasContext: Bool
        /// Combined asymmetric 64-dim semantic + gated cross-sentence topic predictor (`semScale * W_sem * semCtx + topicScale * gate * W_topic * topicMemory`).
        public let semPred: Vec32

        @inline(__always)
        public init(
            wordPred: Vec32,
            charPred: Vec32,
            z: Vec32,
            prevHidden: Vec32,
            lastCtx: Vec32,
            hasContext: Bool,
            semPred: Vec32 = .zero
        ) {
            self.wordPred = wordPred
            self.charPred = charPred
            self.z = z
            self.prevHidden = prevHidden
            self.lastCtx = lastCtx
            self.hasContext = hasContext
            self.semPred = semPred
        }
    }

    private let backingData: NSData
    private let rawBuffer: UnsafeRawBufferPointer
    private let hasBinarySection: Bool
    private let modelVersion: UInt32
    private let charVocabCount: Int
    private let charMapOffset: Int
    private let charEmbOffset: Int
    private let wordVocabCount: Int
    private let wordTableOffset: Int
    private let stringPoolOffset: Int
    private let stringPoolSize: Int

    // L1-cache-resident 32x32 neural network matrices (`25.3 KB` total)
    private let wCtxRows: [Vec32]
    private let wRecRows: [Vec32]
    private let b1: Vec32
    private let wProjRows: [Vec32]
    private let bDirectRows: [Vec32]
    private let bSkipRows: [Vec32]
    private let b2: Vec32
    private let wCharRows: [Vec32]
    private let alpha: Vec32
    private let oneMinusAlpha: Vec32
    public let hBos: Vec32
    private let wEos: Vec32
    private let uEos: Vec32

    // L1-cache-resident 32x32 backward rerank head (`LNBR` v1/v2, 25.3 KB core + optional Int8 backward target residuals)
    private let hasBackwardHead: Bool
    private let bwdVersion: UInt32
    private let bwdBackingData: NSData?
    private let bwdRawBuffer: UnsafeRawBufferPointer
    private let bwdCharResCount: Int
    private let bwdCharResOffset: Int
    private let bwdWordResCount: Int
    private let bwdWordResOffset: Int
    private let bwdWordPoolOffset: Int
    private let bwdWordPoolSize: Int
    private let bwdWCtxRows: [Vec32]
    private let bwdWRecRows: [Vec32]
    private let bwdB1: Vec32
    private let bwdWProjRows: [Vec32]
    private let bwdBDirectRows: [Vec32]
    private let bwdBSkipRows: [Vec32]
    private let bwdB2: Vec32
    private let bwdWCharRows: [Vec32]
    private let bwdAlpha: Vec32
    private let bwdOneMinusAlpha: Vec32
    private let bwdHEos: Vec32
    private let bwdWBos: Vec32
    private let bwdUBos: Vec32

    // Zero-copy `mmap` Int8 2-layer SiLU blind-typing typo reranker (`LNTR` v1, 46,768 bytes)
    private let hasTypoReranker: Bool
    private let lntrBackingData: NSData?
    private let lntrRawBuffer: UnsafeRawBufferPointer
    private let lntrScale1: [Float]
    private let lntrB1: [Float]
    private let lntrScale2: [SIMD8<Float>]
    private let lntrB2: [SIMD8<Float>]
    private let lntrW3: [SIMD8<Float>]
    private let lntrResLin0: SIMD8<Float>
    private let lntrResLin1: SIMD8<Float>
    private let lntrB3: Float
    private let lntrMaxDeltaQ8: Int

    // Asymmetric 64-dim (`Float16` / `Int8`) semantic dual embeddings + cross-sentence decaying topic memory gate (`LNS6` v1)
    private let hasSemantic64: Bool
    private let sem64QuantMode: UInt32
    private let sem64BackingData: NSData?
    private let sem64RawBuffer: UnsafeRawBufferPointer
    private let sem64CharCount: Int
    private let sem64CharMapOffset: Int
    private let sem64CharEmbOffset: Int
    private let sem64WordCount: Int
    private let sem64WordTableOffset: Int
    private let sem64PoolOffset: Int
    private let sem64PoolSize: Int
    private let sem64WSemRows: [Vec32]
    private let sem64WTopicRows: [Vec32]
    private let sem64WGateH: Vec32
    private let sem64WGateTopic: Vec32
    private let sem64BGate: Float
    private let sem64SemScale: Float
    private let sem64TopicScale: Float
    private let sem64ClauseDecay: Float
    private let sem64SentenceDecay: Float
    private let sem64MaxBonusQ8: Int

    // Consolidated in-memory cache for hot word records + lazy left-context projections
    private var cacheLock = os_unfair_lock_s()
    private var wordRecordCache: [String: WordNeuralRecord] = [:]
    private var wordRecordRing: [String] = []
    private var wordRecordRingCursor: Int = 0
    private var nextRecordCacheId: UInt32 = 1
    private var contextProjSlots: [ContextProjectionSlot] = []
    private static let maxWordRecordCacheCount = 768
    private static let contextProjSlotCount = 256
    private static let contextProjSlotMask: UInt32 = 255

    public static let magicLNLM: UInt32 = 0x4D4C4E4C // "LNLM"
    public static let magicLNBR: UInt32 = 0x52424E4C // "LNBR"
    public static let magicLNTR: UInt32 = 0x52544E4C // "LNTR"
    public static let magicLNS6: UInt32 = 0x36534E4C // "LNS6"
    public static let magicLKEX: UInt32 = 0x58454B4C // "LKEX"
    public static let backwardBinaryByteSize: Int = 16 + 6336 * 4
    public static let typoRerankerByteSize: Int = 46_768
    public static let typoFeatureDim: Int = 64
    public static let maxBonusQ8: Int = 520
    public static let minBonusQ8: Int = -560

    public enum LNLMValidationError: Error, Equatable {
        case invalidFooter
        case invalidHeader
    }

    /// Parses and validates an optional embedded `LKEX` v1 neural extension container (`LNBR`, `LNTR`, `LNS6`)
    /// located between `endOfLNLM` (`off + sz`) and `footerOff` (`raw.count - 16`) inside a single `.lokeypack`.
    public static func parseEmbeddedLKEXRanges(
        in raw: UnsafeRawBufferPointer,
        endOfLNLM: Int,
        footerOffset: Int,
        validatePayloads: Bool
    ) throws -> (bwd: Range<Int>?, lntr: Range<Int>?, sem64: Range<Int>?)? {
        guard footerOffset >= endOfLNLM, footerOffset - endOfLNLM >= 32 else {
            return nil
        }
        let lkexOff = footerOffset - 32
        guard loadU32(raw, at: lkexOff) == magicLKEX else {
            return nil
        }
        let lkexVer = loadU32(raw, at: lkexOff + 4)
        guard lkexVer == 1 else {
            throw LNLMValidationError.invalidHeader
        }
        let bwdOff = Int(loadU32(raw, at: lkexOff + 8))
        let bwdLen = Int(loadU32(raw, at: lkexOff + 12))
        let lntrOff = Int(loadU32(raw, at: lkexOff + 16))
        let lntrLen = Int(loadU32(raw, at: lkexOff + 20))
        let sem64Off = Int(loadU32(raw, at: lkexOff + 24))
        let sem64Len = Int(loadU32(raw, at: lkexOff + 28))

        func checkRange(_ rOff: Int, _ rLen: Int) throws -> Range<Int>? {
            if rLen == 0 {
                guard rOff == 0 else { throw LNLMValidationError.invalidHeader }
                return nil
            }
            guard rLen > 0, rOff >= endOfLNLM, rOff <= lkexOff - rLen else {
                throw LNLMValidationError.invalidHeader
            }
            return rOff..<(rOff + rLen)
        }

        let rBwd = try checkRange(bwdOff, bwdLen)
        let rLntr = try checkRange(lntrOff, lntrLen)
        let rSem64 = try checkRange(sem64Off, sem64Len)

        let active = [rBwd, rLntr, rSem64].compactMap { $0 }.sorted { $0.lowerBound < $1.lowerBound }
        for i in 1..<active.count {
            if active[i - 1].upperBound > active[i].lowerBound {
                throw LNLMValidationError.invalidHeader
            }
        }

        if validatePayloads, let base = raw.baseAddress {
            if let r = rBwd {
                let slice = NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: r.lowerBound)), length: r.count, freeWhenDone: false)
                guard parseBackwardHead(slice).loaded else { throw LNLMValidationError.invalidHeader }
            }
            if let r = rLntr {
                let slice = NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: r.lowerBound)), length: r.count, freeWhenDone: false)
                guard parseTypoReranker(slice).loaded else { throw LNLMValidationError.invalidHeader }
            }
            if let r = rSem64 {
                let slice = NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: r.lowerBound)), length: r.count, freeWhenDone: false)
                guard parseSemantic64(slice).loaded else { throw LNLMValidationError.invalidHeader }
            }
        }
        return (rBwd, rLntr, rSem64)
    }

    public static func validateLNLMv2(
        in raw: UnsafeRawBufferPointer,
        minimumOffset: Int
    ) throws -> (offset: Int, size: Int, charCount: Int, wordCount: Int) {
        let minOff = max(72, minimumOffset)
        guard raw.count >= minOff + 25376 + 16 else {
            throw LNLMValidationError.invalidFooter
        }
        let footerOff = raw.count - 16
        let magic = loadU32(raw, at: footerOff)
        let ver = loadU32(raw, at: footerOff + 4)
        let off = Int(loadU32(raw, at: footerOff + 8))
        let sz = Int(loadU32(raw, at: footerOff + 12))
        guard magic == magicLNLM,
              ver == 2,
              off >= minOff,
              sz >= 25376,
              off <= footerOff - sz else {
            throw LNLMValidationError.invalidFooter
        }
        let hdrMagic = loadU32(raw, at: off)
        let dim = loadU32(raw, at: off + 4)
        guard hdrMagic == magicLNLM, dim == 32 else {
            throw LNLMValidationError.invalidHeader
        }
        let cCount = Int(loadU32(raw, at: off + 8))
        let cMapOff = Int(loadU32(raw, at: off + 12))
        let cEmbOff = Int(loadU32(raw, at: off + 16))
        let wCount = Int(loadU32(raw, at: off + 20))
        let wTabOff = Int(loadU32(raw, at: off + 24))
        let mlpOff = Int(loadU32(raw, at: off + 28))
        let endBound = off + sz
        guard cCount <= Int(UInt16.max),
              cMapOff >= off + 32,
              cEmbOff >= off + 32,
              wTabOff >= off + 32,
              mlpOff >= off + 32,
              cMapOff <= endBound - 20992 * 2,
              cEmbOff <= endBound - (cCount + 1) * 64,
              wTabOff <= endBound - wCount * 72,
              mlpOff <= endBound - 25344 else {
            throw LNLMValidationError.invalidHeader
        }
        for i in 0..<6336 {
            let weight = Float(bitPattern: loadU32(raw, at: mlpOff + i * 4))
            guard weight.isFinite, abs(weight) <= 1.0e6 else {
                throw LNLMValidationError.invalidHeader
            }
        }
        _ = try parseEmbeddedLKEXRanges(
            in: raw,
            endOfLNLM: endBound,
            footerOffset: footerOff,
            validatePayloads: true
        )
        return (offset: off, size: sz, charCount: cCount, wordCount: wCount)
    }

    private struct ParsedBackwardHead {
        let loaded: Bool
        let version: UInt32
        let backingData: NSData?
        let rawBuffer: UnsafeRawBufferPointer
        let charResCount: Int
        let charResOffset: Int
        let wordResCount: Int
        let wordResOffset: Int
        let wordPoolOffset: Int
        let wordPoolSize: Int
        let wCtxRows: [Vec32]
        let wRecRows: [Vec32]
        let b1: Vec32
        let wProjRows: [Vec32]
        let bDirectRows: [Vec32]
        let bSkipRows: [Vec32]
        let b2: Vec32
        let wCharRows: [Vec32]
        let alpha: Vec32
        let oneMinusAlpha: Vec32
        let hEos: Vec32
        let wBos: Vec32
        let uBos: Vec32

        static var empty: ParsedBackwardHead {
            let zeroRows = Array(repeating: Vec32.zero, count: 32)
            let half = Vec32(
                v0: SIMD8<Float>(repeating: 0.5),
                v1: SIMD8<Float>(repeating: 0.5),
                v2: SIMD8<Float>(repeating: 0.5),
                v3: SIMD8<Float>(repeating: 0.5)
            )
            return ParsedBackwardHead(
                loaded: false,
                version: 0,
                backingData: nil,
                rawBuffer: UnsafeRawBufferPointer(start: nil, count: 0),
                charResCount: 0,
                charResOffset: 0,
                wordResCount: 0,
                wordResOffset: 0,
                wordPoolOffset: 0,
                wordPoolSize: 0,
                wCtxRows: zeroRows,
                wRecRows: zeroRows,
                b1: .zero,
                wProjRows: zeroRows,
                bDirectRows: zeroRows,
                bSkipRows: zeroRows,
                b2: .zero,
                wCharRows: zeroRows,
                alpha: half,
                oneMinusAlpha: half,
                hEos: .zero,
                wBos: .zero,
                uBos: .zero
            )
        }
    }

    @inline(__always)
    private static func compareStaticBytes(
        _ raw: UnsafeRawBufferPointer,
        offsetA: Int,
        lenA: Int,
        offsetB: Int,
        lenB: Int
    ) -> Int {
        guard let base = raw.baseAddress else { return -1 }
        let n = min(lenA, lenB)
        if n > 0 {
            let c = memcmp(base.advanced(by: offsetA), base.advanced(by: offsetB), n)
            if c != 0 { return c < 0 ? -1 : 1 }
        }
        if lenA == lenB { return 0 }
        return lenA < lenB ? -1 : 1
    }

    private static func parseBackwardHead(_ data: NSData?) -> ParsedBackwardHead {
        guard let data, data.length >= backwardBinaryByteSize else {
            return .empty
        }
        let raw = UnsafeRawBufferPointer(start: data.bytes, count: data.length)
        let magic = loadU32(raw, at: 0)
        let ver = loadU32(raw, at: 4)
        let dim = loadU32(raw, at: 8)
        let floatCount = loadU32(raw, at: 12)
        guard magic == magicLNBR, (ver == 1 || ver == 2), dim == 32, floatCount == 6336 else {
            return .empty
        }

        let mlpStart = (ver == 2) ? 32 : 16
        guard raw.count >= mlpStart + 6336 * 4 else {
            return .empty
        }

        var charResCount = 0
        var charResOffset = 0
        var wordResCount = 0
        var wordResOffset = 0
        var wordPoolOffset = 0
        var wordPoolSize = 0

        if ver == 2 {
            let cCount = Int(loadU32(raw, at: 16))
            let cOff = Int(loadU32(raw, at: 20))
            let wCount = Int(loadU32(raw, at: 24))
            let wOff = Int(loadU32(raw, at: 28))
            let minTableOff = 32 + 6336 * 4
            guard cCount >= 0, cCount <= 20992,
                  wCount >= 0, wCount <= Int(UInt16.max),
                  (cCount == 0 || (cOff >= minTableOff && cOff <= raw.count && cCount * 36 <= raw.count - cOff)),
                  (wCount == 0 || (wOff >= minTableOff && wOff <= raw.count && wCount * 40 <= raw.count - wOff)) else {
                return .empty
            }
            if cCount > 0 && wCount > 0 {
                let cEnd = cOff + cCount * 36
                guard cEnd <= wOff else { return .empty }
            }
            if cCount > 0 {
                var prevCode = -1
                for i in 0..<cCount {
                    let codeOff = Int(loadU16(raw, at: cOff + i * 36))
                    guard codeOff > prevCode && codeOff < 20992 else { return .empty }
                    prevCode = codeOff
                }
            }
            let pOff = wCount > 0 ? (wOff + wCount * 40) : raw.count
            guard pOff <= raw.count else { return .empty }
            let pSize = raw.count - pOff
            if wCount > 0 {
                var prevOff = 0
                var prevLen = 0
                for i in 0..<wCount {
                    let rec = wOff + i * 40
                    let sOff = Int(loadU32(raw, at: rec))
                    let sLen = Int(loadU16(raw, at: rec + 4))
                    guard sLen > 0, sOff <= pSize, sLen <= pSize - sOff else { return .empty }
                    if i > 0 {
                        let cmp = compareStaticBytes(
                            raw,
                            offsetA: pOff + prevOff,
                            lenA: prevLen,
                            offsetB: pOff + sOff,
                            lenB: sLen
                        )
                        guard cmp < 0 else { return .empty }
                    }
                    prevOff = sOff
                    prevLen = sLen
                }
            }
            charResCount = cCount
            charResOffset = cOff
            wordResCount = wCount
            wordResOffset = wOff
            wordPoolOffset = pOff
            wordPoolSize = pSize
        }

        for i in 0..<6336 {
            let weight = Float(bitPattern: loadU32(raw, at: mlpStart + i * 4))
            guard weight.isFinite, abs(weight) <= 100.0 else {
                return .empty
            }
        }
        // `bwd_alpha` occupies indices [6208..<6240]
        for i in 6208..<6240 {
            let a = Float(bitPattern: loadU32(raw, at: mlpStart + i * 4))
            guard a >= 0.01, a <= 0.99 else {
                return .empty
            }
        }

        var cursor = mlpStart
        func readVec32() -> Vec32 {
            let v0 = loadSIMD8F32(raw, at: cursor)
            let v1 = loadSIMD8F32(raw, at: cursor + 32)
            let v2 = loadSIMD8F32(raw, at: cursor + 64)
            let v3 = loadSIMD8F32(raw, at: cursor + 96)
            cursor += 128
            return Vec32(v0: v0, v1: v1, v2: v2, v3: v3)
        }
        func readMatrix32x32() -> [Vec32] {
            var rows: [Vec32] = []
            rows.reserveCapacity(32)
            for _ in 0..<32 {
                rows.append(readVec32())
            }
            return rows
        }

        let wCtx = readMatrix32x32()
        let wRec = readMatrix32x32()
        let b1Vec = readVec32()
        let wProj = readMatrix32x32()
        let bDir = readMatrix32x32()
        let bSkp = readMatrix32x32()
        let b2Vec = readVec32()
        let wCh = readMatrix32x32()
        let aVec = readVec32()
        let hEosVec = readVec32()
        let wBosVec = readVec32()
        let uBosVec = readVec32()
        let ones = Vec32(
            v0: SIMD8<Float>(repeating: 1.0),
            v1: SIMD8<Float>(repeating: 1.0),
            v2: SIMD8<Float>(repeating: 1.0),
            v3: SIMD8<Float>(repeating: 1.0)
        )

        return ParsedBackwardHead(
            loaded: true,
            version: ver,
            backingData: ver == 2 ? data : nil,
            rawBuffer: ver == 2 ? raw : UnsafeRawBufferPointer(start: nil, count: 0),
            charResCount: charResCount,
            charResOffset: charResOffset,
            wordResCount: wordResCount,
            wordResOffset: wordResOffset,
            wordPoolOffset: wordPoolOffset,
            wordPoolSize: wordPoolSize,
            wCtxRows: transpose32x32(wCtx),
            wRecRows: transpose32x32(wRec),
            b1: b1Vec,
            wProjRows: transpose32x32(wProj),
            bDirectRows: transpose32x32(bDir),
            bSkipRows: transpose32x32(bSkp),
            b2: b2Vec,
            wCharRows: transpose32x32(wCh),
            alpha: aVec,
            oneMinusAlpha: ones - aVec,
            hEos: hEosVec,
            wBos: wBosVec,
            uBos: uBosVec
        )
    }

    private struct ParsedTypoReranker {
        let loaded: Bool
        let backingData: NSData?
        let rawBuffer: UnsafeRawBufferPointer
        let scale1: [Float]
        let b1: [Float]
        let scale2: [SIMD8<Float>]
        let b2: [SIMD8<Float>]
        let w3: [SIMD8<Float>]
        let resLin0: SIMD8<Float>
        let resLin1: SIMD8<Float>
        let b3: Float
        let maxDeltaQ8: Int

        static var empty: ParsedTypoReranker {
            ParsedTypoReranker(
                loaded: false,
                backingData: nil,
                rawBuffer: UnsafeRawBufferPointer(start: nil, count: 0),
                scale1: [],
                b1: [],
                scale2: [],
                b2: [],
                w3: [],
                resLin0: .zero,
                resLin1: .zero,
                b3: 0.0,
                maxDeltaQ8: 0
            )
        }
    }

    private static func parseTypoReranker(_ data: NSData?) -> ParsedTypoReranker {
        guard let data, data.length >= typoRerankerByteSize else {
            return .empty
        }
        let raw = UnsafeRawBufferPointer(start: data.bytes, count: data.length)
        let magic = loadU32(raw, at: 0)
        let ver = loadU32(raw, at: 4)
        let dIn = loadU32(raw, at: 8)
        let h1 = loadU32(raw, at: 12)
        let h2 = loadU32(raw, at: 16)
        let payloadSz = loadU32(raw, at: 28)
        guard magic == magicLNTR, ver == 1, dIn == 64, h1 == 384, h2 == 48,
              Int(payloadSz) == typoRerankerByteSize - 32 else {
            return .empty
        }

        // Float table starts right after W1 (384*64 = 24,576):
        // scale1 (384) + b1 (384) = 768 floats, then W2 (48*384 = 18,432 bytes),
        // then scale2 (48) + b2 (48) + w3 (48) + resLin (16) + tail (4) = 164 floats.
        let scale1Off = 32 + 24_576
        let b1Off = scale1Off + 384 * 4
        let w2Off = b1Off + 384 * 4
        let scale2Off = w2Off + 18_432
        let totalFloatsAfterW2 = 48 + 48 + 48 + 16 + 4 // 164 floats = 656 bytes
        guard scale2Off + totalFloatsAfterW2 * 4 == typoRerankerByteSize else {
            return .empty
        }

        var s1 = [Float]()
        s1.reserveCapacity(384)
        var bias1 = [Float]()
        bias1.reserveCapacity(384)
        for i in 0..<384 {
            let sv = Float(bitPattern: loadU32(raw, at: scale1Off + i * 4))
            let bv = Float(bitPattern: loadU32(raw, at: b1Off + i * 4))
            guard sv.isFinite, bv.isFinite, abs(sv) <= 10.0, abs(bv) <= 50.0 else {
                return .empty
            }
            s1.append(sv)
            bias1.append(bv)
        }

        for i in 0..<totalFloatsAfterW2 {
            let fv = Float(bitPattern: loadU32(raw, at: scale2Off + i * 4))
            guard fv.isFinite, abs(fv) <= 2000.0 else {
                return .empty
            }
        }

        var cursor = scale2Off
        func readVec8Group(_ count: Int) -> [SIMD8<Float>] {
            var out = [SIMD8<Float>]()
            out.reserveCapacity(count)
            for _ in 0..<count {
                out.append(loadSIMD8F32(raw, at: cursor))
                cursor += 32
            }
            return out
        }

        let s2Vecs = readVec8Group(6)   // 48 floats
        let b2Vecs = readVec8Group(6)   // 48 floats
        let w3Vecs = readVec8Group(6)   // 48 floats
        let rl0 = loadSIMD8F32(raw, at: cursor); cursor += 32
        let rl1 = loadSIMD8F32(raw, at: cursor); cursor += 32
        let b3Val = Float(bitPattern: loadU32(raw, at: cursor))
        let maxDQ8 = Float(bitPattern: loadU32(raw, at: cursor + 4))
        guard abs(b3Val) <= 50.0, maxDQ8 >= 10.0, maxDQ8 <= 1200.0 else {
            return .empty
        }

        return ParsedTypoReranker(
            loaded: true,
            backingData: data,
            rawBuffer: raw,
            scale1: s1,
            b1: bias1,
            scale2: s2Vecs,
            b2: b2Vecs,
            w3: w3Vecs,
            resLin0: rl0,
            resLin1: rl1,
            b3: b3Val,
            maxDeltaQ8: Int(maxDQ8.rounded())
        )
    }

    private struct ParsedSemantic64 {
        let loaded: Bool
        let quantMode: UInt32
        let backingData: NSData?
        let rawBuffer: UnsafeRawBufferPointer
        let charCount: Int
        let charMapOffset: Int
        let charEmbOffset: Int
        let wordCount: Int
        let wordTableOffset: Int
        let poolOffset: Int
        let poolSize: Int
        let wSemRows: [Vec32]
        let wTopicRows: [Vec32]
        let wGateH: Vec32
        let wGateTopic: Vec32
        let bGate: Float
        let semScale: Float
        let topicScale: Float
        let clauseDecay: Float
        let sentenceDecay: Float
        let maxBonusQ8: Int

        static var empty: ParsedSemantic64 {
            let zeroRows = Array(repeating: Vec32.zero, count: 32)
            return ParsedSemantic64(
                loaded: false,
                quantMode: 0,
                backingData: nil,
                rawBuffer: UnsafeRawBufferPointer(start: nil, count: 0),
                charCount: 0,
                charMapOffset: 0,
                charEmbOffset: 0,
                wordCount: 0,
                wordTableOffset: 0,
                poolOffset: 0,
                poolSize: 0,
                wSemRows: zeroRows,
                wTopicRows: zeroRows,
                wGateH: .zero,
                wGateTopic: .zero,
                bGate: 0.0,
                semScale: 0.0,
                topicScale: 0.0,
                clauseDecay: 0.82,
                sentenceDecay: 0.68,
                maxBonusQ8: 0
            )
        }
    }

    private static func parseSemantic64(_ data: NSData?) -> ParsedSemantic64 {
        guard let data, data.length >= 48 + 41_984 + 8_480 else {
            return .empty
        }
        let raw = UnsafeRawBufferPointer(start: data.bytes, count: data.length)
        let magic = loadU32(raw, at: 0)
        let ver = loadU32(raw, at: 4)
        let semDim = loadU32(raw, at: 8)
        let qMode = loadU32(raw, at: 12)
        guard magic == magicLNS6, ver == 1, semDim == 32, (qMode == 1 || qMode == 2) else {
            return .empty
        }

        let pairBytes = (qMode == 1) ? 64 : 128
        let wordRecBytes = 8 + pairBytes
        let cCount = Int(loadU32(raw, at: 16))
        let cMapOff = Int(loadU32(raw, at: 20))
        let cEmbOff = Int(loadU32(raw, at: 24))
        let wCount = Int(loadU32(raw, at: 28))
        let wTabOff = Int(loadU32(raw, at: 32))
        let poolOff = Int(loadU32(raw, at: 36))
        let poolSz = Int(loadU32(raw, at: 40))
        let projOff = Int(loadU32(raw, at: 44))
        let totalLen = raw.count

        guard cCount >= 0, cCount <= 20992,
              wCount >= 0, wCount <= Int(UInt16.max),
              poolSz >= 0,
              cMapOff >= 48, cMapOff <= totalLen - 41_984,
              cEmbOff >= cMapOff + 41_984, cEmbOff <= totalLen - (cCount + 1) * pairBytes,
              wTabOff >= cEmbOff + (cCount + 1) * pairBytes, wTabOff <= totalLen - wCount * wordRecBytes,
              poolOff >= wTabOff + wCount * wordRecBytes, poolOff <= totalLen - poolSz,
              projOff >= poolOff + poolSz, projOff <= totalLen - 8_480 else {
            return .empty
        }

        if wCount > 0 {
            guard let base = raw.baseAddress else { return .empty }
            let poolBase = base.advanced(by: poolOff)
            var recPtr = base.advanced(by: wTabOff)
            var prevOff = 0
            var prevLen = 0
            var i = 0
            while i < wCount {
                let sOff = Int(UInt32(littleEndian: recPtr.loadUnaligned(as: UInt32.self)))
                let sLen = Int(UInt16(littleEndian: recPtr.advanced(by: 4).loadUnaligned(as: UInt16.self)))
                guard sLen > 0, sOff <= poolSz, sLen <= poolSz - sOff else { return .empty }
                if i > 0 {
                    let n = prevLen < sLen ? prevLen : sLen
                    let c = memcmp(poolBase.advanced(by: prevOff), poolBase.advanced(by: sOff), n)
                    if c > 0 || (c == 0 && prevLen >= sLen) {
                        return .empty
                    }
                }
                prevOff = sOff
                prevLen = sLen
                recPtr = recPtr.advanced(by: wordRecBytes)
                i &+= 1
            }
        }

        if let base = raw.baseAddress {
            var fPtr = base.advanced(by: projOff)
            var j = 0
            while j < 2120 {
                let fv = Float(bitPattern: UInt32(littleEndian: fPtr.loadUnaligned(as: UInt32.self)))
                guard fv.isFinite, abs(fv) <= 1000.0 else { return .empty }
                fPtr = fPtr.advanced(by: 4)
                j &+= 1
            }
        } else {
            return .empty
        }

        var cursor = projOff
        func readVec32() -> Vec32 {
            let v0 = loadSIMD8F32(raw, at: cursor)
            let v1 = loadSIMD8F32(raw, at: cursor + 32)
            let v2 = loadSIMD8F32(raw, at: cursor + 64)
            let v3 = loadSIMD8F32(raw, at: cursor + 96)
            cursor += 128
            return Vec32(v0: v0, v1: v1, v2: v2, v3: v3)
        }
        func readMatrix32x32() -> [Vec32] {
            var rows: [Vec32] = []
            rows.reserveCapacity(32)
            for _ in 0..<32 { rows.append(readVec32()) }
            return rows
        }

        let wSem = readMatrix32x32()
        let wTopic = readMatrix32x32()
        let gH = readVec32()
        let gT = readVec32()
        let bGate = Float(bitPattern: loadU32(raw, at: cursor))
        let semScale = Float(bitPattern: loadU32(raw, at: cursor + 4))
        let topicScale = Float(bitPattern: loadU32(raw, at: cursor + 8))
        let clauseDecay = Float(bitPattern: loadU32(raw, at: cursor + 12))
        let sentenceDecay = Float(bitPattern: loadU32(raw, at: cursor + 16))
        let maxBonus = Float(bitPattern: loadU32(raw, at: cursor + 20))
        guard abs(bGate) <= 20.0,
              semScale >= 0.0, semScale <= 4.0,
              topicScale >= 0.0, topicScale <= 4.0,
              clauseDecay >= 0.0, clauseDecay <= 0.99,
              sentenceDecay >= 0.0, sentenceDecay <= 0.99,
              maxBonus >= 0.0, maxBonus <= 600.0 else {
            return .empty
        }

        return ParsedSemantic64(
            loaded: true,
            quantMode: qMode,
            backingData: data,
            rawBuffer: raw,
            charCount: cCount,
            charMapOffset: cMapOff,
            charEmbOffset: cEmbOff,
            wordCount: wCount,
            wordTableOffset: wTabOff,
            poolOffset: poolOff,
            poolSize: poolSz,
            wSemRows: transpose32x32(wSem),
            wTopicRows: transpose32x32(wTopic),
            wGateH: gH,
            wGateTopic: gT,
            bGate: bGate,
            semScale: semScale,
            topicScale: topicScale,
            clauseDecay: clauseDecay,
            sentenceDecay: sentenceDecay,
            maxBonusQ8: Int(maxBonus.rounded())
        )
    }

    public convenience init(
        data: Data,
        stringPoolOffset: Int,
        stringPoolSize: Int,
        backwardData: Data? = nil,
        typoRerankerData: Data? = nil,
        semantic64Data: Data? = nil
    ) {
        self.init(
            nsData: data as NSData,
            stringPoolOffset: stringPoolOffset,
            stringPoolSize: stringPoolSize,
            backwardData: backwardData as NSData?,
            typoRerankerData: typoRerankerData as NSData?,
            semantic64Data: semantic64Data as NSData?
        )
    }

    public init(
        nsData: NSData,
        stringPoolOffset: Int,
        stringPoolSize: Int,
        backwardData: NSData? = nil,
        typoRerankerData: NSData? = nil,
        semantic64Data: NSData? = nil
    ) {
        let parsedBwd = Self.parseBackwardHead(backwardData)
        self.hasBackwardHead = parsedBwd.loaded
        self.bwdVersion = parsedBwd.version
        self.bwdBackingData = parsedBwd.backingData
        self.bwdRawBuffer = parsedBwd.rawBuffer
        self.bwdCharResCount = parsedBwd.charResCount
        self.bwdCharResOffset = parsedBwd.charResOffset
        self.bwdWordResCount = parsedBwd.wordResCount
        self.bwdWordResOffset = parsedBwd.wordResOffset
        self.bwdWordPoolOffset = parsedBwd.wordPoolOffset
        self.bwdWordPoolSize = parsedBwd.wordPoolSize
        self.bwdWCtxRows = parsedBwd.wCtxRows
        self.bwdWRecRows = parsedBwd.wRecRows
        self.bwdB1 = parsedBwd.b1
        self.bwdWProjRows = parsedBwd.wProjRows
        self.bwdBDirectRows = parsedBwd.bDirectRows
        self.bwdBSkipRows = parsedBwd.bSkipRows
        self.bwdB2 = parsedBwd.b2
        self.bwdWCharRows = parsedBwd.wCharRows
        self.bwdAlpha = parsedBwd.alpha
        self.bwdOneMinusAlpha = parsedBwd.oneMinusAlpha
        self.bwdHEos = parsedBwd.hEos
        self.bwdWBos = parsedBwd.wBos
        self.bwdUBos = parsedBwd.uBos

        let parsedLNTR = Self.parseTypoReranker(typoRerankerData)
        self.hasTypoReranker = parsedLNTR.loaded
        self.lntrBackingData = parsedLNTR.backingData
        self.lntrRawBuffer = parsedLNTR.rawBuffer
        self.lntrScale1 = parsedLNTR.scale1
        self.lntrB1 = parsedLNTR.b1
        self.lntrScale2 = parsedLNTR.scale2
        self.lntrB2 = parsedLNTR.b2
        self.lntrW3 = parsedLNTR.w3
        self.lntrResLin0 = parsedLNTR.resLin0
        self.lntrResLin1 = parsedLNTR.resLin1
        self.lntrB3 = parsedLNTR.b3
        self.lntrMaxDeltaQ8 = parsedLNTR.maxDeltaQ8

        let parsedSem = Self.parseSemantic64(semantic64Data)
        self.hasSemantic64 = parsedSem.loaded
        self.sem64QuantMode = parsedSem.quantMode
        self.sem64BackingData = parsedSem.backingData
        self.sem64RawBuffer = parsedSem.rawBuffer
        self.sem64CharCount = parsedSem.charCount
        self.sem64CharMapOffset = parsedSem.charMapOffset
        self.sem64CharEmbOffset = parsedSem.charEmbOffset
        self.sem64WordCount = parsedSem.wordCount
        self.sem64WordTableOffset = parsedSem.wordTableOffset
        self.sem64PoolOffset = parsedSem.poolOffset
        self.sem64PoolSize = parsedSem.poolSize
        self.sem64WSemRows = parsedSem.wSemRows
        self.sem64WTopicRows = parsedSem.wTopicRows
        self.sem64WGateH = parsedSem.wGateH
        self.sem64WGateTopic = parsedSem.wGateTopic
        self.sem64BGate = parsedSem.bGate
        self.sem64SemScale = parsedSem.semScale
        self.sem64TopicScale = parsedSem.topicScale
        self.sem64ClauseDecay = parsedSem.clauseDecay
        self.sem64SentenceDecay = parsedSem.sentenceDecay
        self.sem64MaxBonusQ8 = parsedSem.maxBonusQ8

        self.backingData = nsData
        let raw = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
        self.rawBuffer = raw
        self.stringPoolOffset = stringPoolOffset
        let validPool = stringPoolOffset >= 0 && stringPoolOffset <= raw.count
            && stringPoolSize >= 0 && stringPoolSize <= raw.count - stringPoolOffset
        self.stringPoolSize = validPool ? stringPoolSize : 0

        // Check 16-byte footer at the end of `lokey_lexicon.bin` for `LNLM v2` (32-dim) or `LNLM v1` (16-dim)
        var foundOffset = 0
        var foundSize = 0
        var foundVer: UInt32 = 0
        if validPool, raw.count >= 104 {
            let footerOff = raw.count - 16
            let magic = Self.loadU32(raw, at: footerOff)
            let ver = Self.loadU32(raw, at: footerOff + 4)
            let off = Int(Self.loadU32(raw, at: footerOff + 8))
            let sz = Int(Self.loadU32(raw, at: footerOff + 12))
            if magic == Self.magicLNLM && off >= 72 && sz >= 32 && off + sz <= footerOff {
                let hdrMagic = Self.loadU32(raw, at: off)
                let dim = Self.loadU32(raw, at: off + 4)
                if hdrMagic == Self.magicLNLM {
                    if ver == 2 && dim == 32 && sz >= 25376 {
                        foundOffset = off
                        foundSize = sz
                        foundVer = 2
                    } else if ver == 1 && dim == 16 && sz >= 6560 {
                        foundOffset = off
                        foundSize = sz
                        foundVer = 1
                    }
                }
            }
        }

        if foundOffset > 0 && foundSize > 0 && foundVer == 2 {
            let cCount = Int(Self.loadU32(raw, at: foundOffset + 8))
            let cMapOff = Int(Self.loadU32(raw, at: foundOffset + 12))
            let cEmbOff = Int(Self.loadU32(raw, at: foundOffset + 16))
            let wCount = Int(Self.loadU32(raw, at: foundOffset + 20))
            let wTabOff = Int(Self.loadU32(raw, at: foundOffset + 24))
            let mlpOff = Int(Self.loadU32(raw, at: foundOffset + 28))
            let endBound = foundOffset + foundSize

            if cCount <= Int(UInt16.max), cMapOff >= foundOffset + 32,
               cEmbOff >= foundOffset + 32, wTabOff >= foundOffset + 32, mlpOff >= foundOffset + 32,
               cMapOff + 20992 * 2 <= endBound,
               cEmbOff + (cCount + 1) * 64 <= endBound,
               wTabOff + wCount * 72 <= endBound,
               mlpOff + 25344 <= endBound {
                var cursor = mlpOff
                func readVec32() -> Vec32 {
                    let v0 = Self.loadSIMD8F32(raw, at: cursor)
                    let v1 = Self.loadSIMD8F32(raw, at: cursor + 32)
                    let v2 = Self.loadSIMD8F32(raw, at: cursor + 64)
                    let v3 = Self.loadSIMD8F32(raw, at: cursor + 96)
                    cursor += 128
                    return Vec32(v0: v0, v1: v1, v2: v2, v3: v3)
                }
                func readMatrix32x32() -> [Vec32] {
                    var rows: [Vec32] = []
                    rows.reserveCapacity(32)
                    for _ in 0..<32 {
                        rows.append(readVec32())
                    }
                    return rows
                }

                let wCtx = readMatrix32x32()
                let wRec = readMatrix32x32()
                let b1Vec = readVec32()
                let wProj = readMatrix32x32()
                let bDir = readMatrix32x32()
                let bSkp = readMatrix32x32()
                let b2Vec = readVec32()
                let wCh = readMatrix32x32()
                let aVec = readVec32()
                let bosVec = readVec32()
                let weVec = readVec32()
                let ueVec = readVec32()
                let ones = Vec32(
                    v0: SIMD8<Float>(repeating: 1.0),
                    v1: SIMD8<Float>(repeating: 1.0),
                    v2: SIMD8<Float>(repeating: 1.0),
                    v3: SIMD8<Float>(repeating: 1.0)
                )

                self.hasBinarySection = true
                self.modelVersion = 2
                self.charVocabCount = cCount
                self.charMapOffset = cMapOff
                self.charEmbOffset = cEmbOff
                self.wordVocabCount = wCount
                self.wordTableOffset = wTabOff
                self.wCtxRows = Self.transpose32x32(wCtx)
                self.wRecRows = Self.transpose32x32(wRec)
                self.b1 = b1Vec
                self.wProjRows = Self.transpose32x32(wProj)
                self.bDirectRows = Self.transpose32x32(bDir)
                self.bSkipRows = Self.transpose32x32(bSkp)
                self.b2 = b2Vec
                self.wCharRows = Self.transpose32x32(wCh)
                self.alpha = aVec
                self.oneMinusAlpha = ones - aVec
                self.hBos = bosVec
                self.wEos = weVec
                self.uEos = ueVec
                return
            }
        } else if foundOffset > 0 && foundSize > 0 && foundVer == 1 {
            let cCount = Int(Self.loadU32(raw, at: foundOffset + 8))
            let cMapOff = Int(Self.loadU32(raw, at: foundOffset + 12))
            let cEmbOff = Int(Self.loadU32(raw, at: foundOffset + 16))
            let wCount = Int(Self.loadU32(raw, at: foundOffset + 20))
            let wTabOff = Int(Self.loadU32(raw, at: foundOffset + 24))
            let mlpOff = Int(Self.loadU32(raw, at: foundOffset + 28))
            let endBound = foundOffset + foundSize

            if cCount <= Int(UInt16.max), cMapOff >= foundOffset + 32,
               cEmbOff >= foundOffset + 32, wTabOff >= foundOffset + 32, mlpOff >= foundOffset + 32,
               cMapOff + 20992 * 2 <= endBound,
               cEmbOff + (cCount + 1) * 32 <= endBound,
               wTabOff + wCount * 40 <= endBound,
               mlpOff + 6528 <= endBound {
                var cursor = mlpOff
                func readVec16As32() -> Vec32 {
                    let v0 = Self.loadSIMD8F32(raw, at: cursor)
                    let v1 = Self.loadSIMD8F32(raw, at: cursor + 32)
                    cursor += 64
                    return Vec32(v0: v0, v1: v1, v2: .zero, v3: .zero)
                }
                func readMatrix16As32() -> [Vec32] {
                    var rows: [Vec32] = []
                    rows.reserveCapacity(32)
                    for _ in 0..<16 {
                        rows.append(readVec16As32())
                    }
                    for _ in 16..<32 {
                        rows.append(.zero)
                    }
                    return rows
                }

                let wCtx = readMatrix16As32()
                let wRec = readMatrix16As32()
                let b1Vec = readVec16As32()
                let wProj = readMatrix16As32()
                let bDir = readMatrix16As32()
                let bSkp = readMatrix16As32()
                let b2Vec = readVec16As32()
                let wCh = readMatrix16As32()
                let aVec = readVec16As32()
                let bosVec = readVec16As32()
                let weVec = readVec16As32()
                let ueVec = readVec16As32()
                let ones = Vec32(
                    v0: SIMD8<Float>(repeating: 1.0),
                    v1: SIMD8<Float>(repeating: 1.0),
                    v2: SIMD8<Float>(repeating: 1.0),
                    v3: SIMD8<Float>(repeating: 1.0)
                )

                self.hasBinarySection = true
                self.modelVersion = 1
                self.charVocabCount = cCount
                self.charMapOffset = cMapOff
                self.charEmbOffset = cEmbOff
                self.wordVocabCount = wCount
                self.wordTableOffset = wTabOff
                self.wCtxRows = Self.transpose32x32(wCtx)
                self.wRecRows = Self.transpose32x32(wRec)
                self.b1 = b1Vec
                self.wProjRows = Self.transpose32x32(wProj)
                self.bDirectRows = Self.transpose32x32(bDir)
                self.bSkipRows = Self.transpose32x32(bSkp)
                self.b2 = b2Vec
                self.wCharRows = Self.transpose32x32(wCh)
                self.alpha = aVec
                self.oneMinusAlpha = ones - aVec
                self.hBos = bosVec
                self.wEos = weVec
                self.uEos = ueVec
                return
            }
        }

        let zeroRows = Array(repeating: Vec32.zero, count: 32)
        let half = Vec32(
            v0: SIMD8<Float>(repeating: 0.5),
            v1: SIMD8<Float>(repeating: 0.5),
            v2: SIMD8<Float>(repeating: 0.5),
            v3: SIMD8<Float>(repeating: 0.5)
        )
        self.hasBinarySection = false
        self.modelVersion = 0
        self.charVocabCount = 0
        self.charMapOffset = 0
        self.charEmbOffset = 0
        self.wordVocabCount = 0
        self.wordTableOffset = 0
        self.wCtxRows = zeroRows
        self.wRecRows = zeroRows
        self.b1 = .zero
        self.wProjRows = zeroRows
        self.bDirectRows = zeroRows
        self.bSkipRows = zeroRows
        self.b2 = .zero
        self.wCharRows = zeroRows
        self.alpha = half
        self.oneMinusAlpha = half
        self.hBos = .zero
        self.wEos = .zero
        self.uEos = .zero
    }

    public var isLoaded: Bool { hasBinarySection }
    public var isBackwardLoaded: Bool { hasBinarySection && hasBackwardHead }
    public var backwardVersion: UInt32 { hasBinarySection && hasBackwardHead ? bwdVersion : 0 }
    public var isTypoRerankerLoaded: Bool { hasBinarySection && hasTypoReranker }
    public var isSemantic64Loaded: Bool { hasBinarySection && hasSemantic64 }
    public var semantic64QuantMode: UInt32 { hasBinarySection && hasSemantic64 ? sem64QuantMode : 0 }
    public var version: UInt32 { modelVersion }

    /// Releases transient decoded word-embedding and context-projection caches under iOS keyboard extension memory pressure.
    public func purgeTransientCaches(releaseCapacity: Bool = false) {
        os_unfair_lock_lock(&cacheLock)
        wordRecordCache.removeAll(keepingCapacity: !releaseCapacity)
        wordRecordRing.removeAll(keepingCapacity: !releaseCapacity)
        wordRecordRingCursor = 0
        if releaseCapacity {
            contextProjSlots.removeAll(keepingCapacity: false)
        } else if !contextProjSlots.isEmpty {
            for idx in contextProjSlots.indices {
                contextProjSlots[idx].cacheId = 0
            }
        }
        os_unfair_lock_unlock(&cacheLock)
    }

    @inline(__always)
    private func contextProjection(for record: WordNeuralRecord) -> ContextProjectionSlot {
        let cid = record.cacheId
        if cid != 0 {
            let slotIdx = Int(cid & Self.contextProjSlotMask)
            os_unfair_lock_lock(&cacheLock)
            if contextProjSlots.count == Self.contextProjSlotCount {
                let slot = contextProjSlots[slotIdx]
                if slot.cacheId == cid {
                    os_unfair_lock_unlock(&cacheLock)
                    return slot
                }
            }
            os_unfair_lock_unlock(&cacheLock)
        }

        let lastCharCtx = embedding(forScalarValue: Int(record.lastCharScalar)).ctx
        let built = ContextProjectionSlot(
            cacheId: cid,
            wx: Self.matVec32(wCtxRows, x: record.ctx),
            bd: Self.matVec32(bDirectRows, x: record.ctx),
            cp: Self.matVec32(wCharRows, x: lastCharCtx),
            semPred: hasSemantic64 ? Self.matVec32(sem64WSemRows, x: record.semCtx) : .zero
        )

        if cid != 0 {
            let slotIdx = Int(cid & Self.contextProjSlotMask)
            os_unfair_lock_lock(&cacheLock)
            if contextProjSlots.count != Self.contextProjSlotCount {
                contextProjSlots = Array(repeating: .empty, count: Self.contextProjSlotCount)
            }
            contextProjSlots[slotIdx] = built
            os_unfair_lock_unlock(&cacheLock)
        }
        return built
    }

    // MARK: - Recurrent Neural Forward Pass (`SIMD8<Float> x 4`)

    /// Project the last few overlapping words using the shipping LNLM context vectors.
    /// Precisely the same bounded features are used by the build-time pair trainer.
    func commitContextFeatures(_ context: String) -> Vec32 {
        let chars = Array(ViterbiDecoder.extractTrailingChineseSuffix(from: context, maxChars: 12))
        var feature = Vec32.zero
        var mass: Float = 0
        for end in chars.indices {
            let age = chars.count - 1 - end
            for size in 1...min(3, end + 1) {
                let token = String(chars[(end + 1 - size)...end])
                let vector: Vec32
                if size == 1 {
                    vector = embedding(forChar: chars[end]).ctx
                } else if let record = lookupWordTableEmbedding(token) {
                    vector = record.ctx
                } else {
                    continue
                }
                let weight = Float(size * size) / Float(3 + age)
                feature = feature + weight * vector
                mass += weight
            }
        }
        return mass > 0 ? (1 / mass) * feature : .zero
    }

    @inline(__always)
    public func initialHiddenState(precedingContext: String?) -> Vec32 {
        guard hasBinarySection, let ctx = precedingContext, !ctx.isEmpty else {
            return hBos
        }
        let suffix = ViterbiDecoder.extractTrailingChineseSuffix(from: ctx, maxChars: 8)
        guard !suffix.isEmpty else {
            return hBos
        }
        let chars = Array(suffix)
        var hidden = hBos
        var prevRec: WordNeuralRecord?
        var pos = 0
        while pos < chars.count {
            var token: String?
            var prefetchedEmb: EmbeddingPair?
            let maxLen = min(3, chars.count - pos)
            if maxLen >= 2 {
                for len in stride(from: maxLen, through: 2, by: -1) {
                    let piece = String(chars[pos..<(pos + len)])
                    if let hit = lookupWordTableEmbedding(piece) {
                        token = piece
                        prefetchedEmb = hit
                        pos += len
                        break
                    }
                }
            }
            let resolvedToken: String
            if let matched = token {
                resolvedToken = matched
            } else {
                resolvedToken = String(chars[pos])
                pos += 1
            }
            let rec = wordRecord(for: resolvedToken, prefetchedEmbedding: prefetchedEmb)
            if let prev = prevRec {
                let pred = prepareStepPredictor(lastRecord: prev, hidden: hidden)
                hidden = advanceHiddenState(predictor: pred, record: rec)
            } else {
                hidden = advanceHiddenStateFromBOS(record: rec, baseHidden: hidden)
            }
            prevRec = rec
        }
        return hidden
    }

    @inline(__always)
    public func prepareStepPredictor(
        lastWord: String,
        hidden: Vec32,
        topicMemory: Vec32 = .zero
    ) -> StepPredictor {
        guard hasBinarySection, !lastWord.isEmpty else {
            return StepPredictor(
                wordPred: .zero,
                charPred: .zero,
                z: .zero,
                prevHidden: hidden,
                lastCtx: .zero,
                hasContext: false
            )
        }
        return prepareStepPredictor(lastRecord: wordRecord(for: lastWord), hidden: hidden, topicMemory: topicMemory)
    }

    @inline(__always)
    public func prepareStepPredictor(
        lastRecord: WordNeuralRecord,
        hidden: Vec32,
        topicMemory: Vec32 = .zero
    ) -> StepPredictor {
        guard hasBinarySection, lastRecord.charCount > 0 else {
            return StepPredictor(
                wordPred: .zero,
                charPred: .zero,
                z: .zero,
                prevHidden: hidden,
                lastCtx: .zero,
                hasContext: false
            )
        }

        let proj = contextProjection(for: lastRecord)

        // Layer 1: z = SiLU(W_ctx * v_ctx(w_{m-1}) + W_rec * h_{m-1} + b_1)
        let wr = Self.matVec32(wRecRows, x: hidden)
        let z = Self.silu32(proj.wx + wr + b1)

        // Layer 2: p_word = W_proj * z + B_direct * v_ctx(w_{m-1}) + B_skip * h_{m-1} + b_2
        let wp = Self.matVec32(wProjRows, x: z)
        let bs = Self.matVec32(bSkipRows, x: hidden)
        let wordPred = wp + proj.bd + bs + b2

        var semCombined = Vec32.zero
        if hasSemantic64 {
            semCombined = sem64SemScale * proj.semPred
            if topicMemory != .zero && sem64TopicScale > 0 {
                let gArg = sem64WGateH.dot(hidden) + sem64WGateTopic.dot(topicMemory) + sem64BGate
                let gate = Self.approxSigmoidScalar(gArg)
                let tProj = Self.matVec32(sem64WTopicRows, x: topicMemory)
                semCombined = semCombined + (sem64TopicScale * gate) * tProj
            }
        }

        return StepPredictor(
            wordPred: wordPred,
            charPred: proj.cp,
            z: z,
            prevHidden: hidden,
            lastCtx: lastRecord.ctx,
            hasContext: true,
            semPred: semCombined
        )
    }

    /// Lock-free, zero-allocation inner-loop candidate evaluation (`< 15 ns` in Apple Silicon SIMD registers).
    @inline(__always)
    public func scorePreloadedCandidate(
        predictor: StepPredictor,
        record: WordNeuralRecord,
        singleCharRun: Int = 0,
        isEndOfSentence: Bool = false
    ) -> Int {
        guard hasBinarySection, predictor.hasContext, record.charCount > 0 else {
            return 0
        }

        let wordDot = predictor.wordPred.dot(record.tgt)
        let charDot = predictor.charPred.dot(record.firstCharTgt)
        var raw = wordDot + 0.30 * charDot
        if hasSemantic64 && predictor.semPred != .zero {
            let semDot = predictor.semPred.dot(record.semTgt)
            if semDot.isFinite {
                let maxSemRaw = Float(sem64MaxBonusQ8) / 170.0
                raw += min(maxSemRaw, max(-maxSemRaw, semDot))
            }
        }

        if isEndOfSentence {
            let nextH = alpha * predictor.prevHidden + oneMinusAlpha * Self.tanh32(record.ctx + 0.35 * predictor.z)
            let eosDot = wEos.dot(nextH) + record.eosCtxScore
            raw += 0.35 * eosDot
        }

        guard raw.isFinite else { return 0 }
        let scaled = (raw * 170.0).rounded()
        guard scaled.isFinite else { return raw > 0 ? Self.maxBonusQ8 : Self.minBonusQ8 }
        let clamped = min(Float(Self.maxBonusQ8), max(Float(Self.minBonusQ8), scaled))
        var bonusQ8 = Int(clamped)
        if bonusQ8 > Self.maxBonusQ8 { bonusQ8 = Self.maxBonusQ8 }
        if bonusQ8 < Self.minBonusQ8 { bonusQ8 = Self.minBonusQ8 }

        if singleCharRun >= 1 && record.charCount == 1 && raw < 0.25 {
            bonusQ8 -= min(320, singleCharRun * 140)
        }
        return bonusQ8
    }

    @inline(__always)
    public func scoreCandidate(
        predictor: StepPredictor,
        nextWord: String,
        singleCharRun: Int = 0,
        isEndOfSentence: Bool = false
    ) -> Int {
        guard hasBinarySection, predictor.hasContext, !nextWord.isEmpty else {
            return 0
        }
        return scorePreloadedCandidate(
            predictor: predictor,
            record: wordRecord(for: nextWord),
            singleCharRun: singleCharRun,
            isEndOfSentence: isEndOfSentence
        )
    }

    @inline(__always)
    public func advanceHiddenState(predictor: StepPredictor, record: WordNeuralRecord) -> Vec32 {
        guard hasBinarySection, record.charCount > 0 else {
            return predictor.prevHidden
        }
        let act = Self.tanh32(record.ctx + 0.35 * predictor.z)
        return alpha * predictor.prevHidden + oneMinusAlpha * act
    }

    @inline(__always)
    public func advanceHiddenState(predictor: StepPredictor, nextWord: String) -> Vec32 {
        guard hasBinarySection, !nextWord.isEmpty else {
            return predictor.prevHidden
        }
        return advanceHiddenState(predictor: predictor, record: wordRecord(for: nextWord))
    }

    @inline(__always)
    public func advanceHiddenStateFromBOS(record: WordNeuralRecord, baseHidden: Vec32) -> Vec32 {
        guard hasBinarySection, record.charCount > 0 else {
            return baseHidden
        }
        return alpha * baseHidden + oneMinusAlpha * record.tanhCtx
    }

    /// Evaluates cross-sentence topic memory gate bonus (`Q8`) for a standalone / sentence-start word.
    @inline(__always)
    public func scoreTopicGateBonusQ8(hidden: Vec32, topicMemory: Vec32, record: WordNeuralRecord) -> Int {
        guard hasBinarySection, hasSemantic64, sem64MaxBonusQ8 > 0,
              topicMemory != .zero, record.charCount > 0 else {
            return 0
        }
        let gArg = sem64WGateH.dot(hidden) + sem64WGateTopic.dot(topicMemory) + sem64BGate
        let gate = Self.approxSigmoidScalar(gArg)
        let tProj = Self.matVec32(sem64WTopicRows, x: topicMemory)
        let raw = sem64TopicScale * gate * tProj.dot(record.semTgt)
        guard raw.isFinite else { return 0 }
        let scaled = (raw * 170.0).rounded()
        guard scaled.isFinite else { return raw > 0 ? sem64MaxBonusQ8 : -sem64MaxBonusQ8 }
        let cap = Float(sem64MaxBonusQ8)
        return Int(min(cap, max(-cap, scaled)))
    }

    /// Encodes a committed phrase/sentence into a normalized 32-dim semantic topic summary vector.
    public func encodeTopicSummary(words: [String]) -> Vec32 {
        guard hasBinarySection, !words.isEmpty else { return .zero }
        var acc = Vec32.zero
        var totalWeight: Float = 0.0
        for w in words where !w.isEmpty {
            let rec = wordRecord(for: w)
            guard rec.charCount > 0 else { continue }
            let vec = hasSemantic64 ? rec.semCtx : rec.ctx
            let wt: Float = (rec.charCount >= 2) ? 1.0 : 0.25
            acc = acc + wt * vec
            totalWeight += wt
        }
        guard totalWeight > 0 else { return .zero }
        let meanVec = (1.0 / totalWeight) * acc
        let normSq = meanVec.dot(meanVec)
        guard normSq.isFinite, normSq > 1e-8 else { return .zero }
        let invNorm = min(Float(1.5), 1.0 / sqrt(max(Float(0.25), normSq)))
        return invNorm * meanVec
    }

    /// Exponentially decays cross-sentence topic memory (`γ * current + (1 - γ) * summary` when `words` is non-empty,
    /// or pure boundary decay `γ * current` across punctuation breaks).
    public func decayTopicMemory(_ current: Vec32, committedWords: [String], isSentenceBreak: Bool) -> Vec32 {
        let gamma: Float = isSentenceBreak
            ? (hasSemantic64 ? sem64SentenceDecay : 0.68)
            : (hasSemantic64 ? sem64ClauseDecay : 0.82)
        if committedWords.isEmpty {
            let next = gamma * current
            return next.dot(next) < 1e-6 ? .zero : next
        }
        let summary = encodeTopicSummary(words: committedWords)
        guard summary != .zero else {
            let next = gamma * current
            return next.dot(next) < 1e-6 ? .zero : next
        }
        return gamma * current + (1.0 - gamma) * summary
    }

    /// Evaluates total neural sentence coherence across a segmented word sequence `words`.
    public func scoreWholeSentence(
        words: [String],
        precedingContext: String? = nil,
        topicMemory: Vec32 = .zero
    ) -> Int {
        guard hasBinarySection, !words.isEmpty else { return 0 }
        var hidden = initialHiddenState(precedingContext: precedingContext)
        let prevWord = ViterbiDecoder.extractTrailingChineseSuffix(from: precedingContext ?? "", maxChars: 3)
        var prevRec: WordNeuralRecord = prevWord.isEmpty ? .empty : wordRecord(for: prevWord)
        var totalQ8 = 0
        var oneCharRun = prevRec.charCount == 1 ? 1 : 0

        for (idx, w) in words.enumerated() {
            let isLast = (idx == words.count - 1)
            let wRec = wordRecord(for: w)
            if prevRec.charCount > 0 {
                let pred = prepareStepPredictor(lastRecord: prevRec, hidden: hidden, topicMemory: topicMemory)
                totalQ8 += scorePreloadedCandidate(
                    predictor: pred,
                    record: wRec,
                    singleCharRun: oneCharRun,
                    isEndOfSentence: isLast
                )
                hidden = advanceHiddenState(predictor: pred, record: wRec)
            } else {
                if topicMemory != .zero && hasSemantic64 {
                    totalQ8 += scoreTopicGateBonusQ8(hidden: hidden, topicMemory: topicMemory, record: wRec)
                }
                hidden = advanceHiddenStateFromBOS(record: wRec, baseHidden: hidden)
            }
            if wRec.charCount == 1 {
                oneCharRun += 1
            } else {
                oneCharRun = 0
            }
            prevRec = wRec
        }
        return totalQ8
    }

    /// Evaluates right-to-left (`LNBR` v1 / v2) coherence across a segmented word sequence `words`.
    /// `LNBR v1` reuses frozen `LNLM-v2` embeddings; `LNBR v2` adds dedicated Int8 backward target residuals.
    public func scoreBackwardSentence(words: [String]) -> Int {
        guard hasBinarySection, hasBackwardHead, words.count >= 2 else { return 0 }
        var rightWord = words[words.count - 1]
        var rightRec = wordRecord(for: rightWord)
        guard rightRec.charCount > 0 else { return 0 }
        var hidden = bwdAlpha * bwdHEos + bwdOneMinusAlpha * rightRec.tanhCtx
        let hasV2Residuals = (bwdVersion >= 2) && (bwdWordResCount > 0 || bwdCharResCount > 0)
        let minEmb = SIMD8<Float>(repeating: -127.0 / 32.0)
        let maxEmb = SIMD8<Float>(repeating: 127.0 / 32.0)

        var totalQ8 = 0
        for idx in stride(from: words.count - 2, through: 0, by: -1) {
            let leftWord = words[idx]
            let leftRec = wordRecord(for: leftWord)
            guard leftRec.charCount > 0 else { return 0 }

            let wx = Self.matVec32(bwdWCtxRows, x: rightRec.ctx)
            let wr = Self.matVec32(bwdWRecRows, x: hidden)
            let z = Self.silu32(wx + wr + bwdB1)

            let wp = Self.matVec32(bwdWProjRows, x: z)
            let bd = Self.matVec32(bwdBDirectRows, x: rightRec.ctx)
            let bs = Self.matVec32(bwdBSkipRows, x: hidden)
            let wordPred = wp + bd + bs + bwdB2

            let rightFirstCtx = rightWord.first.map { embedding(forChar: $0).ctx } ?? .zero
            let baseLeftLastTgt = leftWord.last.map { embedding(forChar: $0).tgt } ?? .zero
            let charPred = Self.matVec32(bwdWCharRows, x: rightFirstCtx)

            let effWordTgt: Vec32
            let effLastCharTgt: Vec32
            if hasV2Residuals {
                let wDelta = lookupBackwardWordDelta(leftWord)
                effWordTgt = (wDelta == .zero) ? leftRec.tgt : Self.clampVec32(leftRec.tgt + wDelta, lower: minEmb, upper: maxEmb)
                let cDelta = leftWord.last.map { lookupBackwardCharDelta($0) } ?? .zero
                effLastCharTgt = (cDelta == .zero) ? baseLeftLastTgt : Self.clampVec32(baseLeftLastTgt + cDelta, lower: minEmb, upper: maxEmb)
            } else {
                effWordTgt = leftRec.tgt
                effLastCharTgt = baseLeftLastTgt
            }

            var raw = wordPred.dot(effWordTgt) + 0.30 * charPred.dot(effLastCharTgt)
            let nextHidden = bwdAlpha * hidden + bwdOneMinusAlpha * Self.tanh32(leftRec.ctx + 0.35 * z)
            if idx == 0 {
                raw += 0.25 * (bwdWBos.dot(nextHidden) + bwdUBos.dot(leftRec.ctx))
            }

            if raw.isFinite {
                let scaled = (raw * 170.0).rounded()
                if scaled.isFinite {
                    let clamped = min(Float(Self.maxBonusQ8), max(Float(Self.minBonusQ8), scaled))
                    var bonusQ8 = Int(clamped)
                    if bonusQ8 > Self.maxBonusQ8 { bonusQ8 = Self.maxBonusQ8 }
                    if bonusQ8 < Self.minBonusQ8 { bonusQ8 = Self.minBonusQ8 }
                    totalQ8 += bonusQ8
                } else {
                    totalQ8 += (raw > 0 ? Self.maxBonusQ8 : Self.minBonusQ8)
                }
            }

            hidden = nextHidden
            rightWord = leftWord
            rightRec = leftRec
        }
        return totalQ8
    }

    // MARK: - On-Device Blind-Typing Typo Reranker (`LNTR` v1, 64 -> 384 -> 48 -> 1 Int8 SiLU MLP)

    /// Builds the canonical 64-dim feature vector shared identically between Swift (`NoisyChannelRefiner`) and offline model training.
    public func extractTypoFeatures(
        typedCount: Int,
        intendedCount: Int,
        syllableCount: Int,
        alignCostQ8: Int,
        substCount: Int,
        omitCount: Int,
        transposeCount: Int,
        deleteCount: Int,
        maxPrimaryDriftQ8: Int,
        matchedTouchGainQ8: Int,
        viterbiScoreQ8: Int,
        cleanLatticeQ8: Int,
        fwdNeuralQ8: Int,
        bwdNeuralQ8: Int,
        spellingLL: Int?,
        spellingBoundary: Int,
        words: [String]
    ) -> [Float] {
        @inline(__always)
        func clampF(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            guard v.isFinite else { return 0.0 }
            return min(hi, max(lo, v))
        }

        let sF = Float(max(1, syllableCount))
        let wF = Float(max(1, words.count))
        var charTotal = 0
        var oneCharWords = 0
        var meanCtx = Vec32.zero
        for w in words where !w.isEmpty {
            charTotal += w.count
            if w.count == 1 { oneCharWords += 1 }
            meanCtx = meanCtx + wordRecord(for: w).ctx
        }
        if !words.isEmpty {
            meanCtx = (1.0 / wF) * meanCtx
        }
        let cF = Float(max(1, charTotal))

        var out = [Float](repeating: 0.0, count: Self.typoFeatureDim)
        out[0] = clampF(Float(typedCount) / 24.0, -4.0, 4.0)
        out[1] = clampF(Float(intendedCount - typedCount) / 4.0, -4.0, 4.0)
        out[2] = clampF(Float(alignCostQ8) / 800.0, -4.0, 4.0)
        out[3] = clampF(Float(substCount) / 3.0, -4.0, 4.0)
        out[4] = clampF(Float(omitCount) / 3.0, -4.0, 4.0)
        out[5] = clampF(Float(transposeCount) / 2.0, -4.0, 4.0)
        out[6] = clampF(Float(deleteCount) / 2.0, -4.0, 4.0)
        out[7] = clampF(Float(maxPrimaryDriftQ8) / 300.0, -4.0, 4.0)
        out[8] = clampF(Float(matchedTouchGainQ8) / 300.0, -4.0, 4.0)
        out[9] = clampF((Float(viterbiScoreQ8) / sF) / 1200.0, -6.0, 6.0)
        out[10] = clampF((Float(cleanLatticeQ8) / sF) / 1200.0, -6.0, 6.0)
        out[11] = clampF((Float(fwdNeuralQ8) / wF) / 400.0, -4.0, 4.0)
        out[12] = clampF((Float(bwdNeuralQ8) / wF) / 400.0, -4.0, 4.0)
        out[13] = spellingLL.map { clampF((Float($0) / cF) / 900.0, -6.0, 6.0) } ?? 0.0
        out[14] = clampF(Float(spellingBoundary) / 400.0, -4.0, 4.0)
        out[15] = clampF(Float(oneCharWords) / wF, 0.0, 1.0)

        for k in 0..<8 {
            out[16 + k] = meanCtx.v0[k]
            out[24 + k] = meanCtx.v1[k]
            out[32 + k] = meanCtx.v2[k]
            out[40 + k] = meanCtx.v3[k]
        }
        if let firstW = words.first, !firstW.isEmpty {
            let fTgt = wordRecord(for: firstW).tgt.v0
            for k in 0..<8 { out[48 + k] = fTgt[k] }
        }
        if let lastW = words.last, !lastW.isEmpty {
            let lCtx = wordRecord(for: lastW).ctx.v0
            for k in 0..<8 { out[56 + k] = lCtx[k] }
        }
        return out
    }

    /// Evaluates the 46.7 KB Int8 2-layer SiLU MLP (`LNTR` v1) in Apple Silicon SIMD registers (`~0.9 µs`).
    public func scoreTypoCandidateQ8(features: [Float]) -> Int {
        let w2Offset = 32 + 24_576 + 768 * 4
        guard hasBinarySection, hasTypoReranker, features.count == Self.typoFeatureDim,
              lntrRawBuffer.count >= w2Offset + 48 * 384,
              let basePtr = lntrRawBuffer.baseAddress else {
            return 0
        }

        return withUnsafeTemporaryAllocation(of: SIMD8<Float>.self, capacity: 56) { scratch in
            let lo8 = SIMD8<Float>(repeating: -8.0)
            let hi8 = SIMD8<Float>(repeating: 8.0)
            for g in 0..<8 {
                let off = g * 8
                let raw8 = SIMD8<Float>(
                    features[off].isFinite ? features[off] : 0,
                    features[off + 1].isFinite ? features[off + 1] : 0,
                    features[off + 2].isFinite ? features[off + 2] : 0,
                    features[off + 3].isFinite ? features[off + 3] : 0,
                    features[off + 4].isFinite ? features[off + 4] : 0,
                    features[off + 5].isFinite ? features[off + 5] : 0,
                    features[off + 6].isFinite ? features[off + 6] : 0,
                    features[off + 7].isFinite ? features[off + 7] : 0
                )
                scratch[g] = raw8.clamped(lowerBound: lo8, upperBound: hi8)
            }

            let w1Ptr = basePtr.advanced(by: 32).assumingMemoryBound(to: Int8.self)
            for blk in 0..<48 {
                var pre8 = SIMD8<Float>.zero
                for lane in 0..<8 {
                    let row = blk * 8 + lane
                    let rPtr = w1Ptr.advanced(by: row * 64)
                    var acc = SIMD8<Float>.zero
                    for g in 0..<8 {
                        let gOff = g * 8
                        let w8 = SIMD8<Float>(
                            Float(rPtr[gOff]), Float(rPtr[gOff + 1]), Float(rPtr[gOff + 2]), Float(rPtr[gOff + 3]),
                            Float(rPtr[gOff + 4]), Float(rPtr[gOff + 5]), Float(rPtr[gOff + 6]), Float(rPtr[gOff + 7])
                        )
                        acc += w8 * scratch[g]
                    }
                    pre8[lane] = acc.sum() * lntrScale1[row] + lntrB1[row]
                }
                scratch[8 + blk] = Self.silu8(pre8)
            }

            let w2Ptr = basePtr.advanced(by: w2Offset).assumingMemoryBound(to: Int8.self)
            var outDot: Float = 0.0
            for blk2 in 0..<6 {
                var pre2 = SIMD8<Float>.zero
                for lane in 0..<8 {
                    let row2 = blk2 * 8 + lane
                    let rPtr2 = w2Ptr.advanced(by: row2 * 384)
                    var acc2 = SIMD8<Float>.zero
                    for b1Idx in 0..<48 {
                        let gOff = b1Idx * 8
                        let w8 = SIMD8<Float>(
                            Float(rPtr2[gOff]), Float(rPtr2[gOff + 1]), Float(rPtr2[gOff + 2]), Float(rPtr2[gOff + 3]),
                            Float(rPtr2[gOff + 4]), Float(rPtr2[gOff + 5]), Float(rPtr2[gOff + 6]), Float(rPtr2[gOff + 7])
                        )
                        acc2 += w8 * scratch[8 + b1Idx]
                    }
                    pre2[lane] = acc2.sum()
                }
                let h2 = Self.silu8(pre2 * lntrScale2[blk2] + lntrB2[blk2])
                outDot += (h2 * lntrW3[blk2]).sum()
            }

            let skipDot = (lntrResLin0 * scratch[0] + lntrResLin1 * scratch[1]).sum()
            let rawOut = outDot + skipDot + lntrB3
            guard rawOut.isFinite else { return 0 }
            let scaled = (rawOut * 170.0).rounded()
            guard scaled.isFinite else { return rawOut > 0 ? lntrMaxDeltaQ8 : -lntrMaxDeltaQ8 }
            let cap = Float(lntrMaxDeltaQ8)
            return Int(min(cap, max(-cap, scaled)))
        }
    }

    @inline(__always)
    public func scoreTypoDeltaQ8(challenger: [Float], incumbent: [Float]) -> Int {
        guard hasBinarySection, hasTypoReranker else { return 0 }
        let diff = scoreTypoCandidateQ8(features: challenger) - scoreTypoCandidateQ8(features: incumbent)
        return min(lntrMaxDeltaQ8, max(-lntrMaxDeltaQ8, diff))
    }

    // MARK: - Zero-Copy `mmap` Embedding & Consolidated Word Record Lookups

    private func lookupBackwardCharDelta(_ ch: Character) -> Vec32 {
        guard bwdCharResCount > 0, let scalar = ch.unicodeScalars.first else { return .zero }
        let v = Int(scalar.value)
        guard v >= 0x4E00 && v < 0xA000 else { return .zero }
        let targetCode = v - 0x4E00
        var lo = 0
        var hi = bwdCharResCount - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let recOff = bwdCharResOffset + mid * 36
            let code = Int(Self.loadU16(bwdRawBuffer, at: recOff))
            if code == targetCode {
                return Self.loadQuantizedVec32(bwdRawBuffer, at: recOff + 4)
            } else if code < targetCode {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return .zero
    }

    private func lookupBackwardWordDelta(_ word: String) -> Vec32 {
        guard bwdWordResCount > 0 else { return .zero }
        var query = word
        return query.withUTF8 { queryBuf -> Vec32 in
            guard !queryBuf.isEmpty else { return .zero }
            var lo = 0
            var hi = bwdWordResCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let recOff = bwdWordResOffset + mid * 40
                let sOff = Int(Self.loadU32(bwdRawBuffer, at: recOff))
                let sLen = Int(Self.loadU16(bwdRawBuffer, at: recOff + 4))
                let cmp = Self.compareArbitraryPoolBytes(
                    bwdRawBuffer,
                    poolOffset: bwdWordPoolOffset,
                    poolSize: bwdWordPoolSize,
                    offset: sOff,
                    length: sLen,
                    against: queryBuf
                )
                if cmp == 0 {
                    return Self.loadQuantizedVec32(bwdRawBuffer, at: recOff + 8)
                } else if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return .zero
        }
    }

    private func semanticEmbedding(forChar ch: Character) -> EmbeddingPair {
        guard hasSemantic64, let scalar = ch.unicodeScalars.first else { return .zero }
        let v = Int(scalar.value)
        guard v >= 0x4E00 && v < 0xA000 else { return .zero }
        let cid = Int(Self.loadU16(sem64RawBuffer, at: sem64CharMapOffset + (v - 0x4E00) * 2))
        guard cid > 0 && cid <= sem64CharCount else { return .zero }
        if sem64QuantMode == 1 {
            let off = sem64CharEmbOffset + cid * 64
            return EmbeddingPair(
                ctx: Self.loadQuantizedVec32(sem64RawBuffer, at: off),
                tgt: Self.loadQuantizedVec32(sem64RawBuffer, at: off + 32)
            )
        } else {
            let off = sem64CharEmbOffset + cid * 128
            return EmbeddingPair(
                ctx: Self.loadFloat16Vec32(sem64RawBuffer, at: off),
                tgt: Self.loadFloat16Vec32(sem64RawBuffer, at: off + 64)
            )
        }
    }

    private func lookupSemanticWordEmbedding(_ word: String) -> EmbeddingPair? {
        guard hasSemantic64, sem64WordCount > 0 else { return nil }
        let pairBytes = (sem64QuantMode == 1) ? 64 : 128
        let strideBytes = 8 + pairBytes
        var query = word
        return query.withUTF8 { queryBuf -> EmbeddingPair? in
            guard !queryBuf.isEmpty else { return nil }
            var lo = 0
            var hi = sem64WordCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let recOff = sem64WordTableOffset + mid * strideBytes
                let sOff = Int(Self.loadU32(sem64RawBuffer, at: recOff))
                let sLen = Int(Self.loadU16(sem64RawBuffer, at: recOff + 4))
                let cmp = Self.compareArbitraryPoolBytes(
                    sem64RawBuffer,
                    poolOffset: sem64PoolOffset,
                    poolSize: sem64PoolSize,
                    offset: sOff,
                    length: sLen,
                    against: queryBuf
                )
                if cmp == 0 {
                    if sem64QuantMode == 1 {
                        return EmbeddingPair(
                            ctx: Self.loadQuantizedVec32(sem64RawBuffer, at: recOff + 8),
                            tgt: Self.loadQuantizedVec32(sem64RawBuffer, at: recOff + 40)
                        )
                    } else {
                        return EmbeddingPair(
                            ctx: Self.loadFloat16Vec32(sem64RawBuffer, at: recOff + 8),
                            tgt: Self.loadFloat16Vec32(sem64RawBuffer, at: recOff + 72)
                        )
                    }
                } else if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return nil
        }
    }

    @inline(__always)
    public func embedding(forChar ch: Character) -> EmbeddingPair {
        guard hasBinarySection, let scalar = ch.unicodeScalars.first else {
            return .zero
        }
        return embedding(forScalarValue: Int(scalar.value))
    }

    @inline(__always)
    private func embedding(forScalarValue v: Int) -> EmbeddingPair {
        guard hasBinarySection, v >= 0x4E00 && v < 0xA000 else {
            return .zero
        }
        let cid = Int(Self.loadU16(rawBuffer, at: charMapOffset + (v - 0x4E00) * 2))
        guard cid > 0 && cid <= charVocabCount else { return .zero }
        // Keep the quantized vectors in read-only mapped pages. Expand only the active character.
        if modelVersion == 2 {
            let offset = charEmbOffset + cid * 64
            return EmbeddingPair(ctx: Self.loadQuantizedVec32(rawBuffer, at: offset),
                                 tgt: Self.loadQuantizedVec32(rawBuffer, at: offset + 32))
        }
        let offset = charEmbOffset + cid * 32
        return EmbeddingPair(ctx: Self.loadQuantizedVec16As32(rawBuffer, at: offset),
                             tgt: Self.loadQuantizedVec16As32(rawBuffer, at: offset + 16))
    }

    @inline(__always)
    public func wordRecord(for word: String) -> WordNeuralRecord {
        wordRecord(for: word, prefetchedEmbedding: nil)
    }

    @inline(__always)
    private func wordRecord(for word: String, prefetchedEmbedding: EmbeddingPair?) -> WordNeuralRecord {
        guard hasBinarySection, !word.isEmpty else {
            return .empty
        }
        os_unfair_lock_lock(&cacheLock)
        if let cached = wordRecordCache[word] {
            os_unfair_lock_unlock(&cacheLock)
            return cached
        }
        os_unfair_lock_unlock(&cacheLock)

        let cCount = word.count
        let firstCh = word.first ?? Character(" ")
        let lastCh = word.last ?? firstCh
        let lastScalar = lastCh.unicodeScalars.first?.value ?? 0
        let firstCharEmb = embedding(forChar: firstCh)

        let resolvedEmb: EmbeddingPair
        if let prefetchedEmbedding {
            resolvedEmb = prefetchedEmbedding
        } else if cCount == 1 {
            resolvedEmb = lookupWordTableEmbedding(word) ?? firstCharEmb
        } else if let hit = lookupWordTableEmbedding(word) {
            resolvedEmb = hit
        } else {
            let lastCharEmb = embedding(forScalarValue: Int(lastScalar))
            // Compositional neural pooling for out-of-table compound words (`0.35 * firstChar + 0.65 * lastChar`),
            // clearing dim 30 (`ACCIDENTAL_TYPO_SINGLETON`) and setting dim 31 (`LEXICAL_MULTIWORD_FLOW = 0.45`).
            var cV = 0.35 * firstCharEmb.ctx + 0.65 * lastCharEmb.ctx
            var tV = 0.65 * firstCharEmb.tgt + 0.35 * lastCharEmb.tgt
            if modelVersion >= 2 {
                cV.v3[6] = 0.0
                tV.v3[6] = 0.0
                cV.v3[7] = 0.45
                tV.v3[7] = 0.45
            }
            resolvedEmb = EmbeddingPair(ctx: cV, tgt: tV)
        }

        var sCtx = Vec32.zero
        var sTgt = Vec32.zero
        if hasSemantic64 {
            if let semHit = lookupSemanticWordEmbedding(word) {
                sCtx = semHit.ctx
                sTgt = semHit.tgt
            } else {
                let fSem = semanticEmbedding(forChar: firstCh)
                if cCount == 1 {
                    sCtx = fSem.ctx
                    sTgt = fSem.tgt
                } else {
                    let lSem = semanticEmbedding(forChar: lastCh)
                    sCtx = 0.35 * fSem.ctx + 0.65 * lSem.ctx
                    sTgt = 0.65 * fSem.tgt + 0.35 * lSem.tgt
                }
            }
        }

        let tanhCtx = Self.tanh32(resolvedEmb.ctx)
        let eosCtxScore = uEos.dot(resolvedEmb.ctx)
        let isSingleton = (cCount == 1 && resolvedEmb.tgt.v3[6] > 0.5)

        os_unfair_lock_lock(&cacheLock)
        if let existing = wordRecordCache[word] {
            os_unfair_lock_unlock(&cacheLock)
            return existing
        }
        let cid = nextRecordCacheId
        nextRecordCacheId &+= 1
        if nextRecordCacheId == 0 {
            nextRecordCacheId = 1
            for idx in contextProjSlots.indices {
                contextProjSlots[idx].cacheId = 0
            }
        }
        let built = WordNeuralRecord(
            ctx: resolvedEmb.ctx,
            tanhCtx: tanhCtx,
            tgt: resolvedEmb.tgt,
            firstCharTgt: firstCharEmb.tgt,
            eosCtxScore: eosCtxScore,
            charCount: cCount,
            isAccidentalSingleton: isSingleton,
            semCtx: sCtx,
            semTgt: sTgt,
            cacheId: cid,
            lastCharScalar: lastScalar
        )
        if wordRecordRing.count >= Self.maxWordRecordCacheCount {
            let victim = wordRecordRing[wordRecordRingCursor]
            wordRecordCache.removeValue(forKey: victim)
            wordRecordRing[wordRecordRingCursor] = word
            wordRecordRingCursor += 1
            if wordRecordRingCursor == Self.maxWordRecordCacheCount {
                wordRecordRingCursor = 0
            }
        } else {
            wordRecordRing.append(word)
        }
        wordRecordCache[word] = built
        os_unfair_lock_unlock(&cacheLock)
        return built
    }

    func lookupWordTableEmbedding(_ word: String) -> EmbeddingPair? {
        guard wordVocabCount > 0 else { return nil }
        let raw = rawBuffer
        let strideBytes = (modelVersion >= 2) ? 72 : 40
        var query = word
        return query.withUTF8 { queryBuf -> EmbeddingPair? in
            guard !queryBuf.isEmpty else { return nil }
            var lo = 0
            var hi = wordVocabCount - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let recOff = wordTableOffset + mid * strideBytes
                let sOff = Int(Self.loadU32(raw, at: recOff))
                let sLen = Int(Self.loadU16(raw, at: recOff + 4))
                let cmp = comparePoolBytes(raw, offset: sOff, length: sLen, against: queryBuf)
                if cmp == 0 {
                    if modelVersion >= 2 {
                        let cV = Self.loadQuantizedVec32(raw, at: recOff + 8)
                        let tV = Self.loadQuantizedVec32(raw, at: recOff + 40)
                        return EmbeddingPair(ctx: cV, tgt: tV)
                    } else {
                        let cV = Self.loadQuantizedVec16As32(raw, at: recOff + 8)
                        let tV = Self.loadQuantizedVec16As32(raw, at: recOff + 24)
                        return EmbeddingPair(ctx: cV, tgt: tV)
                    }
                } else if cmp < 0 {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return nil
        }
    }

    // MARK: - SIMD & Low-Level Helpers

    private static func transpose32x32(_ rows: [Vec32]) -> [Vec32] {
        func scalar(_ v: Vec32, _ idx: Int) -> Float {
            switch idx >> 3 {
            case 0: return v.v0[idx & 7]
            case 1: return v.v1[idx & 7]
            case 2: return v.v2[idx & 7]
            default: return v.v3[idx & 7]
            }
        }
        var cols: [Vec32] = []
        cols.reserveCapacity(32)
        for c in 0..<32 {
            let v0 = SIMD8<Float>(
                scalar(rows[0], c), scalar(rows[1], c), scalar(rows[2], c), scalar(rows[3], c),
                scalar(rows[4], c), scalar(rows[5], c), scalar(rows[6], c), scalar(rows[7], c)
            )
            let v1 = SIMD8<Float>(
                scalar(rows[8], c), scalar(rows[9], c), scalar(rows[10], c), scalar(rows[11], c),
                scalar(rows[12], c), scalar(rows[13], c), scalar(rows[14], c), scalar(rows[15], c)
            )
            let v2 = SIMD8<Float>(
                scalar(rows[16], c), scalar(rows[17], c), scalar(rows[18], c), scalar(rows[19], c),
                scalar(rows[20], c), scalar(rows[21], c), scalar(rows[22], c), scalar(rows[23], c)
            )
            let v3 = SIMD8<Float>(
                scalar(rows[24], c), scalar(rows[25], c), scalar(rows[26], c), scalar(rows[27], c),
                scalar(rows[28], c), scalar(rows[29], c), scalar(rows[30], c), scalar(rows[31], c)
            )
            cols.append(Vec32(v0: v0, v1: v1, v2: v2, v3: v3))
        }
        return cols
    }

    /// Branchless column-major `32x32` SIMD8 FMA matrix-vector multiply (in-register NEON FMA, zero stack spills).
    @inline(__always)
    private static func matVec32(_ columns: [Vec32], x: Vec32) -> Vec32 {
        var r0 = SIMD8<Float>.zero
        var r1 = SIMD8<Float>.zero
        var r2 = SIMD8<Float>.zero
        var r3 = SIMD8<Float>.zero
        columns.withUnsafeBufferPointer { cols in
            guard cols.count >= 32, let p = cols.baseAddress else { return }
            @inline(__always)
            func accum(_ vec: SIMD8<Float>, base: Int) {
                let s0 = vec[0], s1 = vec[1], s2 = vec[2], s3 = vec[3]
                let s4 = vec[4], s5 = vec[5], s6 = vec[6], s7 = vec[7]
                let c0 = p[base];     r0.addProduct(s0, c0.v0); r1.addProduct(s0, c0.v1); r2.addProduct(s0, c0.v2); r3.addProduct(s0, c0.v3)
                let c1 = p[base + 1]; r0.addProduct(s1, c1.v0); r1.addProduct(s1, c1.v1); r2.addProduct(s1, c1.v2); r3.addProduct(s1, c1.v3)
                let c2 = p[base + 2]; r0.addProduct(s2, c2.v0); r1.addProduct(s2, c2.v1); r2.addProduct(s2, c2.v2); r3.addProduct(s2, c2.v3)
                let c3 = p[base + 3]; r0.addProduct(s3, c3.v0); r1.addProduct(s3, c3.v1); r2.addProduct(s3, c3.v2); r3.addProduct(s3, c3.v3)
                let c4 = p[base + 4]; r0.addProduct(s4, c4.v0); r1.addProduct(s4, c4.v1); r2.addProduct(s4, c4.v2); r3.addProduct(s4, c4.v3)
                let c5 = p[base + 5]; r0.addProduct(s5, c5.v0); r1.addProduct(s5, c5.v1); r2.addProduct(s5, c5.v2); r3.addProduct(s5, c5.v3)
                let c6 = p[base + 6]; r0.addProduct(s6, c6.v0); r1.addProduct(s6, c6.v1); r2.addProduct(s6, c6.v2); r3.addProduct(s6, c6.v3)
                let c7 = p[base + 7]; r0.addProduct(s7, c7.v0); r1.addProduct(s7, c7.v1); r2.addProduct(s7, c7.v2); r3.addProduct(s7, c7.v3)
            }
            accum(x.v0, base: 0)
            accum(x.v1, base: 8)
            accum(x.v2, base: 16)
            accum(x.v3, base: 24)
        }
        return Vec32(v0: r0, v1: r1, v2: r2, v3: r3)
    }

    @inline(__always)
    private static func clampVec32(_ x: Vec32, lower: SIMD8<Float>, upper: SIMD8<Float>) -> Vec32 {
        Vec32(
            v0: x.v0.clamped(lowerBound: lower, upperBound: upper),
            v1: x.v1.clamped(lowerBound: lower, upperBound: upper),
            v2: x.v2.clamped(lowerBound: lower, upperBound: upper),
            v3: x.v3.clamped(lowerBound: lower, upperBound: upper)
        )
    }

    @inline(__always)
    private static func approxSigmoidScalar(_ x: Float) -> Float {
        guard x.isFinite else { return 0.5 }
        let ax = abs(x)
        let x2 = x * x
        let denom: Float = 1.0 + ax + 0.27 * x2 + 0.035 * ax * x2
        return 0.5 + (0.5 * x) / denom
    }

    @inline(__always)
    private static func silu32(_ x: Vec32) -> Vec32 {
        Vec32(v0: silu8(x.v0), v1: silu8(x.v1), v2: silu8(x.v2), v3: silu8(x.v3))
    }

    @inline(__always)
    private static func tanh32(_ x: Vec32) -> Vec32 {
        Vec32(v0: tanh8(x.v0), v1: tanh8(x.v1), v2: tanh8(x.v2), v3: tanh8(x.v3))
    }

    /// Fast rational Padé approximation of `SiLU(x) = x / (1 + exp(-x))` on `SIMD8<Float>`.
    @inline(__always)
    private static func silu8(_ x: SIMD8<Float>) -> SIMD8<Float> {
        let one = SIMD8<Float>(repeating: 1.0)
        let half = SIMD8<Float>(repeating: 0.5)
        let c1 = SIMD8<Float>(repeating: 0.27)
        let c2 = SIMD8<Float>(repeating: 0.035)
        let ax = simd_abs(x)
        let x2 = x * x
        let denom = one + ax + c1 * x2 + c2 * ax * x2
        let sig = half + (x * half) / denom
        return x * sig
    }

    /// Fast rational Padé approximation of `tanh(x)` on `SIMD8<Float>`.
    @inline(__always)
    private static func tanh8(_ x: SIMD8<Float>) -> SIMD8<Float> {
        let clamped = x.clamped(lowerBound: SIMD8<Float>(repeating: -3.0), upperBound: SIMD8<Float>(repeating: 3.0))
        let x2 = clamped * clamped
        let c27 = SIMD8<Float>(repeating: 27.0)
        let c9 = SIMD8<Float>(repeating: 9.0)
        return clamped * (c27 + x2) / (c27 + c9 * x2)
    }

    @inline(__always)
    private static func halfBitsToFloat(_ h: UInt16) -> Float {
        if (h & 0x7C00) == 0x7C00 { return 0.0 }
        #if arch(arm64)
        return Float(Float16(bitPattern: h))
        #else
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int((h >> 10) & 0x1F)
        let mant = UInt32(h & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let s: Float = (h & 0x8000) != 0 ? -1.0 : 1.0
            return s * Float(mant) * (1.0 / 16_777_216.0)
        }
        return Float(bitPattern: sign | (UInt32(exp + 112) << 23) | (mant << 13))
        #endif
    }

    @inline(__always)
    private static func loadFloat16Vec32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Vec32 {
        guard offset >= 0, offset <= raw.count - 64 else { return .zero }
        @inline(__always)
        func lane8(_ baseOff: Int) -> SIMD8<Float> {
            SIMD8<Float>(
                halfBitsToFloat(loadU16(raw, at: baseOff)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 2)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 4)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 6)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 8)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 10)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 12)),
                halfBitsToFloat(loadU16(raw, at: baseOff + 14))
            )
        }
        return Vec32(
            v0: lane8(offset),
            v1: lane8(offset + 16),
            v2: lane8(offset + 32),
            v3: lane8(offset + 48)
        )
    }

    @inline(__always)
    private static func loadQuantizedVec32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Vec32 {
        let scale: Float = 1.0 / 32.0
        guard offset >= 0, offset <= raw.count - 32, let base = raw.baseAddress else { return .zero }
        let p = base.advanced(by: offset).assumingMemoryBound(to: Int8.self)
        let v0 = SIMD8<Float>(
            Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3]),
            Float(p[4]), Float(p[5]), Float(p[6]), Float(p[7])
        ) * scale
        let v1 = SIMD8<Float>(
            Float(p[8]), Float(p[9]), Float(p[10]), Float(p[11]),
            Float(p[12]), Float(p[13]), Float(p[14]), Float(p[15])
        ) * scale
        let v2 = SIMD8<Float>(
            Float(p[16]), Float(p[17]), Float(p[18]), Float(p[19]),
            Float(p[20]), Float(p[21]), Float(p[22]), Float(p[23])
        ) * scale
        let v3 = SIMD8<Float>(
            Float(p[24]), Float(p[25]), Float(p[26]), Float(p[27]),
            Float(p[28]), Float(p[29]), Float(p[30]), Float(p[31])
        ) * scale
        return Vec32(v0: v0, v1: v1, v2: v2, v3: v3)
    }

    @inline(__always)
    private static func loadQuantizedVec16As32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Vec32 {
        let scale: Float = 1.0 / 32.0
        guard offset >= 0, offset <= raw.count - 16, let base = raw.baseAddress else { return .zero }
        let p = base.advanced(by: offset).assumingMemoryBound(to: Int8.self)
        let v0 = SIMD8<Float>(
            Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3]),
            Float(p[4]), Float(p[5]), Float(p[6]), Float(p[7])
        ) * scale
        let v1 = SIMD8<Float>(
            Float(p[8]), Float(p[9]), Float(p[10]), Float(p[11]),
            Float(p[12]), Float(p[13]), Float(p[14]), Float(p[15])
        ) * scale
        return Vec32(v0: v0, v1: v1, v2: .zero, v3: .zero)
    }

    @inline(__always)
    private static func loadSIMD8F32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> SIMD8<Float> {
        guard offset >= 0, offset <= raw.count - 32 else { return .zero }
        let f0 = Float(bitPattern: loadU32(raw, at: offset))
        let f1 = Float(bitPattern: loadU32(raw, at: offset + 4))
        let f2 = Float(bitPattern: loadU32(raw, at: offset + 8))
        let f3 = Float(bitPattern: loadU32(raw, at: offset + 12))
        let f4 = Float(bitPattern: loadU32(raw, at: offset + 16))
        let f5 = Float(bitPattern: loadU32(raw, at: offset + 20))
        let f6 = Float(bitPattern: loadU32(raw, at: offset + 24))
        let f7 = Float(bitPattern: loadU32(raw, at: offset + 28))
        return SIMD8<Float>(f0, f1, f2, f3, f4, f5, f6, f7)
    }

    @inline(__always)
    private static func loadU16(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        guard let base = raw.baseAddress, UInt(bitPattern: offset) &+ 2 <= UInt(bitPattern: raw.count) else { return 0 }
        return UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    private static func loadU32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        guard let base = raw.baseAddress, UInt(bitPattern: offset) &+ 4 <= UInt(bitPattern: raw.count) else { return 0 }
        return UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    private static func compareArbitraryPoolBytes(
        _ raw: UnsafeRawBufferPointer,
        poolOffset: Int,
        poolSize: Int,
        offset: Int,
        length: Int,
        against rhs: UnsafeBufferPointer<UInt8>
    ) -> Int {
        guard let base = raw.baseAddress,
              offset >= 0 && length > 0 && offset <= poolSize && length <= poolSize - offset else { return -1 }
        let ptr = base.advanced(by: poolOffset + offset).assumingMemoryBound(to: UInt8.self)
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
    private func comparePoolBytes(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int, against rhs: UnsafeBufferPointer<UInt8>) -> Int {
        Self.compareArbitraryPoolBytes(
            raw,
            poolOffset: stringPoolOffset,
            poolSize: stringPoolSize,
            offset: offset,
            length: length,
            against: rhs
        )
    }
}
