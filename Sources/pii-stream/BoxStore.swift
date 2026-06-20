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
}

final class FrameStore {
    private let lock = NSLock()
    private var samples: [FrameSample] = []
    private let maxSamples = 240

    @discardableResult
    func update(_ buffer: CVPixelBuffer) -> FrameSample {
        lock.lock()
        defer { lock.unlock() }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let sample = FrameSample(
            pixelBuffer: buffer,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            frameSize: frameSize
        )
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
        return samples.last(where: { $0.capturedAt <= capturedAt }) ?? samples.first
    }
}
