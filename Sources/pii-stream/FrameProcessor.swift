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

/// Stateful frame processor. Callers must serialize access to this type; `process(sample:)`
/// and `updateAccessibilityBoxes(_:at:)` mutate detector, guard-state,
/// stabilization, and frame-order state.
final class FrameProcessor {
    private var options: FrameProcessingOptions
    private var detector: VisionPIIDetector
    private var guardState: GuardStateMachine
    private var stabilizer = BoxStabilizer()
    private var newestAcceptedFrameID: UInt64 = 0

    /// Latest accessibility-derived boxes and when they were produced. AX runs
    /// on its own cadence; results merge into every OCR pass while fresh.
    private var accessibilityBoxes: [PIIBox] = []
    private var lastAccessibilityAt: TimeInterval?
    private var lastOCRAt: TimeInterval?
    /// AX results older than this are ignored (windows move, text scrolls).
    private let accessibilityFreshness: TimeInterval = 0.8

    init(options: FrameProcessingOptions) {
        self.options = options
        detector = DetectionRecipe.frameProcessor(options).makeDetector()
        guardState = GuardStateMachine(mode: options.mode)
    }

    func updateOptions(_ options: FrameProcessingOptions) {
        guard options != self.options else { return }
        let modeChanged = options.mode != self.options.mode
        self.options = options
        detector = DetectionRecipe.frameProcessor(options).makeDetector()
        if modeChanged {
            guardState.setMode(options.mode)
            stabilizer.reset()
            newestAcceptedFrameID = 0
        }
    }

    func updateAccessibilityBoxes(_ boxes: [PIIBox], at time: TimeInterval) {
        accessibilityBoxes = boxes
        lastAccessibilityAt = time
    }

    var freshness: DetectionFreshness {
        DetectionFreshness(lastOCRAt: lastOCRAt, lastAccessibilityAt: lastAccessibilityAt)
    }

    func process(sample: FrameSample) -> ProcessedFrame? {
        guard sample.id > newestAcceptedFrameID else { return nil }
        let ocrBoxes = detector.detect(in: sample.pixelBuffer)
        guard sample.id > newestAcceptedFrameID else { return nil }
        newestAcceptedFrameID = sample.id
        let now = ProcessInfo.processInfo.systemUptime
        lastOCRAt = now

        let detectedBoxes = Self.merge(
            ocr: ocrBoxes,
            accessibility: freshAccessibilityBoxes(at: now)
        )

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
            blackoutWholeFrame: guardSnapshot.blackoutWholeFrame,
            freshness: freshness
        )
        return ProcessedFrame(
            sample: sample,
            detectedBoxes: detectedBoxes,
            snapshot: snapshot,
            processedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private func freshAccessibilityBoxes(at now: TimeInterval) -> [PIIBox] {
        guard let lastAccessibilityAt, now - lastAccessibilityAt <= accessibilityFreshness else {
            return []
        }
        return accessibilityBoxes
    }

    /// Merges the two detection sources into one box list. The union is kept
    /// deliberately: dropping an OCR box because a same-identity accessibility
    /// box overlaps it would let a stale/mispositioned AX rect suppress the
    /// correctly placed OCR mask (e.g. right after a window moves). Masking is
    /// additive, so duplicates only over-mask — never under-mask.
    static func merge(ocr: [PIIBox], accessibility: [PIIBox]) -> [PIIBox] {
        accessibility + ocr
    }
}
