#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/assistant-ocr-XXXXXX")}"
RESOURCES="${2:-$APP_DIR/build/ULecture.app/Contents/Resources/Conversion}"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR/App" "$INPUT_DIR/Tests"
for component in Library Cloud Documents Conversion Assistant; do
 mkdir -p "$INPUT_DIR/$component"
 cp "$APP_DIR/Sources/$component/"*.swift "$INPUT_DIR/$component/"
done
cp "$APP_DIR/Sources/App/AIAssistantController.swift" "$INPUT_DIR/App/"
cp "$APP_DIR/Tests/AssistantOCRChecks.swift" "$INPUT_DIR/Tests/"
shasum -a 256 "$INPUT_DIR"/*/*.swift > "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$APP_DIR/build/ModuleCache" "$INPUT_DIR"/*/*.swift -lsqlite3 -o "$OUTPUT_DIR/assistant-ocr-checks"
# Production PDFium children apply their own deny-network sandbox. macOS rejects
# nested sandbox_apply, so this host uses the test's URLProtocol-only provider
# session and fixture credentials; it never opens a real provider connection.
"$OUTPUT_DIR/assistant-ocr-checks" "$OUTPUT_DIR" "$RESOURCES"
