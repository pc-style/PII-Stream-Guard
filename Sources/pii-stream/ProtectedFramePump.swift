import Foundation

/// Drives the protected output cadence (60 Hz). Every tick it resolves the
/// delayed (render-delay) frame plus its freshest detection snapshot and fans
/// the result out to whichever sinks are attached: preview window, recorder,
/// or both. Detection cadence stays independent — this only *reads* stores.
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
    private var timer: Timer?

    var guardMode: GuardMode

    /// Delayed, fail-closed protected frame — feeds the preview window and recorder.
    var onProtectedFrame: ((ProtectedFrame) -> Void)?
    /// Zero-delay frame for the on-screen overlay presentation (boxes over the
    /// live screen; never blacks out the whole display).
    var onImmediateFrame: ((ProtectedFrame) -> Void)?

    init(frameStore: FrameStore, boxStore: BoxStore, guardMode: GuardMode) {
        self.frameStore = frameStore
        self.boxStore = boxStore
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
        if let onProtectedFrame {
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
        let freshSnapshot = boxStore.snapshot(atOrBefore: targetTime, maxAge: guardMode.maxSnapshotAge)
        if let freshSnapshot, let snapshotSample = frameStore.sample(frameID: freshSnapshot.frameID) {
            return ProtectedFrame(sample: snapshotSample, snapshot: freshSnapshot)
        }
        guard let delayedSample = frameStore.sample(atOrBefore: targetTime) else { return nil }
        let snapshot = DetectionSnapshot(
            frameID: delayedSample.id,
            boxes: [],
            frameSize: delayedSample.frameSize,
            capturedAt: delayedSample.capturedAt,
            guardMode: guardMode,
            armed: true,
            blackoutWholeFrame: failClosedBlackout
        )
        return ProtectedFrame(sample: delayedSample, snapshot: snapshot)
    }
}
