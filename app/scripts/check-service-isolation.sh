#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-service-isolation-XXXXXX)}"
mkdir -p "$CHECK_DIR"
xcrun swiftc -D DOCUMENT_TRANSLATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 "$APP_ROOT"/Sources/Cloud/*.swift "$APP_ROOT/Tests/CloudFeatureChecks.swift" "$APP_ROOT/Tests/ServiceIsolationChecks.swift" -o "$CHECK_DIR/ServiceIsolationChecks"
"$CHECK_DIR/ServiceIsolationChecks" > "$CHECK_DIR/service-isolation.json"
printf 'Service isolation checks passed: %s\n' "$CHECK_DIR"
