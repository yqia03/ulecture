#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Pass isolated output directory}"
mkdir -p "$output/compile"
for source in SubtitlePanel Localization StatusLocalization; do cp "$app_dir/Sources/App/$source.swift" "$output/compile/$source.swift"; done
cp "$app_dir/Tests/CaptionLatencyChecks.swift" "$output/compile/CaptionLatencyChecks.swift"
shasum -a 256 "$output/compile/"*.swift > "$output/source-sha256.txt"
xcrun swiftc -D LOCALIZATION_TESTING -D CAPTION_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$app_dir/build/ModuleCache" "$output/compile/"*.swift -framework AppKit -framework SwiftUI -framework CoreText -o "$output/caption-latency"
"$output/caption-latency" "$output"
