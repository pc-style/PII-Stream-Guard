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
    var maskMode: MaskMode = .boundingBox
    var blackoutWholeFrame = false
    var usesBuiltInMasking = true

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

    func updateOverlay(
        boxes: [PIIBox],
        frameSize: CGSize,
        maskMode: MaskMode,
        blackoutWholeFrame: Bool,
        usesBuiltInMasking: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.boxes = boxes
            self.frameSize = frameSize
            self.maskMode = maskMode
            self.blackoutWholeFrame = blackoutWholeFrame
            self.usesBuiltInMasking = usesBuiltInMasking
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

        if blackoutWholeFrame {
            let blackoutLayer = CALayer()
            blackoutLayer.frame = viewBounds
            blackoutLayer.backgroundColor = NSColor.black.cgColor
            overlayLayer.addSublayer(blackoutLayer)
            return
        }

        for box in boxes {
            let rect = visionRectToView(box.normalizedRect, frameSize: frameSize)
            var scaled = CGRect(
                x: offsetX + rect.origin.x * scale,
                y: offsetY + rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            if maskMode == .blackout, usesBuiltInMasking {
                scaled = expandedBuiltInBlackoutRect(scaled, within: viewBounds)
            }

            let boxLayer = CALayer()
            boxLayer.frame = scaled
            switch maskMode {
            case .boundingBox:
                boxLayer.borderColor = NSColor.systemRed.cgColor
                boxLayer.borderWidth = 2
                boxLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
            case .blackout:
                boxLayer.backgroundColor = NSColor.black.cgColor
            }
            overlayLayer.addSublayer(boxLayer)

            guard maskMode == .boundingBox else { continue }
            let label = CATextLayer()
            label.string = "\(box.kind.rawValue) detected"
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

    private func expandedBuiltInBlackoutRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let horizontalPadding = max(80, rect.width * 0.45)
        let verticalPadding = max(10, rect.height * 1.2)
        return rect
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(bounds)
    }
}

final class PreviewWindowController: NSWindowController {
    private let previewView: PreviewView
    private let frameStore: FrameStore
    private let boxStore: BoxStore
    private let onModeChanged: (GuardMode) -> Void
    private let recorder = PreviewRecorder()
    private let statusLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var guardMode: GuardMode
    private var maskMode: MaskMode = .boundingBox
    private var isRecording = false

    init(
        frameStore: FrameStore,
        boxStore: BoxStore,
        windowSize: CGSize,
        initialMode: GuardMode,
        onModeChanged: @escaping (GuardMode) -> Void
    ) {
        self.frameStore = frameStore
        self.boxStore = boxStore
        self.guardMode = initialMode
        self.onModeChanged = onModeChanged
        previewView = PreviewView(frame: NSRect(origin: .zero, size: windowSize))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PII-Stream Preview"
        window.sharingType = .none
        window.contentView = NSView()
        window.center()
        window.makeKeyAndOrderFront(nil)

        super.init(window: window)
        window.contentView = makeContentView(windowSize: windowSize)
        startDisplayLoop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLoop()
        recorder.stop()
    }

    private func startDisplayLoop() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDisplayLoop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let targetTime = ProcessInfo.processInfo.systemUptime - guardMode.renderDelay
        let delayedSample = frameStore.sample(atOrBefore: targetTime)
        let freshSnapshot = boxStore.snapshot(atOrBefore: targetTime, maxAge: guardMode.maxSnapshotAge)
        let sample: FrameSample
        let snapshot: DetectionSnapshot

        if let freshSnapshot, let snapshotSample = frameStore.sample(frameID: freshSnapshot.frameID) {
            sample = snapshotSample
            snapshot = freshSnapshot
        } else {
            guard let delayedSample else { return }
            sample = delayedSample
            snapshot = DetectionSnapshot(
                frameID: sample.id,
                boxes: [],
                frameSize: sample.frameSize,
                capturedAt: sample.capturedAt,
                guardMode: guardMode,
                armed: true,
                blackoutWholeFrame: true
            )
        }
        previewView.updateFrame(sample.pixelBuffer)
        previewView.updateOverlay(
            boxes: snapshot.boxes,
            frameSize: sample.frameSize,
            maskMode: maskMode,
            blackoutWholeFrame: snapshot.blackoutWholeFrame,
            usesBuiltInMasking: usesBuiltInMasking(for: guardMode)
        )

        if isRecording {
            recorder.append(
                sample: sample,
                boxes: snapshot.boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                isArmed: snapshot.armed,
                blackoutWholeFrame: snapshot.blackoutWholeFrame
            )
        }
        updateStatus(boxCount: snapshot.boxes.count, armed: snapshot.armed)
    }

    private func makeContentView(windowSize: CGSize) -> NSView {
        let modeControl = NSSegmentedControl(
            labels: GuardMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        modeControl.selectedSegment = GuardMode.allCases.firstIndex(of: guardMode) ?? 1

        let maskControl = NSSegmentedControl(
            labels: ["Boxes", "Blackout"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(maskChanged(_:))
        )
        maskControl.selectedSegment = 0

        let recordButton = NSButton(title: "Record", target: self, action: #selector(recordChanged(_:)))
        recordButton.setButtonType(.toggle)

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [modeControl, maskControl, recordButton, statusLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let root = NSStackView(views: [controls, previewView])
        root.orientation = .vertical
        root.spacing = 0
        root.frame = NSRect(origin: .zero, size: windowSize)
        root.autoresizingMask = [.width, .height]
        previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: windowSize.height - 44).isActive = true
        return root
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = GuardMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        guardMode = modes[sender.selectedSegment]
        onModeChanged(guardMode)
    }

    @objc private func maskChanged(_ sender: NSSegmentedControl) {
        maskMode = sender.selectedSegment == 1 ? .blackout : .boundingBox
    }

    @objc private func recordChanged(_ sender: NSButton) {
        if sender.state == .on {
            do {
                let url = try recorder.start()
                isRecording = true
                statusLabel.stringValue = "Recording \(url.lastPathComponent)"
            } catch {
                sender.state = .off
                isRecording = false
                statusLabel.stringValue = "Recording failed: \(error.localizedDescription)"
            }
        } else {
            isRecording = false
            recorder.stop()
            statusLabel.stringValue = "Recording stopped"
        }
    }

    private func updateStatus(boxCount: Int, armed: Bool) {
        guard !isRecording else { return }
        statusLabel.stringValue = "\(guardMode.title)  delay \(String(format: "%.2fs", guardMode.renderDelay))  \(maskMode.rawValue)  armed \(armed ? "yes" : "no")  boxes \(boxCount)"
    }

    private func usesBuiltInMasking(for mode: GuardMode) -> Bool {
        switch mode {
        case .lockdown, .standard, .lowLatency:
            return true
        }
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
    private var guardState: GuardStateMachine
    private var boxStabilizer = BoxStabilizer()
    private var guardMode: GuardMode
    private var lastDetectionTime: TimeInterval = 0
    private var lastLoggedSignature: String = ""
    private let detectionStateLock = NSLock()
    private var detectionInFlight = false
    private var pendingDetectionSample: FrameSample?
    private var newestAcceptedFrameID: UInt64 = 0

    init(options: WatchOptions) {
        self.options = options
        guardMode = options.mode
        detector = AppCoordinator.makeDetector(options: options, mode: options.mode)
        guardState = GuardStateMachine(mode: options.mode)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        preview = PreviewWindowController(
            frameStore: frameStore,
            boxStore: boxStore,
            windowSize: CGSize(width: 1280, height: 800),
            initialMode: options.mode
        ) { [weak self] mode in
            self?.setMode(mode)
        }

        capture = ScreenCaptureManager(frameStore: frameStore) { [weak self] sample in
            self?.scheduleDetectionIfNeeded(sample: sample)
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

    private func scheduleDetectionIfNeeded(sample: FrameSample) {
        detectionStateLock.lock()
        if detectionInFlight {
            pendingDetectionSample = sample
            detectionStateLock.unlock()
            return
        }
        detectionInFlight = true
        detectionStateLock.unlock()

        detectionQueue.async { [weak self] in
            guard let self else { return }
            var sampleToProcess: FrameSample? = sample
            while let current = sampleToProcess {
                let age = ProcessInfo.processInfo.systemUptime - current.capturedAt
                if age <= self.guardMode.maxDetectionInputAge, self.shouldStartDetectionNow() {
                    self.lastDetectionTime = ProcessInfo.processInfo.systemUptime
                    self.detect(sample: current)
                }

                self.detectionStateLock.lock()
                sampleToProcess = self.pendingDetectionSample
                self.pendingDetectionSample = nil
                if sampleToProcess == nil {
                    self.detectionInFlight = false
                }
                self.detectionStateLock.unlock()
            }
        }
    }

    private func shouldStartDetectionNow() -> Bool {
        let detectionFPS = options.fps ?? guardMode.detectionFPS
        guard detectionFPS > 0 else { return true }
        let interval = 1.0 / detectionFPS
        return ProcessInfo.processInfo.systemUptime - lastDetectionTime >= interval
    }

    private func detect(sample: FrameSample) {
        guard sample.id > newestAcceptedFrameID else { return }
        let detectedBoxes = detector.detect(in: sample.pixelBuffer)
        guard sample.id > newestAcceptedFrameID else { return }
        newestAcceptedFrameID = sample.id
        let guardSnapshot = guardState.ingest(detected: detectedBoxes)
        let displayBoxes: [PIIBox]
        if guardSnapshot.active {
            displayBoxes = boxStabilizer.stabilize(guardSnapshot.boxes)
        } else {
            boxStabilizer.reset()
            displayBoxes = []
        }

        boxStore.update(DetectionSnapshot(
            frameID: sample.id,
            boxes: displayBoxes,
            frameSize: sample.frameSize,
            capturedAt: sample.capturedAt,
            guardMode: guardSnapshot.mode,
            armed: guardSnapshot.active,
            blackoutWholeFrame: guardSnapshot.blackoutWholeFrame
        ))
        logDetections(detectedBoxes, frameID: sample.id, guardSnapshot: guardSnapshot)
    }

    private func usesBuiltInMasking(for mode: GuardMode) -> Bool {
        switch mode {
        case .lockdown, .standard, .lowLatency:
            return true
        }
    }

    private func setMode(_ mode: GuardMode) {
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.guardMode = mode
            self.guardState.setMode(mode)
            self.boxStabilizer.reset()
            self.detector = AppCoordinator.makeDetector(options: self.options, mode: mode)
            self.lastDetectionTime = 0
            self.newestAcceptedFrameID = 0
            self.detectionStateLock.lock()
            self.detectionInFlight = false
            self.pendingDetectionSample = nil
            self.detectionStateLock.unlock()
        }
    }

    private static func makeDetector(options: WatchOptions, mode: GuardMode) -> VisionPIIDetector {
        let settings = options.settingsOverride ?? mode.detectorSettings
        return VisionPIIDetector(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            accurate: settings.accurate,
            maxPixelSize: settings.maxPixelSize,
            minimumTextHeight: settings.minimumTextHeight,
            enhanceLowContrast: settings.enhanceLowContrast
        )
    }

    private func logDetections(_ boxes: [PIIBox], frameID: UInt64, guardSnapshot: GuardStateSnapshot) {
        guard !boxes.isEmpty else {
            lastLoggedSignature = ""
            return
        }
        let signature = boxes.map {
            "\($0.kind.rawValue):len:\($0.matched.count):rect:\(rectBucket(for: $0.normalizedRect))"
        }.sorted().joined(separator: "|")
            + "|\(guardSnapshot.mode.rawValue)|armed:\(guardSnapshot.active)"
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature

        for box in boxes {
            let payload: [String: Any] = [
                "frameID": frameID,
                "kind": box.kind.rawValue,
                "matchedLength": box.matched.count,
                "confidence": box.confidence,
                "detectedAt": box.detectedAt,
                "guardMode": guardSnapshot.mode.rawValue,
                "armed": guardSnapshot.active,
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

    private func rectBucket(for rect: CGRect) -> String {
        let x = Int((rect.origin.x * 1000).rounded())
        let y = Int((rect.origin.y * 1000).rounded())
        let width = Int((rect.width * 1000).rounded())
        let height = Int((rect.height * 1000).rounded())
        return "\(x),\(y),\(width),\(height)"
    }
}

struct WatchOptions {
    var needles: [String] = []
    var checkEmail: Bool = true
    var checkPhone: Bool = true
    var fps: Double?
    var mode: GuardMode = .standard
    var settingsOverride: DetectorSettings?
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
        case "detect-image":
            return .detectImage(try parseDetectImageOptions(Array(args.dropFirst(2))))
        default:
            throw CLIError.usage
        }
    }

    private static func parseWatchOptions(_ args: [String]) throws -> WatchOptions {
        var options = WatchOptions()
        var settingsOverride: DetectorSettings?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--no-phone":
                options.checkPhone = false
            case "--fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]), fps > 0 else {
                    throw CLIError.invalidValue("--fps")
                }
                options.fps = fps
            case "--mode":
                i += 1
                guard i < args.count, let mode = parseGuardMode(args[i]) else {
                    throw CLIError.invalidValue("--mode")
                }
                options.mode = mode
            case "--accurate":
                var settings = settingsOverride ?? options.mode.detectorSettings
                settings.accurate = true
                settingsOverride = settings
            case "--min-text-height":
                i += 1
                guard i < args.count, let value = Float(args[i]), value > 0, value < 1 else {
                    throw CLIError.invalidValue("--min-text-height")
                }
                var settings = settingsOverride ?? options.mode.detectorSettings
                settings.minimumTextHeight = value
                settingsOverride = settings
            case "--max-pixel-size":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw CLIError.invalidValue("--max-pixel-size")
                }
                var settings = settingsOverride ?? options.mode.detectorSettings
                settings.maxPixelSize = CGFloat(value)
                settingsOverride = settings
            case "--enhance-low-contrast":
                var settings = settingsOverride ?? options.mode.detectorSettings
                settings.enhanceLowContrast = true
                settingsOverride = settings
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        options.settingsOverride = settingsOverride
        return options
    }

    private static func parseDetectImageOptions(_ args: [String]) throws -> DetectImageOptions {
        var imagePath: String?
        var needles: [String] = []
        var checkEmail = true
        var checkPhone = true
        var mode: GuardMode = .standard
        var settingsOverride: DetectorSettings?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--image":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--image") }
                imagePath = args[i]
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                needles.append(args[i])
            case "--json":
                break
            case "--no-email":
                checkEmail = false
            case "--no-phone":
                checkPhone = false
            case "--mode":
                i += 1
                guard i < args.count, let parsed = parseGuardMode(args[i]) else {
                    throw CLIError.invalidValue("--mode")
                }
                mode = parsed
            case "--accurate":
                var settings = settingsOverride ?? mode.detectorSettings
                settings.accurate = true
                settingsOverride = settings
            case "--min-text-height":
                i += 1
                guard i < args.count, let value = Float(args[i]), value > 0, value < 1 else {
                    throw CLIError.invalidValue("--min-text-height")
                }
                var settings = settingsOverride ?? mode.detectorSettings
                settings.minimumTextHeight = value
                settingsOverride = settings
            case "--max-pixel-size":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw CLIError.invalidValue("--max-pixel-size")
                }
                var settings = settingsOverride ?? mode.detectorSettings
                settings.maxPixelSize = CGFloat(value)
                settingsOverride = settings
            case "--enhance-low-contrast":
                var settings = settingsOverride ?? mode.detectorSettings
                settings.enhanceLowContrast = true
                settingsOverride = settings
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }

        guard let imagePath else { throw CLIError.missingValue("--image") }
        return DetectImageOptions(
            imagePath: imagePath,
            needles: needles,
            checkEmail: checkEmail,
            checkPhone: checkPhone,
            mode: mode,
            settingsOverride: settingsOverride
        )
    }

    private static func parseBenchmarkOptions(_ args: [String]) throws -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--no-phone":
                options.checkPhone = false
            case "--duration":
                i += 1
                guard i < args.count, let duration = Double(args[i]), duration > 0 else {
                    throw CLIError.invalidValue("--duration")
                }
                options.duration = duration
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
            case "enhanceLowContrast":
                if pieces[1] == "true" {
                    settings.enhanceLowContrast = true
                } else if pieces[1] == "false" {
                    settings.enhanceLowContrast = false
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        return settings
    }

    private static func parseGuardMode(_ value: String) -> GuardMode? {
        switch value.lowercased() {
        case "lockdown":
            return .lockdown
        case "standard":
            return .standard
        case "low-latency", "low_latency", "lowlatency":
            return .lowLatency
        default:
            return nil
        }
    }

    static let helpText = """
    pii-stream — real-time PII detection on the main display

    Usage:
      pii-stream watch [options]
      pii-stream benchmark [options]
      pii-stream detect-image --image PATH [options] --json

    Watch options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --mode MODE     lockdown, standard, or low-latency (default: standard)
      --fps N         Override mode detection rate
      --accurate      Use accurate Vision OCR (slower)
      --min-text-height N
                     Override Vision minimum text height
      --max-pixel-size N
                     Override longest OCR side after downscale
      --enhance-low-contrast
                     Boost contrast/sharpness before OCR

    Benchmark:
      Captures live frames once, then measures detection latency across a
      fixed matrix: 720p (1280x720) and 1080p (1920x1080), each reported
      against 10, 30, and 60 fps budgets. Each row lists min, p95, average
      frame time, required render delay, budget slack, and budget fit.

    Benchmark options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --duration N    Capture duration in seconds (default: 5)
      --output PATH   Write JSON summary to PATH instead of stdout
      --csv PATH      Write CSV summary to PATH

    Detect image options:
      --image PATH    Image to scan
      --needle TEXT   Additional PII needle to match (repeatable)
      --json          Emit detector JSON for benchmark adapters
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --mode MODE     lockdown, standard, or low-latency (default: standard)
      --accurate      Use accurate Vision OCR (slower)
      --min-text-height N
                     Override Vision minimum text height
      --max-pixel-size N
                     Override longest OCR side after downscale
      --enhance-low-contrast
                     Boost contrast/sharpness before OCR

    General:
      -h, --help      Show this help
    """
}

enum Command {
    case watch(WatchOptions)
    case benchmark(BenchmarkOptions)
    case detectImage(DetectImageOptions)
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
