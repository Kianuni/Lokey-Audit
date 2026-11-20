import AudioToolbox
import UIKit

/// Renders the 4-row pixel-calibrated iOS 26 keyboard key grid with zero-dead-zone Voronoi hit testing,
/// rollover multi-touch support, spacebar trackpad cursor control, accelerated backspace, and CoreHaptics feedback.
final class KeyGridView: UIView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        true
    }

    enum Page: Equatable {
        case alphabetic
        case numeric
        case symbolic
    }

    enum ShiftState: Equatable {
        case lower
        case oneShotUpper
        case capsLocked
    }

    enum KeyRole: Equatable {
        case letter(Character)       // 'a'...'z'
        case symbol(String)          // Direct punctuation / number
        case shift
        case backspace
        case pageSwitch(Page, String)
        case globe
        case emoji
        case smartPeriod
        case space
        case returnKey
    }

    private struct KeyItem {
        let role: KeyRole
        var frame: CGRect
        let view: KeycapItemView
    }

    // MARK: - Callbacks

    var onBeforeKeyTouchDown: (() -> Void)?
    var onActiveKeyTouchDown: (() -> Void)?
    var onTouchDownSettingsCheck: (() -> Void)?
    var touchSequence: ((UITouch, UIEvent?) -> UInt64)?
    var onLetterTap: ((Character, CGPoint, Bool, UInt64) -> Void)?
    var onSymbolTap: ((String) -> Void)?
    var shouldDeferLineBreakDeletion: (() -> Bool)?
    var onBackspaceTap: (() -> Void)?
    var onBackspaceSwipeClear: ((Bool) -> Void)?
    var onSpaceTap: (() -> Void)?
    var onReturnTap: (() -> Void)?
    var onPeriodTap: (() -> Void)?
    var onEmojiTap: (() -> Void)?
    var onMoveCursor: ((Int) -> Void)?
    var onGlobeEvent: ((UIView, UIEvent) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onAnchorsUpdated: (([SpatialTouchModel.KeyAnchor]) -> Void)? {
        didSet {
            lastReportedAnchorGeometryKey = nil
            lastLaidOutGridSize = .zero
        }
    }
    var onPageChanged: ((Page) -> Void)?

    // MARK: - Configurable State

    var page: Page = .alphabetic {
        didSet {
            pendingDeferredPage = nil
            if oldValue != page {
                lastLaidOutGridSize = .zero
                rebuildKeys()
                onPageChanged?(page)
            }
        }
    }

    func scheduleAutoReturnToAlphabetic() {
        guard page != .alphabetic else { return }
        if !isHandlingTouchDown {
            page = .alphabetic
            return
        }
        pendingDeferredPage = .alphabetic
        DispatchQueue.main.async { [weak self] in
            self?.flushDeferredPageIfNeeded()
        }
    }

    func flushDeferredPageIfNeeded() {
        guard let next = pendingDeferredPage else { return }
        pendingDeferredPage = nil
        if page != next {
            page = next
        }
    }

    var shiftState: ShiftState = .lower {
        didSet {
            if oldValue != shiftState {
                if isHandlingTouchDown {
                    pageNeedsAppearanceRefresh = true
                    scheduleDeferredAppearanceRefresh()
                } else {
                    refreshKeyAppearances()
                }
            }
        }
    }

    var showPeriodBesideSpace: Bool = false {
        didSet {
            if oldValue != showPeriodBesideSpace {
                rebuildKeys()
            }
        }
    }

    var needsGlobeKey: Bool = false {
        didSet {
            if oldValue != needsGlobeKey {
                rebuildKeys()
            }
        }
    }

    var isChineseContext: Bool = true {
        didSet {
            if oldValue != isChineseContext && showPeriodBesideSpace && page == .alphabetic {
                if isHandlingTouchDown {
                    bottomRowNeedsAppearanceRefresh = true
                    scheduleDeferredAppearanceRefresh()
                } else {
                    refreshBottomRowAppearanceOnly()
                }
            }
        }
    }

    /// True whenever the keyboard is in Chinese Pinyin mode (as opposed to pure ASCII English lock).
    /// Controls both the Chinese punctuation keyset on `.numeric`/`.symbolic` and the `拼` watermark on the spacebar.
    var isPinyinMode: Bool = true {
        didSet {
            if oldValue != isPinyinMode {
                if page != .alphabetic {
                    rebuildKeys()
                } else if isHandlingTouchDown {
                    bottomRowNeedsAppearanceRefresh = true
                    scheduleDeferredAppearanceRefresh()
                } else {
                    refreshBottomRowAppearanceOnly()
                }
            }
        }
    }

    var spaceTitle: String = ""

    var isComposing: Bool = false
    var enableComposingSpaceTrackpad: Bool = false

    private static let audioQueue = DispatchQueue(label: "com.kianuni.lokey.keyAudio", qos: .userInitiated)
    private static var audioStateLock = os_unfair_lock_s()
    private static var isAudioClickInFlight = false
    private var isInputClickScheduled = false

    var returnKeyType: UIReturnKeyType = .default {
        didSet {
            if oldValue != returnKeyType {
                if isHandlingTouchDown {
                    returnKeyNeedsAppearanceRefresh = true
                    scheduleDeferredAppearanceRefresh()
                } else {
                    refreshReturnKeyAppearanceOnly()
                }
            }
        }
    }

    /// Tracks `enablesReturnKeyAutomatically` disabled state on empty host fields (e.g. WeChat `↑` grey disabled Return key).
    var isReturnKeyEnabled: Bool = true {
        didSet {
            if oldValue != isReturnKeyEnabled {
                if isHandlingTouchDown {
                    returnKeyNeedsAppearanceRefresh = true
                    scheduleDeferredAppearanceRefresh()
                } else {
                    refreshReturnKeyAppearanceOnly()
                }
            }
        }
    }

    var hapticFeedbackIntensity: Double = 0.65 {
        didSet {
            let clamped = min(1.0, max(0.0, hapticFeedbackIntensity))
            if hapticFeedbackIntensity != clamped {
                hapticFeedbackIntensity = clamped
                return
            }
            guard abs(clamped - oldValue) > 0.0001 else { return }
            if clamped == 0.0 {
                _hapticStrength = .off
            } else if clamped <= 0.70 {
                _hapticStrength = .light
            } else {
                _hapticStrength = .crisp
            }
            if window != nil {
                prepareHaptics()
            }
        }
    }

    private var _hapticStrength: HapticStrength = .light
    var hapticStrength: HapticStrength {
        get { _hapticStrength }
        set {
            _hapticStrength = newValue
            switch newValue {
            case .off:
                if hapticFeedbackIntensity != 0.0 {
                    hapticFeedbackIntensity = 0.0
                }
            case .light:
                if hapticFeedbackIntensity == 0.0 || hapticFeedbackIntensity > 0.70 {
                    hapticFeedbackIntensity = 0.65
                }
            case .crisp:
                if hapticFeedbackIntensity <= 0.70 {
                    hapticFeedbackIntensity = 1.0
                }
            }
        }
    }

    var isKeyClickSoundEnabled: Bool = true
    var hasFullAccessProvider: (() -> Bool)?
    private var _hasFullAccess: Bool = false
    var hasFullAccess: Bool {
        get { hasFullAccessProvider?() ?? _hasFullAccess }
        set { _hasFullAccess = newValue }
    }

    weak var calloutBubble: KeyCalloutBubbleView? {
        didSet {
            prewarmCalloutIfNeeded()
        }
    }

    // MARK: - Private State

    private struct AnchorGeometryKey: Equatable {
        let w2: Int32
        let h2: Int32
        let showPeriod: Bool
        let needsGlobe: Bool
    }

    private static let letterLowerFont = UIFont.systemFont(ofSize: 25.0, weight: .regular)
    private static let letterUpperFont = UIFont.systemFont(ofSize: 22.5, weight: .regular)
    private static let symSingleFont = UIFont.systemFont(ofSize: 22.0, weight: .regular)
    private static let symMultiFont = UIFont.systemFont(ofSize: 17.5, weight: .regular)
    private static let shiftFont = UIFont.systemFont(ofSize: 18.8, weight: .regular)
    private static let backspaceFont = UIFont.systemFont(ofSize: 19.0, weight: .regular)
    private static let pageHashFont = UIFont.systemFont(ofSize: 13.8, weight: .regular)
    private static let pagePinyinFont = UIFont.systemFont(ofSize: 15.8, weight: .regular)
    private static let pageABCFont = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    private static let page123Font = UIFont.systemFont(ofSize: 18.0, weight: .regular)
    private static let globeFont = UIFont.systemFont(ofSize: 19.0, weight: .regular)
    private static let emojiFont = UIFont.systemFont(ofSize: 20.0, weight: .regular)
    private static let smartPeriodFont = UIFont.systemFont(ofSize: 21.0, weight: .regular)
    private static let spaceFont = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    private static let returnTitleMediumFont = UIFont.systemFont(ofSize: 16.5, weight: .medium)
    private static let returnTitleRegularFont = UIFont.systemFont(ofSize: 16.5, weight: .regular)
    private static let returnIconMediumFont = UIFont.systemFont(ofSize: 19.0, weight: .medium)
    private static let returnIconRegularFont = UIFont.systemFont(ofSize: 19.0, weight: .regular)
    private static let returnDisabledSendArrowFont = UIFont.systemFont(ofSize: 17.0, weight: .medium)

    private var rowItems: [[KeyItem]] = [[], [], [], []]
    private(set) var isHandlingTouchDown = false
    var hasActiveTouches: Bool {
        !activeTouches.isEmpty || isTrackpadActive
    }
    private var pageNeedsAppearanceRefresh = false
    private var bottomRowNeedsAppearanceRefresh = false
    private var returnKeyNeedsAppearanceRefresh = false
    private var deferredAppearanceScheduled = false
    private var needsRelayoutWhenUnhidden = false
    private var alphaRegionTop: CGFloat = 0
    private var alphaRegionHeight: CGFloat = 1
    private var lastReportedAnchorGeometryKey: AnchorGeometryKey?
    private var lastLaidOutGridSize: CGSize = .zero
    private var lastLaidOutPage: Page?
    private var pendingDeferredPage: Page?

    override var isHidden: Bool {
        didSet {
            if oldValue && !isHidden && needsRelayoutWhenUnhidden {
                needsRelayoutWhenUnhidden = false
                setNeedsLayout()
                layoutIfNeeded()
            }
        }
    }

    private struct ActiveTouchState {
        let touchSeq: UInt64
        let initialRole: KeyRole
        var rowIndex: Int
        var colIndex: Int
        let initialPoint: CGPoint
        var currentPoint: CGPoint
        let touchDownTime: TimeInterval
        let wasComposingAtTouchDown: Bool
        var hasUnlockedSlide: Bool
        var didCommitOnTouchDown: Bool
        var didTriggerBackspaceSwipeClear: Bool
        var calloutLabel: String?
        var isMomentaryNumericSlide: Bool = false
    }

    private var activeTouches: [UITouch: ActiveTouchState] = [:]
    private var currentlyPressedKeys: Set<Int> = []
    private var lastShiftTapTime: TimeInterval = 0
    private var lastHapticUptime: TimeInterval = -10
    private var lastAudioUptime: TimeInterval = -10

    // Spacebar / Shift trackpad state
    private var spaceLongPressTimer: Timer?
    private var isTrackpadActive = false
    private weak var trackpadTouch: UITouch?
    private var trackpadAccumulatedDX: CGFloat = 0
    private var lastTrackpadPoint: CGPoint = .zero

    // Accelerated Backspace repeat state
    private var pendingLineBreakDeletion = false
    private weak var backspaceOwner: UITouch?
    private var backspaceDelayTimer: Timer?
    private var backspaceRepeatTimer: Timer?
    private var backspaceTickCount: Int = 0

    // Long-press 123 -> Quick Settings timer & momentary 123 press-slide-release state
    private var settingsLongPressTimer: Timer?
    private var didTriggerSettingsLongPress = false
    private(set) var isMomentaryNumericSlideActive = false
    private(set) var isCommittingMomentaryNumericSymbol = false
    private weak var momentaryNumericSlideTouch: UITouch?

    private lazy var selectionFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardTheme.hitTestableClearBacking
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        clipsToBounds = false
        KeycapItemView.prewarmAllSymbols()
        rebuildKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelAllTimersAndTouches()
    }

    func resetTransientInteractions() {
        guard !activeTouches.isEmpty
            || isTrackpadActive
            || isMomentaryNumericSlideActive
            || spaceLongPressTimer != nil
            || backspaceDelayTimer != nil
            || backspaceRepeatTimer != nil
            || settingsLongPressTimer != nil
            || calloutBubble?.isHidden == false else {
            return
        }
        let wasTrackpad = isTrackpadActive
        let wasMomentaryNumeric = isMomentaryNumericSlideActive
        isMomentaryNumericSlideActive = false
        momentaryNumericSlideTouch = nil
        cancelAllTimersAndTouches()
        if wasMomentaryNumeric && page != .alphabetic {
            page = .alphabetic
            return
        }
        if wasTrackpad {
            refreshKeyAppearances()
        } else {
            updatePressedKeyStatesDiff()
        }
    }

    func prepareHaptics() {
        guard hapticFeedbackIntensity > 0.0 else { return }
        LokeyHapticEngine.shared.prepare(forIntensity: hapticFeedbackIntensity)
    }

    func triggerHaptic(intensityOverride: Double? = nil) {
        let intensity = intensityOverride ?? hapticFeedbackIntensity
        guard intensity > 0.0 else { return }
        if intensityOverride == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHapticUptime >= 0 && now - lastHapticUptime < 0.014 {
                return
            }
            lastHapticUptime = now
        }
        LokeyHapticEngine.shared.playTap(intensity: intensity)
    }

    // MARK: - Key Click Audio Feedback

    enum KeySoundType {
        case standard // 1104
        case delete   // 1155
        case modifier // 1156
    }

    func playKeySound(type: KeySoundType) {
        guard isKeyClickSoundEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAudioUptime >= 0 && now - lastAudioUptime < 0.022 {
            return
        }
        lastAudioUptime = now
        if hasFullAccess {
            let soundID: SystemSoundID
            switch type {
            case .standard:
                soundID = 1104
            case .delete:
                soundID = 1155
            case .modifier:
                soundID = 1156
            }
            os_unfair_lock_lock(&Self.audioStateLock)
            if Self.isAudioClickInFlight {
                os_unfair_lock_unlock(&Self.audioStateLock)
                return
            }
            Self.isAudioClickInFlight = true
            os_unfair_lock_unlock(&Self.audioStateLock)
            Self.audioQueue.async {
                AudioServicesPlaySystemSound(soundID)
                os_unfair_lock_lock(&Self.audioStateLock)
                Self.isAudioClickInFlight = false
                os_unfair_lock_unlock(&Self.audioStateLock)
            }
        } else if !isInputClickScheduled {
            isInputClickScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.isInputClickScheduled = false
                UIDevice.current.playInputClick()
            }
        }
    }

    func playKeySound(for role: KeyRole) {
        switch role {
        case .backspace:
            playKeySound(type: .delete)
        case .returnKey, .shift, .pageSwitch, .globe, .emoji:
            playKeySound(type: .modifier)
        case .letter, .symbol, .smartPeriod, .space:
            playKeySound(type: .standard)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            disableAncestorGestureTouchDelays()
            refreshKeyAppearances()
            prewarmCalloutIfNeeded()
            prepareHaptics()
        } else {
            resetTransientInteractions()
        }
    }

    private func disableAncestorGestureTouchDelays() {
        var cur: UIView? = self
        while let v = cur {
            for gr in v.gestureRecognizers ?? [] {
                gr.delaysTouchesBegan = false
                gr.delaysTouchesEnded = false
            }
            cur = v.superview
        }
        for gr in window?.gestureRecognizers ?? [] {
            gr.delaysTouchesBegan = false
            gr.delaysTouchesEnded = false
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshKeyAppearances()
        }
    }

    // MARK: - Key Hierarchy Construction

    private func rebuildKeys() {
        cancelAllTimersAndTouches()
        lastLaidOutGridSize = .zero
        let rolesPerRow = makeRoles(for: page)
        // Page changes move a slot between the middle rows. Reuse the same keycap
        // across rows so the numeric-to-letter transition never needs a new view.
        let views = rowItems.flatMap { $0.map(\.view) }
        var slot = 0
        for (row, roles) in rolesPerRow.enumerated() {
            rowItems[row] = roles.map { role in
                let view: KeycapItemView
                if slot < views.count {
                    view = views[slot]
                } else {
                    view = KeycapItemView()
                    addSubview(view)
                }
                slot += 1
                return KeyItem(role: role, frame: .zero, view: view)
            }
        }
        for view in views.dropFirst(slot) { view.removeFromSuperview() }

        if isHidden {
            needsRelayoutWhenUnhidden = true
            setNeedsLayout()
        } else if Self.isValidGridSize(width: bounds.width, height: bounds.height) {
            layoutKeyFrames(width: bounds.width, height: bounds.height)
        } else if bounds.width > 40 && bounds.height > 40 && bounds.height < Self.minimumValidGridHeight(forWidth: bounds.width) {
            layoutKeyFrames(width: bounds.width, height: Self.canonicalFallbackGridHeight(forWidth: bounds.width))
        } else {
            setNeedsLayout()
        }
        // Rollover needs the new hit map within this event. UIKit draws the new labels in its layout pass.
        if isHandlingTouchDown {
            pageNeedsAppearanceRefresh = true
            scheduleDeferredAppearanceRefresh()
            setNeedsLayout()
        } else {
            refreshKeyAppearances()
        }
    }

    static func minimumValidGridHeight(forWidth w: CGFloat) -> CGFloat {
        if w > 520.0 {
            return 140.0
        }
        return w >= 428.0 ? 210.0 : 196.0
    }

    static func canonicalFallbackGridHeight(forWidth w: CGFloat) -> CGFloat {
        if w > 520.0 {
            return KeyboardTheme.standardLandscapeKeyboardHeight - KeyboardTheme.candidateBarLandscapeHeight
        }
        return w >= 428.0 ? 224.5 : 206.0
    }

    static func isValidGridSize(width w: CGFloat, height h: CGFloat) -> Bool {
        w > 40.0 && h >= minimumValidGridHeight(forWidth: w) && h <= 360.0
    }

    private var hasLaidOutKeyFrames: Bool {
        guard let firstKey = rowItems.first?.first else { return false }
        return firstKey.frame.width > 0.0 && firstKey.frame.height > 0.0
    }

    /// Preserves full Row 0–3 hit-testing reach (`224.5pt` / `206.0pt`) even while the host `UIInputView`
    /// is transiently attached at a shorter compat height (`176.0pt`).
    private var effectiveHitHeight: CGFloat {
        let bottomRowMaxY = rowItems.last?.first?.frame.maxY ?? 0.0
        return max(bounds.height, bottomRowMaxY)
    }

    private func makeRoles(for page: Page) -> [[KeyRole]] {
        let bottomLeft: KeyRole
        switch page {
        case .alphabetic:
            bottomLeft = .pageSwitch(.numeric, "123")
        case .numeric, .symbolic:
            bottomLeft = .pageSwitch(.alphabetic, isPinyinMode ? "拼音" : "ABC")
        }

        var row3: [KeyRole] = [bottomLeft]
        if needsGlobeKey {
            row3.append(.globe)
        }
        row3.append(.emoji)
        if showPeriodBesideSpace && page == .alphabetic {
            row3.append(.smartPeriod)
        }
        row3.append(.space)
        row3.append(.returnKey)

        switch page {
        case .alphabetic:
            let r0 = Array("qwertyuiop").map { KeyRole.letter($0) }
            let r1 = Array("asdfghjkl").map { KeyRole.letter($0) }
            let r2 = [.shift] + Array("zxcvbnm").map { KeyRole.letter($0) } + [.backspace]
            return [r0, r1, r2, row3]

        case .numeric:
            let r0 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { KeyRole.symbol($0) }
            let r1 = isPinyinMode
                ? ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"].map { KeyRole.symbol($0) }
                : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { KeyRole.symbol($0) }
            let midPunct = isPinyinMode
                ? ["。", "，", "、", "？", "！", "."]
                : [".", ",", "?", "!", "'", "-"]
            let r2 = [.pageSwitch(.symbolic, "#+=")] + midPunct.map { KeyRole.symbol($0) } + [.backspace]
            return [r0, r1, r2, row3]

        case .symbolic:
            let r0 = isPinyinMode
                ? ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="].map { KeyRole.symbol($0) }
                : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { KeyRole.symbol($0) }
            let r1 = isPinyinMode
                ? ["_", "—", "\\", "|", "～", "《", "》", "€", "&", "·"].map { KeyRole.symbol($0) }
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { KeyRole.symbol($0) }
            let midSym = isPinyinMode
                ? ["…", "，", "、", "？", "！", "’"]
                : [".", ",", "?", "!", "'", "`"]
            let r2 = [.pageSwitch(.numeric, "123")] + midSym.map { KeyRole.symbol($0) } + [.backspace]
            return [r0, r1, r2, row3]
        }
    }

    // MARK: - Pixel-Calibrated Native iOS 26 Proportional Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden else {
            needsRelayoutWhenUnhidden = true
            return
        }
        defer { flushDeferredAppearancesIfNeeded() }
        let w = bounds.width
        let h = bounds.height
        // Ignore transient zero-sized, compressed legacy host compat frames (`gridH = 168..176pt` when `view = 216..224pt`),
        // or fullscreen host snapshot frames (`gridH = 908pt` during app-switch animations) so physical keycap frames
        // and `SpatialTouchModel` normalized anchors are never distorted!
        if !Self.isValidGridSize(width: w, height: h) {
            if !hasLaidOutKeyFrames && w > 40.0 && h > 40.0 && h < Self.minimumValidGridHeight(forWidth: w) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                layoutKeyFrames(width: w, height: Self.canonicalFallbackGridHeight(forWidth: w))
            }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layoutKeyFrames(width: w, height: h)
    }

    private func layoutKeyFrames(width w: CGFloat, height h: CGFloat) {
        let targetGridSize = CGSize(width: w, height: h)
        if hasLaidOutKeyFrames
            && lastLaidOutGridSize == targetGridSize
            && lastLaidOutPage == page
            && (page != .alphabetic || onAnchorsUpdated == nil || lastReportedAnchorGeometryKey != nil) {
            return
        }
        lastLaidOutGridSize = targetGridSize
        lastLaidOutPage = page

        let isLandscape = w > 520
        let isCompactPortraitGrid = !isLandscape && h < 216.0
        // Exact iOS 26 Liquid Glass margins & gaps:
        // - Max/Plus (`h >= 216pt`, e.g. `224.5pt`): `topPad = 4.5pt`, `bottomPad = 7.0pt`, `vGap = 11.0pt` -> `keyH = 45.0pt`
        // - Pro/Standard (`h < 216pt`, e.g. `206.0pt`): `topPad = 4.5pt`, `bottomPad = 1.5pt`, `vGap = 10.5pt` -> `keyH = 42.125pt`
        let sideInset: CGFloat = isLandscape ? 6.0 : 6.5
        let hGap: CGFloat = isLandscape ? 7.0 : 6.25
        let topPad = KeyboardTheme.firstKeyRowTopInset(forWidth: w)
        let bottomPad: CGFloat = isLandscape ? 4.0 : (isCompactPortraitGrid ? 1.5 : 7.0)
        let vGap: CGFloat = isLandscape ? 7.0 : (isCompactPortraitGrid ? 10.5 : 11.0)

        let keyH = max(30.0, (h - topPad - bottomPad - vGap * 3.0) / 4.0)
        let stdKeyW = (w - sideInset * 2.0 - hGap * 9.0) / 10.0

        // Row 0: 10 equal-width keys (`q`..`p`)
        let y0 = topPad
        for i in 0..<rowItems[0].count {
            let x = sideInset + CGFloat(i) * (stdKeyW + hGap)
            let f = CGRect(x: x, y: y0, width: stdKeyW, height: keyH)
            rowItems[0][i].frame = f
            if !isHandlingTouchDown && rowItems[0][i].view.frame != f { rowItems[0][i].view.frame = f }
        }

        // Row 1: 9 keys centered on alphabetic page (`a`..`l`), or 10 keys on numeric/symbolic
        let y1 = y0 + keyH + vGap
        let count1 = rowItems[1].count
        let totalW1 = CGFloat(count1) * stdKeyW + CGFloat(max(0, count1 - 1)) * hGap
        let startX1 = (w - totalW1) * 0.5
        for i in 0..<count1 {
            let x = startX1 + CGFloat(i) * (stdKeyW + hGap)
            let f = CGRect(x: x, y: y1, width: stdKeyW, height: keyH)
            rowItems[1][i].frame = f
            if !isHandlingTouchDown && rowItems[1][i].view.frame != f { rowItems[1][i].view.frame = f }
        }

        // Row 2: [Left Modifier] + centered middle keys (`z`..`m`) + [Backspace]
        let y2 = y1 + keyH + vGap
        let count2 = rowItems[2].count
        if count2 >= 3 {
            let midCount = count2 - 2
            // Calibrated to native iOS 26 `115.5px / 85.7px = 1.348`
            let sideModW = max(stdKeyW * 1.348, 42.0)
            let midKeyW: CGFloat
            if page == .alphabetic {
                midKeyW = stdKeyW
            } else {
                // 6 wider punctuation keys in numeric/symbolic Row 2, calibrated to native iOS (`108..180px` in `704px`)
                let availMid = w - sideInset * 2.0 - sideModW * 2.0 - hGap * 2.0 - 10.0
                midKeyW = (availMid - CGFloat(midCount - 1) * hGap) / CGFloat(midCount)
            }
            let totalMidW = CGFloat(midCount) * midKeyW + CGFloat(midCount - 1) * hGap
            let startMidX = (w - totalMidW) * 0.5

            let leftFrame = CGRect(x: sideInset, y: y2, width: sideModW, height: keyH)
            rowItems[2][0].frame = leftFrame
            if !isHandlingTouchDown && rowItems[2][0].view.frame != leftFrame { rowItems[2][0].view.frame = leftFrame }

            for m in 0..<midCount {
                let x = startMidX + CGFloat(m) * (midKeyW + hGap)
                let f = CGRect(x: x, y: y2, width: midKeyW, height: keyH)
                rowItems[2][1 + m].frame = f
                if !isHandlingTouchDown && rowItems[2][1 + m].view.frame != f { rowItems[2][1 + m].view.frame = f }
            }

            let rightFrame = CGRect(x: w - sideInset - sideModW, y: y2, width: sideModW, height: keyH)
            rowItems[2][count2 - 1].frame = rightFrame
            if !isHandlingTouchDown && rowItems[2][count2 - 1].view.frame != rightFrame { rowItems[2][count2 - 1].view.frame = rightFrame }
        }

        // Row 3: Exact Apple `UIKBTree` symmetric geometry!
        // `space.minX` aligns to the pixel with `d.minX` & `x.minX` (`sideInset + 2.5 * (stdKeyW + hGap)`),
        // and `space.maxX` aligns to the pixel with `j.maxX` & `n.maxX` (`w - sideInset - 2.5 * (stdKeyW + hGap)`),
        // making `123` == `😊` == `1.25 * stdKeyW + 0.25 * hGap` and `⏎` == `2.5 * stdKeyW + 1.5 * hGap`!
        let y3 = y2 + keyH + vGap
        let r3 = rowItems[3]
        if !r3.isEmpty {
            let symmetricSideGroupW = 2.5 * stdKeyW + 1.5 * hGap
            let returnW = symmetricSideGroupW

            let modeSwitchW: CGFloat
            let globeW: CGFloat
            let emojiW: CGFloat
            if needsGlobeKey {
                // Home-button device fallback with 3 left buttons (`123`, `🌐`, `😊`)
                let threeBtnGroupW = 3.0 * stdKeyW + 2.0 * hGap
                let each = (threeBtnGroupW - 2.0 * hGap) / 3.0
                modeSwitchW = each
                globeW = each
                emojiW = each
            } else {
                // Standard Face ID iPhone / iOS 26: `123` and `😊` split `symmetricSideGroupW` equally!
                let each = (symmetricSideGroupW - hGap) * 0.5
                modeSwitchW = each
                globeW = 0
                emojiW = each
            }

            let periodW: CGFloat = (showPeriodBesideSpace && page == .alphabetic) ? stdKeyW : 0

            var cursorX = sideInset
            for i in 0..<r3.count {
                let role = r3[i].role
                let kw: CGFloat
                switch role {
                case .pageSwitch:
                    kw = modeSwitchW
                case .globe:
                    kw = globeW
                case .emoji:
                    kw = emojiW
                case .smartPeriod:
                    kw = periodW
                case .returnKey:
                    kw = returnW
                case .space:
                    let rightEdge = w - sideInset - returnW - hGap
                    kw = max(80.0, rightEdge - cursorX)
                default:
                    kw = stdKeyW
                }
                let f = CGRect(x: cursorX, y: y3, width: kw, height: keyH)
                rowItems[3][i].frame = f
                if !isHandlingTouchDown && rowItems[3][i].view.frame != f { rowItems[3][i].view.frame = f }
                cursorX += kw + hGap
            }
        }

        // Update 3-row alphabetic bounding region & report exact live key centers to SpatialTouchModel!
        alphaRegionTop = y0
        alphaRegionHeight = max(1.0, (y2 + keyH) - y0)

        if page == .alphabetic {
            let geomKey = AnchorGeometryKey(
                w2: Int32((w * 2).rounded()),
                h2: Int32((h * 2).rounded()),
                showPeriod: showPeriodBesideSpace,
                needsGlobe: needsGlobeKey
            )
            if let onAnchorsUpdated, geomKey != lastReportedAnchorGeometryKey {
                lastReportedAnchorGeometryKey = geomKey
                var anchors: [SpatialTouchModel.KeyAnchor] = []
                anchors.reserveCapacity(26)
                for r in 0...2 {
                    for item in rowItems[r] {
                        if case let .letter(ch) = item.role {
                            let nx = item.frame.midX / w
                            let ny = (item.frame.midY - alphaRegionTop) / alphaRegionHeight
                            anchors.append(SpatialTouchModel.KeyAnchor(char: ch, center: CGPoint(x: nx, y: ny)))
                        }
                    }
                }
                onAnchorsUpdated(anchors)
            }
        }
        prewarmCalloutIfNeeded()
    }

    func prewarmCalloutIfNeeded() {
        guard !isHandlingTouchDown,
              hasLaidOutKeyFrames,
              rowItems.count >= 2,
              let r0First = rowItems[0].first,
              let r1First = rowItems[1].first,
              let bubble = calloutBubble,
              let bubbleSuper = bubble.superview else { return }
        let row0MinY = convert(r0First.frame.origin, to: bubbleSuper).y
        let row1MinY = convert(r1First.frame.origin, to: bubbleSuper).y
        let isLandscape = bounds.width > 520.0
        let sideInset: CGFloat = isLandscape ? 6.0 : 6.5
        let cw = bubbleSuper.bounds.width > 0 ? bubbleSuper.bounds.width : bounds.width
        bubble.prewarm(
            keyWidth: r0First.frame.width,
            keyHeight: r0First.frame.height,
            row0MinY: row0MinY,
            row1MinY: row1MinY,
            sideInset: sideInset,
            containerWidth: cw,
            dark: traitCollection.userInterfaceStyle == .dark
        )
    }

    // MARK: - Appearance Refresh

    private func scheduleDeferredAppearanceRefresh() {
        guard !deferredAppearanceScheduled else { return }
        deferredAppearanceScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredAppearanceScheduled = false
            self.flushDeferredAppearancesIfNeeded()
        }
    }

    private func flushDeferredAppearancesIfNeeded() {
        guard !isHandlingTouchDown else { return }
        if pageNeedsAppearanceRefresh {
            refreshKeyAppearances()
        } else {
            if bottomRowNeedsAppearanceRefresh {
                refreshBottomRowAppearanceOnly()
            }
            if returnKeyNeedsAppearanceRefresh {
                refreshReturnKeyAppearanceOnly()
            }
        }
    }

    func refreshKeyAppearances() {
        pageNeedsAppearanceRefresh = false
        bottomRowNeedsAppearanceRefresh = false
        returnKeyNeedsAppearanceRefresh = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dark = traitCollection.userInterfaceStyle == .dark
        var nextPressed: Set<Int> = []
        for s in activeTouches.values {
            // Letters use the popup exclusively. Their keycaps have no pressed fill.
            if case .letter = rowItems[s.rowIndex][s.colIndex].role { continue }
            nextPressed.insert((s.rowIndex << 4) | s.colIndex)
        }
        currentlyPressedKeys = nextPressed

        for (rIdx, row) in rowItems.enumerated() {
            for (cIdx, item) in row.enumerated() {
                let isPressed = nextPressed.contains((rIdx << 4) | cIdx)
                configureKeyView(item.view, role: item.role, dark: dark, pressed: isPressed)
            }
        }
    }

    private func refreshBottomRowAppearanceOnly() {
        bottomRowNeedsAppearanceRefresh = false
        guard rowItems.count > 3 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dark = traitCollection.userInterfaceStyle == .dark
        for (cIdx, item) in rowItems[3].enumerated() {
            let isPressed = currentlyPressedKeys.contains((3 << 4) | cIdx)
            configureKeyView(item.view, role: item.role, dark: dark, pressed: isPressed)
        }
    }

    private func refreshReturnKeyAppearanceOnly() {
        returnKeyNeedsAppearanceRefresh = false
        guard rowItems.count > 3 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dark = traitCollection.userInterfaceStyle == .dark
        for (cIdx, item) in rowItems[3].enumerated() where item.role == .returnKey {
            let isPressed = currentlyPressedKeys.contains((3 << 4) | cIdx)
            configureKeyView(item.view, role: item.role, dark: dark, pressed: isPressed)
        }
    }

    /// Updates ONLY the 0..2 keys whose `pressed` state actually changed instead of re-configuring all 29 keys at 120Hz.
    private func updatePressedKeyStatesDiff() {
        var nextPressed: Set<Int> = []
        for s in activeTouches.values {
            // Letters use the popup exclusively. Their keycaps have no pressed fill.
            if case .letter = rowItems[s.rowIndex][s.colIndex].role { continue }
            nextPressed.insert((s.rowIndex << 4) | s.colIndex)
        }
        guard nextPressed != currentlyPressedKeys else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let changed = currentlyPressedKeys.symmetricDifference(nextPressed)
        currentlyPressedKeys = nextPressed
        let dark = traitCollection.userInterfaceStyle == .dark

        for packed in changed {
            let rIdx = packed >> 4
            let cIdx = packed & 0x0F
            guard rIdx >= 0, rIdx < rowItems.count, cIdx >= 0, cIdx < rowItems[rIdx].count else { continue }
            let item = rowItems[rIdx][cIdx]
            // Alphabetic letter keys use the floating callout bubble rather than keycap fill changes
            if case .letter = item.role { continue }
            configureKeyView(item.view, role: item.role, dark: dark, pressed: nextPressed.contains(packed))
        }
    }

    private func configureKeyView(_ v: KeycapItemView, role: KeyRole, dark: Bool, pressed: Bool) {
        let primaryText = KeyboardTheme.primaryKeyTextColor(dark: dark)
        let fgPrimary = isTrackpadActive ? primaryText.withAlphaComponent(0.16) : primaryText

        switch role {
        case let .letter(ch):
            let isUpper = (shiftState != .lower)
            let display = isUpper ? String(ch.uppercased()) : String(ch)
            // Calibrated against iOS 26: lowercase 25.0pt regular with -2.9pt offset centers x-height at 0.0px!
            v.apply(
                title: display,
                symbolName: nil,
                customImage: nil,
                font: isUpper ? Self.letterUpperFont : Self.letterLowerFont,
                symbolWeight: .regular,
                horizontalOffset: 0,
                verticalOffset: isUpper ? -0.5 : -2.9,
                fill: KeyboardTheme.letterKeyFill(dark: dark, pressed: false),
                foreground: fgPrimary,
                dark: dark
            )

        case let .symbol(sym):
            let symFont = sym.count > 1 ? Self.symMultiFont : Self.symSingleFont
            let symHOff = KeyboardTheme.opticalHorizontalOffset(for: sym, font: symFont)
            v.apply(
                title: sym,
                symbolName: nil,
                customImage: nil,
                font: symFont,
                symbolWeight: .regular,
                horizontalOffset: symHOff,
                verticalOffset: -0.5,
                fill: KeyboardTheme.letterKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case .shift:
            let latched = (shiftState != .lower)
            let symName: String
            switch shiftState {
            case .lower: symName = "shift"
            case .oneShotUpper: symName = "shift.fill"
            case .capsLocked: symName = "capslock.fill"
            }
            let baseFg = latched ? KeyboardTheme.latchedModifierIconColor() : primaryText
            let fg = isTrackpadActive ? baseFg.withAlphaComponent(0.16) : baseFg
            v.apply(
                title: nil,
                symbolName: symName,
                customImage: nil,
                font: Self.shiftFont,
                symbolWeight: .regular,
                horizontalOffset: 0.4,
                verticalOffset: 0.4,
                fill: KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed, latched: latched),
                foreground: fg,
                dark: dark
            )

        case .backspace:
            v.apply(
                title: nil,
                symbolName: pressed ? "delete.left.fill" : "delete.left",
                customImage: nil,
                font: Self.backspaceFont,
                symbolWeight: .regular,
                horizontalOffset: -0.8,
                verticalOffset: 0.4,
                fill: KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case let .pageSwitch(_, title):
            let pageFont: UIFont
            switch title {
            case "#+=":
                pageFont = Self.pageHashFont
            case "拼音":
                pageFont = Self.pagePinyinFont
            case "ABC":
                pageFont = Self.pageABCFont
            default:
                pageFont = Self.page123Font
            }
            v.apply(
                title: title,
                symbolName: nil,
                customImage: nil,
                font: pageFont,
                symbolWeight: .regular,
                horizontalOffset: 0,
                verticalOffset: title == "#+=" ? -0.4 : -0.9,
                fill: KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case .globe:
            v.apply(
                title: nil,
                symbolName: "globe",
                customImage: nil,
                font: Self.globeFont,
                symbolWeight: .regular,
                horizontalOffset: 0,
                verticalOffset: 0,
                fill: KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case .emoji:
            v.apply(
                title: nil,
                symbolName: nil,
                customImage: KeyboardTheme.nativeEmojiFaceImage(pointSize: 20.0),
                font: Self.emojiFont,
                symbolWeight: .regular,
                horizontalOffset: 0,
                verticalOffset: -0.6,
                fill: KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case .smartPeriod:
            let pText = isChineseContext ? "。" : "."
            let pFont = Self.smartPeriodFont
            let pHOff = KeyboardTheme.opticalHorizontalOffset(for: pText, font: pFont)
            v.apply(
                title: pText,
                symbolName: nil,
                customImage: nil,
                font: pFont,
                symbolWeight: .regular,
                horizontalOffset: pHOff,
                verticalOffset: isChineseContext ? -2.0 : -3.0,
                fill: KeyboardTheme.letterKeyFill(dark: dark, pressed: pressed),
                foreground: fgPrimary,
                dark: dark
            )

        case .space:
            // In Chinese Pinyin mode (alphabetic, numeric, & symbolic), native iOS 26 leaves the center of the
            // spacebar completely blank and permanently displays `拼` in the bottom-right corner!
            let centerText = (!isPinyinMode && !isTrackpadActive) ? "space" : ""
            let labelAlpha: CGFloat = isTrackpadActive ? 0.16 : 1.0
            let showWatermark = isPinyinMode && !isTrackpadActive
            v.apply(
                title: centerText,
                symbolName: nil,
                customImage: nil,
                font: Self.spaceFont,
                symbolWeight: .regular,
                horizontalOffset: 0,
                verticalOffset: -0.5,
                fill: KeyboardTheme.letterKeyFill(dark: dark, pressed: pressed && !isTrackpadActive),
                foreground: primaryText.withAlphaComponent(0.75 * labelAlpha),
                dark: dark,
                watermark: showWatermark ? "拼" : nil
            )

        case .returnKey:
            let config = KeyboardTheme.returnKeyConfig(for: returnKeyType)
            if !isReturnKeyEnabled {
                let disabledFill = KeyboardTheme.disabledReturnKeyFill(dark: dark)
                let baseDisabledFg = KeyboardTheme.disabledReturnKeyForeground(dark: dark)
                let fg = isTrackpadActive ? baseDisabledFg.withAlphaComponent(0.16) : baseDisabledFg
                if returnKeyType == .send {
                    v.apply(
                        title: nil,
                        symbolName: "arrow.up",
                        customImage: nil,
                        font: Self.returnDisabledSendArrowFont,
                        symbolWeight: .medium,
                        horizontalOffset: 0,
                        verticalOffset: 0,
                        fill: disabledFill,
                        foreground: fg,
                        dark: dark
                    )
                } else {
                    let retFont = config.title != nil ? Self.returnTitleRegularFont : Self.returnIconRegularFont
                    v.apply(
                        title: config.title,
                        symbolName: config.symbolName,
                        customImage: nil,
                        font: retFont,
                        symbolWeight: .regular,
                        horizontalOffset: 0,
                        verticalOffset: config.title != nil ? 0 : 0.4,
                        fill: disabledFill,
                        foreground: fg,
                        dark: dark
                    )
                }
            } else {
                let fill = config.isAccent
                    ? KeyboardTheme.accentReturnKeyFill(dark: dark, pressed: pressed)
                    : KeyboardTheme.modifierKeyFill(dark: dark, pressed: pressed)
                let baseFg: UIColor = config.isAccent ? .white : primaryText
                let fg = isTrackpadActive ? baseFg.withAlphaComponent(0.16) : baseFg
                let isSendArrow = (config.symbolName == "arrow.up")
                let retFont: UIFont
                if config.title != nil {
                    retFont = config.isAccent ? Self.returnTitleMediumFont : Self.returnTitleRegularFont
                } else if isSendArrow {
                    retFont = Self.returnDisabledSendArrowFont
                } else {
                    retFont = config.isAccent ? Self.returnIconMediumFont : Self.returnIconRegularFont
                }
                v.apply(
                    title: config.title,
                    symbolName: config.symbolName,
                    customImage: nil,
                    font: retFont,
                    symbolWeight: isSendArrow ? .medium : .regular,
                    horizontalOffset: 0,
                    verticalOffset: (config.title != nil || isSendArrow) ? 0 : 0.4,
                    fill: fill,
                    foreground: fg,
                    dark: dark
                )
            }
        }
    }

    // MARK: - Zero-Dead-Zone Hit Testing & Multi-Touch Rollover

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let topAllowance: CGFloat = (page == .alphabetic) ? -KeyboardTheme.candidateBarHeight : -10.0
        let hitH = effectiveHitHeight
        let hitRect = CGRect(
            x: -12.0,
            y: topAllowance,
            width: bounds.width + 24.0,
            height: hitH - topAllowance + 12.0
        )
        return hitRect.contains(point)
    }

    private func calloutText(for role: KeyRole) -> String? {
        switch role {
        case let .letter(ch):
            return (shiftState != .lower) ? String(ch.uppercased()) : String(ch)
        case let .symbol(sym) where sym.count == 1:
            return sym
        default:
            return nil
        }
    }

    private func isImmediateTouchDownCommitRole(_ role: KeyRole) -> Bool {
        switch role {
        case .letter, .symbol, .smartPeriod, .returnKey:
            return true
        case .shift:
            return !(isComposing && page == .alphabetic)
        case .space:
            // Default (`enableComposingSpaceTrackpad == false`): while composing, Spacebar commits candidate #0
            // immediately at `0 ms` on touch-down; when `enableComposingSpaceTrackpad == true`, lift-off handles short tap vs trackpad.
            return isComposing && !enableComposingSpaceTrackpad
        case let .pageSwitch(_, title):
            // `拼音`, `ABC`, and `#+=` have no long-press action, so switch pages at `0 ms` on touch-down.
            return title != "123"
        default:
            return false
        }
    }

    private func roleDiagnosticLabel(_ role: KeyRole) -> String {
        switch role {
        case let .letter(ch):
            return shiftState == .lower ? "字母'\(ch)'" : "大写字母'\(ch.uppercased())'"
        case let .symbol(sym):
            return "符号\"\(sym)\""
        case .shift:
            return "Shift键"
        case .backspace:
            return "退格键"
        case let .pageSwitch(_, title):
            return "切页键(\(title))"
        case .globe:
            return "地球键"
        case .emoji:
            return "Emoji键"
        case .smartPeriod:
            return "智能句号键"
        case .space:
            return "空格键"
        case .returnKey:
            return "回车键"
        }
    }

    private func nearestKey(at point: CGPoint) -> (row: Int, col: Int)? {
        guard let hit = nearestKeyWithDiagnostic(at: point) else { return nil }
        return (hit.row, hit.col)
    }

    private func nearestKeyWithDiagnostic(at point: CGPoint) -> (row: Int, col: Int, remappedFrom: String?)? {
        // Generous vertical tolerance above Row 0 (`y >= -49`) so high thumb taps on `q..p` (`w`, `o`, `u`, `i`) are never missed,
        // and `effectiveHitHeight` below Row 3 so bottom-row keys stay reachable during transient 176pt host compat bounds!
        let hitBounds = CGRect(
            x: -12,
            y: -49,
            width: bounds.width + 24,
            height: effectiveHitHeight + 65
        )
        guard hitBounds.contains(point) else { return nil }

        var bestRow = 0
        var bestRowDist = CGFloat.greatestFiniteMagnitude
        for r in 0..<rowItems.count where !rowItems[r].isEmpty {
            let midY = rowItems[r][0].frame.midY
            let dy = abs(point.y - midY)
            if dy < bestRowDist {
                bestRowDist = dy
                bestRow = r
            }
        }

        var bestCol = 0
        var bestColDist = CGFloat.greatestFiniteMagnitude
        for (c, item) in rowItems[bestRow].enumerated() {
            let dx: CGFloat
            if point.x < item.frame.minX {
                dx = item.frame.minX - point.x
            } else if point.x > item.frame.maxX {
                dx = point.x - item.frame.maxX
            } else {
                dx = 0
            }
            if dx < bestColDist {
                bestColDist = dx
                bestCol = c
            }
        }

        // Native iOS `UIKeyboardLayoutStar` Dynamic Letter Hit-Zone Protection on `.alphabetic` page:
        // Prevents fast low/inner-edge thumb taps on `'a'`, `'z'`, `'l'`, `'m'`, and Row-2 letters (`z..m`)
        // from accidentally triggering `.shift` (uppercase hijack), `.backspace` (letter deletion),
        // `.emoji`, `.space` (premature commit), or `.returnKey`!
        if page == .alphabetic,
           rowItems.count == 4,
           rowItems[1].count >= 9,
           rowItems[2].count >= 9,
           !rowItems[3].isEmpty {
            let aFrame = rowItems[1][0].frame
            let lCol = rowItems[1].count - 1
            let lFrame = rowItems[1][lCol].frame
            let zFrame = rowItems[2][1].frame
            let mCol = rowItems[2].count - 2
            let mFrame = rowItems[2][mCol].frame

            if bestRow == 2 {
                if bestCol == 0 {
                    // Landed on `.shift`: protect `'a'` (directly above `.shift`) and `'z'` (to the right of `.shift`)
                    let rawLabel = roleDiagnosticLabel(rowItems[2][0].role)
                    if point.y <= aFrame.maxY + (isComposing ? 16.0 : 10.5) && point.x >= aFrame.minX - 6.0 {
                        return (1, 0, rawLabel)
                    }
                    if point.x >= zFrame.minX - (isComposing ? 18.0 : 11.0) {
                        return (2, 1, rawLabel)
                    }
                } else if bestCol == rowItems[2].count - 1 {
                    // Landed on `.backspace`: protect `'l'` (directly above `.backspace`) and `'m'` (to the left of `.backspace`)
                    let backspace = rowItems[2][bestCol]
                    // The visible delete key owns its entire face. Letter rescue
                    // still applies in the empty gutter above or beside it.
                    if backspace.frame.contains(point) { return (bestRow, bestCol, nil) }
                    let rawLabel = roleDiagnosticLabel(backspace.role)
                    let lDownAllowance: CGFloat
                    if point.x <= lFrame.midX + 4.0 {
                        lDownAllowance = isComposing ? 11.0 : 8.5
                    } else {
                        lDownAllowance = isComposing ? 9.7 : 7.5
                    }
                    if point.y <= lFrame.maxY + lDownAllowance && point.x <= lFrame.maxX + 4.0 {
                        return (1, lCol, rawLabel)
                    }
                    if point.x <= mFrame.maxX + (isComposing ? 12.0 : 8.5) {
                        return (2, mCol, rawLabel)
                    }
                }
            } else if bestRow == 3 {
                // Landed on Row 3 (`123`, `emoji`, `space`, `returnKey`): protect Row 2 letters (`z x c v b n m`) on low thumb taps!
                if point.x >= zFrame.minX - 10.0 && point.x <= mFrame.maxX + 10.0 {
                    let r3Role = rowItems[3][bestCol].role
                    let downAllowance: CGFloat
                    switch r3Role {
                    case .emoji, .returnKey, .pageSwitch:
                        downAllowance = isComposing ? 16.5 : 13.0
                    default:
                        downAllowance = isComposing ? 13.5 : 10.5
                    }
                    if point.y <= zFrame.maxY + downAllowance {
                        var letterCol = 1
                        var letterDist = CGFloat.greatestFiniteMagnitude
                        for c in 1...mCol {
                            let f = rowItems[2][c].frame
                            let dx: CGFloat
                            if point.x < f.minX {
                                dx = f.minX - point.x
                            } else if point.x > f.maxX {
                                dx = point.x - f.maxX
                            } else {
                                dx = 0
                            }
                            if dx < letterDist {
                                letterDist = dx
                                letterCol = c
                            }
                        }
                        return (2, letterCol, roleDiagnosticLabel(r3Role))
                    }
                }
            }
        }

        return (bestRow, bestCol, nil)
    }

    private func roleDiagnosticToken(_ role: KeyRole) -> KeyHitRoleToken {
        switch role {
        case let .letter(ch):
            let isUpper = (shiftState != .lower)
            if let ascii = (isUpper ? ch.uppercased().first : ch)?.asciiValue {
                return .asciiLetter(ascii, isUpper)
            }
            return .text(roleDiagnosticLabel(role))
        case .shift:
            return .staticLabel("Shift键")
        case .backspace:
            return .staticLabel("退格键")
        case .globe:
            return .staticLabel("地球键")
        case .emoji:
            return .staticLabel("Emoji键")
        case .smartPeriod:
            return .staticLabel("智能句号键")
        case .space:
            return .staticLabel("空格键")
        case .returnKey:
            return .staticLabel("回车键")
        case let .symbol(sym):
            return .symbol(sym)
        case let .pageSwitch(_, title):
            return .pageSwitch(title)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchBenchStartNs = DispatchTime.now().uptimeNanoseconds
        flushDeferredPageIfNeeded()
        isHandlingTouchDown = true
        defer { isHandlingTouchDown = false }
        onBeforeKeyTouchDown?()
        onTouchDownSettingsCheck?()
        let now = ProcessInfo.processInfo.systemUptime
        let touchCount = touches.count
        var editingStallTag: StaticString?

        if touchCount == 1, let singleTouch = touches.first {
            handleSingleTouchBegan(singleTouch, event: event, now: now, editingStallTag: &editingStallTag)
        } else if touchCount > 1 {
            let orderedTouches = touches.sorted { $0.timestamp < $1.timestamp }
            for touch in orderedTouches {
                handleSingleTouchBegan(touch, event: event, now: now, editingStallTag: &editingStallTag)
            }
        }

        let totalTouchMs = Double(DispatchTime.now().uptimeNanoseconds &- touchBenchStartNs) / 1_000_000.0
        if totalTouchMs >= 5.0 && LokeyDiagnosticLogger.shared.canRecordInteractions {
            LokeyDiagnosticLogger.shared.recordMainThreadStallFast(
                phase: "touchesBegan",
                touchCount: touchCount,
                tag: editingStallTag,
                elapsedMs: totalTouchMs
            )
        }
    }

    private func handleSingleTouchBegan(
        _ touch: UITouch,
        event: UIEvent?,
        now: TimeInterval,
        editingStallTag: inout StaticString?
    ) {
        let seq = touchSequence?(touch, event) ?? 0
        let pt = touch.location(in: self)
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
            LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(touchSeq: seq, point: pt, reason: .staticReason("键区已隐藏"))
            return
        }
        guard var hit = nearestKeyWithDiagnostic(at: pt) else {
            LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(
                touchSeq: seq,
                point: pt,
                reason: .staticReason("落点超出键区热区范围(未命中任何键)")
            )
            return
        }
        var role = rowItems[hit.row][hit.col].role
        if role == .returnKey && !isReturnKeyEnabled {
            LokeyDiagnosticLogger.shared.recordKeyHitFast(
                touchSeq: seq,
                roleToken: .staticLabel("回车键"),
                isLetter: false,
                isBackspace: false,
                row: hit.row,
                col: hit.col,
                gridPoint: pt,
                borderRemapFrom: hit.remappedFrom,
                actionStatic: "输入框为空(enablesReturnKeyAutomatically)禁用态忽略"
            )
            return
        }

        if !activeTouches.isEmpty {
            let pageBeforeRollover = page
            if activeTouches.count == 1, let (otherTouch, otherState) = activeTouches.first {
                if otherTouch !== touch {
                    if otherTouch === backspaceOwner { finishBackspaceTap() }
                    activeTouches.removeValue(forKey: otherTouch)
                    if otherState.isMomentaryNumericSlide {
                        stopSettingsLongPressTimer()
                        didTriggerSettingsLongPress = false
                        isMomentaryNumericSlideActive = false
                        momentaryNumericSlideTouch = nil
                        if otherState.rowIndex < rowItems.count,
                           otherState.colIndex < rowItems[otherState.rowIndex].count,
                           case let .symbol(sym) = rowItems[otherState.rowIndex][otherState.colIndex].role {
                            isCommittingMomentaryNumericSymbol = true
                            onSymbolTap?(sym)
                            isCommittingMomentaryNumericSymbol = false
                        }
                        if page != .alphabetic {
                            page = .alphabetic
                        }
                    } else if otherState.rowIndex < rowItems.count,
                              otherState.colIndex < rowItems[otherState.rowIndex].count {
                        let otherRole = rowItems[otherState.rowIndex][otherState.colIndex].role
                        if !otherState.didCommitOnTouchDown && isCommitOnRolloverRole(otherRole) {
                            if otherRole == .space { stopSpaceTimer() }
                            if case .pageSwitch = otherRole { stopSettingsLongPressTimer() }
                            let commitPt = otherState.hasUnlockedSlide ? otherState.currentPoint : otherState.initialPoint
                            commitKey(row: otherState.rowIndex, col: otherState.colIndex, point: commitPt, touchSeq: otherState.touchSeq)
                        }
                    }
                }
            } else {
                let priorTouches = activeTouches.sorted { lhs, rhs in
                    if lhs.value.touchDownTime != rhs.value.touchDownTime {
                        return lhs.value.touchDownTime < rhs.value.touchDownTime
                    }
                    return lhs.value.touchSeq < rhs.value.touchSeq
                }
                for (otherTouch, otherState) in priorTouches where otherTouch !== touch {
                    if otherTouch === backspaceOwner { finishBackspaceTap() }
                    activeTouches.removeValue(forKey: otherTouch)
                    if otherState.isMomentaryNumericSlide {
                        stopSettingsLongPressTimer()
                        didTriggerSettingsLongPress = false
                        isMomentaryNumericSlideActive = false
                        momentaryNumericSlideTouch = nil
                        if otherState.rowIndex < rowItems.count,
                           otherState.colIndex < rowItems[otherState.rowIndex].count,
                           case let .symbol(sym) = rowItems[otherState.rowIndex][otherState.colIndex].role {
                            isCommittingMomentaryNumericSymbol = true
                            onSymbolTap?(sym)
                            isCommittingMomentaryNumericSymbol = false
                        }
                        if page != .alphabetic {
                            page = .alphabetic
                        }
                        continue
                    }
                    guard otherState.rowIndex < rowItems.count,
                          otherState.colIndex < rowItems[otherState.rowIndex].count else {
                        continue
                    }
                    let otherRole = rowItems[otherState.rowIndex][otherState.colIndex].role
                    if !otherState.didCommitOnTouchDown && isCommitOnRolloverRole(otherRole) {
                        if otherRole == .space { stopSpaceTimer() }
                        if case .pageSwitch = otherRole { stopSettingsLongPressTimer() }
                        let commitPt = otherState.hasUnlockedSlide ? otherState.currentPoint : otherState.initialPoint
                        commitKey(row: otherState.rowIndex, col: otherState.colIndex, point: commitPt, touchSeq: otherState.touchSeq)
                        // If rollover committed `.emoji` and hid `KeyGridView`, abort immediately so the new touch
                        // never leaks into `activeTouches` or types into Pinyin behind `EmojiKeyboardView`!
                        if isHidden || !isUserInteractionEnabled || alpha <= 0.01 {
                            break
                        }
                    }
                }
            }
            guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
                LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(touchSeq: seq, point: pt, reason: .staticReason("前一触点已切离键区"))
                return
            }
            // If rollover switched keyboard page (e.g. `123` -> `.numeric` or `Space` -> `.alphabetic`),
            // `rebuildKeys()` replaced `rowItems` (Row 2 shrinks from 9 to 8 columns!), so re-resolve `hit`
            // against the newly laid-out page to prevent `Index out of range` crashes and hit the right key!
            if page != pageBeforeRollover || hit.row >= rowItems.count || hit.col >= rowItems[hit.row].count {
                guard let updatedHit = nearestKeyWithDiagnostic(at: pt) else {
                    LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(touchSeq: seq, point: pt, reason: .staticReason("切页后落点未命中"))
                    return
                }
                hit = updatedHit
                role = rowItems[hit.row][hit.col].role
                if role == .returnKey && !isReturnKeyEnabled {
                    LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(touchSeq: seq, point: pt, reason: .staticReason("切页后回车禁用"))
                    return
                }
            }
        }

        let commitsImmediately = isImmediateTouchDownCommitRole(role)
        let isLetterRole: Bool
        if case .letter = role {
            isLetterRole = true
        } else {
            isLetterRole = false
        }
        if LokeyDiagnosticLogger.shared.canRecordInteractions {
            if role == .backspace { editingStallTag = "退格" }
            if role == .symbol("，") { editingStallTag = "逗号" }
            let actionStatic: StaticString
            switch role {
            case .letter:
                actionStatic = "按下触发字母输入"
            case .backspace:
                actionStatic = "0ms按下即刻退格"
            case .space:
                actionStatic = commitsImmediately ? "0ms按下即刻上屏首选词" : "待抬手输入空格/长按游标"
            case .pageSwitch:
                actionStatic = commitsImmediately ? "0ms按下即刻切页" : "待抬手切123/长按切换中英"
            case .shift:
                actionStatic = commitsImmediately ? "0ms按下即刻触发" : "待抬手切换大小写/横滑光标"
            case .symbol, .smartPeriod, .returnKey:
                actionStatic = "0ms按下即刻触发"
            case .emoji:
                actionStatic = "待抬手打开Emoji面板"
            case .globe:
                actionStatic = "交由系统切换输入法"
            }
            LokeyDiagnosticLogger.shared.recordKeyHitFast(
                touchSeq: seq,
                roleToken: roleDiagnosticToken(role),
                isLetter: isLetterRole,
                isBackspace: role == .backspace,
                row: hit.row,
                col: hit.col,
                gridPoint: pt,
                borderRemapFrom: hit.remappedFrom,
                actionStatic: actionStatic
            )
        }

        let wasComposingBeforeTouchDown = isComposing
        activeTouches[touch] = ActiveTouchState(
            touchSeq: seq,
            initialRole: role,
            rowIndex: hit.row,
            colIndex: hit.col,
            initialPoint: pt,
            currentPoint: pt,
            touchDownTime: now,
            wasComposingAtTouchDown: wasComposingBeforeTouchDown,
            hasUnlockedSlide: false,
            didCommitOnTouchDown: commitsImmediately,
            didTriggerBackspaceSwipeClear: false,
            calloutLabel: calloutText(for: role)
        )
        triggerHaptic()
        playKeySound(for: role)
        updateCalloutAndHighlights()

        switch role {
        case .letter:
            // Immediate `0 ms` touch-down commit eliminates `60-100 ms` lift-off lag ("黏连感")
            // and guarantees zero dropped keys even if iOS edge/Home-bar gestures cancel the touch!
            onActiveKeyTouchDown?()
            commitKey(row: hit.row, col: hit.col, point: pt, touchSeq: seq)
        case .symbol, .smartPeriod, .returnKey:
            commitKey(row: hit.row, col: hit.col, point: pt, touchSeq: seq)
        case .shift:
            if commitsImmediately {
                commitKey(row: hit.row, col: hit.col, point: pt, touchSeq: seq)
            }
        case .space:
            if commitsImmediately {
                commitKey(row: hit.row, col: hit.col, point: pt, touchSeq: seq)
            } else {
                let delay: TimeInterval = (wasComposingBeforeTouchDown && enableComposingSpaceTrackpad) ? 0.20 : 0.24
                startSpaceTrackpadTimer(for: touch, initialPoint: pt, delay: delay)
            }
        case .pageSwitch:
            if commitsImmediately {
                commitKey(row: hit.row, col: hit.col, point: pt, touchSeq: seq)
            } else {
                startSettingsLongPressTimer()
            }
        case .backspace:
            onActiveKeyTouchDown?()
            startBackspaceRepeatTimers(for: touch)
            pendingLineBreakDeletion = shouldDeferLineBreakDeletion?() == true
            if !pendingLineBreakDeletion { onBackspaceTap?() }
        case .globe:
            if let event {
                onGlobeEvent?(rowItems[hit.row][hit.col].view, event)
            }
        default:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = ProcessInfo.processInfo.systemUptime

        for touch in touches {
            let pt = touch.location(in: self)

            if isTrackpadActive && touch === trackpadTouch {
                let dx = pt.x - lastTrackpadPoint.x
                lastTrackpadPoint = pt
                trackpadAccumulatedDX += dx
                let stepThreshold: CGFloat = 9.0
                while abs(trackpadAccumulatedDX) >= stepThreshold {
                    let step = trackpadAccumulatedDX > 0 ? 1 : -1
                    trackpadAccumulatedDX -= CGFloat(step) * stepThreshold
                    onMoveCursor?(step)
                    if hapticFeedbackIntensity > 0.0 {
                        selectionFeedback.selectionChanged()
                        selectionFeedback.prepare()
                    }
                }
                continue
            }

            guard var state = activeTouches[touch] else { continue }
            guard state.rowIndex < rowItems.count, state.colIndex < rowItems[state.rowIndex].count else {
                activeTouches.removeValue(forKey: touch)
                continue
            }
            state.currentPoint = pt
            let moveDistFromStart = hypot(pt.x - state.initialPoint.x, pt.y - state.initialPoint.y)
            if case .pageSwitch = state.initialRole, moveDistFromStart > 10.0 {
                stopSettingsLongPressTimer()
            }

            if !state.isMomentaryNumericSlide,
               !didTriggerSettingsLongPress,
               page == .alphabetic,
               state.initialRole == .pageSwitch(.numeric, "123"),
               moveDistFromStart > 14.0,
               pt.y >= -56.0 {
                stopSettingsLongPressTimer()
                isMomentaryNumericSlideActive = true
                momentaryNumericSlideTouch = touch
                page = .numeric
                state.isMomentaryNumericSlide = true
                state.hasUnlockedSlide = true
                if let hit = nearestKey(at: pt) {
                    state.rowIndex = hit.row
                    state.colIndex = hit.col
                    state.calloutLabel = calloutText(for: rowItems[hit.row][hit.col].role)
                } else {
                    state.rowIndex = min(3, max(0, rowItems.count - 1))
                    state.colIndex = 0
                    state.calloutLabel = nil
                }
                activeTouches[touch] = state
                triggerHaptic()
                updateCalloutAndHighlights()
                continue
            }

            if state.initialRole == .backspace {
                let dx = pt.x - state.initialPoint.x
                let dy = pt.y - state.initialPoint.y
                if !state.didTriggerBackspaceSwipeClear
                    && dx <= -24.0
                    && abs(dy) <= max(28.0, abs(dx) * 0.85) {
                    state.didTriggerBackspaceSwipeClear = true
                    activeTouches[touch] = state
                    stopBackspaceTimers()
                    triggerHaptic()
                    playKeySound(type: .delete)
                    LokeyDiagnosticLogger.shared.recordKeyHitFast(
                        touchSeq: state.touchSeq,
                        roleToken: .staticLabel("⌫(左滑清空)"),
                        isLetter: false,
                        isBackspace: true,
                        row: state.rowIndex,
                        col: state.colIndex,
                        gridPoint: pt,
                        borderRemapFrom: nil,
                        actionToken: .backspaceSwipeClear(Int((-dx).rounded()))
                    )
                    onBackspaceSwipeClear?(state.wasComposingAtTouchDown)
                    continue
                }
                if abs(dy) > 36.0 {
                    stopBackspaceTimers()
                }
                activeTouches[touch] = state
                continue
            }

            if state.didCommitOnTouchDown {
                // Already committed at `0 ms` on touch-down; dismiss callout crisp and early if thumb glides toward next key!
                let drift = hypot(pt.x - state.initialPoint.x, pt.y - state.initialPoint.y)
                if drift > 22.0 || pt.y < -40.0 {
                    activeTouches.removeValue(forKey: touch)
                    updateCalloutAndHighlights()
                } else {
                    activeTouches[touch] = state
                }
                continue
            }

            if state.initialRole == .shift && state.wasComposingAtTouchDown && page == .alphabetic {
                if pt.y < -56.0 {
                    activeTouches.removeValue(forKey: touch)
                    updateCalloutAndHighlights()
                    continue
                }
                let dx = pt.x - state.initialPoint.x
                let dy = pt.y - state.initialPoint.y
                if abs(dx) >= 14.0 && abs(dx) > abs(dy) * 1.1 {
                    activateTrackpad(touch: touch, at: pt, initialDX: dx)
                    continue
                }
                activeTouches[touch] = state
                continue
            }

            if !state.hasUnlockedSlide && (state.initialRole == .space || rowItems[state.rowIndex][state.colIndex].role == .space) {
                // When `enableComposingSpaceTrackpad == true` while composing, horizontal drag >= 14pt activates
                // preedit caret trackpad immediately; when idle, keep the 0.16s / 18pt guard against fast lateral taps.
                let dx = pt.x - state.initialPoint.x
                let dy = pt.y - state.initialPoint.y
                let composingSpaceSlideReady = state.wasComposingAtTouchDown
                    && enableComposingSpaceTrackpad
                    && abs(dx) >= 14.0
                    && abs(dx) > abs(dy) * 1.1
                let idleSpaceSlideReady = !state.wasComposingAtTouchDown
                    && (now - state.touchDownTime) >= 0.16
                    && abs(dx) > 18.0
                    && abs(dx) > abs(dy) * 1.2
                if (composingSpaceSlideReady || idleSpaceSlideReady) && spaceLongPressTimer != nil {
                    activateTrackpad(touch: touch, at: pt, initialDX: dx)
                    continue
                }
                if pt.y < -56.0 {
                    activeTouches.removeValue(forKey: touch)
                    stopSpaceTimer()
                    updateCalloutAndHighlights()
                    LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(
                        touchSeq: state.touchSeq,
                        point: pt,
                        reason: .draggedOffSpace(Int(pt.y))
                    )
                    continue
                }
                activeTouches[touch] = state
                continue
            }

            // Only cancel an uncommitted touch if the user drags far upward off the keyboard into the document (`y < -56pt`),
            // and always log it so zero touches vanish uncounted!
            if pt.y < -56.0 {
                let role = rowItems[state.rowIndex][state.colIndex].role
                activeTouches.removeValue(forKey: touch)
                if state.isMomentaryNumericSlide {
                    isMomentaryNumericSlideActive = false
                    momentaryNumericSlideTouch = nil
                    if page != .alphabetic {
                        page = .alphabetic
                    }
                }
                updateCalloutAndHighlights()
                LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(
                    touchSeq: state.touchSeq,
                    point: pt,
                    reason: .draggedOffKey(Int(pt.y), roleDiagnosticToken(role))
                )
                continue
            }

            if !state.hasUnlockedSlide {
                let moveDist = hypot(pt.x - state.initialPoint.x, pt.y - state.initialPoint.y)
                let elapsed = now - state.touchDownTime
                if moveDist > 21.0 && elapsed > 0.105 {
                    state.hasUnlockedSlide = true
                }
            }

            var keyChanged = false
            if state.hasUnlockedSlide, let hit = nearestKey(at: pt) {
                if hit.row != state.rowIndex || hit.col != state.colIndex {
                    let prevRole = rowItems[state.rowIndex][state.colIndex].role
                    if prevRole == .backspace { stopBackspaceTimers() }
                    if prevRole == .space { stopSpaceTimer() }
                    if case .pageSwitch = prevRole { stopSettingsLongPressTimer() }
                    state.rowIndex = hit.row
                    state.colIndex = hit.col
                    state.calloutLabel = calloutText(for: rowItems[hit.row][hit.col].role)
                    keyChanged = true
                }
            }

            activeTouches[touch] = state
            if keyChanged {
                updateCalloutAndHighlights()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.count == 1, let singleTouch = touches.first {
            handleSingleTouchEnded(singleTouch)
        } else if touches.count > 1 {
            let orderedTouches = touches.sorted { $0.timestamp < $1.timestamp }
            for touch in orderedTouches {
                handleSingleTouchEnded(touch)
            }
        }
        flushDeferredPageIfNeeded()
    }

    private func handleSingleTouchEnded(_ touch: UITouch) {
        if isTrackpadActive && touch === trackpadTouch {
            endTrackpadMode()
            activeTouches.removeValue(forKey: touch)
            refreshKeyAppearances()
            updateCalloutAndHighlights()
            return
        }

        // Rollover already retired the older thumb. Its later lift must not
        // redraw the current thumb's bubble or alter its timers.
        guard let state = activeTouches.removeValue(forKey: touch) else { return }
        let role: KeyRole? = state.rowIndex < rowItems.count && state.colIndex < rowItems[state.rowIndex].count
            ? rowItems[state.rowIndex][state.colIndex].role : nil
        var triggeredSettings = false
        if role == .space || activeTouches.isEmpty {
            stopSpaceTimer()
        }
        if touch === backspaceOwner {
            finishBackspaceTap()
        }
        let initialWasPageSwitch: Bool
        if case .pageSwitch = state.initialRole {
            initialWasPageSwitch = true
        } else {
            initialWasPageSwitch = false
        }
        let finalIsPageSwitch: Bool
        if let r = role, case .pageSwitch = r {
            finalIsPageSwitch = true
        } else {
            finalIsPageSwitch = false
        }
        if initialWasPageSwitch || finalIsPageSwitch {
            triggeredSettings = didTriggerSettingsLongPress
            didTriggerSettingsLongPress = false
            stopSettingsLongPressTimer()
        } else if activeTouches.isEmpty {
            didTriggerSettingsLongPress = false
            stopSettingsLongPressTimer()
        }

        if state.isMomentaryNumericSlide
            || (isMomentaryNumericSlideActive && (momentaryNumericSlideTouch == nil || momentaryNumericSlideTouch === touch)) {
            let endPt = touch.location(in: self)
            var slideSymbol: String?
            var resolvedRow = state.rowIndex
            var resolvedCol = state.colIndex
            if !triggeredSettings && endPt.y >= -56.0 {
                if let hit = nearestKey(at: endPt) {
                    resolvedRow = hit.row
                    resolvedCol = hit.col
                }
                if resolvedRow >= 0,
                   resolvedRow < rowItems.count,
                   resolvedCol >= 0,
                   resolvedCol < rowItems[resolvedRow].count,
                   case let .symbol(sym) = rowItems[resolvedRow][resolvedCol].role {
                    slideSymbol = sym
                }
            }
            isMomentaryNumericSlideActive = false
            momentaryNumericSlideTouch = nil
            calloutBubble?.hide()
            if let sym = slideSymbol {
                LokeyDiagnosticLogger.shared.recordKeyHitFast(
                    touchSeq: state.touchSeq,
                    roleToken: .momentarySlideSymbol(sym),
                    isLetter: false,
                    isBackspace: false,
                    row: resolvedRow,
                    col: resolvedCol,
                    gridPoint: endPt,
                    borderRemapFrom: nil,
                    actionStatic: "123按住滑动松手输入符号并自动回字母页"
                )
                playKeySound(type: .standard)
                isCommittingMomentaryNumericSymbol = true
                onSymbolTap?(sym)
                isCommittingMomentaryNumericSymbol = false
                if page != .alphabetic {
                    page = .alphabetic
                } else {
                    updateCalloutAndHighlights()
                }
            } else if page != .alphabetic {
                page = .alphabetic
            } else {
                updateCalloutAndHighlights()
            }
            return
        }

        // Dismiss callout bubble FIRST (`0 ms`) before any commit/XPC work so key release never feels sticky!
        updateCalloutAndHighlights()

        if !state.didCommitOnTouchDown,
           state.initialRole != .backspace,
           let role {
            let endPt = touch.location(in: self)
            if role == .space && state.wasComposingAtTouchDown && enableComposingSpaceTrackpad {
                let duration = ProcessInfo.processInfo.systemUptime - state.touchDownTime
                let drift = hypot(endPt.x - state.initialPoint.x, endPt.y - state.initialPoint.y)
                guard duration < 0.22 && drift < 10.0 else {
                    return
                }
            }
            let commitPt = state.hasUnlockedSlide ? endPt : state.initialPoint
            if role != .backspace && role != .globe && !triggeredSettings {
                commitKey(row: state.rowIndex, col: state.colIndex, point: commitPt, touchSeq: state.touchSeq)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = ProcessInfo.processInfo.systemUptime
        let triggeredSettings = didTriggerSettingsLongPress
        var rescuedCommits: [(Int, Int, CGPoint, UInt64)] = []

        if touches.count == 1, let singleTouch = touches.first {
            handleSingleTouchCancelled(singleTouch, now: now, triggeredSettings: triggeredSettings, rescuedCommits: &rescuedCommits)
        } else if touches.count > 1 {
            let orderedTouches = touches.sorted { $0.timestamp < $1.timestamp }
            for touch in orderedTouches {
                handleSingleTouchCancelled(touch, now: now, triggeredSettings: triggeredSettings, rescuedCommits: &rescuedCommits)
            }
        }
        if activeTouches.isEmpty {
            stopSpaceTimer()
            stopBackspaceTimers()
            stopSettingsLongPressTimer()
            didTriggerSettingsLongPress = false
            if isMomentaryNumericSlideActive {
                isMomentaryNumericSlideActive = false
                momentaryNumericSlideTouch = nil
                if page != .alphabetic {
                    page = .alphabetic
                }
            }
        }
        updateCalloutAndHighlights()
        for (r, c, pt, seq) in rescuedCommits {
            guard !isHidden, isUserInteractionEnabled else { break }
            commitKey(row: r, col: c, point: pt, touchSeq: seq)
        }
        flushDeferredPageIfNeeded()
    }

    private func handleSingleTouchCancelled(
        _ touch: UITouch,
        now: TimeInterval,
        triggeredSettings: Bool,
        rescuedCommits: inout [(Int, Int, CGPoint, UInt64)]
    ) {
        if touch === backspaceOwner {
            let bsState = activeTouches[touch]
            let pt = touch.location(in: self)
            let shouldRescueLineBreak = pendingLineBreakDeletion
                && bsState.map({ !$0.didTriggerBackspaceSwipeClear && (now - $0.touchDownTime) < 0.35 && hypot(pt.x - $0.initialPoint.x, pt.y - $0.initialPoint.y) < 24.0 }) == true
            stopBackspaceTimers()
            if shouldRescueLineBreak {
                onBackspaceTap?()
            }
        }
        if touch === trackpadTouch {
            endTrackpadMode()
            activeTouches.removeValue(forKey: touch)
            return
        }
        if let state = activeTouches.removeValue(forKey: touch) {
            if state.isMomentaryNumericSlide {
                if momentaryNumericSlideTouch === touch {
                    isMomentaryNumericSlideActive = false
                    momentaryNumericSlideTouch = nil
                    if page != .alphabetic {
                        page = .alphabetic
                    }
                }
                return
            }
            if !state.didCommitOnTouchDown,
               state.initialRole != .backspace,
               !triggeredSettings,
               state.rowIndex < rowItems.count,
               state.colIndex < rowItems[state.rowIndex].count {
                let pt = touch.location(in: self)
                let dx = pt.x - state.initialPoint.x
                let dy = pt.y - state.initialPoint.y
                let drift = hypot(dx, dy)
                let role = rowItems[state.rowIndex][state.colIndex].role
                let withinTolerance: Bool
                let maxDuration: TimeInterval
                if role == .space && state.wasComposingAtTouchDown && enableComposingSpaceTrackpad {
                    withinTolerance = drift < 10.0
                    maxDuration = 0.22
                } else {
                    withinTolerance = (role == .space)
                        ? (abs(dx) < 42.0 && abs(dy) < 28.0)
                        : (drift < 28.0)
                    maxDuration = 0.38
                }
                if (now - state.touchDownTime) < maxDuration && withinTolerance && pt.y >= -28.0 && isCommitOnRolloverRole(role) {
                    rescuedCommits.append((state.rowIndex, state.colIndex, state.initialPoint, state.touchSeq))
                } else {
                    LokeyDiagnosticLogger.shared.recordMissedOrCancelledTouchFast(
                        touchSeq: state.touchSeq,
                        point: pt,
                        reason: .systemCancelledUncommitted(roleDiagnosticToken(role))
                    )
                }
            }
        }
    }

    // MARK: - Key Action Dispatch

    private func isCommitOnRolloverRole(_ role: KeyRole) -> Bool {
        switch role {
        case .letter, .shift, .symbol, .smartPeriod, .space, .pageSwitch, .emoji:
            return true
        default:
            return false
        }
    }

    private func commitKey(row: Int, col: Int, point: CGPoint, touchSeq: UInt64) {
        guard row >= 0, row < rowItems.count, col >= 0, col < rowItems[row].count else { return }
        let item = rowItems[row][col]
        switch item.role {
        case let .letter(ch):
            let nx = min(1.0, max(0.0, point.x / max(1.0, bounds.width)))
            let ny = min(1.0, max(0.0, (point.y - alphaRegionTop) / alphaRegionHeight))
            let isShifted = (shiftState != .lower)
            if shiftState == .oneShotUpper {
                shiftState = .lower
            }
            onLetterTap?(ch, CGPoint(x: nx, y: ny), isShifted, touchSeq)

        case let .symbol(sym):
            onSymbolTap?(sym)

        case .shift:
            let now = ProcessInfo.processInfo.systemUptime
            if shiftState == .oneShotUpper && (now - lastShiftTapTime) < 0.32 {
                shiftState = .capsLocked
            } else if shiftState == .lower {
                shiftState = .oneShotUpper
            } else {
                shiftState = .lower
            }
            lastShiftTapTime = now

        case .backspace:
            break

        case let .pageSwitch(targetPage, _):
            page = targetPage

        case .globe:
            break

        case .emoji:
            onEmojiTap?()

        case .smartPeriod:
            onPeriodTap?()

        case .space:
            onSpaceTap?()

        case .returnKey:
            guard isReturnKeyEnabled else { return }
            onReturnTap?()
        }
    }

    private func updateCalloutAndHighlights() {
        updatePressedKeyStatesDiff()

        guard !isTrackpadActive,
              let bubble = calloutBubble,
              let bubbleSuperview = bubble.superview else {
            calloutBubble?.hide()
            return
        }

        var latestState: ActiveTouchState?
        for state in activeTouches.values where state.calloutLabel != nil {
            if let cur = latestState {
                if state.touchDownTime > cur.touchDownTime
                    || (state.touchDownTime == cur.touchDownTime && state.touchSeq > cur.touchSeq) {
                    latestState = state
                }
            } else {
                latestState = state
            }
        }

        if let state = latestState,
           state.rowIndex < rowItems.count,
           state.colIndex < rowItems[state.rowIndex].count,
           let text = state.calloutLabel {
            let item = rowItems[state.rowIndex][state.colIndex]
            let dark = traitCollection.userInterfaceStyle == .dark
            bubble.show(
                text: text,
                keyFrame: convert(item.frame, to: bubbleSuperview),
                containerWidth: bubbleSuperview.bounds.width,
                dark: dark
            )
        } else {
            bubble.hide()
        }
    }

    // MARK: - Timers (Trackpad, Continuous Backspace, Long-Press Settings)

    private func startSpaceTrackpadTimer(for touch: UITouch, initialPoint: CGPoint, delay: TimeInterval = 0.24) {
        stopSpaceTimer()
        lastTrackpadPoint = initialPoint
        spaceLongPressTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak touch] _ in
            guard let self, let touch else { return }
            self.activateTrackpad(touch: touch, at: touch.location(in: self))
        }
    }

    private func activateTrackpad(touch: UITouch, at point: CGPoint, initialDX: CGFloat = 0) {
        stopSpaceTimer()
        isTrackpadActive = true
        trackpadTouch = touch
        lastTrackpadPoint = point
        trackpadAccumulatedDX = 0
        calloutBubble?.hide()
        if hapticFeedbackIntensity > 0.0 {
            selectionFeedback.prepare()
        }
        triggerHaptic()
        refreshKeyAppearances()
        if abs(initialDX) >= 14.0 {
            let firstStep = initialDX > 0 ? 1 : -1
            onMoveCursor?(firstStep)
            if hapticFeedbackIntensity > 0.0 {
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
        }
    }

    private func endTrackpadMode() {
        stopSpaceTimer()
        isTrackpadActive = false
        trackpadTouch = nil
        trackpadAccumulatedDX = 0
    }

    private func stopSpaceTimer() {
        spaceLongPressTimer?.invalidate()
        spaceLongPressTimer = nil
    }

    private func startBackspaceRepeatTimers(for touch: UITouch) {
        stopBackspaceTimers()
        backspaceOwner = touch
        backspaceTickCount = 0
        backspaceDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.pendingLineBreakDeletion {
                self.pendingLineBreakDeletion = false
                self.onBackspaceTap?()
            }
            self.scheduleBackspaceRepeat(interval: 0.085)
        }
    }

    private func scheduleBackspaceRepeat(interval: TimeInterval) {
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.backspaceTickCount += 1
            self.onBackspaceTap?()
            self.triggerHaptic()
            self.playKeySound(type: .delete)
            if self.backspaceTickCount == 10 {
                self.scheduleBackspaceRepeat(interval: 0.045)
            }
        }
    }

    private func finishBackspaceTap() {
        let deleteLineBreak = pendingLineBreakDeletion
        stopBackspaceTimers()
        if deleteLineBreak { onBackspaceTap?() }
    }

    private func stopBackspaceTimers() {
        pendingLineBreakDeletion = false
        backspaceOwner = nil
        backspaceDelayTimer?.invalidate()
        backspaceDelayTimer = nil
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    private func startSettingsLongPressTimer() {
        stopSettingsLongPressTimer()
        didTriggerSettingsLongPress = false
        settingsLongPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.didTriggerSettingsLongPress = true
            self.triggerHaptic()
            self.onOpenSettings?()
        }
    }

    private func stopSettingsLongPressTimer() {
        settingsLongPressTimer?.invalidate()
        settingsLongPressTimer = nil
    }

    private func cancelAllTimersAndTouches() {
        stopSpaceTimer()
        stopBackspaceTimers()
        stopSettingsLongPressTimer()
        isTrackpadActive = false
        trackpadTouch = nil
        activeTouches.removeAll()
        calloutBubble?.hide()
    }

    static func clearSymbolCacheForMemoryWarning() {
        KeycapItemView.clearSymbolCacheForMemoryWarning()
    }
}

// MARK: - Native iOS 26 Liquid Glass Keycap View

private final class KeycapItemView: UIView {
    private struct SymbolKey: Hashable {
        let name: String
        let sizeTenths: Int
        let weightRaw: Int
    }

    private static var symbolCache: [SymbolKey: UIImage] = [:]
    private static var didPrewarmSymbols = false

    static func clearSymbolCacheForMemoryWarning() {
        symbolCache.removeAll(keepingCapacity: false)
        didPrewarmSymbols = false
    }

    static func prewarmAllSymbols() {
        guard !didPrewarmSymbols else { return }
        didPrewarmSymbols = true
        let specs: [(String, CGFloat, UIImage.SymbolWeight)] = [
            ("delete.left", 19.0, .regular),
            ("delete.left.fill", 19.0, .regular),
            ("shift", 18.8, .regular),
            ("shift.fill", 18.8, .regular),
            ("capslock.fill", 18.8, .regular),
            ("globe", 19.0, .regular),
            ("return", 19.0, .regular),
            ("return", 19.0, .medium),
            ("arrow.up", 17.0, .medium)
        ]
        for (name, pt, weight) in specs {
            _ = cachedSymbol(name: name, pointSize: pt, weight: weight)
        }
    }

    private static func cachedSymbol(name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage? {
        let key = SymbolKey(name: name, sizeTenths: Int((pointSize * 10).rounded()), weightRaw: weight.rawValue)
        if let hit = symbolCache[key] {
            return hit
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let img = UIImage(systemName: name, withConfiguration: cfg) {
            symbolCache[key] = img
            return img
        }
        return nil
    }

    private struct RenderState: Equatable {
        let title: String?
        let symbolName: String?
        let customImageID: ObjectIdentifier?
        let fontID: ObjectIdentifier
        let weightRaw: Int
        let horizontalOffset: CGFloat
        let verticalOffset: CGFloat
        let fill: UIColor
        let foreground: UIColor
        let dark: Bool
        let watermark: String?
        let boundsSize: CGSize
    }

    private let label = UILabel()
    private let iconView = UIImageView()
    private let watermarkLabel = UILabel()
    private var horizontalOffset: CGFloat = 0
    private var verticalOffset: CGFloat = 0
    private var lastRenderState: RenderState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        layer.cornerRadius = KeyboardTheme.keyCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowOpacity = KeyboardTheme.keyShadowOpacity

        label.textAlignment = .center
        addSubview(label)

        iconView.contentMode = .center
        iconView.isHidden = true
        addSubview(iconView)

        watermarkLabel.textAlignment = .right
        watermarkLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        watermarkLabel.isHidden = true
        addSubview(watermarkLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.offsetBy(dx: horizontalOffset, dy: verticalOffset)
        iconView.frame = bounds.offsetBy(dx: horizontalOffset, dy: verticalOffset)
        // Calibrated to native iOS 26 `拼` watermark (`(716..743, 587..613)` in 1024px crop)
        watermarkLabel.frame = CGRect(x: bounds.width - 20.4, y: bounds.height - 18.7, width: 16.0, height: 15.5)
    }

    func apply(
        title: String?,
        symbolName: String?,
        customImage: UIImage?,
        font: UIFont,
        symbolWeight: UIImage.SymbolWeight,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        fill: UIColor,
        foreground: UIColor,
        dark: Bool,
        watermark: String? = nil
    ) {
        let nextState = RenderState(
            title: title,
            symbolName: symbolName,
            customImageID: customImage.map { ObjectIdentifier($0) },
            fontID: ObjectIdentifier(font),
            weightRaw: symbolWeight.rawValue,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset,
            fill: fill,
            foreground: foreground,
            dark: dark,
            watermark: watermark,
            boundsSize: bounds.size
        )
        if lastRenderState == nextState {
            return
        }
        lastRenderState = nextState

        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        if backgroundColor != fill {
            backgroundColor = fill
        }

        if let watermark {
            watermarkLabel.text = watermark
            // Calibrated to native iOS 26 `RGB(200,200,200)` on `#FFFFFF` (`alpha ≈ 0.23`)
            watermarkLabel.textColor = dark
                ? UIColor(white: 1.0, alpha: 0.30)
                : UIColor(white: 0.0, alpha: 0.23)
            watermarkLabel.isHidden = false
        } else if !watermarkLabel.isHidden {
            watermarkLabel.isHidden = true
        }

        let targetFrame = bounds.offsetBy(dx: horizontalOffset, dy: verticalOffset)
        if let customImage {
            if !label.isHidden { label.isHidden = true }
            if iconView.isHidden { iconView.isHidden = false }
            iconView.image = customImage
            iconView.tintColor = foreground
            iconView.frame = targetFrame
        } else if let symbolName {
            if !label.isHidden { label.isHidden = true }
            if iconView.isHidden { iconView.isHidden = false }
            iconView.image = Self.cachedSymbol(name: symbolName, pointSize: font.pointSize, weight: symbolWeight)
            iconView.tintColor = foreground
            iconView.frame = targetFrame
        } else {
            if !iconView.isHidden { iconView.isHidden = true }
            if label.isHidden { label.isHidden = false }
            label.text = title
            label.font = font
            label.textColor = foreground
            label.frame = targetFrame
        }
    }
}
