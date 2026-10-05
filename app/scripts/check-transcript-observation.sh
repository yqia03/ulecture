#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
output="${1:?Pass isolated output directory}"
mkdir -p "$output/compile"
ditto app/Sources "$output/compile/Sources"
ditto app/Native "$output/compile/Native"
cp app/Tests/TranscriptObservationChecks.swift "$output/compile/TranscriptObservationChecks.swift"
cp app/build/libClassroomASR.a "$output/compile/libClassroomASR.a"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$output/compile/Sources" -g '*.swift' -g '!UwayClassroomApp.swift' | sort)
shasum -a 256 "${sources[@]}" "$output/compile/TranscriptObservationChecks.swift" "$output/compile/libClassroomASR.a" > "$output/source-sha256.txt"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache -import-objc-header "$output/compile/Native/ASRBridge.h" "${sources[@]}" "$output/compile/TranscriptObservationChecks.swift" "$output/compile/libClassroomASR.a" -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security -framework CoreText -framework Vision -o "$output/transcript-observation"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$output/transcript-observation" --ui-test-workspace "$output/workspace" --model-cache "$output/workspace/Models" --observation-output "$output" --ui-test-preferences "local.ulecture.observation.$(uuidgen)"
