import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private let frameStore: FrameStore
    private let onFrame: ((FrameSample) -> Void)?
    private var stream: SCStream?

    init(frameStore: FrameStore, onFrame: ((FrameSample) -> Void)? = nil) {
        self.frameStore = frameStore
        self.onFrame = onFrame
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pii-stream.capture"))
        try await stream.startCapture()
        self.stream = stream

        fputs(
            "Screen capture started (\(display.width)×\(display.height)). "
                + "Grant Screen Recording in System Settings if no frames appear.\n",
            stderr
        )
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let copy = PixelBufferUtils.copy(buffer) else { return }
        let sample = frameStore.update(copy)
        onFrame?(sample)
    }
}

enum CaptureError: Error, LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available for screen capture."
        }
    }
}
