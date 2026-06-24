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
        let safeConfidence = confidence.isFinite ? max(0, min(confidence, 1)) : 0
        let safeRect = rect.sanitizedNormalizedRect
        return PIIBox(
            kind: kind,
            matched: String(repeating: "*", count: safeMatchedLength),
            confidence: safeConfidence,
            normalizedRect: safeRect,
            detectedAt: detectedAt.isFinite ? detectedAt : 0
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
        sanitizedNormalizedRect
    }

    var sanitizedNormalizedRect: CGRect {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return .zero }
        let minX = min(x, x + width)
        let maxX = max(x, x + width)
        let minY = min(y, y + height)
        let maxY = max(y, y + height)
        let clampedMinX = max(0, min(minX, 1))
        let clampedMaxX = max(0, min(maxX, 1))
        let clampedMinY = max(0, min(minY, 1))
        let clampedMaxY = max(0, min(maxY, 1))
        let clampedWidth = clampedMaxX - clampedMinX
        let clampedHeight = clampedMaxY - clampedMinY
        guard clampedWidth > 0, clampedHeight > 0 else { return .zero }
        return CGRect(x: clampedMinX, y: clampedMinY, width: clampedWidth, height: clampedHeight)
    }
}
