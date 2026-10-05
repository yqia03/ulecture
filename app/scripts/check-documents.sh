#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-document-checks-XXXXXX)}"
mkdir -p "$checks_root"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$app_root"/Sources/Documents/*.swift "$app_root/Tests/DocumentEditingChecks.swift" -o "$checks_root/document-checks"
"$checks_root/document-checks" "$checks_root/fixtures"
printf 'Document editing evidence: %s\n' "$checks_root/fixtures/document-editing-checks.json"
