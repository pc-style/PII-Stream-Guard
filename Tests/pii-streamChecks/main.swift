import CoreGraphics
import Foundation
@testable import pii_stream

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func checkClassifier() {
    let emailBoxes = PIIClassifier(needles: []).classify([
        RecognizedTextFragment(raw: "Contact jane @ example.com today", confidence: 0.9, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
    ])
    check(emailBoxes.count == 1, "expected one email box")
    check(emailBoxes.first?.kind == .email, "expected email kind")
    check(emailBoxes.first?.matched == "jane@example.com", "expected whitespace-normalized email")

    let spacedEmailBoxes = PIIClassifier(needles: []).classify([
        RecognizedTextFragment(raw: "ma rcus.webb@no rthwind-logistics. com", confidence: 0.5, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
    ])
    check(spacedEmailBoxes.count == 1, "expected email with OCR-inserted spaces")
    check(spacedEmailBoxes.first?.matched == "marcus.webb@northwind-logistics.com", "expected compacted OCR email")

    let needleBoxes = PIIClassifier(needles: ["Secret Code"], checkEmail: false, checkPhone: false).classify([
        RecognizedTextFragment(raw: "show SECRET   code now", confidence: 0.8, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.1)),
    ])
    check(needleBoxes.count == 1, "expected one needle box")
    check(needleBoxes.first?.kind == .needle, "expected needle kind")
    check(needleBoxes.first?.matched == "Secret Code", "expected original needle payload")

    let splitPhoneBoxes = PIIClassifier(needles: [], checkEmail: false, checkPhone: true).classify([
        RecognizedTextFragment(raw: "415", confidence: 0.9, normalizedRect: CGRect(x: 0.10, y: 0.50, width: 0.05, height: 0.03)),
        RecognizedTextFragment(raw: "555", confidence: 0.8, normalizedRect: CGRect(x: 0.17, y: 0.50, width: 0.05, height: 0.03)),
        RecognizedTextFragment(raw: "1212", confidence: 0.7, normalizedRect: CGRect(x: 0.24, y: 0.50, width: 0.07, height: 0.03)),
    ])
    check(splitPhoneBoxes.contains { $0.kind == .phone && $0.matched == "4155551212" }, "expected split phone reconstruction")

    let disabledPhoneBoxes = PIIClassifier(needles: [], checkEmail: false, checkPhone: false).classify([
        RecognizedTextFragment(raw: "415-555-1212", confidence: 0.9, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.1)),
    ])
    check(disabledPhoneBoxes.isEmpty, "expected phone detection disabled")
}

func checkFrameMasker() {
    let rect = FrameMasker.pixelRect(
        from: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
        frameSize: CGSize(width: 200, height: 100)
    )
    check(abs(rect.origin.x - 50) < 0.001, "unexpected x projection")
    check(abs(rect.origin.y - 50) < 0.001, "unexpected y projection")
    check(abs(rect.width - 100) < 0.001, "unexpected width projection")
    check(abs(rect.height - 25) < 0.001, "unexpected height projection")

    let expanded = FrameMasker.builtInBlackoutRect(
        CGRect(x: 10, y: 10, width: 20, height: 10),
        within: CGRect(x: 0, y: 0, width: 100, height: 80)
    )
    check(abs(expanded.minX) < 0.001, "expected expansion clamped to left edge")
    check(abs(expanded.minY) < 0.001, "expected expansion clamped to bottom edge")
    check(expanded.maxX <= 100, "expected expansion clamped to right edge")
    check(expanded.maxY <= 80, "expected expansion clamped to top edge")
}

func checkProtectedRenderingRecipes() {
    let boxes = PIIClassifier(needles: ["Secret Code"], checkEmail: false, checkPhone: false).classify([
        RecognizedTextFragment(raw: "Secret Code", confidence: 0.95, normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.20, height: 0.10)),
    ])
    check(boxes.count == 1, "expected one rendering fixture box")

    let frameSize = CGSize(width: 200, height: 100)
    let viewBounds = CGRect(origin: .zero, size: frameSize)
    let protected = FrameMasker.protectedRects(
        for: boxes,
        frameSize: frameSize,
        maskMode: .blackout,
        guardMode: .standard
    )
    let preview = FrameMasker.overlayRects(
        for: boxes,
        frameSize: frameSize,
        viewBounds: viewBounds,
        maskMode: .blackout,
        guardMode: .standard
    )
    check(protected.count == preview.count, "expected preview/protected rect count parity")
    check(rectsAlmostEqual(protected[0], preview[0]), "expected preview and protected JPEG blackout rect parity")

    let wholeProtected = FrameMasker.protectedRects(
        for: boxes,
        frameSize: frameSize,
        maskMode: .blackout,
        guardMode: .standard,
        blackoutWholeFrame: true
    )
    let wholePreview = FrameMasker.overlayRects(
        for: boxes,
        frameSize: frameSize,
        viewBounds: viewBounds,
        maskMode: .blackout,
        guardMode: .standard,
        blackoutWholeFrame: true
    )
    check(wholeProtected.count == 1 && rectsAlmostEqual(wholeProtected[0], viewBounds), "expected protected whole-frame blackout")
    check(wholePreview.count == 1 && rectsAlmostEqual(wholePreview[0], viewBounds), "expected preview whole-frame blackout")
}

func checkDetectionRecipe() {
    let standard = DetectionRecipe(needles: ["Secret"], checkEmail: false, checkPhone: true, mode: .standard)
    check(standard.needles == ["Secret"], "expected recipe needles preserved")
    check(standard.checkEmail == false, "expected recipe email option preserved")
    check(standard.checkPhone == true, "expected recipe phone option preserved")
    check(standard.settings.accurate == false, "expected standard accurate default")
    check(abs(standard.settings.maxPixelSize - 1920) < 0.001, "expected standard max pixel default")
    check(abs(standard.settings.minimumTextHeight - 0.006) < 0.0001, "expected standard minimum text height default")
    check(standard.settings.enhanceLowContrast == true, "expected standard contrast default")

    let override = DetectorSettings(
        accurate: true,
        maxPixelSize: 321,
        minimumTextHeight: 0.123,
        enhanceLowContrast: false
    )
    let overridden = DetectionRecipe(mode: .lowLatency, settings: override)
    check(overridden.settings == override, "expected detector settings override preserved")
}

func rectsAlmostEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.001) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) < tolerance
        && abs(lhs.origin.y - rhs.origin.y) < tolerance
        && abs(lhs.width - rhs.width) < tolerance
        && abs(lhs.height - rhs.height) < tolerance
}

func checkCaptureSizing() {
    check(CaptureEngine.evenDimension(1) == 2, "expected minimum even dimension of 2")
    check(CaptureEngine.evenDimension(1471) == 1470, "expected odd dimension rounded down")
    check(CaptureEngine.evenDimension(1470) == 1470, "expected even dimension preserved")

    let native = CaptureEngine.outputSize(nativeWidth: 2940, nativeHeight: 1912, resolution: .native)
    check(native.width == 2940 && native.height == 1912, "expected native passthrough")

    let capped = CaptureEngine.outputSize(nativeWidth: 2940, nativeHeight: 1912, resolution: .r720p)
    check(capped.width <= 1280 && capped.height <= 720, "expected 720p cap respected")
    let aspectIn = Double(2940) / Double(1912)
    let aspectOut = Double(capped.width) / Double(capped.height)
    check(abs(aspectIn - aspectOut) < 0.01, "expected aspect ratio preserved when capping")

    let noUpscale = CaptureEngine.outputSize(nativeWidth: 640, nativeHeight: 360, resolution: .r4k)
    check(noUpscale.width == 640 && noUpscale.height == 360, "expected no upscaling")

    let bitrateEfficient = RecordingOptions.targetBitrate(width: 1280, height: 720, fps: 30, quality: .efficient, codec: .hevc)
    let bitrateHigh = RecordingOptions.targetBitrate(width: 1280, height: 720, fps: 30, quality: .high, codec: .hevc)
    check(bitrateHigh > bitrateEfficient, "expected high quality to raise bitrate")
    let bitrateH264 = RecordingOptions.targetBitrate(width: 1280, height: 720, fps: 30, quality: .balanced, codec: .h264)
    let bitrateHEVC = RecordingOptions.targetBitrate(width: 1280, height: 720, fps: 30, quality: .balanced, codec: .hevc)
    check(bitrateH264 > bitrateHEVC, "expected h264 to need more bits than hevc")
    check(RecordingOptions.targetBitrate(width: 64, height: 64, fps: 5, quality: .efficient, codec: .hevc) == 1_500_000, "expected bitrate floor")
}

func checkAccessibilityCoordinateConversion() {
    let capture = CGRect(x: 100, y: 50, width: 1000, height: 500)

    // Element fully inside: top-left global -> bottom-left normalized (Vision).
    let element = CGRect(x: 200, y: 100, width: 100, height: 50)
    guard let normalized = AccessibilityTextScanner.normalizedRect(globalRect: element, in: capture) else {
        fatalError("expected normalized rect for intersecting element")
    }
    check(rectsAlmostEqual(normalized, CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.1)), "expected Vision-convention normalized rect, got \(normalized)")

    // Element at the top-left corner of the capture region maps to y near 1.
    let corner = CGRect(x: 100, y: 50, width: 100, height: 50)
    guard let cornerNormalized = AccessibilityTextScanner.normalizedRect(globalRect: corner, in: capture) else {
        fatalError("expected normalized rect for corner element")
    }
    check(rectsAlmostEqual(cornerNormalized, CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1)), "expected top-left element near normalized top, got \(cornerNormalized)")

    // Partially outside: clipped to the capture region.
    let overflowing = CGRect(x: 0, y: 0, width: 300, height: 100)
    guard let clipped = AccessibilityTextScanner.normalizedRect(globalRect: overflowing, in: capture) else {
        fatalError("expected clipped rect for overflowing element")
    }
    check(rectsAlmostEqual(clipped, CGRect(x: 0, y: 0.9, width: 0.2, height: 0.1)), "expected overflow clipped to capture, got \(clipped)")

    // Fully outside: nothing.
    check(AccessibilityTextScanner.normalizedRect(globalRect: CGRect(x: 5000, y: 5000, width: 10, height: 10), in: capture) == nil, "expected nil for non-intersecting element")
}

func checkDetectionSourceMerge() {
    let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
    let now = 100.0
    let ocrBox = PIIBox(kind: .email, matched: "jane@example.com", confidence: 0.6, normalizedRect: rect, detectedAt: now, source: .ocr)
    let axBox = PIIBox(kind: .email, matched: "jane@example.com", confidence: 1.0, normalizedRect: rect.insetBy(dx: 0.01, dy: 0.005), detectedAt: now, source: .accessibility)

    // Same PII, same place: both sources are kept so a stale/mispositioned AX
    // rect can never suppress a correctly-placed OCR mask.
    let merged = FrameProcessor.merge(ocr: [ocrBox], accessibility: [axBox])
    check(merged.count == 2, "expected additive source merge, got \(merged.count)")
    check(merged.map(\.source) == [.accessibility, .ocr], "expected accessibility and OCR boxes preserved")

    // Same PII, different place (two occurrences on screen): both kept.
    let elsewhere = PIIBox(kind: .email, matched: "jane@example.com", confidence: 1.0, normalizedRect: CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.05), detectedAt: now, source: .accessibility)
    check(FrameProcessor.merge(ocr: [ocrBox], accessibility: [elsewhere]).count == 2, "expected distinct locations kept")

    // Different PII overlapping: both kept.
    let differentPII = PIIBox(kind: .phone, matched: "555 123 4567", confidence: 1.0, normalizedRect: rect, detectedAt: now, source: .accessibility)
    check(FrameProcessor.merge(ocr: [ocrBox], accessibility: [differentPII]).count == 2, "expected different PII kept")

    // No accessibility data: OCR untouched.
    check(FrameProcessor.merge(ocr: [ocrBox], accessibility: []).count == 1, "expected OCR passthrough")
    check(FrameProcessor.merge(ocr: [ocrBox], accessibility: []).first?.source == .ocr, "expected OCR source preserved")
}

func checkPIIBoxSourceCoding() {
    // Old payloads without a source field must decode as .ocr.
    let legacyJSON = """
    {"kind":"email","matched":"a@b.co","confidence":0.5,"normalizedRect":[[0.1,0.2],[0.3,0.1]],"detectedAt":1}
    """
    let decoder = JSONDecoder()
    guard let legacy = try? decoder.decode(PIIBox.self, from: Data(legacyJSON.utf8)) else {
        fatalError("expected legacy PIIBox JSON to decode")
    }
    check(legacy.source == .ocr, "expected legacy payload to default to ocr source")

    let encoder = JSONEncoder()
    let box = PIIBox(kind: .needle, matched: "x", confidence: 1, normalizedRect: .zero, detectedAt: 2, source: .accessibility)
    guard let data = try? encoder.encode(box),
          let roundTripped = try? decoder.decode(PIIBox.self, from: data) else {
        fatalError("expected PIIBox round trip")
    }
    check(roundTripped.source == .accessibility, "expected source to survive round trip")
}

func checkDecisionTimeline() {
    let store = DecisionTimelineStore(requiredSources: [.accessibility])
    let coordinator = DetectionCoordinator(timeline: store, clearBatchThreshold: 2)
    let finding = PIIBox(
        kind: .email,
        matched: "synthetic@example.com",
        confidence: 1,
        normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
        detectedAt: 11,
        source: .accessibility
    )

    coordinator.ingest(DetectionBatch(
        source: .accessibility,
        observedAt: 12,
        effectiveFrom: 10,
        coverage: .verified,
        findings: [finding]
    ))
    check(store.decision(at: 10.5, maxAge: 5)?.action == .blackout(.finding), "expected retroactive AX blackout")
    check(store.decision(at: 9.9, maxAge: 5)?.action == .blackout(.incompleteCoverage), "expected a gap to fail closed")
    check(store.decision(at: 16, maxAge: 5)?.action == .blackout(.incompleteCoverage), "expected stale coverage to fail closed")

    let firstClear = coordinator.ingest(DetectionBatch(
        source: .accessibility,
        observedAt: 13,
        effectiveFrom: 13,
        coverage: .verified,
        findings: []
    ))
    check(firstClear.action == .blackout(.clearHysteresis), "expected first clear batch to keep blackout")

    let secondClear = coordinator.ingest(DetectionBatch(
        source: .accessibility,
        observedAt: 14,
        effectiveFrom: 14,
        coverage: .verified,
        findings: []
    ))
    check(secondClear.action == .clear, "expected consecutive clear batches to release AX blackout")
    check(store.decision(at: 14.5, maxAge: 5)?.action == .clear, "expected latest clear decision")

    let incomplete = coordinator.ingest(DetectionBatch(
        source: .accessibility,
        observedAt: 15,
        effectiveFrom: 15,
        coverage: .partial(reason: "synthetic timeout"),
        findings: []
    ))
    check(incomplete.action == .blackout(.incompleteCoverage), "expected incomplete coverage to fail closed")

    let hybridStore = DecisionTimelineStore(requiredSources: [.ocr, .accessibility])
    let hybridCoordinator = DetectionCoordinator(timeline: hybridStore, clearBatchThreshold: 1)
    hybridCoordinator.ingest(DetectionBatch(
        source: .ocr,
        observedAt: 20,
        effectiveFrom: 20,
        coverage: .verified,
        findings: []
    ))
    check(
        hybridStore.decision(at: 20.1, maxAge: 1)?.action == .blackout(.incompleteCoverage),
        "expected a missing required source to block clear output"
    )
    hybridCoordinator.ingest(DetectionBatch(
        source: .accessibility,
        observedAt: 20,
        effectiveFrom: 20,
        coverage: .verified,
        findings: []
    ))
    check(hybridStore.decision(at: 20.1, maxAge: 1)?.action == .clear, "expected all required sources to permit clear output")

    let remoteStore = DecisionTimelineStore(requiredSources: [.ocr])
    let remoteCoordinator = DetectionCoordinator(timeline: remoteStore, clearBatchThreshold: 1)
    remoteCoordinator.ingest(DetectionBatch(
        source: .ocr,
        observedAt: 31,
        effectiveFrom: 31,
        coverage: .verified,
        findings: []
    ))
    let disconnect = remoteCoordinator.ingest(DetectionBatch(
        source: .ocr,
        observedAt: 32,
        effectiveFrom: 30,
        coverage: .unavailable(reason: "synthetic disconnect"),
        findings: []
    ))
    remoteStore.replaceSourceHistory(with: disconnect)
    check(
        remoteStore.decision(at: 31.5, maxAge: 5)?.action == .blackout(.incompleteCoverage),
        "expected disconnect to invalidate retained source history"
    )
}

func checkProtectedDecisionApplication() {
    let emptySnapshot = DetectionSnapshot(
        frameID: 1,
        boxes: [],
        frameSize: CGSize(width: 100, height: 100),
        capturedAt: 1,
        guardMode: .standard,
        armed: false,
        blackoutWholeFrame: false
    )
    let maskDecision = ProtectionDecision(
        effectiveFrom: 1,
        effectiveUntil: nil,
        action: .mask([CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)]),
        sources: [.ocr],
        coverage: .verified,
        createdAt: 1
    )
    let protected = ProtectedFramePump.applying(
        maskDecision,
        to: emptySnapshot,
        failClosedBlackout: true
    )
    check(protected.blackoutWholeFrame, "expected mask without snapshot geometry to fail closed")

    let overlay = ProtectedFramePump.applying(
        maskDecision,
        to: emptySnapshot,
        failClosedBlackout: false
    )
    check(!overlay.blackoutWholeFrame, "expected local overlay path to remain non-blocking")
}

checkClassifier()
checkFrameMasker()
checkProtectedRenderingRecipes()
checkDetectionRecipe()
checkCaptureSizing()
checkAccessibilityCoordinateConversion()
checkDetectionSourceMerge()
checkPIIBoxSourceCoding()
checkDecisionTimeline()
checkProtectedDecisionApplication()
print("pii-stream checks passed")
