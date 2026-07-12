import ApplicationServices
import CoreGraphics
import Foundation

/// Discovers on-screen text through the macOS Accessibility tree of the apps
/// visible inside the capture target, classifies it with the same
/// `PIIClassifier` used for OCR, and emits `PIIBox`es tagged with
/// `.accessibility` in the same Vision-style normalized coordinate model
/// (bottom-left origin, 0-1).
///
/// Best-effort by design: apps with poor AX support simply contribute
/// nothing, and OCR remains the authority. Scans are bounded by element and
/// wall-clock budgets so a pathological tree cannot stall the detection queue.
final class AccessibilityTextScanner {
    private let classifier: PIIClassifier
    private let maxElements = 1500
    private let maxDepth = 15
    private let maxScanDuration: TimeInterval = 0.15
    private let maxApps = 6
    private let maxValueLength = 4000

    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    init(classifier: PIIClassifier) {
        self.classifier = classifier
    }

    struct ScanResult {
        let boxes: [PIIBox]
        let visitedElements: Int
        let exhaustedBudget: Bool
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission if not yet trusted.
    static func requestTrustIfNeeded() {
        guard !isTrusted else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Scans apps whose windows intersect the capture region and returns PII
    /// boxes normalized to the captured frame. Returns nil when the scan could
    /// not run at all (no permission), as opposed to an empty result.
    func scan(geometry: CaptureGeometry, windowTarget: CGWindowID?) -> [PIIBox]? {
        guard Self.isTrusted else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + maxScanDuration

        let candidates = candidateApps(geometry: geometry, windowTarget: windowTarget)

        // Window capture follows the window when it moves, but the geometry
        // captured at stream start does not. Use the window's live bounds so
        // AX boxes stay aligned with the captured frame.
        var geometry = geometry
        if windowTarget != nil, let liveRect = candidates.liveTargetRect {
            geometry = CaptureGeometry(
                globalRect: liveRect,
                outputSize: geometry.outputSize,
                targetDescription: geometry.targetDescription
            )
        }

        var fragments: [RecognizedTextFragment] = []
        var elementBudget = maxElements

        for (pid, windowRects) in candidates.apps {
            guard elementBudget > 0, ProcessInfo.processInfo.systemUptime < deadline else { break }
            let appElement = AXUIElementCreateApplication(pid)
            guard let axWindows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for axWindow in axWindows {
                guard elementBudget > 0, ProcessInfo.processInfo.systemUptime < deadline else { break }
                guard let windowRect = elementGlobalRect(axWindow) else { continue }
                // Only walk AX windows that correspond to on-screen CG windows
                // inside the capture region.
                guard windowRects.contains(where: { $0.intersects(windowRect) }) else { continue }
                walk(
                    element: axWindow,
                    depth: 0,
                    geometry: geometry,
                    deadline: deadline,
                    budget: &elementBudget,
                    fragments: &fragments
                )
            }
        }

        return classifier.classify(fragments).map { box in
            PIIBox(
                kind: box.kind,
                matched: box.matched,
                confidence: box.confidence,
                normalizedRect: box.normalizedRect,
                detectedAt: box.detectedAt,
                source: .accessibility
            )
        }
    }

    /// Extracts one event element, application, or window on the caller's AX
    /// worker. The element never leaves that worker, and both the wall-clock
    /// and element counts are bounded.
    func scan(
        root: AXUIElement,
        geometry: CaptureGeometry,
        maxDuration: TimeInterval = 0.10,
        maxElements: Int? = nil
    ) -> ScanResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + min(max(0.01, maxDuration), maxScanDuration)
        let initialBudget = min(max(1, maxElements ?? self.maxElements), self.maxElements)
        var budget = initialBudget
        var fragments: [RecognizedTextFragment] = []
        walk(
            element: root,
            depth: 0,
            geometry: geometry,
            deadline: deadline,
            budget: &budget,
            fragments: &fragments
        )
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let boxes = classifier.classify(fragments).map { box in
            PIIBox(
                kind: box.kind,
                matched: box.matched,
                confidence: box.confidence,
                normalizedRect: box.normalizedRect,
                detectedAt: box.detectedAt,
                source: .accessibility
            )
        }
        return ScanResult(
            boxes: boxes,
            visitedElements: initialBudget - budget,
            exhaustedBudget: budget == 0 || finishedAt >= deadline
        )
    }

    // MARK: Candidate discovery

    /// Returns PIDs of apps with on-screen windows intersecting the capture
    /// region, front-to-back, with the global rects of those windows. For a
    /// window target, also returns that window's live bounds.
    private func candidateApps(
        geometry: CaptureGeometry,
        windowTarget: CGWindowID?
    ) -> (apps: [(pid_t, [CGRect])], liveTargetRect: CGRect?) {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return ([], nil)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var order: [pid_t] = []
        var rectsByPID: [pid_t: [CGRect]] = [:]
        var liveTargetRect: CGRect?

        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            if let windowTarget,
               let number = entry[kCGWindowNumber as String] as? CGWindowID,
               number != windowTarget {
                continue
            }
            let rect = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if windowTarget != nil {
                liveTargetRect = rect
            } else {
                guard rect.intersects(geometry.globalRect) else { continue }
            }
            if rectsByPID[pid] == nil {
                order.append(pid)
            }
            rectsByPID[pid, default: []].append(rect)
        }

        return (order.prefix(maxApps).map { ($0, rectsByPID[$0] ?? []) }, liveTargetRect)
    }

    // MARK: Tree walk

    private func walk(
        element: AXUIElement,
        depth: Int,
        geometry: CaptureGeometry,
        deadline: TimeInterval,
        budget: inout Int,
        fragments: inout [RecognizedTextFragment]
    ) {
        guard depth <= maxDepth, budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
        budget -= 1

        if let role = copyAttribute(element, kAXRoleAttribute) as? String,
           Self.textRoles.contains(role) {
            collectText(from: element, geometry: geometry, fragments: &fragments)
        }

        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
            walk(
                element: child,
                depth: depth + 1,
                geometry: geometry,
                deadline: deadline,
                budget: &budget,
                fragments: &fragments
            )
        }
    }

    private func collectText(
        from element: AXUIElement,
        geometry: CaptureGeometry,
        fragments: inout [RecognizedTextFragment]
    ) {
        guard let globalRect = elementGlobalRect(element),
              globalRect.intersects(geometry.globalRect) else { return }
        guard let normalizedRect = Self.normalizedRect(globalRect: globalRect, in: geometry.globalRect) else { return }

        var texts: [String] = []
        if let value = copyAttribute(element, kAXValueAttribute) as? String, !value.isEmpty {
            texts.append(value)
        }
        if let title = copyAttribute(element, kAXTitleAttribute) as? String, !title.isEmpty {
            texts.append(title)
        }

        let now = ProcessInfo.processInfo.systemUptime
        for text in texts {
            guard text.count <= maxValueLength else { continue }
            let capturedElement = element
            let capturedGeometry = geometry
            fragments.append(RecognizedTextFragment(
                raw: text,
                confidence: 1.0,
                normalizedRect: normalizedRect,
                detectedAt: now,
                boundingBoxForRange: { range in
                    Self.boundingBox(
                        for: range,
                        in: text,
                        element: capturedElement,
                        elementGlobalRect: globalRect,
                        elementNormalizedRect: normalizedRect,
                        geometry: capturedGeometry
                    )
                }
            ))
        }
    }

    // MARK: Bounds

    /// Bounds for a matched sub-range: precise AX bounds-for-range when the
    /// element supports it, a proportional horizontal slice for single-line
    /// text, or the whole element rect (safe over-mask) for multi-line text.
    private static func boundingBox(
        for range: Range<String.Index>,
        in text: String,
        element: AXUIElement,
        elementGlobalRect: CGRect,
        elementNormalizedRect: CGRect,
        geometry: CaptureGeometry
    ) -> CGRect? {
        let location = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)

        var cfRange = CFRange(location: location, length: length)
        if let rangeValue = AXValueCreate(.cfRange, &cfRange) {
            var boundsRef: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsRef
            )
            if error == .success,
               let boundsRef,
               CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
                   rect.width > 0, rect.height > 0,
                   let normalized = normalizedRect(globalRect: rect, in: geometry.globalRect) {
                    return normalized
                }
            }
        }

        guard !text.contains(where: \.isNewline), !text.isEmpty else {
            return elementNormalizedRect
        }
        let total = CGFloat(text.count)
        let startFraction = CGFloat(location) / total
        let widthFraction = CGFloat(length) / total
        return CGRect(
            x: elementNormalizedRect.origin.x + elementNormalizedRect.width * startFraction,
            y: elementNormalizedRect.origin.y,
            width: elementNormalizedRect.width * widthFraction,
            height: elementNormalizedRect.height
        )
    }

    private func elementGlobalRect(_ element: AXUIElement) -> CGRect? {
        guard let positionRef = copyAttribute(element, kAXPositionAttribute),
              let sizeRef = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Converts a global-screen rect (points, top-left origin) into the
    /// Vision-style normalized rect (bottom-left origin) used by `PIIBox`.
    static func normalizedRect(globalRect: CGRect, in captureRect: CGRect) -> CGRect? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        let clipped = globalRect.intersection(captureRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let nx = (clipped.minX - captureRect.minX) / captureRect.width
        let nyTop = (clipped.minY - captureRect.minY) / captureRect.height
        let nw = clipped.width / captureRect.width
        let nh = clipped.height / captureRect.height
        return CGRect(x: nx, y: 1 - nyTop - nh, width: nw, height: nh)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }
}
