#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-cloud-features-XXXXXX)}"
mkdir -p "$CHECK_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$APP_ROOT"/Sources/Cloud/*.swift "$APP_ROOT/Tests/CloudFeatureChecks.swift" -o "$CHECK_DIR/CloudFeatureChecks"
"$CHECK_DIR/CloudFeatureChecks" > "$CHECK_DIR/cloud-features.json"
printf 'Cloud feature checks passed: %s\n' "$CHECK_DIR"
