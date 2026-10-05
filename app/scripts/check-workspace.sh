#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="$(mktemp -d /private/tmp/ulecture-workspace-checks-XXXXXX)"
mkdir -p app/build/ModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Library/*.swift app/Tests/WorkspaceCatalogChecks.swift -lsqlite3 -o "$CHECK_DIR/WorkspaceCatalogChecks"
"$CHECK_DIR/WorkspaceCatalogChecks" "$CHECK_DIR/fixture" > "$CHECK_DIR/results.json"
printf 'Workspace checks passed: %s\n' "$CHECK_DIR/results.json"
