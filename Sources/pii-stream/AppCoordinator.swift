import AppKit
import CoreGraphics
import Foundation

public final class AppCoordinator: NSObject, NSApplicationDelegate {
    let frameStore = FrameStore()
    private let captureFrameStore: FrameStore
    let boxStore = BoxStore()
    let options: WatchOptions

    private var capture: ScreenCaptureManager?
    private var preview: PreviewWindowController?
    private let detectionQueue = DispatchQueue(label: "pii-stream.detection")
    private var processor: FrameProcessor
    private var remoteClient: RemoteFrameClient?
    private var guardMode: GuardMode
    private var lastDetectionTime: TimeInterval = 0
    private var lastLoggedSignature: String = ""
    private let detectionStateLock = NSLock()
    private var detectionInFlight = false
    private var pendingDetectionSample: FrameSample?
    private let remoteStateLock = NSLock()
    private var remoteInFlight = false
    private var pendingRemoteSample: FrameSample?

    public init(options: WatchOptions) {
        self.options = options
        captureFrameStore = options.remote == nil ? frameStore : FrameStore()
        guardMode = options.mode
        processor = FrameProcessor(options: options.processingOptions)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        preview = PreviewWindowController(
            frameStore: frameStore,
            boxStore: boxStore,
            windowSize: CGSize(width: 1280, height: 800),
            initialMode: options.mode,
            placement: options.placement
        ) { [weak self] mode in
            self?.setMode(mode)
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

        capture = ScreenCaptureManager(frameStore: captureFrameStore) { [weak self] sample in
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

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func scheduleDetectionIfNeeded(sample: FrameSample) {
        if options.remote != nil {
            scheduleRemoteDetectionIfNeeded(sample: sample)
            return
        }

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

    private func shouldStartDetectionNow() -> Bool {
        let detectionFPS = options.fps ?? guardMode.detectionFPS
        guard detectionFPS > 0 else { return true }
        let interval = 1.0 / detectionFPS
        return ProcessInfo.processInfo.systemUptime - lastDetectionTime >= interval
    }

    private func detect(sample: FrameSample) {
        guard let processed = processor.process(sample: sample) else { return }
        boxStore.update(processed.snapshot)
        logDetections(processed.detectedBoxes, snapshot: processed.snapshot)
    }

    private func setMode(_ mode: GuardMode) {
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.guardMode = mode
            var updated = self.options.processingOptions
            updated.mode = mode
            self.processor.updateOptions(updated)
            self.remoteClient?.updateConfig(updated)
            self.lastDetectionTime = 0
            self.detectionStateLock.lock()
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
        boxStore.update(DetectionSnapshot(
            frameID: 0,
            boxes: [],
            frameSize: .zero,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            guardMode: guardMode,
            armed: true,
            blackoutWholeFrame: true
        ))
    }

    private func logDetections(_ boxes: [PIIBox], snapshot: DetectionSnapshot) {
        guard !boxes.isEmpty else {
            lastLoggedSignature = ""
            return
        }
        let signature = boxes.map {
            "\($0.kind.rawValue):len:\($0.matched.count):rect:\(rectBucket(for: $0.normalizedRect))"
        }.sorted().joined(separator: "|")
            + "|\(snapshot.guardMode.rawValue)|armed:\(snapshot.armed)"
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature

        for box in boxes {
            let payload: [String: Any] = [
                "frameID": snapshot.frameID,
                "kind": box.kind.rawValue,
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
