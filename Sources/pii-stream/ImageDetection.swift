import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

public struct DetectImageOptions {
    public var imagePath: String
    public var needles: [String]
    public var checkEmail: Bool
    public var checkPhone: Bool
    public var mode: GuardMode
    public var settingsOverride: DetectorSettings?
    /// When set, write the protected PNG here; otherwise derive `*-protected.png` beside the source.
    public var outputPath: String?
    public var attribution: ImageAttributionStyle
    public var presentation: ImageOutputPresentation

    public init(
        imagePath: String,
        needles: [String] = [],
        checkEmail: Bool = true,
        checkPhone: Bool = true,
        mode: GuardMode = .standard,
        settingsOverride: DetectorSettings? = nil,
        outputPath: String? = nil,
        attribution: ImageAttributionStyle = .badge,
        presentation: ImageOutputPresentation = .standard
    ) {
        self.imagePath = imagePath
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        self.mode = mode
        self.settingsOverride = settingsOverride
        self.outputPath = outputPath
        self.attribution = attribution
        self.presentation = presentation
    }
}

public struct ImageDetectionRunner {
    let options: DetectImageOptions

    public init(options: DetectImageOptions) {
        self.options = options
    }

    public func run() throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let buffer = try loadPixelBuffer(path: options.imagePath)
        var runOptions = options
        if runOptions.needles.isEmpty {
            runOptions.needles = Self.defaultSecretNeedles
        }
        let detector = DetectionRecipe.imageDetection(runOptions).makeDetector()
        let rawBoxes = detector.detect(in: buffer)
        let boxes = ImageDetectionPostProcess.boxesForProtectedImage(rawBoxes)
        let savedPath = try writeProtectedImage(buffer: buffer, boxes: boxes)
        let ended = DispatchTime.now().uptimeNanoseconds
        let output = ImageDetectionOutput(
            imagePath: options.imagePath,
            savedImagePath: savedPath,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            detections: rawBoxes.map(ImageDetectionOutput.Detection.init(box:)),
            latencyMs: Double(ended - started) / 1_000_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func writeProtectedImage(buffer: CVPixelBuffer, boxes: [PIIBox]) throws -> String {
        let path = options.outputPath ?? Self.defaultProtectedPath(for: options.imagePath)
        let attribution: ImageAttributionStyle = options.presentation == .demo ? .none : options.attribution
        let protected = try FrameCodec.protectedCGImage(
            from: buffer,
            boxes: boxes,
            guardMode: options.mode,
            maskMode: .blackout,
            blackoutWholeFrame: false,
            attribution: attribution,
            presentation: options.presentation
        )
        let bitmap = NSBitmapImageRep(cgImage: protected)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageDetectionError.cannotWriteProtectedImage(path)
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
        return path
    }

    /// OCR-friendly needles for terminal deploy keys when the caller passes none.
    static let defaultSecretNeedles = ["eyJ", "dev:", "rugged-gnat"]

    static func defaultProtectedPath(for imagePath: String) -> String {
        let url = URL(fileURLWithPath: imagePath)
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().path
        return (dir as NSString).appendingPathComponent("\(base)-protected.png")
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
    let savedImagePath: String
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
    case cannotWriteProtectedImage(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let path):
            return "Could not read image at \(path)."
        case .pixelBufferCreateFailed(let status):
            return "Could not create image pixel buffer: CVReturn \(status)."
        case .cannotWriteProtectedImage(let path):
            return "Could not write protected image to \(path)."
        }
    }
}
