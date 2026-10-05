#!/bin/bash
set -euo pipefail
# Requires an unlocked macOS desktop; this intentionally creates a visible native fixture window.
# No capture, playback, permission prompts, or cloud code are linked into this harness.
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-native-checks-XXXXXX)}"
mkdir -p "$checks_root"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$app_root"/Sources/Documents/*.swift "$app_root/Tests/DocumentNativeChecks.swift" -o "$checks_root/native-checks"
"$checks_root/native-checks" "$checks_root/fixtures"
printf 'Native document evidence: %s\n' "$checks_root/fixtures/native-checks.json"
