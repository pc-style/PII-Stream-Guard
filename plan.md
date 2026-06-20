# PII-Stream — Real-Time PII Detection & Redaction

A ground-up rebuild of the old Final Cut Pro PII scanner. Same proven detection
logic (Apple Vision OCR + email/needle matching), but **no Xcode project** and
repurposed for **real-time PII-leak detection**.

> **MVP target:** capture the main macOS display, run PII detection live, and show
> a preview window that draws boxes around detected PII. Blur/redaction and file
> playback come later.

---

## 0. Status & next steps

### Done

- [x] SwiftPM package scaffold (`Package.swift`, macOS 14+, `swift build` works)
- [x] ScreenCaptureKit capture of main display → `CVPixelBuffer` (with pixel-buffer copy)
- [x] Background detection loop (throttled, default 8 fps, downscale to 1440 px)
- [x] `VisionPIIDetector` with per-substring bounding boxes (email regex + needle matching ported from `ScannerEngine`)
- [x] `BoxStore` / `FrameStore` thread-safe snapshots
- [x] AppKit preview window with live frame + red box overlay + labels
- [x] Y-axis overlay fix (`overlayLayer.isGeometryFlipped = true` — CALayer bottom-left vs Vision→view top-left math)
- [x] CLI: `pii-stream watch [--needle …] [--no-email] [--fps N] [--accurate]`
- [x] JSON detection lines to stdout
- [x] Manual smoke test: large plain emails (e.g. `test@example.com`) and sign-in pill emails (e.g. `adam00krupa@gmail.com`) box correctly
- [x] Preview controls: lockdown / standard / low-latency mode toggle, bounding-box / blackout toggle, preview recorder
- [x] Initial low-contrast small-text pass: lockdown/standard modes can boost OCR contrast/sharpness and use lower `minimumTextHeight`

### Next (in order)

1. **[x] Create GitHub repo — first priority**
   - `git init`, add `.gitignore` (exclude `.build/`, `.DS_Store`, etc.)
   - Initial commit with current SwiftPM sources + this plan
   - Create **public** repo via `gh`: **`PII-Stream-Guard`** (display name: **PII Stream Guard**)
   - Push `main`

2. **[x] Headless benchmark CLI** (no AppKit window — keep working on Mac while iterating)
   - `pii-stream benchmark` subcommand
   - Silent capture and/or bundled fixture images with known PII
   - Sweep settings: `minimumTextHeight`, `maxPixelSize`, `--fps`, fast vs accurate
   - Report per-config: latency (p50/p95), hit count, matched strings
   - Output JSON/CSV summary for comparison runs

3. **[~] Tune small-text detection** (use benchmark to pick defaults)
   - Lower `minimumTextHeight` (currently `0.012`) without killing fps
   - Consider higher OCR resolution cap or adaptive downscale
   - Validate on hard cases: Google sign-in footer ("English (United States)"), small UI chrome
   - Apply winning settings to `watch` defaults
   - Notify when ready to hand-test: `osascript -e 'display notification "PII-Stream ready to test" with title "PII Stream Guard"'`

4. **[ ] Phase 0 verification (formal)**
   - Measure end-to-end latency (capture → box drawn); target < ~300 ms
   - Document results in plan or a short `BENCHMARK.md`

### Not started (post-MVP)

- Phase 1 — blur/redact live preview, box hold + IoU merge
- Phase 2 — local MP4 play/export, `BoxTimeline`, dense-rescan heuristic
- Phase 3 — latency & accuracy pass, adaptive cadence, box tracking
- Phase 4 — live streams
- Phase 5 — cross-platform OCR backend
- `.app` wrapper for stable Screen Recording TCC identity

---

## 1. Guiding principles (kept from the design review)

- **Keep Apple Vision OCR.** It is free, GPU-accelerated on Apple silicon, and
  already proven on this exact problem. Don't replace it with Paddle/ONNX/etc.
- **Keep the geometry.** The old scanner threw bounding boxes away (it joined all
  OCR text into one string). The whole new product depends on per-observation and
  per-substring boxes — this is the single most important change.
- **Never OCR on the hot path.** Detection runs on a background queue, throttled.
  The display/preview path only reads the latest cached boxes and draws.
- **Detect ahead / tolerate small latency.** Real-time means "small bounded delay,"
  not zero. A frame may be shown a few hundred ms after it was captured/analyzed.
- **No Xcode project.** Build with **SwiftPM** (`swift build`), using AVFoundation,
  Vision, CoreImage, ScreenCaptureKit, AppKit. Command Line Tools provide the Swift
  toolchain + macOS SDK — the full Xcode app is not required.

---

## 2. Stack decision

**SwiftPM executable + Apple frameworks. macOS-first.**

| Concern | Choice |
| --- | --- |
| Build | SwiftPM (`Package.swift`, `swift build -c release`) — no `.xcodeproj`, no asset catalog, no codesign step |
| Screen capture | **ScreenCaptureKit** (`SCStream`, `SCShareableContent`, `SCContentFilter`) |
| OCR + boxes | **Vision** (`VNRecognizeTextRequest`, `boundingBox(for:)`) |
| Frame processing | CoreImage / `CVPixelBuffer` (blur added in later phase) |
| Preview window | **AppKit** (`NSApplication`, `NSWindow`, `CALayer` overlay) |
| Later: file/stream decode & export | AVFoundation (`AVAssetReader`, `AVVideoComposition`, `AVAssetExportSession`) |

**Why not Python / Rust / Node for the core:** all would force rebuilding OCR
models, GPU rendering, and capture/sync plumbing that Apple frameworks give for
free. A Bun/TypeScript layer may wrap the tool later (config UI, dashboards), but
never owns frame-level processing.

**Caveat — portability:** this is macOS-only. Isolate detection behind a
`PIIDetector` protocol (see §4) so a cross-platform ONNX/RapidOCR backend can be
added later without touching the pipeline.

---

## 3. Architecture

```diagram
                    ╭───────────────────────────────────────────╮
                    │            PiiStream (SwiftPM)             │
                    ╰───────────────────────────────────────────╯

  ScreenCaptureKit                Detection (bg queue)         Preview (main)
 ╭────────────────╮   frames    ╭──────────────────────╮     ╭───────────────╮
 │ SCStream of    │────────────▶│ throttle every N ms  │     │ NSWindow      │
 │ main display   │ CVPixelBuf  │ downscale            │     │  ├ frame layer│
 ╰────────────────╯             │ Vision OCR           │     │  └ box overlay│
        │                       │ match email/needles  │     ╰───────▲───────╯
        │ latest frame          │ → PIIBox[] w/ rects  │             │
        └──────────────────────▶│ write BoxStore       │─────────────┘
                                ╰──────────────────────╯   read latest boxes
```

- Capture and detection are decoupled: capture never blocks on OCR.
- `BoxStore` holds the most recent detection result (thread-safe snapshot).
- The preview draws the latest captured frame and overlays the latest boxes.

---

## 4. Core data model

```swift
enum PIIKind { case email, needle }

struct PIIBox {
    let kind: PIIKind
    let matched: String          // the literal PII text
    let confidence: Float
    let normalizedRect: CGRect   // Vision coords: origin bottom-left, [0,1]
    let detectedAt: TimeInterval // mach time when this frame was OCR'd
}

/// Thread-safe latest-result holder. Phase 1+ extends this into a
/// time-indexed BoxTimeline for buffered playback / files.
final class BoxStore {
    func update(_ boxes: [PIIBox], frameSize: CGSize) { /* lock + store */ }
    func current() -> (boxes: [PIIBox], frameSize: CGSize) { /* lock + read */ }
}

/// Backend abstraction so non-Apple OCR can be swapped in later.
protocol PIIDetector {
    func detect(in pixelBuffer: CVPixelBuffer) -> [PIIBox]
}
struct VisionPIIDetector: PIIDetector { /* VNRecognizeTextRequest */ }
```

**Getting substring boxes (the key technique):**

```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast          // .accurate only for re-scans
request.usesLanguageCorrection = false
// ... perform on VNImageRequestHandler(cvPixelBuffer:)

for obs in request.results ?? [] {
    guard let candidate = obs.topCandidates(1).first else { continue }
    let raw = candidate.string

    // emails
    for m in emailRegex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
        if let r = Range(m.range, in: raw),
           let boxObs = try? candidate.boundingBox(for: r) {
            boxes.append(PIIBox(kind: .email, matched: String(raw[r]),
                                confidence: candidate.confidence,
                                normalizedRect: boxObs.boundingBox, detectedAt: now))
        }
    }
    // needles: match on normalized text, map back to original range, box it
}
```

If a substring box can't be computed, fall back to the full observation box,
padded. **Over-blurring is safer than leaking PII.**

---

## 5. MVP — Phase 0: live screen capture + PII boxes

**Deliverable:** run `swift run pii-stream watch`, a window opens mirroring the
main display, and red boxes are drawn around any on-screen email / configured
needle in near real time.

**Tasks**

1. **Scaffold SwiftPM package.** ✅
   - `Package.swift` with one `executableTarget` named `pii-stream`,
     `platforms: [.macOS(.v14)]`.
   - Confirm `swift build` works with no Xcode project.
2. **Screen capture.** ✅
   - `SCShareableContent` → pick main display → `SCContentFilter` → `SCStream`.
   - Implement `SCStreamOutput` to receive `CMSampleBuffer` → `CVPixelBuffer`.
   - Trigger and document the Screen Recording permission flow (§8).
3. **Detection loop.** ✅
   - On a serial background queue, throttle to ~5–10 fps (every ~100–200 ms).
   - Downscale the frame (cap longest side ~1440 px) before OCR.
   - Run `VisionPIIDetector`; write results into `BoxStore`.
   - Port the email regex + needle normalization from the old `ScannerEngine`.
4. **Preview window.** ✅
   - `NSApplication` (`.regular`), borderless/standard `NSWindow`.
   - One `CALayer`/`NSView` shows the latest captured frame.
   - Overlay layer draws `BoxStore.current()` rects every display tick
     (timer at 60 Hz), converting Vision normalized (bottom-left)
     → view coordinates. Label each box with the matched text + kind.
   - Fixed: overlay Y-axis inversion via `overlayLayer.isGeometryFlipped = true`.
5. **CLI surface.** ✅
   - `pii-stream watch [--needle "x"]... [--no-email] [--fps N] [--accurate]`
   - Print detections to stdout as JSON lines for debugging/auditing.
6. **Verify.** 🟡 partial
   - Large emails and sign-in pills: confirmed working manually.
   - Small UI text (footer labels, locale selectors): **not yet reliable** — needs benchmark + tuning (see §0).
   - End-to-end latency measurement: not yet recorded.

**Remaining before Phase 0 is closed:** GitHub repo (§0 #1), headless benchmark (§0 #2), small-text tuning (§0 #3), formal latency check (§0 #4).

**Out of scope for MVP:** blurring, MP4 files, audio, export, multi-display,
window/region selection, streams.

---

## 6. Phases after MVP

### Phase 1 — Blur/redact the live preview
- Add a CoreImage compositor: blur or pixelate the `BoxStore` rects on the
  displayed frame (GPU). Expose **blur** (nice to watch) vs **redact** (solid /
  pixelate, safer) modes.
- Add box "hold" (keep a box ~150–300 ms after last detection) + light
  smoothing/merging (IoU) so boxes don't flicker between OCR passes.

### Phase 2 — Local MP4 file mode
- `pii-stream play input.mp4` and `pii-stream export input.mp4 -o out.mp4`.
- Reuse the detector + box model; switch source to `AVAssetReader`, render via
  `AVVideoComposition(asset:applyingCIFiltersWithHandler:)`, export via
  `AVAssetExportSession`. Extend `BoxStore` into a time-indexed `BoxTimeline`.
- Re-introduce the old **dense-rescan heuristic** (sign-in / account-chooser
  windows) and **span merging** here, where a look-back buffer is feasible.

### Phase 3 — Latency & accuracy pass
- Sequential `AVAssetReader` instead of random-access generation.
- `VNImageRequestHandler(cvPixelBuffer:)`, reused request objects.
- Adaptive cadence: sparse when idle, dense around triggers.
- Box interpolation/tracking between OCR passes; scene-cut detection to drop
  stale boxes.

### Phase 4 — Live streams
- Apply the same pipeline to stream sources (HLS/RTMP/webcam/NDI — TBD).
- Mandatory bounded latency buffer (0.5–5 s depending on safety mode).
- Design only once the concrete stream source is known.

### Phase 5 (optional) — Cross-platform / non-Apple OCR
- Implement a second `PIIDetector` (ONNX/RapidOCR) behind the existing protocol
  if Linux/Windows support is ever required.

---

## 7. Carry over from the old Swift code

| Keep | Adapt | Drop |
| --- | --- | --- |
| Email regex (`ScannerEngine.swift`) | Make matching return **ranges + boxes**, not joined strings | FCPXML marker output (use JSON audit log) |
| Needle normalization (lowercase, strip whitespace) | Map normalized match back to original range for boxing | The single joined-text OCR path (kills geometry) |
| Dense-rescan heuristic (sign-in triggers) | Re-add in file/stream phases with a look-back buffer | The 0.5 s sample interval (too coarse — use 100–200 ms) |
| Span merging / padding | Becomes box "hold" + IoU merge for live | — |
| Cancellation / progress, downscale control | Reuse | — |

---

## 8. Permissions, build & run

**Screen Recording permission (TCC):** ScreenCaptureKit requires it. On first
`watch`, macOS prompts; grant in **System Settings → Privacy & Security → Screen
Recording**. For a bare SwiftPM binary, the permission is keyed to the binary —
expect to (re)grant after rebuilds, or run via the terminal app that already has
the permission. A small `.app` wrapper for stable TCC identity can come later.

```bash
swift build -c release        # compile, no Xcode project
swift run pii-stream watch    # capture main display + draw PII boxes
```

---

## 9. Risks & open questions

- **TCC churn for CLI binaries** — may need an `.app` wrapper sooner than planned
  if re-granting per build is annoying.
- **OCR latency vs fps** — `.fast` should suffice for screen text; validate on
  small UI fonts; use `minimumTextHeight` to skip noise.
- **Coordinate mapping** — ~~Vision (normalized, bottom-left) → pixel buffer → Retina-scaled view. Validate early with debug rectangles.~~ **Resolved:** overlay layer geometry flip (§0).
- **Small text misses** — `minimumTextHeight`, downscale cap, and `.fast` OCR skip footer/small UI text. Headless benchmark + tuning in progress (§0 #2–3).
- **Blur strength** — Gaussian blur of an email can be partially recoverable;
  default exports to redact/pixelate.
- **Multi-display / display switching** — MVP assumes the single main display.
- **No GitHub repo yet** — first next step is public **`PII-Stream-Guard`** via `gh` (§0 #1).
