#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--hardware" || "$#" -gt 2 ]]; then
  echo "BLOCKED: opt-in physical microphone check. Usage: $0 --hardware [output-directory]" >&2
  exit 2
fi
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${2:-$(mktemp -d "$APP_DIR/build/microphone-device-XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
# Reuse the engine archive only for linking; this check never loads models.
test -f "$APP_DIR/build/libClassroomASR.a"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
  "$APP_DIR"/Sources/Audio/*.swift "$APP_DIR/Tests/MicrophoneDeviceChecks.swift" "$APP_DIR/build/libClassroomASR.a" \
  -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation \
  -framework AppKit -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia \
  -o "$OUTPUT_DIR/microphone-device-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  "$OUTPUT_DIR/microphone-device-checks" --hardware
