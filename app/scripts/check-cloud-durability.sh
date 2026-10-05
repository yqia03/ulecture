#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-cloud-durability-XXXXXX)}"
mkdir -p "$checks_root/sources"
cp "$app_root"/Sources/Cloud/*.swift "$checks_root/sources/"
cp "$app_root/Tests/CloudChecks.swift" "$checks_root/sources/"
shasum -a 256 "$checks_root"/sources/*.swift > "$checks_root/source-sha256.txt"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$checks_root"/sources/*.swift -o "$checks_root/cloud-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$checks_root/cloud-checks" > "$checks_root/results.json"
printf 'Cloud durability evidence: %s\n' "$checks_root/results.json"
