import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class PreviewRecorder {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var metadataHandle: FileHandle?
    private var frameIndex: Int64 = 0
    private var lastAppendAt: TimeInterval = 0
    private var outputURL: URL?

    var isRecording: Bool {
        writer != nil
    }

    func start() throws -> URL {
        let directory = URL(fileURLWithPath: "recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("pii-stream-preview-\(stamp).mov")
        let metadataURL = directory.appendingPathComponent("pii-stream-preview-\(stamp).jsonl")
        FileManager.default.createFile(atPath: metadataURL.path, contents: nil)
        metadataHandle = try FileHandle(forWritingTo: metadataURL)
        outputURL = url
        return url
    }

    func stop() {
        metadataHandle?.closeFile()
        metadataHandle = nil

        guard let writer, let input else {
            clear()
            return
        }

        input.markAsFinished()
        writer.finishWriting { _ = writer.status }
        clear()
    }

    func append(
        sample: FrameSample,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        isArmed: Bool,
        blackoutWholeFrame: Bool
    ) {
        guard metadataHandle != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAppendAt >= 1.0 / 30.0 else { return }
        lastAppendAt = now

        do {
            try ensureWriter(width: Int(sample.frameSize.width), height: Int(sample.frameSize.height))
        } catch {
            fputs("Recording failed to start: \(error.localizedDescription)\n", stderr)
            stop()
            return
        }

        guard let writer, let input, let adaptor, writer.status == .writing, input.isReadyForMoreMediaData else {
            return
        }
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
        let time = CMTime(value: frameIndex, timescale: 30)
        if adaptor.append(output, withPresentationTime: time) {
            frameIndex += 1
            writeMetadata(
                sample: sample,
                boxes: boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                isArmed: isArmed,
                blackoutWholeFrame: blackoutWholeFrame
            )
        }
    }

    private func ensureWriter(width: Int, height: Int) throws {
        guard writer == nil else { return }
        guard let outputURL else { throw RecordingError.notStarted }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else { throw RecordingError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStart }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        frameIndex = 0
    }

    private func render(
        _ source: CVPixelBuffer,
        into output: CVPixelBuffer,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        blackoutWholeFrame: Bool
    ) {
        let image = CIImage(cvPixelBuffer: source)
        ciContext.render(image, to: output)

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return }

        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        if blackoutWholeFrame {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return
        }

        for box in boxes {
            var rect = FrameMasker.pixelRect(from: box.normalizedRect, frameSize: CGSize(width: width, height: height))
            if maskMode == .blackout, FrameMasker.usesBuiltInMasking(for: guardMode) {
                rect = FrameMasker.builtInBlackoutRect(
                    rect,
                    within: CGRect(x: 0, y: 0, width: width, height: height)
                )
            }
            let drawRect = CGRect(
                x: rect.origin.x,
                y: CGFloat(height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            switch maskMode {
            case .blackout:
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(drawRect)
            case .boundingBox:
                context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.setLineWidth(4)
                context.stroke(drawRect)
            }
        }
    }

    private func writeMetadata(
        sample: FrameSample,
        boxes: [PIIBox],
        maskMode: MaskMode,
        guardMode: GuardMode,
        isArmed: Bool,
        blackoutWholeFrame: Bool
    ) {
        let payload: [String: Any] = [
            "frameID": sample.id,
            "displayedAt": ProcessInfo.processInfo.systemUptime,
            "frameCapturedAt": sample.capturedAt,
            "guardMode": guardMode.rawValue,
            "maskMode": maskMode.rawValue,
            "armed": isArmed,
            "blackoutWholeFrame": blackoutWholeFrame,
            "boxes": boxes.map { box in
                [
                    "kind": box.kind.rawValue,
                    "matchedLength": box.matched.count,
                    "confidence": box.confidence,
                    "rect": [
                        "x": box.normalizedRect.origin.x,
                        "y": box.normalizedRect.origin.y,
                        "width": box.normalizedRect.width,
                        "height": box.normalizedRect.height,
                    ],
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        metadataHandle?.write(data)
        metadataHandle?.write(Data("\n".utf8))
    }


    private func clear() {
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        frameIndex = 0
        lastAppendAt = 0
    }
}

enum RecordingError: Error, LocalizedError {
    case notStarted
    case cannotAddInput
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Recording has not been started."
        case .cannotAddInput:
            return "Cannot add video input to the recorder."
        case .cannotStart:
            return "Cannot start the recorder."
        }
    }
}

private extension ISO8601DateFormatter {
    static let filenameFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
