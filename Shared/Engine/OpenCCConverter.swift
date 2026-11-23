import Foundation

/// Zero-copy memory-mapped OpenCC Simplified-to-Traditional Chinese converter.
///
/// Executes Rime `s2twp` and `s2hk` pipelines strictly offline using the compiled
/// `lokey_opencc.bin` (`LOCC`) dictionary image:
///   - `modeRawValue == 0`: Simplified passthrough
///   - `modeRawValue == 1` (`s2twp`): `[STPhrases ∪ STCharacters]` -> `TWPhrases` -> `TWVariants`
///   - `modeRawValue == 2` (`s2hk`):  `[STPhrases ∪ STCharacters]` -> `HKVariants`
public final class OpenCCConverter: @unchecked Sendable {
    public static let shared = OpenCCConverter()

    private static let loccMagic: UInt32 = 0x43434F4C  // "LOCC" little-endian
    private static let supportedVersion: UInt32 = 1

    private struct TableLayout {
        let stCharCount: Int
        let stCharOffset: Int
        let twVarCount: Int
        let twVarOffset: Int
        let hkVarCount: Int
        let hkVarOffset: Int

        let stBitmapOffset: Int
        let stIndexCount: Int
        let stIndexOffset: Int
        let stPhraseCount: Int
        let stPhraseOffset: Int

        let twBitmapOffset: Int
        let twIndexCount: Int
        let twIndexOffset: Int
        let twPhraseCount: Int
        let twPhraseOffset: Int

        let poolUnitCount: Int
        let poolOffset: Int
    }

    private let backingData: NSData?
    private let rawBuffer: UnsafeRawBufferPointer
    private let layout: TableLayout?

    public init() {
        if let url = Self.locateDefaultDictionary(),
           let loaded = Self.loadTable(from: url) {
            self.backingData = loaded.data
            self.rawBuffer = loaded.buffer
            self.layout = loaded.layout
        } else {
            self.backingData = nil
            self.rawBuffer = UnsafeRawBufferPointer(start: nil, count: 0)
            self.layout = nil
        }
    }

    public convenience init?(contentsOf url: URL) {
        self.init(verifiedURL: url)
    }

    private init?(verifiedURL url: URL) {
        guard let loaded = Self.loadTable(from: url) else {
            return nil
        }
        self.backingData = loaded.data
        self.rawBuffer = loaded.buffer
        self.layout = loaded.layout
    }

    /// Converts `text` according to `modeRawValue`:
    /// - `0`: Simplified Chinese passthrough (O(1))
    /// - `1`: Traditional Chinese (Taiwan standard, `s2twp`)
    /// - `2`: Traditional Chinese (Hong Kong standard, `s2hk`)
    public func convert(_ text: String, modeRawValue: Int) -> String {
        switch modeRawValue {
        case 1:
            return convertSimplifiedToTraditionalTW(text)
        case 2:
            return convertSimplifiedToTraditionalHK(text)
        default:
            return text
        }
    }

    /// Converts `text` according to `ChineseScriptMode`.
    public func convert(_ text: String, mode: ChineseScriptMode) -> String {
        convert(text, modeRawValue: mode.rawValue)
    }

    /// Converts Simplified Chinese text to Taiwan Standard Traditional Chinese (`s2twp`).
    public func convertSimplifiedToTraditionalTW(_ text: String) -> String {
        guard !text.isEmpty, let layout = layout, !Self.isPureASCII(text) else {
            return text
        }
        let stage1 = applyPhraseAndCharStage(
            units: Array(text.utf16),
            bitmapOffset: layout.stBitmapOffset,
            indexCount: layout.stIndexCount,
            indexOffset: layout.stIndexOffset,
            phraseCount: layout.stPhraseCount,
            phraseOffset: layout.stPhraseOffset,
            charCount: layout.stCharCount,
            charOffset: layout.stCharOffset,
            poolOffset: layout.poolOffset,
            poolUnitCount: layout.poolUnitCount
        )
        let stage2 = applyPhraseAndCharStage(
            units: stage1,
            bitmapOffset: layout.twBitmapOffset,
            indexCount: layout.twIndexCount,
            indexOffset: layout.twIndexOffset,
            phraseCount: layout.twPhraseCount,
            phraseOffset: layout.twPhraseOffset,
            charCount: 0,
            charOffset: 0,
            poolOffset: layout.poolOffset,
            poolUnitCount: layout.poolUnitCount
        )
        let stage3 = applyVariantStage(
            units: stage2,
            charCount: layout.twVarCount,
            charOffset: layout.twVarOffset
        )
        return String(utf16CodeUnits: stage3, count: stage3.count)
    }

    /// Converts Simplified Chinese text to Hong Kong Standard Traditional Chinese (`s2hk`).
    public func convertSimplifiedToTraditionalHK(_ text: String) -> String {
        guard !text.isEmpty, let layout = layout, !Self.isPureASCII(text) else {
            return text
        }
        let stage1 = applyPhraseAndCharStage(
            units: Array(text.utf16),
            bitmapOffset: layout.stBitmapOffset,
            indexCount: layout.stIndexCount,
            indexOffset: layout.stIndexOffset,
            phraseCount: layout.stPhraseCount,
            phraseOffset: layout.stPhraseOffset,
            charCount: layout.stCharCount,
            charOffset: layout.stCharOffset,
            poolOffset: layout.poolOffset,
            poolUnitCount: layout.poolUnitCount
        )
        let stage2 = applyVariantStage(
            units: stage1,
            charCount: layout.hkVarCount,
            charOffset: layout.hkVarOffset
        )
        return String(utf16CodeUnits: stage2, count: stage2.count)
    }

    // MARK: - Pipeline Stages

    private func applyPhraseAndCharStage(
        units: [UInt16],
        bitmapOffset: Int,
        indexCount: Int,
        indexOffset: Int,
        phraseCount: Int,
        phraseOffset: Int,
        charCount: Int,
        charOffset: Int,
        poolOffset: Int,
        poolUnitCount: Int
    ) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(units.count + (units.count >> 3))

        var pos = 0
        let total = units.count
        while pos < total {
            let u0 = units[pos]
            if indexCount > 0,
               (rawBuffer[bitmapOffset + Int(u0 >> 3)] & (1 << (u0 & 7))) != 0,
               let match = matchLongestPhrase(
                   units: units,
                   pos: pos,
                   indexCount: indexCount,
                   indexOffset: indexOffset,
                   phraseCount: phraseCount,
                   phraseOffset: phraseOffset,
                   poolOffset: poolOffset,
                   poolUnitCount: poolUnitCount
               ) {
                let valOff = Int(match.valPacked >> 8)
                let valLen = Int(match.valPacked & 0xFF)
                if match.valPacked == 0 || valLen == 0 || valOff < 0 || valOff > poolUnitCount - valLen {
                    // Overlap guard entry (or invalid value range): preserve phrase boundary, emit per-scalar STCharacters.
                    appendCharConvertedSlice(
                        units: units,
                        start: pos,
                        length: match.matchedLen,
                        charCount: charCount,
                        charOffset: charOffset,
                        into: &out
                    )
                } else {
                    let byteBase = poolOffset + valOff * 2
                    for i in 0..<valLen {
                        out.append(loadU16(byteBase + i * 2))
                    }
                }
                pos += match.matchedLen
                continue
            }

            let step = appendOneScalarConverted(
                units: units,
                pos: pos,
                charCount: charCount,
                charOffset: charOffset,
                into: &out
            )
            pos += step
        }
        return out
    }

    private func applyVariantStage(
        units: [UInt16],
        charCount: Int,
        charOffset: Int
    ) -> [UInt16] {
        guard charCount > 0 else { return units }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var pos = 0
        let total = units.count
        while pos < total {
            pos += appendOneScalarConverted(
                units: units,
                pos: pos,
                charCount: charCount,
                charOffset: charOffset,
                into: &out
            )
        }
        return out
    }

    // MARK: - Greedy Binary-Search Lookup

    private func matchLongestPhrase(
        units: [UInt16],
        pos: Int,
        indexCount: Int,
        indexOffset: Int,
        phraseCount: Int,
        phraseOffset: Int,
        poolOffset: Int,
        poolUnitCount: Int
    ) -> (matchedLen: Int, valPacked: UInt32)? {
        let u0 = units[pos]
        guard let idxPos = binarySearchFirstUnit(u0, count: indexCount, offset: indexOffset) else {
            return nil
        }

        let entryBase = indexOffset + idxPos * 8
        let lenMask = loadU16(entryBase + 2)
        let groupStart = Int(loadU32(entryBase + 4))
        let groupEnd = Int(loadU32(entryBase + 12))
        guard groupStart >= 0, groupStart < groupEnd, groupEnd <= phraseCount else { return nil }

        let maxLen = min(16, units.count - pos)
        var length = maxLen
        while length >= 1 {
            if (lenMask & (UInt16(1) &<< (length - 1))) != 0 {
                if let valPacked = binarySearchPhraseSlice(
                    units: units,
                    pos: pos,
                    length: length,
                    groupStart: groupStart,
                    groupEnd: groupEnd,
                    phraseOffset: phraseOffset,
                    poolOffset: poolOffset,
                    poolUnitCount: poolUnitCount
                ) {
                    return (length, valPacked)
                }
            }
            length -= 1
        }
        return nil
    }

    private func binarySearchFirstUnit(_ target: UInt16, count: Int, offset: Int) -> Int? {
        var lo = 0
        var hi = count - 1
        while lo <= hi {
            let mid = lo + ((hi - lo) >> 1)
            let midUnit = loadU16(offset + mid * 8)
            if midUnit == target {
                return mid
            } else if midUnit < target {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return nil
    }

    private func binarySearchPhraseSlice(
        units: [UInt16],
        pos: Int,
        length: Int,
        groupStart: Int,
        groupEnd: Int,
        phraseOffset: Int,
        poolOffset: Int,
        poolUnitCount: Int
    ) -> UInt32? {
        var lo = groupStart
        var hi = groupEnd - 1
        while lo <= hi {
            let mid = lo + ((hi - lo) >> 1)
            let recBase = phraseOffset + mid * 8
            let keyPacked = loadU32(recBase)
            let keyOff = Int(keyPacked >> 8)
            let keyLen = Int(keyPacked & 0xFF)
            guard keyOff >= 0, keyLen > 0, keyOff <= poolUnitCount - keyLen else {
                return nil
            }
            let cmp = compareSlice(
                units: units,
                pos: pos,
                length: length,
                poolByteBase: poolOffset + keyOff * 2,
                keyLen: keyLen
            )
            if cmp == 0 {
                return loadU32(recBase + 4)
            } else if cmp < 0 {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return nil
    }

    @inline(__always)
    private func compareSlice(
        units: [UInt16],
        pos: Int,
        length: Int,
        poolByteBase: Int,
        keyLen: Int
    ) -> Int {
        let minLen = min(length, keyLen)
        for i in 0..<minLen {
            let a = units[pos + i]
            let b = loadU16(poolByteBase + i * 2)
            if a != b {
                return a < b ? -1 : 1
            }
        }
        if length == keyLen { return 0 }
        return length < keyLen ? -1 : 1
    }

    private func appendCharConvertedSlice(
        units: [UInt16],
        start: Int,
        length: Int,
        charCount: Int,
        charOffset: Int,
        into out: inout [UInt16]
    ) {
        var offset = 0
        while offset < length {
            offset += appendOneScalarConverted(
                units: units,
                pos: start + offset,
                charCount: charCount,
                charOffset: charOffset,
                into: &out
            )
        }
    }

    @inline(__always)
    private func appendOneScalarConverted(
        units: [UInt16],
        pos: Int,
        charCount: Int,
        charOffset: Int,
        into out: inout [UInt16]
    ) -> Int {
        let u0 = units[pos]
        let scalar: UInt32
        let consumed: Int
        if UTF16.isLeadSurrogate(u0),
           pos + 1 < units.count,
           UTF16.isTrailSurrogate(units[pos + 1]) {
            let lead = UInt32(u0) - 0xD800
            let trail = UInt32(units[pos + 1]) - 0xDC00
            scalar = 0x10000 + (lead << 10) + trail
            consumed = 2
        } else {
            scalar = UInt32(u0)
            consumed = 1
        }

        if charCount > 0, let mapped = lookupScalar(scalar, count: charCount, offset: charOffset) {
            appendScalar(mapped, into: &out)
        } else if consumed == 1 {
            out.append(u0)
        } else {
            out.append(u0)
            out.append(units[pos + 1])
        }
        return consumed
    }

    private func lookupScalar(_ target: UInt32, count: Int, offset: Int) -> UInt32? {
        var lo = 0
        var hi = count - 1
        while lo <= hi {
            let mid = lo + ((hi - lo) >> 1)
            let recBase = offset + mid * 8
            let k = loadU32(recBase)
            if k == target {
                return loadU32(recBase + 4)
            } else if k < target {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return nil
    }

    @inline(__always)
    private func appendScalar(_ scalar: UInt32, into out: inout [UInt16]) {
        if scalar <= 0xFFFF {
            out.append(UInt16(truncatingIfNeeded: scalar))
        } else {
            let adj = scalar - 0x10000
            out.append(UInt16(truncatingIfNeeded: 0xD800 + (adj >> 10)))
            out.append(UInt16(truncatingIfNeeded: 0xDC00 + (adj & 0x3FF)))
        }
    }

    // MARK: - Raw Little-Endian Memory Helpers

    @inline(__always)
    private func loadU16(_ byteOffset: Int) -> UInt16 {
        guard byteOffset >= 0, byteOffset + 2 <= rawBuffer.count else { return 0 }
        return UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
    }

    @inline(__always)
    private func loadU32(_ byteOffset: Int) -> UInt32 {
        guard byteOffset >= 0, byteOffset + 4 <= rawBuffer.count else { return 0 }
        return UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self))
    }

    @inline(__always)
    private static func loadU32(_ raw: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt32 {
        guard byteOffset >= 0, byteOffset + 4 <= raw.count else { return 0 }
        return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self))
    }

    @inline(__always)
    private static func isPureASCII(_ text: String) -> Bool {
        !text.utf8.contains(where: { $0 >= 0x80 })
    }

    // MARK: - Zero-Copy Loading & Validation

    private static func locateDefaultDictionary() -> URL? {
        let bundles: [Bundle] = [Bundle.main, Bundle(for: OpenCCConverter.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "lokey_opencc", withExtension: "bin") {
                return url
            }
        }
        let fm = FileManager.default
        var candidateURLs: [URL] = []
        candidateURLs.reserveCapacity(8)
        if let plugInsURL = Bundle.main.builtInPlugInsURL {
            candidateURLs.append(
                plugInsURL
                    .appendingPathComponent("LokeyKeyboard.appex")
                    .appendingPathComponent("lokey_opencc.bin")
            )
        }
        for bundle in bundles {
            if let resURL = bundle.resourceURL {
                candidateURLs.append(resURL.appendingPathComponent("lokey_opencc.bin"))
                candidateURLs.append(resURL.appendingPathComponent("Resources/lokey_opencc.bin"))
            }
            candidateURLs.append(bundle.bundleURL.appendingPathComponent("lokey_opencc.bin"))
            candidateURLs.append(
                bundle.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("lokey_opencc.bin")
            )
            if bundle !== Bundle.main, let plugInsURL = bundle.builtInPlugInsURL {
                candidateURLs.append(
                    plugInsURL
                        .appendingPathComponent("LokeyKeyboard.appex")
                        .appendingPathComponent("lokey_opencc.bin")
                )
            }
        }
        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Shared/Resources/lokey_opencc.bin")
        candidateURLs.append(cwdURL)
        let sourceRelativeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/lokey_opencc.bin")
        candidateURLs.append(sourceRelativeURL)

        for url in candidateURLs where fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func loadTable(
        from url: URL
    ) -> (data: NSData, buffer: UnsafeRawBufferPointer, layout: TableLayout)? {
        guard let nsData = try? NSData(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        let raw = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
        guard raw.count >= 80 else { return nil }
        guard loadU32(raw, at: 0) == loccMagic,
              loadU32(raw, at: 4) == supportedVersion else {
            return nil
        }

        let layout = TableLayout(
            stCharCount: Int(loadU32(raw, at: 8)),
            stCharOffset: Int(loadU32(raw, at: 12)),
            twVarCount: Int(loadU32(raw, at: 16)),
            twVarOffset: Int(loadU32(raw, at: 20)),
            hkVarCount: Int(loadU32(raw, at: 24)),
            hkVarOffset: Int(loadU32(raw, at: 28)),
            stBitmapOffset: Int(loadU32(raw, at: 32)),
            stIndexCount: Int(loadU32(raw, at: 36)),
            stIndexOffset: Int(loadU32(raw, at: 40)),
            stPhraseCount: Int(loadU32(raw, at: 44)),
            stPhraseOffset: Int(loadU32(raw, at: 48)),
            twBitmapOffset: Int(loadU32(raw, at: 52)),
            twIndexCount: Int(loadU32(raw, at: 56)),
            twIndexOffset: Int(loadU32(raw, at: 60)),
            twPhraseCount: Int(loadU32(raw, at: 64)),
            twPhraseOffset: Int(loadU32(raw, at: 68)),
            poolUnitCount: Int(loadU32(raw, at: 72)),
            poolOffset: Int(loadU32(raw, at: 76))
        )

        func inBounds(_ offset: Int, count: Int, stride: Int) -> Bool {
            guard offset >= 80, offset <= raw.count, count >= 0, stride > 0 else { return false }
            return count <= (raw.count - offset) / stride
        }

        guard layout.stIndexCount >= 0, layout.stIndexCount < Int.max,
              layout.twIndexCount >= 0, layout.twIndexCount < Int.max,
              inBounds(layout.stCharOffset, count: layout.stCharCount, stride: 8),
              inBounds(layout.twVarOffset, count: layout.twVarCount, stride: 8),
              inBounds(layout.hkVarOffset, count: layout.hkVarCount, stride: 8),
              inBounds(layout.stBitmapOffset, count: 8192, stride: 1),
              inBounds(layout.stIndexOffset, count: layout.stIndexCount + 1, stride: 8),
              inBounds(layout.stPhraseOffset, count: layout.stPhraseCount, stride: 8),
              inBounds(layout.twBitmapOffset, count: 8192, stride: 1),
              inBounds(layout.twIndexOffset, count: layout.twIndexCount + 1, stride: 8),
              inBounds(layout.twPhraseOffset, count: layout.twPhraseCount, stride: 8),
              inBounds(layout.poolOffset, count: layout.poolUnitCount, stride: 2) else {
            return nil
        }

        return (nsData, raw, layout)
    }
}
