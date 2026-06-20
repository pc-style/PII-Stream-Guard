import CoreGraphics
import CoreVideo
import Foundation

enum PIIKind: String, Codable {
    case email
    case needle
}

struct PIIBox: Codable {
    let kind: PIIKind
    let matched: String
    let confidence: Float
    let normalizedRect: CGRect
    let detectedAt: TimeInterval
}

struct DetectionSnapshot {
    let boxes: [PIIBox]
    let frameSize: CGSize
    let capturedAt: TimeInterval
    let guardMode: GuardMode
    let armed: Bool
    let blackoutWholeFrame: Bool

    static let empty = DetectionSnapshot(
        boxes: [],
        frameSize: .zero,
        capturedAt: 0,
        guardMode: .balanced,
        armed: false,
        blackoutWholeFrame: false
    )
}

struct FrameSample {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: TimeInterval
    let frameSize: CGSize
}
