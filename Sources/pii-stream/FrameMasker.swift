import CoreGraphics
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
}
