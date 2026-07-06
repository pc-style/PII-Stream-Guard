# PII Stream Guard

PII Stream Guard is a macOS tool for streaming or sharing your screen without leaking PII. It captures any display or window with ScreenCaptureKit, detects emails, phone numbers, and custom text with Apple Vision OCR plus the macOS Accessibility tree, and renders a slightly delayed protected output where detected areas are boxed or blacked out before they can leak.

The protected output window is shareable by design: point OBS, Discord, Zoom, or any meeting tool at it instead of your raw screen. The same protected frames can optionally be recorded to a `.mov` with a frame-by-frame metadata sidecar.

The app supports both local and server-client use:

- **Local mode:** one Mac captures the screen, runs detection, and renders the protected output.
- **Server-client mode:** a client Mac captures frames and sends them to a processing server over a token-authenticated WebSocket. The server returns protected frames; if the remote path fails, the client fails closed with a black frame.

Detection runs from two sources in parallel:

- **Vision OCR** on sampled frames (the authority; always on).
- **Accessibility tree** scans of the visible apps (faster, structured, exact text; best-effort). Requires the Accessibility permission; when granted, accessibility-derived boxes are preferred where both sources agree, and OCR covers everything else.

## Install

Run the interactive installer:

```bash
./scripts/setup.sh
```

The script checks macOS and SwiftPM, builds the release binary, optionally installs a `pii-stream` launcher in `~/.local/bin`, writes local setup values to `.pii-stream.env`, and offers to start local mode, server mode, or remote-client mode immediately.

Requirements:

- macOS 14 or newer
- SwiftPM from Xcode or Xcode Command Line Tools
- Screen Recording permission for the terminal app you use to run `pii-stream watch`

If Swift is missing, install the command line tools:

```bash
xcode-select --install
```

## Quick Start

Local preview:

```bash
pii-stream watch --mode standard
```

First launch may require Screen Recording permission:

1. Open System Settings.
2. Go to Privacy & Security -> Screen Recording.
3. Enable the terminal app you used.
4. Quit and rerun `pii-stream watch --mode standard`.

The preview window has controls for guard mode, box vs blackout masking, and recording protected output into `recordings/`.

Capture a specific display or window (list ids first):

```bash
pii-stream targets
pii-stream watch --window 12345 --mode standard
pii-stream watch --display 2 --resolution 1080p --capture-fps 30
```

Record the protected output (works with or without the preview window):

```bash
# Protected window + recording
pii-stream watch --record --codec hevc --quality balanced --record-fps 30

# Headless protected recording with system audio, stop after 60s
pii-stream watch --preview none --record --audio --duration 60 --output demo.mov
```

Every recording writes a `.jsonl` sidecar with per-frame timing, detection source (`ocr` or `accessibility`), detection freshness, mask mode, boxes, and blackout state.

Automation-friendly control: pass `--json-events` for JSON lifecycle events on stdout, and drive the running process over stdin (`pause`, `resume`, `record start [path]`, `record stop`, `mode MODE`, `mask boxes|blackout`, `status`, `stop`). See `pii-stream --help` for the full flag list.

## Server-Client Mode

Start the processing server on the OCR machine:

```bash
pii-stream serve --host 0.0.0.0 --port 8765 --token "replace-with-a-long-random-token"
```

Start the client on the machine being shared:

```bash
pii-stream watch --remote SERVER_IP:8765 --token "replace-with-a-long-random-token" --mode standard
```

Use `127.0.0.1` as the server host for same-machine testing. Use `0.0.0.0` only when another Mac needs to connect over your LAN. Keep the token private; it gates access to the processing server.

## Modes

- `lockdown`: most cautious. Uses accurate OCR, higher delay, and blackouts while armed.
- `standard`: balanced default for normal screen-sharing use.
- `low-latency`: lower delay and faster detection cadence when responsiveness matters more.

## Commands

```bash
pii-stream --help
pii-stream watch [options]
pii-stream targets [--json]
pii-stream serve [options]
pii-stream benchmark [options]
pii-stream detect-image --image PATH [options] --json
```

Useful watch options:

```bash
pii-stream watch --needle "customer-123" --mode standard
pii-stream watch --no-email --mode low-latency
pii-stream watch --accurate --enhance-low-contrast
```

Benchmark the live capture and OCR path:

```bash
pii-stream benchmark --duration 5 --output benchmark-results/latest.json --csv benchmark-results/latest.csv
```

Scan a static image (writes a protected PNG and prints JSON with `savedImagePath`):

```bash
pii-stream detect-image --image ./screenshot.png --json
# default: ./screenshot-protected.png with a small "saved by PII-STREAM-GUARD" badge
pii-stream detect-image --image ./screenshot.png --output ./redacted.png --no-badge
pii-stream detect-image --image ./screenshot.png --watermark
```

## Build From Source

```bash
swift build -c release
.build/release/pii-stream --help
```

During development:

```bash
swift run pii-stream --help
swift run pii-stream watch --mode standard
```

## Troubleshooting

If the preview opens but never updates, Screen Recording permission is usually missing. Grant it to your terminal app, quit that terminal, and run the command again.

If a remote client turns black, check that the server is still running, the token matches exactly, the port is reachable, and the client uses `--remote HOST:PORT`.

If `pii-stream` is not found after install, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

If OCR misses small or low-contrast text, try:

```bash
pii-stream watch --mode lockdown --accurate --enhance-low-contrast
```
