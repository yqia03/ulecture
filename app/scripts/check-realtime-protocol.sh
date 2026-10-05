#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$(mktemp -d "$APP_DIR/build/realtime-protocol-XXXXXX")}"
mkdir -p "$OUTPUT_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$APP_DIR/build/ModuleCache" \
  "$APP_DIR/Sources/Interpretation/InterpretationModels.swift" \
  "$APP_DIR/Sources/Interpretation/RealtimeTransport.swift" \
  "$APP_DIR/Sources/Interpretation/InterpretationSession.swift" \
  "$APP_DIR/Tests/RealtimeProtocolChecks.swift" \
  -o "$OUTPUT_DIR/realtime-protocol-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$OUTPUT_DIR/realtime-protocol-checks"
rm -f "$OUTPUT_DIR/loopback-port"
python3 "$APP_DIR/Tests/realtime_websocket_fixture.py" "$OUTPUT_DIR/loopback-port" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
  if [[ -s "$OUTPUT_DIR/loopback-port" ]]; then break; fi
  sleep 0.05
done
[[ -s "$OUTPUT_DIR/loopback-port" ]]
"$OUTPUT_DIR/realtime-protocol-checks" loopback "$(cat "$OUTPUT_DIR/loopback-port")"
wait "$FIXTURE_PID"
