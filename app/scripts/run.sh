#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$TASK_ROOT/app/build/ULecture.app"
if [ ! -x "$APP_DIR/Contents/MacOS/ULecture" ]; then "$TASK_ROOT/app/scripts/build.sh"; fi
open "$APP_DIR"
