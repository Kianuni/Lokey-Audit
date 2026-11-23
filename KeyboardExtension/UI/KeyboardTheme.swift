import CoreText
import UIKit

/// Native iOS 26 Liquid Glass system keyboard color, geometry, and iconography tokens
/// pixel-calibrated 1:1 against real-device screenshots.
/// Note: The root `inputView` stays `.clear` so iOS renders its authentic system Liquid Glass capsule underneath.
enum KeyboardTheme {
    /// Imperceptible luminance-matched remote-layer hit-catching backing (`ceil(0.004 * 255) = 1/255 > 0`)
    /// so `BackBoardd`/`CARenderServer` never drops inter-key or inter-candidate gutter touches in
    /// `LokeyKeyboard.appex`'s remote `CAContext`, while compositing with `0/255` RGB delta over both
    /// Light (`0.886..0.910`) and Dark (`0.137..0.149`) Liquid Glass capsules.
    static let hitTestableClearBacking = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.14, alpha: 0.004)
            : UIColor(white: 0.89, alpha: 0.004)
    }

    // MARK: - Dynamic Semantic Colors (safe across live Light/Dark trait transitions)

    static let dynamicPrimaryText = UIColor { tc in
        tc.userInterfaceStyle == .dark ? .white : .black
    }

    static let dynamicSecondaryText = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.62)
            : UIColor(white: 0.0, alpha: 0.55)
    }

    static let dynamicCandidateDivider = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.14)
            : UIColor(white: 0.0, alpha: 0.16)
    }

    static func expandedGridRowDivider(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 0.0, alpha: 0.45)
            : UIColor(white: 0.0, alpha: 0.13)
    }

    static let dynamicCandidateChevron = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.86)
            : UIColor(white: 0.0, alpha: 0.82)
    }

    static let dynamicSubtlePill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.13)
            : UIColor(white: 1.0, alpha: 0.58)
    }

    static let dynamicPillText = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.82)
            : UIColor(white: 0.0, alpha: 0.75)
    }

    // MARK: - iOS 26 Liquid Glass Keycap Fills

    static func letterKeyFill(dark: Bool, pressed: Bool = false) -> UIColor {
        if dark {
            return pressed
                ? UIColor(white: 1.0, alpha: 0.28)
                : UIColor(white: 1.0, alpha: 0.155)
        } else {
            return pressed
                ? UIColor(red: 0.855, green: 0.868, blue: 0.896, alpha: 1.0)
                : UIColor.white
        }
    }

    /// In iOS 26 Liquid Glass Light Mode, modifier keys (`⇧`, `⌫`, `123`, `😊`, `⏎`) share the exact same
    /// pure `#FFFFFF` keycap fill as letter keys (zero legacy grey fill).
    static func modifierKeyFill(dark: Bool, pressed: Bool = false, latched: Bool = false) -> UIColor {
        if latched {
            return UIColor.white
        }
        if dark {
            return pressed
                ? UIColor(white: 1.0, alpha: 0.28)
                : UIColor(white: 1.0, alpha: 0.155)
        } else {
            return pressed
                ? UIColor(red: 0.855, green: 0.868, blue: 0.896, alpha: 1.0)
                : UIColor.white
        }
    }

    static func accentReturnKeyFill(dark: Bool, pressed: Bool = false) -> UIColor {
        if dark {
            return pressed
                ? UIColor(red: 0.02, green: 0.42, blue: 0.86, alpha: 1.0)
                : UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0) // #0A84FF
        } else {
            return pressed
                ? UIColor(red: 0.0, green: 0.38, blue: 0.82, alpha: 1.0)
                : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)    // #007AFF
        }
    }

    /// Calibrated to Native iOS 26 disabled Return key (`enablesReturnKeyAutomatically` on empty field, e.g. WeChat `RGB(191,192,196)`).
    static func disabledReturnKeyFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(red: 191.0 / 255.0, green: 192.0 / 255.0, blue: 196.0 / 255.0, alpha: 1.0)
    }

    static func disabledReturnKeyForeground(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.32)
            : UIColor(red: 164.0 / 255.0, green: 165.0 / 255.0, blue: 170.0 / 255.0, alpha: 1.0)
    }

    static func candidateHighlightPillFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : UIColor(white: 1.0, alpha: 0.82)
    }

    /// Opaque callout bubble fill so popped-up key cleanly masks the row behind it.
    static func calloutBubbleFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1.0)
            : UIColor.white
    }

    static func calloutStrokeColor(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.14)
            : UIColor(white: 0.0, alpha: 0.08)
    }

    // MARK: - Emoji Panel Semantic Colors

    /// Calibrated to Native iOS 26 Emoji search capsule (`RGB(239,240,244)` over `RGB(226,227,231)` glass).
    static func emojiSearchBarFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : UIColor(white: 1.0, alpha: 0.58)
    }

    static func emojiSearchBarPlaceholderColor(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.56)
            : UIColor(white: 0.36, alpha: 0.92)
    }

    /// Translucent circular pill behind the active Emoji category icon (`RGB(208,211,216)` on `RGB(226,227,231)`).
    static func emojiCategoryPillFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(white: 1.0, alpha: 0.15)
            : UIColor(white: 0.0, alpha: 0.088)
    }

    static func emojiCategoryIconTint(dark: Bool, selected: Bool) -> UIColor {
        if dark {
            return selected
                ? UIColor(white: 1.0, alpha: 0.96)
                : UIColor(white: 1.0, alpha: 0.68)
        } else {
            return selected
                ? UIColor(red: 0.19, green: 0.21, blue: 0.24, alpha: 0.96)
                : UIColor(red: 0.33, green: 0.35, blue: 0.39, alpha: 0.90)
        }
    }

    // MARK: - Foreground / Shadows

    static func primaryKeyTextColor(dark: Bool) -> UIColor {
        dark ? .white : .black
    }

    static func latchedModifierIconColor() -> UIColor {
        .black
    }

    /// iOS 26 Liquid Glass keys have zero harsh dark bottom shadow line.
    static let keyShadowOpacity: Float = 0.0

    static func keyBottomShadowColor(dark: Bool) -> CGColor {
        UIColor.clear.cgColor
    }

    static func overlayPanelFill(dark: Bool) -> UIColor {
        dark
            ? UIColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 0.96)
            : UIColor(red: 0.91, green: 0.915, blue: 0.935, alpha: 0.97)
    }

    // MARK: - Pixel-Calibrated iOS 26 Geometry & Return Key Mapping

    enum LayoutProfile: Equatable {
        case regularMiniPortrait
        case regularCompactPortrait
        case regularMaxPortrait
        case regularLandscape
        case duoCover
        case duoUnfoldedPortrait
        case duoUnfoldedLandscape
    }

    static func layoutProfile(forWidth width: CGFloat, screenSize: CGSize = .zero) -> LayoutProfile {
        let minScreenDim = min(screenSize.width, screenSize.height)
        let isLargeFoldableDisplay = minScreenDim >= 460.0
        if width > 520.0 {
            if isLargeFoldableDisplay {
                let isLandscapeFoldableScreen = screenSize.width >= 600.0 && screenSize.width > screenSize.height
                return (width > 725.0 || isLandscapeFoldableScreen) ? .duoUnfoldedLandscape : .duoUnfoldedPortrait
            }
            return .regularLandscape
        }
        if width >= 446.0 {
            return .duoCover
        }
        if width <= 0.0 || width >= 428.0 {
            return .regularMaxPortrait
        }
        if width >= 390.0 {
            return .regularCompactPortrait
        }
        return .regularMiniPortrait
    }

    /// Continuous squircle corner radius (`7.0pt` matches measured `12px` corner tangent reach on iOS 26).
    static let keyCornerRadius: CGFloat = 7.0

    static func keyCornerRadius(for profile: LayoutProfile) -> CGFloat {
        switch profile {
        case .duoUnfoldedLandscape:
            return 11.5
        case .duoUnfoldedPortrait:
            return 10.5
        case .duoCover:
            return 8.5
        case .regularMiniPortrait, .regularCompactPortrait, .regularMaxPortrait, .regularLandscape:
            return keyCornerRadius
        }
    }

    /// Top candidate strip height:
    /// - Max/Plus/Pro portrait (`>= 390pt`): `44.0pt` (`8.0pt` top breathing + `32.5pt` pill + `3.5pt` bottom breathing)
    /// - Mini/SE portrait (`< 390pt`): `41.0pt` (`5.5pt` top breathing + `32.0pt` pill + `3.5pt` bottom breathing)
    /// - Landscape (`> 520pt`): `36.0pt`
    /// - Foldable unfolded portrait (`669x951`): `50.0pt`; unfolded book/landscape (`951x669`): `48.0pt`
    static let candidateBarHeight: CGFloat = 44.0
    static let compactCandidateBarHeight: CGFloat = 41.0
    static let duoUnfoldedPortraitCandidateBarHeight: CGFloat = 50.0
    static let duoUnfoldedLandscapeCandidateBarHeight: CGFloat = 48.0

    static func firstKeyRowTopInset(forWidth width: CGFloat, screenSize: CGSize = .zero) -> CGFloat {
        switch layoutProfile(forWidth: width, screenSize: screenSize) {
        case .duoUnfoldedPortrait:
            return 6.0
        case .duoUnfoldedLandscape:
            return 5.5
        case .regularLandscape:
            return 3.0
        default:
            return 4.5
        }
    }
    static let candidateBarLandscapeHeight: CGFloat = 36.0
    /// Legacy host top padding ceiling (`17.0pt`) kept for explicit unit-test override clamping compatibility.
    static let iOS26RoundedHostTopPadding: CGFloat = 17.0
    /// Total portrait `UIInputView` height on Max/Plus widths (`>= 428pt`: `268.5pt` = `44.0pt` candidate bar + `224.5pt` 4-row `KeyGridView`).
    static let standardPortraitKeyboardHeight: CGFloat = 268.5
    /// Total portrait `UIInputView` height on Pro/Standard widths (`390pt..<428pt`: `250.0pt` = `44.0pt` candidate bar + `206.0pt` 4-row `KeyGridView`).
    static let compactPortraitKeyboardHeight: CGFloat = 250.0
    /// Total portrait `UIInputView` height on Mini/SE widths (`< 390pt`: `239.0pt` = `41.0pt` candidate bar + `198.0pt` 4-row `KeyGridView`).
    static let miniPortraitKeyboardHeight: CGFloat = 239.0
    static let standardLandscapeKeyboardHeight: CGFloat = 197.5
    static let duoUnfoldedPortraitKeyboardHeight: CGFloat = 300.0
    static let duoUnfoldedLandscapeKeyboardHeight: CGFloat = 265.0
    /// Screen-adaptive Emoji keyboard heights (`290.0pt` Max/Plus, `276.0pt` Pro/Standard, `266.0pt` Mini/SE, `216.0pt` landscape, foldable unfolded `308.0pt` / `274.0pt`).
    static let emojiPortraitKeyboardHeight: CGFloat = 290.0
    static let emojiCompactPortraitKeyboardHeight: CGFloat = 276.0
    static let emojiMiniPortraitKeyboardHeight: CGFloat = 266.0
    static let emojiLandscapeKeyboardHeight: CGFloat = 216.0
    static let duoUnfoldedPortraitEmojiKeyboardHeight: CGFloat = 308.0
    static let duoUnfoldedLandscapeEmojiKeyboardHeight: CGFloat = 274.0

    /// Self-contained screen-adaptive keyboard height (`width` and optional `screenSize` determine tier/foldable profile; optional `hostTopPadding` for test overrides).
    static func portraitKeyboardHeight(
        forWidth width: CGFloat,
        hostTopPadding: CGFloat = 0.0,
        screenSize: CGSize = .zero
    ) -> CGFloat {
        let clampedPad = min(max(hostTopPadding, 0.0), iOS26RoundedHostTopPadding)
        switch layoutProfile(forWidth: width, screenSize: screenSize) {
        case .duoUnfoldedPortrait:
            return duoUnfoldedPortraitKeyboardHeight - clampedPad
        case .duoUnfoldedLandscape:
            return duoUnfoldedLandscapeKeyboardHeight - clampedPad
        case .regularLandscape:
            return standardLandscapeKeyboardHeight
        case .duoCover, .regularMaxPortrait:
            return standardPortraitKeyboardHeight - clampedPad
        case .regularCompactPortrait:
            return compactPortraitKeyboardHeight - clampedPad
        case .regularMiniPortrait:
            return miniPortraitKeyboardHeight - clampedPad
        }
    }

    /// Screen-adaptive `CandidateBarView` height (`50.0pt` foldable unfolded portrait, `48.0pt` foldable unfolded book, `44.0pt` >=390pt, `41.0pt` <390pt, `36.0pt` landscape; optional `hostTopPadding` clamped >= 31.0pt).
    static func portraitCandidateBarHeight(
        forWidth width: CGFloat = 440.0,
        hostTopPadding: CGFloat = 0.0,
        screenSize: CGSize = .zero
    ) -> CGFloat {
        let clampedPad = min(max(hostTopPadding, 0.0), iOS26RoundedHostTopPadding)
        switch layoutProfile(forWidth: width, screenSize: screenSize) {
        case .duoUnfoldedPortrait:
            return max(31.0, duoUnfoldedPortraitCandidateBarHeight - clampedPad)
        case .duoUnfoldedLandscape:
            return max(31.0, duoUnfoldedLandscapeCandidateBarHeight - clampedPad)
        case .regularLandscape:
            return candidateBarLandscapeHeight
        case .regularMiniPortrait:
            return max(31.0, compactCandidateBarHeight - clampedPad)
        case .duoCover, .regularCompactPortrait, .regularMaxPortrait:
            return max(31.0, candidateBarHeight - clampedPad)
        }
    }

    static func emojiKeyboardHeight(
        forWidth width: CGFloat = 440.0,
        isLandscape: Bool,
        hostTopPadding: CGFloat = 0.0,
        screenSize: CGSize = .zero
    ) -> CGFloat {
        let clampedPad = min(max(hostTopPadding, 0.0), iOS26RoundedHostTopPadding)
        let profile = layoutProfile(forWidth: width, screenSize: screenSize)
        switch profile {
        case .duoUnfoldedPortrait:
            return duoUnfoldedPortraitEmojiKeyboardHeight - clampedPad
        case .duoUnfoldedLandscape:
            return duoUnfoldedLandscapeEmojiKeyboardHeight - clampedPad
        case .regularLandscape:
            return emojiLandscapeKeyboardHeight
        case .duoCover, .regularMaxPortrait:
            if isLandscape {
                return emojiLandscapeKeyboardHeight
            }
            return emojiPortraitKeyboardHeight - clampedPad
        case .regularCompactPortrait:
            if isLandscape {
                return emojiLandscapeKeyboardHeight
            }
            return emojiCompactPortraitKeyboardHeight - clampedPad
        case .regularMiniPortrait:
            if isLandscape {
                return emojiLandscapeKeyboardHeight
            }
            return emojiMiniPortraitKeyboardHeight - clampedPad
        }
    }

    /// Disables iOS 26+ automatic `UIScrollEdgeEffect` Liquid Glass pocket blurs (`top`/`bottom`/`left`/`right`)
    /// and safe-area inset adjustments so `32.5pt` candidate strips and emoji grids stay 100% crisp and unobstructed.
    static func disableScrollEdgeEffects(on scrollView: UIScrollView) {
        scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
    }

    // MARK: - CoreText Optical Ink Centering for Fullwidth CJK Punctuation

    private static let asymmetricFullwidthPunctuation: Set<Character> = [
        "：", "；", "（", "）", "。", "，", "、", "？", "！",
        "【", "】", "｛", "｝", "《", "》", "“", "”", "‘", "’"
    ]
    private static var opticalOffsetCache: [String: CGFloat] = [:]

    /// Computes exact horizontal translation so asymmetric fullwidth CJK glyphs in PingFang SC (`：`, `。`, `，`, `（`, `）`, etc.)
    /// sit at `0.0px` dead-center on keycaps, matching Native iOS 26 regardless of device locale cascade font.
    static func opticalHorizontalOffset(for text: String, font: UIFont) -> CGFloat {
        guard text.count == 1, let ch = text.first, asymmetricFullwidthPunctuation.contains(ch) else {
            return 0
        }
        let key = "\(text)@\(Int((font.pointSize * 10).rounded()))"
        if let cached = opticalOffsetCache[key] {
            return cached
        }
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let adv = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pathBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard adv > 0, pathBounds.width > 0 else {
            opticalOffsetCache[key] = 0
            return 0
        }
        let offset = -(pathBounds.midX - adv * 0.5)
        opticalOffsetCache[key] = offset
        return offset
    }

    static func returnKeyConfig(for type: UIReturnKeyType?) -> (title: String?, symbolName: String?, isAccent: Bool) {
        guard let type else { return (nil, "return", false) }
        switch type {
        case .go:
            return ("前往", nil, true)
        case .google, .search, .yahoo:
            return ("搜索", nil, true)
        case .join:
            return ("加入", nil, true)
        case .next:
            return ("下一项", nil, false)
        case .route:
            return ("路线", nil, true)
        case .send:
            return (nil, "arrow.up", true)
        case .done:
            return ("完成", nil, true)
        case .continue:
            return ("继续", nil, true)
        default:
            return (nil, "return", false)
        }
    }

    static func returnKeyTitle(for type: UIReturnKeyType?) -> (title: String, isAccent: Bool) {
        let cfg = returnKeyConfig(for: type)
        return (cfg.title ?? "⏎", cfg.isAccent)
    }

    // MARK: - Authentic Native iOS Vector Icons (@3x Template)

    private static var cachedEmojiFaceIcons: [Int: UIImage] = [:]
    private static var cachedClockIcons: [Int: UIImage] = [:]
    private static var cachedDogIcons: [Int: UIImage] = [:]
    private static var cachedAppleIcons: [Int: UIImage] = [:]
    private static var cachedCarSideIcons: [Int: UIImage] = [:]

    /// Renders Apple's native `UIKeyboardEmojiKeyView` grinning face icon (circle + oval eyes + open teeth/mouth D-grin)
    /// as a crisp `@3x` template image matching native iOS 26 pixel-for-pixel.
    static func nativeEmojiFaceImage(pointSize: CGFloat = 20.0) -> UIImage {
        let bucket = Int((pointSize * 10).rounded())
        if let cached = cachedEmojiFaceIcons[bucket] {
            return cached
        }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false

        let img = UIGraphicsImageRenderer(size: size, format: format).image { rendererCtx in
            let ctx = rendererCtx.cgContext
            let s = pointSize / 20.0

            UIColor.black.setStroke()
            UIColor.black.setFill()

            // 1. Outer circle outline
            let outerRadius = 8.9 * s
            let outerPath = UIBezierPath(
                arcCenter: CGPoint(x: 10.0 * s, y: 10.0 * s),
                radius: outerRadius,
                startAngle: 0,
                endAngle: .pi * 2.0,
                clockwise: true
            )
            outerPath.lineWidth = 1.45 * s
            outerPath.stroke()

            // 2. Two vertical oval eyes
            let leftEye = UIBezierPath(ovalIn: CGRect(x: 6.55 * s, y: 6.45 * s, width: 1.65 * s, height: 2.35 * s))
            let rightEye = UIBezierPath(ovalIn: CGRect(x: 11.80 * s, y: 6.45 * s, width: 1.65 * s, height: 2.35 * s))
            leftEye.fill()
            rightEye.fill()

            // 3. Open grinning D-mouth (curved smiling upper lip + teeth band + solid lower mouth cavity)
            let mouthPath = UIBezierPath()
            let mouthLeft = CGPoint(x: 5.05 * s, y: 10.65 * s)
            let mouthRight = CGPoint(x: 14.95 * s, y: 10.65 * s)
            mouthPath.move(to: mouthLeft)
            mouthPath.addQuadCurve(
                to: mouthRight,
                controlPoint: CGPoint(x: 10.0 * s, y: 12.65 * s)
            )
            mouthPath.addCurve(
                to: mouthLeft,
                controlPoint1: CGPoint(x: 14.55 * s, y: 16.45 * s),
                controlPoint2: CGPoint(x: 5.45 * s, y: 16.45 * s)
            )
            mouthPath.close()

            ctx.saveGState()
            mouthPath.addClip()
            let lowerCavity = UIBezierPath()
            lowerCavity.move(to: CGPoint(x: 4.5 * s, y: 12.55 * s))
            lowerCavity.addQuadCurve(
                to: CGPoint(x: 15.5 * s, y: 12.55 * s),
                controlPoint: CGPoint(x: 10.0 * s, y: 13.75 * s)
            )
            lowerCavity.addLine(to: CGPoint(x: 15.5 * s, y: 17.5 * s))
            lowerCavity.addLine(to: CGPoint(x: 4.5 * s, y: 17.5 * s))
            lowerCavity.close()
            lowerCavity.fill()
            ctx.restoreGState()

            mouthPath.lineWidth = 1.18 * s
            mouthPath.lineJoinStyle = .round
            mouthPath.stroke()
        }.withRenderingMode(.alwaysTemplate)

        cachedEmojiFaceIcons[bucket] = img
        return img
    }

    /// Native Emoji Dock Category 0: Recent / Frequently Used clock (`12:00` + `9:00` hands).
    static func nativeEmojiClockIcon(pointSize: CGFloat = 17.5) -> UIImage {
        let bucket = Int((pointSize * 10).rounded())
        if let cached = cachedClockIcons[bucket] { return cached }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false

        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let s = pointSize / 20.0
            UIColor.black.setStroke()

            let circle = UIBezierPath(
                arcCenter: CGPoint(x: 10.0 * s, y: 10.0 * s),
                radius: 8.3 * s,
                startAngle: 0,
                endAngle: .pi * 2.0,
                clockwise: true
            )
            circle.lineWidth = 1.48 * s
            circle.stroke()

            // Native iOS Emoji Recents clock points to 9:00 (12:00 vertical up + 9:00 horizontal left)
            let hands = UIBezierPath()
            hands.move(to: CGPoint(x: 10.0 * s, y: 5.0 * s))
            hands.addLine(to: CGPoint(x: 10.0 * s, y: 10.2 * s))
            hands.addLine(to: CGPoint(x: 5.8 * s, y: 10.2 * s))
            hands.lineWidth = 1.48 * s
            hands.lineCapStyle = .round
            hands.lineJoinStyle = .round
            hands.stroke()
        }.withRenderingMode(.alwaysTemplate)

        cachedClockIcons[bucket] = img
        return img
    }

    /// Native Emoji Dock Category 2: Animals & Nature spotted puppy head (`🐶` floppy ears + right eye patch + nose + creased tongue).
    static func nativeEmojiDogIcon(pointSize: CGFloat = 19.0) -> UIImage {
        let bucket = Int((pointSize * 10).rounded())
        if let cached = cachedDogIcons[bucket] { return cached }
        let size = CGSize(width: pointSize * 1.08, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false

        let img = UIGraphicsImageRenderer(size: size, format: format).image { rendererCtx in
            let ctx = rendererCtx.cgContext
            let s = pointSize / 20.0
            let cx = size.width * 0.5
            UIColor.black.setStroke()
            UIColor.black.setFill()

            // Wide curved floppy ears flanking the puppy face
            let leftEar = UIBezierPath()
            leftEar.move(to: CGPoint(x: cx - 3.6 * s, y: 4.1 * s))
            leftEar.addCurve(
                to: CGPoint(x: cx - 8.6 * s, y: 11.4 * s),
                controlPoint1: CGPoint(x: cx - 7.8 * s, y: 3.9 * s),
                controlPoint2: CGPoint(x: cx - 9.8 * s, y: 8.8 * s)
            )
            leftEar.addQuadCurve(
                to: CGPoint(x: cx - 5.9 * s, y: 11.4 * s),
                controlPoint: CGPoint(x: cx - 7.5 * s, y: 13.0 * s)
            )
            leftEar.close()
            leftEar.fill()

            let rightEar = UIBezierPath()
            rightEar.move(to: CGPoint(x: cx + 3.6 * s, y: 4.1 * s))
            rightEar.addCurve(
                to: CGPoint(x: cx + 8.6 * s, y: 11.4 * s),
                controlPoint1: CGPoint(x: cx + 7.8 * s, y: 3.9 * s),
                controlPoint2: CGPoint(x: cx + 9.8 * s, y: 8.8 * s)
            )
            rightEar.addQuadCurve(
                to: CGPoint(x: cx + 5.9 * s, y: 11.4 * s),
                controlPoint: CGPoint(x: cx + 7.5 * s, y: 13.0 * s)
            )
            rightEar.close()
            rightEar.fill()

            // Plump rounded-oval puppy face outline
            let head = UIBezierPath(
                roundedRect: CGRect(x: cx - 6.2 * s, y: 3.9 * s, width: 12.4 * s, height: 11.2 * s),
                cornerRadius: 5.5 * s
            )
            head.lineWidth = 1.42 * s
            head.stroke()

            // Left eye: vertical dark oval
            UIBezierPath(ovalIn: CGRect(x: cx - 3.2 * s, y: 8.3 * s, width: 1.4 * s, height: 1.9 * s)).fill()

            // Viewer-right eye: tilted filled dark oval patch with even-odd white eye ring cutout + dark pupil
            ctx.saveGState()
            ctx.translateBy(x: cx + 2.6 * s, y: 9.0 * s)
            ctx.rotate(by: -0.22)
            let patch = UIBezierPath(ovalIn: CGRect(x: -2.05 * s, y: -2.75 * s, width: 4.1 * s, height: 5.5 * s))
            let cutout = UIBezierPath(ovalIn: CGRect(x: -1.05 * s, y: -1.45 * s, width: 2.1 * s, height: 2.9 * s))
            patch.append(cutout)
            patch.usesEvenOddFillRule = true
            patch.fill()
            UIBezierPath(ovalIn: CGRect(x: -0.55 * s, y: -0.85 * s, width: 1.1 * s, height: 1.7 * s)).fill()
            ctx.restoreGState()

            // Cute oval nose
            UIBezierPath(ovalIn: CGRect(x: cx - 1.05 * s, y: 11.2 * s, width: 2.1 * s, height: 1.4 * s)).fill()

            // Sticking-out tongue loop with vertical center crease
            let tongue = UIBezierPath()
            tongue.move(to: CGPoint(x: cx - 1.35 * s, y: 15.0 * s))
            tongue.addCurve(
                to: CGPoint(x: cx + 1.35 * s, y: 15.0 * s),
                controlPoint1: CGPoint(x: cx - 1.45 * s, y: 18.0 * s),
                controlPoint2: CGPoint(x: cx + 1.45 * s, y: 18.0 * s)
            )
            tongue.move(to: CGPoint(x: cx, y: 15.1 * s))
            tongue.addLine(to: CGPoint(x: cx, y: 16.9 * s))
            tongue.lineWidth = 1.18 * s
            tongue.lineCapStyle = .round
            tongue.stroke()
        }.withRenderingMode(.alwaysTemplate)

        cachedDogIcons[bucket] = img
        return img
    }

    /// Native Emoji Dock Category 3: Food & Drink crisp wide-shouldered apple outline (`🍎` body + stem + leaf).
    static func nativeEmojiAppleIcon(pointSize: CGFloat = 18.0) -> UIImage {
        let bucket = Int((pointSize * 10).rounded())
        if let cached = cachedAppleIcons[bucket] { return cached }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false

        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let s = pointSize / 20.0
            UIColor.black.setStroke()
            UIColor.black.setFill()

            // Plump wide-shouldered Macintosh/Emoji apple silhouette with top & bottom dimples
            let body = UIBezierPath()
            body.move(to: CGPoint(x: 10.0 * s, y: 6.5 * s))
            body.addCurve(
                to: CGPoint(x: 2.8 * s, y: 10.8 * s),
                controlPoint1: CGPoint(x: 7.0 * s, y: 4.9 * s),
                controlPoint2: CGPoint(x: 2.8 * s, y: 6.9 * s)
            )
            body.addCurve(
                to: CGPoint(x: 8.1 * s, y: 17.6 * s),
                controlPoint1: CGPoint(x: 2.8 * s, y: 14.8 * s),
                controlPoint2: CGPoint(x: 5.5 * s, y: 18.0 * s)
            )
            body.addQuadCurve(
                to: CGPoint(x: 11.9 * s, y: 17.6 * s),
                controlPoint: CGPoint(x: 10.0 * s, y: 16.7 * s)
            )
            body.addCurve(
                to: CGPoint(x: 17.2 * s, y: 10.8 * s),
                controlPoint1: CGPoint(x: 14.5 * s, y: 18.0 * s),
                controlPoint2: CGPoint(x: 17.2 * s, y: 14.8 * s)
            )
            body.addCurve(
                to: CGPoint(x: 10.0 * s, y: 6.5 * s),
                controlPoint1: CGPoint(x: 17.2 * s, y: 6.9 * s),
                controlPoint2: CGPoint(x: 13.0 * s, y: 4.9 * s)
            )
            body.close()
            body.lineWidth = 1.44 * s
            body.lineJoinStyle = .round
            body.stroke()

            // Short curved stem
            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: 9.7 * s, y: 6.2 * s))
            stem.addQuadCurve(
                to: CGPoint(x: 8.5 * s, y: 2.6 * s),
                controlPoint: CGPoint(x: 8.7 * s, y: 4.2 * s)
            )
            stem.lineWidth = 1.35 * s
            stem.lineCapStyle = .round
            stem.stroke()

            // Plump angled leaf
            let leaf = UIBezierPath()
            leaf.move(to: CGPoint(x: 10.1 * s, y: 5.1 * s))
            leaf.addQuadCurve(
                to: CGPoint(x: 14.0 * s, y: 2.4 * s),
                controlPoint: CGPoint(x: 10.7 * s, y: 2.2 * s)
            )
            leaf.addQuadCurve(
                to: CGPoint(x: 10.1 * s, y: 5.1 * s),
                controlPoint: CGPoint(x: 13.7 * s, y: 5.1 * s)
            )
            leaf.close()
            leaf.fill()
        }.withRenderingMode(.alwaysTemplate)

        cachedAppleIcons[bucket] = img
        return img
    }

    /// Native Emoji Dock Category 5: Travel & Places left-facing compact Smart hatchback (`🚗` tall arched cabin + filled D-window + rear antenna + door trim).
    static func nativeEmojiCarSideIcon(pointSize: CGFloat = 18.5) -> UIImage {
        let bucket = Int((pointSize * 10).rounded())
        if let cached = cachedCarSideIcons[bucket] { return cached }
        let size = CGSize(width: pointSize * 1.15, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false

        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let s = pointSize / 20.0
            UIColor.black.setStroke()
            UIColor.black.setFill()

            // Left-facing tall rounded compact hatchback body with wheel cutouts
            let car = UIBezierPath()
            car.move(to: CGPoint(x: 4.1 * s, y: 14.8 * s))
            car.addLine(to: CGPoint(x: 2.2 * s, y: 14.8 * s))
            car.addQuadCurve(
                to: CGPoint(x: 2.0 * s, y: 11.4 * s),
                controlPoint: CGPoint(x: 1.4 * s, y: 13.4 * s)
            )
            car.addQuadCurve(
                to: CGPoint(x: 6.4 * s, y: 9.4 * s),
                controlPoint: CGPoint(x: 3.4 * s, y: 10.0 * s)
            )
            // Tall rounded Smart-car cabin arch
            car.addCurve(
                to: CGPoint(x: 19.6 * s, y: 10.8 * s),
                controlPoint1: CGPoint(x: 8.8 * s, y: 3.8 * s),
                controlPoint2: CGPoint(x: 17.8 * s, y: 3.8 * s)
            )
            car.addQuadCurve(
                to: CGPoint(x: 20.4 * s, y: 14.8 * s),
                controlPoint: CGPoint(x: 20.8 * s, y: 13.0 * s)
            )
            car.addLine(to: CGPoint(x: 18.6 * s, y: 14.8 * s))

            // Lower sill between front & rear wheels
            car.move(to: CGPoint(x: 8.5 * s, y: 14.8 * s))
            car.addLine(to: CGPoint(x: 14.2 * s, y: 14.8 * s))

            // Horizontal door trim line between wheels
            car.move(to: CGPoint(x: 9.2 * s, y: 12.7 * s))
            car.addLine(to: CGPoint(x: 13.5 * s, y: 12.7 * s))

            // Short angled rear roof antenna at top-right
            car.move(to: CGPoint(x: 17.0 * s, y: 5.5 * s))
            car.addLine(to: CGPoint(x: 18.2 * s, y: 4.1 * s))

            car.lineWidth = 1.40 * s
            car.lineCapStyle = .round
            car.lineJoinStyle = .round
            car.stroke()

            // Solid-filled dark D-window inside the cabin arch
            let win = UIBezierPath()
            win.move(to: CGPoint(x: 8.1 * s, y: 10.1 * s))
            win.addCurve(
                to: CGPoint(x: 17.2 * s, y: 10.1 * s),
                controlPoint1: CGPoint(x: 9.6 * s, y: 5.8 * s),
                controlPoint2: CGPoint(x: 16.0 * s, y: 5.8 * s)
            )
            win.close()
            win.fill()

            // Front & rear wheels
            let leftWheel = UIBezierPath(
                arcCenter: CGPoint(x: 6.3 * s, y: 14.9 * s),
                radius: 2.05 * s,
                startAngle: 0,
                endAngle: .pi * 2.0,
                clockwise: true
            )
            leftWheel.lineWidth = 1.40 * s
            leftWheel.stroke()

            let rightWheel = UIBezierPath(
                arcCenter: CGPoint(x: 16.4 * s, y: 14.9 * s),
                radius: 2.05 * s,
                startAngle: 0,
                endAngle: .pi * 2.0,
                clockwise: true
            )
            rightWheel.lineWidth = 1.40 * s
            rightWheel.stroke()
        }.withRenderingMode(.alwaysTemplate)

        cachedCarSideIcons[bucket] = img
        return img
    }

    static func clearCachesForMemoryWarning() {
        opticalOffsetCache.removeAll(keepingCapacity: false)
        cachedEmojiFaceIcons.removeAll(keepingCapacity: false)
        cachedClockIcons.removeAll(keepingCapacity: false)
        cachedDogIcons.removeAll(keepingCapacity: false)
        cachedAppleIcons.removeAll(keepingCapacity: false)
        cachedCarSideIcons.removeAll(keepingCapacity: false)
    }
}
