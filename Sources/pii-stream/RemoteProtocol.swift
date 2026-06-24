import CoreGraphics
import CoreVideo
import Foundation

struct RemoteEnvelope: Codable {
    var token: String
    var config: FrameProcessingOptions?
    var frame: RemoteFrame?
}

struct RemoteFrame: Codable {
    var id: UInt64
    var capturedAt: TimeInterval
    var width: Int
    var height: Int
    var imageBase64: String
}

struct RemoteResponse: Codable {
    var frameID: UInt64
    var capturedAt: TimeInterval
    var processedAt: TimeInterval
    var guardMode: GuardMode
    var armed: Bool
    var blackoutWholeFrame: Bool
    var detections: [RemoteDetection]
    var imageBase64: String?
    var error: String?
}

struct RemoteDetection: Codable {
    var kind: PIIKind
    var confidence: Float
    var matchedLength: Int
    var rect: RemoteRect
    var detectedAt: TimeInterval

    init(box: PIIBox) {
        kind = box.kind
        confidence = box.confidence
        matchedLength = box.matched.count
        rect = RemoteRect(box.normalizedRect)
        detectedAt = box.detectedAt
    }

    var box: PIIBox {
        let safeMatchedLength = max(0, min(matchedLength, 10_000))
        return PIIBox(
            kind: kind,
            matched: String(repeating: "*", count: safeMatchedLength),
            confidence: confidence,
            normalizedRect: rect.cgRect,
            detectedAt: detectedAt
        )
    }
}

struct RemoteRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
