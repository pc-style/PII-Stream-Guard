import CoreGraphics
import CoreVideo
import Foundation

struct FrameProcessingOptions: Codable, Equatable {
    var needles: [String]
    var checkEmail: Bool
    var checkPhone: Bool
    var fps: Double?
    var mode: GuardMode
    var settingsOverride: DetectorSettings?

    init(
        needles: [String] = [],
        checkEmail: Bool = true,
        checkPhone: Bool = true,
        fps: Double? = nil,
        mode: GuardMode = .standard,
        settingsOverride: DetectorSettings? = nil
    ) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        self.fps = fps
        self.mode = mode
        self.settingsOverride = settingsOverride
    }
}

struct ProcessedFrame {
    let sample: FrameSample
    let detectedBoxes: [PIIBox]
    let snapshot: DetectionSnapshot
    let processedAt: TimeInterval
}

final class FrameProcessor {
    private var options: FrameProcessingOptions
    private var detector: VisionPIIDetector
    private var guardState: GuardStateMachine
    private var stabilizer = BoxStabilizer()
    private var newestAcceptedFrameID: UInt64 = 0

    init(options: FrameProcessingOptions) {
        self.options = options
        detector = Self.makeDetector(options: options)
        guardState = GuardStateMachine(mode: options.mode)
    }

    func updateOptions(_ options: FrameProcessingOptions) {
        guard options != self.options else { return }
        let modeChanged = options.mode != self.options.mode
        self.options = options
        detector = Self.makeDetector(options: options)
        if modeChanged {
            guardState.setMode(options.mode)
            stabilizer.reset()
            newestAcceptedFrameID = 0
        }
    }

    func process(sample: FrameSample) -> ProcessedFrame? {
        guard sample.id > newestAcceptedFrameID else { return nil }
        let detectedBoxes = detector.detect(in: sample.pixelBuffer)
        guard sample.id > newestAcceptedFrameID else { return nil }
        newestAcceptedFrameID = sample.id

        let guardSnapshot = guardState.ingest(detected: detectedBoxes)
        let displayBoxes: [PIIBox]
        if guardSnapshot.active {
            displayBoxes = stabilizer.stabilize(guardSnapshot.boxes)
        } else {
            stabilizer.reset()
            displayBoxes = []
        }

        let snapshot = DetectionSnapshot(
            frameID: sample.id,
            boxes: displayBoxes,
            frameSize: sample.frameSize,
            capturedAt: sample.capturedAt,
            guardMode: guardSnapshot.mode,
            armed: guardSnapshot.active,
            blackoutWholeFrame: guardSnapshot.blackoutWholeFrame
        )
        return ProcessedFrame(
            sample: sample,
            detectedBoxes: detectedBoxes,
            snapshot: snapshot,
            processedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func makeDetector(options: FrameProcessingOptions) -> VisionPIIDetector {
        let settings = options.settingsOverride ?? options.mode.detectorSettings
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
}
