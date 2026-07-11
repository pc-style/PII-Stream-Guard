# Screen Capture

The project captures macOS screen content via ScreenCaptureKit at configurable resolution and cadence.

### What can be captured

- full display,
- specific display,
- specific window.

### Core behavior

- Frame production is controlled by `capture-fps` and target selection.
- The output is delayed by design, so sensitive text has time to be analyzed before appearing externally.
- The protected view can be shown in a preview window or run headless for direct sharing/recording pipelines.

### Failure handling

If screen capture cannot proceed (permissions, target loss, stream interruption), the system prefers privacy-safe behavior: stop sharing with fallback-safe output (typically black frame) rather than pass raw content.

### Practical integration

- Point OBS/Zoom/Discord to the protected output instead of the raw desktop.
- Use `--preview none` for headless use when only the safeguarded stream is needed.
