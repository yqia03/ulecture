#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
PREVIEW="${1:?Pass a fresh preview directory}"
mkdir -p "$PREVIEW/ULecture.app/Contents/MacOS" "$PREVIEW/compile"
ditto app/Sources "$PREVIEW/compile/Sources"
ditto app/Native "$PREVIEW/compile/Native"
ditto app/Resources "$PREVIEW/ULecture.app/Contents/Resources"
cp app/Resources/Info.plist "$PREVIEW/ULecture.app/Contents/Info.plist"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$PREVIEW/compile/Sources" -g '*.swift' | sort)
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache -import-objc-header "$PREVIEW/compile/Native/ASRBridge.h" "${SOURCES[@]}" app/build/libClassroomASR.a -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security -o "$PREVIEW/ULecture.app/Contents/MacOS/ULecture"
codesign --force --sign - --timestamp=none "$PREVIEW/ULecture.app"
cp app/Tests/ProductUIFixture.swift "$PREVIEW/compile/"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache "$PREVIEW/compile/Sources/Library/"*.swift "$PREVIEW/compile/ProductUIFixture.swift" -lsqlite3 -o "$PREVIEW/ProductUIFixture"
"$PREVIEW/ProductUIFixture" "$PREVIEW/workspace" "$TASK_ROOT/app/Tests/Fixtures/Conversion/complex.pdf"
