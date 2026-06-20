import CoreGraphics
import CoreVideo
import Foundation

final class BoxStore {
    private let lock = NSLock()
    private var boxes: [PIIBox] = []
    private var frameSize: CGSize = .zero

    func update(_ boxes: [PIIBox], frameSize: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        self.boxes = boxes
        self.frameSize = frameSize
    }

    func current() -> DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DetectionSnapshot(boxes: boxes, frameSize: frameSize)
    }
}

final class FrameStore {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?
    private var capturedAt: TimeInterval = 0

    func update(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        pixelBuffer = buffer
        capturedAt = ProcessInfo.processInfo.systemUptime
    }

    func current() -> (buffer: CVPixelBuffer?, capturedAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (pixelBuffer, capturedAt)
    }
}
