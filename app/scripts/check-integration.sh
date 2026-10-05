#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
COMPILE_DIR="$(mktemp -d "$TASK_ROOT/app/build/integration-compile-XXXXXX")"
ditto app/Sources "$COMPILE_DIR/Sources"
cp app/Tests/IntegrationChecks.swift "$COMPILE_DIR/IntegrationChecks.swift"
cp app/build/libClassroomASR.a "$COMPILE_DIR/libClassroomASR.a"
cp app/Native/ASRBridge.h "$COMPILE_DIR/ASRBridge.h"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$COMPILE_DIR/Sources" -g '*.swift' -g '!UwayClassroomApp.swift' | sort)
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -Onone -target arm64-apple-macosx14.0 -module-cache-path app/build/ModuleCache \
 -import-objc-header "$COMPILE_DIR/ASRBridge.h" "${SOURCES[@]}" "$COMPILE_DIR/IntegrationChecks.swift" "$COMPILE_DIR/libClassroomASR.a" \
 -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security \
 -o app/build/IntegrationChecks
app/build/IntegrationChecks --ui-test-library "${1:?Pass a fresh isolated library path}"
