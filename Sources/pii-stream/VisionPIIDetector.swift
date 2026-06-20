import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

struct NormalizedText {
    let normalized: String
    let map: [String.Index]

    static func build(from raw: String) -> NormalizedText {
        var normalized = ""
        var map: [String.Index] = []
        for idx in raw.indices {
            let ch = raw[idx]
            if ch.isWhitespace { continue }
            normalized.append(Character(String(ch).lowercased()))
            map.append(idx)
        }
        return NormalizedText(normalized: normalized, map: map)
    }

    func originalRange(for needleRange: Range<String.Index>, in raw: String) -> Range<String.Index>? {
        let startOffset = normalized.distance(from: normalized.startIndex, to: needleRange.lowerBound)
        let endOffset = normalized.distance(from: normalized.startIndex, to: needleRange.upperBound) - 1
        guard startOffset >= 0, endOffset >= startOffset, endOffset < map.count else { return nil }
        let startIdx = map[startOffset]
        let endIdx = map[endOffset]
        return startIdx..<raw.index(after: endIdx)
    }
}

struct VisionPIIDetector: PIIDetector {
    let needles: [String]
    let checkEmail: Bool
    let accurate: Bool
    let maxPixelSize: CGFloat
    let minimumTextHeight: Float

    private let emailRegex = try! NSRegularExpression(
        pattern: "\\b[A-Z0-9._%+-]+\\s*@\\s*(?:[A-Z0-9-]+\\s*\\.\\s*)+[A-Z]{2,}\\b",
        options: [.caseInsensitive]
    )

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(
        needles: [String],
        checkEmail: Bool = true,
        accurate: Bool = false,
        maxPixelSize: CGFloat = 1440,
        minimumTextHeight: Float = 0.012
    ) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.accurate = accurate
        self.maxPixelSize = maxPixelSize
        self.minimumTextHeight = minimumTextHeight
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [PIIBox] {
        let scaled = downscale(pixelBuffer)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight

        let handler = VNImageRequestHandler(cvPixelBuffer: scaled, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let now = ProcessInfo.processInfo.systemUptime
        let normalizedNeedles = needles.map { $0.lowercased().filter { !$0.isWhitespace } }
        var boxes: [PIIBox] = []

        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let raw = candidate.string
            let confidence = candidate.confidence

            if checkEmail {
                collectEmailBoxes(
                    from: raw,
                    candidate: candidate,
                    observation: observation,
                    confidence: confidence,
                    detectedAt: now,
                    into: &boxes
                )
            }

            let normText = NormalizedText.build(from: raw)
            for (idx, needle) in normalizedNeedles.enumerated() where !needle.isEmpty {
                var searchStart = normText.normalized.startIndex
                while searchStart < normText.normalized.endIndex,
                      let range = normText.normalized.range(of: needle, range: searchStart..<normText.normalized.endIndex) {
                    if let originalRange = normText.originalRange(for: range, in: raw) {
                        appendBox(
                            kind: .needle,
                            matched: needles[idx],
                            confidence: confidence,
                            detectedAt: now,
                            raw: raw,
                            originalRange: originalRange,
                            candidate: candidate,
                            observation: observation,
                            into: &boxes
                        )
                    }
                    searchStart = range.upperBound
                }
            }
        }

        return boxes
    }

    private func collectEmailBoxes(
        from raw: String,
        candidate: VNRecognizedText,
        observation: VNRecognizedTextObservation,
        confidence: Float,
        detectedAt: TimeInterval,
        into boxes: inout [PIIBox]
    ) {
        let nsRange = NSRange(raw.startIndex..., in: raw)
        for match in emailRegex.matches(in: raw, range: nsRange) {
            guard let range = Range(match.range, in: raw) else { continue }
            let matched = String(raw[range]).filter { !$0.isWhitespace }
            appendBox(
                kind: .email,
                matched: matched,
                confidence: confidence,
                detectedAt: detectedAt,
                raw: raw,
                originalRange: range,
                candidate: candidate,
                observation: observation,
                into: &boxes
            )
        }
    }

    private func appendBox(
        kind: PIIKind,
        matched: String,
        confidence: Float,
        detectedAt: TimeInterval,
        raw: String,
        originalRange: Range<String.Index>,
        candidate: VNRecognizedText,
        observation: VNRecognizedTextObservation,
        into boxes: inout [PIIBox]
    ) {
        if let boxObs = try? candidate.boundingBox(for: originalRange) {
            boxes.append(PIIBox(
                kind: kind,
                matched: matched,
                confidence: confidence,
                normalizedRect: boxObs.boundingBox,
                detectedAt: detectedAt
            ))
            return
        }

        let padded = paddedRect(observation.boundingBox)
        boxes.append(PIIBox(
            kind: kind,
            matched: matched,
            confidence: confidence,
            normalizedRect: padded,
            detectedAt: detectedAt
        ))
    }

    private func paddedRect(_ rect: CGRect, padding: CGFloat = 0.02) -> CGRect {
        var r = rect
        r.origin.x = max(0, r.origin.x - padding)
        r.origin.y = max(0, r.origin.y - padding)
        r.size.width = min(1 - r.origin.x, r.size.width + padding * 2)
        r.size.height = min(1 - r.origin.y, r.size.height + padding * 2)
        return r
    }

    private func downscale(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let longest = max(width, height)
        guard longest > maxPixelSize else { return buffer }

        let scale = maxPixelSize / longest
        let newWidth = Int((width * scale).rounded())
        let newHeight = Int((height * scale).rounded())

        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            newWidth,
            newHeight,
            CVPixelBufferGetPixelFormatType(buffer),
            attrs as CFDictionary,
            &output
        )
        guard let out = output else { return buffer }

        let inputImage = CIImage(cvPixelBuffer: buffer)
        let scaled = inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(scaled, to: out)
        return out
    }
}
