# Architecture

PII Stream Guard is structured as a capture → detect → render → stream/record loop.

## Data flow

1. **Capture layer** grabs frames from a selected display or window.
2. **Detection layer** runs:
   - Apple Vision OCR for frame-based text extraction,
   - Accessibility tree scans for structured on-screen text when permission is available.
3. **Fusion & policy layer** merges detections, applies source confidence rules, adds guard-mode policy (boxes vs blackout), and computes final redaction regions.
4. **Renderer/output layer** draws masked frames to a protected output stream/window and optionally writes recordings with metadata sidecar.
5. **Transport/control layer** handles local CLI-driven control and optional server-client forwarding over token-authenticated WebSocket.

## Runtime variants

- **Local mode**: capture, detection, and rendering happen on one machine.
- **Server-client mode**: a client captures and forwards frames; processing happens on a server with strict token checks; failures return a closed/fail-safe black frame on the client side.

## Control surfaces

- CLI startup flags choose source, FPS, resolution, mode, detection quality, and output behavior.
- Runtime stdin commands can pause/resume, switch mode, start/stop recording, and switch mask style without restarting the process.
- JSON events and sidecar outputs provide observability for automation and benchmarking.
