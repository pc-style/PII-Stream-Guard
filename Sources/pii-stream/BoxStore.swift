import CoreGraphics
import CoreVideo
import Foundation

final class BoxStore {
    private let lock = NSLock()
    private var snapshots: [DetectionSnapshot] = []
    private let maxSnapshots = 240

    func update(_ snapshot: DetectionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    func current() -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last ?? .empty
    }

    func snapshot(atOrBefore capturedAt: TimeInterval) -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last(where: { $0.capturedAt <= capturedAt }) ?? .empty
    }

    func snapshot(for sample: FrameSample, maxAge: TimeInterval) -> DetectionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots.last(where: { $0.frameID <= sample.id && $0.capturedAt <= sample.capturedAt }),
              sample.capturedAt - snapshot.capturedAt <= maxAge else {
            return nil
        }
        return snapshot
    }

    func aggregate(from start: TimeInterval, through end: TimeInterval, fallbackAt capturedAt: TimeInterval) -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard !snapshots.isEmpty else {
            return .empty
        }

        let own = snapshots.last(where: { $0.capturedAt <= capturedAt }) ?? snapshots[0]
        let window = snapshots.filter { snapshot in
            snapshot.capturedAt >= start && snapshot.capturedAt <= end
        }
        let boxes = window.flatMap(\.boxes)
        let blackoutWholeFrame = window.contains { $0.blackoutWholeFrame }
        let armed = blackoutWholeFrame || window.contains { $0.armed } || !boxes.isEmpty

        return DetectionSnapshot(
            frameID: own.frameID,
            boxes: boxes,
            frameSize: own.frameSize,
            capturedAt: own.capturedAt,
            guardMode: own.guardMode,
            armed: armed,
            blackoutWholeFrame: blackoutWholeFrame
        )
    }
}

final class FrameStore {
    private let lock = NSLock()
    private var samples: [FrameSample] = []
    private let maxSamples = 240
    private var nextFrameID: UInt64 = 1

    @discardableResult
    func update(_ buffer: CVPixelBuffer) -> FrameSample {
        lock.lock()
        defer { lock.unlock() }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let sample = FrameSample(
            id: nextFrameID,
            pixelBuffer: buffer,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            frameSize: frameSize
        )
        nextFrameID &+= 1
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        return sample
    }

    func current() -> (buffer: CVPixelBuffer?, capturedAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = samples.last else { return (nil, 0) }
        return (sample.pixelBuffer, sample.capturedAt)
    }

    func currentSample() -> FrameSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples.last
    }

    func sample(atOrBefore capturedAt: TimeInterval) -> FrameSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples.last(where: { $0.capturedAt <= capturedAt })
    }
}
