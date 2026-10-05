#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-interpretation-settings-XXXXXX)}"
mkdir -p "$CHECK_DIR"
shasum -a 256 app/Sources/Cloud/*.swift app/Sources/Library/*.swift \
 app/Sources/Interpretation/InterpretationModels.swift app/Sources/Interpretation/RealtimeTransport.swift \
 app/Sources/Interpretation/InterpretationSession.swift app/Sources/Interpretation/InterpretationServiceSettings.swift \
 app/Tests/InterpretationSettingsChecks.swift app/Tests/InterpretationPersistenceChecks.swift > "$CHECK_DIR/source-sha256.txt"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 app/Sources/Cloud/*.swift \
 app/Sources/Interpretation/InterpretationModels.swift app/Sources/Interpretation/RealtimeTransport.swift \
 app/Sources/Interpretation/InterpretationSession.swift app/Sources/Interpretation/InterpretationServiceSettings.swift \
 app/Tests/InterpretationSettingsChecks.swift -o "$CHECK_DIR/InterpretationSettingsChecks"
"$CHECK_DIR/InterpretationSettingsChecks" > "$CHECK_DIR/settings.json"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 app/Sources/Library/*.swift \
 app/Tests/InterpretationPersistenceChecks.swift -lsqlite3 -o "$CHECK_DIR/InterpretationPersistenceChecks"
FIXTURE_DIR="$(mktemp -d "$CHECK_DIR/fixture-XXXXXX")"
"$CHECK_DIR/InterpretationPersistenceChecks" "$FIXTURE_DIR" > "$CHECK_DIR/persistence.json"
printf 'Interpretation settings and persistence checks passed: %s\n' "$CHECK_DIR"
