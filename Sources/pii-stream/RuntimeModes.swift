import CoreGraphics
import Foundation

enum GuardMode: String, CaseIterable, Codable {
    case lockdown
    case standard
    case lowLatency = "low-latency"

    var title: String {
        switch self {
        case .lockdown: return "Lockdown"
        case .standard: return "Standard"
        case .lowLatency: return "Low Latency"
        }
    }

    var renderDelay: TimeInterval {
        switch self {
        case .lockdown: return 0.35
        case .standard: return 0.12
        case .lowLatency: return 0.05
        }
    }

    var detectorSettings: DetectorSettings {
        switch self {
        case .lockdown:
            return DetectorSettings(
                accurate: true,
                maxPixelSize: 2560,
                minimumTextHeight: 0.004,
                enhanceLowContrast: true
            )
        case .standard:
            return DetectorSettings(
                accurate: false,
                maxPixelSize: 1920,
                minimumTextHeight: 0.006,
                enhanceLowContrast: true
            )
        case .lowLatency:
            return DetectorSettings(
                accurate: false,
                maxPixelSize: 1920,
                minimumTextHeight: 0.006,
                enhanceLowContrast: true
            )
        }
    }

    var detectionFPS: Double {
        switch self {
        case .lockdown: return 5
        case .standard: return 10
        case .lowLatency: return 30
        }
    }

    var detectsEveryFrame: Bool {
        detectionFPS <= 0
    }

    var armingTTL: TimeInterval {
        switch self {
        case .lockdown:
            return renderDelay + 0.35
        case .standard:
            return renderDelay + 0.20
        case .lowLatency:
            return renderDelay + 0.08
        }
    }

    var maxSnapshotAge: TimeInterval {
        switch self {
        case .lockdown: return renderDelay + 0.35
        case .standard: return renderDelay + 0.20
        case .lowLatency: return renderDelay + 0.08
        }
    }

    var maxDetectionInputAge: TimeInterval {
        switch self {
        case .lockdown: return 0.50
        case .standard: return 0.25
        case .lowLatency: return 0.12
        }
    }
}

enum MaskMode: String, Codable {
    case boundingBox
    case blackout
}

struct GuardStateSnapshot {
    let boxes: [PIIBox]
    let active: Bool
    let mode: GuardMode
    let blackoutWholeFrame: Bool
}

final class GuardStateMachine {
    private var mode: GuardMode
    private var isArmed = false
    private var armedBoxes: [PIIBox] = []
    private var previousDetectionBoxes: [PIIBox] = []
    private var consecutiveSimilarDetections = 0
    private var misses = 0
    private var armedUntil: TimeInterval = 0

    init(mode: GuardMode) {
        self.mode = mode
    }

    func setMode(_ mode: GuardMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        isArmed = false
        armedBoxes = []
        previousDetectionBoxes = []
        consecutiveSimilarDetections = 0
        misses = 0
        armedUntil = 0
    }

    func ingest(detected boxes: [PIIBox], at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> GuardStateSnapshot {
        switch mode {
        case .lockdown:
            return ingestLockdown(boxes, at: now)
        case .standard:
            return ingestStandard(boxes, at: now)
        case .lowLatency:
            return ingestLowLatency(boxes, at: now)
        }
    }

    private func ingestLockdown(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            if shouldDisarm(at: now, missLimit: 8) {
                disarm()
            }
        } else {
            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func ingestStandard(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            consecutiveSimilarDetections = 0
            if shouldDisarm(at: now, missLimit: 3) {
                disarm()
            }
        } else {
            misses = 0
            if boxesAreSimilar(boxes, previousDetectionBoxes) {
                consecutiveSimilarDetections += 1
            } else {
                consecutiveSimilarDetections = 1
            }
            previousDetectionBoxes = boxes

            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func ingestLowLatency(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            if shouldDisarm(at: now, missLimit: 2) {
                disarm()
            }
        } else {
            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func arm(with boxes: [PIIBox], at now: TimeInterval) {
        isArmed = true
        misses = 0
        armedBoxes = boxes
        armedUntil = now + mode.armingTTL
    }

    private func shouldDisarm(at now: TimeInterval, missLimit: Int) -> Bool {
        misses >= missLimit && now >= armedUntil
    }

    private func disarm() {
        isArmed = false
        armedBoxes = []
        previousDetectionBoxes = []
        consecutiveSimilarDetections = 0
        misses = 0
        armedUntil = 0
    }

    private func snapshot() -> GuardStateSnapshot {
        GuardStateSnapshot(
            boxes: isArmed ? armedBoxes : [],
            active: isArmed,
            mode: mode,
            blackoutWholeFrame: isArmed && mode == .lockdown
        )
    }

    private func boxesAreSimilar(_ lhs: [PIIBox], _ rhs: [PIIBox]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for left in lhs {
            for right in rhs where iou(left.normalizedRect, right.normalizedRect) >= 0.25 {
                return true
            }
        }
        return false
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}
