#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$APP_DIR/build/audio-lifecycle-check}"
mkdir -p "$OUTPUT_DIR"
# Intentionally reuses the existing static engine. Safe to run beside app builds.
test -f "$APP_DIR/build/libClassroomASR.a"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
 "$APP_DIR"/Sources/Audio/*.swift "$APP_DIR/Tests/AudioLifecycleChecks.swift" "$APP_DIR/build/libClassroomASR.a" \
 -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation \
 -framework AppKit -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox \
 -framework CoreMedia -o "$OUTPUT_DIR/audio-lifecycle-checks"
"$OUTPUT_DIR/audio-lifecycle-checks" "$OUTPUT_DIR"
