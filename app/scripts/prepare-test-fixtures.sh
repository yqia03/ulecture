#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$APP_ROOT/build/fixture-python"
UV="$APP_ROOT/Dependencies/babeldoc-tools/bin/uv"
if [ ! -x "$UV" ]; then python3 "$APP_ROOT/scripts/bootstrap.py" --python-only; fi
if [ ! -x "$ENV_DIR/bin/python3" ]; then "$UV" venv --python "$APP_ROOT/Dependencies/babeldoc-runtime/runtime/bin/python3" "$ENV_DIR"; fi
"$UV" pip install --python "$ENV_DIR/bin/python3" reportlab==4.4.9 pillow==12.1.1 pypdf==6.8.0 python-pptx==1.0.2 msoffcrypto-tool==5.4.2 olefile==0.47
"$ENV_DIR/bin/python3" "$APP_ROOT/Tests/make-conversion-fixtures.py" "$APP_ROOT/Tests/Fixtures/Conversion"
"$ENV_DIR/bin/python3" "$APP_ROOT/Tests/make-encrypted-slide-fixture.py" "$APP_ROOT/Tests/Fixtures/Conversion"
LO="$APP_ROOT/Dependencies/libreoffice-26.8.0/LibreOffice.app/Contents/MacOS/soffice"
if [ -x "$LO" ] && [ ! -f "$APP_ROOT/Tests/Fixtures/Conversion/lesson.ppt" ]; then
  PROFILE_DIR="$(mktemp -d "$APP_ROOT/build/fixture-office-XXXXXX")"
  PROFILE_URL="$("$ENV_DIR/bin/python3" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri())' "$PROFILE_DIR")"
  PYTHONDONTWRITEBYTECODE=1 "$LO" "-env:UserInstallation=$PROFILE_URL" --headless --convert-to 'ppt:MS PowerPoint 97' --outdir "$APP_ROOT/Tests/Fixtures/Conversion" "$APP_ROOT/Tests/Fixtures/Conversion/lesson.pptx"
fi
