#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/capture-lifecycle-XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
 "$APP_DIR"/Sources/Audio/*.swift "$APP_DIR/Tests/CaptureLifecycleChecks.swift" "$APP_DIR/build/libClassroomASR.a" \
 -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation \
 -framework AppKit -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia \
 -o "$OUTPUT_DIR/capture-lifecycle-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
 "$OUTPUT_DIR/capture-lifecycle-checks" "$ROOT_DIR" "$OUTPUT_DIR"
