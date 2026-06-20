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
}

struct FrameSample {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: TimeInterval
    let frameSize: CGSize
}
