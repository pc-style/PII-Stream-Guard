import CoreGraphics
import CoreVideo
import Foundation

public enum PIIKind: String, Codable, Sendable {
    case email
    case phone
    case needle
}

/// Which subsystem produced a detection. OCR boxes come from Vision on
/// sampled frames; accessibility boxes come from the AX tree of visible apps.
public enum PIIDetectionSource: String, Codable, Hashable, Sendable {
    case ocr
    case accessibility
}

public struct PIIBox: Codable, Sendable {
    public let kind: PIIKind
    public let matched: String
    public let confidence: Float
    public let normalizedRect: CGRect
    public let detectedAt: TimeInterval
    public let source: PIIDetectionSource

    public init(
        kind: PIIKind,
        matched: String,
        confidence: Float,
        normalizedRect: CGRect,
        detectedAt: TimeInterval,
        source: PIIDetectionSource = .ocr
    ) {
        self.kind = kind
        self.matched = matched
        self.confidence = confidence
        self.normalizedRect = normalizedRect
        self.detectedAt = detectedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case kind, matched, confidence, normalizedRect, detectedAt, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(PIIKind.self, forKey: .kind)
        matched = try container.decode(String.self, forKey: .matched)
        confidence = try container.decode(Float.self, forKey: .confidence)
        normalizedRect = try container.decode(CGRect.self, forKey: .normalizedRect)
        detectedAt = try container.decode(TimeInterval.self, forKey: .detectedAt)
        source = try container.decodeIfPresent(PIIDetectionSource.self, forKey: .source) ?? .ocr
    }

    public var identityKey: String {
        "\(kind.rawValue):\(Self.normalizedMatch(kind: kind, matched: matched))"
    }

    public static func normalizedMatch(kind: PIIKind, matched: String) -> String {
        switch kind {
        case .email, .needle:
            return matched.lowercased().filter { !$0.isWhitespace }
        case .phone:
            let digits = matched.filter(\.isNumber)
            let hasLeadingPlus = matched.first { !$0.isWhitespace } == "+"
            return hasLeadingPlus ? "+\(digits)" : digits
        }
    }
}

/// Freshness of each detection source at the moment a snapshot was produced.
/// `nil` means the source has never delivered a result (disabled or not yet run).
struct DetectionFreshness {
    let lastOCRAt: TimeInterval?
    let lastAccessibilityAt: TimeInterval?

    static let none = DetectionFreshness(lastOCRAt: nil, lastAccessibilityAt: nil)

    func ocrAge(at now: TimeInterval) -> TimeInterval? {
        lastOCRAt.map { now - $0 }
    }

    func accessibilityAge(at now: TimeInterval) -> TimeInterval? {
        lastAccessibilityAt.map { now - $0 }
    }
}

struct DetectionSnapshot {
    let frameID: UInt64
    let boxes: [PIIBox]
    let frameSize: CGSize
    let capturedAt: TimeInterval
    let guardMode: GuardMode
    let armed: Bool
    let blackoutWholeFrame: Bool
    let freshness: DetectionFreshness

    init(
        frameID: UInt64,
        boxes: [PIIBox],
        frameSize: CGSize,
        capturedAt: TimeInterval,
        guardMode: GuardMode,
        armed: Bool,
        blackoutWholeFrame: Bool,
        freshness: DetectionFreshness = .none
    ) {
        self.frameID = frameID
        self.boxes = boxes
        self.frameSize = frameSize
        self.capturedAt = capturedAt
        self.guardMode = guardMode
        self.armed = armed
        self.blackoutWholeFrame = blackoutWholeFrame
        self.freshness = freshness
    }

    static let empty = DetectionSnapshot(
        frameID: 0,
        boxes: [],
        frameSize: .zero,
        capturedAt: 0,
        guardMode: .standard,
        armed: false,
        blackoutWholeFrame: false
    )
}

struct FrameSample {
    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    let capturedAt: TimeInterval
    let frameSize: CGSize
}
