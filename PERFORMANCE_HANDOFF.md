# Performance Optimization Handoff

## Mission

Continue the aggressive performance pass without weakening the app's fail-closed privacy behavior. The next three priorities are:

1. Dirty-frame bypass and dirty-region/ROI OCR with periodic full-frame safety scans.
2. Event-driven, incrementally cached Accessibility detection.
3. Asynchronous recorder finalization that never blocks the main thread.

Measure before and after where possible. Prioritize removing full-frame work, cross-process calls, image encodes, and main-thread stalls over small collection-level optimizations.

## Repository state

There is an **uncommitted first optimization pass** in the working tree. Review its diff before changing anything:

```bash
rtk git status --short
rtk git diff -- Sources/pii-stream
```

`Tests/pii-streamChecks/main.swift` was already modified before the optimization pass. Preserve those user changes. They update the expected additive Accessibility/OCR merge behavior.

### First-pass work already implemented

- `CaptureEngine.swift`
  - Removed the per-frame full-resolution `CVPixelBuffer` copy.
  - Captured ScreenCaptureKit surfaces are retained directly by `FrameStore`.
- `BoxStore.swift` / `AppCoordinator.swift`
  - Frame history retention now varies by guard mode.
  - Remote source capture keeps only one stored frame; the remote client retains its in-flight sample.
- `PixelBufferUtils.swift`
  - Added keyed `CVPixelBufferPool` reuse.
  - Same-size resize requests return the source buffer.
- `VisionPIIDetector.swift`
  - Reuses one `VNRecognizeTextRequest` per detector.
  - Fast OCR modes classify one candidate per observation; accurate/lockdown mode still classifies three.
  - OCR preparation uses pooled buffers.
- `AppCoordinator.swift`
  - Detection cadence is reserved before dispatch, eliminating no-op queue jobs between OCR slots.
- `ProtectedFramePump.swift`
  - Skips protected-store resolution while neither the protected preview nor recorder needs frames.
- `PreviewWindow.swift`
  - Replaced per-frame CI-to-CGImage preview conversion with `AVSampleBufferDisplayLayer`.
- `ProtectedRecorder.swift`
  - No-mask frames stay on the GPU path and avoid buffer locking/CGContext creation.
  - Whole-frame blackout skips source rendering entirely.
  - Metadata writes are buffered in 32 KiB batches.
- `RemoteProcessing.swift` / `RemoteProtocol.swift` / `FrameCodec.swift`
  - New clients advertise optional `acceptsMetadataOnly`; new servers omit the protected JPEG response for those clients.
  - Old peers remain compatible because the field and response image are optional.
  - New clients retain and locally mask their original full-resolution sample.
  - Upload JPEGs are scaled to the detector's maximum OCR size before encoding.
  - JPEG encode/decode now uses Core Image directly rather than unnecessary NSImage/CGImage intermediates.
- `PIIClassifier.swift`, `BoxStabilizer.swift`, `FrameMasker.swift`
  - Shared compiled regexes, allocation-free moving-track matching, squared-distance comparisons, and reduced CGContext state churn.

### Validation already completed

The following passed after the first pass:

```bash
rtk swiftc -typecheck -parse-as-library -module-name pii_stream Sources/pii-stream/*.swift
rtk git diff --check
```

The full `pii-stream-checks` executable was not run because that requires a Swift build. Project instructions say to ask before running build commands. `swift-format lint` currently reports many project-wide pre-existing formatting warnings; do not reformat entire files just to silence them.

## Non-negotiable privacy invariants

1. **Fail closed:** if a sufficiently fresh detection snapshot cannot be resolved for a delayed protected frame, blackout the whole frame.
2. **No stale AX suppression:** Accessibility and OCR boxes remain additive. A stale/moved AX rectangle must never suppress an OCR rectangle.
3. **Current-frame snapshots:** when reusing cached OCR results for an unchanged frame, emit a new snapshot tied to the current `FrameSample`; otherwise delayed rendering can fail to resolve the corresponding frame.
4. **Periodic full OCR:** ROI or unchanged-frame shortcuts must never permanently replace full-frame scans.
5. **Conservative invalidation:** missing, malformed, oversized, or ambiguous dirty-region metadata must trigger full-frame OCR, not a skip.
6. **Coordinate correctness:** ScreenCaptureKit, Core Graphics, Vision, and overlay coordinates use different origins. Add explicit tests for every conversion.
7. **Bounded staleness:** cached OCR/AX detections must expire. Do not indefinitely carry boxes that no longer have a validated source.
8. **Remote fail closed:** missing response pixels are valid only when the client retained the exact matching local sample. A missing sample or mismatched frame ID must disconnect/fail closed.

---

# Phase 1 — Dirty-frame bypass and ROI OCR

This is the highest-leverage remaining optimization because Vision OCR and OCR preprocessing dominate active CPU/GPU time.

## Recommended incremental implementation

### 1A. Safely bypass truly unchanged frames first

Implement this before ROI OCR. It is simpler, easier to validate, and likely captures much of the benefit for static desktop content.

1. Extract ScreenCaptureKit dirty-rectangle metadata in `CaptureEngine.handleVideo` using the same attachment dictionary currently used for frame status.
2. Extend `FrameSample` with conservative frame-change metadata. Prefer an enum rather than an optional array so “metadata unavailable” cannot be confused with “known unchanged,” for example:
   - `.unknown`
   - `.unchanged`
   - `.changed([CGRect])`
   - `.fullFrame`
3. Treat absent/unparseable metadata as `.unknown` and run full OCR.
4. In `FrameProcessor`, cache the last complete OCR result separately from Accessibility results.
5. For a verified unchanged frame:
   - Reuse the cached OCR boxes.
   - Still merge fresh AX boxes.
   - Still ingest the guard state and emit a new current-frame snapshot.
   - Do not claim a new real OCR timestamp unless Vision actually ran; keep separate “last Vision run” and “last validated/reused result” semantics if freshness reporting needs both.
6. Force a full scan on a bounded interval even when every frame says unchanged.
7. Reset the cache on mode/settings/target/geometry changes.

Suggested full-scan ceilings to start benchmarking—not final policy:

- Lockdown: 0.25–0.5 seconds.
- Standard: 0.75–1.0 seconds.
- Low latency: 0.5–0.75 seconds.

Privacy policy should drive the final values, not benchmark results alone.

### 1B. Add dirty-region OCR

After unchanged bypass is stable:

1. Normalize and clamp dirty rectangles to the captured pixel bounds.
2. Expand each dirty region substantially before OCR so antialiasing, shadows, cursor movement, and neighboring text are included.
3. Merge intersecting/nearby dirty regions.
4. Fall back to full-frame OCR when:
   - Dirty metadata is unavailable or invalid.
   - Dirty area exceeds a threshold (start around 25–35% of the frame).
   - There are too many disjoint regions (start around 2–4 regions).
   - A periodic full scan is due.
   - Capture geometry or detector settings changed.
5. Prefer one union ROI or a very small number of merged ROIs. Repeated Vision requests can erase the expected savings.
6. Maintain an OCR box cache:
   - Remove cached boxes intersecting the expanded dirty region.
   - OCR the dirty region.
   - Insert the new regional results.
   - Retain boxes outside the dirty region only until the periodic full-scan deadline.
7. Verify whether Vision observation boxes produced with `regionOfInterest` are full-image normalized or ROI-relative on the deployed macOS SDK. Do not assume. Add a deterministic conversion helper and tests.
8. Keep Accessibility merging additive after the OCR cache is reconstructed.

### Tests required for Phase 1

Add checks for:

- Missing dirty metadata causes full OCR.
- Empty/unchanged metadata reuses boxes but emits a current-frame snapshot.
- A dirty region removes stale boxes inside it while retaining boxes outside it.
- A new PII box inside a dirty region is normalized into full-frame coordinates correctly.
- Dirty-area and region-count thresholds force full OCR.
- Periodic full scan fires after repeated unchanged frames.
- Mode/settings changes invalidate cached OCR.
- Top-left ScreenCaptureKit rectangles convert correctly to Vision's bottom-left normalized coordinates.
- Fail-closed delayed rendering still resolves current frame IDs.

### Benchmark counters

Add lightweight counters or signposts for:

- Frames captured.
- Full OCR requests.
- ROI OCR requests.
- OCR requests skipped as unchanged.
- Forced safety refreshes.
- Average dirty-area percentage.
- OCR preparation time, Vision time, classification time, and total processing time.

Avoid logging per frame by default. Aggregate periodically or expose through the existing status event.

---

# Phase 2 — Incremental Accessibility detection

Current hot path: `AccessibilityDetection.swift` performs repeated CG window discovery and bounded recursive AX tree walks. AX calls are cross-process IPC and should be avoided whenever nothing changed.

## Recommended architecture

1. Keep the existing bounded scan as the authoritative fallback.
2. Add an `AXObserver` per candidate application PID.
3. Subscribe where supported to notifications such as:
   - Value changed.
   - Title changed.
   - Focused UI element changed.
   - Window moved/resized.
   - UI element created/destroyed.
4. Observer callbacks should only mark applications/windows/elements dirty and schedule work on `axQueue`; do not classify or walk synchronously in the callback.
5. Cache classified fragments/boxes by a stable key where possible:
   - PID + window identity + element identity.
   - Last value/title signature.
   - Last global bounds.
6. On notification:
   - Re-read and reclassify the affected element or window subtree.
   - Invalidate old boxes before inserting replacements.
7. Periodically run the existing full bounded scan as a safety reconciliation pass.
8. Rebuild observers when candidate apps/windows change, capture target changes, permission changes, or a process exits.
9. If observer registration fails for an app, keep it on timer-based scanning.
10. Do not weaken the existing additive merge behavior in `FrameProcessor.merge`.

## Lower-risk intermediate step

If AXObserver caching is too large for one change, first add a coarse candidate-window signature and skip tree scans only between periodic refreshes when:

- Candidate PIDs/window IDs/bounds are unchanged.
- No observer marked content dirty.
- The safety refresh interval has not elapsed.

Do not infer “text unchanged” from window bounds alone without a periodic scan.

## AX implementation concerns

- AX notification support differs by application; handle `.notificationUnsupported` without treating it as fatal.
- Observer run-loop integration must work with the existing `axQueue`. Keep ownership/lifetime explicit.
- Never hold a shared lock while making AX IPC calls.
- Cap cache size and remove entries on process/window destruction.
- Keep the existing wall-clock, depth, app, value-length, and element budgets.
- Consider `AXUIElementCopyMultipleAttributeValues` to reduce IPC calls after correctness is established.

### Tests required for Phase 2

Separate pure cache/invalidation logic from AX APIs so it can be tested without Accessibility permission:

- Value changes replace old boxes.
- Move/resize invalidates old coordinates.
- Element/window destruction removes cached boxes.
- Unsupported notifications retain periodic scanning.
- Cache expiry and periodic reconciliation work.
- OCR boxes remain present when an AX cache entry is stale or mispositioned.

---

# Phase 3 — Asynchronous recorder finalization

Current hot path: `ProtectedRecorder.stop()` calls `finishWriting`, waits on a semaphore for up to 15 seconds, and can block the main thread.

## Target behavior

1. Introduce explicit recorder state, for example:
   - `.idle`
   - `.recording`
   - `.finishing`
2. On stop:
   - Stop accepting frames/audio immediately.
   - Flush and close metadata safely.
   - Mark writer inputs finished.
   - Detach the active recording session state.
   - Call `finishWriting` without waiting on the main thread.
3. Perform completion handling on a dedicated recorder/finalization queue.
4. Deliver `RecorderEvent` callbacks on the expected queue—preferably main, since the coordinator updates UI/event output.
5. Prevent a new recording while finalization is active, or explicitly queue the new start. Do not silently overwrite writer state.
6. Preserve duration-triggered headless shutdown: shutdown must wait for finalization completion rather than terminating immediately.
7. Handle app termination with AppKit's deferred termination flow if recording is finalizing:
   - Return `.terminateLater` from the appropriate termination delegate method.
   - Call `NSApp.reply(toApplicationShouldTerminate:)` after finalize/timeout.
8. Keep a bounded timeout, but do not block the main thread while waiting for it.
9. Ensure every path emits exactly one terminal event and clears state exactly once.

### Tests/state-machine checks for Phase 3

- Stop while idle is a no-op.
- Stop transitions recording → finishing → idle.
- Appending during finishing is rejected.
- Starting during finishing has explicit behavior.
- Finish success emits one `.finished` event.
- Writer failure and timeout emit one `.failed` event.
- Metadata is flushed before completion.
- Duration-based headless recording exits only after completion/timeout.
- Repeated stop calls do not double-finalize.

---

# Follow-up opportunities after the three phases

1. **GPU mask composition:** replace CI render followed by CPU CGContext masking with a single Core Image or Metal composition into the writer pool buffer.
2. **Remote binary protocol:** replace JSON/base64 image transport with binary WebSocket messages; base64 currently adds memory traffic and roughly 33% payload overhead.
3. **Server concurrency:** give each remote session a dedicated processing queue so one client's OCR cannot block every connection on the listener queue.
4. **Frame/BoxStore ring buffers:** replace array `removeFirst` maintenance with a bounded circular buffer if profiling still shows lock/store overhead.
5. **Mask rectangle coalescing:** union overlapping protected rectangles before recorder/image rendering while preserving overlay labels separately.
6. **Incremental metadata encoder:** replace `[String: Any]` + `JSONSerialization` with typed `Encodable` records if metadata remains visible after batching.
7. **Preview backpressure metrics:** track renderer-ready drops and flushes to verify `AVSampleBufferDisplayLayer` behavior under load.

## Suggested execution order

1. Review all uncommitted changes and run typecheck.
2. Add timing/counter instrumentation with negligible release overhead.
3. Implement Phase 1A unchanged-frame bypass and tests.
4. Benchmark and smoke-test capture surface retention and preview correctness.
5. Implement Phase 1B ROI OCR with conservative fallbacks and periodic full scans.
6. Implement AX caching/observers.
7. Refactor recorder finalization last because it changes coordinator lifecycle behavior.
8. Ask before running `swift build` or `swift run pii-stream-checks`.
9. Finish with:

```bash
rtk swiftc -typecheck -parse-as-library -module-name pii_stream Sources/pii-stream/*.swift
rtk git diff --check
rtk git status --short
```

## Manual smoke-test checklist

When permission is granted to build/run:

- Static screen: OCR request rate drops sharply while masks remain stable.
- New email appears in a small changed region: it is masked within the expected guard delay.
- Existing email disappears or moves: stale mask is replaced, not retained indefinitely.
- Window move/scroll: AX and OCR masks remain aligned and additive.
- Lockdown: missing/stale detection data still blacks out the whole frame.
- Preview: no flicker, stale surface reuse, color shift, or runaway retained-surface memory.
- Recording: no-mask, masked, and full-blackout recordings render correctly.
- Stop recording: UI remains responsive during AVAssetWriter finalization.
- Headless duration recording: process exits only after the file is finalized.
- Remote mode: new↔new uses metadata-only responses; mixed-version peers still function.
