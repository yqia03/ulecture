#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/uway-local-checks-XXXXXX)}"
mkdir -p "$CHECK_DIR"
mkdir -p app/build/ModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Library/*.swift app/Tests/LibraryChecks.swift -lsqlite3 -o "$CHECK_DIR/LibraryChecks"
"$CHECK_DIR/LibraryChecks" "$CHECK_DIR/library" > "$CHECK_DIR/library-checks.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Cloud/*.swift app/Tests/CloudChecks.swift -o "$CHECK_DIR/CloudChecks"
"$CHECK_DIR/CloudChecks" > "$CHECK_DIR/cloud-checks.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Cloud/*.swift app/Sources/Library/*.swift app/Tests/CloudBackupChecks.swift -lsqlite3 -o "$CHECK_DIR/CloudBackupChecks"
"$CHECK_DIR/CloudBackupChecks" > "$CHECK_DIR/cloud-backup-checks.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Cloud/*.swift app/Sources/App/CloudPresentation.swift app/Tests/CloudPresentationChecks.swift -o "$CHECK_DIR/CloudPresentationChecks"
"$CHECK_DIR/CloudPresentationChecks" > "$CHECK_DIR/cloud-presentation-checks.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache app/Sources/Library/*.swift app/Tests/LibraryConcurrencyChecks.swift -lsqlite3 -o "$CHECK_DIR/LibraryConcurrencyChecks"
"$CHECK_DIR/LibraryConcurrencyChecks" "$CHECK_DIR/concurrent-library" > "$CHECK_DIR/library-concurrency-checks.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache -D LOCALIZATION_TESTING app/Sources/App/Localization.swift app/Sources/App/StatusLocalization.swift app/Tests/LocalizationChecks.swift -o "$CHECK_DIR/LocalizationChecks"
"$CHECK_DIR/LocalizationChecks" "$TASK_ROOT" > "$CHECK_DIR/localization-checks.json"
if [ ! -f app/build/libClassroomASR.a ]; then app/scripts/build-engine.sh; fi
bash app/scripts/check-integration.sh "$CHECK_DIR/integration" > "$CHECK_DIR/integration.log" 2>&1
printf 'Local checks passed. Isolated results: %s\n' "$CHECK_DIR"
