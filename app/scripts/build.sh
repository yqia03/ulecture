#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
mkdir -p app/build/ModuleCache
PACKAGE_DIR="$(mktemp -d "$TASK_ROOT/app/build/package-XXXXXX")"
APP_DIR="$PACKAGE_DIR/ULecture.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
COMPILE_DIR="$(mktemp -d "$TASK_ROOT/app/build/compile-XXXXXX")"
ditto app/Sources "$COMPILE_DIR/Sources"
ditto app/Native "$COMPILE_DIR/Native"
ditto app/Resources "$COMPILE_DIR/Resources"
ditto app/scripts "$COMPILE_DIR/scripts"
python3 "$COMPILE_DIR/scripts/build-manifest.py" --capture-release-inputs "$COMPILE_DIR" "$TASK_ROOT/app"
app/scripts/build-engine.sh "$COMPILE_DIR/Native"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$COMPILE_DIR/Sources" -g '*.swift' | sort)
xcrun swiftc -swift-version 5 -whole-module-optimization -O -target arm64-apple-macosx14.0 \
  -file-prefix-map "$TASK_ROOT=/ULecture" -debug-prefix-map "$TASK_ROOT=/ULecture" \
  -module-cache-path app/build/ModuleCache \
  -import-objc-header "$COMPILE_DIR/Native/ASRBridge.h" "${SOURCES[@]}" app/build/libClassroomASR.a \
  -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit \
  -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio \
  -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security \
  -o "$APP_DIR/Contents/MacOS/ULecture"
cp "$COMPILE_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto "$COMPILE_DIR/Resources" "$APP_DIR/Contents/Resources"
bash app/scripts/build-babeldoc-runtime.sh "$APP_DIR/Contents/Resources/BabelDOC"
bash app/scripts/build-pdfium-helper.sh "$APP_DIR/Contents/Resources/Conversion" "$COMPILE_DIR/Sources/Conversion/PDFiumHelper.mm"
ditto app/Dependencies/libreoffice-26.8.0/LibreOffice.app "$APP_DIR/Contents/Resources/Conversion/LibreOffice.app"
# Development conversions can leave absolute compile filenames in Python caches.
# Sanitize only the staged copy, then seal its changed nested resource bundles.
python3 "$COMPILE_DIR/scripts/sanitize-python-caches.py" "$APP_DIR/Contents/Resources/Conversion/LibreOffice.app"
codesign --force --deep --sign - --timestamp=none "$APP_DIR/Contents/Resources/Conversion/LibreOffice.app"
codesign --verify --deep --strict "$APP_DIR/Contents/Resources/Conversion/LibreOffice.app"
mkdir -p "$APP_DIR/Contents/Resources/Conversion/Licenses/PDFium"
cp app/Dependencies/pdfium-7999/LICENSE "$APP_DIR/Contents/Resources/Conversion/Licenses/PDFium/LICENSE"
if [ -d app/Dependencies/pdfium-7999/licenses ]; then ditto app/Dependencies/pdfium-7999/licenses "$APP_DIR/Contents/Resources/Conversion/Licenses/PDFium/third-party"; fi
cp app/Dependencies/pdfium-7999/dependency-lock.json "$APP_DIR/Contents/Resources/Conversion/pdfium-lock.json"
cp app/Dependencies/libreoffice-26.8.0/dependency-lock.json "$APP_DIR/Contents/Resources/Conversion/libreoffice-lock.json"
cp LICENSE "$APP_DIR/Contents/Resources/Licenses/ULecture-AGPL-3.0.txt"
cp COPYRIGHT "$APP_DIR/Contents/Resources/Licenses/ULecture-COPYRIGHT.txt"
if [ -f THIRD_PARTY_NOTICES.md ]; then cp THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"; fi
python3 "$COMPILE_DIR/scripts/conversion-integrity.py" "$APP_DIR/Contents/Resources/Conversion" "$APP_DIR/Contents/Resources/ConversionIntegrity.json"
(cd "$COMPILE_DIR" && rg --files Sources -g '*.swift' | sort | while IFS= read -r file; do shasum -a 256 "$file"; done) > "$APP_DIR/Contents/Resources/source-sha256.txt"
python3 "$COMPILE_DIR/scripts/build-manifest.py" "$COMPILE_DIR" "$TASK_ROOT/app" "$APP_DIR/Contents/Resources/build-manifest.json"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
shasum -a 256 "$APP_DIR/Contents/MacOS/ULecture"
if [ -d "$TASK_ROOT/app/build/ULecture.app" ]; then
  mv "$TASK_ROOT/app/build/ULecture.app" "$TASK_ROOT/app/build/ULecture.previous-$(date -u +%Y%m%dT%H%M%SZ).app"
fi
mv "$APP_DIR" "$TASK_ROOT/app/build/ULecture.app"
printf '%s\n' "$TASK_ROOT/app/build/ULecture.app"
