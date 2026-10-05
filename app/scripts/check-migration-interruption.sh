#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="$(mktemp -d /private/tmp/ulecture-migration-interruption-XXXXXX)"
ditto app/Sources/Library "$CHECK_DIR/Library"
cp app/Tests/MigrationInterruptionChecks.swift "$CHECK_DIR/"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache "$CHECK_DIR/Library/"*.swift "$CHECK_DIR/MigrationInterruptionChecks.swift" -lsqlite3 -o "$CHECK_DIR/Checks"
"$CHECK_DIR/Checks" "$CHECK_DIR/fixture" > "$CHECK_DIR/results.json"
printf '%s\n' "$CHECK_DIR/results.json"
