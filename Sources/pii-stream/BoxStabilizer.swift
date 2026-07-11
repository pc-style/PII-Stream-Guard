import CoreGraphics
import Foundation

final class BoxStabilizer {
    private struct Track {
        let id: UInt64
        var identityKey: String
        var kind: PIIKind
        var box: PIIBox
        var lastSeen: TimeInterval
    }

    private var tracks: [Track] = []
    private var nextID: UInt64 = 1
    private let holdDuration: TimeInterval
    private let identityIoUThreshold: CGFloat
    private let fallbackIoUThreshold: CGFloat
    private let currentWeight: CGFloat
    private let safetyPadding: CGFloat
    private let maxIdentityCenterDistance: CGFloat
    private let snapCenterDistance: CGFloat

    init(
        holdDuration: TimeInterval = 0.14,
        identityIoUThreshold: CGFloat = 0.08,
        fallbackIoUThreshold: CGFloat = 0.25,
        currentWeight: CGFloat = 0.85,
        safetyPadding: CGFloat = 0.003,
        maxIdentityCenterDistance: CGFloat = 0.35,
        snapCenterDistance: CGFloat = 0.025
    ) {
        self.holdDuration = holdDuration
        self.identityIoUThreshold = identityIoUThreshold
        self.fallbackIoUThreshold = fallbackIoUThreshold
        self.currentWeight = currentWeight
        self.safetyPadding = safetyPadding
        self.maxIdentityCenterDistance = maxIdentityCenterDistance
        self.snapCenterDistance = snapCenterDistance
    }

    func reset() {
        tracks = []
        nextID = 1
    }

    func stabilize(_ boxes: [PIIBox], at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [PIIBox] {
        tracks.removeAll { now - $0.lastSeen > holdDuration }

        var usedTrackIDs = Set<UInt64>()

        for box in boxes {
            if let idx = bestMatch(for: box, usedTrackIDs: usedTrackIDs) {
                var track = tracks[idx]
                track.identityKey = box.identityKey
                track.kind = box.kind
                track.box = smoothedBox(previous: track.box, current: box)
                track.lastSeen = now
                tracks[idx] = track
                usedTrackIDs.insert(track.id)
            } else {
                let track = Track(
                    id: nextID,
                    identityKey: box.identityKey,
                    kind: box.kind,
                    box: paddedBox(box),
                    lastSeen: now
                )
                nextID &+= 1
                tracks.append(track)
                usedTrackIDs.insert(track.id)
            }
        }

        tracks.removeAll { now - $0.lastSeen > holdDuration }
        return tracks.sorted { lhs, rhs in
            if lhs.lastSeen == rhs.lastSeen {
                return lhs.id < rhs.id
            }
            return lhs.lastSeen > rhs.lastSeen
        }.map(\.box)
    }

    private func bestMatch(for box: PIIBox, usedTrackIDs: Set<UInt64>) -> Int? {
        if let identityMatch = bestMatch(
            for: box,
            usedTrackIDs: usedTrackIDs,
            minimumIoU: identityIoUThreshold,
            predicate: { $0.identityKey == box.identityKey }
        ) {
            return identityMatch
        }

        if let movingIdentityMatch = bestMovingIdentityMatch(for: box, usedTrackIDs: usedTrackIDs) {
            return movingIdentityMatch
        }

        return bestMatch(
            for: box,
            usedTrackIDs: usedTrackIDs,
            minimumIoU: fallbackIoUThreshold,
            predicate: { $0.kind == box.kind }
        )
    }

    private func bestMatch(
        for box: PIIBox,
        usedTrackIDs: Set<UInt64>,
        minimumIoU: CGFloat,
        predicate: (Track) -> Bool
    ) -> Int? {
        var bestIndex: Int?
        var bestScore: CGFloat = 0

        for idx in tracks.indices {
            let track = tracks[idx]
            guard !usedTrackIDs.contains(track.id), predicate(track) else { continue }
            let score = iou(track.box.normalizedRect, box.normalizedRect)
            guard score >= minimumIoU, score > bestScore else { continue }
            bestScore = score
            bestIndex = idx
        }

        return bestIndex
    }

    private func bestMovingIdentityMatch(for box: PIIBox, usedTrackIDs: Set<UInt64>) -> Int? {
        let maximumDistanceSquared = maxIdentityCenterDistance * maxIdentityCenterDistance
        var bestIndex: Int?
        var bestDistanceSquared = maximumDistanceSquared

        for idx in tracks.indices {
            let track = tracks[idx]
            guard !usedTrackIDs.contains(track.id), track.identityKey == box.identityKey else { continue }
            let distanceSquared = centerDistanceSquared(track.box.normalizedRect, box.normalizedRect)
            guard distanceSquared <= maximumDistanceSquared,
                  bestIndex == nil || distanceSquared < bestDistanceSquared else { continue }
            bestDistanceSquared = distanceSquared
            bestIndex = idx
        }
        return bestIndex
    }

    private func smoothedBox(previous: PIIBox, current: PIIBox) -> PIIBox {
        if iou(previous.normalizedRect, current.normalizedRect) < identityIoUThreshold,
           centerDistanceSquared(previous.normalizedRect, current.normalizedRect)
               > snapCenterDistance * snapCenterDistance {
            return paddedBox(current)
        }

        let blended = blend(previous.normalizedRect, current.normalizedRect, currentWeight: currentWeight)
        let safeRect = clamped(current.normalizedRect.union(blended).insetBy(dx: -safetyPadding, dy: -safetyPadding))
        return PIIBox(
            kind: current.kind,
            matched: current.matched,
            confidence: max(previous.confidence, current.confidence),
            normalizedRect: safeRect,
            detectedAt: current.detectedAt,
            source: current.source
        )
    }

    private func paddedBox(_ box: PIIBox) -> PIIBox {
        PIIBox(
            kind: box.kind,
            matched: box.matched,
            confidence: box.confidence,
            normalizedRect: clamped(box.normalizedRect.insetBy(dx: -safetyPadding, dy: -safetyPadding)),
            detectedAt: box.detectedAt,
            source: box.source
        )
    }

    private func blend(_ previous: CGRect, _ current: CGRect, currentWeight: CGFloat) -> CGRect {
        let previousWeight = 1 - currentWeight
        return CGRect(
            x: previous.origin.x * previousWeight + current.origin.x * currentWeight,
            y: previous.origin.y * previousWeight + current.origin.y * currentWeight,
            width: previous.width * previousWeight + current.width * currentWeight,
            height: previous.height * previousWeight + current.height * currentWeight
        )
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        let minX = max(0, rect.minX)
        let minY = max(0, rect.minY)
        let maxX = min(1, rect.maxX)
        let maxY = min(1, rect.maxY)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func centerDistanceSquared(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
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
