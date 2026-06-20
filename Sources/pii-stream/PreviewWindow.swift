import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class PreviewView: NSView {
    private let frameLayer = CALayer()
    private let overlayLayer = CALayer()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var boxes: [PIIBox] = []
    var frameSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        frameLayer.contentsGravity = .resizeAspect
        frameLayer.frame = bounds
        frameLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        overlayLayer.frame = bounds
        overlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // CALayer defaults to bottom-left origin; flip so Vision→view math (top-left) maps correctly.
        overlayLayer.isGeometryFlipped = true

        layer?.addSublayer(frameLayer)
        layer?.addSublayer(overlayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame(_ buffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.frameLayer.contents = cgImage
        }
    }

    func updateOverlay(boxes: [PIIBox], frameSize: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.boxes = boxes
            self.frameSize = frameSize
            self.redrawOverlay()
        }
    }

    private func redrawOverlay() {
        overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        guard frameSize.width > 0, frameSize.height > 0 else { return }

        let viewBounds = bounds
        let scale = min(viewBounds.width / frameSize.width, viewBounds.height / frameSize.height)
        let drawnWidth = frameSize.width * scale
        let drawnHeight = frameSize.height * scale
        let offsetX = (viewBounds.width - drawnWidth) / 2
        let offsetY = (viewBounds.height - drawnHeight) / 2

        for box in boxes {
            let rect = visionRectToView(box.normalizedRect, frameSize: frameSize)
            let scaled = CGRect(
                x: offsetX + rect.origin.x * scale,
                y: offsetY + rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )

            let boxLayer = CALayer()
            boxLayer.frame = scaled
            boxLayer.borderColor = NSColor.systemRed.cgColor
            boxLayer.borderWidth = 2
            boxLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
            overlayLayer.addSublayer(boxLayer)

            let label = CATextLayer()
            label.string = "\(box.kind.rawValue): \(box.matched)"
            label.fontSize = 11
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
            label.contentsScale = window?.backingScaleFactor ?? 2
            label.alignmentMode = .left
            label.frame = CGRect(x: scaled.minX, y: scaled.maxY + 2, width: min(320, viewBounds.width - scaled.minX), height: 16)
            overlayLayer.addSublayer(label)
        }
    }

    /// Vision normalized coords: origin bottom-left → view coords: origin top-left.
    private func visionRectToView(_ rect: CGRect, frameSize: CGSize) -> CGRect {
        let x = rect.origin.x * frameSize.width
        let y = (1 - rect.origin.y - rect.height) * frameSize.height
        let w = rect.width * frameSize.width
        let h = rect.height * frameSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

final class PreviewWindowController: NSWindowController {
    private let previewView: PreviewView
    private let frameStore: FrameStore
    private let boxStore: BoxStore

    init(frameStore: FrameStore, boxStore: BoxStore, windowSize: CGSize) {
        self.frameStore = frameStore
        self.boxStore = boxStore
        previewView = PreviewView(frame: NSRect(origin: .zero, size: windowSize))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PII-Stream Preview"
        window.contentView = previewView
        window.center()
        window.makeKeyAndOrderFront(nil)

        super.init(window: window)
        startDisplayLoop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLoop()
    }

    private func startDisplayLoop() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDisplayLoop() {}

    private func tick() {
        let (buffer, _) = frameStore.current()
        if let buffer {
            previewView.updateFrame(buffer)
        }
        let snapshot = boxStore.current()
        previewView.updateOverlay(boxes: snapshot.boxes, frameSize: snapshot.frameSize)
    }
}

final class AppCoordinator: NSObject, NSApplicationDelegate {
    let frameStore = FrameStore()
    let boxStore = BoxStore()
    let options: WatchOptions

    private var capture: ScreenCaptureManager?
    private var preview: PreviewWindowController?
    private let detectionQueue = DispatchQueue(label: "pii-stream.detection")
    private var detector: VisionPIIDetector
    private var lastDetectionTime: TimeInterval = 0
    private var lastLoggedSignature: String = ""

    init(options: WatchOptions) {
        self.options = options
        detector = VisionPIIDetector(
            needles: options.needles,
            checkEmail: options.checkEmail,
            accurate: options.settings.accurate,
            maxPixelSize: options.settings.maxPixelSize,
            minimumTextHeight: options.settings.minimumTextHeight
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        preview = PreviewWindowController(
            frameStore: frameStore,
            boxStore: boxStore,
            windowSize: CGSize(width: 1280, height: 800)
        )

        capture = ScreenCaptureManager(frameStore: frameStore) { [weak self] in
            self?.scheduleDetectionIfNeeded()
        }

        Task {
            do {
                try await capture?.start()
            } catch {
                fputs("Failed to start screen capture: \(error.localizedDescription)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func scheduleDetectionIfNeeded() {
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let interval = 1.0 / self.options.fps
            guard now - self.lastDetectionTime >= interval else { return }
            self.lastDetectionTime = now

            let (buffer, _) = self.frameStore.current()
            guard let buffer else { return }

            let width = CGFloat(CVPixelBufferGetWidth(buffer))
            let height = CGFloat(CVPixelBufferGetHeight(buffer))
            let frameSize = CGSize(width: width, height: height)

            let boxes = self.detector.detect(in: buffer)
            self.boxStore.update(boxes, frameSize: frameSize)
            self.logDetections(boxes)
        }
    }

    private func logDetections(_ boxes: [PIIBox]) {
        guard !boxes.isEmpty else {
            lastLoggedSignature = ""
            return
        }
        let signature = boxes.map { "\($0.kind.rawValue):\($0.matched)" }.sorted().joined(separator: "|")
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature

        for box in boxes {
            let payload: [String: Any] = [
                "kind": box.kind.rawValue,
                "matched": box.matched,
                "confidence": box.confidence,
                "detectedAt": box.detectedAt,
                "rect": [
                    "x": box.normalizedRect.origin.x,
                    "y": box.normalizedRect.origin.y,
                    "width": box.normalizedRect.width,
                    "height": box.normalizedRect.height,
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        }
    }
}

struct WatchOptions {
    var needles: [String] = []
    var checkEmail: Bool = true
    var fps: Double = 8
    var settings = DetectorSettings()
}

enum CLI {
    static func parse(_ args: [String]) throws -> Command {
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
            throw CLIError.help
        }
        guard args.count >= 2 else {
            throw CLIError.usage
        }

        switch args[1] {
        case "watch":
            return .watch(try parseWatchOptions(Array(args.dropFirst(2))))
        case "benchmark":
            return .benchmark(try parseBenchmarkOptions(Array(args.dropFirst(2))))
        default:
            throw CLIError.usage
        }
    }

    private static func parseWatchOptions(_ args: [String]) throws -> WatchOptions {
        var options = WatchOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]), fps > 0 else {
                    throw CLIError.invalidValue("--fps")
                }
                options.fps = fps
            case "--accurate":
                options.settings.accurate = true
            case "--min-text-height":
                i += 1
                guard i < args.count, let value = Float(args[i]), value > 0, value < 1 else {
                    throw CLIError.invalidValue("--min-text-height")
                }
                options.settings.minimumTextHeight = value
            case "--max-pixel-size":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw CLIError.invalidValue("--max-pixel-size")
                }
                options.settings.maxPixelSize = CGFloat(value)
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        return options
    }

    private static func parseBenchmarkOptions(_ args: [String]) throws -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var customSettings: [DetectorSettings] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]), fps > 0 else {
                    throw CLIError.invalidValue("--fps")
                }
                options.fps = fps
            case "--duration":
                i += 1
                guard i < args.count, let duration = Double(args[i]), duration > 0 else {
                    throw CLIError.invalidValue("--duration")
                }
                options.duration = duration
            case "--config":
                i += 1
                guard i < args.count, let settings = parseDetectorSettings(args[i]) else {
                    throw CLIError.invalidValue("--config")
                }
                customSettings.append(settings)
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--output") }
                options.outputPath = args[i]
            case "--csv":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--csv") }
                options.csvPath = args[i]
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        if !customSettings.isEmpty {
            options.settings = customSettings
        }
        return options
    }

    private static func parseDetectorSettings(_ value: String) -> DetectorSettings? {
        var settings = DetectorSettings()
        for part in value.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            switch pieces[0] {
            case "accurate":
                if pieces[1] == "true" {
                    settings.accurate = true
                } else if pieces[1] == "false" {
                    settings.accurate = false
                } else {
                    return nil
                }
            case "maxPixelSize":
                guard let parsed = Double(pieces[1]), parsed > 0 else { return nil }
                settings.maxPixelSize = CGFloat(parsed)
            case "minimumTextHeight":
                guard let parsed = Float(pieces[1]), parsed > 0, parsed < 1 else { return nil }
                settings.minimumTextHeight = parsed
            default:
                return nil
            }
        }
        return settings
    }

    static let helpText = """
    pii-stream — real-time PII detection on the main display

    Usage:
      pii-stream watch [options]
      pii-stream benchmark [options]

    Watch options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --fps N         Detection rate (default: 8)
      --accurate      Use accurate Vision OCR (slower)
      --min-text-height N
                     Vision minimum text height (default: 0.012)
      --max-pixel-size N
                     Longest OCR side after downscale (default: 1440)

    Benchmark options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --fps N         Screen sample rate (default: 8)
      --duration N    Capture duration in seconds (default: 5)
      --config SPEC   Detector config, repeatable. Example:
                     accurate=false,maxPixelSize=1920,minimumTextHeight=0.008
      --output PATH   Write JSON summary to PATH instead of stdout
      --csv PATH      Write CSV summary to PATH

    General:
      -h, --help      Show this help
    """
}

enum Command {
    case watch(WatchOptions)
    case benchmark(BenchmarkOptions)
}

enum CLIError: Error, LocalizedError {
    case usage
    case help
    case missingValue(String)
    case invalidValue(String)
    case unknownFlag(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Invalid usage. Run `pii-stream --help`."
        case .help:
            return CLI.helpText
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidValue(let flag):
            return "Invalid value for \(flag)."
        case .unknownFlag(let flag):
            return "Unknown flag: \(flag)."
        }
    }
}
