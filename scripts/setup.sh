#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_NAME="pii-stream"
RELEASE_BIN="$PROJECT_ROOT/.build/release/$BIN_NAME"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_BIN="$INSTALL_DIR/$BIN_NAME"
ENV_FILE="$PROJECT_ROOT/.pii-stream.env"

bold() {
  printf '\033[1m%s\033[0m\n' "$1"
}

note() {
  printf '\n%s\n' "$1"
}

ask() {
  local prompt="$1"
  local default_value="$2"
  local reply
  if [ -n "$default_value" ]; then
    read -r -p "$prompt [$default_value]: " reply
    printf '%s' "${reply:-$default_value}"
  else
    read -r -p "$prompt: " reply
    printf '%s' "$reply"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local reply
  read -r -p "$prompt [$default_value]: " reply
  reply="${reply:-$default_value}"
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

random_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    date +%s | shasum -a 256 | awk '{print $1}'
  fi
}

print_readme_tour() {
  bold "What this installs"
  printf '%s\n' "PII Stream Guard is a macOS Swift app that watches your main display, detects emails/phone numbers/custom text with Apple Vision OCR, and shows a protected preview window."
  printf '%s\n' "It has two runtime shapes:"
  printf '%s\n' "  1. Local: capture and OCR happen on the same Mac."
  printf '%s\n' "  2. Server/client: the client Mac captures frames; a server process runs OCR and returns protected frames over a token-authenticated WebSocket."

  bold "macOS permission"
  printf '%s\n' "The watch and benchmark commands need Screen Recording permission:"
  printf '%s\n' "System Settings -> Privacy & Security -> Screen Recording."
  printf '%s\n' "If capture starts but no frames appear, grant permission to the terminal app you used and run this script again."
}

check_platform() {
  if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "This project currently requires macOS because it uses ScreenCaptureKit and Vision." >&2
    exit 1
  fi

  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "${major:-0}" -lt 14 ]; then
    printf '%s\n' "macOS 14 or newer is required. Found $(sw_vers -productVersion)." >&2
    exit 1
  fi

  if ! command -v swift >/dev/null 2>&1; then
    printf '%s\n' "SwiftPM was not found. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  fi
}

build_release() {
  note "Building release binary..."
  (cd "$PROJECT_ROOT" && swift build -c release)
}

install_launcher() {
  mkdir -p "$INSTALL_DIR"
  ln -sf "$RELEASE_BIN" "$INSTALL_BIN"
  note "Installed launcher: $INSTALL_BIN"
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      printf '%s\n' "Add this to your shell profile if pii-stream is not found later:"
      printf '%s\n' "export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
  esac
}

write_env_file() {
  local mode="$1"
  local token="$2"
  local host="$3"
  local port="$4"
  {
    printf 'PII_STREAM_MODE=%s\n' "$mode"
    printf 'PII_STREAM_TOKEN=%s\n' "$token"
    printf 'PII_STREAM_HOST=%s\n' "$host"
    printf 'PII_STREAM_PORT=%s\n' "$port"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  note "Saved local setup values to $ENV_FILE"
}

run_choice() {
  local command_path="$1"
  local mode="$2"
  local token="$3"
  local host="$4"
  local port="$5"

  note "Choose what to run now:"
  printf '%s\n' "  1. Local protected preview"
  printf '%s\n' "  2. Processing server"
  printf '%s\n' "  3. Remote client"
  printf '%s\n' "  4. Nothing"
  local choice
  choice="$(ask "Selection" "1")"

  case "$choice" in
    1)
      note "Starting local preview. Close the preview window to stop."
      exec "$command_path" watch --mode "$mode"
      ;;
    2)
      note "Starting processing server. Use this client command on another Mac:"
      printf '%s\n' "$command_path watch --remote ${host}:${port} --token ${token} --mode ${mode}"
      exec "$command_path" serve --host "$host" --port "$port" --token "$token"
      ;;
    3)
      local remote
      remote="$(ask "Server HOST:PORT" "${host}:${port}")"
      note "Starting remote client. Close the preview window to stop."
      exec "$command_path" watch --remote "$remote" --token "$token" --mode "$mode"
      ;;
    *)
      note "Setup complete."
      printf '%s\n' "Try local mode with: $command_path watch --mode $mode"
      printf '%s\n' "Start a server with: $command_path serve --host $host --port $port --token $token"
      ;;
  esac
}

main() {
  cd "$PROJECT_ROOT"
  bold "PII Stream Guard setup"
  print_readme_tour
  check_platform

  local mode
  mode="$(ask "Default guard mode (lockdown, standard, low-latency)" "standard")"
  case "$mode" in
    lockdown|standard|low-latency) ;;
    low_latency|lowlatency) mode="low-latency" ;;
    *)
      printf '%s\n' "Unknown mode: $mode" >&2
      exit 1
      ;;
  esac

  local host
  local port
  local token
  host="$(ask "Server listen host for server/client mode" "127.0.0.1")"
  port="$(ask "Server listen port" "8765")"
  token="$(ask "Shared remote token" "$(random_token)")"

  build_release

  local command_path="$RELEASE_BIN"
  if ask_yes_no "Install pii-stream launcher to $INSTALL_BIN?" "y"; then
    install_launcher
    command_path="$INSTALL_BIN"
  fi

  write_env_file "$mode" "$token" "$host" "$port"

  note "Verifying command help..."
  "$command_path" --help >/dev/null

  run_choice "$command_path" "$mode" "$token" "$host" "$port"
}

main "$@"
