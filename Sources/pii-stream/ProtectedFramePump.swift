import Foundation

/// Drives the protected output cadence (60 Hz). Every tick it resolves the
/// delayed (render-delay) frame plus its freshest detection snapshot and fans
/// the result out to whichever sinks are attached: preview window, recorder,
/// or both. Detection cadence stays independent because this only reads stores.
///
/// Fail-closed: when no sufficiently fresh snapshot exists for the delayed
/// frame, the delivered snapshot blacks out the whole frame.
final class ProtectedFramePump {
    struct ProtectedFrame {
        let sample: FrameSample
        let snapshot: DetectionSnapshot
    }

    private let frameStore: FrameStore
    private let boxStore: BoxStore
    private let decisionStore: DecisionTimelineStore
    private var timer: Timer?

    var guardMode: GuardMode

    /// Delayed, fail-closed protected frame that feeds the preview window and recorder.
    var onProtectedFrame: ((ProtectedFrame) -> Void)?
    /// Zero-delay frame for the on-screen overlay presentation (boxes over the
    /// live screen; never blacks out the whole display).
    var onImmediateFrame: ((ProtectedFrame) -> Void)?
    /// Lets an attached but currently idle sink (for example, a stopped
    /// recorder) suppress store scans without rebuilding the pump.
    var shouldProduceProtectedFrame: (() -> Bool)?

    init(
        frameStore: FrameStore,
        boxStore: BoxStore,
        decisionStore: DecisionTimelineStore,
        guardMode: GuardMode
    ) {
        self.frameStore = frameStore
        self.boxStore = boxStore
        self.decisionStore = decisionStore
        self.guardMode = guardMode
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let onProtectedFrame, shouldProduceProtectedFrame?() != false {
            if let frame = resolveFrame(at: now - guardMode.renderDelay, failClosedBlackout: true) {
                onProtectedFrame(frame)
            }
        }
        if let onImmediateFrame {
            if let frame = resolveFrame(at: now, failClosedBlackout: false) {
                onImmediateFrame(frame)
            }
        }
    }

    private func resolveFrame(at targetTime: TimeInterval, failClosedBlackout: Bool) -> ProtectedFrame? {
        let decision = decisionStore.decision(at: targetTime, maxAge: guardMode.maxSnapshotAge)
        let freshSnapshot = boxStore.snapshot(atOrBefore: targetTime, maxAge: guardMode.maxSnapshotAge)
        if let freshSnapshot, let snapshotSample = frameStore.sample(frameID: freshSnapshot.frameID) {
            return ProtectedFrame(
                sample: snapshotSample,
                snapshot: Self.applying(decision, to: freshSnapshot, failClosedBlackout: failClosedBlackout)
            )
        }
        guard let delayedSample = frameStore.sample(atOrBefore: targetTime) else { return nil }
        let fallback = DetectionSnapshot(
            frameID: delayedSample.id,
            boxes: [],
            frameSize: delayedSample.frameSize,
            capturedAt: delayedSample.capturedAt,
            guardMode: guardMode,
            armed: true,
            blackoutWholeFrame: failClosedBlackout
        )
        return ProtectedFrame(
            sample: delayedSample,
            snapshot: Self.applying(decision, to: fallback, failClosedBlackout: failClosedBlackout)
        )
    }

    static func applying(
        _ decision: ProtectionDecision?,
        to snapshot: DetectionSnapshot,
        failClosedBlackout: Bool
    ) -> DetectionSnapshot {
        let timelineRequiresBlackout: Bool
        switch decision?.action {
        case .blackout:
            timelineRequiresBlackout = failClosedBlackout
        case .clear:
            timelineRequiresBlackout = false
        case .mask:
            timelineRequiresBlackout = failClosedBlackout && snapshot.boxes.isEmpty
        case nil:
            timelineRequiresBlackout = failClosedBlackout
        }

        guard timelineRequiresBlackout, !snapshot.blackoutWholeFrame else { return snapshot }
        return DetectionSnapshot(
            frameID: snapshot.frameID,
            boxes: snapshot.boxes,
            frameSize: snapshot.frameSize,
            capturedAt: snapshot.capturedAt,
            guardMode: snapshot.guardMode,
            armed: true,
            blackoutWholeFrame: true,
            freshness: snapshot.freshness
        )
    }
}
