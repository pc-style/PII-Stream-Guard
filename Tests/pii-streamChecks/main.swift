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

checkClassifier()
checkFrameMasker()
print("pii-stream checks passed")
