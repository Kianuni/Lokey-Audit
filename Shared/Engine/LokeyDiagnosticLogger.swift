import CoreGraphics
import Darwin
import Foundation

/// Structured diagnostic entry recording a single touch, hit-test, scroll, decode, or commit step.
public struct LokeyDiagnosticEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let touchSeq: UInt64
    public let wallTime: String
    public let deltaMs: Double
    public let category: String
    public let summary: String

    public init(
        id: UInt64,
        touchSeq: UInt64,
        wallTime: String,
        deltaMs: Double,
        category: String,
        summary: String
    ) {
        self.id = id
        self.touchSeq = touchSeq
        self.wallTime = wallTime
        self.deltaMs = deltaMs
        self.category = category
        self.summary = summary
    }
}

/// Cumulative diagnostic counters answering "how many times did I tap the screen and how did Lokey process each tap".
public struct LokeyDiagnosticCounters: Codable, Sendable, Equatable {
    public var screenTouchDownCount: Int = 0
    public var letterTapCount: Int = 0
    public var backspaceTapCount: Int = 0
    public var spaceReturnSymbolCount: Int = 0
    public var borderRemapCount: Int = 0
    public var seamPassThroughCount: Int = 0
    public var multiTouchOverlapCount: Int = 0
    public var candidateTapCount: Int = 0
    public var candidateScrollPanCount: Int = 0
    // Older persisted reports omit the grid counter.
    public var gridScrollPanCount: Int?
    public var missedOrCancelledCount: Int = 0
    public var pinyinAppendCount: Int? // Absent in reports from before Build 50.

    public init() {}
}

/// Bounded persistent diagnostic snapshot shared exclusively via the local `App Group` container (zero network).
public struct LokeyDiagnosticSnapshot: Codable, Sendable, Equatable {
    public var clearEpoch: UInt64 = 1
    public var nextEntryID: UInt64 = 1
    public var nextTouchSeq: UInt64 = 1
    public var counters: LokeyDiagnosticCounters = LokeyDiagnosticCounters()
    public var entries: [LokeyDiagnosticEntry] = []

    public init() {}
}

/// Zero-allocation hit-target token recorded on `.main` during `touchesBegan` and rendered lazily on snapshot export.
public enum TouchHitTargetToken: Sendable {
    case nilArea
    case keyGrid
    case candidateButton(Int, String)
    case candidateExpandChevron
    case candidateScrollContainer
    case candidateBar
    case expandedGridButton(String)
    case expandedGrid
    case emojiPanel
    case custom(String)

    fileprivate var renderedText: String {
        switch self {
        case .nilArea:
            return "空区域(nil)"
        case .keyGrid:
            return "26键区(KeyGridView)"
        case let .candidateButton(tag, title):
            return "候选按钮#\(tag)(\"\(title)\")"
        case .candidateExpandChevron:
            return "候选栏展开键(⌄)"
        case .candidateScrollContainer:
            return "候选栏滑动容器(CandidateScrollView)"
        case .candidateBar:
            return "候选顶栏(CandidateBarView)"
        case let .expandedGridButton(title):
            return "展开面板按钮(\"\(title)\")"
        case .expandedGrid:
            return "展开候选面板(ExpandedGrid)"
        case .emojiPanel:
            return "Emoji面板"
        case let .custom(name):
            return name
        }
    }
}

/// Zero-allocation key role & action token recorded on `.main` during `KeyGridView.touchesBegan`.
public enum KeyHitRoleToken: Sendable {
    case asciiLetter(UInt8, Bool)
    case staticLabel(StaticString)
    case symbol(String)
    case pageSwitch(String)
    case momentarySlideSymbol(String)
    case text(String)

    fileprivate var renderedText: String {
        switch self {
        case let .asciiLetter(ascii, isUpper):
            let ch = Character(UnicodeScalar(ascii))
            return isUpper ? "大写字母'\(ch)'" : "字母'\(ch)'"
        case let .staticLabel(s):
            return String(describing: s)
        case let .symbol(sym):
            return "符号\"\(sym)\""
        case let .pageSwitch(title):
            return "切页键(\(title))"
        case let .momentarySlideSymbol(sym):
            return "123滑动选符\"\(sym)\""
        case let .text(s):
            return s
        }
    }
}

/// Zero-allocation key action token recorded on `.main` during `KeyGridView` touch handling.
public enum KeyHitActionToken: Sendable {
    case staticText(StaticString)
    case backspaceSwipeClear(Int)

    fileprivate var renderedText: String {
        switch self {
        case let .staticText(s):
            return String(describing: s)
        case let .backspaceSwipeClear(px):
            return "左滑\(px)pt即刻清空全部已打输入"
        }
    }
}

/// Zero-allocation missed/cancelled touch reason token recorded on `.main`.
public enum MissedTouchReasonToken: Sendable {
    case staticReason(StaticString)
    case draggedOffSpace(Int)
    case draggedOffKey(Int, KeyHitRoleToken)
    case systemCancelledUncommitted(KeyHitRoleToken)

    fileprivate var renderedText: String {
        switch self {
        case let .staticReason(s):
            return String(describing: s)
        case let .draggedOffSpace(y):
            return "手指上滑移出键盘(y=\(y)pt) -> 取消空格直通"
        case let .draggedOffKey(y, role):
            return "手指上滑移出键盘(y=\(y)pt) -> 取消 \(role.renderedText)"
        case let .systemCancelledUncommitted(role):
            return "系统取消未提交触控(\(role.renderedText))"
        }
    }
}

/// Zero-allocation letter disposition token recorded on `.main`.
public enum LetterDispositionToken: Sendable {
    case engineNotLoadedDirect(Character, Bool)

    fileprivate var renderedText: String {
        switch self {
        case let .engineNotLoadedDirect(ch, isShifted):
            let s = isShifted ? String(ch.uppercased()) : String(ch)
            return "未入串，引擎未载入，直接输入 \(s)"
        }
    }
}

/// Zero-allocation commit source & remaining-preedit tokens recorded on `.main`.
public enum CommitSourceToken: Sendable {
    case staticSource(StaticString)
    case association(Int)

    fileprivate var renderedText: String {
        switch self {
        case let .staticSource(s):
            return String(describing: s)
        case let .association(index):
            return "联想候选#\(index)"
        }
    }
}

public enum CommitRemainingToken: Sendable {
    case empty
    case clearedPreedit(String)
    case text(String)

    fileprivate var renderedText: String {
        switch self {
        case .empty:
            return ""
        case let .clearedPreedit(preedit):
            return preedit.isEmpty ? "(已清空待上屏拼音)" : "已清空:\(preedit)"
        case let .text(value):
            return value
        }
    }
}

/// Zero-allocation candidate-bar / expanded-grid event token recorded on `.main`.
public enum CandidateBarEventToken: Sendable {
    case staticText(StaticString)
    case pressedCandidate(Int, String)
    case selectedCandidate(Int, String)
    case autoFlushedCandidate(Int, String)
    case microRollRescue(Int, String, CGFloat)
    case transferredToScroll(Int, String)
    case nearestCandidate(StaticString, Int, String)
    case scrollStart(horizontal: Bool, origin: CGFloat, content: CGFloat, viewport: CGFloat, count: Int)
    case scrollProgress(horizontal: Bool, phase: StaticString, offset: CGFloat, delta: CGFloat, elapsedMs: Double, updates: Int, maxGapMs: Double)
    case expandedPanelState(open: Bool, reason: String, inWindow: Bool)
    case expandedPressed(Int)
    case expandedReleaseInvalidated(Int)
    case expandedCancelled(Int)
    case expandedTouchUpOutside(Int)
    case expandedLongPressDelete(Int)
    case expandedSelected(Int, StaticString)
    case expandedOpenEnded(String)
    case expandedLayoutCompleted(elapsedMs: Double, width: CGFloat, height: CGFloat, candidateCount: Int, visibleCount: Int)
    case expandedFirstDisplayRefresh(elapsedMs: Double, inWindow: Bool, isHidden: Bool, visibleCount: Int)

    fileprivate var renderedText: String {
        switch self {
        case let .staticText(s):
            return String(describing: s)
        case let .pressedCandidate(idx, title):
            return "按下候选#\(idx)(\"\(title)\") 待抬手或横滑"
        case let .selectedCandidate(idx, title):
            return "点击选中候选#\(idx)(\"\(title)\")"
        case let .autoFlushedCandidate(idx, title):
            return "双指连击自动冲刷按下中的候选#\(idx)(\"\(title)\")"
        case let .microRollRescue(idx, title, deltaX):
            return String(format: "微滑防吞救回选中候选#%d(\"%@\") (Δx=%.1fpt)", idx, title, deltaX)
        case let .transferredToScroll(idx, title):
            return "候选#\(idx)(\"\(title)\")按钮追踪已转交滑动判定"
        case let .nearestCandidate(prefix, idx, title):
            return "\(prefix)#\(idx)(\"\(title)\")"
        case let .scrollStart(horizontal, origin, content, viewport, count):
            let axis = horizontal ? "横向滑动" : "展开面板纵滑"
            return String(format: "%@开始 offset=%.1f 内容=%.1f 视口=%.1f 候选=%d", axis, origin, content, viewport, count)
        case let .scrollProgress(horizontal, phase, offset, delta, elapsedMs, updates, maxGapMs):
            let axis = horizontal ? "横向滑动" : "展开面板纵滑"
            return String(format: "%@%@ offset=%.1f 位移=%.1f 耗时=%.1fms 更新=%d 最大滚动回调间隔=%.1fms",
                          axis, String(describing: phase), offset, delta, elapsedMs, updates, maxGapMs)
        case let .expandedPanelState(open, reason, inWindow):
            return "展开面板状态=\(open ? "展开" : "收起") 原因=\(reason) 在窗口=\(inWindow)"
        case let .expandedPressed(idx):
            return "展开面板按下 #\(idx)"
        case let .expandedReleaseInvalidated(idx):
            return "展开面板抬手忽略 原因=按下项已失效 #\(idx)"
        case let .expandedCancelled(idx):
            return "展开面板按钮取消 #\(idx)"
        case let .expandedTouchUpOutside(idx):
            return "展开面板移出抬手 #\(idx)"
        case let .expandedLongPressDelete(idx):
            return "展开面板长按删除 #\(idx)"
        case let .expandedSelected(idx, source):
            return "展开面板选中 #\(idx) 方式=\(source)"
        case let .expandedOpenEnded(reason):
            return "展开面板首个刷新回调前结束 原因=\(reason)"
        case let .expandedLayoutCompleted(elapsedMs, width, height, candidateCount, visibleCount):
            return String(format: "展开面板布局完成 耗时=%.2fms 尺寸=%.1fx%.1f 候选=%d 可见按钮=%d",
                          elapsedMs, width, height, candidateCount, visibleCount)
        case let .expandedFirstDisplayRefresh(elapsedMs, inWindow, isHidden, visibleCount):
            return String(format: "展开面板首次屏幕刷新回调 耗时=%.2fms 在窗口=%d 面板隐藏=%d 可见按钮=%d",
                          elapsedMs, inWindow ? 1 : 0, isHidden ? 1 : 0, visibleCount)
        }
    }
}

/// Inline stack-packed ASCII byte buffer (`<= 64` bytes) avoiding `.main` `[Character]`/`String` allocations on decode logs.
public struct InlineASCII64: Sendable {
    private var w0: UInt64 = 0
    private var w1: UInt64 = 0
    private var w2: UInt64 = 0
    private var w3: UInt64 = 0
    private var w4: UInt64 = 0
    private var w5: UInt64 = 0
    private var w6: UInt64 = 0
    private var w7: UInt64 = 0
    private var byteCount: UInt8 = 0
    private var overflowString: String?

    public init(samples: [TouchSample]) {
        let count = samples.count
        if count == 0 {
            return
        }
        if count <= 64 {
            var idx = 0
            var allASCII = true
            var bytes = (
                w0: UInt64(0), w1: UInt64(0), w2: UInt64(0), w3: UInt64(0),
                w4: UInt64(0), w5: UInt64(0), w6: UInt64(0), w7: UInt64(0)
            )
            withUnsafeMutableBytes(of: &bytes) { raw in
                for sample in samples {
                    guard let ascii = sample.primaryChar.asciiValue else {
                        allASCII = false
                        break
                    }
                    raw[idx] = ascii
                    idx += 1
                }
            }
            if allASCII {
                w0 = bytes.w0; w1 = bytes.w1; w2 = bytes.w2; w3 = bytes.w3
                w4 = bytes.w4; w5 = bytes.w5; w6 = bytes.w6; w7 = bytes.w7
                byteCount = UInt8(count)
                return
            }
        }
        var s = String()
        s.reserveCapacity(count)
        for sample in samples {
            s.append(sample.primaryChar)
        }
        overflowString = s
    }

    public var stringValue: String {
        if let overflowString {
            return overflowString
        }
        let n = Int(byteCount)
        if n == 0 { return "" }
        var bytes = (w0, w1, w2, w3, w4, w5, w6, w7)
        return withUnsafeBytes(of: &bytes) { raw in
            String(decoding: raw.prefix(n), as: UTF8.self)
        }
    }
}

/// Stack-allocated top-4 candidate summary avoiding `.prefix(4).map(\.text)` array allocations on `.main`.
public struct DiagnosticTop4Candidates: Sendable {
    private let c0: String?
    private let c1: String?
    private let c2: String?
    private let c3: String?

    public init(candidates: [LokeyCandidate]) {
        let n = candidates.count
        c0 = n > 0 ? candidates[0].text : nil
        c1 = n > 1 ? candidates[1].text : nil
        c2 = n > 2 ? candidates[2].text : nil
        c3 = n > 3 ? candidates[3].text : nil
    }

    fileprivate var joinedSummary: String {
        switch (c0, c1, c2, c3) {
        case let (a?, b?, c?, d?): return "\(a) | \(b) | \(c) | \(d)"
        case let (a?, b?, c?, nil): return "\(a) | \(b) | \(c)"
        case let (a?, b?, nil, nil): return "\(a) | \(b)"
        case let (a?, nil, nil, nil): return a
        default: return ""
        }
    }
}

/// Quantized layout geometry snapshot (`0.1pt` resolution) avoiding `String(format:)` checks on `.main`.
public struct GeometrySignature: Equatable, Sendable {
    public let viewW10: Int32
    public let viewH10: Int32
    public let barH10: Int32
    public let gridH10: Int32
    public let pad10: Int32

    public init(viewSize: CGSize, barHeight: CGFloat, gridHeight: CGFloat, hostTopPadding: CGFloat) {
        self.viewW10 = Int32((viewSize.width * 10.0).rounded())
        self.viewH10 = Int32((viewSize.height * 10.0).rounded())
        self.barH10 = Int32((barHeight * 10.0).rounded())
        self.gridH10 = Int32((gridHeight * 10.0).rounded())
        self.pad10 = Int32((hostTopPadding * 10.0).rounded())
    }
}

/// Store value snapshots on the input path. Render localized text only for disk or display.
private enum DiagnosticDetail {
    case text(String)
    case staticText(StaticString)
    case down(CGPoint, Int, String, Bool, Double?)
    case downFast(CGPoint, Int, TouchHitTargetToken, Bool, Double?)
    case key(String, Int, Int, CGPoint, String?, String)
    case keyFast(KeyHitRoleToken, Int, Int, CGPoint, String?, KeyHitActionToken)
    case missed(CGPoint, String)
    case missedStatic(CGPoint, StaticString)
    case missedFast(CGPoint, MissedTouchReasonToken)
    case letterDisposition(LetterDispositionToken)
    case decode(String, String, [String], Double)
    case decodeFast(InlineASCII64, String, DiagnosticTop4Candidates, Double)
    case commit(String, String, String)
    case commitFast(CommitSourceToken, String, CommitRemainingToken)
    case candidateBarFast(CandidateBarEventToken)
    case layoutGeometryFast(GeometrySignature, CGFloat, CGFloat)
    case preeditDelay(Double, Double)
    case stall(String, Double)
    case stallFast(StaticString, Int, StaticString?, Double)

    var text: String {
        switch self {
        case let .text(value): return value
        case let .staticText(value): return String(describing: value)
        case let .down(point, fingers, target, seam, lag):
            let fingerTag = fingers >= 2 ? "\(fingers)指重叠" : "单指"
            let lagTag = lag.flatMap { $0.isFinite ? String(format: " 派发延迟=%.1fms", max(0, $0)) : nil } ?? ""
            let seamTag = seam ? " [候选栏底沿防吞直通]" : ""
            return String(format: "按下 pt=(%.1f, %.1f) %@%@ -> 命中 %@%@",
                          point.x, point.y, fingerTag, lagTag, target, seamTag)
        case let .downFast(point, fingers, target, seam, lag):
            let fingerTag = fingers >= 2 ? "\(fingers)指重叠" : "单指"
            let lagTag = lag.flatMap { $0.isFinite ? String(format: " 派发延迟=%.1fms", max(0, $0)) : nil } ?? ""
            let seamTag = seam ? " [候选栏底沿防吞直通]" : ""
            return String(format: "按下 pt=(%.1f, %.1f) %@%@ -> 命中 %@%@",
                          point.x, point.y, fingerTag, lagTag, target.renderedText, seamTag)
        case let .key(role, row, col, point, remap, action):
            let tag = remap.map { " [边缘防误触: \($0)->\(role)]" } ?? ""
            return String(format: "识别为 %@ (第%d排第%d列, grid=%.1f,%.1f)%@ -> %@",
                          role, row + 1, col + 1, point.x, point.y, tag, action)
        case let .keyFast(roleTok, row, col, point, remap, actionTok):
            let role = roleTok.renderedText
            let tag = remap.map { " [边缘防误触: \($0)->\(role)]" } ?? ""
            return String(format: "识别为 %@ (第%d排第%d列, grid=%.1f,%.1f)%@ -> %@",
                          role, row + 1, col + 1, point.x, point.y, tag, actionTok.renderedText)
        case let .missed(point, reason):
            return String(format: "pt=(%.1f, %.1f) -> %@", point.x, point.y, reason)
        case let .missedStatic(point, reason):
            return String(format: "pt=(%.1f, %.1f) -> %@", point.x, point.y, String(describing: reason))
        case let .missedFast(point, reason):
            return String(format: "pt=(%.1f, %.1f) -> %@", point.x, point.y, reason.renderedText)
        case let .letterDisposition(tok):
            return tok.renderedText
        case let .decode(raw, preedit, candidates, ms):
            return String(format: "键串=\"%@\"(%d键) -> 分词=\"%@\" | 候选=[%@] (%.2fms)",
                          raw, raw.count, preedit, candidates.prefix(4).joined(separator: " | "), ms)
        case let .decodeFast(inlineRaw, preedit, top4, ms):
            let raw = inlineRaw.stringValue
            return String(format: "键串=\"%@\"(%d键) -> 分词=\"%@\" | 候选=[%@] (%.2fms)",
                          raw, raw.count, preedit, top4.joinedSummary, ms)
        case let .commit(source, committedText, remainingPreedit):
            let remNote = remainingPreedit.isEmpty ? "拼写结束" : "剩余未上屏=\"\(remainingPreedit)\""
            let preview = committedText.prefix(128)
            let suffix = preview.endIndex < committedText.endIndex ? "…" : ""
            return "\(source) -> 上屏 \"\(preview)\(suffix)\" (\(remNote))"
        case let .commitFast(sourceTok, committedText, remainingTok):
            let remainingPreedit = remainingTok.renderedText
            let remNote = remainingPreedit.isEmpty ? "拼写结束" : "剩余未上屏=\"\(remainingPreedit)\""
            let preview = committedText.prefix(128)
            let suffix = preview.endIndex < committedText.endIndex ? "…" : ""
            return "\(sourceTok.renderedText) -> 上屏 \"\(preview)\(suffix)\" (\(remNote))"
        case let .candidateBarFast(event):
            return event.renderedText
        case let .layoutGeometryFast(sig, screenMinY, screenMaxY):
            return String(
                format: "view=(%.1fx%.1f) barH=%.1f gridH=%.1f hostTopPad=%.1f screenY=(%.1f..%.1f)",
                Double(sig.viewW10) / 10.0,
                Double(sig.viewH10) / 10.0,
                Double(sig.barH10) / 10.0,
                Double(sig.gridH10) / 10.0,
                Double(sig.pad10) / 10.0,
                screenMinY,
                screenMaxY
            )
        case let .preeditDelay(waitMs, proxyMs):
            return String(format: "拼音回显请求到宿主代理返回 %.2fms（等待 %.2fms，代理调用 %.2fms）",
                          waitMs + proxyMs, waitMs, proxyMs)
        case let .stall(phase, elapsedMs):
            return String(format: "%@ 同步耗时 %.2fms", phase, elapsedMs)
        case let .stallFast(phase, touchCount, tag, elapsedMs):
            let resolvedPhase: String
            if touchCount > 0 {
                let suffix = tag.map { "·\(String(describing: $0))" } ?? ""
                resolvedPhase = "touchesBegan(\(touchCount)指)\(suffix)"
            } else {
                resolvedPhase = String(describing: phase)
            }
            return String(format: "%@ 同步耗时 %.2fms", resolvedPhase, elapsedMs)
        }
    }
}

private enum BufferedDiagnosticEntry {
    case restored(LokeyDiagnosticEntry)
    case event(UInt64, UInt64, Int64, Double, String, DiagnosticDetail)

    var entryID: UInt64 {
        switch self {
        case let .restored(entry): return entry.id
        case let .event(id, _, _, _, _, _): return id
        }
    }

    var rendered: LokeyDiagnosticEntry {
        var lastSec = time_t.min
        var lastTM = tm()
        return rendered(lastSec: &lastSec, lastTM: &lastTM)
    }

    func rendered(lastSec: inout time_t, lastTM: inout tm) -> LokeyDiagnosticEntry {
        switch self {
        case let .restored(entry): return entry
        case let .event(id, seq, wallMicros, deltaMs, category, detail):
            var sec = time_t(wallMicros / 1_000_000)
            var usec = Int32(wallMicros % 1_000_000)
            if usec < 0 {
                sec -= 1
                usec += 1_000_000
            }
            if sec != lastSec {
                var s = sec
                localtime_r(&s, &lastTM)
                lastSec = sec
            }
            let h = Int(lastTM.tm_hour)
            let m = Int(lastTM.tm_min)
            let s = Int(lastTM.tm_sec)
            let ms = Int(usec / 1000)
            var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                UInt8(48 + (h / 10) % 10), UInt8(48 + h % 10), 58,
                UInt8(48 + (m / 10) % 10), UInt8(48 + m % 10), 58,
                UInt8(48 + (s / 10) % 10), UInt8(48 + s % 10), 46,
                UInt8(48 + (ms / 100) % 10), UInt8(48 + (ms / 10) % 10), UInt8(48 + ms % 10)
            )
            let wall = withUnsafeBytes(of: &buf) { String(decoding: $0, as: UTF8.self) }
            return LokeyDiagnosticEntry(id: id, touchSeq: seq, wallTime: wall, deltaMs: deltaMs,
                                        category: category, summary: detail.text)
        }
    }
}

/// Flat 1D ring buffer of buffered entries. All reads and writes to `storage` happen strictly
/// under `lockPtr`, extracting independent flat arrays (`O(delta)` on `ioQueue` flushes) so
/// `orderedEntries()` / rendering never shares CoW array buffers across lock boundaries.
private struct DiagnosticEntryRing {
    private var storage: [BufferedDiagnosticEntry] = []
    private var next = 0
    private(set) var count = 0

    var firstEntryID: UInt64? {
        guard count > 0 else { return nil }
        let startIndex = count == LokeyDiagnosticLogger.maxEntries ? next : 0
        return storage[startIndex].entryID
    }

    mutating func append(_ entry: BufferedDiagnosticEntry) {
        if count < LokeyDiagnosticLogger.maxEntries {
            if storage.isEmpty {
                storage.reserveCapacity(64)
            }
            storage.append(entry)
            count += 1
            next = count % LokeyDiagnosticLogger.maxEntries
        } else {
            storage[next] = entry
            next = (next + 1) % LokeyDiagnosticLogger.maxEntries
        }
    }

    func copyOrderedRawEntries() -> [BufferedDiagnosticEntry] {
        guard count > 0 else { return [] }
        var copy = [BufferedDiagnosticEntry]()
        copy.reserveCapacity(count)
        if count < LokeyDiagnosticLogger.maxEntries {
            copy.append(contentsOf: storage)
        } else {
            copy.append(contentsOf: storage[next..<LokeyDiagnosticLogger.maxEntries])
            if next > 0 {
                copy.append(contentsOf: storage[0..<next])
            }
        }
        return copy
    }

    func copyNewerRawEntries(after lastID: UInt64) -> [BufferedDiagnosticEntry] {
        guard count > 0 else { return [] }
        var copy = [BufferedDiagnosticEntry]()
        if count < LokeyDiagnosticLogger.maxEntries {
            Self.appendNewerRaw(from: storage[0..<count], after: lastID, into: &copy)
        } else {
            Self.appendNewerRaw(from: storage[next..<LokeyDiagnosticLogger.maxEntries], after: lastID, into: &copy)
            if next > 0 {
                Self.appendNewerRaw(from: storage[0..<next], after: lastID, into: &copy)
            }
        }
        return copy
    }

    static func renderEntries(_ rawEntries: [BufferedDiagnosticEntry]) -> [LokeyDiagnosticEntry] {
        guard !rawEntries.isEmpty else { return [] }
        var result = [LokeyDiagnosticEntry]()
        result.reserveCapacity(rawEntries.count)
        var lastSec = time_t.min
        var lastTM = tm()
        for entry in rawEntries {
            result.append(entry.rendered(lastSec: &lastSec, lastTM: &lastTM))
        }
        return result
    }

    func orderedEntries() -> [LokeyDiagnosticEntry] {
        Self.renderEntries(copyOrderedRawEntries())
    }

    private static func appendNewerRaw(
        from slice: ArraySlice<BufferedDiagnosticEntry>,
        after lastID: UInt64,
        into copy: inout [BufferedDiagnosticEntry]
    ) {
        guard let last = slice.last, last.entryID > lastID else { return }
        var lo = slice.startIndex
        if let first = slice.first, first.entryID <= lastID {
            var hi = slice.endIndex
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if slice[mid].entryID <= lastID {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
        }
        copy.append(contentsOf: slice[lo..<slice.endIndex])
    }
}

private final class FastFlagStorage: @unchecked Sendable {
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock_s>
    private var isEnabledValue: Bool
    private var isSecureContextValue: Bool
    private var canRecordValue: Bool

    init(isEnabled: Bool) {
        let ptr = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock_s())
        self.lockPtr = ptr
        self.isEnabledValue = isEnabled
        self.isSecureContextValue = false
        self.canRecordValue = isEnabled
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    @inline(__always)
    func readIsEnabled() -> Bool {
        os_unfair_lock_lock(lockPtr)
        let v = isEnabledValue
        os_unfair_lock_unlock(lockPtr)
        return v
    }

    @inline(__always)
    func readIsSecureContext() -> Bool {
        os_unfair_lock_lock(lockPtr)
        let v = isSecureContextValue
        os_unfair_lock_unlock(lockPtr)
        return v
    }

    @inline(__always)
    func readCanRecord() -> Bool {
        os_unfair_lock_lock(lockPtr)
        let v = canRecordValue
        os_unfair_lock_unlock(lockPtr)
        return v
    }

    @inline(__always)
    func update(isEnabled: Bool, isSecureContext: Bool) {
        os_unfair_lock_lock(lockPtr)
        isEnabledValue = isEnabled
        isSecureContextValue = isSecureContext
        canRecordValue = isEnabled && !isSecureContext
        os_unfair_lock_unlock(lockPtr)
    }
}

/// Bounded local diagnostic trace recorder
/// with automatic secure-field (`isSecureTextEntry`) redaction and coalesced background App Group persistence.
public final class LokeyDiagnosticLogger: @unchecked Sendable {
    public static let shared = LokeyDiagnosticLogger()
    public static let maxEntries = 2048
    private static let defaultsStorageKey = "com.kianuni.lokey.diagnostics.v2"
    private static let fileName = "lokey_touch_diagnostics.json"

    private let lockPtr: UnsafeMutablePointer<os_unfair_lock_s>
    private let flagStorage: FastFlagStorage
    private var snapshot = LokeyDiagnosticSnapshot()
    private var entries = DiagnosticEntryRing()
    // Only startup IDs handed out before the old session was loaded need translation.
    private var earlyTouchLimit: UInt64 = 0
    private var earlyTouchOffset: UInt64 = 0
    private var _isEnabled: Bool = true
    private var _isSecureContext: Bool = false
    /// Calibrated once at init (and refreshed on background flush) so `.main` event recording computes
    /// wall-clock microseconds purely from `ProcessInfo.processInfo.systemUptime` (`mach_absolute_time` commpage, zero syscalls).
    private var clockBaseWallMicros: Int64
    private var lastEventUptime: TimeInterval = 0
    private var scrollingOwners: Set<ObjectIdentifier?> = []
    private var lastScrollActivityUptime: TimeInterval = 0
    private var activeTouchSeq: UInt64 = 0
    private var pendingFlushWorkItem: DispatchWorkItem?
    private var lastSelfPostedEpoch: UInt64 = 0
    private var didBootstrapFromDisk: Bool = false
    private var ringRevision: UInt64 = 0

    // `ioQueue`-exclusive caches for incremental materialization, dirty-skip, and encoder reuse.
    private var cachedMaterializedEpoch: UInt64 = 0
    private var cachedMaterializedRevision: UInt64 = 0
    private var cachedMaterializedEntries: [LokeyDiagnosticEntry] = []
    private var lastFlushedEpoch: UInt64 = 0
    private var lastFlushedNextEntryID: UInt64 = 0
    private let ioEncoder = JSONEncoder()

    private let ioQueue = DispatchQueue(label: "com.kianuni.lokey.diagnosticLoggerIO", qos: .utility)
    private let fileURLOverride: URL?

    private static func computeClockBaseWallMicros() -> Int64 {
        var stamp = timeval()
        gettimeofday(&stamp, nil)
        let uptimeMicros = Int64((ProcessInfo.processInfo.systemUptime * 1_000_000.0).rounded())
        let wallMicros = Int64(stamp.tv_sec) * 1_000_000 &+ Int64(stamp.tv_usec)
        return wallMicros &- uptimeMicros
    }

    public init(fileURLOverride: URL? = nil, initialEnabled: Bool = true) {
        let ptr = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock_s())
        self.lockPtr = ptr
        self.flagStorage = FastFlagStorage(isEnabled: initialEnabled)
        self.fileURLOverride = fileURLOverride
        self._isEnabled = initialEnabled
        self.clockBaseWallMicros = Self.computeClockBaseWallMicros()
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    private var targetFileURL: URL {
        fileURLOverride ?? LokeyAppGroup.sharedDiagnosticLogFileURL()
    }

    private var localExtensionBackupURL: URL {
        LokeyAppGroup.localPrivateSupportDirectoryURL().appendingPathComponent(Self.fileName)
    }

    private var isRunningInExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private static func isNewer(_ a: LokeyDiagnosticSnapshot, than b: LokeyDiagnosticSnapshot) -> Bool {
        if a.clearEpoch != b.clearEpoch {
            return a.clearEpoch > b.clearEpoch
        }
        return a.nextEntryID > b.nextEntryID
    }

    /// Reads the freshest `LokeyDiagnosticSnapshot` across App Group JSON files, App Group `UserDefaults`,
    /// and (inside `.appex`) the local private backup directory.
    private func readBestSnapshotFromStorage() -> (snapshot: LokeyDiagnosticSnapshot, needsSharedPromotion: Bool)? {
        let decoder = JSONDecoder()
        if let override = fileURLOverride {
            guard let data = try? Data(contentsOf: override),
                  let snap = try? decoder.decode(LokeyDiagnosticSnapshot.self, from: data) else {
                return nil
            }
            return (snap, false)
        }

        LokeyAppGroup.invalidateCacheIfUnresolved()
        var bestShared: LokeyDiagnosticSnapshot?
        let containers = LokeyAppGroup.accessibleContainers()
        for item in containers {
            let fURL = item.lokeyDir.appendingPathComponent(Self.fileName)
            var didReadContainerFile = false
            if let data = try? Data(contentsOf: fURL),
               let s = try? decoder.decode(LokeyDiagnosticSnapshot.self, from: data) {
                didReadContainerFile = true
                if let cur = bestShared {
                    if Self.isNewer(s, than: cur) { bestShared = s }
                } else {
                    bestShared = s
                }
            }
            // Only fall back to `UserDefaults(suiteName:)` (`cfprefsd` XPC) if the direct App Group file was missing or unreadable.
            if !didReadContainerFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: Self.defaultsStorageKey),
               let s = try? decoder.decode(LokeyDiagnosticSnapshot.self, from: data) {
                if let cur = bestShared {
                    if Self.isNewer(s, than: cur) { bestShared = s }
                } else {
                    bestShared = s
                }
            }
        }

        if bestShared == nil {
            let fallbackURL = targetFileURL
            if let data = try? Data(contentsOf: fallbackURL),
               let s = try? decoder.decode(LokeyDiagnosticSnapshot.self, from: data) {
                bestShared = s
            }
        }

        if isRunningInExtension,
           let localData = try? Data(contentsOf: localExtensionBackupURL),
           let localSnap = try? decoder.decode(LokeyDiagnosticSnapshot.self, from: localData) {
            if let shared = bestShared {
                if Self.isNewer(localSnap, than: shared) {
                    return (localSnap, !containers.isEmpty)
                }
                return (shared, false)
            }
            return (localSnap, !containers.isEmpty)
        }

        if let shared = bestShared {
            return (shared, false)
        }
        return nil
    }

    public var isEnabled: Bool {
        @inline(__always)
        get {
            flagStorage.readIsEnabled()
        }
        set {
            os_unfair_lock_lock(lockPtr)
            _isEnabled = newValue
            flagStorage.update(isEnabled: newValue, isSecureContext: _isSecureContext)
            os_unfair_lock_unlock(lockPtr)
        }
    }

    public var isSecureContext: Bool {
        @inline(__always)
        get {
            flagStorage.readIsSecureContext()
        }
        set {
            os_unfair_lock_lock(lockPtr)
            _isSecureContext = newValue
            flagStorage.update(isEnabled: _isEnabled, isSecureContext: newValue)
            os_unfair_lock_unlock(lockPtr)
        }
    }

    @inline(__always)
    public var canRecordInteractions: Bool {
        flagStorage.readCanRecord()
    }

    public var currentActiveTouchSeq: UInt64 {
        guard flagStorage.readCanRecord() else { return 0 }
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        return activeTouchSeq
    }

    /// Marks whether a 120Hz candidate-bar / grid scroll or momentum deceleration is actively running,
    /// deferring background JSON serialization, atomic file writes, and cross-process Darwin notifications until scrolling settles.
    public func setScrollInteractionActive(_ active: Bool, owner: AnyObject? = nil) {
        if !active && !flagStorage.readCanRecord() {
            os_unfair_lock_lock(lockPtr)
            if scrollingOwners.isEmpty {
                os_unfair_lock_unlock(lockPtr)
                return
            }
            let id = owner.map(ObjectIdentifier.init)
            _ = scrollingOwners.remove(id)
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(lockPtr)
        let id = owner.map(ObjectIdentifier.init)
        if active {
            scrollingOwners.insert(id)
            lastScrollActivityUptime = now
        } else if scrollingOwners.remove(id) != nil {
            lastScrollActivityUptime = now
        }
        os_unfair_lock_unlock(lockPtr)
    }

    @inline(__always)
    public func noteScrollActivity() {
        guard flagStorage.readCanRecord() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(lockPtr)
        if _isEnabled && !_isSecureContext {
            lastScrollActivityUptime = now
        }
        os_unfair_lock_unlock(lockPtr)
    }

    /// Loads existing App Group diagnostic state once on extension attach so logs persist across host-app switches.
    public func bootstrapFromDiskIfNeeded() {
        os_unfair_lock_lock(lockPtr)
        if didBootstrapFromDisk {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        didBootstrapFromDisk = true
        os_unfair_lock_unlock(lockPtr)
        reloadFromDisk()
    }

    /// Non-blocking background bootstrap for `KeyboardViewController` so cold keyboard attach does zero disk/JSON work on `.main`.
    public func bootstrapFromDiskAsync() {
        os_unfair_lock_lock(lockPtr)
        if didBootstrapFromDisk {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        didBootstrapFromDisk = true
        os_unfair_lock_unlock(lockPtr)
        ioQueue.async { [weak self] in
            self?.mergeBootstrapFromDiskOnQueue()
        }
    }

    private func mergeBootstrapFromDiskOnQueue() {
        guard let loaded = readBestSnapshotFromStorage() else { return }
        let diskSnap = loaded.snapshot
        os_unfair_lock_lock(lockPtr)
        if diskSnap.clearEpoch >= snapshot.clearEpoch, entries.count == 0 && snapshot.counters == LokeyDiagnosticCounters() {
            installSnapshotLocked(diskSnap)
        } else if diskSnap.clearEpoch >= snapshot.clearEpoch && diskSnap.nextEntryID > 1 {
            // Preserve any ultra-early touches recorded before async disk read completed while restoring historical prefix!
            let earlyEntries = entries.orderedEntries()
            earlyTouchLimit = snapshot.nextTouchSeq
            earlyTouchOffset = diskSnap.nextTouchSeq - 1
            let earlyCounters = snapshot.counters
            var merged = diskSnap
            merged.counters.screenTouchDownCount += earlyCounters.screenTouchDownCount
            merged.counters.letterTapCount += earlyCounters.letterTapCount
            merged.counters.backspaceTapCount += earlyCounters.backspaceTapCount
            merged.counters.spaceReturnSymbolCount += earlyCounters.spaceReturnSymbolCount
            merged.counters.multiTouchOverlapCount += earlyCounters.multiTouchOverlapCount
            merged.counters.seamPassThroughCount += earlyCounters.seamPassThroughCount
            merged.counters.borderRemapCount += earlyCounters.borderRemapCount
            merged.counters.candidateTapCount += earlyCounters.candidateTapCount
            merged.counters.candidateScrollPanCount += earlyCounters.candidateScrollPanCount
            merged.counters.gridScrollPanCount = (merged.counters.gridScrollPanCount ?? 0) + (earlyCounters.gridScrollPanCount ?? 0)
            merged.counters.missedOrCancelledCount += earlyCounters.missedOrCancelledCount
            merged.counters.pinyinAppendCount = (merged.counters.pinyinAppendCount ?? 0) + (earlyCounters.pinyinAppendCount ?? 0)
            for var e in earlyEntries {
                let id = merged.nextEntryID
                merged.nextEntryID &+= 1
                let seq = e.touchSeq > 0 ? (diskSnap.nextTouchSeq &+ e.touchSeq &- 1) : 0
                e = LokeyDiagnosticEntry(
                    id: id,
                    touchSeq: seq,
                    wallTime: e.wallTime,
                    deltaMs: e.deltaMs,
                    category: e.category,
                    summary: e.summary
                )
                merged.entries.append(e)
            }
            merged.nextTouchSeq = diskSnap.nextTouchSeq &+ max(0, snapshot.nextTouchSeq &- 1)
            installSnapshotLocked(merged)
        }
        os_unfair_lock_unlock(lockPtr)
    }

    /// Reloads snapshot from disk (used by Host App UI and when an external `clear()` bumps `clearEpoch`).
    @discardableResult
    public func reloadFromDisk() -> LokeyDiagnosticSnapshot {
        guard let loaded = readBestSnapshotFromStorage() else {
            return currentSnapshot()
        }
        let diskSnap = loaded.snapshot
        var shouldPromote = loaded.needsSharedPromotion
        os_unfair_lock_lock(lockPtr)
        if snapshot.clearEpoch > diskSnap.clearEpoch || (Self.isNewer(snapshot, than: diskSnap) && isRunningInExtension) {
            shouldPromote = true
        } else {
            installSnapshotLocked(diskSnap)
        }
        let header = snapshot
        let rawEntries = entries.copyOrderedRawEntries()
        os_unfair_lock_unlock(lockPtr)
        let copy = Self.materialize(header, rawEntries)
        if shouldPromote {
            ioQueue.async { [weak self] in
                self?.writeSnapshotToDisk(copy, notifyIPC: true, forceWrite: true)
            }
        }
        return copy
    }

    /// Non-blocking background disk reload for Host App UI polling (zero main-thread file I/O, JSON decoding, or `cfprefsd` XPC).
    public func reloadFromDiskAsync(completion: @escaping @Sendable (LokeyDiagnosticSnapshot) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.reloadFromDisk()
            completion(loaded)
        }
    }

    /// Non-blocking external clear check dispatched strictly on `ioQueue` (zero main-thread I/O or JSON decoding).
    public func syncExternalClearAsync() {
        ioQueue.async { [weak self] in
            self?.syncExternalClearIfNeeded()
        }
    }

    /// Called on Darwin clear notification so tapping "清空日志" in Host App resets RAM state too.
    public func syncExternalClearIfNeeded() {
        guard let loaded = readBestSnapshotFromStorage() else {
            return
        }
        let diskSnap = loaded.snapshot
        var clearedCopy: LokeyDiagnosticSnapshot?
        os_unfair_lock_lock(lockPtr)
        if diskSnap.clearEpoch > snapshot.clearEpoch {
            let nextSequence = snapshot.nextTouchSeq
            installSnapshotLocked(diskSnap)
            snapshot.nextTouchSeq = max(snapshot.nextTouchSeq, nextSequence)
            earlyTouchLimit = 0
            activeTouchSeq = 0
            lastEventUptime = 0

            clearedCopy = diskSnap
        }
        os_unfair_lock_unlock(lockPtr)
        if let clearedCopy, isRunningInExtension {
            ioQueue.async { [weak self] in
                self?.writeSnapshotToDisk(clearedCopy, notifyIPC: false, isClearReset: true)
            }
        }
    }

    private func installSnapshotLocked(_ loaded: LokeyDiagnosticSnapshot) {
        ringRevision &+= 1
        snapshot = loaded
        snapshot.entries = []
        entries = DiagnosticEntryRing()
        for entry in loaded.entries.suffix(Self.maxEntries) { entries.append(.restored(entry)) }
    }

    private static func materialize(_ header: LokeyDiagnosticSnapshot, _ rawEntries: [BufferedDiagnosticEntry]) -> LokeyDiagnosticSnapshot {
        var result = header
        result.entries = DiagnosticEntryRing.renderEntries(rawEntries)
        return result
    }

    /// Captures only the delta entries under `lockPtr` when called from `ioQueue` so ring buffer storage
    /// never crosses lock boundaries while keeping incremental flushes `O(log N + delta)`.
    private func captureIOQueueDeltaLocked() -> (
        header: LokeyDiagnosticSnapshot,
        revision: UInt64,
        ringCount: Int,
        firstRingID: UInt64?,
        rawDelta: [BufferedDiagnosticEntry]
    ) {
        let header = snapshot
        let rev = ringRevision
        let ringCount = entries.count
        let firstRingID = entries.firstEntryID
        let afterID: UInt64
        if cachedMaterializedEpoch == header.clearEpoch && cachedMaterializedRevision == rev {
            afterID = cachedMaterializedEntries.last?.id ?? 0
        } else {
            afterID = 0
        }
        let rawDelta = ringCount > 0 ? entries.copyNewerRawEntries(after: afterID) : []
        return (header, rev, ringCount, firstRingID, rawDelta)
    }

    /// `ioQueue`-exclusive incremental materializer: keeps already-rendered `LokeyDiagnosticEntry` objects across
    /// coalesced flushes so only newly appended entries run `localtime_r` + string formatting.
    private func materializeForIOQueue(
        _ header: LokeyDiagnosticSnapshot,
        revision: UInt64,
        ringCount: Int,
        firstRingID: UInt64?,
        rawDelta: [BufferedDiagnosticEntry]
    ) -> LokeyDiagnosticSnapshot {
        if cachedMaterializedEpoch != header.clearEpoch || cachedMaterializedRevision != revision {
            cachedMaterializedEntries.removeAll(keepingCapacity: true)
            cachedMaterializedEpoch = header.clearEpoch
            cachedMaterializedRevision = revision
        }
        if ringCount == 0 {
            cachedMaterializedEntries.removeAll(keepingCapacity: true)
        } else {
            if let firstRingID,
               let firstCachedID = cachedMaterializedEntries.first?.id,
               firstRingID > firstCachedID {
                if let keepIdx = cachedMaterializedEntries.firstIndex(where: { $0.id >= firstRingID }) {
                    if keepIdx > 0 {
                        cachedMaterializedEntries.removeFirst(keepIdx)
                    }
                } else {
                    cachedMaterializedEntries.removeAll(keepingCapacity: true)
                }
            }
            if !rawDelta.isEmpty {
                var lastSec = time_t.min
                var lastTM = tm()
                for entry in rawDelta {
                    cachedMaterializedEntries.append(entry.rendered(lastSec: &lastSec, lastTM: &lastTM))
                }
            }
        }
        var result = header
        result.entries = cachedMaterializedEntries
        return result
    }

    public func currentSnapshot() -> LokeyDiagnosticSnapshot {
        os_unfair_lock_lock(lockPtr)
        let header = snapshot
        let rawEntries = entries.copyOrderedRawEntries()
        os_unfair_lock_unlock(lockPtr)
        return Self.materialize(header, rawEntries)
    }

    /// Clears all recorded events and counters in RAM and on disk immediately.
    public func clear() {
        ioQueue.sync { _ = clearOnIOQueue() }
    }

    /// Non-blocking clear dispatched off `.main` onto `ioQueue`.
    public func clearAsync(completion: (@Sendable (LokeyDiagnosticSnapshot) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let cleared = self.clearOnIOQueue()
            completion?(cleared)
        }
    }

    @discardableResult
    private func clearOnIOQueue() -> LokeyDiagnosticSnapshot {
        let snapToWrite: LokeyDiagnosticSnapshot
        os_unfair_lock_lock(lockPtr)
        let nextEpoch = snapshot.clearEpoch &+ 1
        var fresh = LokeyDiagnosticSnapshot()
        fresh.clearEpoch = nextEpoch
        fresh.nextTouchSeq = snapshot.nextTouchSeq
        ringRevision &+= 1
        entries = DiagnosticEntryRing()
        earlyTouchLimit = 0
        snapshot = fresh
        activeTouchSeq = 0
        lastEventUptime = 0

        lastScrollActivityUptime = 0
        lastSelfPostedEpoch = nextEpoch
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        snapToWrite = fresh
        os_unfair_lock_unlock(lockPtr)

        cachedMaterializedEntries.removeAll(keepingCapacity: true)
        cachedMaterializedEpoch = nextEpoch
        writeSnapshotToDisk(snapToWrite, notifyIPC: true, isClearReset: true)
        if fileURLOverride == nil {
            LokeyIPC.postDiagnosticLogCleared()
        }
        return snapToWrite
    }

    // MARK: - Event Recording API

    /// Records a physical finger-down anywhere on the keyboard window and returns its unique `touchSeq`.
    @discardableResult
    public func recordScreenTouchDown(
        point: CGPoint,
        activeFingerCount: Int,
        hitViewName: @autoclosure () -> String,
        didSeamPassThrough: Bool,
        dispatchLagMs: Double? = nil
    ) -> UInt64 {
        guard flagStorage.readCanRecord() else { return 0 }
        let resolvedHitName = hitViewName()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return 0
        }
        let seq = snapshot.nextTouchSeq
        snapshot.nextTouchSeq &+= 1
        activeTouchSeq = seq
        snapshot.counters.screenTouchDownCount += 1
        if activeFingerCount >= 2 {
            snapshot.counters.multiTouchOverlapCount += 1
        }
        if didSeamPassThrough {
            snapshot.counters.seamPassThroughCount += 1
        }

        appendEntryLocked(touchSeq: seq, category: "屏幕触控",
                          detail: .down(point, activeFingerCount, resolvedHitName, didSeamPassThrough, dispatchLagMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
        return seq
    }

    /// Zero-allocation fast path for `KeyboardViewController` root touch sniffer (`0` heap strings on `.main`).
    @discardableResult
    public func recordScreenTouchDownFast(
        point: CGPoint,
        activeFingerCount: Int,
        target: TouchHitTargetToken,
        didSeamPassThrough: Bool,
        dispatchLagMs: Double? = nil
    ) -> UInt64 {
        guard flagStorage.readCanRecord() else { return 0 }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return 0
        }
        let seq = snapshot.nextTouchSeq
        snapshot.nextTouchSeq &+= 1
        activeTouchSeq = seq
        snapshot.counters.screenTouchDownCount += 1
        if activeFingerCount >= 2 {
            snapshot.counters.multiTouchOverlapCount += 1
        }
        if didSeamPassThrough {
            snapshot.counters.seamPassThroughCount += 1
        }

        appendEntryLocked(touchSeq: seq, category: "屏幕触控",
                          detail: .downFast(point, activeFingerCount, target, didSeamPassThrough, dispatchLagMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
        return seq
    }

    public func recordKeyHit(
        touchSeq: UInt64,
        roleDesc: @autoclosure () -> String,
        isLetter: Bool,
        isBackspace: Bool,
        row: Int,
        col: Int,
        gridPoint: CGPoint,
        borderRemapFrom: String?,
        actionDesc: @autoclosure () -> String
    ) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedRole = roleDesc()
        let resolvedAction = actionDesc()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        if isLetter {
            snapshot.counters.letterTapCount += 1
        } else if isBackspace {
            snapshot.counters.backspaceTapCount += 1
        } else {
            snapshot.counters.spaceReturnSymbolCount += 1
        }
        if borderRemapFrom != nil { snapshot.counters.borderRemapCount += 1 }
        appendEntryLocked(touchSeq: touchSeq, category: "按键识别",
                          detail: .key(resolvedRole, row, col, gridPoint, borderRemapFrom, resolvedAction))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    /// Zero-allocation fast path for `KeyGridView.touchesBegan` (`0` string interpolation on `.main`).
    public func recordKeyHitFast(
        touchSeq: UInt64,
        roleToken: KeyHitRoleToken,
        isLetter: Bool,
        isBackspace: Bool,
        row: Int,
        col: Int,
        gridPoint: CGPoint,
        borderRemapFrom: String?,
        actionStatic: StaticString
    ) {
        recordKeyHitFast(
            touchSeq: touchSeq,
            roleToken: roleToken,
            isLetter: isLetter,
            isBackspace: isBackspace,
            row: row,
            col: col,
            gridPoint: gridPoint,
            borderRemapFrom: borderRemapFrom,
            actionToken: .staticText(actionStatic)
        )
    }

    public func recordKeyHitFast(
        touchSeq: UInt64,
        roleToken: KeyHitRoleToken,
        isLetter: Bool,
        isBackspace: Bool,
        row: Int,
        col: Int,
        gridPoint: CGPoint,
        borderRemapFrom: String?,
        actionToken: KeyHitActionToken
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        if isLetter {
            snapshot.counters.letterTapCount += 1
        } else if isBackspace {
            snapshot.counters.backspaceTapCount += 1
        } else {
            snapshot.counters.spaceReturnSymbolCount += 1
        }
        if borderRemapFrom != nil { snapshot.counters.borderRemapCount += 1 }
        appendEntryLocked(touchSeq: touchSeq, category: "按键识别",
                          detail: .keyFast(roleToken, row, col, gridPoint, borderRemapFrom, actionToken))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordMissedOrCancelledTouch(
        touchSeq: UInt64,
        point: CGPoint,
        reason: @autoclosure () -> String
    ) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedReason = reason()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        snapshot.counters.missedOrCancelledCount += 1
        appendEntryLocked(touchSeq: touchSeq, category: "未命中/取消", detail: .missed(point, resolvedReason))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordMissedOrCancelledTouchFast(
        touchSeq: UInt64,
        point: CGPoint,
        reason: MissedTouchReasonToken
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        snapshot.counters.missedOrCancelledCount += 1
        appendEntryLocked(touchSeq: touchSeq, category: "未命中/取消", detail: .missedFast(point, reason))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    /// A receipt from the actual buffer mutation, independent of asynchronous ranking.
    func recordLetterDisposition(touchSeq: UInt64, enteredPinyin: Bool = false, detail: @autoclosure () -> String) {
        guard flagStorage.readCanRecord(), touchSeq != 0 else { return }
        let text = detail()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        if enteredPinyin { snapshot.counters.pinyinAppendCount = (snapshot.counters.pinyinAppendCount ?? 0) + 1 }
        appendEntryLocked(touchSeq: touchSeq, category: "字母去向", summary: text)
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordLetterDispositionFast(
        touchSeq: UInt64,
        enteredPinyin: Bool = false,
        disposition: LetterDispositionToken
    ) {
        guard flagStorage.readCanRecord(), touchSeq != 0 else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        if enteredPinyin { snapshot.counters.pinyinAppendCount = (snapshot.counters.pinyinAppendCount ?? 0) + 1 }
        appendEntryLocked(touchSeq: touchSeq, category: "字母去向", detail: .letterDisposition(disposition))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    func recordTouchEnd(touchSeq: UInt64, cancelled: Bool) {
        guard flagStorage.readCanRecord(), touchSeq != 0 else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let staticSummary: StaticString = cancelled ? "系统取消" : "抬手"
        appendEntryLocked(touchSeq: touchSeq, category: "触点结束", detail: .staticText(staticSummary))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordDecode(
        touchSeq: UInt64,
        rawKeys: String,
        preedit: String,
        topCandidates: @autoclosure () -> [String],
        elapsedMs: Double
    ) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedTop = topCandidates()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        appendEntryLocked(touchSeq: touchSeq, category: "引擎解码", detail: .decode(rawKeys, preedit, resolvedTop, elapsedMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    /// Zero-allocation decode logging path (`0` `[Character]`/`String`/`[String]` heap allocations on `.main`).
    public func recordDecodeFast(
        touchSeq: UInt64,
        samples: [TouchSample],
        preedit: String,
        candidates: [LokeyCandidate],
        elapsedMs: Double
    ) {
        guard flagStorage.readCanRecord() else { return }
        let inlineRaw = InlineASCII64(samples: samples)
        let top4 = DiagnosticTop4Candidates(candidates: candidates)
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        appendEntryLocked(touchSeq: touchSeq, category: "引擎解码", detail: .decodeFast(inlineRaw, preedit, top4, elapsedMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordCommit(
        touchSeq: UInt64,
        source: String,
        committedText: String,
        remainingPreedit: String
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        appendEntryLocked(touchSeq: seq, category: "上屏提交", detail: .commit(source, committedText, remainingPreedit))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordCommitFast(
        touchSeq: UInt64,
        source: CommitSourceToken,
        committedText: String,
        remaining: CommitRemainingToken
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        appendEntryLocked(touchSeq: seq, category: "上屏提交", detail: .commitFast(source, committedText, remaining))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordCandidateBarEvent(
        touchSeq: UInt64 = 0,
        isTapCommit: Bool = false,
        isScrollPanStart: Bool = false,
        isGridPanStart: Bool = false,
        detail: @autoclosure () -> String
    ) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedDetail = detail()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        if isTapCommit {
            snapshot.counters.candidateTapCount += 1
        }
        if isGridPanStart { snapshot.counters.gridScrollPanCount = (snapshot.counters.gridScrollPanCount ?? 0) + 1 }
        if isScrollPanStart {
            snapshot.counters.candidateScrollPanCount += 1
        }
        appendEntryLocked(touchSeq: seq, category: "候选栏", summary: resolvedDetail)
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordCandidateBarEventFast(
        touchSeq: UInt64 = 0,
        isTapCommit: Bool = false,
        isScrollPanStart: Bool = false,
        isGridPanStart: Bool = false,
        event: CandidateBarEventToken
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        if isTapCommit {
            snapshot.counters.candidateTapCount += 1
        }
        if isGridPanStart { snapshot.counters.gridScrollPanCount = (snapshot.counters.gridScrollPanCount ?? 0) + 1 }
        if isScrollPanStart {
            snapshot.counters.candidateScrollPanCount += 1
        }
        appendEntryLocked(touchSeq: seq, category: "候选栏", detail: .candidateBarFast(event))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordLayoutGeometry(detail: @autoclosure () -> String) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedDetail = detail()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        appendEntryLocked(touchSeq: 0, category: "界面几何", summary: resolvedDetail)
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordLayoutGeometryFast(signature: GeometrySignature, screenMinY: CGFloat, screenMaxY: CGFloat) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        appendEntryLocked(touchSeq: 0, category: "界面几何", detail: .layoutGeometryFast(signature, screenMinY, screenMaxY))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    func recordPreeditDelay(touchSeq: UInt64, waitMs: Double, proxyMs: Double) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        appendEntryLocked(touchSeq: touchSeq, category: "拼音回显", detail: .preeditDelay(waitMs, proxyMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordMainThreadStall(touchSeq: UInt64 = 0, phase: @autoclosure () -> String, elapsedMs: Double) {
        guard flagStorage.readCanRecord() else { return }
        let resolvedPhase = phase()
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        appendEntryLocked(touchSeq: seq, category: "主线程耗时", detail: .stall(resolvedPhase, elapsedMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordMainThreadStallFast(
        touchSeq: UInt64 = 0,
        phase: StaticString,
        touchCount: Int = 0,
        tag: StaticString? = nil,
        elapsedMs: Double
    ) {
        guard flagStorage.readCanRecord() else { return }
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let seq = touchSeq > 0 ? touchSeq : activeTouchSeq
        appendEntryLocked(touchSeq: seq, category: "主线程耗时", detail: .stallFast(phase, touchCount, tag, elapsedMs))
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    // MARK: - Plain-Text Report Formatter

    public static func formatPlainTextReport(snapshot: LokeyDiagnosticSnapshot, appVersion: String) -> String {
        let c = snapshot.counters
        var lines: [String] = []
        lines.reserveCapacity(snapshot.entries.count + 8)
        lines.append("=== Lokey 触控与输入诊断日志 (v\(appVersion)) ===")
        lines.append("屏幕总点击: \(c.screenTouchDownCount) 次 | 字母命中: \(c.letterTapCount) 次 | 空格/回车/标点: \(c.spaceReturnSymbolCount) 次 | 退格: \(c.backspaceTapCount) 次")
        lines.append("双指重叠连击: \(c.multiTouchOverlapCount) 次 | 候选栏底沿直通: \(c.seamPassThroughCount) 次 | 边缘防误触修正: \(c.borderRemapCount) 次")
        lines.append("候选栏选词: \(c.candidateTapCount) 次 | 候选栏横向滑动: \(c.candidateScrollPanCount) 次 | 展开面板纵滑: \(c.gridScrollPanCount ?? 0) 次 | 未命中/取消: \(c.missedOrCancelledCount) 次")
        lines.append("逐触点追踪（Build 50 起） | 已入拼音串: \(c.pinyinAppendCount ?? 0) 次 | 明细: 最近 \(snapshot.entries.count)/\(Self.maxEntries) 条")
        lines.append(String(repeating: "-", count: 52))
        if snapshot.entries.isEmpty {
            lines.append("（暂无日志记录）")
        } else {
            for e in snapshot.entries {
                let seqStr = e.touchSeq > 0 ? String(format: "#%03llu", e.touchSeq) : "#---"
                lines.append(String(format: "[%@ %@ +%.1fms] [%@] %@", seqStr, e.wallTime, e.deltaMs, e.category, e.summary))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence Internals

    private func appendEntryLocked(touchSeq: UInt64, category: String, summary: String) {
        appendEntryLocked(touchSeq: touchSeq, category: category, detail: .text(summary))
    }

    private func appendEntryLocked(touchSeq: UInt64, category: String, detail: DiagnosticDetail) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let deltaMs: Double
        if lastEventUptime > 0 && nowUptime >= lastEventUptime {
            deltaMs = min(99_999.0, (nowUptime - lastEventUptime) * 1000.0)
        } else {
            deltaMs = 0.0
        }
        lastEventUptime = nowUptime

        let entryID = snapshot.nextEntryID
        snapshot.nextEntryID &+= 1
        let seq = touchSeq > 0 && touchSeq < earlyTouchLimit ? touchSeq + earlyTouchOffset : touchSeq
        let wallMicros = clockBaseWallMicros &+ Int64((nowUptime * 1_000_000.0).rounded())
        entries.append(.event(entryID, seq, wallMicros, deltaMs, category, detail))
    }

    private func scheduleCoalescedFlush(delay: TimeInterval? = nil) {
        let isTestOverride = (fileURLOverride != nil)
        let defaultDelay: TimeInterval = isTestOverride ? 0.16 : 0.45
        let idleGate: TimeInterval = isTestOverride ? 0.14 : 0.40
        let targetDelay = delay ?? defaultDelay

        os_unfair_lock_lock(lockPtr)
        if pendingFlushWorkItem != nil {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            os_unfair_lock_lock(self.lockPtr)
            let idle = now - self.lastEventUptime
            let scrollCooldown: TimeInterval = isTestOverride ? 0.06 : 0.32
            let scrollBusy = !self.scrollingOwners.isEmpty
                || (self.lastScrollActivityUptime > 0 && now - self.lastScrollActivityUptime < scrollCooldown)
            if scrollBusy || (self.lastEventUptime > 0 && idle >= 0 && idle < idleGate) {
                // Coalesce burst typing and defer disk/IPC flushes during 120Hz scroll deceleration!
                self.pendingFlushWorkItem = nil
                os_unfair_lock_unlock(self.lockPtr)
                let nextDelay = scrollBusy ? (isTestOverride ? 0.10 : 0.38) : max(0.001, idleGate - idle)
                self.scheduleCoalescedFlush(delay: nextDelay)
                return
            }
            self.pendingFlushWorkItem = nil

            let headerPreview = self.snapshot
            if headerPreview.clearEpoch == self.lastFlushedEpoch && headerPreview.nextEntryID == self.lastFlushedNextEntryID {
                os_unfair_lock_unlock(self.lockPtr)
                return
            }
            let captured = self.captureIOQueueDeltaLocked()
            os_unfair_lock_unlock(self.lockPtr)
            let snap = self.materializeForIOQueue(
                captured.header,
                revision: captured.revision,
                ringCount: captured.ringCount,
                firstRingID: captured.firstRingID,
                rawDelta: captured.rawDelta
            )
            self.writeSnapshotToDisk(snap, notifyIPC: true)
        }
        pendingFlushWorkItem = item
        os_unfair_lock_unlock(lockPtr)
        ioQueue.asyncAfter(deadline: .now() + targetDelay, execute: item)
    }

    public func flushSynchronously() {
        ioQueue.sync { flushOnIOQueue() }
    }

    private func flushOnIOQueue() {
        os_unfair_lock_lock(lockPtr)
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil

        let headerPreview = snapshot
        if headerPreview.clearEpoch == lastFlushedEpoch && headerPreview.nextEntryID == lastFlushedNextEntryID {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let captured = captureIOQueueDeltaLocked()
        os_unfair_lock_unlock(lockPtr)
        let snap = materializeForIOQueue(
            captured.header,
            revision: captured.revision,
            ringCount: captured.ringCount,
            firstRingID: captured.firstRingID,
            rawDelta: captured.rawDelta
        )
        writeSnapshotToDisk(snap, notifyIPC: true)
    }

    public func flushAsync() {
        ioQueue.async { [weak self] in self?.flushOnIOQueue() }
    }

    private func writeSnapshotToDisk(
        _ snap: LokeyDiagnosticSnapshot,
        notifyIPC: Bool,
        isClearReset: Bool = false,
        forceWrite: Bool = false
    ) {
        if snap.clearEpoch < lastFlushedEpoch {
            return
        }
        if snap.clearEpoch == lastFlushedEpoch {
            if snap.nextEntryID < lastFlushedNextEntryID {
                return
            }
            if !forceWrite && snap.nextEntryID == lastFlushedNextEntryID {
                return
            }
        }
        let recalibratedBase = Self.computeClockBaseWallMicros()
        os_unfair_lock_lock(lockPtr)
        clockBaseWallMicros = recalibratedBase
        let epoch = snapshot.clearEpoch
        os_unfair_lock_unlock(lockPtr)
        guard snap.clearEpoch >= epoch,
              let data = try? ioEncoder.encode(snap) else { return }
        lastFlushedEpoch = snap.clearEpoch
        lastFlushedNextEntryID = snap.nextEntryID

        if let override = fileURLOverride {
            try? FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: override, options: .atomic)
            return
        }

        if isRunningInExtension {
            let localURL = localExtensionBackupURL
            try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: localURL, options: .atomic)
        }

        LokeyAppGroup.invalidateCacheIfUnresolved()
        let containers = LokeyAppGroup.accessibleContainers()
        if !containers.isEmpty {
            for item in containers {
                let fURL = item.lokeyDir.appendingPathComponent(Self.fileName)
                let wroteFile = (try? data.write(to: fURL, options: .atomic)) != nil
                if isClearReset {
                    // Purge any stale large diagnostic blob in `UserDefaults` (`cfprefsd`) and write the tiny cleared header.
                    if let suite = UserDefaults(suiteName: item.id) {
                        suite.set(data, forKey: Self.defaultsStorageKey)
                    }
                } else if !wroteFile, let suite = UserDefaults(suiteName: item.id) {
                    // Only fall back to `cfprefsd` XPC if atomic file write into the App Group directory failed!
                    suite.set(data, forKey: Self.defaultsStorageKey)
                }
            }
        } else {
            let url = targetFileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        if notifyIPC {
            LokeyIPC.postDiagnosticLogChanged()
        }
    }
}

// MARK: - Non-Blocking Host App & Extension Shared Async Loaders (F10)

private let sharedAsyncLoaderQueue = DispatchQueue(label: "com.kianuni.lokey.sharedAsyncLoader", qos: .utility)

public extension LokeyAppGroupBridgeStatus {
    static let empty = LokeyAppGroupBridgeStatus(
        hostGroups: [],
        extensionGroups: [],
        resolvedGroupID: nil,
        hasEntitlementMismatch: false,
        extensionHeartbeat: nil
    )
}

public extension LokeyAppGroup {
    static func inspectBridgeStatusAsync(
        on queue: DispatchQueue? = nil,
        completion: @escaping @Sendable (LokeyAppGroupBridgeStatus) -> Void
    ) {
        (queue ?? sharedAsyncLoaderQueue).async {
            completion(LokeyAppGroup.inspectBridgeStatus())
        }
    }
}

public extension LokeySettings {
    static func loadAsync(
        on queue: DispatchQueue? = nil,
        completion: @escaping @Sendable (LokeySettings) -> Void
    ) {
        (queue ?? sharedAsyncLoaderQueue).async {
            completion(LokeySettings.load())
        }
    }
}

public extension LokeyTouchCalibration {
    static func loadAsync(
        on queue: DispatchQueue? = nil,
        completion: @escaping @Sendable (LokeyTouchCalibration) -> Void
    ) {
        (queue ?? sharedAsyncLoaderQueue).async {
            completion(LokeyTouchCalibration.load())
        }
    }
}

// MARK: - Candidate Selection Mismatch / Feedback Logger (选词纠偏样本本)

/// Structured record of a real-world candidate selection mismatch (`top1Predicted` vs `userChosen`)
/// accumulated locally for future offline neural / lexicon distillation.
public struct LokeySelectionFeedbackEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case nonTopSelect = "non_top"
        case stepwiseCompose = "stepwise"

        public var title: String {
            switch self {
            case .nonTopSelect:
                return "直接改选"
            case .stepwiseCompose:
                return "分步拼词"
            }
        }
    }

    public var id: UInt64
    public var wallTime: String
    public var kind: Kind
    public var pinyinScheme: String
    public var precedingContext: String
    public var rawInput: String
    public var matchedPinyin: String
    public var top1Predicted: String
    public var userChosen: String
    public var selectedIndex: Int
    public var topCandidatesPreview: [String]

    public init(
        id: UInt64,
        wallTime: String,
        kind: Kind,
        pinyinScheme: String,
        precedingContext: String,
        rawInput: String,
        matchedPinyin: String,
        top1Predicted: String,
        userChosen: String,
        selectedIndex: Int,
        topCandidatesPreview: [String]
    ) {
        self.id = id
        self.wallTime = wallTime
        self.kind = kind
        self.pinyinScheme = pinyinScheme
        self.precedingContext = precedingContext
        self.rawInput = rawInput
        self.matchedPinyin = matchedPinyin
        self.top1Predicted = top1Predicted
        self.userChosen = userChosen
        self.selectedIndex = selectedIndex
        self.topCandidatesPreview = topCandidatesPreview
    }
}

/// Persistent snapshot of candidate selection accuracy counters and up to `5,000` mismatch entries.
public struct LokeySelectionFeedbackSnapshot: Codable, Sendable, Equatable {
    public var clearEpoch: UInt64 = 1
    public var mutationSeq: UInt64 = 0
    public var nextEntryID: UInt64 = 1
    public var totalComposingCommits: UInt64 = 0
    public var top1HitCount: UInt64 = 0
    public var mismatchCount: UInt64 = 0
    public var entries: [LokeySelectionFeedbackEntry] = []

    public init() {}

    public var top1HitRatePercent: Double? {
        guard totalComposingCommits > 0 else { return nil }
        return Double(top1HitCount) * 100.0 / Double(totalComposingCommits)
    }
}

private enum BufferedSelectionFeedbackEntry {
    case recorded(
        id: UInt64,
        wallMicros: Int64,
        kind: LokeySelectionFeedbackEntry.Kind,
        pinyinScheme: String,
        precedingContext: String,
        rawInput: String,
        matchedPinyin: String,
        top1Predicted: String,
        userChosen: String,
        selectedIndex: Int,
        topCandidatesPreview: [String]
    )
    case restored(LokeySelectionFeedbackEntry)

    var entryID: UInt64 {
        switch self {
        case let .recorded(id, _, _, _, _, _, _, _, _, _, _):
            return id
        case let .restored(entry):
            return entry.id
        }
    }

    func rendered(lastSec: inout time_t, lastTM: inout tm) -> LokeySelectionFeedbackEntry {
        switch self {
        case let .restored(entry):
            return entry
        case let .recorded(
            id,
            wallMicros,
            kind,
            pinyinScheme,
            precedingContext,
            rawInput,
            matchedPinyin,
            top1Predicted,
            userChosen,
            selectedIndex,
            topCandidatesPreview
        ):
            var sec = time_t(wallMicros / 1_000_000)
            if wallMicros < 0 && wallMicros % 1_000_000 != 0 {
                sec &-= 1
            }
            if sec != lastSec {
                var s = sec
                localtime_r(&s, &lastTM)
                lastSec = sec
            }
            let mon = max(1, min(12, Int(lastTM.tm_mon) + 1))
            let day = max(1, min(31, Int(lastTM.tm_mday)))
            let h = max(0, min(23, Int(lastTM.tm_hour)))
            let m = max(0, min(59, Int(lastTM.tm_min)))
            let s = max(0, min(60, Int(lastTM.tm_sec)))
            var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                UInt8(48 + (mon / 10) % 10), UInt8(48 + mon % 10), 45, // MM-
                UInt8(48 + (day / 10) % 10), UInt8(48 + day % 10), 32, // dd_
                UInt8(48 + (h / 10) % 10), UInt8(48 + h % 10), 58,     // HH:
                UInt8(48 + (m / 10) % 10), UInt8(48 + m % 10), 58,     // mm:
                UInt8(48 + (s / 10) % 10), UInt8(48 + s % 10)          // ss
            )
            let wall = withUnsafeBytes(of: &buf) { String(decoding: $0, as: UTF8.self) }
            return LokeySelectionFeedbackEntry(
                id: id,
                wallTime: wall,
                kind: kind,
                pinyinScheme: pinyinScheme,
                precedingContext: precedingContext,
                rawInput: rawInput,
                matchedPinyin: matchedPinyin,
                top1Predicted: top1Predicted,
                userChosen: userChosen,
                selectedIndex: selectedIndex,
                topCandidatesPreview: topCandidatesPreview
            )
        }
    }
}

private struct SelectionFeedbackRing {
    private var storage: [BufferedSelectionFeedbackEntry] = []
    private var next = 0
    private(set) var count = 0

    var firstEntryID: UInt64? {
        guard count > 0 else { return nil }
        let startIndex = count == LokeySelectionFeedbackLogger.maxEntries ? next : 0
        return storage[startIndex].entryID
    }

    mutating func append(_ entry: BufferedSelectionFeedbackEntry) {
        if count < LokeySelectionFeedbackLogger.maxEntries {
            if storage.isEmpty {
                storage.reserveCapacity(32)
            }
            storage.append(entry)
            count += 1
            next = count % LokeySelectionFeedbackLogger.maxEntries
        } else {
            storage[next] = entry
            next = (next + 1) % LokeySelectionFeedbackLogger.maxEntries
        }
    }

    func copyOrderedRawEntries() -> [BufferedSelectionFeedbackEntry] {
        guard count > 0 else { return [] }
        var copy = [BufferedSelectionFeedbackEntry]()
        copy.reserveCapacity(count)
        if count < LokeySelectionFeedbackLogger.maxEntries {
            copy.append(contentsOf: storage)
        } else {
            copy.append(contentsOf: storage[next..<LokeySelectionFeedbackLogger.maxEntries])
            if next > 0 {
                copy.append(contentsOf: storage[0..<next])
            }
        }
        return copy
    }

    func copyNewerRawEntries(after lastID: UInt64) -> [BufferedSelectionFeedbackEntry] {
        guard count > 0 else { return [] }
        var copy = [BufferedSelectionFeedbackEntry]()
        if count < LokeySelectionFeedbackLogger.maxEntries {
            Self.appendNewerRaw(from: storage[0..<count], after: lastID, into: &copy)
        } else {
            Self.appendNewerRaw(from: storage[next..<LokeySelectionFeedbackLogger.maxEntries], after: lastID, into: &copy)
            if next > 0 {
                Self.appendNewerRaw(from: storage[0..<next], after: lastID, into: &copy)
            }
        }
        return copy
    }

    static func renderEntries(_ rawEntries: [BufferedSelectionFeedbackEntry]) -> [LokeySelectionFeedbackEntry] {
        guard !rawEntries.isEmpty else { return [] }
        var result = [LokeySelectionFeedbackEntry]()
        result.reserveCapacity(rawEntries.count)
        var lastSec = time_t.min
        var lastTM = tm()
        for entry in rawEntries {
            result.append(entry.rendered(lastSec: &lastSec, lastTM: &lastTM))
        }
        return result
    }

    func orderedEntries() -> [LokeySelectionFeedbackEntry] {
        Self.renderEntries(copyOrderedRawEntries())
    }

    private static func appendNewerRaw(
        from slice: ArraySlice<BufferedSelectionFeedbackEntry>,
        after lastID: UInt64,
        into copy: inout [BufferedSelectionFeedbackEntry]
    ) {
        guard let last = slice.last, last.entryID > lastID else { return }
        var lo = slice.startIndex
        if let first = slice.first, first.entryID <= lastID {
            var hi = slice.endIndex
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if slice[mid].entryID <= lastID {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
        }
        copy.append(contentsOf: slice[lo..<slice.endIndex])
    }
}

/// Persistent, zero-network, main-thread non-blocking collector of candidate selection mismatches
/// (up to `5,000` entries) with automatic secure-field redaction and one-tap TSV export.
public final class LokeySelectionFeedbackLogger: @unchecked Sendable {
    public static let shared = LokeySelectionFeedbackLogger()
    public static let maxEntries = 5000
    private static let defaultsStorageKey = "com.kianuni.lokey.selection_feedback.v1"
    private static let fileName = "lokey_selection_feedback.json"

    private let lockPtr: UnsafeMutablePointer<os_unfair_lock_s>
    private let flagStorage: FastFlagStorage
    private var snapshot = LokeySelectionFeedbackSnapshot()
    private var entries = SelectionFeedbackRing()
    private var _isEnabled: Bool = true
    private var _isSecureContext: Bool = false
    private var clockBaseWallMicros: Int64
    private var lastEventUptime: TimeInterval = 0
    private var pendingFlushWorkItem: DispatchWorkItem?
    private var didBootstrapFromDisk: Bool = false
    private var ringRevision: UInt64 = 0

    // `ioQueue`-exclusive incremental materialization & dirty-check state.
    private var cachedMaterializedEpoch: UInt64 = 0
    private var cachedMaterializedRevision: UInt64 = 0
    private var cachedMaterializedEntries: [LokeySelectionFeedbackEntry] = []
    private var lastFlushedEpoch: UInt64 = 1
    private var lastFlushedMutationSeq: UInt64 = 0
    private let ioEncoder = JSONEncoder()

    private let ioQueue = DispatchQueue(label: "com.kianuni.lokey.selectionFeedbackIO", qos: .utility)
    private let fileURLOverride: URL?

    private static func computeClockBaseWallMicros() -> Int64 {
        var stamp = timeval()
        gettimeofday(&stamp, nil)
        let uptimeMicros = Int64((ProcessInfo.processInfo.systemUptime * 1_000_000.0).rounded())
        let wallMicros = Int64(stamp.tv_sec) * 1_000_000 &+ Int64(stamp.tv_usec)
        return wallMicros &- uptimeMicros
    }

    public init(fileURLOverride: URL? = nil, initialEnabled: Bool = true) {
        let ptr = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock_s())
        self.lockPtr = ptr
        self.flagStorage = FastFlagStorage(isEnabled: initialEnabled)
        self.fileURLOverride = fileURLOverride
        self._isEnabled = initialEnabled
        self.clockBaseWallMicros = Self.computeClockBaseWallMicros()
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    private var targetFileURL: URL {
        fileURLOverride ?? LokeyAppGroup.sharedSelectionFeedbackFileURL()
    }

    private var localExtensionBackupURL: URL {
        LokeyAppGroup.localPrivateSupportDirectoryURL().appendingPathComponent(Self.fileName)
    }

    private var isRunningInExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private static func isNewer(_ a: LokeySelectionFeedbackSnapshot, than b: LokeySelectionFeedbackSnapshot) -> Bool {
        if a.clearEpoch != b.clearEpoch {
            return a.clearEpoch > b.clearEpoch
        }
        if a.mutationSeq != b.mutationSeq {
            return a.mutationSeq > b.mutationSeq
        }
        return a.nextEntryID > b.nextEntryID
    }

    public var isEnabled: Bool {
        @inline(__always)
        get { flagStorage.readIsEnabled() }
        set {
            os_unfair_lock_lock(lockPtr)
            _isEnabled = newValue
            flagStorage.update(isEnabled: newValue, isSecureContext: _isSecureContext)
            os_unfair_lock_unlock(lockPtr)
        }
    }

    public var isSecureContext: Bool {
        @inline(__always)
        get { flagStorage.readIsSecureContext() }
        set {
            os_unfair_lock_lock(lockPtr)
            _isSecureContext = newValue
            flagStorage.update(isEnabled: _isEnabled, isSecureContext: newValue)
            os_unfair_lock_unlock(lockPtr)
        }
    }

    @inline(__always)
    public var canRecord: Bool {
        flagStorage.readCanRecord()
    }

    // MARK: - Recording API (O(1), lock-protected, zero disk/JSON work on `.main`)

    public func recordTop1Hit() {
        guard flagStorage.readCanRecord() else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        snapshot.totalComposingCommits &+= 1
        snapshot.top1HitCount &+= 1
        snapshot.mutationSeq &+= 1
        lastEventUptime = nowUptime
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    public func recordMismatch(
        kind: LokeySelectionFeedbackEntry.Kind,
        pinyinScheme: String,
        precedingContext: String,
        rawInput: String,
        matchedPinyin: String,
        top1Predicted: String,
        userChosen: String,
        selectedIndex: Int,
        topCandidatesPreview: [String],
        alsoCountCommit: Bool = true
    ) {
        guard flagStorage.readCanRecord() else { return }
        let sanitizedRaw = Self.sanitizeField(rawInput)
        let sanitizedTop1 = Self.sanitizeField(top1Predicted)
        let sanitizedChosen = Self.sanitizeField(userChosen)
        guard !sanitizedRaw.isEmpty, !sanitizedTop1.isEmpty, !sanitizedChosen.isEmpty else { return }
        let sanitizedCtx = String(Self.sanitizeField(precedingContext).suffix(10))
        let sanitizedMatched = Self.sanitizeField(matchedPinyin)
        let sanitizedScheme = Self.sanitizeField(pinyinScheme)
        let sanitizedPreview = Array(topCandidatesPreview.map { Self.sanitizeField($0) }.filter { !$0.isEmpty }.prefix(5))

        let nowUptime = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(lockPtr)
        guard _isEnabled, !_isSecureContext else {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        if alsoCountCommit {
            snapshot.totalComposingCommits &+= 1
        }
        snapshot.mismatchCount &+= 1
        snapshot.mutationSeq &+= 1
        let entryID = snapshot.nextEntryID
        snapshot.nextEntryID &+= 1
        lastEventUptime = nowUptime
        let wallMicros = clockBaseWallMicros &+ Int64((nowUptime * 1_000_000.0).rounded())
        entries.append(
            .recorded(
                id: entryID,
                wallMicros: wallMicros,
                kind: kind,
                pinyinScheme: sanitizedScheme,
                precedingContext: sanitizedCtx,
                rawInput: sanitizedRaw,
                matchedPinyin: sanitizedMatched,
                top1Predicted: sanitizedTop1,
                userChosen: sanitizedChosen,
                selectedIndex: max(0, selectedIndex),
                topCandidatesPreview: sanitizedPreview
            )
        )
        let needsFlush = (pendingFlushWorkItem == nil)
        os_unfair_lock_unlock(lockPtr)
        if needsFlush { scheduleCoalescedFlush() }
    }

    // MARK: - Persistence & Lifecycle

    public func bootstrapFromDiskIfNeeded() {
        os_unfair_lock_lock(lockPtr)
        if didBootstrapFromDisk {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        didBootstrapFromDisk = true
        os_unfair_lock_unlock(lockPtr)
        _ = reloadFromDisk()
    }

    public func bootstrapFromDiskAsync() {
        os_unfair_lock_lock(lockPtr)
        if didBootstrapFromDisk {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        didBootstrapFromDisk = true
        os_unfair_lock_unlock(lockPtr)
        ioQueue.async { [weak self] in
            self?.mergeBootstrapFromDiskOnQueue()
        }
    }

    private func mergeBootstrapFromDiskOnQueue() {
        guard let loaded = readBestSnapshotFromStorage() else { return }
        let diskSnap = loaded.snapshot
        var shouldPromote = loaded.needsSharedPromotion
        var promoteCopy: LokeySelectionFeedbackSnapshot?

        os_unfair_lock_lock(lockPtr)
        if diskSnap.clearEpoch >= snapshot.clearEpoch && snapshot.mutationSeq == 0 && entries.count == 0 {
            installSnapshotLocked(diskSnap)
            lastFlushedEpoch = diskSnap.clearEpoch
            lastFlushedMutationSeq = diskSnap.mutationSeq
            if shouldPromote {
                promoteCopy = Self.materialize(snapshot, entries.copyOrderedRawEntries())
            }
        } else if diskSnap.clearEpoch >= snapshot.clearEpoch && (diskSnap.mutationSeq > 0 || diskSnap.nextEntryID > 1) {
            let earlyEntries = entries.orderedEntries()
            let earlyHeader = snapshot
            var merged = diskSnap
            merged.totalComposingCommits &+= earlyHeader.totalComposingCommits
            merged.top1HitCount &+= earlyHeader.top1HitCount
            merged.mismatchCount &+= earlyHeader.mismatchCount
            merged.mutationSeq = diskSnap.mutationSeq &+ earlyHeader.mutationSeq
            for var e in earlyEntries {
                let id = merged.nextEntryID
                merged.nextEntryID &+= 1
                e.id = id
                merged.entries.append(e)
            }
            installSnapshotLocked(merged)
            shouldPromote = true
            promoteCopy = Self.materialize(snapshot, entries.copyOrderedRawEntries())
        }
        os_unfair_lock_unlock(lockPtr)

        if shouldPromote, let promoteCopy {
            writeSnapshotToDisk(promoteCopy, notifyIPC: true, forceWrite: true)
        }
    }

    @discardableResult
    public func reloadFromDisk() -> LokeySelectionFeedbackSnapshot {
        guard let loaded = readBestSnapshotFromStorage() else {
            return currentSnapshot()
        }
        let diskSnap = loaded.snapshot
        var shouldPromote = loaded.needsSharedPromotion
        os_unfair_lock_lock(lockPtr)
        if snapshot.clearEpoch > diskSnap.clearEpoch || (Self.isNewer(snapshot, than: diskSnap) && isRunningInExtension) {
            shouldPromote = true
        } else {
            installSnapshotLocked(diskSnap)
            lastFlushedEpoch = diskSnap.clearEpoch
            lastFlushedMutationSeq = diskSnap.mutationSeq
        }
        let header = snapshot
        let rawEntries = entries.copyOrderedRawEntries()
        os_unfair_lock_unlock(lockPtr)
        let copy = Self.materialize(header, rawEntries)
        if shouldPromote {
            ioQueue.async { [weak self] in
                self?.writeSnapshotToDisk(copy, notifyIPC: true, forceWrite: true)
            }
        }
        return copy
    }

    public func reloadFromDiskAsync(completion: @escaping @Sendable (LokeySelectionFeedbackSnapshot) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.reloadFromDisk()
            completion(loaded)
        }
    }

    public func syncExternalClearAsync() {
        ioQueue.async { [weak self] in
            self?.syncExternalClearIfNeeded()
        }
    }

    public func syncExternalClearIfNeeded() {
        guard let loaded = readBestSnapshotFromStorage() else { return }
        let diskSnap = loaded.snapshot
        var clearedCopy: LokeySelectionFeedbackSnapshot?
        os_unfair_lock_lock(lockPtr)
        if diskSnap.clearEpoch > snapshot.clearEpoch {
            installSnapshotLocked(diskSnap)
            lastEventUptime = 0
            lastFlushedEpoch = diskSnap.clearEpoch
            lastFlushedMutationSeq = diskSnap.mutationSeq
            clearedCopy = diskSnap
        }
        os_unfair_lock_unlock(lockPtr)
        if let clearedCopy, isRunningInExtension {
            ioQueue.async { [weak self] in
                self?.writeSnapshotToDisk(clearedCopy, notifyIPC: false, isClearReset: true, forceWrite: true)
            }
        }
    }

    public func currentSnapshot() -> LokeySelectionFeedbackSnapshot {
        os_unfair_lock_lock(lockPtr)
        let header = snapshot
        let rawEntries = entries.copyOrderedRawEntries()
        os_unfair_lock_unlock(lockPtr)
        return Self.materialize(header, rawEntries)
    }

    public func flushSynchronously() {
        ioQueue.sync { flushOnIOQueue() }
    }

    public func flushAsync() {
        ioQueue.async { [weak self] in self?.flushOnIOQueue() }
    }

    public func clear() {
        ioQueue.sync { _ = clearOnIOQueue() }
    }

    public func clearAsync(completion: (@Sendable (LokeySelectionFeedbackSnapshot) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let cleared = self.clearOnIOQueue()
            completion?(cleared)
        }
    }

    // MARK: - TSV Export Formatter

    public static func formatTSVReport(snapshot: LokeySelectionFeedbackSnapshot, appVersion: String) -> String {
        let total = snapshot.totalComposingCommits
        let hits = snapshot.top1HitCount
        let rateStr: String
        if let rate = snapshot.top1HitRatePercent {
            rateStr = String(format: "%.1f%%", rate)
        } else {
            rateStr = "待统计"
        }
        var lines: [String] = []
        lines.reserveCapacity(snapshot.entries.count + 4)
        lines.append("# Lokey 选词纠偏样本本 (v\(appVersion))")
        lines.append("# 累计上屏: \(total) 次 | 首选一次命中: \(hits) 次 (\(rateStr)) | 累计纠偏: \(snapshot.mismatchCount) 次 | 当前样本: \(snapshot.entries.count)/\(Self.maxEntries) 条")
        lines.append("id\ttime\tkind\tscheme\tcontext\traw_input\tmatched_pinyin\ttop1_predicted\tuser_chosen\tchosen_rank\tcandidates_top5")
        for e in snapshot.entries {
            let preview = e.topCandidatesPreview.map { sanitizeField($0) }.joined(separator: "|")
            let cols: [String] = [
                String(e.id),
                sanitizeField(e.wallTime),
                e.kind.rawValue,
                sanitizeField(e.pinyinScheme),
                sanitizeField(e.precedingContext),
                sanitizeField(e.rawInput),
                sanitizeField(e.matchedPinyin),
                sanitizeField(e.top1Predicted),
                sanitizeField(e.userChosen),
                String(e.selectedIndex + 1),
                preview,
            ]
            lines.append(cols.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private static func sanitizeField(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(value.count)
        var lastWasSpace = false
        for scalar in value.unicodeScalars {
            if scalar == "\t" || scalar == "\r" || scalar == "\n" {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = (scalar == " ")
            }
        }
        return out
    }

    private func installSnapshotLocked(_ loaded: LokeySelectionFeedbackSnapshot) {
        ringRevision &+= 1
        snapshot = loaded
        snapshot.entries = []
        entries = SelectionFeedbackRing()
        for entry in loaded.entries.suffix(Self.maxEntries) {
            entries.append(.restored(entry))
        }
    }

    private static func materialize(
        _ header: LokeySelectionFeedbackSnapshot,
        _ rawEntries: [BufferedSelectionFeedbackEntry]
    ) -> LokeySelectionFeedbackSnapshot {
        var result = header
        result.entries = SelectionFeedbackRing.renderEntries(rawEntries)
        return result
    }

    private func readBestSnapshotFromStorage() -> (snapshot: LokeySelectionFeedbackSnapshot, needsSharedPromotion: Bool)? {
        let decoder = JSONDecoder()
        if let override = fileURLOverride {
            guard let data = try? Data(contentsOf: override),
                  let snap = try? decoder.decode(LokeySelectionFeedbackSnapshot.self, from: data) else {
                return nil
            }
            return (snap, false)
        }

        LokeyAppGroup.invalidateCacheIfUnresolved()
        var bestShared: LokeySelectionFeedbackSnapshot?
        let containers = LokeyAppGroup.accessibleContainers()
        for item in containers {
            let fURL = item.lokeyDir.appendingPathComponent(Self.fileName)
            var didReadContainerFile = false
            if let data = try? Data(contentsOf: fURL),
               let s = try? decoder.decode(LokeySelectionFeedbackSnapshot.self, from: data) {
                didReadContainerFile = true
                if let cur = bestShared {
                    if Self.isNewer(s, than: cur) { bestShared = s }
                } else {
                    bestShared = s
                }
            }
            if !didReadContainerFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: Self.defaultsStorageKey),
               let s = try? decoder.decode(LokeySelectionFeedbackSnapshot.self, from: data) {
                if let cur = bestShared {
                    if Self.isNewer(s, than: cur) { bestShared = s }
                } else {
                    bestShared = s
                }
            }
        }

        if bestShared == nil {
            let fallbackURL = targetFileURL
            if let data = try? Data(contentsOf: fallbackURL),
               let s = try? decoder.decode(LokeySelectionFeedbackSnapshot.self, from: data) {
                bestShared = s
            }
        }

        if isRunningInExtension,
           let localData = try? Data(contentsOf: localExtensionBackupURL),
           let localSnap = try? decoder.decode(LokeySelectionFeedbackSnapshot.self, from: localData) {
            if let shared = bestShared {
                if Self.isNewer(localSnap, than: shared) {
                    return (localSnap, !containers.isEmpty)
                }
                return (shared, false)
            }
            return (localSnap, !containers.isEmpty)
        }

        if let shared = bestShared {
            return (shared, false)
        }
        return nil
    }

    private func scheduleCoalescedFlush(delay: TimeInterval? = nil) {
        let isTestOverride = (fileURLOverride != nil)
        let defaultDelay: TimeInterval = isTestOverride ? 0.14 : 0.55
        let idleGate: TimeInterval = isTestOverride ? 0.12 : 0.45
        let targetDelay = delay ?? defaultDelay

        os_unfair_lock_lock(lockPtr)
        if pendingFlushWorkItem != nil {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            os_unfair_lock_lock(self.lockPtr)
            let idle = now - self.lastEventUptime
            if self.lastEventUptime > 0 && idle >= 0 && idle < idleGate {
                self.pendingFlushWorkItem = nil
                os_unfair_lock_unlock(self.lockPtr)
                self.scheduleCoalescedFlush(delay: max(0.01, idleGate - idle))
                return
            }
            self.pendingFlushWorkItem = nil

            let headerPreview = self.snapshot
            if headerPreview.clearEpoch == self.lastFlushedEpoch && headerPreview.mutationSeq == self.lastFlushedMutationSeq {
                os_unfair_lock_unlock(self.lockPtr)
                return
            }
            let captured = self.captureIOQueueDeltaLocked()
            os_unfair_lock_unlock(self.lockPtr)
            let snap = self.materializeForIOQueue(
                captured.header,
                revision: captured.revision,
                ringCount: captured.ringCount,
                firstRingID: captured.firstRingID,
                rawDelta: captured.rawDelta
            )
            self.writeSnapshotToDisk(snap, notifyIPC: true)
        }
        pendingFlushWorkItem = item
        os_unfair_lock_unlock(lockPtr)
        ioQueue.asyncAfter(deadline: .now() + targetDelay, execute: item)
    }

    private func flushOnIOQueue() {
        os_unfair_lock_lock(lockPtr)
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil

        let headerPreview = snapshot
        if headerPreview.clearEpoch == lastFlushedEpoch && headerPreview.mutationSeq == lastFlushedMutationSeq {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        let captured = captureIOQueueDeltaLocked()
        os_unfair_lock_unlock(lockPtr)
        let snap = materializeForIOQueue(
            captured.header,
            revision: captured.revision,
            ringCount: captured.ringCount,
            firstRingID: captured.firstRingID,
            rawDelta: captured.rawDelta
        )
        writeSnapshotToDisk(snap, notifyIPC: true)
    }

    @discardableResult
    private func clearOnIOQueue() -> LokeySelectionFeedbackSnapshot {
        let snapToWrite: LokeySelectionFeedbackSnapshot
        os_unfair_lock_lock(lockPtr)
        let nextEpoch = snapshot.clearEpoch &+ 1
        var fresh = LokeySelectionFeedbackSnapshot()
        fresh.clearEpoch = nextEpoch
        ringRevision &+= 1
        entries = SelectionFeedbackRing()
        snapshot = fresh
        lastEventUptime = 0
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        snapToWrite = fresh
        os_unfair_lock_unlock(lockPtr)

        cachedMaterializedEntries.removeAll(keepingCapacity: true)
        cachedMaterializedEpoch = nextEpoch
        writeSnapshotToDisk(snapToWrite, notifyIPC: true, isClearReset: true, forceWrite: true)
        if fileURLOverride == nil {
            LokeyIPC.postSelectionFeedbackCleared()
        }
        return snapToWrite
    }

    private func captureIOQueueDeltaLocked() -> (
        header: LokeySelectionFeedbackSnapshot,
        revision: UInt64,
        ringCount: Int,
        firstRingID: UInt64?,
        rawDelta: [BufferedSelectionFeedbackEntry]
    ) {
        let header = snapshot
        let rev = ringRevision
        let ringCount = entries.count
        let firstRingID = entries.firstEntryID
        let afterID: UInt64
        if cachedMaterializedEpoch == header.clearEpoch && cachedMaterializedRevision == rev {
            afterID = cachedMaterializedEntries.last?.id ?? 0
        } else {
            afterID = 0
        }
        let rawDelta = ringCount > 0 ? entries.copyNewerRawEntries(after: afterID) : []
        return (header, rev, ringCount, firstRingID, rawDelta)
    }

    private func materializeForIOQueue(
        _ header: LokeySelectionFeedbackSnapshot,
        revision: UInt64,
        ringCount: Int,
        firstRingID: UInt64?,
        rawDelta: [BufferedSelectionFeedbackEntry]
    ) -> LokeySelectionFeedbackSnapshot {
        if cachedMaterializedEpoch != header.clearEpoch || cachedMaterializedRevision != revision {
            cachedMaterializedEntries.removeAll(keepingCapacity: true)
            cachedMaterializedEpoch = header.clearEpoch
            cachedMaterializedRevision = revision
        }
        if ringCount == 0 {
            cachedMaterializedEntries.removeAll(keepingCapacity: true)
        } else {
            if let firstRingID,
               let firstCachedID = cachedMaterializedEntries.first?.id,
               firstRingID > firstCachedID {
                if let keepIdx = cachedMaterializedEntries.firstIndex(where: { $0.id >= firstRingID }) {
                    if keepIdx > 0 {
                        cachedMaterializedEntries.removeFirst(keepIdx)
                    }
                } else {
                    cachedMaterializedEntries.removeAll(keepingCapacity: true)
                }
            }
            if !rawDelta.isEmpty {
                var lastSec = time_t.min
                var lastTM = tm()
                for entry in rawDelta {
                    cachedMaterializedEntries.append(entry.rendered(lastSec: &lastSec, lastTM: &lastTM))
                }
            }
        }
        var result = header
        result.entries = cachedMaterializedEntries
        return result
    }

    private func writeSnapshotToDisk(
        _ snap: LokeySelectionFeedbackSnapshot,
        notifyIPC: Bool,
        isClearReset: Bool = false,
        forceWrite: Bool = false
    ) {
        let recalibratedBase = Self.computeClockBaseWallMicros()
        os_unfair_lock_lock(lockPtr)
        clockBaseWallMicros = recalibratedBase
        let currentEpoch = snapshot.clearEpoch
        let staleEpoch = snap.clearEpoch < lastFlushedEpoch || snap.clearEpoch < currentEpoch
        let staleMutation = (snap.clearEpoch == lastFlushedEpoch)
            && (snap.mutationSeq < lastFlushedMutationSeq || (!forceWrite && snap.mutationSeq == lastFlushedMutationSeq))
        if staleEpoch || staleMutation {
            os_unfair_lock_unlock(lockPtr)
            return
        }
        lastFlushedEpoch = snap.clearEpoch
        lastFlushedMutationSeq = snap.mutationSeq
        os_unfair_lock_unlock(lockPtr)

        guard let data = try? ioEncoder.encode(snap) else { return }

        if let override = fileURLOverride {
            try? FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: override, options: .atomic)
            return
        }

        if isRunningInExtension {
            let localURL = localExtensionBackupURL
            try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: localURL, options: .atomic)
        }

        LokeyAppGroup.invalidateCacheIfUnresolved()
        let containers = LokeyAppGroup.accessibleContainers()
        if !containers.isEmpty {
            for item in containers {
                let fURL = item.lokeyDir.appendingPathComponent(Self.fileName)
                let wroteFile = (try? data.write(to: fURL, options: .atomic)) != nil
                if isClearReset {
                    if let suite = UserDefaults(suiteName: item.id) {
                        suite.set(data, forKey: Self.defaultsStorageKey)
                    }
                } else if !wroteFile, let suite = UserDefaults(suiteName: item.id) {
                    suite.set(data, forKey: Self.defaultsStorageKey)
                }
            }
        } else {
            let url = targetFileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        if notifyIPC {
            LokeyIPC.postSelectionFeedbackChanged()
        }
    }
}
