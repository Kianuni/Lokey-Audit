import Foundation

/// Pure-offline parser, pre-import deduplicator, and weight calibrator for personal Rime
/// dictionaries (`*.userdb.txt`, `*.dict.yaml`, and plain-text custom phrase tables).
/// Runs strictly inside the host app (`Lokey`) and unit tests so the keyboard extension stays untouched.
public enum RimeUserLexiconImporter {
    public static let maxFileBytes = 16 * 1024 * 1024

    public enum SourceFormat: String, Sendable, Equatable, CaseIterable {
        case rimeUserDB
        case rimeDictYAML
        case plainText

        public var title: String {
            switch self {
            case .rimeUserDB:
                return "Rime 同步个人词库 (.userdb.txt)"
            case .rimeDictYAML:
                return "Rime 词典 (.dict.yaml)"
            case .plainText:
                return "文本词表 (.txt / .tsv)"
            }
        }
    }

    public enum WeightPreset: String, Sendable, Equatable, CaseIterable, Identifiable {
        case balanced
        case gentle
        case priority

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .balanced:
                return "均衡折算（推荐）"
            case .gentle:
                return "温和备选"
            case .priority:
                return "高频优先"
            }
        }
    }

    public enum ImportError: LocalizedError, Equatable {
        case emptyFile
        case fileTooLarge(maxMB: Int)
        case unreadableText
        case builtInLexiconUnavailable
        case binaryLevelDBFolderSelected
        case directoryNotSupported
        case iCloudDownloadIncomplete

        public var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "所选文件为空。"
            case let .fileTooLarge(maxMB):
                return "文件体积超过 \(maxMB) MB 上限，个人词库导入仅支持中小型私人词表。"
            case .unreadableText:
                return "无法按 UTF-8 / UTF-16 / GB18030 解码该文件内容。"
            case .builtInLexiconUnavailable:
                return "未能定位内置基础词典，暂时无法执行内置去重。"
            case .binaryLevelDBFolderSelected:
                return "所选的是 Rime 运行期二进制数据库文件夹（.userdb），而非明文词库文件。请在 Rime 中执行一次「同步用户资料」，再选择 sync 目录下的 .userdb.txt 文件。"
            case .directoryNotSupported:
                return "不支持直接导入文件夹，请选择 .userdb.txt、.dict.yaml 或 .txt 词库文件。"
            case .iCloudDownloadIncomplete:
                return "该 iCloud 云盘文件尚未下载到本机，已触发系统下载，请稍候片刻再试或先在「文件」App 中点击云朵图标下载。"
            }
        }
    }

    public struct CandidateItem: Sendable, Equatable, Identifiable {
        public let id: String
        public let originalSurface: String
        public let canonicalSurface: String
        public let syllables: [String]
        public var spacedPinyin: String { syllables.joined(separator: " ") }
        public var compactPinyin: String { syllables.joined() }
        public var jianpin: String { String(syllables.compactMap(\.first)) }
        public let rawWeight: Double
        public let hasExplicitWeight: Bool
        public let rawDee: Double?
        public let existingUseCount: Int?
        public var isExistingInUserStore: Bool { existingUseCount != nil }
        public let topBuiltInHomophone: String?
        public let topBuiltInHomophoneScoreQ8: Int?
        public let flaggedExclusionReason: String?
        public let gentleUseCount: Int
        public let balancedUseCount: Int
        public let priorityUseCount: Int
        public var isSelected: Bool

        public func calibratedUseCount(for preset: WeightPreset) -> Int {
            switch preset {
            case .balanced:
                return balancedUseCount
            case .gentle:
                return gentleUseCount
            case .priority:
                return priorityUseCount
            }
        }
    }

    public struct AnalysisResult: Sendable, Equatable, Identifiable {
        public let id = UUID()
        public let fileName: String
        public let format: SourceFormat
        public let totalRawLines: Int
        public let parsedCandidateCount: Int
        public let duplicateInFileCount: Int
        public let duplicateInBuiltInCount: Int
        public let duplicateInUserStoreCount: Int
        public let skippedTombstoneCount: Int
        public let skippedSingleCharCount: Int
        public let skippedInvalidCount: Int
        public let flaggedClauseOrHomophoneCount: Int
        public var items: [CandidateItem]
    }

    private struct RawParsedRow {
        let originalSurface: String
        let canonicalSurface: String
        let syllables: [String]
        let weight: Double
        let hasExplicitWeight: Bool
        let rawDee: Double?
    }

    private enum LineParseOutcome {
        case parsed(RawParsedRow)
        case tombstone
        case singleChar
        case invalid
        case ignoreLine
    }

    private struct YAMLColumnMapping {
        var textIndex: Int = 0
        var codeIndex: Int = 1
        var weightIndex: Int? = 2
    }

    /// Locates and opens the bundled read-only `lokey_lexicon.bin` from host app PlugIns or test bundles.
    public static func locateBuiltInLexicon() -> MmapLexicon? {
        let fm = FileManager.default
        var urls: [URL] = []
        if let mainURL = Bundle.main.url(forResource: "lokey_lexicon", withExtension: "bin") {
            urls.append(mainURL)
        }
        if let appexURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("LokeyKeyboard.appex/lokey_lexicon.bin") {
            urls.append(appexURL)
        }
        let clsBundle = Bundle(for: MmapLexicon.self)
        if let clsURL = clsBundle.url(forResource: "lokey_lexicon", withExtension: "bin") {
            urls.append(clsURL)
        }
        for b in Bundle.allBundles {
            if let bURL = b.url(forResource: "lokey_lexicon", withExtension: "bin") {
                urls.append(bURL)
            }
        }
        let devFallback = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Shared/Resources/lokey_lexicon.bin")
        urls.append(devFallback)

        for url in urls where fm.fileExists(atPath: url.path) {
            if let lex = try? MmapLexicon(contentsOf: url) {
                return lex
            }
        }
        return nil
    }

    /// Reads file bytes safely from security-scoped, `-Inbox` copy (`UIDocumentPickerViewController(..., asCopy: true)`),
    /// or `Documents/Inbox` Share/Open-In URLs, validating against binary `.userdb` folders, size caps, and iCloud placeholders,
    /// then cleaning up transient Inbox copies upon completion or failure.
    public static func loadImportableData(from url: URL) throws -> (data: Data, fileName: String) {
        let fileName = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            cleanupInboxTemporaryFileIfNeeded(url)
        }

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
        let existsAtPath = fm.fileExists(atPath: url.path, isDirectory: &isDirObjC)
        let isDirectoryOrPackage = (values?.isDirectory == true)
            || (values?.isPackage == true)
            || (existsAtPath && isDirObjC.boolValue)
        if isDirectoryOrPackage {
            let hasCurrent = fm.fileExists(atPath: url.appendingPathComponent("CURRENT").path)
            if url.pathExtension.lowercased() == "userdb" || hasCurrent {
                throw ImportError.binaryLevelDBFolderSelected
            }
            throw ImportError.directoryNotSupported
        }

        if let fileSize = values?.fileSize, fileSize > maxFileBytes {
            throw ImportError.fileTooLarge(maxMB: maxFileBytes / (1024 * 1024))
        }
        if let attrSize = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           attrSize.intValue > maxFileBytes {
            throw ImportError.fileTooLarge(maxMB: maxFileBytes / (1024 * 1024))
        }

        let isUbiquitous = values?.isUbiquitousItem ?? false
        if isUbiquitous && values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }

        let data = try readFileBytes(from: url, isUbiquitous: isUbiquitous)
        guard data.count <= maxFileBytes else {
            throw ImportError.fileTooLarge(maxMB: maxFileBytes / (1024 * 1024))
        }
        return (data, fileName)
    }

    private static func readFileBytes(from url: URL, isUbiquitous: Bool) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let directError {
            var coordinatedData: Data? = nil
            var innerError: Error? = nil
            var coordError: NSError? = nil
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { coordinatedURL in
                do {
                    if let attrSize = (try? FileManager.default.attributesOfItem(atPath: coordinatedURL.path))?[.size] as? NSNumber,
                       attrSize.intValue > maxFileBytes {
                        throw ImportError.fileTooLarge(maxMB: maxFileBytes / (1024 * 1024))
                    }
                    coordinatedData = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
                } catch {
                    innerError = error
                }
            }
            if let data = coordinatedData {
                return data
            }
            if let importErr = innerError as? ImportError {
                throw importErr
            }
            if isUbiquitous {
                throw ImportError.iCloudDownloadIncomplete
            }
            throw innerError ?? coordError ?? directError
        }
    }

    private static func cleanupInboxTemporaryFileIfNeeded(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path.contains("-Inbox/") || path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Parses raw Rime lexicon file bytes, normalizes full Pinyin readings, runs 4-stage dedup/screening,
    /// and computes safe calibrated `useCount` values across all three weight presets.
    public static func analyze(
        data: Data,
        fileName: String = "custom.dict.yaml",
        builtInLexicon: MmapLexicon? = nil,
        existingUserPhrases: [String: Int] = [:]
    ) throws -> AnalysisResult {
        guard !data.isEmpty else {
            throw ImportError.emptyFile
        }
        guard data.count <= maxFileBytes else {
            throw ImportError.fileTooLarge(maxMB: maxFileBytes / (1024 * 1024))
        }
        guard let text = decodeText(data) else {
            throw ImportError.unreadableText
        }
        guard let lexicon = builtInLexicon ?? locateBuiltInLexicon() else {
            throw ImportError.builtInLexiconUnavailable
        }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allLines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        let format = detectFormat(fileName: fileName, lines: allLines)

        let scan = scanLines(allLines, format: format, lexicon: lexicon)
        let (dedupedRows, duplicateInFileCount) = deduplicateIntraFile(scan.rows)

        var duplicateInBuiltInCount = 0
        var duplicateInUserStoreCount = 0
        var flaggedClauseOrHomophoneCount = 0

        struct StagedCandidate {
            let row: RawParsedRow
            let existingUseCount: Int?
            let topHomophone: String?
            let topHomophoneScoreQ8: Int?
            let flaggedReason: String?
        }

        var staged: [StagedCandidate] = []
        staged.reserveCapacity(dedupedRows.count)

        for row in dedupedRows {
            let trieMatch = lookupBuiltInTrie(
                syllables: row.syllables,
                canonicalSurface: row.canonicalSurface,
                in: lexicon
            )
            if trieMatch.containsExactSurface {
                duplicateInBuiltInCount += 1
                continue
            }

            let key = "\(row.canonicalSurface)|\(row.syllables.joined())"
            let existingCount = existingUserPhrases[key]
            if existingCount != nil {
                duplicateInUserStoreCount += 1
            }

            let flaggedReason = screenCandidateReason(
                surface: row.canonicalSurface,
                format: format,
                rawWeight: row.weight,
                hasExplicitWeight: row.hasExplicitWeight,
                topHomophone: trieMatch.topHomophone,
                topHomophoneScoreQ8: trieMatch.topScoreQ8
            )
            if flaggedReason != nil && existingCount == nil {
                flaggedClauseOrHomophoneCount += 1
            }

            staged.append(
                StagedCandidate(
                    row: row,
                    existingUseCount: existingCount,
                    topHomophone: trieMatch.topHomophone,
                    topHomophoneScoreQ8: trieMatch.topScoreQ8,
                    flaggedReason: flaggedReason
                )
            )
        }

        let calibratedBalanced = calibrateBalancedUseCounts(
            rows: staged.map(\.row),
            format: format
        )

        var items: [CandidateItem] = []
        items.reserveCapacity(staged.count)
        for (idx, st) in staged.enumerated() {
            let balanced = calibratedBalanced[idx]
            let gentle = max(1, min(2, (balanced + 1) / 2))
            let priority = min(6, max(4, balanced + 2))
            let isDefaultSelected = (st.existingUseCount == nil && st.flaggedReason == nil)
            let row = st.row
            let key = "\(row.canonicalSurface)|\(row.syllables.joined())"
            items.append(
                CandidateItem(
                    id: key,
                    originalSurface: row.originalSurface,
                    canonicalSurface: row.canonicalSurface,
                    syllables: row.syllables,
                    rawWeight: row.weight,
                    hasExplicitWeight: row.hasExplicitWeight,
                    rawDee: row.rawDee,
                    existingUseCount: st.existingUseCount,
                    topBuiltInHomophone: st.topHomophone,
                    topBuiltInHomophoneScoreQ8: st.topHomophoneScoreQ8,
                    flaggedExclusionReason: st.flaggedReason,
                    gentleUseCount: gentle,
                    balancedUseCount: balanced,
                    priorityUseCount: priority,
                    isSelected: isDefaultSelected
                )
            )
        }

        return AnalysisResult(
            fileName: fileName,
            format: format,
            totalRawLines: allLines.count,
            parsedCandidateCount: scan.rows.count,
            duplicateInFileCount: duplicateInFileCount,
            duplicateInBuiltInCount: duplicateInBuiltInCount,
            duplicateInUserStoreCount: duplicateInUserStoreCount,
            skippedTombstoneCount: scan.tombstones,
            skippedSingleCharCount: scan.singleChars,
            skippedInvalidCount: scan.invalids,
            flaggedClauseOrHomophoneCount: flaggedClauseOrHomophoneCount,
            items: items
        )
    }

    /// Converts selected preview items into `UserLexiconStore.ImportedPhraseSeed` records for persistence.
    public static func buildImportSeeds(
        from items: [CandidateItem],
        preset: WeightPreset,
        includeExisting: Bool
    ) -> [UserLexiconStore.ImportedPhraseSeed] {
        var out: [UserLexiconStore.ImportedPhraseSeed] = []
        out.reserveCapacity(items.count)
        for item in items where item.isSelected {
            if item.isExistingInUserStore && !includeExisting {
                continue
            }
            out.append(
                UserLexiconStore.ImportedPhraseSeed(
                    surface: item.canonicalSurface,
                    syllables: item.syllables,
                    useCount: item.calibratedUseCount(for: preset)
                )
            )
        }
        return out
    }

    // MARK: - Text Decoding & Format Detection

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let trimmed = data.dropFirst(3)
            if let str = String(data: trimmed, encoding: .utf8) {
                return str
            }
        } else if let str = String(data: data, encoding: .utf8) {
            return str
        }

        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let str = String(data: data, encoding: .utf16) {
                return str
            }
        }

        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let str = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return str
        }
        return nil
    }

    private static func detectFormat(fileName: String, lines: [Substring]) -> SourceFormat {
        let lowerName = fileName.lowercased()
        var hasUserDBMeta = false
        var hasYAMLHeaderMarker = false
        var sampleLinesChecked = 0
        var userDBRowHits = 0

        for rawLine in lines.prefix(120) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#@/db_type") && trimmed.contains("userdb") {
                hasUserDBMeta = true
                break
            }
            if trimmed == "---" || trimmed == "..." || trimmed.hasPrefix("columns:") || trimmed.hasPrefix("sort:") {
                hasYAMLHeaderMarker = true
            }
            if trimmed.hasPrefix("#") { continue }
            if rawLine.contains("\t") {
                sampleLinesChecked += 1
                let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
                if cols.count >= 3 && parseUserDBMetadata(cols[2]) != nil {
                    userDBRowHits += 1
                }
                if sampleLinesChecked >= 12 { break }
            }
        }

        if hasUserDBMeta || userDBRowHits >= 2 || lowerName.hasSuffix(".userdb.txt") {
            return .rimeUserDB
        }
        if hasYAMLHeaderMarker || lowerName.hasSuffix(".dict.yaml") || lowerName.hasSuffix(".yaml") {
            return .rimeDictYAML
        }
        return .plainText
    }

    // MARK: - Line Scanning

    private struct LineScanSummary {
        var rows: [RawParsedRow] = []
        var tombstones: Int = 0
        var singleChars: Int = 0
        var invalids: Int = 0
    }

    private static func scanLines(
        _ lines: [Substring],
        format: SourceFormat,
        lexicon: MmapLexicon
    ) -> LineScanSummary {
        var summary = LineScanSummary()
        switch format {
        case .rimeUserDB:
            for line in lines {
                recordOutcome(parseUserDBLine(line, lexicon: lexicon), into: &summary)
            }
        case .rimeDictYAML:
            let (bodyStartIndex, colMap) = parseYAMLHeader(in: lines)
            for idx in bodyStartIndex..<lines.count {
                recordOutcome(parseYAMLDictLine(lines[idx], columns: colMap, lexicon: lexicon), into: &summary)
            }
        case .plainText:
            for line in lines {
                recordOutcome(parsePlainTextLine(line, lexicon: lexicon), into: &summary)
            }
        }
        return summary
    }

    private static func recordOutcome(_ outcome: LineParseOutcome, into summary: inout LineScanSummary) {
        switch outcome {
        case let .parsed(row):
            summary.rows.append(row)
        case .tombstone:
            summary.tombstones += 1
        case .singleChar:
            summary.singleChars += 1
        case .invalid:
            summary.invalids += 1
        case .ignoreLine:
            break
        }
    }

    private static func parseYAMLHeader(in lines: [Substring]) -> (bodyStartIndex: Int, columns: YAMLColumnMapping) {
        var columns = YAMLColumnMapping()
        var endMarkerIdx: Int? = nil
        var startMarkerSeen = false
        var insideColumnsList = false
        var parsedColumnNames: [String] = []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                startMarkerSeen = true
                insideColumnsList = false
                continue
            }
            if trimmed == "..." {
                endMarkerIdx = idx + 1
                break
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if idx == 0 && !startMarkerSeen && line.contains("\t") {
                // Headerless YAML snippet: body begins immediately.
                return (0, columns)
            }

            if trimmed.hasPrefix("columns:") {
                let rest = trimmed.dropFirst("columns:".count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") && rest.hasSuffix("]") {
                    let inner = rest.dropFirst().dropLast()
                    parsedColumnNames = inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                    insideColumnsList = false
                } else {
                    insideColumnsList = true
                    parsedColumnNames.removeAll()
                }
                continue
            }

            if insideColumnsList {
                if trimmed.hasPrefix("-") {
                    let colName = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !colName.isEmpty {
                        parsedColumnNames.append(colName)
                    }
                    continue
                } else if trimmed.contains(":") {
                    insideColumnsList = false
                }
            }
        }

        if !parsedColumnNames.isEmpty {
            if let tIdx = parsedColumnNames.firstIndex(of: "text") {
                columns.textIndex = tIdx
            }
            if let cIdx = parsedColumnNames.firstIndex(of: "code") {
                columns.codeIndex = cIdx
            }
            columns.weightIndex = parsedColumnNames.firstIndex(of: "weight")
        }

        if let endMarkerIdx {
            return (endMarkerIdx, columns)
        }
        return (0, columns)
    }

    private static func parseUserDBLine(_ rawLine: Substring, lexicon: MmapLexicon) -> LineParseOutcome {
        let line = stripTrailingCR(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return .ignoreLine
        }
        // Rime internal metadata rows start with control/delete markers (e.g. `\x02` / `\x7fenc`).
        if let firstScalar = line.unicodeScalars.first, firstScalar.value < 0x20 || firstScalar.value == 0x7F {
            return .ignoreLine
        }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 2 else {
            return .invalid
        }
        let rawCode = String(cols[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSurface = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawSurface.hasPrefix("~") || rawCode.hasPrefix("\u{7F}") {
            return .ignoreLine
        }
        let meta = cols.count >= 3 ? parseUserDBMetadata(cols[2]) : nil
        if let meta, meta.commits <= 0 {
            return .tombstone
        }
        let commits = Double(max(1, meta?.commits ?? 1))
        return normalizeCandidateRow(
            rawSurface: rawSurface,
            rawCode: rawCode,
            weight: commits,
            hasExplicitWeight: meta != nil,
            rawDee: meta?.dee,
            lexicon: lexicon
        )
    }

    private static func parseUserDBMetadata(_ rawMeta: Substring) -> (commits: Int, dee: Double?)? {
        var foundCommits: Int? = nil
        var foundDee: Double? = nil
        for token in rawMeta.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("c="), let c = Int(token.dropFirst(2)) {
                foundCommits = c
            } else if token.hasPrefix("d="), let d = Double(token.dropFirst(2)) {
                foundDee = d
            }
        }
        guard let commits = foundCommits else { return nil }
        return (commits, foundDee)
    }

    private static func parseYAMLDictLine(
        _ rawLine: Substring,
        columns: YAMLColumnMapping,
        lexicon: MmapLexicon
    ) -> LineParseOutcome {
        let stripped = stripCommentIfLeadingOrSpaced(rawLine)
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "---" || trimmed == "..." {
            return .ignoreLine
        }
        if !stripped.contains("\t") {
            // YAML metadata (`key: value` / `- item`) left over before body.
            if trimmed.contains(":") || trimmed.hasPrefix("-") {
                return .ignoreLine
            }
            return .invalid
        }
        let cols = stripped.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.textIndex < cols.count, columns.codeIndex < cols.count else {
            return .invalid
        }
        let rawSurface = String(cols[columns.textIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCode = String(cols[columns.codeIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        var parsedWeight: Double = 0
        var hasWeight = false
        if let wIdx = columns.weightIndex, wIdx < cols.count {
            let wToken = String(cols[wIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            if !wToken.isEmpty {
                if let w = Double(wToken) {
                    if w < 0 { return .tombstone }
                    parsedWeight = w
                    hasWeight = true
                }
            }
        }

        return normalizeCandidateRow(
            rawSurface: rawSurface,
            rawCode: rawCode,
            weight: parsedWeight,
            hasExplicitWeight: hasWeight,
            rawDee: nil,
            lexicon: lexicon
        )
    }

    private static func parsePlainTextLine(_ rawLine: Substring, lexicon: MmapLexicon) -> LineParseOutcome {
        let stripped = stripCommentIfLeadingOrSpaced(rawLine)
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .ignoreLine
        }

        if stripped.contains("\t") {
            let cols = stripped.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 2 else { return .invalid }
            let col0 = String(cols[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let col1 = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let (rawSurface, rawCode): (String, String)
            if isPureCJK(col0) {
                rawSurface = col0
                rawCode = col1
            } else if isPureCJK(col1) {
                rawSurface = col1
                rawCode = col0
            } else {
                return .invalid
            }
            var parsedWeight: Double = 0
            var hasWeight = false
            if cols.count >= 3 {
                let wStr = String(cols[2])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "%", with: "")
                if let w = Double(wStr) {
                    if w < 0 { return .tombstone }
                    parsedWeight = w
                    hasWeight = true
                }
            }
            return normalizeCandidateRow(
                rawSurface: rawSurface,
                rawCode: rawCode,
                weight: parsedWeight,
                hasExplicitWeight: hasWeight,
                rawDee: nil,
                lexicon: lexicon
            )
        }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else {
            return .invalid
        }
        if isPureCJK(tokens[0]) {
            var codeTokens = Array(tokens.dropFirst())
            var parsedWeight: Double = 0
            var hasWeight = false
            if codeTokens.count >= 2, let lastW = Double(codeTokens.last!.replacingOccurrences(of: "%", with: "")) {
                if lastW < 0 { return .tombstone }
                parsedWeight = lastW
                hasWeight = true
                codeTokens.removeLast()
            }
            return normalizeCandidateRow(
                rawSurface: tokens[0],
                rawCode: codeTokens.joined(separator: " "),
                weight: parsedWeight,
                hasExplicitWeight: hasWeight,
                rawDee: nil,
                lexicon: lexicon
            )
        } else if isPureCJK(tokens.last!) {
            let codeTokens = Array(tokens.dropLast())
            return normalizeCandidateRow(
                rawSurface: tokens.last!,
                rawCode: codeTokens.joined(separator: " "),
                weight: 0,
                hasExplicitWeight: false,
                rawDee: nil,
                lexicon: lexicon
            )
        }
        return .invalid
    }

    // MARK: - Surface & Full-Pinyin Normalization

    private static func stripTrailingCR(_ s: Substring) -> String {
        s.hasSuffix("\r") ? String(s.dropLast()) : String(s)
    }

    private static func stripCommentIfLeadingOrSpaced(_ rawLine: Substring) -> String {
        let s = stripTrailingCR(rawLine)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return "" }
        if let range = s.range(of: " #") {
            return String(s[..<range.lowerBound])
        }
        if let range = s.range(of: "\t#") {
            return String(s[..<range.lowerBound])
        }
        return s
    }

    private static func isPureCJK(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { ViterbiDecoder.isCJKIdeograph($0) }
    }

    private static func canonicalizeToSimplified(_ surface: String) -> String {
        let transformed = (surface as NSString).applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? surface
        return transformed.count == surface.count ? transformed : surface
    }

    private static func normalizeCandidateRow(
        rawSurface: String,
        rawCode: String,
        weight: Double,
        hasExplicitWeight: Bool,
        rawDee: Double?,
        lexicon: MmapLexicon
    ) -> LineParseOutcome {
        let cleanOrig = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return .invalid }
        guard cleanOrig.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else {
            return .invalid
        }
        if cleanOrig.count == 1 {
            return .singleChar
        }
        guard cleanOrig.count >= 2 && cleanOrig.count <= 12 else {
            return .invalid
        }

        let canonicalSurface = canonicalizeToSimplified(cleanOrig)
        guard canonicalSurface.count == cleanOrig.count,
              canonicalSurface.allSatisfy({ ViterbiDecoder.isCJKIdeograph($0) }) else {
            return .invalid
        }

        guard let syllables = normalizeAndResolveSyllables(
            rawCode: rawCode,
            targetCharCount: canonicalSurface.count,
            in: lexicon
        ) else {
            return .invalid
        }

        return .parsed(
            RawParsedRow(
                originalSurface: cleanOrig,
                canonicalSurface: canonicalSurface,
                syllables: syllables,
                weight: weight,
                hasExplicitWeight: hasExplicitWeight,
                rawDee: rawDee
            )
        )
    }

    private static let toneCharMap: [Character: Character] = [
        "ā": "a", "á": "a", "ǎ": "a", "à": "a",
        "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
        "ē": "e", "é": "e", "ě": "e", "è": "e", "ê": "e",
        "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
        "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
        "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
        "ń": "n", "ň": "n", "ǹ": "n",
        "ḿ": "m",
    ]

    private static func normalizeASCIIPinyinText(_ rawCode: String) -> String {
        let precomposed = rawCode.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "u:", with: "v")
        var out = ""
        out.reserveCapacity(precomposed.count)
        for ch in precomposed {
            if let mapped = toneCharMap[ch] {
                out.append(mapped)
            } else if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first,
                      (0x0300...0x036F).contains(s.value) {
                continue
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func canonicalizeSingleSyllable(_ token: Substring, in lexicon: MmapLexicon) -> String? {
        var s = String(token)
        if let last = s.last, last >= "1" && last <= "5" {
            s.removeLast()
        }
        guard !s.isEmpty, s.count <= 7 else { return nil }
        for b in s.utf8 {
            guard b >= 0x61 && b <= 0x7A else { return nil }
        }
        if s == "lue" { s = "lve" }
        if s == "nue" { s = "nve" }
        guard lexicon.syllableToID[s] != nil else { return nil }
        return s
    }

    private static func normalizeAndResolveSyllables(
        rawCode: String,
        targetCharCount: Int,
        in lexicon: MmapLexicon
    ) -> [String]? {
        let normalized = normalizeASCIIPinyinText(rawCode)
        let tokens = normalized.split { ch in
            ch.isWhitespace || ch == "'" || ch == "’"
        }
        guard !tokens.isEmpty else { return nil }

        if tokens.count == targetCharCount {
            var resolved: [String] = []
            resolved.reserveCapacity(targetCharCount)
            for tok in tokens {
                guard let syl = canonicalizeSingleSyllable(tok, in: lexicon) else {
                    return nil
                }
                resolved.append(syl)
            }
            return resolved
        }

        // Handle unspaced compact Pinyin strings (e.g. `lanzhoulongyuan` for 4 characters).
        if tokens.count == 1 {
            var compact = String(tokens[0])
            if let last = compact.last, last >= "1" && last <= "5" {
                compact.removeLast()
            }
            return segmentCompactPinyin(compact, targetCount: targetCharCount, in: lexicon)
        }

        return nil
    }

    private static func segmentCompactPinyin(
        _ compact: String,
        targetCount k: Int,
        in lexicon: MmapLexicon
    ) -> [String]? {
        let chars = Array(compact.utf8)
        let m = chars.count
        guard k >= 2, m >= k, m <= k * 7 else { return nil }
        for b in chars {
            guard b >= 0x61 && b <= 0x7A else { return nil }
        }

        struct DPState {
            let score: Int
            let prevPos: Int
            let syl: String
        }

        var dp: [[DPState?]] = Array(repeating: Array(repeating: nil, count: k + 1), count: m + 1)
        dp[0][0] = DPState(score: 0, prevPos: -1, syl: "")

        for pos in 0..<m {
            for cnt in 0..<k {
                guard let cur = dp[pos][cnt] else { continue }
                let maxLen = min(7, m - pos)
                for len in 1...maxLen {
                    let end = pos + len
                    let slice = String(decoding: chars[pos..<end], as: UTF8.self)
                    let canon: String
                    if slice == "lue" {
                        canon = "lve"
                    } else if slice == "nue" {
                        canon = "nve"
                    } else {
                        canon = slice
                    }
                    guard lexicon.syllableToID[canon] != nil else { continue }
                    // Favor full syllables with consonant onsets cleanly when breaking ties (e.g. `chang+an` vs `chan+gan`).
                    let stepScore = len * len * 4 + (len >= 2 ? 12 : 0)
                    let nextScore = cur.score + stepScore
                    if let existing = dp[end][cnt + 1], existing.score >= nextScore {
                        continue
                    }
                    dp[end][cnt + 1] = DPState(score: nextScore, prevPos: pos, syl: canon)
                }
            }
        }

        guard dp[m][k] != nil else { return nil }
        var out: [String] = []
        out.reserveCapacity(k)
        var pos = m
        var cnt = k
        while cnt > 0 {
            guard let step = dp[pos][cnt] else { return nil }
            out.append(step.syl)
            pos = step.prevPos
            cnt -= 1
        }
        return out.reversed()
    }

    // MARK: - Dedup, Screening & Weight Calibration

    private static func deduplicateIntraFile(_ rows: [RawParsedRow]) -> (deduped: [RawParsedRow], duplicateCount: Int) {
        var bestByKey: [String: RawParsedRow] = [:]
        var keyOrder: [String] = []
        bestByKey.reserveCapacity(rows.count)
        keyOrder.reserveCapacity(rows.count)
        var duplicates = 0

        for row in rows {
            let key = "\(row.canonicalSurface)|\(row.syllables.joined())"
            if let existing = bestByKey[key] {
                duplicates += 1
                let replaceWeight = row.hasExplicitWeight && (!existing.hasExplicitWeight || row.weight > existing.weight)
                let mergedWeight = max(existing.weight, row.weight)
                let mergedHasWeight = existing.hasExplicitWeight || row.hasExplicitWeight
                let mergedDee = replaceWeight ? row.rawDee : (existing.rawDee ?? row.rawDee)
                bestByKey[key] = RawParsedRow(
                    originalSurface: existing.originalSurface,
                    canonicalSurface: existing.canonicalSurface,
                    syllables: existing.syllables,
                    weight: mergedWeight,
                    hasExplicitWeight: mergedHasWeight,
                    rawDee: mergedDee
                )
            } else {
                bestByKey[key] = row
                keyOrder.append(key)
            }
        }

        let ordered = keyOrder.compactMap { bestByKey[$0] }
        return (ordered, duplicates)
    }

    private static func lookupBuiltInTrie(
        syllables: [String],
        canonicalSurface: String,
        in lexicon: MmapLexicon
    ) -> (containsExactSurface: Bool, topHomophone: String?, topScoreQ8: Int?) {
        var node = lexicon.rootNodeIndex
        for syl in syllables {
            guard let sid = lexicon.syllableToID[syl],
                  let next = lexicon.step(from: node, syllableID: sid) else {
                return (false, nil, nil)
            }
            node = next
        }
        let hits = lexicon.words(at: node, limit: 256)
        let exact = hits.contains(where: { $0.text == canonicalSurface })
        let top = hits.first
        return (exact, top?.text, top?.scoreQ8)
    }

    private static func screenCandidateReason(
        surface: String,
        format: SourceFormat,
        rawWeight: Double,
        hasExplicitWeight: Bool,
        topHomophone: String?,
        topHomophoneScoreQ8: Int?
    ) -> String? {
        if format == .rimeUserDB {
            if surface.count >= 6 {
                return "超长历史句（\(surface.count)字）"
            }
            if UserLexiconStore.hasConversationalClauseMarkers(surface) {
                return "疑似口语多词短句"
            }
            if surface.count == 2,
               (!hasExplicitWeight || rawWeight <= 2.0),
               let topText = topHomophone,
               let topScore = topHomophoneScoreQ8,
               topScore >= -2350 {
                return "低频二字同音（内置常用词：\(topText)）"
            }
            return nil
        }

        if surface.count > 8 {
            return "超长词条（\(surface.count)字）"
        }
        if UserLexiconStore.hasConversationalClauseMarkers(surface) {
            return "疑似口语短句"
        }
        return nil
    }

    private static func calibrateBalancedUseCounts(
        rows: [RawParsedRow],
        format: SourceFormat
    ) -> [Int] {
        guard !rows.isEmpty else { return [] }
        if format == .rimeUserDB {
            return rows.map { row in
                let commits = Int(max(1, row.weight.rounded()))
                var base: Int
                switch commits {
                case ...1:
                    base = 1
                case 2...3:
                    base = 2
                case 4...7:
                    base = 3
                case 8...19:
                    base = 4
                case 20...49:
                    base = 5
                default:
                    base = 6
                }
                if let dee = row.rawDee, dee < 0.05 {
                    base = max(1, base - 1)
                }
                return base
            }
        }

        let positiveLogWeights = rows.compactMap { row -> Double? in
            guard row.hasExplicitWeight && row.weight > 0 else { return nil }
            return log10(row.weight + 1.0)
        }.sorted()

        guard !positiveLogWeights.isEmpty else {
            return Array(repeating: 3, count: rows.count)
        }

        let p10 = percentile(sortedValues: positiveLogWeights, p: 0.10)
        let p90 = percentile(sortedValues: positiveLogWeights, p: 0.90)
        let spread = p90 - p10

        return rows.map { row in
            guard row.hasExplicitWeight else { return 2 }
            guard row.weight > 0 else { return 2 }
            guard spread >= 1e-6 else { return 3 }
            let lw = log10(row.weight + 1.0)
            let q = min(1.0, max(0.0, (lw - p10) / spread))
            return min(6, max(1, 1 + Int((q * 5.0).rounded())))
        }
    }

    private static func percentile(sortedValues: [Double], p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        if sortedValues.count == 1 { return sortedValues[0] }
        let idx = min(Double(sortedValues.count - 1), max(0.0, p * Double(sortedValues.count - 1)))
        let lo = Int(floor(idx))
        let hi = Int(ceil(idx))
        if lo == hi { return sortedValues[lo] }
        let frac = idx - Double(lo)
        return sortedValues[lo] + (sortedValues[hi] - sortedValues[lo]) * frac
    }
}
