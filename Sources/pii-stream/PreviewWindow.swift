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
            let rect = FrameMasker.pixelRect(from: box.normalizedRect, frameSize: frameSize)
            var scaled = CGRect(
                x: offsetX + rect.origin.x * scale,
                y: offsetY + rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            if maskMode == .blackout, usesBuiltInMasking {
                scaled = FrameMasker.builtInBlackoutRect(scaled, within: viewBounds)
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
    private var lastDisplayedFrameID: UInt64?
    private var lastOverlaySignature: String?

    init(
        frameStore: FrameStore,
        boxStore: BoxStore,
        windowSize: CGSize,
        initialMode: GuardMode,
        placement: WindowPlacement = .center,
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
        // Place the window per the chosen placement (default: centered).
        if let screen = NSScreen.main, let frame = placement.frame(on: screen) {
            window.setFrame(frame, display: true)
        } else {
            window.center()
        }
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
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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
        if sample.id != lastDisplayedFrameID {
            previewView.updateFrame(sample.pixelBuffer)
            lastDisplayedFrameID = sample.id
        }

        let usesBuiltInMasking = FrameMasker.usesBuiltInMasking(for: guardMode)
        let overlaySignature = signature(
            for: snapshot,
            frameSize: sample.frameSize,
            maskMode: maskMode,
            usesBuiltInMasking: usesBuiltInMasking
        )
        if overlaySignature != lastOverlaySignature {
            previewView.updateOverlay(
                boxes: snapshot.boxes,
                frameSize: sample.frameSize,
                maskMode: maskMode,
                blackoutWholeFrame: snapshot.blackoutWholeFrame,
                usesBuiltInMasking: usesBuiltInMasking
            )
            lastOverlaySignature = overlaySignature
        }

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
        lastOverlaySignature = nil
        onModeChanged(guardMode)
    }

    @objc private func maskChanged(_ sender: NSSegmentedControl) {
        maskMode = sender.selectedSegment == 1 ? .blackout : .boundingBox
        lastOverlaySignature = nil
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


    private func signature(
        for snapshot: DetectionSnapshot,
        frameSize: CGSize,
        maskMode: MaskMode,
        usesBuiltInMasking: Bool
    ) -> String {
        let boxSignature = snapshot.boxes.map { box in
            "\(box.kind.rawValue):\(box.matched):\(rectBucket(for: box.normalizedRect)):c\(Int((box.confidence * 100).rounded()))"
        }.joined(separator: "|")
        return [
            "size:\(Int(frameSize.width))x\(Int(frameSize.height))",
            "mode:\(snapshot.guardMode.rawValue)",
            "mask:\(maskMode.rawValue)",
            "armed:\(snapshot.armed)",
            "blackout:\(snapshot.blackoutWholeFrame)",
            "builtin:\(usesBuiltInMasking)",
            boxSignature,
        ].joined(separator: ";")
    }

    private func rectBucket(for rect: CGRect) -> String {
        let x = Int((rect.origin.x * 1000).rounded())
        let y = Int((rect.origin.y * 1000).rounded())
        let width = Int((rect.width * 1000).rounded())
        let height = Int((rect.height * 1000).rounded())
        return "\(x),\(y),\(width),\(height)"
    }
}
