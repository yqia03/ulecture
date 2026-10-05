#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$APP_DIR/build/audio-check-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTPUT_DIR"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR/Audio" "$INPUT_DIR/Tests"
cp "$APP_DIR"/Sources/Audio/*.swift "$INPUT_DIR/Audio/"
cp "$APP_DIR/Tests/AudioChecks.swift" "$INPUT_DIR/Tests/"
shasum -a 256 "$INPUT_DIR"/*/*.swift > "$OUTPUT_DIR/compile-inputs.sha256"
if [[ "${UWAY_AUDIO_REUSE_ENGINE:-0}" == "1" ]]; then
 test -f "$APP_DIR/build/libClassroomASR.a"
 printf '%s\n' 'Reused existing engine archive; no engine build requested.' > "$OUTPUT_DIR/engine-build.log"
else
 "$APP_DIR/scripts/build-engine.sh" > "$OUTPUT_DIR/engine-build.log" 2>&1
fi
cp "$APP_DIR/build/libClassroomASR.a" "$INPUT_DIR/libClassroomASR.a"
cmp -s "$APP_DIR/build/libClassroomASR.a" "$INPUT_DIR/libClassroomASR.a" || { echo "Native library changed during snapshot; retry after its build completes." >&2; exit 1; }
shasum -a 256 "$INPUT_DIR/libClassroomASR.a" >> "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
 "$INPUT_DIR"/Audio/*.swift "$INPUT_DIR/Tests/AudioChecks.swift" "$INPUT_DIR/libClassroomASR.a" \
 -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation \
 -framework AppKit -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox \
 -framework CoreMedia -o "$OUTPUT_DIR/audio-checks"
# Offline child only. This neither changes host network settings nor opens capture/audio output.
/usr/bin/time -l /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
 "$OUTPUT_DIR/audio-checks" "$ROOT_DIR" "$OUTPUT_DIR" > "$OUTPUT_DIR/run.log" 2>&1
printf '%s\n' "Silent production audio checks completed: $OUTPUT_DIR/audio-results.json"
