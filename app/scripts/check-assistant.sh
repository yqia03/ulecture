#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/assistant-XXXXXX")}"
INPUT_DIR="$OUTPUT_DIR/compile-inputs"
mkdir -p "$INPUT_DIR/App" "$INPUT_DIR/Tests"
for component in Library Cloud Documents Conversion Assistant; do
 mkdir -p "$INPUT_DIR/$component"
 cp "$APP_DIR/Sources/$component/"*.swift "$INPUT_DIR/$component/"
done
cp "$APP_DIR/Sources/App/AppTheme.swift" "$APP_DIR/Sources/App/Localization.swift" "$APP_DIR/Sources/App/StatusLocalization.swift" "$APP_DIR"/Sources/App/AIAssistant*.swift "$INPUT_DIR/App/"
cp "$APP_DIR/Tests/AssistantChecks.swift" "$INPUT_DIR/Tests/"
shasum -a 256 "$INPUT_DIR"/*/*.swift > "$OUTPUT_DIR/compile-inputs.sha256"
xcrun swiftc -D LOCALIZATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 \
 -module-cache-path "$APP_DIR/build/ModuleCache" "$INPUT_DIR"/*/*.swift -lsqlite3 -o "$OUTPUT_DIR/assistant-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/assistant-checks" "$OUTPUT_DIR"
