#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$1"
OUTPUT_DIR="$2"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR/App" "$INPUT_DIR/Tests"
for component in Library Cloud Documents Conversion Assistant; do
 mkdir -p "$INPUT_DIR/$component"
 cp "$APP_DIR/Sources/$component/"*.swift "$INPUT_DIR/$component/"
done
cp "$APP_DIR/Sources/App/AppTheme.swift" "$APP_DIR/Sources/App/Localization.swift" "$APP_DIR/Sources/App/StatusLocalization.swift" "$APP_DIR/Sources/App/AIAssistantController.swift" "$INPUT_DIR/App/"
cp "$APP_DIR/Tests/AssistantArchiveChecks.swift" "$INPUT_DIR/Tests/"
shasum -a 256 "$INPUT_DIR"/*/*.swift > "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -D LOCALIZATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" "$INPUT_DIR"/*/*.swift -lsqlite3 -o "$OUTPUT_DIR/assistant-archive-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/assistant-archive-checks" "$FIXTURE_DIR" "$OUTPUT_DIR"
