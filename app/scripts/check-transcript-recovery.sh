#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-transcript-recovery-XXXXXX)}"
mkdir -p "$checks_root"
mkdir -p "$checks_root/sources"
cp "$app_root"/Sources/Library/*.swift "$checks_root/sources/"
cp "$app_root/Tests/TranscriptRecoveryChecks.swift" "$checks_root/sources/"
shasum -a 256 "$checks_root"/sources/*.swift > "$checks_root/source-sha256.txt"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$checks_root"/sources/*.swift -lsqlite3 -o "$checks_root/transcript-recovery-checks"
"$checks_root/transcript-recovery-checks" "$checks_root/fixtures" > "$checks_root/results.json"
printf 'Transcript recovery evidence: %s\n' "$checks_root/results.json"
