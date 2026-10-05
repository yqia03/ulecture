#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-conversion-isolation-XXXXXX)}"
mkdir -p "$CHECK_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$APP_ROOT"/Sources/Cloud/*.swift "$APP_ROOT"/Sources/Conversion/*.swift "$APP_ROOT/Tests/ConversionIsolationChecks.swift" -o "$CHECK_DIR/ConversionIsolationChecks"
"$CHECK_DIR/ConversionIsolationChecks" "$CHECK_DIR"
