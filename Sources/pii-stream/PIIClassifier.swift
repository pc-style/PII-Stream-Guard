import CoreGraphics
import Foundation

public struct NormalizedText {
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

public struct RecognizedTextFragment {
    public let raw: String
    public let confidence: Float
    public let normalizedRect: CGRect
    public let detectedAt: TimeInterval
    public let boundingBoxForRange: ((Range<String.Index>) -> CGRect?)?

    public init(
        raw: String,
        confidence: Float,
        normalizedRect: CGRect,
        detectedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        boundingBoxForRange: ((Range<String.Index>) -> CGRect?)? = nil
    ) {
        self.raw = raw
        self.confidence = confidence
        self.normalizedRect = normalizedRect
        self.detectedAt = detectedAt
        self.boundingBoxForRange = boundingBoxForRange
    }
}

public struct PIIClassifier {
    private struct PhoneFragment {
        let digits: String
        let rect: CGRect
        public let confidence: Float
        public let detectedAt: TimeInterval
    }

    public let needles: [String]
    public let checkEmail: Bool
    public let checkPhone: Bool

    private let normalizedNeedles: [String]
    private let compactEmailRegex = try! NSRegularExpression(
        pattern: "\\b[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\\.)+[A-Z]{2,}\\b",
        options: [.caseInsensitive]
    )
    private let spacedEmailRegex = try! NSRegularExpression(
        pattern: "\\b[A-Z0-9._%+-]+\\s*@\\s*(?:[A-Z0-9-]+\\s*\\.\\s*)+[A-Z]{2,}\\b",
        options: [.caseInsensitive]
    )
    private let phoneRegex = try! NSRegularExpression(
        pattern: "(?<![A-Z0-9])(?:\\+\\s*\\d{1,3}[\\s.-]*)?(?:\\(\\s*\\d{3}\\s*\\)|\\d{3})[\\s.-]*\\d{3}[\\s.-]*\\d{4}(?![A-Z0-9])",
        options: [.caseInsensitive]
    )

    public init(needles: [String], checkEmail: Bool = true, checkPhone: Bool = true) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        normalizedNeedles = needles.map { $0.lowercased().filter { !$0.isWhitespace } }
    }

    public func classify(_ fragments: [RecognizedTextFragment]) -> [PIIBox] {
        var boxes: [PIIBox] = []
        var phoneFragments: [PhoneFragment] = []
        let shouldMatchNeedles = normalizedNeedles.contains { !$0.isEmpty }

        for fragment in fragments {
            let raw = fragment.raw
            if checkPhone {
                let digits = raw.filter(\.isNumber)
                if (2...6).contains(digits.count) {
                    phoneFragments.append(PhoneFragment(
                        digits: digits,
                        rect: fragment.normalizedRect,
                        confidence: fragment.confidence,
                        detectedAt: fragment.detectedAt
                    ))
                }
            }

            if checkEmail {
                collectEmailBoxes(from: fragment, into: &boxes)
            }
            if checkPhone {
                collectPhoneBoxes(from: fragment, into: &boxes)
            }
            if shouldMatchNeedles {
                collectNeedleBoxes(from: fragment, into: &boxes)
            }
        }

        if checkPhone {
            collectSplitPhoneBoxes(from: phoneFragments, into: &boxes)
        }

        return deduplicated(boxes)
    }

    private func collectEmailBoxes(from fragment: RecognizedTextFragment, into boxes: inout [PIIBox]) {
        let raw = fragment.raw
        let nsRange = NSRange(raw.startIndex..., in: raw)
        for match in spacedEmailRegex.matches(in: raw, range: nsRange) {
            guard let range = Range(match.range, in: raw) else { continue }
            let matched = String(raw[range]).filter { !$0.isWhitespace }.lowercased()
            appendBox(kind: .email, matched: matched, range: range, fragment: fragment, into: &boxes)
        }

        collectWhitespaceSplitEmailBoxes(from: fragment, into: &boxes)
    }

    private func collectWhitespaceSplitEmailBoxes(from fragment: RecognizedTextFragment, into boxes: inout [PIIBox]) {
        let raw = fragment.raw
        let tokens = raw.rangesOfNonWhitespace()
        guard tokens.count >= 2 else { return }

        for start in tokens.indices {
            let maxEnd = min(tokens.index(start, offsetBy: 5, limitedBy: tokens.endIndex) ?? tokens.endIndex, tokens.endIndex)
            if !raw[tokens[start]].contains("@") {
                let next = tokens.index(after: start)
                guard next < tokens.endIndex, raw[tokens[next]].contains("@") else { continue }
            }
            guard tokens[start..<maxEnd].contains(where: { raw[$0].contains("@") }) else { continue }
            var end = tokens.index(after: start)
            var bestMatch: (matched: String, range: Range<String.Index>)?
            while end <= maxEnd {
                let window = tokens[start..<end]
                let compact = window.map { raw[$0] }.joined().lowercased()
                if isWholeEmail(compact), shouldAcceptWhitespaceEmailWindow(window, raw: raw, compact: compact) {
                    let originalRange = tokens[start].lowerBound..<window.last!.upperBound
                    if bestMatch == nil || compact.count > bestMatch!.matched.count {
                        bestMatch = (compact, originalRange)
                    }
                }
                guard end < tokens.endIndex else { break }
                end = tokens.index(after: end)
            }
            if let bestMatch {
                appendBox(kind: .email, matched: bestMatch.matched, range: bestMatch.range, fragment: fragment, into: &boxes)
            }
        }
    }

    private func isWholeEmail(_ value: String) -> Bool {
        let nsRange = NSRange(value.startIndex..., in: value)
        guard let match = compactEmailRegex.firstMatch(in: value, range: nsRange) else { return false }
        return match.range.location == 0 && match.range.length == nsRange.length
    }

    private func shouldAcceptWhitespaceEmailWindow(
        _ window: ArraySlice<Range<String.Index>>,
        raw: String,
        compact: String
    ) -> Bool {
        guard let last = window.last, window.count > 1 else { return true }
        let lastText = raw[last]
        guard !lastText.contains("@"), !lastText.contains(".") else { return true }
        let withoutLast = window.dropLast().map { raw[$0] }.joined().lowercased()
        return !isWholeEmail(withoutLast)
    }

    private func collectPhoneBoxes(from fragment: RecognizedTextFragment, into boxes: inout [PIIBox]) {
        let raw = fragment.raw
        let nsRange = NSRange(raw.startIndex..., in: raw)
        for match in phoneRegex.matches(in: raw, range: nsRange) {
            guard let range = Range(match.range, in: raw),
                  let matched = normalizedPhoneMatch(String(raw[range])) else {
                continue
            }
            appendBox(kind: .phone, matched: matched, range: range, fragment: fragment, into: &boxes)
        }
    }

    private func collectNeedleBoxes(from fragment: RecognizedTextFragment, into boxes: inout [PIIBox]) {
        let raw = fragment.raw
        let normText = NormalizedText.build(from: raw)
        for (idx, needle) in normalizedNeedles.enumerated() where !needle.isEmpty {
            var searchStart = normText.normalized.startIndex
            while searchStart < normText.normalized.endIndex,
                  let range = normText.normalized.range(of: needle, range: searchStart..<normText.normalized.endIndex) {
                if let originalRange = normText.originalRange(for: range, in: raw) {
                    appendBox(kind: .needle, matched: needles[idx], range: originalRange, fragment: fragment, into: &boxes)
                }
                searchStart = range.upperBound
            }
        }
    }

    private func appendBox(
        kind: PIIKind,
        matched: String,
        range: Range<String.Index>,
        fragment: RecognizedTextFragment,
        into boxes: inout [PIIBox]
    ) {
        boxes.append(PIIBox(
            kind: kind,
            matched: matched,
            confidence: fragment.confidence,
            normalizedRect: fragment.boundingBoxForRange?(range) ?? paddedRect(fragment.normalizedRect),
            detectedAt: fragment.detectedAt
        ))
    }

    private func normalizedPhoneMatch(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 10, digits.count <= 15 else { return nil }
        let hasLeadingPlus = raw.first { !$0.isWhitespace } == "+"
        return hasLeadingPlus ? "+\(digits)" : digits
    }

    private func collectSplitPhoneBoxes(from fragments: [PhoneFragment], into boxes: inout [PIIBox]) {
        let candidates = fragments
            .filter { $0.digits.count == 3 || $0.digits.count == 4 }
            .sorted {
                if abs($0.rect.midY - $1.rect.midY) > 0.02 {
                    return $0.rect.midY > $1.rect.midY
                }
                return $0.rect.minX < $1.rect.minX
            }

        guard candidates.count >= 3 else { return }

        for i in 0..<(candidates.count - 2) {
            let a = candidates[i]
            let b = candidates[i + 1]
            let c = candidates[i + 2]
            guard a.digits.count == 3, b.digits.count == 3, c.digits.count == 4 else { continue }
            guard sameTextRow(a.rect, b.rect), sameTextRow(b.rect, c.rect) else { continue }
            guard reasonableSplitPhoneGap(a.rect, b.rect), reasonableSplitPhoneGap(b.rect, c.rect) else { continue }

            boxes.append(PIIBox(
                kind: .phone,
                matched: a.digits + b.digits + c.digits,
                confidence: min(a.confidence, b.confidence, c.confidence),
                normalizedRect: a.rect.union(b.rect).union(c.rect),
                detectedAt: max(a.detectedAt, b.detectedAt, c.detectedAt)
            ))
        }
    }

    private func sameTextRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance = max(lhs.height, rhs.height) * 1.8 + 0.01
        return abs(lhs.midY - rhs.midY) <= tolerance
    }

    private func reasonableSplitPhoneGap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let gap = rhs.minX - lhs.maxX
        guard gap >= -0.01 else { return false }
        return gap <= max(lhs.width, rhs.width) * 4 + 0.08
    }

    private func deduplicated(_ boxes: [PIIBox]) -> [PIIBox] {
        let boxes = boxes.filter { box in
            guard box.kind == .email else { return true }
            return !boxes.contains { other in
                other.kind == .email
                    && other.matched.count > box.matched.count
                    && other.matched.contains(box.matched)
                    && rectOverlap(box.normalizedRect, other.normalizedRect) >= 0.75
            }
        }

        var bestByKey: [String: PIIBox] = [:]
        for box in boxes {
            let key = "\(box.identityKey):\(coarseRectBucket(box.normalizedRect))"
            if let existing = bestByKey[key], existing.confidence >= box.confidence {
                continue
            }
            bestByKey[key] = box
        }
        return boxes.compactMap { box in
            let key = "\(box.identityKey):\(coarseRectBucket(box.normalizedRect))"
            guard bestByKey[key]?.confidence == box.confidence else { return nil }
            let selected = bestByKey[key]
            bestByKey[key] = nil
            return selected
        }
    }

    private func coarseRectBucket(_ rect: CGRect) -> String {
        [rect.origin.x, rect.origin.y, rect.width, rect.height]
            .map { String(Int(($0 * 50).rounded())) }
            .joined(separator: ",")
    }

    private func rectOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let smallerArea = min(a.width * a.height, b.width * b.height)
        guard smallerArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / smallerArea
    }

    private func paddedRect(_ rect: CGRect, padding: CGFloat = 0.02) -> CGRect {
        var r = rect
        r.origin.x = max(0, r.origin.x - padding)
        r.origin.y = max(0, r.origin.y - padding)
        r.size.width = min(1 - r.origin.x, r.size.width + padding * 2)
        r.size.height = min(1 - r.origin.y, r.size.height + padding * 2)
        return r
    }
}

private extension String {
    func rangesOfNonWhitespace() -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?

        for index in indices {
            if self[index].isWhitespace {
                if let tokenStart = start {
                    ranges.append(tokenStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }

        if let tokenStart = start {
            ranges.append(tokenStart..<endIndex)
        }
        return ranges
    }
}
