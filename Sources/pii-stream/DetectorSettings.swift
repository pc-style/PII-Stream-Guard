import CoreGraphics
import Foundation

struct DetectorSettings: Codable, Equatable {
    var accurate: Bool = false
    var maxPixelSize: CGFloat = 1440
    var minimumTextHeight: Float = 0.012
    var enhanceLowContrast: Bool = false
}
