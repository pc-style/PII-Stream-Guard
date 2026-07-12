import AppKit
import CoreGraphics
import CoreMedia
import Foundation

public final class AppCoordinator: NSObject, NSApplicationDelegate {
    let frameStore: FrameStore
    private let captureFrameStore: FrameStore
    let boxStore = BoxStore()
    private let decisionStore: DecisionTimelineStore
    private let detectionCoordinator: DetectionCoordinator
    let options: WatchOptions

    private var capture: CaptureEngine?
    private var preview: PreviewWindowController?
    private var pump: ProtectedFramePump?
    private let recorder = ProtectedRecorder()
    private let detectionQueue = DispatchQueue(label: "pii-stream.detection")
    private var processor: FrameProcessor
    private var remoteClient: RemoteFrameClient?
    private var guardMode: GuardMode
    private var maskMode: MaskMode
    private var lastDetectionTime: TimeInterval = 0
    private var lastLoggedSignature: String = ""
    private let detectionStateLock = NSLock()
    private var detectionInFlight = false
    private var pendingDetectionSample: FrameSample?
    private let remoteStateLock = NSLock()
    private var remoteInFlight = false
    private var pendingRemoteSample: FrameSample?

    private var axScanner: AccessibilityTextScanner?
    private var axTimer: DispatchSourceTimer?
    private let axQueue = DispatchQueue(label: "pii-stream.ax", qos: .utility)
    private var axInFlight = false
    private var axWarnedNoTrust = false

    private var durationWorkItem: DispatchWorkItem?
    private var sigintSource: DispatchSourceSignal?
    private var latestFreshness = DetectionFreshness.none

    public init(options: WatchOptions) {
        self.options = options
        let decisionStore = DecisionTimelineStore(requiredSources: [.ocr])
        self.decisionStore = decisionStore
        detectionCoordinator = DetectionCoordinator(timeline: decisionStore)
        let maximumFrameCount = max(
            2,
            Int((Double(options.capture.captureFPS) * 0.75).rounded(.up)) + 2
        )
        let outputStore = FrameStore(
            maxSampleAge: Self.frameRetention(for: options.mode),
            maxSamples: maximumFrameCount
        )
        frameStore = outputStore
        // In remote mode source frames only need to survive the in-flight
        // request; RemoteFrameClient retains that one sample explicitly.
        captureFrameStore = options.remote == nil
            ? outputStore
            : FrameStore(maxSampleAge: 0, maxSamples: 1)
        guardMode = options.mode
        maskMode = options.maskMode
        processor = FrameProcessor(options: options.processingOptions)
        super.init()
    }

    private static func frameRetention(for mode: GuardMode) -> TimeInterval {
        // Keep enough history for delayed rendering and snapshot fallback, but
        // do not retain three quarters of a second of 4K surfaces in every mode.
        min(0.75, mode.renderDelay + mode.maxSnapshotAge + 0.05)
    }

    // MARK: App lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let headless = options.previewPresentation == nil
        NSApp.setActivationPolicy(headless ? .accessory : .regular)
        if !headless {
            NSApp.activate(ignoringOtherApps: true)
        }

        recorder.onEvent = { [weak self] event in
            self?.handleRecorderEvent(event)
        }

        if let presentation = options.previewPresentation {
            preview = PreviewWindowController(
                windowSize: CGSize(width: 1280, height: 800),
                initialMode: options.mode,
                initialMaskMode: options.maskMode,
                presentation: presentation,
                placement: options.placement,
                shareable: options.shareablePreview,
                onModeChanged: { [weak self] mode in
                    self?.setMode(mode)
                },
                onMaskChanged: { [weak self] mask in
                    self?.maskMode = mask
                },
                onRecordToggle: { [weak self] wantsRecording in
                    self?.toggleRecording(wantsRecording)
                }
            )
        }

        if let remote = options.remote {
            guard let token = options.token else {
                fputs("Remote watch requires --token TOKEN.\n", stderr)
                NSApp.terminate(nil)
                return
            }
            do {
                remoteClient = try RemoteFrameClient(
                    hostPort: remote,
                    token: token,
                    config: options.processingOptions,
                    onResponse: { [weak self] processed in
                        self?.acceptRemoteFrame(processed)
                    },
                    onDisconnect: { [weak self] in
                        self?.failClosed()
                    }
                )
                remoteClient?.start()
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                NSApp.terminate(nil)
                return
            }
        }

        let pump = ProtectedFramePump(
            frameStore: frameStore,
            boxStore: boxStore,
            decisionStore: decisionStore,
            guardMode: guardMode
        )
        pump.onProtectedFrame = { [weak self] frame in
            self?.handleProtectedFrame(frame)
        }
        pump.shouldProduceProtectedFrame = { [weak self] in
            guard let self else { return false }
            return self.options.previewPresentation == .window || self.recorder.isRecording
        }
        if options.previewPresentation == .screenOverlay {
            pump.onImmediateFrame = { [weak self] frame in
                guard let self else { return }
                self.preview?.render(frame, maskMode: self.maskMode)
            }
        }
        self.pump = pump
        pump.start()

        capture = CaptureEngine(
            frameStore: captureFrameStore,
            options: options.capture,
            onFrame: { [weak self] sample in
                self?.scheduleDetectionIfNeeded(sample: sample)
            },
            onAudio: { [weak self] sampleBuffer in
                self?.recorder.appendAudio(sampleBuffer)
            }
        )

        installSignalHandler()
        startControlInput()

        Task {
            do {
                try await capture?.start()
                await MainActor.run {
                    self.emitEvent("started", [
                        "target": self.capture?.geometry?.targetDescription ?? "unknown",
                        "guardMode": self.guardMode.rawValue,
                        "preview": self.options.previewPresentation?.rawValue ?? "none",
                    ])
                    self.startAccessibilityScanningIfEnabled()
                    if self.options.recording != nil {
                        self.startRecording(overridePath: nil)
                    }
                }
            } catch {
                fputs("Failed to start screen capture: \(error.localizedDescription)\n", stderr)
                await MainActor.run {
                    self.emitEvent("error", ["message": error.localizedDescription])
                    NSApp.terminate(nil)
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        options.previewPresentation != nil
    }

    public func applicationWillTerminate(_ notification: Notification) {
        recorder.stop()
    }

    // MARK: Protected frame fan-out

    private func handleProtectedFrame(_ frame: ProtectedFramePump.ProtectedFrame) {
        if options.previewPresentation == .window {
            preview?.render(frame, maskMode: maskMode)
        }
        if recorder.isRecording {
            recorder.append(
                sample: frame.sample,
                boxes: frame.snapshot.boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                isArmed: frame.snapshot.armed,
                blackoutWholeFrame: frame.snapshot.blackoutWholeFrame,
                freshness: frame.snapshot.freshness
            )
        }
    }

    // MARK: Recording control

    private func startRecording(overridePath: String?) {
        guard !recorder.isRecording else { return }
        var recordingOptions = options.recording ?? RecordingOptions()
        if let overridePath {
            recordingOptions.outputPath = overridePath
        }
        recordingOptions.includeAudio = recordingOptions.includeAudio && options.capture.capturesAudio
        do {
            let url = try recorder.start(options: recordingOptions)
            preview?.setRecordingStatus(true, message: "Recording \(url.lastPathComponent)")
            if let duration = recordingOptions.duration {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.recorder.isRecording else { return }
                    self.recorder.stop()
                    if self.options.previewPresentation == nil {
                        self.shutdown()
                    }
                }
                durationWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
            }
        } catch {
            preview?.setRecordingStatus(false, message: "Recording failed: \(error.localizedDescription)")
            emitEvent("error", ["message": error.localizedDescription])
        }
    }

    private func stopRecording() {
        durationWorkItem?.cancel()
        durationWorkItem = nil
        recorder.stop()
    }

    /// Window record button callback. Returns a status message.
    private func toggleRecording(_ wantsRecording: Bool) -> String? {
        if wantsRecording {
            startRecording(overridePath: nil)
            return nil // startRecording set the status
        }
        stopRecording()
        return nil
    }

    private func handleRecorderEvent(_ event: RecorderEvent) {
        switch event {
        case .started(let url):
            emitEvent("recordingStarted", ["path": url.path])
        case .paused:
            emitEvent("recordingPaused", [:])
            preview?.setRecordingStatus(true, message: "Recording paused")
        case .resumed:
            emitEvent("recordingResumed", [:])
            preview?.setRecordingStatus(true, message: "Recording resumed")
        case .finished(let url, let metadataURL, let frames, let droppedAudio):
            emitEvent("recordingFinished", [
                "path": url.path,
                "metadataPath": metadataURL.path,
                "frames": frames,
                "droppedAudioSamples": droppedAudio,
            ])
            preview?.setRecordingStatus(false, message: "Saved \(url.lastPathComponent)")
            fputs("Recording saved to \(url.path)\n", stderr)
        case .failed(let message):
            emitEvent("error", ["message": message])
            preview?.setRecordingStatus(false, message: "Recording failed: \(message)")
        }
    }

    // MARK: Control input (stdin) & signals

    private func startControlInput() {
        Thread.detachNewThread { [weak self] in
            while let line = readLine(strippingNewline: true) {
                let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                DispatchQueue.main.async {
                    self?.handleControlCommand(command)
                }
            }
        }
    }

    private func handleControlCommand(_ command: String) {
        // Keywords are case-insensitive; arguments (e.g. output paths) keep
        // their case, and the third token onwards is taken verbatim so paths
        // with spaces work: `record start /tmp/My Recordings/out.mov`.
        let rawParts = command.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let parts = rawParts.map { $0.lowercased() }
        switch parts.first {
        case "pause":
            recorder.pause()
        case "resume":
            recorder.resume()
        case "record" where parts.count >= 2 && parts[1] == "start":
            startRecording(overridePath: rawParts.count >= 3 ? rawParts[2] : nil)
        case "record" where parts.count >= 2 && parts[1] == "stop":
            stopRecording()
        case "mode" where parts.count >= 2:
            if let mode = GuardMode(rawValue: parts[1]) {
                setMode(mode)
                preview?.setGuardMode(mode)
            } else {
                emitEvent("error", ["message": "unknown mode \(parts[1])"])
            }
        case "mask" where parts.count >= 2:
            switch parts[1] {
            case "boxes": maskMode = .boundingBox
            case "blackout": maskMode = .blackout
            default: emitEvent("error", ["message": "unknown mask \(parts[1])"])
            }
        case "status":
            printStatus()
        case "stop", "quit", "exit":
            shutdown()
        default:
            emitEvent("error", ["message": "unknown command: \(command)"])
        }
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            self?.shutdown()
        }
        source.resume()
        sigintSource = source
    }

    private func shutdown() {
        stopRecording()
        axTimer?.cancel()
        axTimer = nil
        pump?.stop()
        emitEvent("stopped", [:])
        let capture = capture
        Task {
            await capture?.stop()
            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }

    private func printStatus() {
        let now = ProcessInfo.processInfo.systemUptime
        var payload: [String: Any] = [
            "event": "status",
            "recording": recorder.isRecording,
            "paused": recorder.isPausedNow,
            "guardMode": guardMode.rawValue,
            "maskMode": maskMode.rawValue,
            "target": capture?.geometry?.targetDescription ?? "unknown",
            "preview": options.previewPresentation?.rawValue ?? "none",
            "accessibilityTrusted": AccessibilityTextScanner.isTrusted,
        ]
        if let ocrAge = latestFreshness.ocrAge(at: now) {
            payload["ocrAgeMs"] = (ocrAge * 1000).rounded()
        }
        if let axAge = latestFreshness.accessibilityAge(at: now) {
            payload["accessibilityAgeMs"] = (axAge * 1000).rounded()
        }
        printJSON(payload)
    }

    private func emitEvent(_ name: String, _ fields: [String: Any]) {
        guard options.jsonEvents else { return }
        var payload = fields
        payload["event"] = name
        payload["at"] = ProcessInfo.processInfo.systemUptime
        printJSON(payload)
    }

    private func printJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    // MARK: Accessibility detection

    private func startAccessibilityScanningIfEnabled() {
        guard options.accessibilityEnabled, options.remote == nil else { return }
        AccessibilityTextScanner.requestTrustIfNeeded()

        let processingOptions = options.processingOptions
        axScanner = AccessibilityTextScanner(classifier: PIIClassifier(
            needles: processingOptions.needles,
            checkEmail: processingOptions.checkEmail,
            checkPhone: processingOptions.checkPhone
        ))

        let interval = 1.0 / max(0.1, options.accessibilityFPS)
        let timer = DispatchSource.makeTimerSource(queue: axQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.runAccessibilityScan()
        }
        timer.resume()
        axTimer = timer
    }

    private func runAccessibilityScan() {
        guard !axInFlight, let geometry = capture?.geometry, let axScanner else { return }
        axInFlight = true
        defer { axInFlight = false }
        let scanStartedAt = ProcessInfo.processInfo.systemUptime

        var windowTarget: CGWindowID?
        if case .window(let id) = options.capture.target {
            windowTarget = id
        }

        guard let boxes = axScanner.scan(geometry: geometry, windowTarget: windowTarget) else {
            if !axWarnedNoTrust {
                axWarnedNoTrust = true
                fputs(
                    "Accessibility detection inactive: grant Accessibility permission in "
                        + "System Settings > Privacy & Security to enable it (OCR still runs).\n",
                    stderr
                )
            }
            return
        }
        let scannedAt = ProcessInfo.processInfo.systemUptime
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.processor.updateAccessibilityBoxes(boxes, at: scannedAt)
            self.detectionCoordinator.ingest(DetectionBatch(
                source: .accessibility,
                observedAt: scannedAt,
                effectiveFrom: scanStartedAt,
                coverage: .verified,
                findings: boxes
            ))
        }
    }

    // MARK: OCR detection scheduling (unchanged cadence model)

    private func scheduleDetectionIfNeeded(sample: FrameSample) {
        if options.remote != nil {
            scheduleRemoteDetectionIfNeeded(sample: sample)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        detectionStateLock.lock()
        if detectionInFlight {
            pendingDetectionSample = sample
            detectionStateLock.unlock()
            return
        }
        // Reserve the cadence slot before dispatching. Previously every capture
        // frame queued a detection task and most of those tasks immediately did
        // nothing (60 queue hops/sec for a 5–15 Hz detector).
        guard shouldStartDetectionNow(at: now) else {
            detectionStateLock.unlock()
            return
        }
        detectionInFlight = true
        lastDetectionTime = now
        detectionStateLock.unlock()

        detectionQueue.async { [weak self] in
            guard let self else { return }
            var sampleToProcess: FrameSample? = sample
            while let current = sampleToProcess {
                let age = ProcessInfo.processInfo.systemUptime - current.capturedAt
                if age <= self.guardMode.maxDetectionInputAge {
                    self.detect(sample: current)
                }

                self.detectionStateLock.lock()
                let pending = self.pendingDetectionSample
                self.pendingDetectionSample = nil
                let now = ProcessInfo.processInfo.systemUptime
                if let pending,
                   now - pending.capturedAt <= self.guardMode.maxDetectionInputAge,
                   self.shouldStartDetectionNow(at: now) {
                    self.lastDetectionTime = now
                    sampleToProcess = pending
                } else {
                    sampleToProcess = nil
                    self.detectionInFlight = false
                }
                self.detectionStateLock.unlock()
            }
        }
    }

    private func scheduleRemoteDetectionIfNeeded(sample: FrameSample) {
        remoteStateLock.lock()
        if remoteInFlight {
            pendingRemoteSample = sample
            remoteStateLock.unlock()
            return
        }
        guard shouldStartDetectionNow() else {
            remoteStateLock.unlock()
            return
        }
        remoteInFlight = true
        remoteStateLock.unlock()

        lastDetectionTime = ProcessInfo.processInfo.systemUptime
        remoteClient?.send(sample: sample)
    }

    private func shouldStartDetectionNow(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let detectionFPS = options.fps ?? guardMode.detectionFPS
        guard detectionFPS > 0 else { return true }
        let interval = 1.0 / detectionFPS
        return now - lastDetectionTime >= interval
    }

    private func detect(sample: FrameSample) {
        guard let processed = processor.process(sample: sample) else { return }
        detectionCoordinator.ingest(DetectionBatch(
            source: .ocr,
            observedAt: processed.processedAt,
            effectiveFrom: sample.capturedAt,
            coverage: .verified,
            findings: processed.detectedBoxes.filter { $0.source == .ocr }
        ))
        latestFreshness = processed.snapshot.freshness
        boxStore.update(processed.snapshot)
        logDetections(processed.detectedBoxes, snapshot: processed.snapshot)
    }

    private func setMode(_ mode: GuardMode) {
        guardMode = mode
        frameStore.setMaxSampleAge(Self.frameRetention(for: mode))
        pump?.guardMode = mode
        detectionQueue.async { [weak self] in
            guard let self else { return }
            var updated = self.options.processingOptions
            updated.mode = mode
            self.processor.updateOptions(updated)
            self.remoteClient?.updateConfig(updated)
            self.detectionStateLock.lock()
            self.lastDetectionTime = 0
            self.detectionInFlight = false
            self.pendingDetectionSample = nil
            self.detectionStateLock.unlock()
            self.remoteStateLock.lock()
            self.pendingRemoteSample = nil
            self.remoteStateLock.unlock()
        }
    }

    private func acceptRemoteFrame(_ processed: RemoteProcessedFrame) {
        let sample = frameStore.update(processed.buffer)
        let snapshot = DetectionSnapshot(
            frameID: sample.id,
            boxes: processed.snapshot.boxes,
            frameSize: sample.frameSize,
            capturedAt: sample.capturedAt,
            guardMode: processed.snapshot.guardMode,
            armed: processed.snapshot.armed,
            blackoutWholeFrame: processed.snapshot.blackoutWholeFrame
        )
        boxStore.update(snapshot)
        detectionCoordinator.ingest(DetectionBatch(
            source: .ocr,
            observedAt: ProcessInfo.processInfo.systemUptime,
            effectiveFrom: sample.capturedAt,
            coverage: .verified,
            findings: snapshot.boxes
        ))
        logDetections(snapshot.boxes, snapshot: snapshot)
        completeRemoteDetection()
    }

    private func completeRemoteDetection() {
        remoteStateLock.lock()
        let pending = pendingRemoteSample
        pendingRemoteSample = nil
        if let pending, shouldStartDetectionNow() {
            remoteInFlight = true
            remoteStateLock.unlock()

            lastDetectionTime = ProcessInfo.processInfo.systemUptime
            remoteClient?.send(sample: pending)
            return
        }
        remoteInFlight = false
        remoteStateLock.unlock()
    }

    private func failClosed() {
        let now = ProcessInfo.processInfo.systemUptime
        boxStore.update(DetectionSnapshot(
            frameID: 0,
            boxes: [],
            frameSize: .zero,
            capturedAt: now,
            guardMode: guardMode,
            armed: true,
            blackoutWholeFrame: true
        ))
        let unavailableDecision = detectionCoordinator.ingest(DetectionBatch(
            source: .ocr,
            observedAt: now,
            effectiveFrom: frameStore.oldestCapturedAt() ?? now,
            coverage: .unavailable(reason: "remote processor disconnected"),
            findings: []
        ))
        decisionStore.replaceSourceHistory(with: unavailableDecision)
    }

    private func logDetections(_ boxes: [PIIBox], snapshot: DetectionSnapshot) {
        guard !boxes.isEmpty else {
            lastLoggedSignature = ""
            return
        }
        let signature = boxes.map {
            "\($0.kind.rawValue):\($0.source.rawValue):len:\($0.matched.count):rect:\(rectBucket(for: $0.normalizedRect))"
        }.sorted().joined(separator: "|")
            + "|\(snapshot.guardMode.rawValue)|armed:\(snapshot.armed)"
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature

        for box in boxes {
            let payload: [String: Any] = [
                "frameID": snapshot.frameID,
                "kind": box.kind.rawValue,
                "source": box.source.rawValue,
                "matchedLength": box.matched.count,
                "confidence": box.confidence,
                "detectedAt": box.detectedAt,
                "guardMode": snapshot.guardMode.rawValue,
                "armed": snapshot.armed,
                "rect": [
                    "x": box.normalizedRect.origin.x,
                    "y": box.normalizedRect.origin.y,
                    "width": box.normalizedRect.width,
                    "height": box.normalizedRect.height,
                ],
            ]
            printJSON(payload)
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

public enum WindowPlacement: String {
    case center
    case left
    case right

    /// The window frame for this placement on the given screen, or nil to
    /// fall back to the default centered placement.
    func frame(on screen: NSScreen) -> NSRect? {
        let vf = screen.visibleFrame
        switch self {
        case .center:
            return nil
        case .left:
            let halfWidth = (vf.width / 2).rounded(.down)
            return NSRect(x: vf.minX, y: vf.minY, width: halfWidth, height: vf.height)
        case .right:
            let halfWidth = (vf.width / 2).rounded(.down)
            return NSRect(x: vf.maxX - halfWidth, y: vf.minY, width: halfWidth, height: vf.height)
        }
    }
}
