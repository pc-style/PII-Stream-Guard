import CoreGraphics
import CoreVideo
import Foundation

final class BoxStore {
    private let lock = NSLock()
    private var snapshots: [DetectionSnapshot] = []
    private let maxSnapshots = 240

    func update(_ boxes: [PIIBox], frameSize: CGSize, capturedAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(DetectionSnapshot(boxes: boxes, frameSize: frameSize, capturedAt: capturedAt))
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    func current() -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last ?? DetectionSnapshot(boxes: [], frameSize: .zero, capturedAt: 0)
    }

    func snapshot(atOrBefore capturedAt: TimeInterval) -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last(where: { $0.capturedAt <= capturedAt })
            ?? DetectionSnapshot(boxes: [], frameSize: .zero, capturedAt: capturedAt)
    }
}

final class FrameStore {
    private let lock = NSLock()
    private var samples: [FrameSample] = []
    private let maxSamples = 240

    func update(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        samples.append(FrameSample(
            pixelBuffer: buffer,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            frameSize: frameSize
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
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
