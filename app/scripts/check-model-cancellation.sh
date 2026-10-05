#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$APP_DIR/build/model-cancellation-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTPUT_DIR"
# Reuse the frozen native archive; this check never constructs an engine.
test -f "$APP_DIR/build/libClassroomASR.a"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" -import-objc-header "$APP_DIR/Native/ASRBridge.h" \
 "$APP_DIR/Sources/Audio/ModelManager.swift" "$APP_DIR/Tests/ModelCancellationChecks.swift" "$APP_DIR/build/libClassroomASR.a" \
 -lc++ -framework Accelerate -framework Metal -framework MetalKit \
 -o "$OUTPUT_DIR/model-cancellation-checks"
# Defense in depth: the injected downloader rejects before URLSession exists.
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
 "$OUTPUT_DIR/model-cancellation-checks" "$OUTPUT_DIR"
