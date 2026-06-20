import CoreGraphics
import Foundation

enum GuardMode: String, CaseIterable {
    case paranoid
    case safe
    case balanced
    case fast
    case expLow = "exp-low"
    case expHigh = "exp-high"

    var title: String {
        switch self {
        case .paranoid: return "Paranoid"
        case .safe: return "Safe"
        case .balanced: return "Balanced"
        case .fast: return "Fast but faulty"
        case .expLow: return "Exp Low"
        case .expHigh: return "Exp High"
        }
    }

    var renderDelay: TimeInterval {
        switch self {
        case .paranoid: return 3.00
        case .safe: return 2.50
        case .balanced: return 0.75
        case .fast: return 0
        case .expLow: return 0.75
        case .expHigh: return 0.75
        }
    }

    var experimentalTraceBackDuration: TimeInterval {
        switch self {
        case .expLow, .expHigh:
            return renderDelay + (5.0 / 60.0)
        case .paranoid, .safe, .balanced, .fast:
            return 0
        }
    }

    var detectorSettings: DetectorSettings {
        switch self {
        case .paranoid:
            return DetectorSettings(
                accurate: false,
                maxPixelSize: 1920,
                minimumTextHeight: 0.006,
                enhanceLowContrast: true
            )
        case .safe:
            return DetectorSettings(
                accurate: true,
                maxPixelSize: 2560,
                minimumTextHeight: 0.004,
                enhanceLowContrast: true
            )
        case .balanced:
            return DetectorSettings(
                accurate: false,
                maxPixelSize: 1920,
                minimumTextHeight: 0.006,
                enhanceLowContrast: true
            )
        case .fast:
            return DetectorSettings(
                accurate: false,
                maxPixelSize: 1440,
                minimumTextHeight: 0.012,
                enhanceLowContrast: false
            )
        case .expLow:
            return GuardMode.balanced.detectorSettings
        case .expHigh:
            return GuardMode.safe.detectorSettings
        }
    }

    var detectionFPS: Double {
        switch self {
        case .paranoid: return 8
        case .safe: return 5
        case .balanced: return 12
        case .fast: return 12
        case .expLow: return 12
        case .expHigh: return 8
        }
    }

    var detectsEveryFrame: Bool {
        detectionFPS <= 0
    }

    var armingTTL: TimeInterval {
        switch self {
        case .fast:
            return 0.45
        case .balanced:
            return renderDelay + 0.35
        case .safe:
            return renderDelay + 0.50
        case .paranoid:
            return renderDelay + 0.75
        case .expLow, .expHigh:
            return renderDelay + 0.50
        }
    }

    var maxSnapshotAge: TimeInterval {
        max(renderDelay + 0.35, armingTTL)
    }

    var maxDetectionInputAge: TimeInterval {
        max(renderDelay + 0.25, 0.50)
    }
}

enum MaskMode: String {
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
        case .paranoid:
            return ingestParanoid(boxes, at: now)
        case .safe:
            return ingestSafe(boxes, at: now)
        case .balanced:
            return ingestBalanced(boxes, at: now)
        case .fast:
            return ingestFast(boxes, at: now)
        case .expLow, .expHigh:
            return ingestExperimental(boxes, at: now)
        }
    }

    private func ingestParanoid(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            if shouldDisarm(at: now, missLimit: 25) {
                disarm()
            }
        } else {
            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func ingestSafe(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            if shouldDisarm(at: now, missLimit: 25) {
                disarm()
            }
        } else {
            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func ingestBalanced(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            consecutiveSimilarDetections = 0
            if shouldDisarm(at: now, missLimit: 15) {
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

    private func ingestFast(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        if boxes.isEmpty {
            misses += 1
            if shouldDisarm(at: now, missLimit: 3) {
                disarm()
            }
        } else {
            arm(with: boxes, at: now)
        }
        return snapshot()
    }

    private func ingestExperimental(_ boxes: [PIIBox], at now: TimeInterval) -> GuardStateSnapshot {
        misses = boxes.isEmpty ? misses + 1 : 0
        if boxes.isEmpty {
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
            blackoutWholeFrame: isArmed && mode == .paranoid
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
