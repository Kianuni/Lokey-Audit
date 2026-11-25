import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Passive, zero-delay gesture recognizer attached directly to candidate `UIScrollView`s so stationary
/// brake-taps during momentum deceleration (`isDecelerating == true`) are captured in real `UIWindow.sendEvent`
/// even when `hitTest` returns a `UIButton` (`UIControl` swallows `UIResponder.touchesBegan`) and `UIScrollView`
/// withholds `UIButton` `.touchDown` to halt deceleration.
internal final class DecelerationBrakeTapGestureRecognizer: UIGestureRecognizer {
    var onTouchesBegan: ((Set<UITouch>) -> Void)?
    var onTouchesMoved: ((Set<UITouch>) -> Void)?
    var onTouchesEnded: ((Set<UITouch>) -> Void)?
    var onTouchesCancelled: ((Set<UITouch>) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchesBegan?(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchesMoved?(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchesEnded?(touches)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouchesCancelled?(touches)
        state = .failed
    }
}

/// Shared `UITouch`-identity-verified deceleration brake-tap tracker deduplicating passive gesture-recognizer
/// callbacks (`UIWindow.sendEvent`) and direct `UIScrollView.touchesBegan` unit-test calls.
internal final class DecelerationBrakeTracker {
    private weak var trackedTouch: UITouch?
    private var startPoint: CGPoint = .zero
    private var startUptime: TimeInterval = 0
    private var invalidated = false

    var hasPendingTouch: Bool {
        trackedTouch != nil && !invalidated
    }

    func reset() {
        trackedTouch = nil
        invalidated = false
    }

    func handleBegan(_ touches: Set<UITouch>, in scrollView: UIScrollView, isDecelerating: Bool) {
        if let existing = trackedTouch {
            if touches.count == 1 && touches.first === existing {
                // Duplicate delivery of the exact same touch from `UIGestureRecognizer` + `UIResponder`
                return
            }
            // Multi-touch overlap inside the candidate scroll view cancels single-finger brake-tap
            trackedTouch = nil
            invalidated = true
            return
        }
        guard isDecelerating, touches.count == 1, let t = touches.first else {
            trackedTouch = nil
            invalidated = false
            return
        }
        trackedTouch = t
        startPoint = t.location(in: scrollView)
        startUptime = ProcessInfo.processInfo.systemUptime
        invalidated = false
    }

    func handleMoved(_ touches: Set<UITouch>, in scrollView: UIScrollView) {
        guard let tracked = trackedTouch, !invalidated else { return }
        for t in touches where t === tracked {
            let pt = t.location(in: scrollView)
            if hypot(pt.x - startPoint.x, pt.y - startPoint.y) > 8.0 {
                invalidated = true
            }
        }
    }

    func consumeIfEligibleOnLift(_ touches: Set<UITouch>, in scrollView: UIScrollView, isDragging: Bool) -> CGPoint? {
        guard let tracked = trackedTouch else { return nil }
        guard touches.contains(where: { $0 === tracked }) else { return nil }
        let wasInvalidated = invalidated
        let pt = tracked.location(in: scrollView)
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        let moved = hypot(pt.x - startPoint.x, pt.y - startPoint.y)
        trackedTouch = nil
        invalidated = false
        guard !wasInvalidated, !isDragging, elapsed <= 0.26, moved <= 8.0 else {
            return nil
        }
        return pt
    }

    func consumePendingIfEligibleForRollover(in scrollView: UIScrollView, isDragging: Bool) -> CGPoint? {
        guard let tracked = trackedTouch, !invalidated else { return nil }
        let pt = tracked.location(in: scrollView)
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        let moved = hypot(pt.x - startPoint.x, pt.y - startPoint.y)
        trackedTouch = nil
        invalidated = true
        guard !isDragging, elapsed <= 0.26, moved <= 8.0 else {
            return nil
        }
        return pt
    }

    func handleCancelled(_ touches: Set<UITouch>) {
        guard let tracked = trackedTouch else { return }
        if touches.contains(where: { $0 === tracked }) {
            trackedTouch = nil
            invalidated = false
        }
    }
}

/// Dedicated horizontal scroll view for the top candidate strip.
///
/// By default in UIKit, `UIScrollView.touchesShouldCancel(in:)` returns `false` whenever `view is UIControl`!
/// Because `CandidateBarView` sets `delaysContentTouches = false` (for `0 ms` instant tap responsiveness)
/// and renders every candidate as a `UIButton`, a plain `UIScrollView` refuses to cancel button touches
/// on horizontal drag (`候选栏滑不动`). Overriding `touchesShouldCancel(in:) -> true` lets `panGestureRecognizer`
/// smoothly cancel any touched `UIButton` the instant a horizontal swipe begins!
internal final class CandidateScrollView: UIScrollView {
    var onDecelerationBrakeTap: ((CGPoint) -> Void)?
    var onRawTouchesBegan: ((Set<UITouch>) -> Void)?
    var onRawTouchesMoved: ((Set<UITouch>) -> Void)?
    var onRawTouchesEnded: ((Set<UITouch>) -> Void)?
    var onRawTouchesCancelled: ((Set<UITouch>) -> Void)?
    internal var simulatedDeceleratingForTesting = false
    internal let brakeTapGestureRecognizer = DecelerationBrakeTapGestureRecognizer(target: nil, action: nil)
    private let brakeTracker = DecelerationBrakeTracker()

    override init(frame: CGRect) {
        super.init(frame: frame)
        installBrakeTapRecognizer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installBrakeTapRecognizer() {
        brakeTapGestureRecognizer.onTouchesBegan = { [weak self] touches in
            guard let self else { return }
            self.onRawTouchesBegan?(touches)
            self.brakeTracker.handleBegan(touches, in: self, isDecelerating: self.isDecelerating)
        }
        brakeTapGestureRecognizer.onTouchesMoved = { [weak self] touches in
            guard let self else { return }
            self.onRawTouchesMoved?(touches)
            self.brakeTracker.handleMoved(touches, in: self)
        }
        brakeTapGestureRecognizer.onTouchesEnded = { [weak self] touches in
            guard let self else { return }
            self.onRawTouchesEnded?(touches)
            if let pt = self.brakeTracker.consumeIfEligibleOnLift(touches, in: self, isDragging: self.isDragging) {
                self.onDecelerationBrakeTap?(pt)
            }
        }
        brakeTapGestureRecognizer.onTouchesCancelled = { [weak self] touches in
            guard let self else { return }
            self.onRawTouchesCancelled?(touches)
            self.brakeTracker.handleCancelled(touches)
        }
        addGestureRecognizer(brakeTapGestureRecognizer)
    }

    var hasPendingBrakeTouch: Bool {
        brakeTracker.hasPendingTouch
    }

    func resetBrakeTouchTracking() {
        brakeTracker.reset()
    }

    func consumePendingBrakeTapPointForRollover() -> CGPoint? {
        brakeTracker.consumePendingIfEligibleForRollover(in: self, isDragging: isDragging)
    }

    override var isDecelerating: Bool {
        simulatedDeceleratingForTesting || super.isDecelerating
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if !animated {
            simulatedDeceleratingForTesting = false
        }
        super.setContentOffset(contentOffset, animated: animated)
    }

    override func touchesShouldBegin(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) -> Bool {
        true
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleBegan(touches, in: self, isDecelerating: isDecelerating)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleMoved(touches, in: self)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let tapPoint = brakeTracker.consumeIfEligibleOnLift(touches, in: self, isDragging: isDragging)
        super.touchesEnded(touches, with: event)
        if let tapPoint {
            onDecelerationBrakeTap?(tapPoint)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleCancelled(touches)
        super.touchesCancelled(touches, with: event)
    }
}

internal final class CandidateGridVerticalScrollView: UIScrollView {
    var onDecelerationBrakeTap: ((CGPoint) -> Void)?
    internal var simulatedDeceleratingForTesting = false
    internal let brakeTapGestureRecognizer = DecelerationBrakeTapGestureRecognizer(target: nil, action: nil)
    private let brakeTracker = DecelerationBrakeTracker()

    override init(frame: CGRect) {
        super.init(frame: frame)
        installBrakeTapRecognizer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installBrakeTapRecognizer() {
        brakeTapGestureRecognizer.onTouchesBegan = { [weak self] touches in
            guard let self else { return }
            self.brakeTracker.handleBegan(touches, in: self, isDecelerating: self.isDecelerating)
        }
        brakeTapGestureRecognizer.onTouchesMoved = { [weak self] touches in
            guard let self else { return }
            self.brakeTracker.handleMoved(touches, in: self)
        }
        brakeTapGestureRecognizer.onTouchesEnded = { [weak self] touches in
            guard let self else { return }
            if let pt = self.brakeTracker.consumeIfEligibleOnLift(touches, in: self, isDragging: self.isDragging) {
                self.onDecelerationBrakeTap?(pt)
            }
            DispatchQueue.main.async { [weak self] in
                self?.snapNegativeOverscrollIfIdle()
            }
        }
        brakeTapGestureRecognizer.onTouchesCancelled = { [weak self] touches in
            guard let self else { return }
            self.brakeTracker.handleCancelled(touches)
            DispatchQueue.main.async { [weak self] in
                self?.snapNegativeOverscrollIfIdle()
            }
        }
        addGestureRecognizer(brakeTapGestureRecognizer)
    }

    func snapNegativeOverscrollIfIdle() {
        let minY = -contentInset.top
        if !isTracking && !isDragging && !isDecelerating && contentOffset.y < minY {
            setContentOffset(CGPoint(x: 0.0, y: minY), animated: false)
        }
    }

    func resetBrakeTouchTracking() {
        brakeTracker.reset()
    }

    override var isDecelerating: Bool {
        simulatedDeceleratingForTesting || super.isDecelerating
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if !animated {
            simulatedDeceleratingForTesting = false
        }
        super.setContentOffset(contentOffset, animated: animated)
    }

    override func touchesShouldBegin(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) -> Bool {
        true
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleBegan(touches, in: self, isDecelerating: isDecelerating)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleMoved(touches, in: self)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let tapPoint = brakeTracker.consumeIfEligibleOnLift(touches, in: self, isDragging: isDragging)
        super.touchesEnded(touches, with: event)
        if let tapPoint {
            onDecelerationBrakeTap?(tapPoint)
        }
        snapNegativeOverscrollIfIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        brakeTracker.handleCancelled(touches)
        super.touchesCancelled(touches, with: event)
        snapNegativeOverscrollIfIdle()
    }
}

/// Records scroll callbacks in memory and emits at most four progress events per second.
private struct CandidateScrollTrace {
    let horizontal: Bool
    let touch: UInt64
    let start: TimeInterval
    let origin: CGFloat
    var last: TimeInterval?
    var lastReport: TimeInterval
    var updates = 0
    var largestGap = 0.0

    init?(horizontal: Bool, scroll: UIScrollView, count: Int) {
        let logger = LokeyDiagnosticLogger.shared
        guard logger.canRecordInteractions else { return nil }
        self.horizontal = horizontal
        touch = logger.currentActiveTouchSeq
        start = CACurrentMediaTime()
        lastReport = start
        origin = horizontal ? scroll.contentOffset.x : scroll.contentOffset.y
        let content = horizontal ? scroll.contentSize.width : scroll.contentSize.height
        let viewport = horizontal ? scroll.bounds.width : scroll.bounds.height
        logger.recordCandidateBarEventFast(
            touchSeq: touch,
            isScrollPanStart: horizontal,
            isGridPanStart: !horizontal,
            event: .scrollStart(horizontal: horizontal, origin: origin, content: content, viewport: viewport, count: count)
        )
    }

    mutating func moved(_ scroll: UIScrollView) {
        let now = CACurrentMediaTime()
        if let last { largestGap = max(largestGap, now - last) }
        last = now
        updates += 1
        if now - lastReport >= 0.25 {
            lastReport = now
            record(scroll.isDecelerating ? "惯性中" : "移动中", scroll)
        }
    }

    func record(_ phase: StaticString, _ scroll: UIScrollView) {
        let offset = horizontal ? scroll.contentOffset.x : scroll.contentOffset.y
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            touchSeq: touch,
            event: .scrollProgress(
                horizontal: horizontal,
                phase: phase,
                offset: offset,
                delta: offset - origin,
                elapsedMs: (CACurrentMediaTime() - start) * 1000,
                updates: updates,
                maxGapMs: largestGap * 1000
            )
        )
    }
}

/// Pixel-calibrated iOS 26 top candidate bar:
/// - **Composing mode**: Candidate #0 highlighted in a crisp `11pt` continuous soft-white squircle pill (`36.5pt` tall with `8.0pt` top Liquid Glass whitespace and `8.0pt` bottom whitespace above Row 0) + `20pt` regular (`22.5pt` Emoji) candidates + right `|` divider & `⌄` chevron.
/// - **Idle Chinese mode**: Predictive starter / user-frequent words at `41.1pt` native single-char pitch without pill highlight + right `|` divider & `⌄` chevron, matching native iOS 26 1:1.
final class CandidateBarView: UIView, UIScrollViewDelegate {
    var beforeHitTest: (() -> Void)?
    var onSelectCandidate: ((Int) -> Void)?
    private(set) var isSelectingDisplayedCandidate = false
    private var scrollInteractionInProgress = false
    var onInteractionEnded: (() -> Void)?

    private func dispatchDisplayedCandidate(_ index: Int) {
        consumeCurrentEpochTouchesAndAdvance()
        isSelectingDisplayedCandidate = true
        defer { isSelectingDisplayedCandidate = false }
        onSelectCandidate?(index)
    }
    var onDeleteCandidate: ((Int) -> Void)?
    var onToggleExpandGrid: (() -> Void)?
    private(set) var arrowDownTime: CFTimeInterval?

    private let composingContainer = UIView()
    private let scrollView = CandidateScrollView()
    private let pillHighlightView = UIView()
    private let rightSeparator = UIView()
    private let expandButton = UIButton(type: .custom)
    private let noticeLabel = UILabel()

    private final class CandidatePoolButton: UIButton {
        let poolSlot: Int
        var preferredTitleMidY: CGFloat?

        init(poolSlot: Int) {
            self.poolSlot = poolSlot
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
            let ins = titleEdgeInsets
            let h = max(0.0, contentRect.height - ins.top - ins.bottom)
            let y: CGFloat
            if let midY = preferredTitleMidY, contentRect.height > 0 {
                y = midY - h * 0.5
            } else {
                y = contentRect.minY + ins.top
            }
            return CGRect(
                x: contentRect.minX + ins.left,
                y: y,
                width: max(0.0, contentRect.width - ins.left - ins.right),
                height: h
            )
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: 0.0, dy: -9.0).contains(point)
        }
    }

    private struct ButtonRenderState: Equatable {
        let title: String
        let mode: UInt8 // 0 = normal, 1 = highlightedPill, 2 = quickPunct, 3 = leadingUnpill
        let shiftX: CGFloat
        let isEmoji: Bool
        let dark: Bool
    }

    private struct CandidateSlotLayout: Equatable {
        let minX: CGFloat
        let width: CGFloat
        let mode: UInt8
        let isEmoji: Bool
        let shiftX: CGFloat

        var maxX: CGFloat { minX + width }
    }

    internal struct VerticalMetrics: Equatable {
        let topInset: CGFloat
        let pillHeight: CGFloat
        let pillCornerRadius: CGFloat
        let pillCenterY: CGFloat
        let idleOpticalCenterY: CGFloat
        let composingOpticalCenterY: CGFloat

        func opticalCenterY(highlightFirst: Bool) -> CGFloat {
            highlightFirst ? composingOpticalCenterY : idleOpticalCenterY
        }
    }

    private var currentCandidates: [LokeyCandidate] = []
    internal var displayedCandidates: [LokeyCandidate] { currentCandidates }
    private var isGridExpanded: Bool = false
    private var lastRenderedChevronExpanded: Bool?
    private var lastAppliedShowsRightAccessory: Bool?
    private var lastRenderedCount: Int = 0
    private var lastShowsRightAccessoryFlag: Bool = true
    private var lastRenderedHighlightFirst: Bool?
    private var lastAppliedVerticalMetrics: VerticalMetrics?
    private var lastLaidOutHighlightFirst: Bool?
    private var lastSyncedViewportWidth: CGFloat = -1
    private var lastScrollActivityNoteUptime: TimeInterval = 0
    private var isApplyingProgrammaticUpdate: Bool = false
    private var slotLayouts: [CandidateSlotLayout] = []
    private var minimumSlotWidth: CGFloat = 0
    private var candToSlot: [Int] = []
    private var slotBoundCand: [Int] = []
    private var renderedWindowRange: Range<Int> = 0..<0
    private var lastLaidOutBarSize: CGSize = .zero
    private var lastLaidOutShowsAccessory: Bool?
    private var buttonRenderStates: [ButtonRenderState?] = []

    var hostScreenSize: CGSize = .zero {
        didSet {
            if oldValue != hostScreenSize {
                setNeedsLayout()
            }
        }
    }

    static let maxDisplayCandidates = 96
    static let minPillWidth: CGFloat = 44.0
    private static let initialPoolSize = 12
    private static let maxPoolSize = 44
    static let candidateFont = UIFont.systemFont(ofSize: 20.0, weight: .regular)
    static let emojiCandidateFont = UIFont.systemFont(ofSize: 22.5, weight: .regular)
    private static let candidateFontAttrs: [NSAttributedString.Key: Any] = [.font: candidateFont]
    private static let emojiCandidateFontAttrs: [NSAttributedString.Key: Any] = [.font: emojiCandidateFont]
    private static var titleWidthGen0: [String: CGFloat] = [:]
    private static var titleWidthGen1: [String: CGFloat] = [:]
    private static var emojiWidthGen0: [String: CGFloat] = [:]
    private static var emojiWidthGen1: [String: CGFloat] = [:]

    /// Verified monospaced CJK Unified Ideograph (`U+4E00...U+9FFF`) advance in `candidateFont`.
    /// Validated once against CoreText `size(withAttributes:)` across lengths 1..8 so pure-Hanzi
    /// candidates measure in `~3ns` with zero `NSString` bridging or cache eviction cliffs.
    private static let verifiedCJKUnitWidth: CGFloat? = {
        let w1 = ("我" as NSString).size(withAttributes: candidateFontAttrs).width
        guard w1 > 10.0 else { return nil }
        for probe in ["国", "永", "的", "一"] {
            let pw = (probe as NSString).size(withAttributes: candidateFontAttrs).width
            if abs(pw - w1) > 0.001 { return nil }
        }
        for len in 1...8 {
            let s = String(repeating: "我", count: len)
            let measured = ceil((s as NSString).size(withAttributes: candidateFontAttrs).width)
            if measured != ceil(CGFloat(len) * w1) { return nil }
        }
        return w1
    }()

    static func isEmojiSurface(_ text: String) -> Bool {
        for cu in text.utf16 {
            if cu < 0x2000 || (cu >= 0x4E00 && cu <= 0x9FFF) {
                continue
            }
            for sc in text.unicodeScalars {
                if (sc.value >= 0x1F000 && sc.value <= 0x1FAFF)
                    || sc.properties.isEmojiPresentation
                    || sc.value == 0xFE0F {
                    return true
                }
            }
            return false
        }
        return false
    }

    static func clearCachesForMemoryWarning() {
        titleWidthGen0.removeAll(keepingCapacity: false)
        titleWidthGen1.removeAll(keepingCapacity: false)
        emojiWidthGen0.removeAll(keepingCapacity: false)
        emojiWidthGen1.removeAll(keepingCapacity: false)
    }

    fileprivate static func cachedTitleWidth(for text: String, isEmoji: Bool) -> CGFloat {
        if isEmoji {
            if let hit = emojiWidthGen0[text] { return hit }
            if let hit = emojiWidthGen1[text] {
                if emojiWidthGen0.count >= 512 {
                    emojiWidthGen1 = emojiWidthGen0
                    emojiWidthGen0.removeAll(keepingCapacity: true)
                }
                emojiWidthGen0[text] = hit
                return hit
            }
            let w = ceil((text as NSString).size(withAttributes: emojiCandidateFontAttrs).width)
            if emojiWidthGen0.count >= 512 {
                emojiWidthGen1 = emojiWidthGen0
                emojiWidthGen0.removeAll(keepingCapacity: true)
            }
            emojiWidthGen0[text] = w
            return w
        }
        if let unitW = verifiedCJKUnitWidth {
            let u16 = text.utf16
            let n = u16.count
            if n >= 1 && n <= 16 {
                var allStandardCJK = true
                for cu in u16 {
                    if cu < 0x4E00 || cu > 0x9FFF {
                        allStandardCJK = false
                        break
                    }
                }
                if allStandardCJK {
                    return ceil(CGFloat(n) * unitW)
                }
            }
        }
        if let hit = titleWidthGen0[text] { return hit }
        if let hit = titleWidthGen1[text] {
            if titleWidthGen0.count >= 2048 {
                titleWidthGen1 = titleWidthGen0
                titleWidthGen0.removeAll(keepingCapacity: true)
            }
            titleWidthGen0[text] = hit
            return hit
        }
        let w = ceil((text as NSString).size(withAttributes: candidateFontAttrs).width)
        if titleWidthGen0.count >= 2048 {
            titleWidthGen1 = titleWidthGen0
            titleWidthGen0.removeAll(keepingCapacity: true)
        }
        titleWidthGen0[text] = w
        return w
    }

    private static let chevronDownImage = UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
    )?.withRenderingMode(.alwaysTemplate)
    private static let chevronUpImage = UIImage(
        systemName: "chevron.up",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
    )?.withRenderingMode(.alwaysTemplate)

    private struct RescuableCandidateTap {
        let index: Int
        let title: String
        let startOffsetX: CGFloat
        let touchDownUptime: TimeInterval
    }

    /// Zero-delay touch record captured directly from `CandidateScrollView`'s passive gesture recognizer
    /// (immune to `_UISystemGestureGateGestureRecognizer` hold-back near left/right screen edges `x <= ~31pt`).
    /// Prevents delayed `UIControl` touch replays (`+3..80ms` after finger lift) from double-committing
    /// newly populated associative candidates (`联想候选`, e.g. `"喊了"` -> `"我"`, `"这么早"` -> `"期的"`).
    private struct TrackedBarTouch {
        let id: ObjectIdentifier
        weak var touch: UITouch?
        var commitEpochAtBegan: UInt64
        var beganUptime: TimeInterval
        var startPointInScroll: CGPoint
        var startOffsetX: CGFloat
        var initialCandidateIndex: Int
        var initialCandidateTitle: String
        var movedBeyondSlop: Bool
        var endedOrCancelled: Bool
        var consumed: Bool
    }

    private static let maxTrackedBarTouches = 16

    private var buttonPool: [CandidatePoolButton] = []
    private var longPressPool: [UILongPressGestureRecognizer] = []
    private var isHighlightFirstActive: Bool = false
    private var isContentScrollable: Bool = false
    private var pendingCandidateIndex: Int?
    private var pendingTouchStartOffsetX: CGFloat = 0
    private var pendingTouchDownUptime: TimeInterval = 0
    private var rescuableTap: RescuableCandidateTap?
    private var trackedBarTouches: [TrackedBarTouch] = []
    private var commitEpoch: UInt64 = 0
    private var lastCandidateCommitUptime: TimeInterval = -10
    private var lastBrakeTapCommitUptime: TimeInterval = -10
    private var scrollTrace: CandidateScrollTrace?
    private var activeDownButtons = Set<Int>()
    // A release belongs to the candidate seen on touch-down, even if the button was rebound.
    private var pressedCandidateBySlot: [Int: Int] = [:]
    private var invalidatedHeldButtons = Set<Int>()
    private var didTriggerLongPressDelete: Bool = false
    private var didToggleExpandOnCurrentPress: Bool = false
    private(set) var lastHitTestDidSeamPassThrough: Bool = false

    var hasActiveTouch: Bool {
        scrollInteractionInProgress || !activeDownButtons.isEmpty || !pressedCandidateBySlot.isEmpty || pendingCandidateIndex != nil || rescuableTap != nil || isScrollPanActive
    }

    /// Updated on every active letter/backspace touch-down in `KeyGridView` so upward-drifting Row-0
    /// thumb strikes (`q w e r t y u i o p`) during `< 220ms` rapid typing bursts pass cleanly to `KeyGridView`!
    var lastKeyTapUptime: TimeInterval = -10

    var candidateScrollView: UIScrollView { scrollView }
    var expandAccessoryButton: UIButton { expandButton }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardTheme.hitTestableClearBacking
        clipsToBounds = true
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        setupComposingBar()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupComposingBar() {
        _ = Self.chevronDownImage
        _ = Self.chevronUpImage
        composingContainer.backgroundColor = .clear
        composingContainer.clipsToBounds = true
        composingContainer.isHidden = true
        addSubview(composingContainer)

        expandButton.isExclusiveTouch = false
        // Luminance-matched 1/255 backing keeps `expandButton` hit-testable across the full
        // accessory rect in `CARenderServer` with `0/255` composited RGB delta over Liquid Glass.
        expandButton.backgroundColor = KeyboardTheme.hitTestableClearBacking
        expandButton.imageEdgeInsets = .zero
        expandButton.addTarget(self, action: #selector(handleExpandTouchDown), for: .touchDown)
        expandButton.addTarget(self, action: #selector(handleExpandTap), for: .touchUpInside)
        expandButton.addTarget(self, action: #selector(handleExpandTouchDone), for: [.touchCancel, .touchUpOutside])
        composingContainer.addSubview(expandButton)

        rightSeparator.backgroundColor = KeyboardTheme.dynamicCandidateDivider
        composingContainer.addSubview(rightSeparator)

        scrollView.delegate = self
        scrollView.isMultipleTouchEnabled = true
        scrollView.isExclusiveTouch = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        // Must remain `false` on a 1D horizontal strip (`contentSize.height == 0`):
        // With `isDirectionalLockEnabled = true`, any swipe whose initial thumb contact has `|dy| >= |dx|`
        // (e.g. touching near the top edge `y = 3pt` and curving slightly downward) locks UIKit's pan gesture
        // onto the dead vertical axis for the entire swipe (`Δx = 0.0` across 750ms!).
        scrollView.isDirectionalLockEnabled = false
        scrollView.decelerationRate = .normal
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.clipsToBounds = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 6.5, bottom: 0, right: 8.0)
        KeyboardTheme.disableScrollEdgeEffects(on: scrollView)
        trackedBarTouches.reserveCapacity(Self.maxTrackedBarTouches)
        scrollView.onRawTouchesBegan = { [weak self] touches in
            self?.recordRawTouchesBegan(touches)
        }
        scrollView.onRawTouchesMoved = { [weak self] touches in
            self?.recordRawTouchesMoved(touches)
        }
        scrollView.onRawTouchesEnded = { [weak self] touches in
            self?.recordRawTouchesEnded(touches)
        }
        scrollView.onRawTouchesCancelled = { [weak self] touches in
            self?.recordRawTouchesCancelled(touches)
        }
        scrollView.onDecelerationBrakeTap = { [weak self] ptInScroll in
            self?.handleDecelerationBrakeTap(at: ptInScroll)
        }
        let bgTap = UITapGestureRecognizer(target: self, action: #selector(handleScrollBackgroundTap(_:)))
        bgTap.cancelsTouchesInView = false
        bgTap.delaysTouchesBegan = false
        bgTap.delaysTouchesEnded = false
        scrollView.addGestureRecognizer(bgTap)
        composingContainer.addSubview(scrollView)

        pillHighlightView.isUserInteractionEnabled = false
        pillHighlightView.layer.cornerRadius = 11.0
        pillHighlightView.layer.cornerCurve = .continuous
        pillHighlightView.layer.shadowOpacity = 0
        pillHighlightView.isHidden = true
        scrollView.addSubview(pillHighlightView)

        ensurePoolCapacity(Self.initialPoolSize)

        noticeLabel.font = .systemFont(ofSize: 14, weight: .medium)
        noticeLabel.textColor = KeyboardTheme.dynamicSecondaryText
        noticeLabel.textAlignment = .center
        noticeLabel.isHidden = true
        composingContainer.addSubview(noticeLabel)

        syncVerticalMetricsIfNeeded()
    }

    internal static func computeVerticalMetrics(
        width: CGFloat,
        height: CGFloat,
        screenSize: CGSize = .zero
    ) -> VerticalMetrics {
        let effW = width > 0 ? width : 393.0
        let defaultH = KeyboardTheme.portraitCandidateBarHeight(forWidth: effW, screenSize: screenSize)
        let h = height > 0 ? height : defaultH
        let isCompactLandscapeBar = effW > 520.0 && h < 42.0
        // Self-contained vertical geometry with 0.0pt idle-to-composing optical shift and zero top overflow:
        // - Always reserve `3.5pt` bottom clearance so combined with `KeyGridView.topGap == 4.5pt`,
        //   `row0KeyTop - pill.maxY == 8.0pt` on Max/Plus/Pro (`44pt`), Mini/SE (`41pt`), and landscape (`36pt`).
        // - Unifies `idleOpticalCenterY` and `composingOpticalCenterY` at `pillCenterY`.
        let bottomClearance: CGFloat = 3.5
        let pillBottom: CGFloat = max(24.5, h - bottomClearance)
        let minTopInset: CGFloat = isCompactLandscapeBar
            ? 3.0
            : (h >= 40.0
                ? min(8.0, max(5.5, (h - 32.0) * 0.5))
                : max(2.0, (h - 25.5) * 0.35))
        let pillH: CGFloat = min(36.5, max(22.5, pillBottom - minTopInset))
        let topInset: CGFloat = max(minTopInset, pillBottom - pillH)
        let pillCenterY: CGFloat = topInset + pillH * 0.5
        let cornerRadius: CGFloat
        if pillH >= 34.0 {
            cornerRadius = 11.0
        } else if pillH >= 30.0 {
            cornerRadius = 10.0
        } else {
            cornerRadius = 8.5
        }
        return VerticalMetrics(
            topInset: topInset,
            pillHeight: pillH,
            pillCornerRadius: cornerRadius,
            pillCenterY: pillCenterY,
            idleOpticalCenterY: pillCenterY,
            composingOpticalCenterY: pillCenterY
        )
    }

    private func computeVerticalMetrics() -> VerticalMetrics {
        Self.computeVerticalMetrics(width: bounds.width, height: bounds.height, screenSize: hostScreenSize)
    }

    @discardableResult
    private func syncVerticalMetricsIfNeeded() -> VerticalMetrics {
        let m = computeVerticalMetrics()
        let effW = bounds.width > 0 ? bounds.width : 393.0
        let effH = bounds.height > 0 ? bounds.height : KeyboardTheme.portraitCandidateBarHeight(forWidth: effW, screenSize: hostScreenSize)
        let targetSize = CGSize(width: effW, height: effH)
        let showsAcc = lastAppliedShowsRightAccessory ?? true
        let metricsChanged = (lastAppliedVerticalMetrics != m)
        let highlightChanged = (lastLaidOutHighlightFirst != isHighlightFirstActive)
        let opticalY = m.opticalCenterY(highlightFirst: isHighlightFirstActive)
        if metricsChanged
            || highlightChanged
            || lastLaidOutBarSize != targetSize
            || lastLaidOutShowsAccessory != showsAcc
            || composingContainer.frame.size != targetSize {
            lastLaidOutBarSize = targetSize
            lastLaidOutShowsAccessory = showsAcc
            lastLaidOutHighlightFirst = isHighlightFirstActive
            composingContainer.frame = CGRect(origin: .zero, size: targetSize)

            // Keep `expandButton` strictly inside `CandidateBarView.bounds` (`0 .. effH`) so it NEVER
            // intrudes into `KeyGridView` above `'p'`/`'o'`, while centering the chevron optically on `opticalY`.
            let accessoryW: CGFloat = 44.5
            let sepW: CGFloat = 0.67
            let desiredHalfSep: CGFloat = effH >= 40.0 ? 14.5 : (effH >= 35.0 ? 13.0 : 12.0)
            expandButton.frame = CGRect(x: effW - accessoryW, y: 0.0, width: accessoryW, height: effH)
            let offset = 2.0 * opticalY - effH
            let targetInsets = UIEdgeInsets(top: max(0.0, offset), left: 0.0, bottom: max(0.0, -offset), right: 0.0)
            if expandButton.contentEdgeInsets != targetInsets {
                expandButton.contentEdgeInsets = targetInsets
                expandButton.setNeedsLayout()
            }
            let sepMinY = max(0.3, opticalY - desiredHalfSep)
            let sepMaxY = min(m.topInset + m.pillHeight, opticalY + desiredHalfSep)
            rightSeparator.frame = CGRect(
                x: effW - accessoryW - sepW,
                y: sepMinY,
                width: sepW,
                height: max(12.0, sepMaxY - sepMinY)
            )
            let scrollW = max(0.0, showsAcc ? (effW - accessoryW - sepW) : effW)
            let targetScrollFrame = CGRect(x: 0.0, y: m.topInset, width: scrollW, height: m.pillHeight)
            if scrollView.frame != targetScrollFrame {
                let wasProg = isApplyingProgrammaticUpdate
                isApplyingProgrammaticUpdate = true
                scrollView.frame = targetScrollFrame
                isApplyingProgrammaticUpdate = wasProg
            }
            noticeLabel.frame = CGRect(x: 16.0, y: m.topInset, width: max(0.0, effW - 32.0), height: m.pillHeight)
        }
        guard metricsChanged || highlightChanged else { return m }
        lastAppliedVerticalMetrics = m
        pillHighlightView.layer.cornerRadius = m.pillCornerRadius
        pillHighlightView.frame.size.height = m.pillHeight
        let baseMidInBtn = opticalY - m.topInset
        for btn in buttonPool where !btn.isHidden {
            btn.frame.size.height = m.pillHeight
            let isEmoji = (btn.tag >= 0 && btn.tag < slotLayouts.count) ? slotLayouts[btn.tag].isEmoji : false
            let targetMid = isEmoji ? max(9.5, baseMidInBtn) : baseMidInBtn
            if btn.preferredTitleMidY != targetMid {
                btn.preferredTitleMidY = targetMid
                btn.setNeedsLayout()
            }
        }
        return m
    }

    private func ensurePoolCapacity(_ capacity: Int) {
        guard capacity > buttonPool.count else { return }
        buttonPool.reserveCapacity(capacity)
        longPressPool.reserveCapacity(capacity)
        for idx in buttonPool.count..<capacity {
            let btn = CandidatePoolButton(poolSlot: idx)
            btn.tag = -1
            btn.isExclusiveTouch = false
            btn.titleLabel?.font = Self.candidateFont
            btn.titleLabel?.textAlignment = .center
            btn.titleLabel?.lineBreakMode = .byClipping
            btn.layer.cornerRadius = 11.0
            btn.layer.cornerCurve = .continuous
            btn.layer.shadowOpacity = 0
            btn.addTarget(self, action: #selector(handleCandidateTouchDown(_:forEvent:)), for: .touchDown)
            btn.addTarget(self, action: #selector(handleCandidateButtonTap(_:forEvent:)), for: .touchUpInside)
            btn.addTarget(self, action: #selector(handleCandidateTouchCancel(_:)), for: .touchCancel)
            btn.addTarget(self, action: #selector(handleCandidateTouchUpOutside(_:)), for: .touchUpOutside)

            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleCandidateLongPress(_:)))
            lp.minimumPressDuration = 0.45
            lp.isEnabled = false
            btn.addGestureRecognizer(lp)

            btn.isHidden = true
            scrollView.addSubview(btn)
            slotBoundCand.append(-1)
            buttonRenderStates.append(nil)
            buttonPool.append(btn)
            longPressPool.append(lp)
        }
    }

    // Size for the active viewport window (`+80pt` on keystroke, wider `+236pt` during horizontal scroll).
    private func preparePool(forViewportWidth width: CGFloat) {
        guard minimumSlotWidth > 0 else { return }
        let extraSpan: CGFloat = (isScrollPanActive || scrollView.contentOffset.x > 4.0) ? (96.0 + 140.0) : 80.0
        let windowWidth = width + extraSpan
        let capacity = min(Self.maxPoolSize, min(slotLayouts.count, Int(ceil(windowWidth / minimumSlotWidth)) + 2) + 2)
        ensurePoolCapacity(capacity)
    }

    override func layoutSubviews() {
        if bounds.height > 420.0 || (superview?.bounds.height ?? 0.0) > 420.0 {
            super.layoutSubviews()
            return
        }
        let m = syncVerticalMetricsIfNeeded()
        super.layoutSubviews()
        let w = scrollView.bounds.width
        if w > 0, abs(w - lastSyncedViewportWidth) > 1.0 {
            lastSyncedViewportWidth = w
            if !slotLayouts.isEmpty {
                preparePool(forViewportWidth: w)
                syncVisibleWindow(forceReconfigureBound: false, verticalMetrics: m)
            }
            let totalWidth = scrollView.contentSize.width + scrollView.contentInset.left + scrollView.contentInset.right
            let scrollable = !slotLayouts.isEmpty && totalWidth > w + 1.0
            if isContentScrollable != scrollable {
                isContentScrollable = scrollable
                if scrollView.alwaysBounceHorizontal != scrollable {
                    scrollView.alwaysBounceHorizontal = scrollable
                }
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        lastHitTestDidSeamPassThrough = false
        guard bounds.contains(point), isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        beforeHitTest?()
        guard !composingContainer.isHidden else { return nil }
        let accessoryColW: CGFloat = isGridExpanded ? 44.5 : 41.5
        let overAccessoryColumn = point.x >= bounds.maxX - accessoryColW && point.x < bounds.maxX && point.x >= bounds.minX
        // Calibrated bottom-rim seam protection:
        // - Over Primary Candidate Pill #0 (`x <= pillMaxX + 4pt` when unscrolled): uses a tight `0.18s` burst window
        //   so intentional candidate `#0` taps right after typing (`+200..400ms`, including lower-third thumb taps at
        //   `y = 35..43pt` in `48pt` mode or `y = 26.5pt` in `31pt` mode) NEVER miss or fall through to `'q'`/`'w'`.
        // - Over secondary candidates (`x > pillMaxX`, directly above Row-0 `e r t y u i o`): widens active composing
        //   protection to `0.42s` so upward-drifting right-thumb strikes during continuous typing route cleanly to Row 0.
        let isOverRightAccessory = !expandButton.isHidden && overAccessoryColumn
        if isGridExpanded {
            return isOverRightAccessory ? expandButton : nil
        }
        if !isOverRightAccessory {
            let vMetrics = computeVerticalMetrics()
            let pillBottom = vMetrics.topInset + vMetrics.pillHeight
            let primaryPill = composingPillFrameInBar
            let isOverPrimaryPill = (lastRenderedHighlightFirst == true)
                && !pillHighlightView.isHidden
                && scrollView.contentOffset.x <= 4.0
                && point.x <= primaryPill.maxX + 4.0
            let activeBurstWindow: TimeInterval = (lastRenderedHighlightFirst == true && !isOverPrimaryPill) ? 0.42 : 0.18
            let isActiveBurst = (ProcessInfo.processInfo.systemUptime - lastKeyTapUptime) < activeBurstWindow
            let burstRimInset: CGFloat = (bounds.height >= 38.0 || !isOverPrimaryPill) ? 5.5 : 3.0
            let seamCutoffY: CGFloat = isActiveBurst
                ? max(vMetrics.pillCenterY + 4.0, pillBottom - burstRimInset)
                : min(bounds.height - 1.5, pillBottom + 1.0)
            if point.y >= seamCutoffY {
                lastHitTestDidSeamPassThrough = true
                return nil
            }
        } else {
            // Protect Row-0 `'p'`/`'o'` both during rapid typing bursts (`< 0.45s`, whether idle or composing)
            // and on word-initial bottom-seam strikes while keeping the chevron body (`y = 0..37pt` on `48pt` bar,
            // `y = 0..25.5pt` on `31pt` bar) responsive and giving full accessory height once `isGridExpanded`.
            if !isGridExpanded {
                let inBurst = (ProcessInfo.processInfo.systemUptime - lastKeyTapUptime) < 0.45
                let bottomRim: CGFloat = inBurst
                    ? (bounds.height >= 44.0 ? 11.0 : (bounds.height >= 38.0 ? 8.5 : 5.5))
                    : (bounds.height >= 38.0 ? 3.5 : 1.5)
                if point.y >= bounds.height - bottomRim {
                    lastHitTestDidSeamPassThrough = true
                    return nil
                }
            }
            return expandButton
        }
        guard let hit = super.hitTest(point, with: event) else {
            return nil
        }
        if hit is UIControl {
            return hit
        }
        // Snap taps in the `8.0pt` top margin, `6.5pt` left inset, or inter-button gaps to the nearest visible candidate button!
        let ptInScroll = convert(point, to: scrollView)
        var nearestBtn: UIButton?
        var nearestDist: CGFloat = 14.0
        for btn in buttonPool where !btn.isHidden {
            let dx: CGFloat
            if ptInScroll.x < btn.frame.minX {
                dx = btn.frame.minX - ptInScroll.x
            } else if ptInScroll.x > btn.frame.maxX {
                dx = ptInScroll.x - btn.frame.maxX
            } else {
                dx = 0
            }
            if dx < nearestDist {
                nearestDist = dx
                nearestBtn = btn
            }
        }
        if let nearestBtn {
            return nearestBtn
        }
        if hit === scrollView || hit.isDescendant(of: scrollView) || (point.y >= 0 && point.x < bounds.width - accessoryColW) {
            return scrollView
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            KeyboardTheme.disableScrollEdgeEffects(on: scrollView)
            disableAncestorGestureTouchDelays()
            applyTheme()
        } else {
            didToggleExpandOnCurrentPress = false
            arrowDownTime = nil
            resetTouchTracking()
        }
    }

    func resetTouchTracking() {
        scrollTrace?.record("跟踪结束", scrollView)
        scrollTrace = nil
        scrollInteractionInProgress = false
        activeDownButtons.removeAll(keepingCapacity: true)
        pressedCandidateBySlot.removeAll(keepingCapacity: true)
        invalidatedHeldButtons.removeAll(keepingCapacity: true)
        pendingCandidateIndex = nil
        rescuableTap = nil
        trackedBarTouches.removeAll(keepingCapacity: true)
        commitEpoch &+= 1
        didTriggerLongPressDelete = false
        scrollView.resetBrakeTouchTracking()
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
    }

    private func disableAncestorGestureTouchDelays() {
        var cur: UIView? = self
        while let v = cur {
            for gr in v.gestureRecognizers ?? [] {
                Self.disarmTouchDelaysIfSupported(gr)
            }
            cur = v.superview
        }
        for gr in window?.gestureRecognizers ?? [] {
            Self.disarmTouchDelaysIfSupported(gr)
        }
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyTheme()
        }
    }

    // MARK: - Testing & Inspection Support

    func candidateButton(at index: Int) -> UIButton {
        precondition(index >= 0 && index < Self.maxDisplayCandidates, "Candidate button index \(index) out of bounds")
        if index < slotLayouts.count {
            let existingSlot = candToSlot[index]
            if existingSlot >= 0 {
                return buttonPool[existingSlot]
            }
            let slot = acquirePoolSlotForOnDemandCandidate(index)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let dark = traitCollection.userInterfaceStyle == .dark
            let vMetrics = syncVerticalMetricsIfNeeded()
            applyCandidateToSlot(
                slot: slot,
                candIdx: index,
                dark: dark,
                vMetrics: vMetrics,
                primaryText: KeyboardTheme.dynamicPrimaryText,
                highlightText: dark ? .white : .black
            )
            CATransaction.commit()
            return buttonPool[slot]
        }
        return buttonPool[index % buttonPool.count]
    }

    var composingPillFrame: CGRect {
        pillHighlightView.isHidden ? .zero : pillHighlightView.frame
    }

    /// Returns Pill #0's frame in `CandidateBarView` coordinates (`minY == 8.0pt` in `48.0pt` portrait mode).
    var composingPillFrameInBar: CGRect {
        guard !pillHighlightView.isHidden else { return .zero }
        if scrollView.frame.height > 0 {
            return convert(pillHighlightView.frame, from: scrollView)
        }
        let m = computeVerticalMetrics()
        return CGRect(
            x: pillHighlightView.frame.minX + scrollView.contentInset.left,
            y: m.topInset,
            width: pillHighlightView.frame.width,
            height: pillHighlightView.frame.height
        )
    }

    var expandAccessoryWidth: CGFloat {
        expandButton.bounds.width > 0 ? expandButton.bounds.width : 44.5
    }

    var rightSeparatorFrameInBar: CGRect {
        composingContainer.convert(rightSeparator.frame, to: self)
    }

    var expandChevronCenterYInBar: CGFloat {
        expandButton.layoutIfNeeded()
        if let iv = expandButton.imageView, iv.bounds.height > 0 {
            return expandButton.convert(iv.frame, to: self).midY
        }
        let contentRect = expandButton.contentRect(forBounds: expandButton.bounds)
        return expandButton.convert(contentRect, to: self).midY
    }

    func candidateGlyphCenterYInBar(at index: Int) -> CGFloat {
        let btn = candidateButton(at: index)
        btn.layoutIfNeeded()
        if let tl = btn.titleLabel {
            return btn.convert(tl.frame, to: self).midY
        }
        return convert(btn.frame, from: scrollView).midY
    }

    func returnToLeadingCandidateForTyping() {
        guard !hasActiveTouch, !isActivelyDraggingScroll,
              scrollView.contentOffset.x > -scrollView.contentInset.left + 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: -scrollView.contentInset.left, y: 0), animated: false)
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
    }

    // MARK: - Public Updates

    func update(decode: DecodeResult, expanded: Bool) {
        update(candidates: decode.candidates, highlightFirst: true, expanded: expanded, showsRightAccessory: true)
    }

    func update(
        candidates: [LokeyCandidate],
        highlightFirst: Bool,
        expanded: Bool,
        showsRightAccessory: Bool = true,
        preservingScrollOffset: Bool = false
    ) {
        let previousCandidates = self.currentCandidates
        self.currentCandidates = candidates
        self.isGridExpanded = expanded
        self.isHighlightFirstActive = highlightFirst

        // Only invalidate an in-progress finger press if the candidate text under that button ACTUALLY changed!
        // Preserving unchanged held buttons eliminates dropped candidate taps when async IPC/context callbacks refresh UI mid-tap.
        for heldIdx in activeDownButtons {
            let sameSurface = heldIdx >= 0
                && heldIdx < previousCandidates.count
                && heldIdx < candidates.count
                && previousCandidates[heldIdx].text == candidates[heldIdx].text
                && previousCandidates[heldIdx].consumedInputCount == candidates[heldIdx].consumedInputCount
            if !sameSurface {
                invalidatedHeldButtons.insert(heldIdx)
                if pendingCandidateIndex == heldIdx {
                    pendingCandidateIndex = nil
                }
            }
        }
        if let pIdx = pendingCandidateIndex {
            let validPending = pIdx >= 0
                && pIdx < previousCandidates.count
                && pIdx < candidates.count
                && previousCandidates[pIdx].text == candidates[pIdx].text
            if !validPending {
                pendingCandidateIndex = nil
            }
        }
        if let rt = rescuableTap {
            if rt.index < 0 || rt.index >= candidates.count || candidates[rt.index].text != rt.title {
                rescuableTap = nil
            }
        }

        let hasCandidates = !candidates.isEmpty
        composingContainer.isHidden = !hasCandidates

        guard hasCandidates else {
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            syncVerticalMetricsIfNeeded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pillHighlightView.isHidden = true
            for slot in buttonPool.indices where slotBoundCand[slot] >= 0 || !buttonPool[slot].isHidden {
                unbindPoolSlot(slot)
            }
            CATransaction.commit()
            activeDownButtons.removeAll(keepingCapacity: true)
            pressedCandidateBySlot.removeAll(keepingCapacity: true)
            invalidatedHeldButtons.removeAll(keepingCapacity: true)
            pendingCandidateIndex = nil
            rescuableTap = nil
            if !previousCandidates.isEmpty {
                consumeCurrentEpochTouchesAndAdvance()
            }
            slotLayouts.removeAll(keepingCapacity: true)
            candToSlot.removeAll(keepingCapacity: true)
            renderedWindowRange = 0..<0
            lastRenderedCount = 0
            lastRenderedHighlightFirst = nil
            if scrollView.contentSize != .zero {
                scrollView.contentSize = .zero
            }
            isContentScrollable = false
            if scrollView.alwaysBounceHorizontal {
                scrollView.alwaysBounceHorizontal = false
            }
            if !isActivelyDraggingScroll {
                LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
            }
            return
        }

        let count = min(Self.maxDisplayCandidates, candidates.count)
        let prevCount = min(Self.maxDisplayCandidates, previousCandidates.count)
        var isSameSurfaceList = (count == lastRenderedCount)
            && (count == prevCount)
            && (lastRenderedHighlightFirst == highlightFirst)
            && (lastAppliedShowsRightAccessory == showsRightAccessory)
        if isSameSurfaceList {
            for i in 0..<count where previousCandidates[i].text != candidates[i].text {
                isSameSurfaceList = false
                break
            }
        }
        let didChangeRenderedList = !isSameSurfaceList

        if lastAppliedShowsRightAccessory != showsRightAccessory {
            lastAppliedShowsRightAccessory = showsRightAccessory
            expandButton.isHidden = !showsRightAccessory
            syncVerticalMetricsIfNeeded()
        }
        scrollView.isHidden = expanded
        rightSeparator.isHidden = expanded || !showsRightAccessory

        let dark = traitCollection.userInterfaceStyle == .dark
        if showsRightAccessory {
            updateExpandChevron()
        }

        if isSameSurfaceList {
            for slot in buttonPool.indices where slotBoundCand[slot] >= 0 {
                let enabled = candidates[slotBoundCand[slot]].isDeletableUserPhrase
                if longPressPool[slot].isEnabled != enabled { longPressPool[slot].isEnabled = enabled }
            }
            return
        }
        let availScrollWidth = scrollView.bounds.width > 0
            ? scrollView.bounds.width
            : max(200.0, (bounds.width > 0 ? bounds.width : 393.0) - (showsRightAccessory ? 45.5 : 0.0))
        lastRenderedCount = count
        lastShowsRightAccessoryFlag = showsRightAccessory
        lastRenderedHighlightFirst = highlightFirst

        // Precompute exact horizontal geometry for ALL `0..<count` candidates upfront in pure value math (`< 3µs`).
        // `scrollView.contentSize` is 100% final immediately — zero mid-drag `contentSize` jump and zero 36-item scroll wall!
        slotLayouts.removeAll(keepingCapacity: true)
        if slotLayouts.capacity < count {
            slotLayouts.reserveCapacity(count)
        }
        var cursorX: CGFloat = 0.0
        minimumSlotWidth = .greatestFiniteMagnitude
        for idx in 0..<count {
            let text = candidates[idx].text
            let isEmoji = Self.isEmojiSurface(text)
            let mode: UInt8
            let leftPad: CGFloat
            let rightPad: CGFloat
            let trailingStep: CGFloat
            let shiftX: CGFloat
            if idx == 0 && highlightFirst {
                mode = 1
                leftPad = 6.5
                rightPad = 6.5
                trailingStep = 9.0
                shiftX = 0.0
            } else if !showsRightAccessory {
                mode = 2
                leftPad = (idx == 0) ? 3.5 : 8.5
                rightPad = (idx == count - 1) ? 6.0 : 8.5
                trailingStep = 3.5
                let targetFont = isEmoji ? Self.emojiCandidateFont : Self.candidateFont
                let optX = KeyboardTheme.opticalHorizontalOffset(for: text, font: targetFont)
                shiftX = (leftPad - rightPad) * 0.5 + optX
            } else if !highlightFirst && idx == 0 {
                mode = 3
                leftPad = 3.7
                rightPad = 9.3
                trailingStep = 2.5
                shiftX = (leftPad - rightPad) * 0.5
            } else if highlightFirst {
                mode = 0
                leftPad = isEmoji ? 7.5 : 8.5
                rightPad = isEmoji ? 7.5 : 8.5
                trailingStep = 2.5
                shiftX = 0.0
            } else {
                mode = 0
                leftPad = isEmoji ? 8.0 : 9.3
                rightPad = isEmoji ? 8.0 : 9.3
                trailingStep = 2.5
                shiftX = 0.0
            }
            let rawBtnW = Self.cachedTitleWidth(for: text, isEmoji: isEmoji) + leftPad + rightPad
            let btnW = (mode == 1 || (mode == 0 && highlightFirst)) ? max(Self.minPillWidth, rawBtnW) : rawBtnW
            minimumSlotWidth = min(minimumSlotWidth, btnW)
            slotLayouts.append(
                CandidateSlotLayout(
                    minX: cursorX,
                    width: btnW,
                    mode: mode,
                    isEmoji: isEmoji,
                    shiftX: shiftX
                )
            )
            cursorX += btnW + (idx + 1 < count ? trailingStep : 0.0)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isApplyingProgrammaticUpdate = true

        preparePool(forViewportWidth: availScrollWidth)

        // Synchronize `candToSlot` atomically with `slotLayouts` BEFORE mutating `scrollView.contentSize` / `contentOffset`
        // (which synchronously fire `scrollViewDidScroll` in UIKit!).
        if candToSlot.count < count {
            for i in 0..<candToSlot.count { candToSlot[i] = -1 }
            candToSlot.append(contentsOf: repeatElement(-1, count: count - candToSlot.count))
        } else {
            if candToSlot.count > count {
                candToSlot.removeSubrange(count..<candToSlot.count)
            }
            for i in 0..<count {
                candToSlot[i] = -1
            }
        }
        for slot in buttonPool.indices {
            let oldCand = slotBoundCand[slot]
            if oldCand >= 0 {
                if oldCand < count {
                    candToSlot[oldCand] = slot
                } else {
                    unbindPoolSlot(slot)
                }
            }
        }

        let vMetrics = syncVerticalMetricsIfNeeded()
        if highlightFirst, let s0 = slotLayouts.first {
            pillHighlightView.backgroundColor = KeyboardTheme.candidateHighlightPillFill(dark: dark)
            pillHighlightView.frame = CGRect(x: s0.minX, y: 0.0, width: s0.width, height: vMetrics.pillHeight)
            if pillHighlightView.isHidden {
                pillHighlightView.isHidden = false
            }
        } else if !pillHighlightView.isHidden {
            pillHighlightView.isHidden = true
        }

        let previousOffset = scrollView.contentOffset.x
        let targetContentSize = CGSize(width: cursorX, height: 0)
        if scrollView.contentSize != targetContentSize {
            scrollView.contentSize = targetContentSize
        }
        if didChangeRenderedList && activeDownButtons.isEmpty && !isScrollPanActive {
            let leading = -scrollView.contentInset.left
            let trailing = max(leading, cursorX + scrollView.contentInset.right - availScrollWidth)
            let x = preservingScrollOffset ? min(max(previousOffset, leading), trailing) : leading
            let targetOffset = CGPoint(x: x, y: 0)
            if abs(scrollView.contentOffset.x - targetOffset.x) > 0.5 {
                scrollView.setContentOffset(targetOffset, animated: false)
            }
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        }
        let totalWidth = cursorX + scrollView.contentInset.left + scrollView.contentInset.right
        self.isContentScrollable = totalWidth > availScrollWidth + 1.0
        if scrollView.alwaysBounceHorizontal != isContentScrollable {
            scrollView.alwaysBounceHorizontal = isContentScrollable
        }

        isApplyingProgrammaticUpdate = false
        syncVisibleWindow(forceReconfigureBound: true, verticalMetrics: vMetrics)
        CATransaction.commit()
    }

    // MARK: - 120Hz Virtualized Candidate Windowing

    @inline(__always)
    private func isSlotPinned(slot: Int, candIdx: Int) -> Bool {
        pressedCandidateBySlot[slot] != nil || activeDownButtons.contains(candIdx) || pendingCandidateIndex == candIdx
    }

    private func unbindPoolSlot(_ slot: Int) {
        let oldCand = slotBoundCand[slot]
        if oldCand >= 0 && oldCand < candToSlot.count && candToSlot[oldCand] == slot {
            candToSlot[oldCand] = -1
        }
        slotBoundCand[slot] = -1
        let btn = buttonPool[slot]
        btn.tag = -1
        if longPressPool[slot].isEnabled {
            longPressPool[slot].isEnabled = false
        }
        if !btn.isHidden {
            btn.isHidden = true
        }
    }

    private func acquirePoolSlotForOnDemandCandidate(_ candIdx: Int) -> Int {
        for slot in buttonPool.indices where slotBoundCand[slot] == -1 && pressedCandidateBySlot[slot] == nil {
            slotBoundCand[slot] = candIdx
            candToSlot[candIdx] = slot
            return slot
        }
        // Fallback when all 32 slots are occupied: evict the non-pinned slot furthest from viewport center.
        let viewMidX = scrollView.contentOffset.x + max(180.0, scrollView.bounds.width * 0.5)
        var bestSlot = 0
        var bestScore: CGFloat = -1.0
        for slot in buttonPool.indices {
            let c = slotBoundCand[slot]
            if c >= 0, !isSlotPinned(slot: slot, candIdx: c), c != 0 {
                let midX = c < slotLayouts.count ? (slotLayouts[c].minX + slotLayouts[c].width * 0.5) : 0.0
                let outsideBonus: CGFloat = renderedWindowRange.contains(c) ? 0.0 : 100_000.0
                let dist = abs(midX - viewMidX) + outsideBonus
                if dist > bestScore {
                    bestScore = dist
                    bestSlot = slot
                }
            }
        }
        let oldCand = slotBoundCand[bestSlot]
        if oldCand >= 0 && oldCand < candToSlot.count && candToSlot[oldCand] == bestSlot {
            candToSlot[oldCand] = -1
        }
        slotBoundCand[bestSlot] = candIdx
        candToSlot[candIdx] = bestSlot
        return bestSlot
    }

    private func applyCandidateToSlot(
        slot: Int,
        candIdx: Int,
        dark: Bool,
        vMetrics: VerticalMetrics,
        primaryText: UIColor,
        highlightText: UIColor
    ) {
        let layout = slotLayouts[candIdx]
        let cand = currentCandidates[candIdx]
        let btn = buttonPool[slot]
        if btn.tag != candIdx {
            btn.tag = candIdx
        }
        let nextState = ButtonRenderState(
            title: cand.text,
            mode: layout.mode,
            shiftX: layout.shiftX,
            isEmoji: layout.isEmoji,
            dark: dark
        )
        if buttonRenderStates[slot] != nextState {
            let previous = buttonRenderStates[slot]
            buttonRenderStates[slot] = nextState
            if previous?.isEmoji != nextState.isEmoji {
                btn.titleLabel?.font = layout.isEmoji ? Self.emojiCandidateFont : Self.candidateFont
            }
            if previous?.title != cand.text { btn.setTitle(cand.text, for: .normal) }
            if previous?.mode != layout.mode || previous?.dark != dark {
                btn.setTitleColor(layout.mode == 1 ? highlightText : primaryText, for: .normal)
            }
            if previous?.shiftX != layout.shiftX || previous?.mode != layout.mode {
                let shift = layout.mode == 1 ? 0 : layout.shiftX
                if previous != nil || shift != 0 {
                    btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: shift, bottom: 0, right: -shift)
                }
            }
        }
        let baseMidInBtn = vMetrics.opticalCenterY(highlightFirst: isHighlightFirstActive) - vMetrics.topInset
        let targetMidInBtn = layout.isEmoji ? max(9.5, baseMidInBtn) : baseMidInBtn
        if btn.preferredTitleMidY != targetMidInBtn {
            btn.preferredTitleMidY = targetMidInBtn
            btn.setNeedsLayout()
        }
        let targetFrame = CGRect(x: layout.minX, y: 0.0, width: layout.width, height: vMetrics.pillHeight)
        if btn.frame != targetFrame {
            btn.frame = targetFrame
        }
        if longPressPool[slot].isEnabled != cand.isDeletableUserPhrase {
            longPressPool[slot].isEnabled = cand.isDeletableUserPhrase
        }
        if btn.isHidden {
            btn.isHidden = false
        }
    }

    private func syncVisibleWindow(forceReconfigureBound: Bool, verticalMetrics: VerticalMetrics? = nil) {
        let count = slotLayouts.count
        guard count > 0, candToSlot.count == count else {
            renderedWindowRange = 0..<0
            return
        }
        let availScrollWidth = scrollView.bounds.width > 0
            ? scrollView.bounds.width
            : max(200.0, (bounds.width > 0 ? bounds.width : 393.0) - (lastShowsRightAccessoryFlag ? 45.5 : 0.0))
        if scrollView.bounds.width > 0 {
            lastSyncedViewportWidth = scrollView.bounds.width
        }

        let offsetX = scrollView.contentOffset.x
        let isScrollingHorizontally = isScrollPanActive || offsetX > 4.0
        if !forceReconfigureBound && !renderedWindowRange.isEmpty,
           let last = renderedWindowRange.last, last < count {
            let first = renderedWindowRange.lowerBound
            let leftCovered = first == 0 || slotLayouts[first].minX <= offsetX - 24
            let lastSlot = slotLayouts[last]
            let rightMargin: CGFloat = isScrollingHorizontally ? 32.0 : 20.0
            let rightCovered = last == count - 1 || lastSlot.minX + lastSlot.width >= offsetX + availScrollWidth + rightMargin
            if leftCovered && rightCovered { return }
        }
        let minVisX = offsetX - (isScrollingHorizontally ? 96.0 : 16.0)
        let maxVisX = offsetX + availScrollWidth + (isScrollingHorizontally ? 140.0 : 80.0)

        // Binary search `startIdx` (`maxX >= minVisX`) and `endIdx` (`minX <= maxVisX`) in `O(log N)` (~7 comparisons).
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if slotLayouts[mid].maxX < minVisX {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let startIdx = min(lo, count - 1)

        var rLo = startIdx
        var rHi = count
        while rLo < rHi {
            let mid = (rLo + rHi) >> 1
            if slotLayouts[mid].minX <= maxVisX {
                rLo = mid + 1
            } else {
                rHi = mid
            }
        }
        let endIdx = max(startIdx + 1, rLo)
        let newRange = startIdx..<endIdx

        if !forceReconfigureBound && newRange == renderedWindowRange {
            return
        }
        renderedWindowRange = newRange

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let neededSlots = min(Self.maxPoolSize, newRange.count + pressedCandidateBySlot.count + 2)
        if neededSlots > buttonPool.count {
            ensurePoolCapacity(neededSlots)
        }

        let vMetrics = verticalMetrics ?? syncVerticalMetricsIfNeeded()
        let dark = traitCollection.userInterfaceStyle == .dark
        let primaryText = KeyboardTheme.dynamicPrimaryText
        let highlightText: UIColor = dark ? .white : .black

        var evictableVisibleSlots: [Int] = []
        var freeHiddenSlots: [Int] = []
        evictableVisibleSlots.reserveCapacity(8)
        freeHiddenSlots.reserveCapacity(buttonPool.count)

        for slot in buttonPool.indices {
            let c = slotBoundCand[slot]
            if c == -1 {
                if pressedCandidateBySlot[slot] == nil { freeHiddenSlots.append(slot) }
            } else if !newRange.contains(c) && !isSlotPinned(slot: slot, candIdx: c) {
                evictableVisibleSlots.append(slot)
            } else if forceReconfigureBound && !newRange.contains(c) && c < count {
                applyCandidateToSlot(
                    slot: slot,
                    candIdx: c,
                    dark: dark,
                    vMetrics: vMetrics,
                    primaryText: primaryText,
                    highlightText: highlightText
                )
            }
        }

        var evictCursor = 0
        var freeCursor = 0

        for candIdx in newRange {
            let existingSlot = candToSlot[candIdx]
            if existingSlot >= 0 {
                if forceReconfigureBound {
                    applyCandidateToSlot(
                        slot: existingSlot,
                        candIdx: candIdx,
                        dark: dark,
                        vMetrics: vMetrics,
                        primaryText: primaryText,
                        highlightText: highlightText
                    )
                }
                continue
            }

            let targetSlot: Int
            if evictCursor < evictableVisibleSlots.count {
                targetSlot = evictableVisibleSlots[evictCursor]
                evictCursor += 1
                let prevCand = slotBoundCand[targetSlot]
                if prevCand >= 0 && prevCand < candToSlot.count && candToSlot[prevCand] == targetSlot {
                    candToSlot[prevCand] = -1
                }
            } else if freeCursor < freeHiddenSlots.count {
                targetSlot = freeHiddenSlots[freeCursor]
                freeCursor += 1
            } else {
                break
            }

            slotBoundCand[targetSlot] = candIdx
            candToSlot[candIdx] = targetSlot
            applyCandidateToSlot(
                slot: targetSlot,
                candIdx: candIdx,
                dark: dark,
                vMetrics: vMetrics,
                primaryText: primaryText,
                highlightText: highlightText
            )
        }

        while evictCursor < evictableVisibleSlots.count {
            unbindPoolSlot(evictableVisibleSlots[evictCursor])
            evictCursor += 1
        }
    }

    func flashDeletedNotice() {
        noticeLabel.text = "已从个人词库移除"
        noticeLabel.isHidden = false
        scrollView.alpha = 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) {
                self.noticeLabel.isHidden = true
                self.scrollView.alpha = 1.0
            }
        }
    }

    // MARK: - Styling

    func setGridExpanded(_ expanded: Bool) {
        guard isGridExpanded != expanded || lastRenderedChevronExpanded != expanded else { return }
        isGridExpanded = expanded
        scrollView.isHidden = expanded
        rightSeparator.isHidden = expanded || (lastAppliedShowsRightAccessory != true)
        updateExpandChevron()
    }

    func trimUnusedPoolIfIdle() {
        guard !hasActiveTouch, !isScrollPanActive, pressedCandidateBySlot.isEmpty else { return }
        let keepCount = max(Self.initialPoolSize, currentCandidates.isEmpty ? 0 : (renderedWindowRange.count + 2))
        guard buttonPool.count > keepCount else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for slot in buttonPool.indices {
            let c = slotBoundCand[slot]
            if c >= 0 && (currentCandidates.isEmpty || !renderedWindowRange.contains(c)) {
                unbindPoolSlot(slot)
            }
        }

        if !currentCandidates.isEmpty {
            let vMetrics = syncVerticalMetricsIfNeeded()
            let dark = traitCollection.userInterfaceStyle == .dark
            let primaryText = KeyboardTheme.dynamicPrimaryText
            let highlightText: UIColor = dark ? .white : .black
            var lowCursor = 0
            for highSlot in keepCount..<buttonPool.count {
                let candIdx = slotBoundCand[highSlot]
                guard candIdx >= 0 else { continue }
                while lowCursor < keepCount && slotBoundCand[lowCursor] >= 0 {
                    lowCursor += 1
                }
                guard lowCursor < keepCount else { return }
                unbindPoolSlot(highSlot)
                slotBoundCand[lowCursor] = candIdx
                if candIdx < candToSlot.count {
                    candToSlot[candIdx] = lowCursor
                }
                applyCandidateToSlot(
                    slot: lowCursor,
                    candIdx: candIdx,
                    dark: dark,
                    vMetrics: vMetrics,
                    primaryText: primaryText,
                    highlightText: highlightText
                )
                lowCursor += 1
            }
        }

        for slot in keepCount..<buttonPool.count where slotBoundCand[slot] >= 0 {
            return
        }
        for slot in keepCount..<buttonPool.count {
            buttonPool[slot].removeFromSuperview()
        }
        buttonPool.removeSubrange(keepCount..<buttonPool.count)
        longPressPool.removeSubrange(keepCount..<longPressPool.count)
        slotBoundCand.removeSubrange(keepCount..<slotBoundCand.count)
        buttonRenderStates.removeSubrange(keepCount..<buttonRenderStates.count)
    }

    internal var poolCapacityForTesting: Int { buttonPool.count }

    private func updateExpandChevron() {
        if lastRenderedChevronExpanded != isGridExpanded {
            lastRenderedChevronExpanded = isGridExpanded
            expandButton.setImage(isGridExpanded ? Self.chevronUpImage : Self.chevronDownImage, for: .normal)
        }
        expandButton.tintColor = KeyboardTheme.dynamicCandidateChevron
    }

    private func applyTheme() {
        noticeLabel.textColor = KeyboardTheme.dynamicSecondaryText
        rightSeparator.backgroundColor = KeyboardTheme.dynamicCandidateDivider
        scrollView.isHidden = isGridExpanded
        rightSeparator.isHidden = isGridExpanded || (lastAppliedShowsRightAccessory != true)
        updateExpandChevron()
        if !slotLayouts.isEmpty {
            let dark = traitCollection.userInterfaceStyle == .dark
            if isHighlightFirstActive && !pillHighlightView.isHidden {
                pillHighlightView.backgroundColor = KeyboardTheme.candidateHighlightPillFill(dark: dark)
            }
            syncVisibleWindow(forceReconfigureBound: true)
        }
    }

    // MARK: - UIScrollViewDelegate (Horizontal Candidate Strip Telemetry & Micro-Roll Tap Rescue)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollInteractionInProgress = true
        invalidatedHeldButtons.formUnion(activeDownButtons)
        pendingCandidateIndex = nil
        lastScrollActivityNoteUptime = ProcessInfo.processInfo.systemUptime
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(true, owner: self)
        scrollTrace?.record("被新拖动中断", scrollView)
        scrollTrace = CandidateScrollTrace(horizontal: true, scroll: scrollView, count: currentCandidates.count)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingProgrammaticUpdate else { return }
        if !slotLayouts.isEmpty {
            syncVisibleWindow(forceReconfigureBound: false)
        }
        scrollTrace?.moved(scrollView)
        if isScrollPanActive {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastScrollActivityNoteUptime >= 0.08 {
                lastScrollActivityNoteUptime = now
                LokeyDiagnosticLogger.shared.noteScrollActivity()
            }
        }
        if let rt = rescuableTap, abs(scrollView.contentOffset.x - rt.startOffsetX) >= 11.5 {
            // Genuine horizontal scroll beyond micro-roll tolerance: clear tap rescue so swipe never selects a word.
            rescuableTap = nil
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollInteractionInProgress = decelerate
        defer { if !decelerate { onInteractionEnded?() } }
        scrollTrace?.record(decelerate ? "松手进入惯性" : "松手停稳", scrollView)
        if !decelerate { scrollTrace = nil }
        let endX = scrollView.contentOffset.x
        if let rt = rescuableTap {
            rescuableTap = nil
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - rt.touchDownUptime
            let offsetDelta = abs(endX - rt.startOffsetX)
            let panTransX = abs(scrollView.panGestureRecognizer.translation(in: self).x)
            let panVelX = abs(scrollView.panGestureRecognizer.velocity(in: self).x)
            if elapsed < 0.28
                && offsetDelta < 11.5
                && panTransX < 13.5
                && (!decelerate || panVelX < 140.0)
                && !didTriggerLongPressDelete
                && rt.index >= 0
                && rt.index < currentCandidates.count
                && currentCandidates[rt.index].text == rt.title {
                if decelerate {
                    scrollView.setContentOffset(CGPoint(x: rt.startOffsetX, y: 0), animated: false)
                }
                LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
                lastCandidateCommitUptime = now
                LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
                    isTapCommit: true,
                    event: .microRollRescue(rt.index, rt.title, offsetDelta)
                )
                scrollTrace?.record("轻微滑动救回选词", scrollView)
                scrollTrace = nil
                dispatchDisplayedCandidate(rt.index)
                return
            }
        }
        if !decelerate {
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollInteractionInProgress = false
        defer { onInteractionEnded?() }
        rescuableTap = nil
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        scrollTrace?.record("惯性结束", scrollView)
        scrollTrace = nil
    }

    // MARK: - Actions

    private var isActivelyDraggingScroll: Bool {
        let st = scrollView.panGestureRecognizer.state
        return st == .began || st == .changed || scrollView.isDragging
    }

    private var isScrollPanActive: Bool {
        isActivelyDraggingScroll || scrollView.isDecelerating
    }

    private func haltDecelerationIfNeeded() {
        if scrollView.isDecelerating {
            scrollTrace?.record("惯性被点停", scrollView)
            scrollTrace = nil
            scrollInteractionInProgress = false
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        }
    }

    // MARK: - Zero-Delay Touch Gate & Epoch Tracking

    private func consumeCurrentEpochTouchesAndAdvance() {
        for i in trackedBarTouches.indices where trackedBarTouches[i].commitEpochAtBegan == commitEpoch {
            trackedBarTouches[i].consumed = true
        }
        commitEpoch &+= 1
    }

    private func nearestVisibleCandidateIndex(atScrollPoint ptInScroll: CGPoint, maxDistance: CGFloat) -> Int? {
        var bestIdx: Int?
        var bestDist = maxDistance
        for btn in buttonPool where !btn.isHidden {
            let dx: CGFloat
            if ptInScroll.x < btn.frame.minX {
                dx = btn.frame.minX - ptInScroll.x
            } else if ptInScroll.x > btn.frame.maxX {
                dx = ptInScroll.x - btn.frame.maxX
            } else {
                dx = 0
            }
            if dx < bestDist {
                bestDist = dx
                bestIdx = btn.tag
            }
        }
        if let idx = bestIdx, idx >= 0, idx < currentCandidates.count {
            return idx
        }
        return nil
    }

    internal func recordRawTouchesBegan(_ touches: Set<UITouch>) {
        guard !touches.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let hasExistingActive = trackedBarTouches.contains(where: { entry in
            !entry.endedOrCancelled
                && !entry.consumed
                && entry.commitEpochAtBegan == commitEpoch
                && !touches.contains(where: { ObjectIdentifier($0) == entry.id })
        })
        if touches.count > 1 || hasExistingActive {
            for i in trackedBarTouches.indices where !trackedBarTouches[i].endedOrCancelled {
                trackedBarTouches[i].movedBeyondSlop = true
            }
        }
        for t in touches {
            let id = ObjectIdentifier(t)
            if let existingIdx = trackedBarTouches.firstIndex(where: { $0.id == id && !$0.endedOrCancelled && $0.touch === t }) {
                if touches.count > 1 {
                    trackedBarTouches[existingIdx].movedBeyondSlop = true
                }
                continue
            }
            let pt = t.location(in: scrollView)
            let candIdx = nearestVisibleCandidateIndex(atScrollPoint: pt, maxDistance: 14.0) ?? -1
            let candTitle = (candIdx >= 0 && candIdx < currentCandidates.count) ? currentCandidates[candIdx].text : ""
            let record = TrackedBarTouch(
                id: id,
                touch: t,
                commitEpochAtBegan: commitEpoch,
                beganUptime: now,
                startPointInScroll: pt,
                startOffsetX: scrollView.contentOffset.x,
                initialCandidateIndex: candIdx,
                initialCandidateTitle: candTitle,
                movedBeyondSlop: touches.count > 1 || hasExistingActive,
                endedOrCancelled: false,
                consumed: false
            )
            if let sameIDIdx = trackedBarTouches.firstIndex(where: { $0.id == id }) {
                trackedBarTouches[sameIDIdx] = record
            } else if trackedBarTouches.count >= Self.maxTrackedBarTouches {
                trackedBarTouches.removeFirst()
                trackedBarTouches.append(record)
            } else {
                trackedBarTouches.append(record)
            }
        }
    }

    internal func recordRawTouchesMoved(_ touches: Set<UITouch>) {
        let curOffsetX = scrollView.contentOffset.x
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let idx = trackedBarTouches.lastIndex(where: { $0.id == id }) else { continue }
            if trackedBarTouches[idx].movedBeyondSlop { continue }
            let pt = t.location(in: scrollView)
            let moved = hypot(pt.x - trackedBarTouches[idx].startPointInScroll.x, pt.y - trackedBarTouches[idx].startPointInScroll.y)
            if moved > 9.0 || abs(curOffsetX - trackedBarTouches[idx].startOffsetX) > 8.0 {
                trackedBarTouches[idx].movedBeyondSlop = true
            }
        }
    }

    internal func recordRawTouchesEnded(_ touches: Set<UITouch>) {
        let curOffsetX = scrollView.contentOffset.x
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let idx = trackedBarTouches.lastIndex(where: { $0.id == id }) else { continue }
            let pt = t.location(in: scrollView)
            let moved = hypot(pt.x - trackedBarTouches[idx].startPointInScroll.x, pt.y - trackedBarTouches[idx].startPointInScroll.y)
            if moved > 9.0 || abs(curOffsetX - trackedBarTouches[idx].startOffsetX) > 8.0 {
                trackedBarTouches[idx].movedBeyondSlop = true
            }
            trackedBarTouches[idx].endedOrCancelled = true
        }
    }

    internal func recordRawTouchesCancelled(_ touches: Set<UITouch>) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let idx = trackedBarTouches.lastIndex(where: { $0.id == id }) else { continue }
            trackedBarTouches[idx].movedBeyondSlop = true
            trackedBarTouches[idx].endedOrCancelled = true
            trackedBarTouches[idx].consumed = true
        }
    }

    private func shouldRejectControlTouchEvent(_ event: UIEvent?, for sender: UIButton, isTapCommit: Bool) -> Bool {
        guard let event else {
            // Synthetic `UIControl.sendActions(for:)` in unit tests passes `event == nil`.
            return false
        }
        let senderTouches = event.touches(for: sender)
        let relevantTouches: Set<UITouch>
        if let st = senderTouches, !st.isEmpty {
            relevantTouches = st
        } else if let all = event.allTouches, !all.isEmpty {
            relevantTouches = all
        } else {
            relevantTouches = []
        }
        for t in relevantTouches {
            let id = ObjectIdentifier(t)
            if let entry = trackedBarTouches.last(where: { $0.id == id && ($0.touch == nil || $0.touch === t) }) {
                if entry.consumed || entry.commitEpochAtBegan != commitEpoch {
                    return true
                }
            }
            // Hardware `UITouch.timestamp` (`systemUptime`) of any touch replayed by `_UISystemGestureGateGestureRecognizer`
            // after an earlier commit (e.g. `bgTap` `间隙容差命中候选` at `+0.3ms` on lift) is strictly `<= lastCandidateCommitUptime`.
            if lastCandidateCommitUptime > 0 && t.timestamp > 0 && t.timestamp <= lastCandidateCommitUptime + 0.002 {
                return true
            }
        }
        if isTapCommit {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCandidateCommitUptime <= 0.06 {
                return true
            }
        }
        return false
    }

    /// Flushes any in-flight non-panning candidate button touch-down before `KeyGridView` processes a subsequent keystroke,
    /// guaranteeing strict chronological ordering during rapid two-thumb rollover (Thumb 1 taps candidate -> Thumb 2 taps next letter)
    /// while never falsely committing during a horizontal candidate-bar scroll!
    func commitPendingCandidateTouchIfNeeded() {
        if pendingCandidateIndex == nil, let brakePt = scrollView.consumePendingBrakeTapPointForRollover() {
            handleDecelerationBrakeTap(at: brakePt)
            return
        }
        if let idx = pendingCandidateIndex,
           !invalidatedHeldButtons.contains(idx),
           !didTriggerLongPressDelete,
           idx >= 0,
           idx < currentCandidates.count {
            let scrollDelta = abs(scrollView.contentOffset.x - pendingTouchStartOffsetX)
            guard !isActivelyDraggingScroll, scrollDelta < 8.0 else {
                pendingCandidateIndex = nil
                return
            }
            let candText = currentCandidates[idx].text
            invalidatedHeldButtons.insert(idx)
            invalidatedHeldButtons.formUnion(activeDownButtons)
            pendingCandidateIndex = nil
            rescuableTap = nil
            scrollView.resetBrakeTouchTracking()
            haltDecelerationIfNeeded()
            lastCandidateCommitUptime = ProcessInfo.processInfo.systemUptime
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
                isTapCommit: true,
                event: .autoFlushedCandidate(idx, candText)
            )
            dispatchDisplayedCandidate(idx)
            return
        }
        // Left/right edge rollover protection: if `_UISystemGestureGateGestureRecognizer` is still withholding
        // `UIControl` `.touchDown` on Candidate #0 (`x <= ~31pt`) when the user's other thumb presses the next letter,
        // flush the unconsumed stationary touch from the current `commitEpoch` and mark it consumed so the later replay is ignored.
        guard !didTriggerLongPressDelete, !isActivelyDraggingScroll else { return }
        var gatedMatchIndex: Int?
        for i in trackedBarTouches.indices {
            let entry = trackedBarTouches[i]
            guard !entry.endedOrCancelled,
                  !entry.consumed,
                  !entry.movedBeyondSlop,
                  entry.commitEpochAtBegan == commitEpoch else { continue }
            if gatedMatchIndex != nil {
                return
            }
            gatedMatchIndex = i
        }
        guard let tIdx = gatedMatchIndex else { return }
        let entry = trackedBarTouches[tIdx]
        let idx = entry.initialCandidateIndex
        guard idx >= 0,
              idx < currentCandidates.count,
              currentCandidates[idx].text == entry.initialCandidateTitle,
              abs(scrollView.contentOffset.x - entry.startOffsetX) < 8.0 else {
            return
        }
        trackedBarTouches[tIdx].consumed = true
        invalidatedHeldButtons.insert(idx)
        invalidatedHeldButtons.formUnion(activeDownButtons)
        pendingCandidateIndex = nil
        rescuableTap = nil
        scrollView.resetBrakeTouchTracking()
        haltDecelerationIfNeeded()
        lastCandidateCommitUptime = ProcessInfo.processInfo.systemUptime
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            isTapCommit: true,
            event: .autoFlushedCandidate(idx, entry.initialCandidateTitle)
        )
        dispatchDisplayedCandidate(idx)
    }

    private func performExpandToggleNow() {
        defer { arrowDownTime = nil }
        rescuableTap = nil
        scrollView.resetBrakeTouchTracking()
        haltDecelerationIfNeeded()
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            event: .staticText(isGridExpanded ? "箭头按下 请求收起" : "箭头按下 请求展开")
        )
        onToggleExpandGrid?()
    }

    @objc private func handleExpandTouchDown() {
        arrowDownTime = CACurrentMediaTime()
        didToggleExpandOnCurrentPress = true
        performExpandToggleNow()
        didToggleExpandOnCurrentPress = true
    }

    @objc private func handleExpandTap() {
        if didToggleExpandOnCurrentPress {
            didToggleExpandOnCurrentPress = false
            return
        }
        if arrowDownTime == nil {
            arrowDownTime = CACurrentMediaTime()
        }
        performExpandToggleNow()
    }

    @objc private func handleExpandTouchDone() {
        didToggleExpandOnCurrentPress = false
        arrowDownTime = nil
    }

    @objc private func handleCandidateTouchDown(_ sender: UIButton, forEvent event: UIEvent?) {
        let idx = sender.tag
        guard let button = sender as? CandidatePoolButton,
              currentCandidates.indices.contains(idx),
              !shouldRejectControlTouchEvent(event, for: sender, isTapCommit: false) else { return }
        pressedCandidateBySlot[button.poolSlot] = idx
        invalidatedHeldButtons.remove(idx)
        let now = ProcessInfo.processInfo.systemUptime
        let startX = scrollView.contentOffset.x
        let candText = currentCandidates[idx].text
        activeDownButtons.insert(idx)
        pendingCandidateIndex = idx
        pendingTouchStartOffsetX = startX
        pendingTouchDownUptime = now
        rescuableTap = RescuableCandidateTap(
            index: idx,
            title: candText,
            startOffsetX: startX,
            touchDownUptime: now
        )
        didTriggerLongPressDelete = false
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            event: .pressedCandidate(idx, candText)
        )
    }

    @objc private func handleCandidateButtonTap(_ sender: UIButton, forEvent event: UIEvent?) {
        defer { onInteractionEnded?() }
        guard let button = sender as? CandidatePoolButton,
              let idx = pressedCandidateBySlot.removeValue(forKey: button.poolSlot) else { return }
        activeDownButtons.remove(idx)
        rescuableTap = nil
        scrollView.resetBrakeTouchTracking()
        if shouldRejectControlTouchEvent(event, for: sender, isTapCommit: true) {
            if pendingCandidateIndex == idx {
                pendingCandidateIndex = nil
            }
            return
        }
        if invalidatedHeldButtons.remove(idx) != nil || sender.tag != idx {
            if pendingCandidateIndex == idx {
                pendingCandidateIndex = nil
            }
            return
        }
        guard !didTriggerLongPressDelete else {
            didTriggerLongPressDelete = false
            pendingCandidateIndex = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBrakeTapCommitUptime > 0.06 else {
            pendingCandidateIndex = nil
            return
        }
        let hadPending = (pendingCandidateIndex == idx)
        let scrollDelta = abs(scrollView.contentOffset.x - pendingTouchStartOffsetX)
        pendingCandidateIndex = nil
        guard !isActivelyDraggingScroll, (!hadPending || scrollDelta < 12.0) else {
            return
        }
        guard idx >= 0, idx < currentCandidates.count else {
            return
        }
        let candText = currentCandidates[idx].text
        invalidatedHeldButtons.formUnion(activeDownButtons)
        haltDecelerationIfNeeded()
        lastCandidateCommitUptime = now
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            isTapCommit: true,
            event: .selectedCandidate(idx, candText)
        )
        dispatchDisplayedCandidate(idx)
    }

    @objc private func handleCandidateTouchCancel(_ sender: UIButton) {
        defer { onInteractionEnded?() }
        guard let button = sender as? CandidatePoolButton,
              let idx = pressedCandidateBySlot.removeValue(forKey: button.poolSlot) else { return }
        let wasPending = (pendingCandidateIndex == idx)
        activeDownButtons.remove(idx)
        invalidatedHeldButtons.remove(idx)
        if wasPending {
            pendingCandidateIndex = nil
            if didTriggerLongPressDelete {
                rescuableTap = nil
            } else if let tap = rescuableTap {
                // UIKit may deliver touchCancel just before scrollViewWillBeginDragging.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.scrollInteractionInProgress,
                          self.rescuableTap?.touchDownUptime == tap.touchDownUptime else { return }
                    self.rescuableTap = nil
                    self.onInteractionEnded?()
                }
            }
            if idx >= 0 && idx < currentCandidates.count {
                LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
                    event: .transferredToScroll(idx, currentCandidates[idx].text)
                )
            }
        }
        didTriggerLongPressDelete = false
    }

    @objc private func handleCandidateTouchUpOutside(_ sender: UIButton) {
        defer { onInteractionEnded?() }
        guard let button = sender as? CandidatePoolButton,
              let idx = pressedCandidateBySlot.removeValue(forKey: button.poolSlot) else { return }
        activeDownButtons.remove(idx)
        invalidatedHeldButtons.remove(idx)
        if pendingCandidateIndex == idx {
            pendingCandidateIndex = nil
        }
        rescuableTap = nil
        didTriggerLongPressDelete = false
    }

    private func selectNearestVisibleCandidate(
        atScrollPoint ptInScroll: CGPoint,
        maxDistance: CGFloat,
        logPrefix: StaticString,
        isBrakeTap: Bool = false
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !composingContainer.isHidden,
              !didTriggerLongPressDelete,
              now - lastCandidateCommitUptime > 0.06 else {
            return
        }
        var bestIdx: Int?
        var bestDist = maxDistance
        for btn in buttonPool where !btn.isHidden {
            let dx: CGFloat
            if ptInScroll.x < btn.frame.minX {
                dx = btn.frame.minX - ptInScroll.x
            } else if ptInScroll.x > btn.frame.maxX {
                dx = ptInScroll.x - btn.frame.maxX
            } else {
                dx = 0
            }
            if dx < bestDist {
                bestDist = dx
                bestIdx = btn.tag
            }
        }
        guard let idx = bestIdx, idx >= 0, idx < currentCandidates.count else { return }
        let candText = currentCandidates[idx].text
        haltDecelerationIfNeeded()
        lastCandidateCommitUptime = now
        if isBrakeTap {
            lastBrakeTapCommitUptime = now
        }
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            isTapCommit: true,
            event: .nearestCandidate(logPrefix, idx, candText)
        )
        dispatchDisplayedCandidate(idx)
    }

    private func handleDecelerationBrakeTap(at ptInScroll: CGPoint) {
        guard !isActivelyDraggingScroll else { return }
        scrollInteractionInProgress = false
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        defer { onInteractionEnded?() }
        invalidatedHeldButtons.formUnion(activeDownButtons)
        activeDownButtons.removeAll()
        pressedCandidateBySlot.removeAll(keepingCapacity: true)
        pendingCandidateIndex = nil
        rescuableTap = nil
        selectNearestVisibleCandidate(
            atScrollPoint: ptInScroll,
            maxDistance: 20.0,
            logPrefix: "惯性滑行制动点选命中候选",
            isBrakeTap: true
        )
    }

    @objc private func handleScrollBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        processScrollBackgroundGapTap(atScrollPoint: recognizer.location(in: scrollView))
    }

    internal func simulateBackgroundGapTapForTesting(atScrollPoint ptInScroll: CGPoint) {
        processScrollBackgroundGapTap(atScrollPoint: ptInScroll)
    }

    private func processScrollBackgroundGapTap(atScrollPoint ptInScroll: CGPoint) {
        guard !composingContainer.isHidden,
              activeDownButtons.isEmpty,
              pendingCandidateIndex == nil,
              rescuableTap == nil,
              !isActivelyDraggingScroll,
              !didTriggerLongPressDelete else {
            return
        }
        if !trackedBarTouches.isEmpty {
            let hasEligibleUnconsumedTouch = trackedBarTouches.contains(where: {
                !$0.consumed && !$0.movedBeyondSlop && $0.commitEpochAtBegan == commitEpoch
            })
            guard hasEligibleUnconsumedTouch else { return }
        }
        selectNearestVisibleCandidate(
            atScrollPoint: ptInScroll,
            maxDistance: 22.0,
            logPrefix: "间隙容差命中候选"
        )
    }

    @objc private func handleCandidateLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !isActivelyDraggingScroll, let btn = recognizer.view as? UIButton else { return }
        didTriggerLongPressDelete = true
        rescuableTap = nil
        invalidatedHeldButtons.insert(btn.tag)
        invalidatedHeldButtons.formUnion(activeDownButtons)
        pendingCandidateIndex = nil
        haltDecelerationIfNeeded()
        onDeleteCandidate?(btn.tag)
    }
}

// MARK: - Expanded Full-Area Multi-Row Candidate Grid

final class ExpandedCandidateGridView: UIView, UIScrollViewDelegate {
    enum FilterTab: Int, CaseIterable {
        case all = 0
        case pinyin = 1
        case radical = 2
        case stroke = 3

        var title: String {
            switch self {
            case .all: return "全部"
            case .pinyin: return "拼音"
            case .radical: return "部首"
            case .stroke: return "笔画"
            }
        }
    }

    enum StrokeFilterChip: Equatable {
        case all
        case bucket(HanziMetadataTable.StrokeBucket)
        case exact(Int)

        var title: String {
            switch self {
            case .all: return "全部"
            case let .bucket(b): return b.title
            case let .exact(n): return "\(n)画"
            }
        }
    }

    var onSelectCandidate: ((Int) -> Void)?
    var onSelectExplicitCandidate: ((LokeyCandidate, LokeyCandidate?) -> Void)?
    var filterCatalogProvider: (() -> LokeySessionController.ExpandedFilterCatalog?)?
    private(set) var isSelectingDisplayedCandidate = false
    private(set) var showsComposingFilterBar = false
    private(set) var isFilterBarRevealed = false
    private(set) var activeFilterTab: FilterTab = .all
    private var scrollTrace: CandidateScrollTrace?
    private var scrollInteractionInProgress = false
    var onInteractionEnded: (() -> Void)?

    private func dispatchDisplayedCandidate(_ index: Int, source: StaticString) {
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            isTapCommit: true,
            event: .expandedSelected(index, source)
        )
        isSelectingDisplayedCandidate = true
        defer { isSelectingDisplayedCandidate = false }
        if activeFilterTab != .all, index >= 0, index < activeFilteredPairs.count {
            let pair = activeFilteredPairs[index]
            if let onSelectExplicitCandidate {
                onSelectExplicitCandidate(pair.display, pair.canonical)
                return
            }
        }
        onSelectCandidate?(index)
    }
    var onDeleteCandidate: ((Int) -> Void)?
    var onDeleteExplicitCandidate: ((LokeyCandidate, LokeyCandidate?) -> Void)?
    var headerBarHeight: CGFloat = 0.0 {
        didSet {
            guard abs(oldValue - headerBarHeight) > 0.25 else { return }
            if visibleCellCount > 0 || showsComposingFilterBar {
                let w = layoutChromeFrames()
                rebuildRowsAndLayoutCells(scrollWidth: w)
            }
        }
    }

    private struct GridCellLayout {
        let index: Int
        let span: Int
        let isEmoji: Bool
    }

    private struct RescuableGridTap {
        let index: Int
        let title: String
        let startOffsetY: CGFloat
        let touchDownUptime: TimeInterval
    }

    static let maxLogicalCandidates = 64
    static let maxFilteredCandidates = 256
    static let maxRecycledPoolCells = 54
    static let initialPrewarmPoolCells = 42

    private final class GridPoolButton: UIButton {
        var preferredTitleMidY: CGFloat?

        override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
            if let midY = preferredTitleMidY, contentRect.height > 0 {
                let h = contentRect.height
                return CGRect(
                    x: contentRect.minX,
                    y: midY - h * 0.5,
                    width: contentRect.width,
                    height: h
                )
            }
            return contentRect
        }
    }

    private let scrollViewportView = UIView()
    private let viewportMaskLayer = CALayer()
    private let scrollView = CandidateGridVerticalScrollView()

    private var cellButtons: [GridPoolButton] = []
    private var cellLongPresses: [UILongPressGestureRecognizer?] = []
    private var cachedCellTitles: [String] = []
    private var cachedCellEmoji: [Bool] = []
    private var cachedCellHighlighted: [Bool] = []
    private var cachedCellDark: [Bool?] = []
    private var candToSlot: [Int] = []
    private var slotBoundCand: [Int] = []
    private var didPrewarmCJKPool = false
    private var lastAppliedDarkStyle: Bool?
    private var lastLaidOutPanelSize: CGSize = .zero
    private let dividers = CAShapeLayer()
    private var gridCandidates: [LokeyCandidate] = []
    private var gridCandidateEmojiFlags: [Bool] = []
    private var highlightsFirst = false
    private var frames: [CGRect] = []
    private var drawnRows = 0..<0
    private var rowsModel: [[GridCellLayout]] = []
    private var rowYOrigins: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var visibleCellCount: Int = 0
    private var lastLaidOutScrollWidth: CGFloat = -1
    private var lastLaidOutHeaderBarHeight: CGFloat = -1
    private var lastLaidOutHighlightsFirst: Bool?
    private var lastLaidOutUseFlowRow0: Bool?
    private var row0PreferredTitleMidY: CGFloat = 13.9
    private var pendingTouchStartOffsetY: CGFloat = 0
    private var rescuableTap: RescuableGridTap?
    private var didTriggerLongPressDelete = false
    private var lastGridCommitUptime: TimeInterval = -10
    private var lastGridBrakeCommitUptime: TimeInterval = -10
    private var lastGridScrollNoteUptime: TimeInterval = 0
    private var baseUnfilteredCandidates: [LokeyCandidate] = []
    private var baseHighlightFirst: Bool = false
    private var cachedFilterCatalog: LokeySessionController.ExpandedFilterCatalog?
    private var selectedSyllable: String?
    private var selectedRadicalID: UInt8?
    private var selectedStrokeChip: StrokeFilterChip = .all
    private var activeFilteredPairs: [(display: LokeyCandidate, canonical: LokeyCandidate?)] = []
    private var lastLaidOutTopChromeHeight: CGFloat = 0
    private var isAdjustingFilterChromeInset = false
    private var filterHeaderContainer: UIView?
    private var filterTrackView: UIView?
    private var filterActivePillView: UIView?
    private var filterBottomHairline: UIView?
    private var subFilterHairline: UIView?
    private var subFilterScrollView: CandidateScrollView?
    private var subFilterChipButtons: [UIButton] = []
    private var subFilterChipActions: [() -> Void] = []
    private var filterTabButtons: [UIButton] = []
    private lazy var filterSelectionFeedback = UISelectionFeedbackGenerator()

    internal var pooledButtonCount: Int { cellButtons.count }
    internal var rowDividerCGColorForTesting: CGColor? { dividers.fillColor }
    internal var displayedGridCandidateTextsForTesting: [String] { gridCandidates.map(\.text) }
    internal var isFilterBarRevealedForTesting: Bool { isFilterBarRevealed }
    internal var topChromeHeightForTesting: CGFloat {
        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        return currentTopChromeHeight(panelWidth: effW, panelHeight: effH)
    }

    private var currentPillCornerRadius: CGFloat {
        guard headerBarHeight > 0.5 else { return 11.0 }
        return CandidateBarView.computeVerticalMetrics(width: bounds.width, height: headerBarHeight).pillCornerRadius
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                scrollTrace?.record("面板隐藏", scrollView)
                scrollTrace = nil
                scrollInteractionInProgress = false
                rescuableTap = nil
                scrollView.resetBrakeTouchTracking()
                resetFilterStateToAll(rebuildUI: false, collapseHeader: true)
                LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
            }
        }
    }

    private final class WeakDisplayLinkProxy {
        weak var owner: ExpandedCandidateGridView?

        init(_ owner: ExpandedCandidateGridView) {
            self.owner = owner
        }

        @objc func handleRefresh(_ link: CADisplayLink) {
            if let owner {
                owner.firstPanelRefresh(link)
            } else {
                link.invalidate()
            }
        }
    }

    private var openTrace: (touch: UInt64, start: CFTimeInterval)?
    private var firstRefresh: CADisplayLink?

    deinit {
        firstRefresh?.invalidate()
    }

    func beginOpenTrace(start: CFTimeInterval?) {
        let logger = LokeyDiagnosticLogger.shared
        guard logger.canRecordInteractions else { return }
        openTrace = (logger.currentActiveTouchSeq, start ?? CACurrentMediaTime())
        logger.recordCandidateBarEventFast(event: .staticText("展开面板开始切换"))
        setNeedsLayout()
    }

    func finishOpenTrace(reason: String) {
        firstRefresh?.invalidate()
        firstRefresh = nil
        if let trace = openTrace {
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
                touchSeq: trace.touch,
                event: .expandedOpenEnded(reason)
            )
        }
        openTrace = nil
    }

    private func observeOpenLayout() {
        guard let trace = openTrace, firstRefresh == nil, !isHidden, window != nil else { return }
        let logger = LokeyDiagnosticLogger.shared
        guard logger.canRecordInteractions else {
            finishOpenTrace(reason: "诊断关闭")
            return
        }
        logger.recordCandidateBarEventFast(
            touchSeq: trace.touch,
            event: .expandedLayoutCompleted(
                elapsedMs: (CACurrentMediaTime() - trace.start) * 1000,
                width: bounds.width,
                height: bounds.height,
                candidateCount: gridCandidates.count,
                visibleCount: visibleButtonCount
            )
        )
        let link = CADisplayLink(target: WeakDisplayLinkProxy(self), selector: #selector(WeakDisplayLinkProxy.handleRefresh(_:)))
        firstRefresh = link
        link.add(to: .main, forMode: .common)
    }

    private var visibleButtonCount: Int {
        let vp = scrollView.bounds
        var count = 0
        for btn in cellButtons where !btn.isHidden && vp.intersects(btn.frame) {
            count += 1
        }
        return count
    }

    @objc private func firstPanelRefresh(_ link: CADisplayLink) {
        link.invalidate()
        firstRefresh = nil
        guard let trace = openTrace else { return }
        openTrace = nil
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(
            touchSeq: trace.touch,
            event: .expandedFirstDisplayRefresh(
                elapsedMs: (CACurrentMediaTime() - trace.start) * 1000,
                inWindow: window != nil,
                isHidden: isHidden,
                visibleCount: visibleButtonCount
            )
        )
    }

    var hasActiveInteraction: Bool { scrollInteractionInProgress || rescuableTap != nil }

    internal var gridScrollView: CandidateGridVerticalScrollView { scrollView }

    internal func gridCellButton(at index: Int) -> UIButton? {
        guard frames.indices.contains(index) else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return bindCell(at: index)
    }

    convenience override init(frame: CGRect) {
        self.init(frame: frame, prewarmPoolOnInit: nil)
    }

    init(frame: CGRect, prewarmPoolOnInit: Bool?) {
        super.init(frame: frame)
        let shouldPrewarm = prewarmPoolOnInit ?? (frame.width > 1.0 && frame.height > 1.0)
        setupViews(prewarmPool: shouldPrewarm)
        applyTheme()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyTheme()
        }
    }

    private func warmCJKGlyphLayoutOnceIfNeeded() {
        guard !didPrewarmCJKPool else { return }
        didPrewarmCJKPool = true
        for slot in cellButtons.indices where slotBoundCand[slot] < 0 {
            let btn = cellButtons[slot]
            if btn.bounds.size == .zero {
                btn.frame = CGRect(x: 0, y: 0, width: CandidateBarView.minPillWidth, height: 36.5)
            }
            btn.setTitle("我", for: .normal)
            btn.layoutIfNeeded()
            btn.setTitle("", for: .normal)
            cachedCellTitles[slot] = ""
            break
        }
    }

    /// Pre-warms the compact recycled `UIButton` pool off the critical touch path so the very first
    /// chevron tap opens in `< 0.5ms` with zero `UIButton` / `UILabel` allocations.
    func prewarmPoolIfNeeded() {
        guard cellButtons.count < Self.initialPrewarmPoolCells || !didPrewarmCJKPool || filterHeaderContainer == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ensureCellPoolCapacity(Self.initialPrewarmPoolCells)
        ensureFilterChromeCreated()
        warmCJKGlyphLayoutOnceIfNeeded()
    }

    func prewarmPoolIncrementallyIfNeeded(batchSize: Int = 14, shouldContinue: @escaping () -> Bool) {
        guard shouldContinue() else { return }
        guard cellButtons.count < Self.initialPrewarmPoolCells || !didPrewarmCJKPool || filterHeaderContainer == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let target = min(Self.initialPrewarmPoolCells, cellButtons.count + max(1, batchSize))
        ensureCellPoolCapacity(target)
        if cellButtons.count >= Self.initialPrewarmPoolCells {
            ensureFilterChromeCreated()
            warmCJKGlyphLayoutOnceIfNeeded()
        }
        CATransaction.commit()
        if cellButtons.count < Self.initialPrewarmPoolCells || !didPrewarmCJKPool || filterHeaderContainer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.prewarmPoolIncrementallyIfNeeded(batchSize: batchSize, shouldContinue: shouldContinue)
            }
        }
    }

    func releasePoolIfHidden() {
        guard isHidden, !hasActiveInteraction else { return }
        for btn in cellButtons {
            btn.removeFromSuperview()
        }
        cellButtons.removeAll(keepingCapacity: false)
        cellLongPresses.removeAll(keepingCapacity: false)
        cachedCellTitles.removeAll(keepingCapacity: false)
        cachedCellEmoji.removeAll(keepingCapacity: false)
        cachedCellHighlighted.removeAll(keepingCapacity: false)
        cachedCellDark.removeAll(keepingCapacity: false)
        candToSlot.removeAll(keepingCapacity: false)
        slotBoundCand.removeAll(keepingCapacity: false)
        frames.removeAll(keepingCapacity: false)
        rowsModel.removeAll(keepingCapacity: false)
        rowYOrigins.removeAll(keepingCapacity: false)
        rowHeights.removeAll(keepingCapacity: false)
        gridCandidates.removeAll(keepingCapacity: false)
        gridCandidateEmojiFlags.removeAll(keepingCapacity: false)
        dividers.path = nil
        didPrewarmCJKPool = false
        drawnRows = 0..<0
        visibleCellCount = 0
        lastLaidOutScrollWidth = -1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if openTrace != nil { setNeedsLayout() }
            KeyboardTheme.disableScrollEdgeEffects(on: scrollView)
            applyTheme()
        } else {
            finishOpenTrace(reason: "移出窗口")
            scrollTrace?.record("移出窗口", scrollView)
            scrollTrace = nil
            scrollView.resetBrakeTouchTracking()
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        }
    }

    private func effectiveHeaderRowHeight(panelWidth effW: CGFloat, panelHeight effH: CGFloat) -> CGFloat {
        if headerBarHeight > 0.5 { return headerBarHeight }
        return (effW > 520.0 && effH < 210.0) ? 36.0 : 44.0
    }

    private func currentTopChromeHeight(panelWidth effW: CGFloat, panelHeight effH: CGFloat) -> CGFloat {
        guard showsComposingFilterBar, (isFilterBarRevealed || activeFilterTab != .all) else { return 0.0 }
        let isCompactLandscape = effW > 520.0 && effH < 210.0
        let tabRowH = effectiveHeaderRowHeight(panelWidth: effW, panelHeight: effH)
        let subRowH: CGFloat = (activeFilterTab == .all) ? 0.0 : (isCompactLandscape ? 28.0 : 32.0)
        return tabRowH + subRowH
    }

    private func ensureFilterChromeCreated() {
        guard filterHeaderContainer == nil else { return }
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = KeyboardTheme.hitTestableClearBacking

        let track = UIView()
        track.layer.cornerCurve = .continuous
        container.addSubview(track)

        let activePill = UIView()
        activePill.isUserInteractionEnabled = false
        activePill.layer.cornerCurve = .continuous
        activePill.layer.shadowColor = UIColor.black.cgColor
        activePill.layer.shadowOffset = CGSize(width: 0, height: 1.0)
        activePill.layer.shadowRadius = 2.0
        track.addSubview(activePill)

        var tabs: [UIButton] = []
        for tab in FilterTab.allCases {
            let btn = UIButton(type: .custom)
            btn.tag = tab.rawValue
            btn.setTitle(tab.title, for: .normal)
            btn.layer.cornerCurve = .continuous
            btn.isExclusiveTouch = false
            btn.addTarget(self, action: #selector(handleFilterTabTap(_:)), for: .touchUpInside)
            track.addSubview(btn)
            tabs.append(btn)
        }

        let midLine = UIView()
        midLine.isHidden = true
        container.addSubview(midLine)

        let subScroll = CandidateScrollView()
        subScroll.showsHorizontalScrollIndicator = false
        subScroll.showsVerticalScrollIndicator = false
        subScroll.alwaysBounceHorizontal = true
        subScroll.alwaysBounceVertical = false
        subScroll.isDirectionalLockEnabled = false
        subScroll.delaysContentTouches = false
        subScroll.canCancelContentTouches = true
        subScroll.isExclusiveTouch = false
        subScroll.contentInset = UIEdgeInsets(top: 0, left: 8.0, bottom: 0, right: 8.0)
        KeyboardTheme.disableScrollEdgeEffects(on: subScroll)
        subScroll.isHidden = true
        container.addSubview(subScroll)

        let bottomLine = UIView()
        container.addSubview(bottomLine)

        container.isHidden = true
        addSubview(container)
        self.filterHeaderContainer = container
        self.filterTrackView = track
        self.filterActivePillView = activePill
        self.subFilterHairline = midLine
        self.subFilterScrollView = subScroll
        self.filterBottomHairline = bottomLine
        self.filterTabButtons = tabs
        updateFilterChromeAppearance()
    }

    func setComposingFilterEnabled(_ enabled: Bool) {
        guard showsComposingFilterBar != enabled else {
            if enabled && filterHeaderContainer != nil {
                updateFilterChromeAppearance()
            }
            return
        }
        showsComposingFilterBar = enabled
        if enabled {
            if isFilterBarRevealed || activeFilterTab != .all {
                ensureFilterChromeCreated()
            }
            if filterHeaderContainer != nil {
                updateFilterChromeAppearance()
            }
        } else {
            resetFilterStateToAll(rebuildUI: false, collapseHeader: true)
            filterHeaderContainer?.isHidden = true
        }
        lastLaidOutPanelSize = .zero
        setNeedsLayout()
    }

    func revealFilterBar(animated: Bool = true, playHaptic: Bool = false) {
        guard showsComposingFilterBar, !isFilterBarRevealed else { return }
        rescuableTap = nil
        ensureFilterChromeCreated()
        isFilterBarRevealed = true
        lastLaidOutPanelSize = .zero
        if playHaptic {
            filterSelectionFeedback.selectionChanged()
            filterSelectionFeedback.prepare()
        }
        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        let topH = currentTopChromeHeight(panelWidth: effW, panelHeight: effH)
        _ = layoutChromeFrames()
        updateFilterChromeAppearance()
        if !scrollView.isDragging && !scrollView.isDecelerating && scrollView.contentOffset.y < 0.5 && scrollView.contentOffset.y > -topH {
            scrollView.setContentOffset(CGPoint(x: 0, y: -topH), animated: animated && window != nil)
        }
        renderVisibleRows()
        if animated, window != nil, let header = filterHeaderContainer {
            header.alpha = 0.0
            header.transform = CGAffineTransform(translationX: 0, y: -8.0)
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]) {
                header.alpha = 1.0
                header.transform = .identity
            }
        } else {
            filterHeaderContainer?.alpha = 1.0
            filterHeaderContainer?.transform = .identity
        }
    }

    internal func revealFilterBarForTesting() {
        revealFilterBar(animated: false, playHaptic: false)
    }

    internal var subFilterScrollOffsetXForTesting: CGFloat {
        subFilterScrollView?.contentOffset.x ?? 0.0
    }

    internal var subFilterRestingOffsetXForTesting: CGFloat {
        -(subFilterScrollView?.contentInset.left ?? 0.0)
    }

    internal func setSubFilterScrollOffsetXForTesting(_ x: CGFloat) {
        subFilterScrollView?.setContentOffset(CGPoint(x: x, y: 0.0), animated: false)
    }

    private func resetSubFilterScrollOffset() {
        guard let subScroll = subFilterScrollView else { return }
        let restingX = -subScroll.contentInset.left
        if abs(subScroll.contentOffset.x - restingX) > 0.1 || abs(subScroll.contentOffset.y) > 0.1 {
            subScroll.setContentOffset(CGPoint(x: restingX, y: 0.0), animated: false)
        }
    }

    private func resetFilterStateToAll(rebuildUI: Bool, collapseHeader: Bool = false) {
        activeFilterTab = .all
        if collapseHeader {
            isFilterBarRevealed = false
        }
        selectedSyllable = nil
        selectedRadicalID = nil
        selectedStrokeChip = .all
        cachedFilterCatalog = nil
        activeFilteredPairs.removeAll(keepingCapacity: true)
        resetSubFilterScrollOffset()
        subFilterScrollView?.isHidden = true
        subFilterHairline?.isHidden = true
        if collapseHeader {
            filterHeaderContainer?.isHidden = true
            if scrollView.contentInset.top != 0.0 {
                isAdjustingFilterChromeInset = true
                scrollView.contentInset = .zero
                isAdjustingFilterChromeInset = false
            }
            lastLaidOutPanelSize = .zero
        }
        updateFilterChromeAppearance()
        if rebuildUI {
            lastLaidOutPanelSize = .zero
            applyActiveCandidatesToGrid(preservingScrollOffset: false)
        }
    }

    @objc private func handleFilterTabTap(_ sender: UIButton) {
        guard let nextTab = FilterTab(rawValue: sender.tag) else { return }
        selectFilterTab(nextTab)
    }

    internal func selectFilterTabForTesting(_ tab: FilterTab) {
        selectFilterTab(tab)
    }

    internal func selectRadicalChipForTesting(label: String) -> Bool {
        if activeFilterTab != .radical {
            selectFilterTab(.radical)
        }
        guard let idx = subFilterChipButtons.firstIndex(where: { !$0.isHidden && $0.title(for: .normal) == label }),
              idx < subFilterChipActions.count else {
            return false
        }
        subFilterChipActions[idx]()
        return true
    }

    internal func selectStrokeChipForTesting(title: String) -> Bool {
        if activeFilterTab != .stroke {
            selectFilterTab(.stroke)
        }
        guard let idx = subFilterChipButtons.firstIndex(where: { !$0.isHidden && $0.title(for: .normal) == title }),
              idx < subFilterChipActions.count else {
            return false
        }
        subFilterChipActions[idx]()
        return true
    }

    internal func selectPinyinChipForTesting(syllable: String) -> Bool {
        if activeFilterTab != .pinyin {
            selectFilterTab(.pinyin)
        }
        guard let idx = subFilterChipButtons.firstIndex(where: { !$0.isHidden && $0.title(for: .normal) == syllable }),
              idx < subFilterChipActions.count else {
            return false
        }
        subFilterChipActions[idx]()
        return true
    }

    private func selectFilterTab(_ nextTab: FilterTab) {
        if showsComposingFilterBar && !isFilterBarRevealed {
            ensureFilterChromeCreated()
            isFilterBarRevealed = true
        }
        if activeFilterTab == nextTab {
            if nextTab != .all {
                selectedRadicalID = nil
                selectedStrokeChip = .all
                if nextTab == .pinyin {
                    selectedSyllable = resolvedCatalog()?.pinyinOptions.first?.syllable
                }
                rebuildSubFilterChips()
                resetSubFilterScrollOffset()
                applyActiveCandidatesToGrid(preservingScrollOffset: false)
            }
            return
        }
        activeFilterTab = nextTab
        if nextTab == .pinyin && selectedSyllable == nil {
            selectedSyllable = resolvedCatalog()?.pinyinOptions.first?.syllable
        }
        rebuildSubFilterChips()
        resetSubFilterScrollOffset()
        updateFilterChromeAppearance()
        lastLaidOutPanelSize = .zero
        applyActiveCandidatesToGrid(preservingScrollOffset: false)
    }

    private func resolvedCatalog() -> LokeySessionController.ExpandedFilterCatalog? {
        if let cached = cachedFilterCatalog {
            return cached
        }
        let built = filterCatalogProvider?()
        cachedFilterCatalog = built
        return built
    }

    private func updateFilterChromeAppearance() {
        guard let container = filterHeaderContainer else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        container.backgroundColor = KeyboardTheme.hitTestableClearBacking
        filterTrackView?.backgroundColor = dark
            ? UIColor(white: 1.0, alpha: 0.11)
            : UIColor(white: 0.0, alpha: 0.065)
        filterActivePillView?.backgroundColor = KeyboardTheme.candidateHighlightPillFill(dark: dark)
        filterActivePillView?.layer.shadowOpacity = dark ? 0.0 : 0.06
        filterBottomHairline?.backgroundColor = KeyboardTheme.expandedGridRowDivider(dark: dark)
        subFilterHairline?.backgroundColor = KeyboardTheme.expandedGridRowDivider(dark: dark)

        let inactiveText = KeyboardTheme.dynamicPrimaryText.withAlphaComponent(0.84)
        for btn in filterTabButtons {
            let isSelected = (btn.tag == activeFilterTab.rawValue)
            btn.titleLabel?.font = .systemFont(ofSize: 14.5, weight: isSelected ? .semibold : .medium)
            btn.setTitleColor(isSelected ? (dark ? .white : .black) : inactiveText, for: .normal)
            btn.backgroundColor = .clear
        }
        styleSubFilterChips(dark: dark)
    }

    private func styleSubFilterChips(dark: Bool) {
        for btn in subFilterChipButtons where !btn.isHidden {
            let isSelected = btn.isSelected
            btn.titleLabel?.font = .systemFont(ofSize: 14.0, weight: isSelected ? .semibold : .regular)
            btn.setTitleColor(isSelected ? (dark ? .white : .black) : KeyboardTheme.dynamicPrimaryText, for: .normal)
            btn.backgroundColor = isSelected ? KeyboardTheme.candidateHighlightPillFill(dark: dark) : KeyboardTheme.dynamicSubtlePill
        }
    }

    @objc private func handleSubFilterChipTap(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < subFilterChipActions.count else { return }
        subFilterChipActions[idx]()
    }

    private func rebuildSubFilterChips() {
        guard showsComposingFilterBar, let subScroll = subFilterScrollView else { return }
        guard activeFilterTab != .all, let catalog = resolvedCatalog() else {
            subScroll.isHidden = true
            subFilterHairline?.isHidden = true
            return
        }

        var items: [(title: String, selected: Bool, action: () -> Void)] = []
        switch activeFilterTab {
        case .all:
            break
        case .pinyin:
            if selectedSyllable == nil || !catalog.pinyinOptions.contains(where: { $0.syllable == selectedSyllable }) {
                selectedSyllable = catalog.pinyinOptions.first?.syllable
            }
            for opt in catalog.pinyinOptions {
                let syl = opt.syllable
                items.append((syl, selectedSyllable == syl, { [weak self] in
                    guard let self else { return }
                    self.selectedSyllable = syl
                    self.rebuildSubFilterChips()
                    self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
                }))
            }
        case .radical:
            if let selRad = selectedRadicalID, !catalog.availableRadicals.contains(where: { $0.id == selRad }) {
                selectedRadicalID = nil
            }
            items.append(("全部", selectedRadicalID == nil, { [weak self] in
                guard let self else { return }
                self.selectedRadicalID = nil
                self.rebuildSubFilterChips()
                self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
            }))
            for rad in catalog.availableRadicals {
                let radID = rad.id
                items.append((rad.label, selectedRadicalID == radID, { [weak self] in
                    guard let self else { return }
                    self.selectedRadicalID = radID
                    self.rebuildSubFilterChips()
                    self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
                }))
            }
        case .stroke:
            switch selectedStrokeChip {
            case .all:
                break
            case let .bucket(b):
                if !catalog.availableStrokeBuckets.contains(b) { selectedStrokeChip = .all }
            case let .exact(n):
                if !catalog.availableExactStrokes.contains(n) { selectedStrokeChip = .all }
            }
            items.append(("全部", selectedStrokeChip == .all, { [weak self] in
                guard let self else { return }
                self.selectedStrokeChip = .all
                self.rebuildSubFilterChips()
                self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
            }))
            for bucket in catalog.availableStrokeBuckets {
                let chip = StrokeFilterChip.bucket(bucket)
                items.append((chip.title, selectedStrokeChip == chip, { [weak self] in
                    guard let self else { return }
                    self.selectedStrokeChip = chip
                    self.rebuildSubFilterChips()
                    self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
                }))
            }
            for exactN in catalog.availableExactStrokes.prefix(24) {
                let chip = StrokeFilterChip.exact(exactN)
                items.append((chip.title, selectedStrokeChip == chip, { [weak self] in
                    guard let self else { return }
                    self.selectedStrokeChip = chip
                    self.rebuildSubFilterChips()
                    self.applyActiveCandidatesToGrid(preservingScrollOffset: false)
                }))
            }
        }

        while subFilterChipButtons.count < items.count {
            let btn = UIButton(type: .custom)
            btn.layer.cornerRadius = 11.5
            btn.layer.cornerCurve = .continuous
            btn.isExclusiveTouch = false
            btn.addTarget(self, action: #selector(handleSubFilterChipTap(_:)), for: .touchUpInside)
            subScroll.addSubview(btn)
            subFilterChipButtons.append(btn)
        }
        subFilterChipActions = items.map(\.action)

        let chipFont = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        let chipAttrs: [NSAttributedString.Key: Any] = [.font: chipFont]
        let subH: CGFloat = (bounds.width > 520.0 && bounds.height < 210.0) ? 28.0 : 32.0
        let chipH: CGFloat = subH - 6.0
        let chipY: CGFloat = (subH - chipH) * 0.5
        var curX: CGFloat = 0.0
        for i in 0..<subFilterChipButtons.count {
            let btn = subFilterChipButtons[i]
            if i < items.count {
                let item = items[i]
                btn.tag = i
                btn.setTitle(item.title, for: .normal)
                btn.isSelected = item.selected
                let textW = ceil((item.title as NSString).size(withAttributes: chipAttrs).width)
                let w = max(34.0, textW + 18.0)
                btn.frame = CGRect(x: curX, y: chipY, width: w, height: chipH)
                btn.isHidden = false
                curX += w + 6.0
            } else {
                btn.isHidden = true
            }
        }
        subScroll.contentSize = CGSize(width: max(0.0, curX - 6.0), height: subH)
        subScroll.isHidden = false
        subFilterHairline?.isHidden = false
        styleSubFilterChips(dark: traitCollection.userInterfaceStyle == .dark)
    }

    private func buildFilteredPairsForActiveTab() -> [(display: LokeyCandidate, canonical: LokeyCandidate?)] {
        guard showsComposingFilterBar, activeFilterTab != .all, let catalog = resolvedCatalog() else {
            return baseUnfilteredCandidates.prefix(Self.maxLogicalCandidates).map { ($0, nil) }
        }
        var out: [(display: LokeyCandidate, canonical: LokeyCandidate?)] = []
        out.reserveCapacity(64)
        var seenSurfaces = Set<String>()

        switch activeFilterTab {
        case .all:
            return baseUnfilteredCandidates.prefix(Self.maxLogicalCandidates).map { ($0, nil) }
        case .pinyin:
            let syl = selectedSyllable ?? catalog.pinyinOptions.first?.syllable ?? ""
            for base in baseUnfilteredCandidates where base.matchedSyllables.first?.lowercased() == syl {
                if seenSurfaces.insert(base.text).inserted {
                    out.append((base, nil))
                    if out.count >= Self.maxFilteredCandidates { return out }
                }
            }
            for item in catalog.charCandidates where item.syllable == syl {
                if seenSurfaces.insert(item.displayCandidate.text).inserted {
                    out.append((item.displayCandidate, item.canonicalCandidate))
                    if out.count >= Self.maxFilteredCandidates { return out }
                }
            }
        case .radical:
            for item in catalog.charCandidates {
                if let radID = selectedRadicalID, item.radicalID != radID { continue }
                if seenSurfaces.insert(item.displayCandidate.text).inserted {
                    out.append((item.displayCandidate, item.canonicalCandidate))
                    if out.count >= Self.maxFilteredCandidates { return out }
                }
            }
        case .stroke:
            for item in catalog.charCandidates {
                let matches: Bool
                switch selectedStrokeChip {
                case .all:
                    matches = true
                case let .bucket(b):
                    matches = b.contains(item.totalStrokes)
                case let .exact(n):
                    matches = (item.totalStrokes == n)
                }
                guard matches else { continue }
                if seenSurfaces.insert(item.displayCandidate.text).inserted {
                    out.append((item.displayCandidate, item.canonicalCandidate))
                    if out.count >= Self.maxFilteredCandidates { return out }
                }
            }
        }
        return out
    }

    @discardableResult
    private func layoutChromeFrames() -> CGFloat {
        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        let targetSize = CGSize(width: effW, height: effH)
        let gridW = max(120.0, effW - (effW >= 260.0 ? 45.5 : 0.0))
        let topChromeH = currentTopChromeHeight(panelWidth: effW, panelHeight: effH)

        if lastLaidOutPanelSize != targetSize || abs(lastLaidOutTopChromeHeight - topChromeH) > 0.25 {
            lastLaidOutPanelSize = targetSize
            lastLaidOutTopChromeHeight = topChromeH
            let fullFrame = CGRect(x: 0, y: 0, width: effW, height: effH)
            if scrollViewportView.frame != fullFrame {
                scrollViewportView.frame = fullFrame
            }
            if scrollView.frame != fullFrame {
                scrollView.frame = fullFrame
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            viewportMaskLayer.frame = CGRect(
                x: 0,
                y: topChromeH,
                width: effW,
                height: max(1.0, effH - topChromeH)
            )
            CATransaction.commit()

            if abs(scrollView.contentInset.top - topChromeH) > 0.25 {
                let preservedOffset = scrollView.contentOffset
                isAdjustingFilterChromeInset = true
                scrollView.contentInset = UIEdgeInsets(top: topChromeH, left: 0, bottom: 0, right: 0)
                if scrollView.isDragging || scrollView.isDecelerating || preservedOffset.y > 0.5 {
                    scrollView.contentOffset = preservedOffset
                }
                isAdjustingFilterChromeInset = false
            }
        }

        if let container = filterHeaderContainer {
            if topChromeH > 0.5 {
                container.isHidden = false
                container.frame = CGRect(x: 0, y: 0, width: effW, height: topChromeH)
                if subviews.last !== container {
                    bringSubviewToFront(container)
                }
                let isCompactLandscape = effW > 520.0 && effH < 210.0
                let tabRowH = effectiveHeaderRowHeight(panelWidth: effW, panelHeight: effH)
                let subRowH = max(0.0, topChromeH - tabRowH)

                let rightReserved: CGFloat = effW >= 260.0 ? 49.0 : 40.0
                let trackLeft: CGFloat = 8.0
                let trackW = max(140.0, effW - trackLeft - rightReserved)
                let trackH: CGFloat = isCompactLandscape ? 28.0 : 34.0
                let vMetrics = CandidateBarView.computeVerticalMetrics(width: effW, height: tabRowH)
                let trackY = max(2.0, min(tabRowH - trackH - 2.0, vMetrics.pillCenterY - trackH * 0.5))
                filterTrackView?.frame = CGRect(x: trackLeft, y: trackY, width: trackW, height: trackH)
                filterTrackView?.layer.cornerRadius = trackH * 0.5

                let tabCount = CGFloat(max(1, filterTabButtons.count))
                let innerInset: CGFloat = 2.0
                let innerW = max(60.0, trackW - innerInset * 2.0)
                let segW = innerW / tabCount
                let segH = max(20.0, trackH - innerInset * 2.0)
                for (idx, btn) in filterTabButtons.enumerated() {
                    btn.frame = CGRect(
                        x: innerInset + CGFloat(idx) * segW,
                        y: innerInset,
                        width: segW,
                        height: segH
                    )
                    btn.layer.cornerRadius = segH * 0.5
                }
                let activeIdx = max(0, min(filterTabButtons.count - 1, activeFilterTab.rawValue))
                let activePillFrame = CGRect(
                    x: innerInset + CGFloat(activeIdx) * segW,
                    y: innerInset,
                    width: segW,
                    height: segH
                )
                filterActivePillView?.frame = activePillFrame
                filterActivePillView?.layer.cornerRadius = segH * 0.5

                if subRowH > 0.5 {
                    subFilterHairline?.frame = CGRect(x: 0, y: tabRowH - 0.5, width: gridW, height: 0.5)
                    subFilterScrollView?.frame = CGRect(x: 0, y: tabRowH, width: effW, height: subRowH - 0.5)
                    subFilterHairline?.isHidden = false
                    subFilterScrollView?.isHidden = false
                } else {
                    subFilterHairline?.isHidden = true
                    subFilterScrollView?.isHidden = true
                }
                filterBottomHairline?.frame = CGRect(x: 0, y: topChromeH - 0.5, width: gridW, height: 0.5)
            } else {
                container.isHidden = true
            }
        }
        return gridW
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden else { return }
        applyTheme()
        if bounds.height > 420.0 {
            return
        }
        let prevSize = lastLaidOutPanelSize
        let w = layoutChromeFrames()
        if visibleCellCount > 0 {
            let nextUseFlowRow0 = (headerBarHeight > 0.5) && (activeFilterTab == .all)
            if abs(w - lastLaidOutScrollWidth) > 0.5
                || abs(lastLaidOutPanelSize.height - prevSize.height) > 0.5
                || abs(headerBarHeight - lastLaidOutHeaderBarHeight) > 0.25
                || lastLaidOutHighlightsFirst != highlightsFirst
                || lastLaidOutUseFlowRow0 != nextUseFlowRow0 {
                rebuildRowsAndLayoutCells(scrollWidth: w)
            } else {
                renderVisibleRows()
            }
        }
        observeOpenLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyTheme() {
        let dark = traitCollection.userInterfaceStyle == .dark
        if lastAppliedDarkStyle == dark && dividers.fillColor != nil { return }
        let dividerColor = KeyboardTheme.expandedGridRowDivider(dark: dark).cgColor
        lastAppliedDarkStyle = dark
        backgroundColor = .clear
        dividers.fillColor = dividerColor
        updateFilterChromeAppearance()
        let pillRadius = currentPillCornerRadius
        for slot in cellButtons.indices {
            let candIdx = slotBoundCand[slot]
            guard candIdx >= 0 else { continue }
            let button = cellButtons[slot]
            let highlight = (candIdx == 0 && highlightsFirst)
            cachedCellHighlighted[slot] = highlight
            cachedCellDark[slot] = dark
            button.setTitleColor(highlight ? (dark ? .white : .black) : KeyboardTheme.dynamicPrimaryText, for: .normal)
            button.backgroundColor = highlight ? KeyboardTheme.candidateHighlightPillFill(dark: dark) : .clear
            button.layer.cornerRadius = highlight ? pillRadius : 0
        }
    }

    private func setupViews(prewarmPool: Bool) {
        backgroundColor = .clear
        scrollViewportView.backgroundColor = .clear
        viewportMaskLayer.backgroundColor = UIColor.black.cgColor
        scrollViewportView.layer.mask = viewportMaskLayer
        addSubview(scrollViewportView)

        scrollView.backgroundColor = KeyboardTheme.hitTestableClearBacking
        scrollView.delegate = self
        scrollView.layer.addSublayer(dividers)
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.isExclusiveTouch = false
        scrollView.clipsToBounds = true
        KeyboardTheme.disableScrollEdgeEffects(on: scrollView)
        scrollView.onDecelerationBrakeTap = { [weak self] pt in
            self?.handleDecelerationBrakeTap(at: pt)
        }
        scrollViewportView.addSubview(scrollView)

        _ = layoutChromeFrames()
        if prewarmPool {
            ensureCellPoolCapacity(Self.initialPrewarmPoolCells)
        }
    }

    private func ensureCellPoolCapacity(_ needed: Int) {
        let clamped = min(Self.maxRecycledPoolCells, max(0, needed))
        guard cellButtons.count < clamped else { return }
        if cellButtons.capacity < clamped {
            cellButtons.reserveCapacity(clamped)
            cellLongPresses.reserveCapacity(clamped)
            cachedCellTitles.reserveCapacity(clamped)
            cachedCellEmoji.reserveCapacity(clamped)
            cachedCellHighlighted.reserveCapacity(clamped)
            cachedCellDark.reserveCapacity(clamped)
            slotBoundCand.reserveCapacity(clamped)
        }
        let primaryText = KeyboardTheme.dynamicPrimaryText
        for _ in cellButtons.count..<clamped {
            let btn = GridPoolButton(type: .custom)
            btn.frame = CGRect(x: 0, y: 0, width: CandidateBarView.minPillWidth, height: 36.5)
            btn.tag = -1
            btn.isExclusiveTouch = false
            btn.layer.cornerCurve = .continuous
            btn.layer.shadowOpacity = 0
            btn.backgroundColor = .clear
            btn.setTitleColor(primaryText, for: .normal)
            btn.titleLabel?.font = CandidateBarView.candidateFont
            btn.titleLabel?.textAlignment = .center
            btn.titleLabel?.lineBreakMode = .byClipping
            btn.isHidden = true
            btn.addTarget(self, action: #selector(handleTouchDown(_:forEvent:)), for: .touchDown)
            btn.addTarget(self, action: #selector(handleTap(_:forEvent:)), for: .touchUpInside)
            btn.addTarget(self, action: #selector(handleTouchCancel(_:)), for: .touchCancel)
            btn.addTarget(self, action: #selector(handleTouchUpOutside(_:)), for: .touchUpOutside)

            scrollView.addSubview(btn)
            cellButtons.append(btn)
            cellLongPresses.append(nil)
            cachedCellTitles.append("")
            cachedCellEmoji.append(false)
            cachedCellHighlighted.append(false)
            cachedCellDark.append(nil)
            slotBoundCand.append(-1)
        }
    }

    private func unbindSlot(_ slot: Int) {
        let oldCand = slotBoundCand[slot]
        if oldCand >= 0 && oldCand < candToSlot.count && candToSlot[oldCand] == slot {
            candToSlot[oldCand] = -1
        }
        slotBoundCand[slot] = -1
        let btn = cellButtons[slot]
        if btn.tag != -1 { btn.tag = -1 }
        if btn.preferredTitleMidY != nil {
            btn.preferredTitleMidY = nil
        }
        if let lp = cellLongPresses[slot], lp.isEnabled {
            lp.isEnabled = false
        }
        if !btn.isHidden {
            btn.isHidden = true
        }
    }

    func update(candidates: [LokeyCandidate], highlightFirst: Bool = true, preservingScrollOffset: Bool = false) {
        baseUnfilteredCandidates = candidates
        baseHighlightFirst = highlightFirst
        cachedFilterCatalog = nil
        if showsComposingFilterBar && activeFilterTab != .all {
            rebuildSubFilterChips()
        }
        applyActiveCandidatesToGrid(preservingScrollOffset: preservingScrollOffset)
    }

    private func applyActiveCandidatesToGrid(preservingScrollOffset: Bool) {
        applyTheme()
        let effectiveHighlightFirst: Bool
        let nextSlice: [LokeyCandidate]
        if showsComposingFilterBar && activeFilterTab != .all {
            activeFilteredPairs = buildFilteredPairsForActiveTab()
            nextSlice = activeFilteredPairs.map(\.display)
            effectiveHighlightFirst = false
        } else {
            activeFilteredPairs.removeAll(keepingCapacity: true)
            nextSlice = Array(baseUnfilteredCandidates.prefix(Self.maxLogicalCandidates))
            effectiveHighlightFirst = baseHighlightFirst
        }
        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        let topChromeH = currentTopChromeHeight(panelWidth: effW, panelHeight: effH)
        let nextUseFlowRow0 = (headerBarHeight > 0.5) && (activeFilterTab == .all)
        // Scores and readings can change without changing any cell's layout or action.
        if highlightsFirst == effectiveHighlightFirst,
           lastLaidOutPanelSize == CGSize(width: effW, height: effH),
           abs(lastLaidOutTopChromeHeight - topChromeH) <= 0.25,
           abs(lastLaidOutHeaderBarHeight - headerBarHeight) <= 0.25,
           lastLaidOutUseFlowRow0 == nextUseFlowRow0,
           gridCandidates.count == nextSlice.count,
           zip(gridCandidates, nextSlice).allSatisfy({ old, new in
               old.text == new.text && old.consumedInputCount == new.consumedInputCount
                   && old.isDeletableUserPhrase == new.isDeletableUserPhrase
           }) { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let previousOffset = scrollView.contentOffset.y
        if let tap = rescuableTap, !nextSlice.indices.contains(tap.index) || nextSlice[tap.index].text != tap.title {
            rescuableTap = nil
        }

        gridCandidates = nextSlice
        highlightsFirst = effectiveHighlightFirst
        visibleCellCount = gridCandidates.count

        gridCandidateEmojiFlags.removeAll(keepingCapacity: true)
        if gridCandidateEmojiFlags.capacity < visibleCellCount {
            gridCandidateEmojiFlags.reserveCapacity(visibleCellCount)
        }
        for c in gridCandidates {
            gridCandidateEmojiFlags.append(CandidateBarView.isEmojiSurface(c.text))
        }

        if candToSlot.count < visibleCellCount {
            for i in 0..<candToSlot.count { candToSlot[i] = -1 }
            candToSlot.append(contentsOf: repeatElement(-1, count: visibleCellCount - candToSlot.count))
        } else {
            if candToSlot.count > visibleCellCount {
                candToSlot.removeSubrange(visibleCellCount..<candToSlot.count)
            }
            for i in 0..<visibleCellCount {
                candToSlot[i] = -1
            }
        }
        let survivingPinned = rescuableTap?.index ?? -1
        for slot in cellButtons.indices where slotBoundCand[slot] >= 0 {
            let prevCand = slotBoundCand[slot]
            if prevCand == survivingPinned && prevCand < visibleCellCount {
                candToSlot[prevCand] = slot
            } else {
                slotBoundCand[slot] = -1
            }
        }

        let scrollW = layoutChromeFrames()
        rebuildRowsAndLayoutCells(scrollWidth: scrollW, renderImmediately: false)

        let minOffset = -topChromeH
        let maxOffset = max(minOffset, scrollView.contentSize.height - scrollView.bounds.height)
        let offset = CGPoint(x: 0, y: preservingScrollOffset ? min(max(previousOffset, minOffset), maxOffset) : minOffset)
        if scrollView.contentOffset != offset || scrollView.isDecelerating {
            scrollView.setContentOffset(offset, animated: false)
        }
        renderVisibleRows()
    }

    @inline(__always)
    private static func isBoundedWidthBMP(_ text: String, maxWidthPerUnit: CGFloat, padding: CGFloat, limit: CGFloat) -> Bool {
        let u16 = text.utf16
        let count = u16.count
        guard count > 0, CGFloat(count) * maxWidthPerUnit + padding <= limit else { return false }
        for cu in u16 {
            let ok = (cu >= 0x4E00 && cu <= 0x9FFF)
                || (cu >= 0x0020 && cu <= 0x007E)
                || (cu >= 0x3000 && cu <= 0x303F)
                || (cu >= 0xFF01 && cu <= 0xFF5E)
            if !ok { return false }
        }
        return true
    }

    // Pure Swift width & row packing (`< 15µs` for 64 candidates, zero `UIButton.titleLabel` sizing).
    private func rebuildRowsAndLayoutCells(scrollWidth: CGFloat, renderImmediately: Bool = true) {
        let useFlowRow0 = (headerBarHeight > 0.5) && (activeFilterTab == .all)
        lastLaidOutScrollWidth = scrollWidth
        lastLaidOutHeaderBarHeight = headerBarHeight
        lastLaidOutHighlightsFirst = highlightsFirst
        lastLaidOutUseFlowRow0 = useFlowRow0
        rowsModel.removeAll(keepingCapacity: true)
        rowYOrigins.removeAll(keepingCapacity: true)
        rowHeights.removeAll(keepingCapacity: true)
        if visibleCellCount == 0 {
            frames.removeAll(keepingCapacity: true)
            drawnRows = 0..<0
            dividers.path = nil
            dividers.frame = .zero
            for slot in cellButtons.indices where slotBoundCand[slot] >= 0 || !cellButtons[slot].isHidden {
                unbindSlot(slot)
            }
            if scrollView.contentSize != .zero {
                scrollView.contentSize = .zero
            }
            return
        }

        if frames.count < visibleCellCount {
            frames.append(contentsOf: repeatElement(.zero, count: visibleCellCount - frames.count))
        } else if frames.count > visibleCellCount {
            frames.removeSubrange(visibleCellCount..<frames.count)
        }

        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        let canonicalHeaderH = effectiveHeaderRowHeight(panelWidth: effW, panelHeight: effH)
        let headerH: CGFloat = useFlowRow0 ? headerBarHeight : 0.0
        let reservedHeaderH: CGFloat = (headerBarHeight > 0.5 || showsComposingFilterBar) ? canonicalHeaderH : 0.0
        let fullBodyH = max(96.0, effH - reservedHeaderH)
        let bodyPitch = max(36.0, fullBodyH / 5.0)
        // Align Row 0 identically with `CandidateBarView` (`topInset .. pillBottom` + exact same optical center)
        // so expanding / collapsing produces 0.0pt vertical jump on Row 0 candidates and `#0` composing pill!
        let row0Metrics = CandidateBarView.computeVerticalMetrics(width: bounds.width, height: canonicalHeaderH)
        let pillH: CGFloat = row0Metrics.pillHeight
        let row0TopInset: CGFloat = row0Metrics.topInset
        let row0OpticalY: CGFloat = row0Metrics.opticalCenterY(highlightFirst: highlightsFirst)
        self.row0PreferredTitleMidY = row0OpticalY - row0TopInset

        var nextIndex = 0
        if useFlowRow0 {
            var row0Cells = [GridCellLayout]()
            row0Cells.reserveCapacity(8)
            var cursorX: CGFloat = 6.5
            let maxRow0X = scrollWidth
            let pillTitleW = CandidateBarView.cachedTitleWidth(
                for: gridCandidates[0].text,
                isEmoji: gridCandidateEmojiFlags[0]
            )
            let pillPad: CGFloat = highlightsFirst ? 24.0 : 16.0
            let minFirstW: CGFloat = highlightsFirst ? CandidateBarView.minPillWidth : 34.0
            let maxFirstW = max(minFirstW, maxRow0X - cursorX)
            let firstW = min(maxFirstW, max(minFirstW, ceil(pillTitleW + pillPad)))
            frames[0] = CGRect(x: cursorX, y: row0TopInset, width: firstW, height: pillH)
            row0Cells.append(GridCellLayout(index: 0, span: 1, isEmoji: gridCandidateEmojiFlags[0]))
            cursorX += firstW
            nextIndex = 1

            let row0Gap: CGFloat = 4.0
            while nextIndex < visibleCellCount {
                let text = gridCandidates[nextIndex].text
                let isEmoji = gridCandidateEmojiFlags[nextIndex]
                let itemW = max(34.0, ceil(CandidateBarView.cachedTitleWidth(for: text, isEmoji: isEmoji) + 16.0))
                if cursorX + row0Gap + itemW > maxRow0X {
                    break
                }
                let x = cursorX + row0Gap
                frames[nextIndex] = CGRect(x: x, y: row0TopInset, width: itemW, height: pillH)
                row0Cells.append(GridCellLayout(index: nextIndex, span: 1, isEmoji: isEmoji))
                cursorX = x + itemW
                nextIndex += 1
            }
            rowsModel.append(row0Cells)
            rowYOrigins.append(0.0)
            rowHeights.append(headerH)
        }

        let unitColW = max(32.0, scrollWidth / 6.0)
        let twoColW = unitColW * 2.0
        let threeColW = unitColW * 3.0
        let fourColW = unitColW * 4.0

        var row = [GridCellLayout]()
        row.reserveCapacity(6)
        var units = 0
        for index in nextIndex..<visibleCellCount {
            let text = gridCandidates[index].text
            let isEmoji = gridCandidateEmojiFlags[index]
            let len = text.count
            let span: Int
            if len >= 6 {
                span = 6
            } else if isEmoji && len == 1 {
                span = 1
            } else if !isEmoji && len <= 2 && Self.isBoundedWidthBMP(text, maxWidthPerUnit: 20.5, padding: 10.0, limit: unitColW) {
                span = 1
            } else if !isEmoji && len <= 4 && Self.isBoundedWidthBMP(text, maxWidthPerUnit: 20.5, padding: 12.0, limit: twoColW) {
                span = 2
            } else {
                let reqW = CandidateBarView.cachedTitleWidth(for: text, isEmoji: isEmoji) + 12.0
                if reqW <= unitColW {
                    span = 1
                } else if reqW <= twoColW {
                    span = 2
                } else if reqW <= threeColW {
                    span = 3
                } else if reqW <= fourColW {
                    span = 4
                } else {
                    span = 6
                }
            }
            if units + span > 6 {
                rowsModel.append(row)
                row.removeAll(keepingCapacity: true)
                units = 0
            }
            row.append(GridCellLayout(index: index, span: span, isEmoji: isEmoji))
            units += span
        }
        if !row.isEmpty { rowsModel.append(row) }

        let bodyStartRow = useFlowRow0 ? 1 : 0
        var curY: CGFloat = useFlowRow0 ? headerH : 0.0
        for r in bodyStartRow..<rowsModel.count {
            rowYOrigins.append(curY)
            rowHeights.append(bodyPitch)
            let rCells = rowsModel[r]
            var col = 0
            for cell in rCells {
                let x = floor(CGFloat(col) * unitColW * 3.0) / 3.0
                let isLastCol = col + cell.span >= 6
                let cellW = isLastCol ? max(1.0, scrollWidth - x) : min(scrollWidth - x, floor(CGFloat(cell.span) * unitColW * 3.0) / 3.0)
                let vInset: CGFloat = 2.0
                frames[cell.index] = CGRect(x: x, y: curY + vInset, width: cellW, height: max(24.0, bodyPitch - vInset * 2.0))
                col += cell.span
            }
            curY += bodyPitch
        }

        let lines = CGMutablePath()
        for r in 1..<rowsModel.count {
            lines.addRect(CGRect(x: 0, y: rowYOrigins[r] - 0.5, width: scrollWidth, height: 0.5))
        }
        drawnRows = 0..<0
        let size = CGSize(width: scrollWidth, height: curY)
        dividers.frame = CGRect(origin: .zero, size: size)
        dividers.path = lines
        if scrollView.contentSize != size {
            scrollView.contentSize = size
        }
        if renderImmediately {
            renderVisibleRows()
        }
    }

    private func renderVisibleRows() {
        guard !rowsModel.isEmpty,
              rowYOrigins.count == rowsModel.count,
              rowHeights.count == rowsModel.count,
              frames.count == visibleCellCount else { return }
        let y = max(0, scrollView.contentOffset.y)
        let height = scrollView.bounds.height > 0 ? scrollView.bounds.height : max(42, bounds.height)
        let visibleBottom = max(y + 42, scrollView.contentOffset.y + height)
        let prefetchRows = (scrollInteractionInProgress || y > 1.0) ? 1 : 0

        var startRow = 0
        while startRow < rowsModel.count - 1 && rowYOrigins[startRow] + rowHeights[startRow] <= y {
            startRow += 1
        }
        startRow = max(0, startRow - prefetchRows)

        var endRow = startRow + 1
        while endRow < rowsModel.count && rowYOrigins[endRow] < visibleBottom {
            endRow += 1
        }
        endRow = min(rowsModel.count, endRow + prefetchRows)

        let range = startRow..<endRow
        guard range != drawnRows else { return }
        drawnRows = range

        guard let firstIdx = rowsModel[startRow].first?.index,
              let lastIdx = rowsModel[endRow - 1].last?.index,
              firstIdx <= lastIdx else { return }
        let visibleIndices = firstIdx...lastIdx

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let pinnedIdx = rescuableTap?.index ?? -1
        ensureCellPoolCapacity(min(Self.maxRecycledPoolCells, visibleIndices.count + (pinnedIdx >= 0 ? 1 : 0)))

        for slot in cellButtons.indices {
            let bound = slotBoundCand[slot]
            if bound >= 0 && !visibleIndices.contains(bound) && bound != pinnedIdx {
                unbindSlot(slot)
            }
        }
        for index in visibleIndices {
            _ = bindCell(at: index)
        }
        for slot in cellButtons.indices where slotBoundCand[slot] < 0 && !cellButtons[slot].isHidden {
            unbindSlot(slot)
        }
    }

    private func acquireRecycledSlot(for index: Int) -> Int {
        for slot in cellButtons.indices where slotBoundCand[slot] == -1 {
            slotBoundCand[slot] = index
            candToSlot[index] = slot
            return slot
        }
        if cellButtons.count < Self.maxRecycledPoolCells {
            let newSlot = cellButtons.count
            ensureCellPoolCapacity(newSlot + 1)
            slotBoundCand[newSlot] = index
            candToSlot[index] = newSlot
            return newSlot
        }
        // Pool is at max cap (`42`): evict the furthest non-pinned offscreen slot.
        let viewMidY = scrollView.contentOffset.y + max(90.0, scrollView.bounds.height * 0.5)
        let pinnedIdx = rescuableTap?.index ?? -1
        var bestSlot = 0
        var bestDist: CGFloat = -1.0
        for slot in cellButtons.indices {
            let c = slotBoundCand[slot]
            if c >= 0 && c != pinnedIdx && c != 0 {
                let midY = c < frames.count ? frames[c].midY : 0.0
                let dist = abs(midY - viewMidY)
                if dist > bestDist {
                    bestDist = dist
                    bestSlot = slot
                }
            }
        }
        unbindSlot(bestSlot)
        slotBoundCand[bestSlot] = index
        candToSlot[index] = bestSlot
        return bestSlot
    }

    @discardableResult
    private func bindCell(at index: Int) -> UIButton {
        let emoji = gridCandidateEmojiFlags[index]
        let isRow0 = (lastLaidOutUseFlowRow0 == true && !rowsModel.isEmpty && index < rowsModel[0].count)
        let targetMidY: CGFloat? = isRow0 ? (emoji ? max(9.5, row0PreferredTitleMidY) : row0PreferredTitleMidY) : nil
        let targetCorner: CGFloat = (index == 0 && highlightsFirst) ? currentPillCornerRadius : 0

        let existingSlot = candToSlot[index]
        if existingSlot >= 0 {
            let bound = cellButtons[existingSlot]
            if bound.preferredTitleMidY != targetMidY {
                bound.preferredTitleMidY = targetMidY
                bound.setNeedsLayout()
            }
            if cachedCellHighlighted[existingSlot] && bound.layer.cornerRadius != targetCorner {
                bound.layer.cornerRadius = targetCorner
            }
            let targetFrame = frames[index]
            if bound.frame != targetFrame { bound.frame = targetFrame }
            if bound.isHidden { bound.isHidden = false }
            return bound
        }

        let slot = acquireRecycledSlot(for: index)
        let button = cellButtons[slot]
        let item = gridCandidates[index]
        if cachedCellTitles[slot] != item.text {
            cachedCellTitles[slot] = item.text
            button.setTitle(item.text, for: .normal)
        }
        if cachedCellEmoji[slot] != emoji {
            cachedCellEmoji[slot] = emoji
            button.titleLabel?.font = emoji ? CandidateBarView.emojiCandidateFont : CandidateBarView.candidateFont
        }
        let dark = traitCollection.userInterfaceStyle == .dark
        let highlight = (index == 0 && highlightsFirst)
        if cachedCellHighlighted[slot] != highlight
            || (highlight && (cachedCellDark[slot] != dark || button.layer.cornerRadius != targetCorner)) {
            cachedCellHighlighted[slot] = highlight
            cachedCellDark[slot] = dark
            button.setTitleColor(highlight ? (dark ? .white : .black) : KeyboardTheme.dynamicPrimaryText, for: .normal)
            button.backgroundColor = highlight ? KeyboardTheme.candidateHighlightPillFill(dark: dark) : .clear
            button.layer.cornerRadius = targetCorner
        }
        if button.preferredTitleMidY != targetMidY {
            button.preferredTitleMidY = targetMidY
            button.setNeedsLayout()
        }
        if item.isDeletableUserPhrase && cellLongPresses[slot] == nil {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            press.minimumPressDuration = 0.45
            button.addGestureRecognizer(press)
            cellLongPresses[slot] = press
        }
        if let press = cellLongPresses[slot], press.isEnabled != item.isDeletableUserPhrase {
            press.isEnabled = item.isDeletableUserPhrase
        }
        if button.tag != index {
            button.tag = index
        }
        let targetFrame = frames[index]
        if button.frame != targetFrame {
            button.frame = targetFrame
        }
        if button.isHidden {
            button.isHidden = false
        }
        return button
    }

    // MARK: - Grid Touch & Micro-Roll Rescue

    private var isActivelyDraggingGrid: Bool {
        let st = scrollView.panGestureRecognizer.state
        return st == .began || st == .changed || scrollView.isDragging
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollTrace?.record("被新拖动中断", scrollView)
        scrollTrace = CandidateScrollTrace(horizontal: false, scroll: scrollView, count: gridCandidates.count)
        scrollInteractionInProgress = true
        if didTriggerLongPressDelete {
            rescuableTap = nil
        }
        lastGridScrollNoteUptime = ProcessInfo.processInfo.systemUptime
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(true, owner: self)
    }

    private func checkAutoRevealFilterBarOnScroll(_ scrollView: UIScrollView) {
        guard showsComposingFilterBar, !isFilterBarRevealed, !isHidden else { return }
        let offsetY = scrollView.contentOffset.y
        // 1. Native pull-down at top (`<= -18pt` overscroll while dragging, or `<= -22pt` programmatic pull)
        if offsetY <= -18.0 && (isActivelyDraggingGrid || offsetY <= -22.0) {
            revealFilterBar(animated: window != nil, playHaptic: isActivelyDraggingGrid)
            return
        }
        // 2. Auto-reveal when scrolling down past ~1 screen looking for rare characters
        let effW = bounds.width > 1.0 ? bounds.width : 440.0
        let effH = (bounds.height > 1.0 && bounds.height <= 420.0) ? bounds.height : 224.5
        let headerH = effectiveHeaderRowHeight(panelWidth: effW, panelHeight: effH)
        let oneScreenThreshold = max(128.0, (effH - headerH) * 0.72)
        if offsetY >= oneScreenThreshold && scrollView.contentSize.height > effH + 36.0 {
            revealFilterBar(animated: window != nil, playHaptic: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isAdjustingFilterChromeInset { return }
        checkAutoRevealFilterBarOnScroll(scrollView)
        renderVisibleRows()
        scrollTrace?.moved(scrollView)
        if isActivelyDraggingGrid || scrollView.isDecelerating {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastGridScrollNoteUptime >= 0.08 {
                lastGridScrollNoteUptime = now
                LokeyDiagnosticLogger.shared.noteScrollActivity()
            }
        }
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let minY = -scrollView.contentInset.top
        if minY < -0.5, targetContentOffset.pointee.y > minY, targetContentOffset.pointee.y < 0.0 {
            targetContentOffset.pointee.y = (velocity.y > 0.35) ? 0.0 : minY
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollTrace?.record(decelerate ? "松手进入惯性" : "松手停稳", scrollView)
        if !decelerate { scrollTrace = nil }
        scrollInteractionInProgress = decelerate
        defer { if !decelerate { onInteractionEnded?() } }
        let minY = -scrollView.contentInset.top
        if !decelerate {
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
            if scrollView.contentOffset.y < minY {
                scrollView.setContentOffset(CGPoint(x: 0.0, y: minY), animated: false)
            } else if minY < -0.5 && scrollView.contentOffset.y < 0.0 && scrollView.contentOffset.y > minY {
                scrollView.setContentOffset(CGPoint(x: 0.0, y: minY), animated: window != nil)
            }
        }
        guard !decelerate, let rescue = rescuableTap else {
            rescuableTap = nil
            return
        }
        rescuableTap = nil
        let now = ProcessInfo.processInfo.systemUptime
        let dy = abs(scrollView.contentOffset.y - rescue.startOffsetY)
        if dy <= 11.5 && (now - rescue.touchDownUptime) <= 0.45 && rescue.index < visibleCellCount {
            lastGridCommitUptime = now
            dispatchDisplayedCandidate(rescue.index, source: "轻微滑动救回")
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollTrace?.record("惯性结束", scrollView)
        scrollTrace = nil
        scrollInteractionInProgress = false
        defer { onInteractionEnded?() }
        rescuableTap = nil
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
    }

    private func handleDecelerationBrakeTap(at ptInScroll: CGPoint) {
        guard !isActivelyDraggingGrid else { return }
        scrollTrace?.record("惯性被点停", scrollView)
        scrollTrace = nil
        scrollInteractionInProgress = false
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        defer { onInteractionEnded?() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGridCommitUptime > 0.06 else { return }
        rescuableTap = nil
        let minY = -scrollView.contentInset.top
        for idx in frames.indices where frames[idx].insetBy(dx: -4.0, dy: -3.0).contains(ptInScroll) {
            if scrollView.isDecelerating || scrollView.contentOffset.y < minY {
                scrollView.setContentOffset(CGPoint(x: 0.0, y: max(minY, scrollView.contentOffset.y)), animated: false)
            }
            lastGridCommitUptime = now
            lastGridBrakeCommitUptime = now
            dispatchDisplayedCandidate(idx, source: "惯性点选")
            return
        }
        if scrollView.contentOffset.y < minY {
            scrollView.setContentOffset(CGPoint(x: 0.0, y: minY), animated: false)
        }
    }

    @objc private func handleTouchDown(_ sender: UIButton, forEvent event: UIEvent?) {
        guard !isHidden else { return }
        if let event, let touches = event.allTouches, !touches.isEmpty,
           lastGridCommitUptime > 0,
           touches.contains(where: { $0.timestamp > 0 && $0.timestamp <= lastGridCommitUptime + 0.002 }) {
            return
        }
        let idx = sender.tag
        guard idx >= 0 && idx < visibleCellCount else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let startY = scrollView.contentOffset.y
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .expandedPressed(idx))
        pendingTouchStartOffsetY = startY
        didTriggerLongPressDelete = false
        rescuableTap = RescuableGridTap(index: idx, title: gridCandidates[idx].text, startOffsetY: startY, touchDownUptime: now)
    }

    @objc private func handleTap(_ sender: UIButton, forEvent event: UIEvent?) {
        defer { onInteractionEnded?() }
        guard !isHidden, rescuableTap?.index == sender.tag else {
            rescuableTap = nil
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .expandedReleaseInvalidated(sender.tag))
            return
        }
        rescuableTap = nil
        scrollView.resetBrakeTouchTracking()
        guard !didTriggerLongPressDelete else {
            didTriggerLongPressDelete = false
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let event {
            if let touches = event.allTouches, !touches.isEmpty,
               lastGridCommitUptime > 0,
               touches.contains(where: { $0.timestamp > 0 && $0.timestamp <= lastGridCommitUptime + 0.002 }) {
                return
            }
            if now - lastGridCommitUptime <= 0.06 {
                return
            }
        }
        guard now - lastGridBrakeCommitUptime > 0.06 else {
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .staticText("展开面板抬手忽略 原因=惯性点选已处理"))
            return
        }
        let dy = abs(scrollView.contentOffset.y - pendingTouchStartOffsetY)
        guard !isActivelyDraggingGrid, dy < 12.0 else {
            LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .staticText("展开面板抬手忽略 原因=纵滑"))
            return
        }
        let idx = sender.tag
        guard idx >= 0 && idx < visibleCellCount else { return }
        let minY = -scrollView.contentInset.top
        if scrollView.isDecelerating || scrollView.contentOffset.y < minY {
            scrollView.setContentOffset(CGPoint(x: 0.0, y: max(minY, scrollView.contentOffset.y)), animated: false)
        }
        lastGridCommitUptime = now
        dispatchDisplayedCandidate(idx, source: "点击")
    }

    @objc private func handleTouchCancel(_ sender: UIButton) {
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .expandedCancelled(sender.tag))
        defer { onInteractionEnded?() }
        if didTriggerLongPressDelete {
            rescuableTap = nil
        } else if let tap = rescuableTap {
            // UIKit may deliver touchCancel just before scrollViewWillBeginDragging.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.scrollInteractionInProgress,
                      self.rescuableTap?.touchDownUptime == tap.touchDownUptime else { return }
                self.rescuableTap = nil
                self.onInteractionEnded?()
            }
        }
        didTriggerLongPressDelete = false
    }

    @objc private func handleTouchUpOutside(_ sender: UIButton) {
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .expandedTouchUpOutside(sender.tag))
        defer { onInteractionEnded?() }
        rescuableTap = nil
        didTriggerLongPressDelete = false
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !isActivelyDraggingGrid, let btn = recognizer.view as? UIButton else { return }
        let index = btn.tag
        guard index >= 0, index < gridCandidates.count else { return }
        didTriggerLongPressDelete = true
        rescuableTap = nil
        let minY = -scrollView.contentInset.top
        if scrollView.isDecelerating || scrollView.contentOffset.y < minY {
            scrollView.setContentOffset(CGPoint(x: 0.0, y: max(minY, scrollView.contentOffset.y)), animated: false)
        }
        LokeyDiagnosticLogger.shared.recordCandidateBarEventFast(event: .expandedLongPressDelete(index))
        if activeFilterTab != .all {
            guard index < activeFilteredPairs.count else { return }
            let pair = activeFilteredPairs[index]
            guard pair.display.isDeletableUserPhrase || pair.canonical?.isDeletableUserPhrase == true else { return }
            onDeleteExplicitCandidate?(pair.display, pair.canonical)
            return
        }
        guard gridCandidates[index].isDeletableUserPhrase else { return }
        onDeleteCandidate?(index)
    }
}
