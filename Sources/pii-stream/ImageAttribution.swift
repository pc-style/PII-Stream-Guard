import CoreGraphics
import CoreText
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum ImageAttributionStyle: Equatable {
    case none
    case badge
    case watermark
}

/// Matches website `Layout.astro` tokens: --bar, --paper, --stamp, classification strip.
public enum ImageAttribution {
    public static let badgeLead = "saved by"
    public static let badgeBrand = "pii stream guard"
    public static let watermarkText = "pii stream guard"

    private enum SiteColor {
        static let bar = CGColor(red: 22 / 255, green: 19 / 255, blue: 13 / 255, alpha: 1)
        static let paper = CGColor(red: 236 / 255, green: 233 / 255, blue: 223 / 255, alpha: 1)
        static let stamp = CGColor(red: 184 / 255, green: 57 / 255, blue: 43 / 255, alpha: 1)
    }

    public static func draw(
        in context: CGContext,
        imageSize: CGSize,
        style: ImageAttributionStyle
    ) {
        switch style {
        case .none:
            return
        case .badge:
            drawClassificationStrip(in: context, imageSize: imageSize)
        case .watermark:
            drawWatermark(in: context, imageSize: imageSize)
        }
    }

    /// Full-bleed top strip like the site `.strip` — sizes are fractions of image width/height.
    private static func drawClassificationStrip(in context: CGContext, imageSize: CGSize) {
        let w = imageSize.width
        let h = imageSize.height
        guard w > 0, h > 0 else { return }

        let stripHeight = h * 0.048
        let padX = w * 0.028
        let fontSize = w * 0.0145
        let letterSpacing = fontSize * 0.18
        let blipSize = stripHeight * 0.22

        let strip = CGRect(x: 0, y: h - stripHeight, width: w, height: stripHeight)

        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(SiteColor.bar)
        context.fill(strip)

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)

        let leadAttrs = attributedAttributes(
            font: font,
            color: CGColor(red: 236 / 255, green: 233 / 255, blue: 223 / 255, alpha: 0.82),
            letterSpacing: letterSpacing
        )
        let brandAttrs = attributedAttributes(
            font: font,
            color: SiteColor.paper,
            letterSpacing: letterSpacing
        )

        let lead = displayString(badgeLead, attributes: leadAttrs)
        let brand = displayString(" \(badgeBrand)", attributes: brandAttrs)
        let combined = NSMutableAttributedString(attributedString: lead)
        combined.append(brand)

        let line = CTLineCreateWithAttributedString(combined)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let textX = w - padX - textWidth
        let textY = strip.minY + (stripHeight - fontSize) * 0.42

        let blipX = padX
        let blipY = strip.minY + (stripHeight - blipSize) / 2
        context.setFillColor(SiteColor.stamp)
        context.fillEllipse(in: CGRect(x: blipX, y: blipY, width: blipSize, height: blipSize))

        context.textMatrix = .identity
        context.textPosition = CGPoint(x: max(padX + blipSize + w * 0.018, textX), y: textY)
        CTLineDraw(line, context)
    }

    private static func drawWatermark(in context: CGContext, imageSize: CGSize) {
        let w = imageSize.width
        let h = imageSize.height
        let fontSize = w * 0.072
        let letterSpacing = fontSize * 0.14

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)

        let attrs = attributedAttributes(
            font: font,
            color: CGColor(gray: 1, alpha: 0.14),
            letterSpacing: letterSpacing
        )
        guard let attributed = CFAttributedStringCreate(nil, watermarkText.uppercased() as CFString, attrs as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let textHeight = fontSize * 1.15
        let centerX = w / 2
        let centerY = h / 2

        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: centerX, y: centerY)
        context.rotate(by: -.pi / 6)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -textWidth / 2, y: -textHeight / 2)
        CTLineDraw(line, context)
    }

    private static func attributedAttributes(
        font: CTFont,
        color: CGColor,
        letterSpacing: CGFloat
    ) -> [CFString: Any] {
        [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTKernAttributeName: letterSpacing,
        ]
    }

    private static func displayString(_ text: String, attributes: [CFString: Any]) -> NSAttributedString {
        let upper = text.uppercased() as CFString
        guard let attr = CFAttributedStringCreate(nil, upper, attributes as CFDictionary) else {
            return NSAttributedString(string: text.uppercased())
        }
        return attr as NSAttributedString
    }
}