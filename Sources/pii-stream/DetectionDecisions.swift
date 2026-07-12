import CoreGraphics
import Foundation

public enum DetectionMode: String, Codable, Sendable, CaseIterable {
    case hybrid
    case accessibilityOnly = "accessibility"
    case ocrOnly = "ocr"
}

extension DetectionMode {
    var title: String {
        switch self {
        case .hybrid: "Hybrid"
        case .accessibilityOnly: "Accessibility"
        case .ocrOnly: "OCR"
        }
    }
}

extension CoverageState {
    var eventValue: String {
        switch self {
        case .verified: "verified"
        case .partial: "partial"
        case .unknown: "unknown"
        case .stale: "stale"
        case .unavailable: "unavailable"
        }
    }
}

enum CoverageState: Equatable, Sendable {
    case verified
    case partial(reason: String)
    case unknown(reason: String)
    case stale
    case unavailable(reason: String)

    var permitsClearDecision: Bool {
        self == .verified
    }
}

struct DetectionBatch: Sendable {
    let source: PIIDetectionSource
    let observedAt: TimeInterval
    let effectiveFrom: TimeInterval
    let coverage: CoverageState
    let findings: [PIIBox]
}

enum BlackoutReason: String, Equatable, Sendable {
    case finding
    case incompleteCoverage
    case clearHysteresis
    case missingDecision
    case staleDecision
}

struct ProtectionDecision: Sendable {
    enum Action: Sendable {
        case clear
        case mask([CGRect])
        case blackout(BlackoutReason)
    }

    let effectiveFrom: TimeInterval
    let effectiveUntil: TimeInterval?
    let action: Action
    let sources: Set<PIIDetectionSource>
    let coverage: CoverageState
    let createdAt: TimeInterval
}

extension ProtectionDecision.Action: Equatable {
    static func == (lhs: ProtectionDecision.Action, rhs: ProtectionDecision.Action) -> Bool {
        switch (lhs, rhs) {
        case (.clear, .clear):
            return true
        case let (.mask(lhsRects), .mask(rhsRects)):
            return lhsRects == rhsRects
        case let (.blackout(lhsReason), .blackout(rhsReason)):
            return lhsReason == rhsReason
        default:
            return false
        }
    }
}

/// Stores source decisions by the time they became valid, rather than the time
/// they arrived. This lets a late AX result protect frames that are still in
/// the delayed buffer.
final class DecisionTimelineStore {
    private let lock = NSLock()
    private var decisions: [ProtectionDecision] = []
    private let maxDecisions: Int
    private let requiredSources: Set<PIIDetectionSource>

    init(
        maxDecisions: Int = 512,
        requiredSources: Set<PIIDetectionSource> = [.ocr]
    ) {
        self.maxDecisions = max(1, maxDecisions)
        self.requiredSources = requiredSources
    }

    func insert(_ decision: ProtectionDecision) {
        lock.lock()
        defer { lock.unlock() }

        insertLocked(decision)
    }

    /// Replaces retained decisions for the affected sources from the supplied
    /// cutoff. This is used for failures discovered after frames entered the
    /// delay buffer, where an older positive decision must no longer win.
    func replaceSourceHistory(with decision: ProtectionDecision) {
        lock.lock()
        defer { lock.unlock() }

        decisions.removeAll {
            $0.effectiveFrom >= decision.effectiveFrom
                && !$0.sources.isDisjoint(with: decision.sources)
        }
        insertLocked(decision)
    }

    private func insertLocked(_ decision: ProtectionDecision) {
        decisions.append(decision)
        decisions.sort {
            if $0.effectiveFrom == $1.effectiveFrom {
                return $0.createdAt < $1.createdAt
            }
            return $0.effectiveFrom < $1.effectiveFrom
        }
        if decisions.count > maxDecisions {
            decisions.removeFirst(decisions.count - maxDecisions)
        }
    }

    func decision(at timestamp: TimeInterval, maxAge: TimeInterval) -> ProtectionDecision? {
        lock.lock()
        defer { lock.unlock() }

        let candidates = latestDecisionPerSource(at: timestamp).filter {
            timestamp - $0.effectiveFrom <= maxAge
        }
        let freshSources = Set(candidates.flatMap(\.sources))
        let missingSources = requiredSources.subtracting(freshSources)
        if !missingSources.isEmpty {
            return incompleteCoverageDecision(at: timestamp, sources: missingSources)
        }

        let requiredDecisions = candidates.filter { !$0.sources.isDisjoint(with: requiredSources) }
        if requiredDecisions.contains(where: { !$0.coverage.permitsClearDecision }) {
            return incompleteCoverageDecision(at: timestamp, sources: requiredSources)
        }

        guard !candidates.isEmpty else { return nil }

        return candidates.max { lhs, rhs in
            let lhsStrength = Self.strength(of: lhs.action)
            let rhsStrength = Self.strength(of: rhs.action)
            if lhsStrength == rhsStrength {
                return lhs.createdAt < rhs.createdAt
            }
            return lhsStrength < rhsStrength
        }
    }

    func prune(before cutoff: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        decisions.removeAll {
            ($0.effectiveUntil ?? $0.effectiveFrom) < cutoff
        }
    }

    private func latestDecisionPerSource(at timestamp: TimeInterval) -> [ProtectionDecision] {
        var latest: [PIIDetectionSource: ProtectionDecision] = [:]
        for decision in decisions where decision.effectiveFrom <= timestamp {
            guard decision.effectiveUntil.map({ timestamp < $0 }) ?? true else { continue }
            for source in decision.sources {
                if let current = latest[source] {
                    if decision.effectiveFrom > current.effectiveFrom
                        || (decision.effectiveFrom == current.effectiveFrom && decision.createdAt > current.createdAt) {
                        latest[source] = decision
                    }
                } else {
                    latest[source] = decision
                }
            }
        }
        return Array(latest.values)
    }

    private static func strength(of action: ProtectionDecision.Action) -> Int {
        switch action {
        case .clear: return 0
        case .mask: return 1
        case .blackout: return 2
        }
    }

    private func incompleteCoverageDecision(
        at timestamp: TimeInterval,
        sources: Set<PIIDetectionSource>
    ) -> ProtectionDecision {
        ProtectionDecision(
            effectiveFrom: timestamp,
            effectiveUntil: nil,
            action: .blackout(.incompleteCoverage),
            sources: sources,
            coverage: .unknown(reason: "required detection coverage is missing or stale"),
            createdAt: timestamp
        )
    }
}

/// Converts independent source batches into conservative output decisions.
/// A source must publish two consecutive verified empty batches before it can
/// clear its own blackout decision.
final class DetectionCoordinator {
    private let timeline: DecisionTimelineStore
    private let clearBatchThreshold: Int
    private let lock = NSLock()
    private var consecutiveClearBatches: [PIIDetectionSource: Int] = [:]

    init(timeline: DecisionTimelineStore, clearBatchThreshold: Int = 2) {
        self.timeline = timeline
        self.clearBatchThreshold = max(1, clearBatchThreshold)
    }

    @discardableResult
    func ingest(_ batch: DetectionBatch) -> ProtectionDecision {
        lock.lock()
        defer { lock.unlock() }

        let action: ProtectionDecision.Action
        if !batch.findings.isEmpty {
            consecutiveClearBatches[batch.source] = 0
            action = .blackout(.finding)
        } else if !batch.coverage.permitsClearDecision {
            consecutiveClearBatches[batch.source] = 0
            action = .blackout(.incompleteCoverage)
        } else {
            let count = (consecutiveClearBatches[batch.source] ?? 0) + 1
            consecutiveClearBatches[batch.source] = count
            action = count >= clearBatchThreshold ? .clear : .blackout(.clearHysteresis)
        }

        let decision = ProtectionDecision(
            effectiveFrom: batch.effectiveFrom,
            effectiveUntil: nil,
            action: action,
            sources: [batch.source],
            coverage: batch.coverage,
            createdAt: batch.observedAt
        )
        timeline.insert(decision)
        return decision
    }
}
