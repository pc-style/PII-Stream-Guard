import CoreGraphics
import CoreText
import Foundation

/// Website-matched document frame for `--demo` exports (all sizes are % of image).
enum ImageDemoFrame {
    private enum SiteColor {
        static let bar = CGColor(red: 22 / 255, green: 19 / 255, blue: 13 / 255, alpha: 1)
        static let paper = CGColor(red: 236 / 255, green: 233 / 255, blue: 223 / 255, alpha: 1)
        static let stamp = CGColor(red: 184 / 255, green: 57 / 255, blue: 43 / 255, alpha: 1)
    }

    static func draw(in context: CGContext, imageSize: CGSize) {
        let w = imageSize.width
        let h = imageSize.height
        guard w > 0, h > 0 else { return }

        let margin = w * 0.024
        let stripH = h * 0.044
        let barWidth = max(2, w * 0.005)

        context.saveGState()
        defer { context.restoreGState() }

        let topStrip = CGRect(x: 0, y: h - stripH, width: w, height: stripH)
        let bottomStrip = CGRect(x: 0, y: 0, width: w, height: stripH)
        let inner = CGRect(
            x: margin,
            y: bottomStrip.maxY + margin * 0.35,
            width: w - margin * 2,
            height: topStrip.minY - bottomStrip.maxY - margin * 0.7
        )

        context.setFillColor(SiteColor.paper)
        context.fill(CGRect(x: 0, y: topStrip.minY, width: w, height: h - topStrip.minY))
        context.fill(CGRect(x: 0, y: 0, width: w, height: bottomStrip.maxY))
        context.fill(CGRect(x: 0, y: bottomStrip.maxY, width: margin, height: inner.height))
        context.fill(CGRect(x: w - margin, y: bottomStrip.maxY, width: margin, height: inner.height))

        context.setStrokeColor(SiteColor.bar)
        context.setLineWidth(barWidth)
        context.stroke(inner)

        context.setStrokeColor(SiteColor.stamp)
        context.setLineWidth(max(1, w * 0.0018))
        context.stroke(inner.insetBy(dx: barWidth * 0.6, dy: barWidth * 0.6))

        drawStrip(in: context, rect: topStrip, label: "saved by pii stream guard", imageWidth: w, stripHeight: stripH)
        drawStrip(in: context, rect: bottomStrip, label: "redacted preview", imageWidth: w, stripHeight: stripH)
    }

    private static func drawStrip(
        in context: CGContext,
        rect: CGRect,
        label: String,
        imageWidth: CGFloat,
        stripHeight: CGFloat
    ) {
        context.setFillColor(SiteColor.bar)
        context.fill(rect)

        let fontSize = imageWidth * 0.0135
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: SiteColor.paper,
            kCTKernAttributeName: fontSize * 0.16,
        ]
        let upper = label.uppercased() as CFString
        guard let attr = CFAttributedStringCreate(nil, upper, attrs as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attr)
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let pad = imageWidth * 0.028
        let blip = stripHeight * 0.2
        context.setFillColor(SiteColor.stamp)
        context.fillEllipse(in: CGRect(x: pad, y: rect.midY - blip / 2, width: blip, height: blip))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.maxX - pad - textW, y: rect.minY + (stripHeight - fontSize) * 0.4)
        CTLineDraw(line, context)
    }
}