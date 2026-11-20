import UIKit

/// Zero-lag native-contour key popup callout bubble (`CAShapeLayer`) rendered above the pressed keycap.
/// Placed in the top-level keyboard view so Row 0 (`Q-P`) callouts rise smoothly above the candidate bar without clipping.
final class KeyCalloutBubbleView: UIView {
    /// Key-relative bucketed geometry key: interior keys across the entire keyboard share identical `(w, h, dx, dy)`
    /// (~4 cached `CGPath` entries per keyboard orientation instead of 26+ per-key allocations).
    private struct PathKey: Hashable {
        let w: Int32
        let h: Int32
        let dx: Int32
        let dy: Int32
    }

    private let shapeLayer = CAShapeLayer()
    private let label = UILabel()
    private static var pathCache: [PathKey: CGPath] = [:]
    private var lastAppliedPathKey: PathKey?
    private var lastAppliedPosition: CGPoint = CGPoint(x: -9999, y: -9999)
    private var lastAppliedDark: Bool? = nil
    private var lastPrewarmedSignature: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isHidden = true

        shapeLayer.anchorPoint = .zero
        shapeLayer.bounds = .zero
        shapeLayer.lineWidth = 0.5
        shapeLayer.shadowColor = UIColor.clear.cgColor
        shapeLayer.shadowOffset = .zero
        shapeLayer.shadowRadius = 0.0
        shapeLayer.shadowOpacity = 0.0
        layer.addSublayer(shapeLayer)

        label.textAlignment = .center
        label.font = .systemFont(ofSize: 36, weight: .regular)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pre-warms callout `CGPath` buckets, layer colors, and glyph layout during `KeyGridView` layout
    /// so the very first finger-down hits warm caches in `< 0.01ms` with zero `UIBezierPath` allocation.
    func prewarm(
        keyWidth: CGFloat,
        keyHeight: CGFloat,
        row0MinY: CGFloat,
        row1MinY: CGFloat,
        sideInset: CGFloat,
        containerWidth: CGFloat,
        dark: Bool
    ) {
        guard keyWidth > 8.0, keyHeight > 8.0, containerWidth > 80.0 else { return }
        let sig = (Int64((keyWidth * 4).rounded()) << 40)
            ^ (Int64((keyHeight * 4).rounded()) << 28)
            ^ (Int64((row0MinY * 2).rounded()) << 16)
            ^ (Int64((containerWidth * 2).rounded()) << 2)
            ^ (dark ? 1 : 0)
        guard sig != lastPrewarmedSignature else { return }
        lastPrewarmedSignature = sig

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let sampleFrames = [
            CGRect(x: sideInset, y: row0MinY, width: keyWidth, height: keyHeight),
            CGRect(x: containerWidth * 0.5 - keyWidth * 0.5, y: row0MinY, width: keyWidth, height: keyHeight),
            CGRect(x: containerWidth - sideInset - keyWidth, y: row0MinY, width: keyWidth, height: keyHeight),
            CGRect(x: containerWidth * 0.5 - keyWidth * 0.5, y: row1MinY, width: keyWidth, height: keyHeight)
        ]
        var firstBuilt: (PathKey, CGPath)?
        for kf in sampleFrames {
            let resolved = Self.resolveLocalPath(for: kf, containerWidth: containerWidth)
            if firstBuilt == nil {
                firstBuilt = (resolved.key, resolved.path)
            }
        }
        if let (pk, cgPath) = firstBuilt, lastAppliedPathKey == nil {
            lastAppliedPathKey = pk
            shapeLayer.path = cgPath
            shapeLayer.shadowPath = cgPath
        }
        if lastAppliedDark != dark {
            lastAppliedDark = dark
            shapeLayer.fillColor = KeyboardTheme.calloutBubbleFill(dark: dark).cgColor
            shapeLayer.strokeColor = KeyboardTheme.calloutStrokeColor(dark: dark).cgColor
            label.textColor = KeyboardTheme.primaryKeyTextColor(dark: dark)
        }
        if label.text == nil {
            label.text = "a"
        }
    }

    private static func resolveLocalPath(
        for keyFrame: CGRect,
        containerWidth: CGFloat
    ) -> (key: PathKey, path: CGPath, headMinX: CGFloat, headMinY: CGFloat, headWidth: CGFloat, headHeight: CGFloat) {
        let headWidth = max(keyFrame.width * 1.54, 48.0)
        let headHeight: CGFloat = 52.0
        let neckHeight: CGFloat = 9.0

        var headMinX = keyFrame.midX - headWidth * 0.5
        let edgeInset: CGFloat = 3.0
        if headMinX < edgeInset {
            headMinX = edgeInset
        } else if headMinX + headWidth > containerWidth - edgeInset {
            headMinX = containerWidth - edgeInset - headWidth
        }
        let headMaxY = keyFrame.minY - neckHeight
        let headMinY = max(2.0, headMaxY - headHeight)
        let actualHeadH = headMaxY - headMinY

        let relHeadX = headMinX - keyFrame.minX
        let relHeadY = headMinY - keyFrame.minY
        let pathKey = PathKey(
            w: Int32((keyFrame.width * 4).rounded()),
            h: Int32((keyFrame.height * 4).rounded()),
            dx: Int32((relHeadX * 4).rounded()),
            dy: Int32((relHeadY * 4).rounded())
        )
        let cgPath: CGPath
        if let cached = pathCache[pathKey] {
            cgPath = cached
        } else {
            let localBase = CGRect(x: 0.0, y: 0.0, width: keyFrame.width, height: keyFrame.height)
            let localHead = CGRect(x: relHeadX, y: relHeadY, width: headWidth, height: actualHeadH)
            let built = makeUnifiedCalloutPath(
                base: localBase,
                head: localHead,
                headRadius: 10.5,
                baseRadius: KeyboardTheme.keyCornerRadius
            ).cgPath
            if pathCache.count >= 64 {
                pathCache.removeAll(keepingCapacity: true)
            }
            pathCache[pathKey] = built
            cgPath = built
        }
        return (pathKey, cgPath, headMinX, headMinY, headWidth, actualHeadH)
    }

    func show(text: String, keyFrame: CGRect, containerWidth: CGFloat, dark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let resolved = Self.resolveLocalPath(for: keyFrame, containerWidth: containerWidth)
        if lastAppliedPathKey != resolved.key {
            lastAppliedPathKey = resolved.key
            shapeLayer.path = resolved.path
            shapeLayer.shadowPath = resolved.path
        }
        if lastAppliedPosition != keyFrame.origin {
            lastAppliedPosition = keyFrame.origin
            shapeLayer.position = keyFrame.origin
        }
        if lastAppliedDark != dark {
            lastAppliedDark = dark
            shapeLayer.fillColor = KeyboardTheme.calloutBubbleFill(dark: dark).cgColor
            shapeLayer.strokeColor = KeyboardTheme.calloutStrokeColor(dark: dark).cgColor
            label.textColor = KeyboardTheme.primaryKeyTextColor(dark: dark)
        }

        if label.text != text {
            label.text = text
        }
        let optX = KeyboardTheme.opticalHorizontalOffset(for: text, font: label.font)
        let nextLabelFrame = CGRect(
            x: resolved.headMinX + optX,
            y: resolved.headMinY - 1.0,
            width: resolved.headWidth,
            height: resolved.headHeight
        )
        if label.frame != nextLabelFrame {
            label.frame = nextLabelFrame
        }

        if isHidden {
            isHidden = false
        }
        CATransaction.commit()
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
    }

    private static func makeUnifiedCalloutPath(
        base: CGRect,
        head: CGRect,
        headRadius rH: CGFloat,
        baseRadius rB: CGFloat
    ) -> UIBezierPath {
        let p = UIBezierPath()
        let midNeckY = (head.maxY + base.minY) * 0.5

        // Start at top-left of head (after corner arc)
        p.move(to: CGPoint(x: head.minX + rH, y: head.minY))
        p.addLine(to: CGPoint(x: head.maxX - rH, y: head.minY))
        p.addArc(
            withCenter: CGPoint(x: head.maxX - rH, y: head.minY + rH),
            radius: rH,
            startAngle: -.pi * 0.5,
            endAngle: 0,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: head.maxX, y: head.maxY - rH * 0.6))

        // Smooth S-curve neck on right side down into base right edge
        p.addCurve(
            to: CGPoint(x: base.maxX, y: base.minY + 4.0),
            controlPoint1: CGPoint(x: head.maxX, y: midNeckY),
            controlPoint2: CGPoint(x: base.maxX, y: midNeckY)
        )

        // Base right -> bottom-right -> bottom-left -> base left
        p.addLine(to: CGPoint(x: base.maxX, y: base.maxY - rB))
        p.addArc(
            withCenter: CGPoint(x: base.maxX - rB, y: base.maxY - rB),
            radius: rB,
            startAngle: 0,
            endAngle: .pi * 0.5,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: base.minX + rB, y: base.maxY))
        p.addArc(
            withCenter: CGPoint(x: base.minX + rB, y: base.maxY - rB),
            radius: rB,
            startAngle: .pi * 0.5,
            endAngle: .pi,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: base.minX, y: base.minY + 4.0))

        // Smooth S-curve neck on left side back up to head left edge
        p.addCurve(
            to: CGPoint(x: head.minX, y: head.maxY - rH * 0.6),
            controlPoint1: CGPoint(x: base.minX, y: midNeckY),
            controlPoint2: CGPoint(x: head.minX, y: midNeckY)
        )

        p.addLine(to: CGPoint(x: head.minX, y: head.minY + rH))
        p.addArc(
            withCenter: CGPoint(x: head.minX + rH, y: head.minY + rH),
            radius: rH,
            startAngle: .pi,
            endAngle: -.pi * 0.5,
            clockwise: true
        )
        p.close()
        return p
    }

    static func clearCachesForMemoryWarning() {
        pathCache.removeAll(keepingCapacity: false)
    }

    func clearCachedPathStateIfHidden() {
        guard isHidden else { return }
        lastAppliedPathKey = nil
        lastPrewarmedSignature = 0
        shapeLayer.path = nil
        shapeLayer.shadowPath = nil
    }
}
