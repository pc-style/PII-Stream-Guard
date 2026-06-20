import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct DetectImageOptions {
    var imagePath: String
    var needles: [String] = []
    var checkEmail: Bool = true
    var checkPhone: Bool = true
    var mode: GuardMode = .standard
    var settingsOverride: DetectorSettings?
}

struct ImageDetectionRunner {
    let options: DetectImageOptions

    func run() throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let buffer = try loadPixelBuffer(path: options.imagePath)
        let settings = options.settingsOverride ?? options.mode.detectorSettings
        let detector = VisionPIIDetector(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            accurate: settings.accurate,
            maxPixelSize: settings.maxPixelSize,
            minimumTextHeight: settings.minimumTextHeight,
            enhanceLowContrast: settings.enhanceLowContrast
        )
        let boxes = detector.detect(in: buffer)
        let ended = DispatchTime.now().uptimeNanoseconds
        let output = ImageDetectionOutput(
            imagePath: options.imagePath,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            detections: boxes.map(ImageDetectionOutput.Detection.init(box:)),
            latencyMs: Double(ended - started) / 1_000_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func loadPixelBuffer(path: String) throws -> CVPixelBuffer {
        let url = URL(fileURLWithPath: path)
        guard let image = CIImage(contentsOf: url) else {
            throw ImageDetectionError.unreadableImage(path)
        }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else {
            throw ImageDetectionError.unreadableImage(path)
        }

        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(extent.width),
            Int(extent.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ImageDetectionError.pixelBufferCreateFailed(status)
        }

        CIContext(options: [.useSoftwareRenderer: false]).render(image, to: buffer)
        return buffer
    }
}

private struct ImageDetectionOutput: Encodable {
    let imagePath: String
    let width: Int
    let height: Int
    let detections: [Detection]
    let latencyMs: Double

    struct Detection: Encodable {
        let kind: String
        let matched: String
        let confidence: Float
        let normalizedRect: Rect

        init(box: PIIBox) {
            kind = box.kind.rawValue
            matched = box.matched
            confidence = box.confidence
            normalizedRect = Rect(box.normalizedRect)
        }
    }

    struct Rect: Encodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }
}

enum ImageDetectionError: Error, LocalizedError {
    case unreadableImage(String)
    case pixelBufferCreateFailed(CVReturn)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let path):
            return "Could not read image at \(path)."
        case .pixelBufferCreateFailed(let status):
            return "Could not create image pixel buffer: CVReturn \(status)."
        }
    }
}
