import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

// MARK: - Recording settings

public enum RecordingCodec: String, CaseIterable {
    case h264
    case hevc

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

public enum RecordingQuality: String, CaseIterable {
    case efficient
    case balanced
    case high

    /// Bits per pixel per frame, ported from Wrec's bitrate model.
    var bitsPerPixel: Double {
        switch self {
        case .efficient: return 0.045
        case .balanced: return 0.07
        case .high: return 0.105
        }
    }
}

public struct RecordingOptions: Equatable {
    var codec: RecordingCodec = .hevc
    var quality: RecordingQuality = .balanced
    var fps: Int = 30
    var outputPath: String?
    var duration: TimeInterval?
    var includeAudio: Bool = false

    /// Ported from Wrec: bitrate from pixel throughput, quality, and codec.
    static func targetBitrate(width: Int, height: Int, fps: Int, quality: RecordingQuality, codec: RecordingCodec) -> Int {
        let pixelsPerSecond = Double(width * height * fps)
        let codecScale = codec == .h264 ? 1.35 : 1.0
        return max(1_500_000, Int(pixelsPerSecond * quality.bitsPerPixel * codecScale))
    }
}

enum RecorderEvent {
    case started(URL)
    case paused
    case resumed
    case finished(url: URL, metadataURL: URL, frames: Int64, droppedAudio: Int)
    case failed(String)
}

// MARK: - Protected recorder

/// Writes privacy-protected frames (masks composited into pixels) to a .mov
/// via AVAssetWriter, with a JSONL metadata sidecar. Timing uses capture
/// timestamps so pause/resume produces a gapless file (Wrec-style offset
/// retiming), and optional system audio is retimed into the same timeline.
///
/// Not thread-safe: call all methods from the same queue/thread that drives
/// the frame pump, except `appendAudio` which is internally redirected.
final class ProtectedRecorder {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var metadataHandle: FileHandle?
    private var metadataBuffer = Data()
    private var options = RecordingOptions()

    private var sessionStart: TimeInterval?
    private var lastAppendedPTS: TimeInterval = -.greatestFiniteMagnitude
    private var lastAudioPTS: TimeInterval = -.greatestFiniteMagnitude
    private var lastAppendedFrameID: UInt64 = 0
    private var frameCount: Int64 = 0
    private var droppedAudioCount = 0
    private var isPaused = false
    private var pausedAt: TimeInterval = 0
    private var pauseOffset: TimeInterval = 0
    private var outputURL: URL?
    private var metadataURL: URL?

    var onEvent: ((RecorderEvent) -> Void)?

    var isRecording: Bool {
        outputURL != nil
    }

    var isPausedNow: Bool {
        isPaused
    }

    private static let timescale: CMTimeScale = 60_000
    private static let metadataFlushThreshold = 32 * 1024
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: Lifecycle

    func start(options: RecordingOptions) throws -> URL {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        self.options = options

        let url: URL
        if let path = options.outputPath {
            url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let directory = URL(fileURLWithPath: "recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.filenameFormatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            url = directory.appendingPathComponent("pii-stream-\(stamp).mov")
        }

        let metadataURL = url.deletingPathExtension().appendingPathExtension("jsonl")
        FileManager.default.createFile(atPath: metadataURL.path, contents: nil)
        metadataHandle = try FileHandle(forWritingTo: metadataURL)
        metadataBuffer.removeAll(keepingCapacity: true)
        outputURL = url
        self.metadataURL = metadataURL
        sessionStart = nil
        lastAppendedPTS = -.greatestFiniteMagnitude
        lastAudioPTS = -.greatestFiniteMagnitude
        lastAppendedFrameID = 0
        frameCount = 0
        droppedAudioCount = 0
        isPaused = false
        pauseOffset = 0
        onEvent?(.started(url))
        return url
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedAt = ProcessInfo.processInfo.systemUptime
        onEvent?(.paused)
    }

    func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        pauseOffset += ProcessInfo.processInfo.systemUptime - pausedAt
        onEvent?(.resumed)
    }

    func stop() {
        guard isRecording else { return }
        flushMetadata()
        metadataHandle?.closeFile()
        metadataHandle = nil

        let finishedURL = outputURL
        let finishedMetadataURL = metadataURL
        let frames = frameCount
        let droppedAudio = droppedAudioCount
        let wroteAnything = writer != nil

        if let writer, let videoInput {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 15)
            if writer.status == .failed {
                onEvent?(.failed(writer.error?.localizedDescription ?? "writer failed"))
            }
        }
        clear()
        if wroteAnything, let finishedURL, let finishedMetadataURL {
            onEvent?(.finished(url: finishedURL, metadataURL: finishedMetadataURL, frames: frames, droppedAudio: droppedAudio))
        } else if let finishedMetadataURL {
            // No frame was ever appended: no .mov exists, so don't advertise
            // one. Remove the empty metadata sidecar as well.
            try? FileManager.default.removeItem(at: finishedMetadataURL)
            onEvent?(.failed("recording stopped before any frame was captured"))
        }
    }

    // MARK: Video

    func append(
        sample: FrameSample,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        isArmed: Bool,
        blackoutWholeFrame: Bool,
        freshness: DetectionFreshness
    ) {
        guard isRecording, !isPaused else { return }
        guard sample.id != lastAppendedFrameID else { return }

        // Gate on the rebased (pause-adjusted) timeline, not wall clock, so
        // pause/resume can never produce a duplicate or backwards PTS, which
        // would fail the writer.
        let minInterval = 1.0 / Double(max(1, options.fps))
        let candidateSeconds: TimeInterval
        if let sessionStart {
            candidateSeconds = max(0, sample.capturedAt - sessionStart - pauseOffset)
        } else {
            candidateSeconds = 0
        }
        guard candidateSeconds - lastAppendedPTS >= minInterval - 0.001 else { return }

        do {
            try ensureWriter(width: Int(sample.frameSize.width), height: Int(sample.frameSize.height))
        } catch {
            onEvent?(.failed(error.localizedDescription))
            stop()
            return
        }

        guard let writer, let videoInput, let adaptor, writer.status == .writing else { return }
        // Wrec-style backpressure: drop instead of buffering when the encoder lags.
        guard videoInput.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let output = pixelBuffer else { return }

        render(
            sample.pixelBuffer,
            into: output,
            boxes: boxes,
            maskMode: maskMode,
            guardMode: guardMode,
            blackoutWholeFrame: blackoutWholeFrame
        )

        if sessionStart == nil {
            sessionStart = sample.capturedAt
            pauseOffset = 0 // pauses before the first frame don't shift the timeline
            writer.startSession(atSourceTime: .zero)
        }
        guard let sessionStart else { return }
        let seconds = max(0, sample.capturedAt - sessionStart - pauseOffset)
        let time = CMTime(seconds: seconds, preferredTimescale: Self.timescale)

        if adaptor.append(output, withPresentationTime: time) {
            lastAppendedPTS = seconds
            lastAppendedFrameID = sample.id
            frameCount += 1
            writeMetadata(
                sample: sample,
                pts: seconds,
                boxes: boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                isArmed: isArmed,
                blackoutWholeFrame: blackoutWholeFrame,
                freshness: freshness
            )
        }
    }

    // MARK: Audio

    /// Appends a system-audio sample buffer captured by ScreenCaptureKit.
    /// Safe to call from any queue: work hops to the main queue, where all
    /// other recorder state is mutated, so no locking is needed.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        if Thread.isMainThread {
            appendAudioOnMain(sampleBuffer)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendAudioOnMain(sampleBuffer)
            }
        }
    }

    private func appendAudioOnMain(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, options.includeAudio, !isPaused,
              let audioInput, let sessionStart,
              sampleBuffer.isValid else {
            if isRecording, options.includeAudio { droppedAudioCount += 1 }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // SCK audio PTS and FrameSample.capturedAt share the mach host clock,
        // so both can be rebased onto the same session timeline.
        let rebased = pts.seconds - sessionStart - pauseOffset
        guard pts.isValid, rebased >= 0 else {
            droppedAudioCount += 1
            return
        }
        // Audio PTS must be strictly increasing. Around a resume, delivery
        // latency can make the first post-resume buffer rebase slightly before
        // the last pre-pause one; appending it would fail the writer.
        guard rebased > lastAudioPTS else {
            droppedAudioCount += 1
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            droppedAudioCount += 1
            return
        }
        guard let retimed = retimedSampleBuffer(sampleBuffer, to: rebased) else {
            droppedAudioCount += 1
            return
        }
        if audioInput.append(retimed) {
            lastAudioPTS = rebased
        } else {
            droppedAudioCount += 1
        }
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, to seconds: TimeInterval) -> CMSampleBuffer? {
        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        guard timingCount > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount)

        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newBase = CMTime(seconds: seconds, preferredTimescale: originalPTS.timescale)
        let offset = CMTimeSubtract(newBase, originalPTS)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
            }
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        )
        return retimed
    }

    // MARK: Writer setup

    private func ensureWriter(width: Int, height: Int) throws {
        guard writer == nil else { return }
        guard let outputURL else { throw RecordingError.notStarted }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitrate = RecordingOptions.targetBitrate(
            width: width,
            height: height,
            fps: options.fps,
            quality: options.quality,
            codec: options.codec
        )
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(videoInput) else { throw RecordingError.cannotAddInput }
        writer.add(videoInput)

        if options.includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.cannotAddInput }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStart }

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
    }

    // MARK: Rendering

    private func render(
        _ source: CVPixelBuffer,
        into output: CVPixelBuffer,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool
    ) {
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)

        // A full blackout does not need the source frame at all. Avoid a
        // full-resolution Core Image render only to paint over every pixel.
        if !blackoutWholeFrame {
            let image = CIImage(cvPixelBuffer: source)
            ciContext.render(image, to: output)
            // Most frames contain no masks; keep that path GPU-only and avoid a
            // pixel-buffer lock plus CGContext allocation.
            guard !boxes.isEmpty else { return }
        }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        FrameMasker.drawMasks(
            in: context,
            frameSize: CGSize(width: width, height: height),
            boxes: boxes,
            maskMode: maskMode,
            guardMode: guardMode,
            blackoutWholeFrame: blackoutWholeFrame,
            rectMapping: .topLeftToBottomLeft
        )
    }

    // MARK: Metadata

    private func writeMetadata(
        sample: FrameSample,
        pts: TimeInterval,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        isArmed: Bool,
        blackoutWholeFrame: Bool,
        freshness: DetectionFreshness
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        var payload: [String: Any] = [
            "frameID": sample.id,
            "pts": pts,
            "writtenAt": now,
            "frameCapturedAt": sample.capturedAt,
            "guardMode": guardMode.rawValue,
            "maskMode": maskMode.rawValue,
            "armed": isArmed,
            "blackoutWholeFrame": blackoutWholeFrame,
            "boxes": boxes.map { box in
                [
                    "kind": box.kind.rawValue,
                    "source": box.source.rawValue,
                    "matchedLength": box.matched.count,
                    "confidence": box.confidence,
                    "rect": [
                        "x": box.normalizedRect.origin.x,
                        "y": box.normalizedRect.origin.y,
                        "width": box.normalizedRect.width,
                        "height": box.normalizedRect.height,
                    ],
                ] as [String: Any]
            },
        ]
        if let ocrAge = freshness.ocrAge(at: now) {
            payload["ocrAgeMs"] = (ocrAge * 1000).rounded()
        }
        if let axAge = freshness.accessibilityAge(at: now) {
            payload["accessibilityAgeMs"] = (axAge * 1000).rounded()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        metadataBuffer.append(data)
        metadataBuffer.append(0x0A)
        if metadataBuffer.count >= Self.metadataFlushThreshold {
            flushMetadata()
        }
    }

    private func flushMetadata() {
        guard !metadataBuffer.isEmpty else { return }
        metadataHandle?.write(metadataBuffer)
        metadataBuffer.removeAll(keepingCapacity: true)
    }

    private func clear() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        outputURL = nil
        metadataURL = nil
        metadataBuffer.removeAll(keepingCapacity: true)
        sessionStart = nil
        lastAppendedPTS = -.greatestFiniteMagnitude
        lastAudioPTS = -.greatestFiniteMagnitude
        lastAppendedFrameID = 0
        frameCount = 0
        isPaused = false
        pauseOffset = 0
    }
}

enum RecordingError: Error, LocalizedError {
    case notStarted
    case alreadyRecording
    case cannotAddInput
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Recording has not been started."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .cannotAddInput:
            return "Cannot add input to the recorder."
        case .cannotStart:
            return "Cannot start the recorder."
        }
    }
}

extension ISO8601DateFormatter {
    static let filenameFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
