import CoreGraphics
import pii_stream

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

checkClassifier()
checkFrameMasker()
checkProtectedRenderingRecipes()
checkDetectionRecipe()
print("pii-stream checks passed")
