# PII Stream Guard

PII Stream Guard is a macOS privacy preview for live screen sharing. It captures the main display, detects emails, phone numbers, and custom text with Apple Vision OCR, then shows a delayed preview that can draw boxes or black out detected areas before they leak.

The app now supports both local and server-client use:

- **Local mode:** one Mac captures the screen, runs OCR, and renders the protected preview.
- **Server-client mode:** a client Mac captures frames and sends them to a processing server over a token-authenticated WebSocket. The server returns protected frames; if the remote path fails, the client fails closed with a black frame.

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

The preview window has controls for guard mode, box vs blackout masking, and recording previews into `recordings/`.

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
