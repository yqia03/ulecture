#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-workspace-move-session-XXXXXX)}"
mkdir -p "$checks_root/sources"
cp "$app_root"/Sources/Library/*.swift "$checks_root/sources/"
cp "$app_root/Tests/WorkspaceMoveSessionChecks.swift" "$checks_root/sources/"
shasum -a 256 "$checks_root"/sources/*.swift > "$checks_root/source-sha256.txt"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$checks_root"/sources/*.swift -lsqlite3 -o "$checks_root/checks"
"$checks_root/checks" "$checks_root/fixtures" > "$checks_root/results.json"
printf 'Workspace move/session evidence: %s\n' "$checks_root/results.json"
