#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-document-translation-XXXXXX)}"
mkdir -p "$CHECK_DIR/compile"
if [ ! -f "$APP_ROOT/Tests/Fixtures/Conversion/encrypted.pptx" ]; then bash "$APP_ROOT/scripts/prepare-test-fixtures.sh"; fi
ditto "$APP_ROOT/Sources/Cloud" "$CHECK_DIR/compile/Cloud"
ditto "$APP_ROOT/Sources/Conversion" "$CHECK_DIR/compile/Conversion"
cp "$APP_ROOT/Tests/CloudFeatureChecks.swift" "$APP_ROOT/Tests/DocumentTranslationChecks.swift" "$CHECK_DIR/compile/"
xcrun swiftc -D DOCUMENT_TRANSLATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 "$CHECK_DIR"/compile/Cloud/*.swift "$CHECK_DIR"/compile/Conversion/*.swift "$CHECK_DIR/compile/CloudFeatureChecks.swift" "$CHECK_DIR/compile/DocumentTranslationChecks.swift" -o "$CHECK_DIR/DocumentTranslationChecks"
"$CHECK_DIR/DocumentTranslationChecks" "$APP_ROOT/.." "$CHECK_DIR"
printf 'Document translation checks passed: %s\n' "$CHECK_DIR"
