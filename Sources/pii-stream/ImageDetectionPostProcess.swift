import CoreGraphics
import Foundation

enum ImageDetectionPostProcess {
    /// Filters OCR hallucinations and adds targeted terminal-line masks for static images.
    static func boxesForProtectedImage(_ boxes: [PIIBox]) -> [PIIBox] {
        let filtered = boxes.filter { isPlausibleDetection($0) }
        if let consolidated = consolidatedSecretBand(from: filtered) {
            var masks = [consolidated]
            masks.append(contentsOf: filtered.filter { $0.kind == .email || $0.kind == .phone })
            return masks
        }

        var expanded: [PIIBox] = []
        var addedSecretLineBelow = false
        for box in filtered {
            switch box.kind {
            case .needle:
                if isNarrowLabelNeedle(box) {
                    if !addedSecretLineBelow, let below = secretOutputLineBelow(box) {
                        expanded.append(below)
                        addedSecretLineBelow = true
                    }
                } else {
                    expanded.append(fullWidthRowMask(from: box))
                }
            case .email, .phone:
                expanded.append(box)
            }
        }
        return dedupeOverlapping(expanded)
    }

    private static func consolidatedSecretBand(from boxes: [PIIBox]) -> PIIBox? {
        let secrets = boxes.filter { $0.kind == .needle && isLikelyDeployTokenLine($0) }
        guard let anchor = secrets.max(by: { $0.normalizedRect.width < $1.normalizedRect.width }) else {
            return nil
        }
        let rowH: CGFloat = 0.07
        let y = max(0, anchor.normalizedRect.origin.y - 0.01)
        return PIIBox(
            kind: .needle,
            matched: anchor.matched,
            confidence: anchor.confidence,
            normalizedRect: CGRect(x: 0.01, y: y, width: 0.98, height: min(1 - y, rowH)),
            detectedAt: anchor.detectedAt
        )
    }

    private static func isLikelyDeployTokenLine(_ box: PIIBox) -> Bool {
        let m = box.matched.lowercased()
        if m.hasPrefix("eyj") { return true }
        if m.contains("|") { return true }
        if box.normalizedRect.width > 0.45 { return true }
        return false
    }

    private static func isNarrowLabelNeedle(_ box: PIIBox) -> Bool {
        box.normalizedRect.width < 0.35 && box.matched.count <= 24
    }

    private static func isPlausibleDetection(_ box: PIIBox) -> Bool {
        guard box.kind == .email else { return true }
        let matched = box.matched.lowercased()
        guard let at = matched.firstIndex(of: "@") else { return false }
        let domain = matched[matched.index(after: at)...]
        // Vision often invents `*@email.com` on terminal lines that mention "key".
        if domain == "email.com" {
            return false
        }
        if box.confidence < 0.55 {
            return false
        }
        return true
    }

    private static func secretOutputLineBelow(_ label: PIIBox) -> PIIBox? {
        let row = max(0.016, label.normalizedRect.height * 1.1)
        let gap: CGFloat = 0.004
        let y = label.normalizedRect.origin.y - row - gap
        guard y >= 0 else { return nil }
        return PIIBox(
            kind: label.kind,
            matched: label.matched,
            confidence: label.confidence,
            normalizedRect: fullWidthRowMask(from: label, overrideY: y, overrideHeight: row + gap).normalizedRect,
            detectedAt: label.detectedAt
        )
    }

    private static func fullWidthRowMask(from box: PIIBox, overrideY: CGFloat? = nil, overrideHeight: CGFloat? = nil) -> PIIBox {
        let padY: CGFloat = 0.006
        let y = overrideY ?? max(0, box.normalizedRect.origin.y - padY)
        let h = overrideHeight ?? min(1 - y, box.normalizedRect.height + padY * 2)
        let rect = CGRect(x: 0.02, y: y, width: 0.96, height: max(h, 0.026))
        return PIIBox(
            kind: box.kind,
            matched: box.matched,
            confidence: box.confidence,
            normalizedRect: rect,
            detectedAt: box.detectedAt
        )
    }

    private static func dedupeOverlapping(_ boxes: [PIIBox]) -> [PIIBox] {
        var result: [PIIBox] = []
        for box in boxes.sorted(by: { $0.normalizedRect.width > $1.normalizedRect.width }) {
            if let idx = result.firstIndex(where: { overlapsRow($0.normalizedRect, box.normalizedRect) && $0.kind == box.kind }) {
                let merged = result[idx]
                let keep = merged.normalizedRect.width >= box.normalizedRect.width ? merged : box
                result[idx] = PIIBox(
                    kind: keep.kind,
                    matched: keep.matched,
                    confidence: max(merged.confidence, box.confidence),
                    normalizedRect: keep.normalizedRect,
                    detectedAt: max(merged.detectedAt, box.detectedAt)
                )
            } else {
                result.append(box)
            }
        }
        return result
    }

    private static func overlapsRow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) <= max(a.height, b.height) * 1.5 + 0.012
    }
}