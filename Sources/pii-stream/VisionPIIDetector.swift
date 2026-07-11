import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

struct VisionPIIDetector: PIIDetector {
    let needles: [String]
    let checkEmail: Bool
    let checkPhone: Bool
    let accurate: Bool
    let maxPixelSize: CGFloat
    let minimumTextHeight: Float
    let enhanceLowContrast: Bool

    private let classifier: PIIClassifier
    private let request: VNRecognizeTextRequest
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(
        needles: [String],
        checkEmail: Bool = true,
        checkPhone: Bool = true,
        accurate: Bool = false,
        maxPixelSize: CGFloat = 1440,
        minimumTextHeight: Float = 0.012,
        enhanceLowContrast: Bool = false
    ) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        self.accurate = accurate
        self.maxPixelSize = maxPixelSize
        self.minimumTextHeight = minimumTextHeight
        self.enhanceLowContrast = enhanceLowContrast
        classifier = PIIClassifier(needles: needles, checkEmail: checkEmail, checkPhone: checkPhone)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        self.request = request
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [PIIBox] {
        let scaled = prepareForOCR(pixelBuffer)

        let handler = VNImageRequestHandler(cvPixelBuffer: scaled, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let now = ProcessInfo.processInfo.systemUptime
        // Alternative candidates triple classification and range-box work. Fast
        // OCR is optimized for cadence, while accurate/lockdown mode keeps the
        // broader candidate search for maximum recall.
        let candidateCount = accurate ? 3 : 1
        let fragments = (request.results ?? []).flatMap { observation in
            observation.topCandidates(candidateCount).map { candidate in
                RecognizedTextFragment(
                    raw: candidate.string,
                    confidence: candidate.confidence,
                    normalizedRect: observation.boundingBox,
                    detectedAt: now,
                    boundingBoxForRange: { range in
                        try? candidate.boundingBox(for: range)?.boundingBox
                    }
                )
            }
        }
        return classifier.classify(fragments)
    }

    private func prepareForOCR(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let longest = max(width, height)
        let scale = longest > maxPixelSize ? maxPixelSize / longest : 1
        let newWidth = Int((width * scale).rounded())
        let newHeight = Int((height * scale).rounded())

        guard scale != 1 || enhanceLowContrast else { return buffer }

        guard let out = PixelBufferUtils.makeBuffer(
            width: newWidth,
            height: newHeight,
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer)
        ) else { return buffer }

        var image = CIImage(cvPixelBuffer: buffer)
        if enhanceLowContrast {
            image = image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputContrastKey: 1.45,
                    kCIInputBrightnessKey: 0.02,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: 0.75,
                ])
        }
        let prepared = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(prepared, to: out)
        return out
    }
}
