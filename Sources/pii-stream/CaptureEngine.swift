import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - Capture settings

/// Output resolution cap. Capture is performed at native pixel resolution and
/// only downscaled (never upscaled) to fit the cap, preserving aspect ratio.
/// Ported from Wrec's capture engine.
public enum CaptureResolution: String, CaseIterable {
    case native
    case r720p = "720p"
    case r1080p = "1080p"
    case r2k = "2k"
    case r4k = "4k"

    var maxSize: (width: Int, height: Int)? {
        switch self {
        case .native: return nil
        case .r720p: return (1280, 720)
        case .r1080p: return (1920, 1080)
        case .r2k: return (2560, 1440)
        case .r4k: return (3840, 2160)
        }
    }
}

/// What to capture: the main display, a specific display, or a single window.
public enum CaptureTargetSelector: Equatable {
    case mainDisplay
    case display(CGDirectDisplayID)
    case window(CGWindowID)

    var kindDescription: String {
        switch self {
        case .mainDisplay, .display: return "display"
        case .window: return "window"
        }
    }
}

public struct CaptureOptions: Equatable {
    var target: CaptureTargetSelector = .mainDisplay
    var captureFPS: Int = 60
    var showsCursor: Bool = true
    var capturesAudio: Bool = false
    var hideOwnApp: Bool = true
    var resolution: CaptureResolution = .native
}

/// Resolved geometry of the running capture, needed to map global-screen
/// coordinates (accessibility) into normalized frame coordinates.
struct CaptureGeometry {
    /// Captured region in global display space (points, top-left origin).
    let globalRect: CGRect
    /// Output pixel size of delivered frames.
    let outputSize: CGSize
    let targetDescription: String
}

// MARK: - Target listing

public struct CaptureTargetInfo {
    public let kind: String // "display" | "window"
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
}

public enum CaptureTargetCatalog {
    /// Enumerates capturable displays and windows, skipping the current
    /// process's own windows and tiny (<64pt) windows.
    public static func list() async throws -> [CaptureTargetInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var targets: [CaptureTargetInfo] = []
        for display in content.displays {
            let isMain = display.displayID == CGMainDisplayID()
            targets.append(CaptureTargetInfo(
                kind: "display",
                id: display.displayID,
                name: "Display \(display.displayID)\(isMain ? " (main)" : "")",
                width: display.width,
                height: display.height
            ))
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for window in content.windows {
            guard window.owningApplication?.processID != currentPID else { continue }
            guard window.frame.width >= 64, window.frame.height >= 64 else { continue }
            let appName = window.owningApplication?.applicationName ?? "App"
            let title = window.title ?? "Window"
            targets.append(CaptureTargetInfo(
                kind: "window",
                id: window.windowID,
                name: "\(appName) — \(title)",
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            ))
        }
        return targets
    }
}

// MARK: - Capture engine

/// ScreenCaptureKit capture engine, architecture ported from Wrec
/// (github.com/shivamhwp/wrec, MIT): native-resolution sizing from
/// contentRect x pointPixelScale, even output dimensions, downscale-only
/// resolution caps, bounded queue depth, frame-status gating, and
/// drop-instead-of-buffer backpressure. Deviates from Wrec by capturing BGRA
/// instead of NV12 because frames feed Vision OCR and CoreImage mask
/// rendering before any encoder.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let frameStore: FrameStore
    private let options: CaptureOptions
    private let onFrame: ((FrameSample) -> Void)?
    private let onAudio: ((CMSampleBuffer) -> Void)?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "pii-stream.capture", qos: .userInitiated)
    private(set) var geometry: CaptureGeometry?
    private(set) var droppedFrameCount = 0

    init(
        frameStore: FrameStore,
        options: CaptureOptions,
        onFrame: ((FrameSample) -> Void)? = nil,
        onAudio: ((CMSampleBuffer) -> Void)? = nil
    ) {
        self.frameStore = frameStore
        self.options = options
        self.onFrame = onFrame
        self.onAudio = onAudio
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let globalRect: CGRect
        let fallbackWidth: Int
        let fallbackHeight: Int
        let targetDescription: String

        switch options.target {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowNotFound(windowID)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            globalRect = window.frame
            fallbackWidth = Int(window.frame.width)
            fallbackHeight = Int(window.frame.height)
            let appName = window.owningApplication?.applicationName ?? "App"
            targetDescription = "window \(windowID) (\(appName) — \(window.title ?? "Window"))"

        case .mainDisplay, .display:
            let wantedID: CGDirectDisplayID
            if case .display(let id) = options.target {
                wantedID = id
            } else {
                wantedID = CGMainDisplayID()
            }
            guard let display = content.displays.first(where: { $0.displayID == wantedID })
                ?? (options.target == .mainDisplay ? content.displays.first : nil) else {
                throw CaptureError.displayNotFound(wantedID)
            }
            let excludedApplications: [SCRunningApplication]
            if options.hideOwnApp {
                let currentPID = ProcessInfo.processInfo.processIdentifier
                let currentBundleIdentifier = Bundle.main.bundleIdentifier
                excludedApplications = content.applications.filter { application in
                    application.processID == currentPID
                        || (currentBundleIdentifier != nil && application.bundleIdentifier == currentBundleIdentifier)
                }
            } else {
                excludedApplications = []
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            globalRect = CGDisplayBounds(display.displayID)
            fallbackWidth = display.width
            fallbackHeight = display.height
            targetDescription = "display \(display.displayID)"
        }

        let native = Self.nativeCaptureSize(filter: filter, fallbackWidth: fallbackWidth, fallbackHeight: fallbackHeight)
        let output = Self.outputSize(nativeWidth: native.width, nativeHeight: native.height, resolution: options.resolution)

        let config = SCStreamConfiguration()
        config.width = output.width
        config.height = output.height
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.captureFPS)))
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.capturesAudio
        if options.capturesAudio {
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if options.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        geometry = CaptureGeometry(
            globalRect: globalRect,
            outputSize: CGSize(width: output.width, height: output.height),
            targetDescription: targetDescription
        )

        fputs(
            "Capture started: \(targetDescription) at \(output.width)×\(output.height) "
                + "(native \(native.width)×\(native.height)), \(options.captureFPS) fps"
                + "\(options.capturesAudio ? ", audio" : "")"
                + "\(options.showsCursor ? "" : ", cursor hidden"). "
                + "Grant Screen Recording in System Settings if no frames appear.\n",
            stderr
        )
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Capture stream stopped: \(error.localizedDescription)\n", stderr)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              Self.frameStatus(sampleBuffer) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            droppedFrameCount += 1
            return
        }
        // CVPixelBuffer is reference-counted. Retaining it in FrameStore keeps the
        // ScreenCaptureKit surface alive, so copying every pixel of every frame is
        // unnecessary (and particularly costly for 4K/60 capture).
        let sample = frameStore.update(buffer)
        onFrame?(sample)
    }

    // MARK: Sizing (ported from Wrec)

    static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped - (clamped % 2)
    }

    static func nativeCaptureSize(filter: SCContentFilter, fallbackWidth: Int, fallbackHeight: Int) -> (width: Int, height: Int) {
        let scale = CGFloat(filter.pointPixelScale)
        let width = evenDimension(Int((filter.contentRect.width * scale).rounded()))
        let height = evenDimension(Int((filter.contentRect.height * scale).rounded()))
        if width > 2 && height > 2 {
            return (width, height)
        }
        return (evenDimension(fallbackWidth), evenDimension(fallbackHeight))
    }

    static func outputSize(nativeWidth: Int, nativeHeight: Int, resolution: CaptureResolution) -> (width: Int, height: Int) {
        guard let maxSize = resolution.maxSize else {
            return (evenDimension(nativeWidth), evenDimension(nativeHeight))
        }
        let scale = min(
            1.0,
            Double(maxSize.width) / Double(nativeWidth),
            Double(maxSize.height) / Double(nativeHeight)
        )
        return (
            evenDimension(Int((Double(nativeWidth) * scale).rounded())),
            evenDimension(Int((Double(nativeHeight) * scale).rounded()))
        )
    }

    static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return .complete
        }
        return status
    }
}

enum CaptureError: Error, LocalizedError {
    case noDisplay
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available for screen capture."
        case .displayNotFound(let id):
            return "Display \(id) not found. Run `pii-stream targets` to list capturable targets."
        case .windowNotFound(let id):
            return "Window \(id) not found or no longer on screen. Run `pii-stream targets` to list capturable targets."
        }
    }
}
