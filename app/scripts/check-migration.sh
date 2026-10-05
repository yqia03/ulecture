#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="$(mktemp -d /private/tmp/ulecture-migration-checks-XXXXXX)"
mkdir -p app/build/ModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Library/*.swift app/Tests/LegacyMigrationChecks.swift -lsqlite3 -o "$CHECK_DIR/LegacyMigrationChecks"
"$CHECK_DIR/LegacyMigrationChecks" "$CHECK_DIR/fixture" > "$CHECK_DIR/results.json"
printf 'Migration checks passed: %s\n' "$CHECK_DIR/results.json"
