#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/session-facts-XXXXXX")}"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR/App" "$INPUT_DIR/Tests"
for component in Library Audio Cloud Interpretation; do
 mkdir -p "$INPUT_DIR/$component"
 cp "$APP_DIR/Sources/$component/"*.swift "$INPUT_DIR/$component/"
done
cp "$APP_DIR/Sources/App/AppTheme.swift" "$APP_DIR/Sources/App/Localization.swift" "$APP_DIR/Sources/App/StatusLocalization.swift" "$APP_DIR/Sources/App/SubtitlePanel.swift" "$APP_DIR"/Sources/App/Interpretation*.swift "$INPUT_DIR/App/"
cp "$APP_DIR/Tests/SessionFactStressChecks.swift" "$INPUT_DIR/Tests/"
cp "$APP_DIR/build/libClassroomASR.a" "$INPUT_DIR/libClassroomASR.a"
cp "$APP_DIR/Native/ASRBridge.h" "$INPUT_DIR/ASRBridge.h"
shasum -a 256 "$INPUT_DIR"/*/*.swift "$INPUT_DIR/libClassroomASR.a" > "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -D AUDIO_TESTING -D LOCALIZATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$INPUT_DIR/ASRBridge.h" \
 "$INPUT_DIR"/*/*.swift "$INPUT_DIR/libClassroomASR.a" -lsqlite3 -lc++ \
 -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation -framework AppKit \
 -framework SwiftUI -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia \
 -o "$OUTPUT_DIR/session-fact-stress-checks"
for mode in write reopen; do
 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/session-fact-stress-checks" "$OUTPUT_DIR" "$mode"
done
