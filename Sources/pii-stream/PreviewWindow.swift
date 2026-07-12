import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class PreviewView: NSView {
    private let frameLayer = AVSampleBufferDisplayLayer()
    private let overlayLayer = CALayer()
    private let showsCapturedFrame: Bool
    private var frameFormat: (
        width: Int,
        height: Int,
        pixelFormat: OSType,
        description: CMVideoFormatDescription
    )?
    private let mapsOverlayToBounds: Bool

    var boxes: [PIIBox] = []
    var frameSize: CGSize = .zero
    var maskMode: MaskMode = .boundingBox
    var blackoutWholeFrame = false
    var usesBuiltInMasking = true

    init(frame frameRect: NSRect, showsCapturedFrame: Bool = true, mapsOverlayToBounds: Bool = false) {
        self.showsCapturedFrame = showsCapturedFrame
        self.mapsOverlayToBounds = mapsOverlayToBounds
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = showsCapturedFrame ? NSColor.black.cgColor : NSColor.clear.cgColor

        frameLayer.videoGravity = .resizeAspect
        frameLayer.frame = bounds
        frameLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        overlayLayer.frame = bounds
        overlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // CALayer defaults to bottom-left origin; flip so Vision→view math (top-left) maps correctly.
        overlayLayer.isGeometryFlipped = true

        if showsCapturedFrame {
            layer?.addSublayer(frameLayer)
        }
        layer?.addSublayer(overlayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame(_ buffer: CVPixelBuffer) {
        guard showsCapturedFrame else { return }
        let renderer = frameLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let formatDescription: CMVideoFormatDescription
        if let frameFormat,
           frameFormat.width == width,
           frameFormat.height == height,
           frameFormat.pixelFormat == pixelFormat {
            formatDescription = frameFormat.description
        } else {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &created
            ) == noErr, let created else { return }
            frameFormat = (width, height, pixelFormat, created)
            formatDescription = created
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        renderer.enqueue(sampleBuffer)
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
        let overlayRects = FrameMasker.overlayRects(
            for: boxes,
            frameSize: frameSize,
            viewBounds: viewBounds,
            maskMode: maskMode,
            usesBuiltInMasking: usesBuiltInMasking,
            blackoutWholeFrame: blackoutWholeFrame,
            mapsOverlayToBounds: mapsOverlayToBounds
        )

        if blackoutWholeFrame {
            guard let blackoutRect = overlayRects.first else { return }
            let blackoutLayer = CALayer()
            blackoutLayer.frame = blackoutRect
            blackoutLayer.backgroundColor = NSColor.black.cgColor
            overlayLayer.addSublayer(blackoutLayer)
            return
        }

        for (box, scaled) in zip(boxes, overlayRects) {
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
    private let onModeChanged: (GuardMode) -> Void
    private let onMaskChanged: (MaskMode) -> Void
    private let onRecordToggle: (Bool) -> String?
    private let presentation: PreviewPresentation
    private let statusLabel = NSTextField(labelWithString: "")
    private var modeControl: NSSegmentedControl?
    private var guardMode: GuardMode
    private let detectionMode: DetectionMode
    private var maskMode: MaskMode
    private var isRecording = false
    private var lastDisplayedFrameID: UInt64?
    private var lastOverlaySignature: String?

    init(
        windowSize: CGSize,
        initialMode: GuardMode,
        detectionMode: DetectionMode,
        initialMaskMode: MaskMode = .boundingBox,
        presentation: PreviewPresentation = .window,
        placement: WindowPlacement = .center,
        shareable: Bool = true,
        onModeChanged: @escaping (GuardMode) -> Void,
        onMaskChanged: @escaping (MaskMode) -> Void = { _ in },
        onRecordToggle: @escaping (Bool) -> String? = { _ in nil }
    ) {
        self.guardMode = initialMode
        self.detectionMode = detectionMode
        self.maskMode = initialMaskMode
        self.onModeChanged = onModeChanged
        self.onMaskChanged = onMaskChanged
        self.onRecordToggle = onRecordToggle
        self.presentation = presentation
        previewView = PreviewView(
            frame: NSRect(origin: .zero, size: windowSize),
            showsCapturedFrame: presentation.showsCapturedFrame,
            mapsOverlayToBounds: presentation.mapsOverlayToBounds
        )

        let window = Self.makeWindow(
            presentation: presentation,
            windowSize: windowSize,
            placement: placement,
            shareable: shareable
        )

        super.init(window: window)
        window.contentView = makeContentView(windowSize: window.frame.size)
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sink for the protected frame pump. Window presentation expects delayed,
    /// fail-closed frames; overlay presentation expects immediate frames.
    func render(_ frame: ProtectedFramePump.ProtectedFrame, maskMode: MaskMode) {
        self.maskMode = maskMode
        let sample = frame.sample
        let snapshot = frame.snapshot

        if sample.id != lastDisplayedFrameID {
            previewView.updateFrame(sample.pixelBuffer)
            lastDisplayedFrameID = sample.id
        }

        let usesBuiltInMasking = FrameMasker.usesBuiltInMasking(for: guardMode)
        let overlaySignature = signature(
            for: snapshot,
            frameSize: sample.frameSize,
            viewBounds: previewView.bounds,
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

        updateStatus(boxCount: snapshot.boxes.count, armed: snapshot.armed)
    }

    /// Reflects a mode change initiated elsewhere (e.g. stdin control).
    func setGuardMode(_ mode: GuardMode) {
        guardMode = mode
        lastOverlaySignature = nil
        if let modeControl, let index = GuardMode.allCases.firstIndex(of: mode) {
            modeControl.selectedSegment = index
        }
    }

    func setRecordingStatus(_ recording: Bool, message: String?) {
        isRecording = recording
        if let message {
            statusLabel.stringValue = message
        }
    }

    private func makeContentView(windowSize: CGSize) -> NSView {
        guard presentation == .window else {
            previewView.frame = NSRect(origin: .zero, size: windowSize)
            previewView.autoresizingMask = [.width, .height]
            return previewView
        }

        let modeControl = NSSegmentedControl(
            labels: GuardMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        modeControl.selectedSegment = GuardMode.allCases.firstIndex(of: guardMode) ?? 1
        self.modeControl = modeControl

        let maskControl = NSSegmentedControl(
            labels: ["Boxes", "Blackout"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(maskChanged(_:))
        )
        maskControl.selectedSegment = maskMode == .blackout ? 1 : 0

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
        onMaskChanged(maskMode)
    }

    @objc private func recordChanged(_ sender: NSButton) {
        let wantsRecording = sender.state == .on
        let message = onRecordToggle(wantsRecording)
        // The coordinator reports the actual state back through setRecordingStatus;
        // reset the button if starting failed.
        if wantsRecording, !isRecording {
            sender.state = .off
        }
        if let message {
            statusLabel.stringValue = message
        }
    }

    private func updateStatus(boxCount: Int, armed: Bool) {
        guard !isRecording else { return }
        statusLabel.stringValue = "\(detectionMode.title)  \(guardMode.title)  delay \(String(format: "%.2fs", guardMode.renderDelay))  \(maskMode.rawValue)  armed \(armed ? "yes" : "no")  boxes \(boxCount)"
    }


    private func signature(
        for snapshot: DetectionSnapshot,
        frameSize: CGSize,
        viewBounds: CGRect,
        maskMode: MaskMode,
        usesBuiltInMasking: Bool
    ) -> String {
        let boxSignature = snapshot.boxes.map { box in
            "\(box.kind.rawValue):\(rectBucket(for: box.normalizedRect))"
        }.joined(separator: "|")
        return [
            "size:\(Int(frameSize.width))x\(Int(frameSize.height))",
            "bounds:\(Int(viewBounds.width))x\(Int(viewBounds.height))",
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

    private static func makeWindow(
        presentation: PreviewPresentation,
        windowSize: CGSize,
        placement: WindowPlacement,
        shareable: Bool
    ) -> NSWindow {
        switch presentation {
        case .window:
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "PII-Stream Protected Output"
            // Shareable by default: the whole point of the protected window is
            // that OBS/Discord/Zoom capture it instead of the raw screen. The
            // capture engine excludes this app from its own capture, so no
            // feedback loop occurs.
            window.sharingType = shareable ? .readOnly : .none
            window.contentView = NSView()
            if let screen = NSScreen.main, let frame = placement.frame(on: screen) {
                window.setFrame(frame, display: true)
            } else {
                window.center()
            }
            return window
        case .screenOverlay:
            let screenFrame = Self.screenForMainDisplay()?.frame ?? NSScreen.main?.frame ?? NSRect(origin: .zero, size: windowSize)
            let window = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.title = "PII-Stream Overlay"
            window.sharingType = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return window
        }
    }

    private static func screenForMainDisplay() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return screenNumber.uint32Value == mainDisplayID
        }
    }
}

public enum PreviewPresentation: String {
    case window
    case screenOverlay = "overlay"

    var showsCapturedFrame: Bool {
        self == .window
    }

    var mapsOverlayToBounds: Bool {
        self == .screenOverlay
    }
}
