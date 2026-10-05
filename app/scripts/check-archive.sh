#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-archive-checks-XXXXXX)}"
mkdir -p "$CHECK_DIR/Sources" app/build/ModuleCache
cp app/Sources/Library/*.swift "$CHECK_DIR/Sources/"
cp app/Tests/WorkspaceArchiveChecks.swift "$CHECK_DIR/"
shasum -a 256 "$CHECK_DIR"/Sources/*.swift "$CHECK_DIR/WorkspaceArchiveChecks.swift" > "$CHECK_DIR/source-sha256.txt"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache "$CHECK_DIR"/Sources/*.swift "$CHECK_DIR/WorkspaceArchiveChecks.swift" -lsqlite3 -o "$CHECK_DIR/WorkspaceArchiveChecks"
"$CHECK_DIR/WorkspaceArchiveChecks" "$CHECK_DIR/fixture" > "$CHECK_DIR/results.json"
printf 'Archive checks passed: %s\n' "$CHECK_DIR/results.json"
