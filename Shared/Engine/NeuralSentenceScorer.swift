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

    /// Pre-bundled neural projections for a lexical word so Viterbi inner loops run 100% lock-free in SIMD registers.
    public struct WordNeuralRecord: Sendable {
        public let ctx: Vec32
        public let tanhCtx: Vec32
        public let tgt: Vec32
        public let firstCharTgt: Vec32
        public let wx: Vec32
        public let bd: Vec32
        public let cp: Vec32
        public let eosCtxScore: Float
        public let charCount: Int
        public let isAccidentalSingleton: Bool

        public static let empty = WordNeuralRecord(
            ctx: .zero,
            tanhCtx: .zero,
            tgt: .zero,
            firstCharTgt: .zero,
            wx: .zero,
            bd: .zero,
            cp: .zero,
            eosCtxScore: 0.0,
            charCount: 0,
            isAccidentalSingleton: false
        )
    }

    public struct StepPredictor: Sendable {
        public let wordPred: Vec32
        public let charPred: Vec32
        public let z: Vec32
        public let prevHidden: Vec32
        public let lastCtx: Vec32
        public let hasContext: Bool
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

    // L1-cache-resident 32x32 backward rerank head (`LNBR` v1, 25.3 KB total, shares frozen embeddings)
    private let hasBackwardHead: Bool
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

    // Consolidated in-memory cache for hot word records (single lock acquisition per unique word)
    private var cacheLock = os_unfair_lock_s()
    private var wordRecordCache: [String: WordNeuralRecord] = [:]
    private var wordRecordRing: [String] = []
    private var wordRecordRingCursor: Int = 0
    private static let maxWordRecordCacheCount = 3072

    public static let magicLNLM: UInt32 = 0x4D4C4E4C // "LNLM"
    public static let magicLNBR: UInt32 = 0x52424E4C // "LNBR"
    public static let backwardBinaryByteSize: Int = 16 + 6336 * 4
    public static let maxBonusQ8: Int = 520
    public static let minBonusQ8: Int = -560

    public enum LNLMValidationError: Error, Equatable {
        case invalidFooter
        case invalidHeader
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
        return (offset: off, size: sz, charCount: cCount, wordCount: wCount)
    }

    private struct ParsedBackwardHead {
        let loaded: Bool
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

    private static func parseBackwardHead(_ data: NSData?) -> ParsedBackwardHead {
        guard let data, data.length >= backwardBinaryByteSize else {
            return .empty
        }
        let raw = UnsafeRawBufferPointer(start: data.bytes, count: data.length)
        let magic = loadU32(raw, at: 0)
        let ver = loadU32(raw, at: 4)
        let dim = loadU32(raw, at: 8)
        let floatCount = loadU32(raw, at: 12)
        guard magic == magicLNBR, ver == 1, dim == 32, floatCount == 6336 else {
            return .empty
        }
        for i in 0..<6336 {
            let weight = Float(bitPattern: loadU32(raw, at: 16 + i * 4))
            guard weight.isFinite, abs(weight) <= 100.0 else {
                return .empty
            }
        }
        // `bwd_alpha` occupies indices [6208..<6240]
        for i in 6208..<6240 {
            let a = Float(bitPattern: loadU32(raw, at: 16 + i * 4))
            guard a >= 0.01, a <= 0.99 else {
                return .empty
            }
        }

        var cursor = 16
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

    public convenience init(
        data: Data,
        stringPoolOffset: Int,
        stringPoolSize: Int,
        backwardData: Data? = nil
    ) {
        self.init(
            nsData: data as NSData,
            stringPoolOffset: stringPoolOffset,
            stringPoolSize: stringPoolSize,
            backwardData: backwardData as NSData?
        )
    }

    public init(
        nsData: NSData,
        stringPoolOffset: Int,
        stringPoolSize: Int,
        backwardData: NSData? = nil
    ) {
        let parsedBwd = Self.parseBackwardHead(backwardData)
        self.hasBackwardHead = parsedBwd.loaded
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

                self.wordRecordCache.reserveCapacity(Self.maxWordRecordCacheCount)
                self.wordRecordRing.reserveCapacity(Self.maxWordRecordCacheCount)
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

                self.wordRecordCache.reserveCapacity(Self.maxWordRecordCacheCount)
                self.wordRecordRing.reserveCapacity(Self.maxWordRecordCacheCount)
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
    public var version: UInt32 { modelVersion }

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
    public func prepareStepPredictor(lastWord: String, hidden: Vec32) -> StepPredictor {
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
        return prepareStepPredictor(lastRecord: wordRecord(for: lastWord), hidden: hidden)
    }

    @inline(__always)
    public func prepareStepPredictor(lastRecord: WordNeuralRecord, hidden: Vec32) -> StepPredictor {
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

        // Layer 1: z = SiLU(W_ctx * v_ctx(w_{m-1}) + W_rec * h_{m-1} + b_1)
        let wr = Self.matVec32(wRecRows, x: hidden)
        let z = Self.silu32(lastRecord.wx + wr + b1)

        // Layer 2: p_word = W_proj * z + B_direct * v_ctx(w_{m-1}) + B_skip * h_{m-1} + b_2
        let wp = Self.matVec32(wProjRows, x: z)
        let bs = Self.matVec32(bSkipRows, x: hidden)
        let wordPred = wp + lastRecord.bd + bs + b2

        return StepPredictor(
            wordPred: wordPred,
            charPred: lastRecord.cp,
            z: z,
            prevHidden: hidden,
            lastCtx: lastRecord.ctx,
            hasContext: true
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

    /// Evaluates total neural sentence coherence across a segmented word sequence `words`.
    public func scoreWholeSentence(words: [String], precedingContext: String? = nil) -> Int {
        guard hasBinarySection, !words.isEmpty else { return 0 }
        var hidden = initialHiddenState(precedingContext: precedingContext)
        var prevWord = ViterbiDecoder.extractTrailingChineseSuffix(from: precedingContext ?? "", maxChars: 3)
        var totalQ8 = 0
        var oneCharRun = prevWord.count == 1 ? 1 : 0

        for (idx, w) in words.enumerated() {
            let isLast = (idx == words.count - 1)
            let wRec = wordRecord(for: w)
            if !prevWord.isEmpty {
                let prevRec = wordRecord(for: prevWord)
                let pred = prepareStepPredictor(lastRecord: prevRec, hidden: hidden)
                totalQ8 += scorePreloadedCandidate(
                    predictor: pred,
                    record: wRec,
                    singleCharRun: oneCharRun,
                    isEndOfSentence: isLast
                )
                hidden = advanceHiddenState(predictor: pred, record: wRec)
            } else {
                hidden = advanceHiddenStateFromBOS(record: wRec, baseHidden: hidden)
            }
            if wRec.charCount == 1 {
                oneCharRun += 1
            } else {
                oneCharRun = 0
            }
            prevWord = w
        }
        return totalQ8
    }

    /// Evaluates right-to-left (`LNBR` v1) coherence across a segmented word sequence `words`.
    /// Reuses frozen `LNLM-v2` character/word embeddings while disambiguating early words from later context.
    public func scoreBackwardSentence(words: [String]) -> Int {
        guard hasBinarySection, hasBackwardHead, words.count >= 2 else { return 0 }
        var rightWord = words[words.count - 1]
        var rightRec = wordRecord(for: rightWord)
        guard rightRec.charCount > 0 else { return 0 }
        var hidden = bwdAlpha * bwdHEos + bwdOneMinusAlpha * rightRec.tanhCtx

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
            let leftLastTgt = leftWord.last.map { embedding(forChar: $0).tgt } ?? .zero
            let charPred = Self.matVec32(bwdWCharRows, x: rightFirstCtx)

            var raw = wordPred.dot(leftRec.tgt) + 0.30 * charPred.dot(leftLastTgt)
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

    // MARK: - Zero-Copy `mmap` Embedding & Consolidated Word Record Lookups

    @inline(__always)
    public func embedding(forChar ch: Character) -> EmbeddingPair {
        guard hasBinarySection, let scalar = ch.unicodeScalars.first else {
            return .zero
        }
        let v = Int(scalar.value)
        guard v >= 0x4E00 && v < 0xA000 else {
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
        let firstCharEmb = embedding(forChar: firstCh)
        let lastCharEmb = (cCount == 1) ? firstCharEmb : embedding(forChar: lastCh)

        let resolvedEmb: EmbeddingPair
        if let prefetchedEmbedding {
            resolvedEmb = prefetchedEmbedding
        } else if cCount == 1 {
            resolvedEmb = lookupWordTableEmbedding(word) ?? firstCharEmb
        } else if let hit = lookupWordTableEmbedding(word) {
            resolvedEmb = hit
        } else {
            // Compositional neural pooling for out-of-table compound words (`0.35 * firstChar + 0.65 * lastChar`),
            // clearing dim 30 (`ACCIDENTAL_TYPO_SINGLETON`) and setting dim 31 (`LEXICAL_MULTIWORD_FLOW = 0.45`)!
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

        let built = WordNeuralRecord(
            ctx: resolvedEmb.ctx,
            tanhCtx: Self.tanh32(resolvedEmb.ctx),
            tgt: resolvedEmb.tgt,
            firstCharTgt: firstCharEmb.tgt,
            wx: Self.matVec32(wCtxRows, x: resolvedEmb.ctx),
            bd: Self.matVec32(bDirectRows, x: resolvedEmb.ctx),
            cp: Self.matVec32(wCharRows, x: lastCharEmb.ctx),
            eosCtxScore: uEos.dot(resolvedEmb.ctx),
            charCount: cCount,
            isAccidentalSingleton: cCount == 1 && resolvedEmb.tgt.v3[6] > 0.5
        )

        os_unfair_lock_lock(&cacheLock)
        if wordRecordCache[word] == nil {
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
        }
        os_unfair_lock_unlock(&cacheLock)
        return built
    }

    private func lookupWordTableEmbedding(_ word: String) -> EmbeddingPair? {
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
                let c0 = p[base];     r0.addProduct(vec[0], c0.v0); r1.addProduct(vec[0], c0.v1); r2.addProduct(vec[0], c0.v2); r3.addProduct(vec[0], c0.v3)
                let c1 = p[base + 1]; r0.addProduct(vec[1], c1.v0); r1.addProduct(vec[1], c1.v1); r2.addProduct(vec[1], c1.v2); r3.addProduct(vec[1], c1.v3)
                let c2 = p[base + 2]; r0.addProduct(vec[2], c2.v0); r1.addProduct(vec[2], c2.v1); r2.addProduct(vec[2], c2.v2); r3.addProduct(vec[2], c2.v3)
                let c3 = p[base + 3]; r0.addProduct(vec[3], c3.v0); r1.addProduct(vec[3], c3.v1); r2.addProduct(vec[3], c3.v2); r3.addProduct(vec[3], c3.v3)
                let c4 = p[base + 4]; r0.addProduct(vec[4], c4.v0); r1.addProduct(vec[4], c4.v1); r2.addProduct(vec[4], c4.v2); r3.addProduct(vec[4], c4.v3)
                let c5 = p[base + 5]; r0.addProduct(vec[5], c5.v0); r1.addProduct(vec[5], c5.v1); r2.addProduct(vec[5], c5.v2); r3.addProduct(vec[5], c5.v3)
                let c6 = p[base + 6]; r0.addProduct(vec[6], c6.v0); r1.addProduct(vec[6], c6.v1); r2.addProduct(vec[6], c6.v2); r3.addProduct(vec[6], c6.v3)
                let c7 = p[base + 7]; r0.addProduct(vec[7], c7.v0); r1.addProduct(vec[7], c7.v1); r2.addProduct(vec[7], c7.v2); r3.addProduct(vec[7], c7.v3)
            }
            accum(x.v0, base: 0)
            accum(x.v1, base: 8)
            accum(x.v2, base: 16)
            accum(x.v3, base: 24)
        }
        return Vec32(v0: r0, v1: r1, v2: r2, v3: r3)
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
    private static func loadQuantizedVec32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Vec32 {
        let scale: Float = 1.0 / 32.0
        guard let base = raw.baseAddress else { return .zero }
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
        guard let base = raw.baseAddress else { return .zero }
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
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    private static func loadU32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    private func comparePoolBytes(_ raw: UnsafeRawBufferPointer, offset: Int, length: Int, against rhs: UnsafeBufferPointer<UInt8>) -> Int {
        guard let base = raw.baseAddress,
              offset >= 0 && length > 0 && offset + length <= stringPoolSize else { return -1 }
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
}
