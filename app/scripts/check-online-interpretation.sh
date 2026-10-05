#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/online-interpretation-XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR"/{Library,Audio,Cloud,Interpretation,App,Tests}
cp "$APP_DIR"/Sources/Library/*.swift "$INPUT_DIR/Library/"
cp "$APP_DIR"/Sources/Audio/*.swift "$INPUT_DIR/Audio/"
cp "$APP_DIR"/Sources/Cloud/*.swift "$INPUT_DIR/Cloud/"
cp "$APP_DIR"/Sources/Interpretation/*.swift "$INPUT_DIR/Interpretation/"
cp "$APP_DIR"/Sources/App/Interpretation*.swift "$APP_DIR/Sources/App/Localization.swift" "$APP_DIR/Sources/App/StatusLocalization.swift" "$APP_DIR/Sources/App/SubtitlePanel.swift" "$APP_DIR/Sources/App/AppTheme.swift" "$INPUT_DIR/App/"
cp "$APP_DIR/Tests/OnlineInterpretationChecks.swift" "$INPUT_DIR/Tests/"
shasum -a 256 "$INPUT_DIR"/*/*.swift > "$OUTPUT_DIR/compile-inputs.sha256"
cp "$APP_DIR/build/libClassroomASR.a" "$INPUT_DIR/libClassroomASR.a"
cmp -s "$APP_DIR/build/libClassroomASR.a" "$INPUT_DIR/libClassroomASR.a" || { echo "Native library changed during snapshot; retry after its build completes." >&2; exit 1; }
shasum -a 256 "$INPUT_DIR/libClassroomASR.a" >> "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -D AUDIO_TESTING -D LOCALIZATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
 "$INPUT_DIR"/Library/*.swift "$INPUT_DIR"/Audio/*.swift "$INPUT_DIR"/Cloud/*.swift "$INPUT_DIR"/Interpretation/*.swift "$INPUT_DIR"/App/*.swift \
 "$INPUT_DIR/Tests/OnlineInterpretationChecks.swift" "$INPUT_DIR/libClassroomASR.a" \
 -lsqlite3 -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation \
 -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia \
 -o "$OUTPUT_DIR/online-interpretation-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/online-interpretation-checks" "$OUTPUT_DIR"
