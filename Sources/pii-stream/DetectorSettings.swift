import CoreGraphics
import Foundation

public struct DetectorSettings: Codable, Equatable {
    public var accurate: Bool
    public var maxPixelSize: CGFloat
    public var minimumTextHeight: Float
    public var enhanceLowContrast: Bool

    public init(
        accurate: Bool = false,
        maxPixelSize: CGFloat = 1440,
        minimumTextHeight: Float = 0.012,
        enhanceLowContrast: Bool = false
    ) {
        self.accurate = accurate
        self.maxPixelSize = maxPixelSize
        self.minimumTextHeight = minimumTextHeight
        self.enhanceLowContrast = enhanceLowContrast
    }
}
