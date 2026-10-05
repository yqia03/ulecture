#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Provide isolated evidence directory}"
mkdir -p "$OUTPUT_DIR"
xcrun swiftc -D LOCALIZATION_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$APP_DIR/build/ModuleCache" \
 "$APP_DIR/Sources/App/SubtitlePanel.swift" "$APP_DIR/Sources/App/Localization.swift" "$APP_DIR/Sources/App/StatusLocalization.swift" "$APP_DIR/Tests/SubtitleRollingChecks.swift" \
 -framework AppKit -framework SwiftUI -framework CoreText -o "$OUTPUT_DIR/subtitle-rolling-checks"
"$OUTPUT_DIR/subtitle-rolling-checks" "$OUTPUT_DIR" "${2:-}"
if [ "${2:-}" = "--dynamic" ]; then
 ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$OUTPUT_DIR/frames/%05d.png" -vf 'scale=1920:860,pad=1920:1080:0:110:color=0x141414' -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$OUTPUT_DIR/visual-line-rolling.mp4"
fi
