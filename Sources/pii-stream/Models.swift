import CoreGraphics
import CoreVideo
import Foundation

public enum PIIKind: String, Codable {
    case email
    case phone
    case needle
}

public struct PIIBox: Codable {
    public let kind: PIIKind
    public let matched: String
    public let confidence: Float
    public let normalizedRect: CGRect
    public let detectedAt: TimeInterval

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

struct DetectionSnapshot {
    let frameID: UInt64
    let boxes: [PIIBox]
    let frameSize: CGSize
    let capturedAt: TimeInterval
    let guardMode: GuardMode
    let armed: Bool
    let blackoutWholeFrame: Bool

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
