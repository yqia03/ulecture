#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/interpretation-player-XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" \
 "$APP_DIR/Sources/Interpretation/InterpretationModels.swift" \
 "$APP_DIR/Sources/Interpretation/InterpretationAudioPlayer.swift" \
 "$APP_DIR/Tests/InterpretationAudioPlayerChecks.swift" \
 -framework AVFoundation -o "$OUTPUT_DIR/interpretation-player-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/interpretation-player-checks" "$OUTPUT_DIR"
shasum -a 256 "$APP_DIR/Sources/Interpretation/InterpretationModels.swift" \
 "$APP_DIR/Sources/Interpretation/InterpretationAudioPlayer.swift" \
 "$APP_DIR/Tests/InterpretationAudioPlayerChecks.swift" > "$OUTPUT_DIR/source-sha256.txt"
