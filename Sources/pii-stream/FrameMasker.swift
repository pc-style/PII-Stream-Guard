import CoreGraphics
import CoreText
import Foundation

public struct FrameMasker {
    public static func pixelRect(from normalizedRect: CGRect, frameSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.origin.x * frameSize.width,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * frameSize.height,
            width: normalizedRect.width * frameSize.width,
            height: normalizedRect.height * frameSize.height
        )
    }

    public static func builtInBlackoutRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let horizontalPadding = max(80, rect.width * 0.45)
        let verticalPadding = max(10, rect.height * 1.2)
        return rect
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(bounds)
    }

    public static func usesBuiltInMasking(for mode: GuardMode) -> Bool {
        switch mode {
        case .lockdown, .standard, .lowLatency:
            return true
        }
    }

    public static func protectedRects(
        for boxes: [PIIBox],
        frameSize: CGSize,
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool = false
    ) -> [CGRect] {
        protectedRects(
            for: boxes,
            frameSize: frameSize,
            maskMode: maskMode,
            usesBuiltInMasking: usesBuiltInMasking(for: guardMode),
            blackoutWholeFrame: blackoutWholeFrame
        )
    }

    public static func protectedRects(
        for boxes: [PIIBox],
        frameSize: CGSize,
        maskMode: MaskMode,
        usesBuiltInMasking: Bool,
        blackoutWholeFrame: Bool = false
    ) -> [CGRect] {
        let frameBounds = CGRect(origin: .zero, size: frameSize)
        guard frameBounds.width > 0, frameBounds.height > 0 else { return [] }
        if blackoutWholeFrame { return [frameBounds] }
        return boxes.map { protectedRect(for: $0, frameSize: frameSize, frameBounds: frameBounds, maskMode: maskMode, usesBuiltInMasking: usesBuiltInMasking) }
    }

    public static func overlayRects(
        for boxes: [PIIBox],
        frameSize: CGSize,
        viewBounds: CGRect,
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool = false,
        mapsOverlayToBounds: Bool = false
    ) -> [CGRect] {
        overlayRects(
            for: boxes,
            frameSize: frameSize,
            viewBounds: viewBounds,
            maskMode: maskMode,
            usesBuiltInMasking: usesBuiltInMasking(for: guardMode),
            blackoutWholeFrame: blackoutWholeFrame,
            mapsOverlayToBounds: mapsOverlayToBounds
        )
    }

    public static func overlayRects(
        for boxes: [PIIBox],
        frameSize: CGSize,
        viewBounds: CGRect,
        maskMode: MaskMode,
        usesBuiltInMasking: Bool,
        blackoutWholeFrame: Bool = false,
        mapsOverlayToBounds: Bool = false
    ) -> [CGRect] {
        guard frameSize.width > 0, frameSize.height > 0, viewBounds.width > 0, viewBounds.height > 0 else { return [] }
        if blackoutWholeFrame { return [viewBounds] }

        let scaleX: CGFloat
        let scaleY: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        let projectionSize: CGSize
        if mapsOverlayToBounds {
            scaleX = 1
            scaleY = 1
            offsetX = 0
            offsetY = 0
            projectionSize = viewBounds.size
        } else {
            let scale = min(viewBounds.width / frameSize.width, viewBounds.height / frameSize.height)
            let drawnWidth = frameSize.width * scale
            let drawnHeight = frameSize.height * scale
            scaleX = scale
            scaleY = scale
            offsetX = (viewBounds.width - drawnWidth) / 2
            offsetY = (viewBounds.height - drawnHeight) / 2
            projectionSize = frameSize
        }

        return boxes.map { box in
            let rect = pixelRect(from: box.normalizedRect, frameSize: projectionSize)
            var scaled = CGRect(
                x: offsetX + rect.origin.x * scaleX,
                y: offsetY + rect.origin.y * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
            if maskMode == .blackout, usesBuiltInMasking {
                scaled = builtInBlackoutRect(scaled, within: viewBounds)
            }
            return scaled
        }
    }

    static func drawMasks(
        in context: CGContext,
        frameSize: CGSize,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool,
        rectMapping: CGContextRectMapping
    ) {
        let frameBounds = CGRect(origin: .zero, size: frameSize)
        guard frameBounds.width > 0, frameBounds.height > 0 else { return }

        if blackoutWholeFrame {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rectMapping.map(frameBounds, frameHeight: frameSize.height))
            return
        }

        for rect in protectedRects(for: boxes, frameSize: frameSize, maskMode: maskMode, guardMode: guardMode) {
            let drawRect = rectMapping.map(rect, frameHeight: frameSize.height)
            switch maskMode {
            case .blackout:
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(drawRect)
            case .boundingBox:
                context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.setLineWidth(4)
                context.stroke(drawRect)
            }
        }
    }

    static func drawMasks(
        in context: CGContext,
        frameSize: CGSize,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool,
        rectMapping: CGContextRectMapping,
        presentation: ImageOutputPresentation
    ) {
        guard presentation == .demo else {
            drawMasks(
                in: context,
                frameSize: frameSize,
                boxes: boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                blackoutWholeFrame: blackoutWholeFrame,
                rectMapping: rectMapping
            )
            return
        }

        let frameBounds = CGRect(origin: .zero, size: frameSize)
        guard frameBounds.width > 0, frameBounds.height > 0 else { return }

        if blackoutWholeFrame {
            let drawRect = rectMapping.map(frameBounds, frameHeight: frameSize.height)
            drawDemoRedaction(in: context, rect: drawRect, frameSize: frameSize, label: true)
            return
        }

        for rect in protectedRects(for: boxes, frameSize: frameSize, maskMode: maskMode, guardMode: guardMode) {
            let drawRect = rectMapping.map(rect, frameHeight: frameSize.height)
            let showLabel = drawRect.width > frameSize.width * 0.2
            drawDemoRedaction(in: context, rect: drawRect, frameSize: frameSize, label: showLabel)
        }
    }

    private static func drawDemoRedaction(
        in context: CGContext,
        rect: CGRect,
        frameSize: CGSize,
        label: Bool
    ) {
        let drawRect = rect
        let bar = CGColor(red: 22 / 255, green: 19 / 255, blue: 13 / 255, alpha: 1)
        let stamp = CGColor(red: 184 / 255, green: 57 / 255, blue: 43 / 255, alpha: 1)

        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(bar)
        context.fill(drawRect)

        context.setStrokeColor(stamp)
        context.setLineWidth(max(2, frameSize.width * 0.003))
        context.stroke(drawRect.insetBy(dx: -1, dy: -1))

        context.clip(to: drawRect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        context.setLineWidth(max(1, frameSize.width * 0.0015))
        let step = max(8, frameSize.width * 0.012)
        var x: CGFloat = drawRect.minX - drawRect.height
        while x < drawRect.maxX + drawRect.height {
            context.move(to: CGPoint(x: x, y: drawRect.minY))
            context.addLine(to: CGPoint(x: x + drawRect.height, y: drawRect.maxY))
            x += step
        }
        context.strokePath()

        guard label else { return }
        let fontSize = max(10, frameSize.width * 0.011)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: stamp,
            kCTKernAttributeName: fontSize * 0.12,
        ]
        let text = "REDACTED" as CFString
        guard let attr = CFAttributedStringCreate(nil, text, attrs as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attr)
        let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: drawRect.midX - tw / 2,
            y: drawRect.midY - fontSize / 2
        )
        CTLineDraw(line, context)
    }

    private static func protectedRect(
        for box: PIIBox,
        frameSize: CGSize,
        frameBounds: CGRect,
        maskMode: MaskMode,
        usesBuiltInMasking: Bool
    ) -> CGRect {
        var rect = pixelRect(from: box.normalizedRect, frameSize: frameSize)
        guard maskMode == .blackout else { return rect }
        if usesBuiltInMasking, rect.width < frameBounds.width * 0.85 {
            rect = builtInBlackoutRect(rect, within: frameBounds)
        } else if !usesBuiltInMasking {
            rect = rect.insetBy(dx: -12, dy: -8).intersection(frameBounds)
        }
        return rect
    }
}

enum CGContextRectMapping {
    case direct
    case topLeftToBottomLeft

    func map(_ rect: CGRect, frameHeight: CGFloat) -> CGRect {
        switch self {
        case .direct:
            return rect
        case .topLeftToBottomLeft:
            return CGRect(
                x: rect.origin.x,
                y: frameHeight - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
    }
}
