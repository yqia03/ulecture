#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$APP_ROOT/Resources/BabelDOC"
DEPENDENCY="$APP_ROOT/Dependencies/babeldoc-runtime"
TARGET="${1:-$DEPENDENCY}"
TOOLS="$APP_ROOT/Dependencies/babeldoc-tools"
mkdir -p "$DEPENDENCY" "$TARGET"
if [ ! -x "$DEPENDENCY/runtime/bin/python3" ]; then
  python3 "$APP_ROOT/scripts/bootstrap.py" --python-only
fi
if [ ! -d "$DEPENDENCY/runtime/lib/python3.12/site-packages/babeldoc" ]; then
  MACOSX_DEPLOYMENT_TARGET=14.0 "$TOOLS/bin/uv" pip install --python "$DEPENDENCY/runtime/bin/python3" --python-platform aarch64-apple-darwin --break-system-packages --require-hashes -r "$SOURCE/requirements-hashed.lock"
fi
PYTHON="$DEPENDENCY/runtime/bin/python3"
if [ ! -f "$DEPENDENCY/assets/manifest.json" ]; then
  "$PYTHON" -B "$SOURCE/prepare_assets.py" "$DEPENDENCY/assets" --download
else
  "$PYTHON" -B "$SOURCE/prepare_assets.py" "$DEPENDENCY/assets"
fi
# Preserve complete wheel distribution metadata and bundled license files.
"$PYTHON" -B - "$SOURCE" "$DEPENDENCY" <<'PY'
import hashlib, importlib.metadata, json, pathlib, platform, sys
source, root = map(pathlib.Path, sys.argv[1:])
expected = dict(line.strip().split('==',1) for line in (source/'requirements.lock').read_text().splitlines() if line.strip() and not line.startswith('#'))
for name, version in expected.items():
    if importlib.metadata.version(name) != version:
        raise SystemExit('BabelDOC runtime version mismatch: ' + name)
packages = []
for distribution in importlib.metadata.distributions():
    packages.append({'name': distribution.metadata['Name'], 'version': distribution.version,
                     'license': distribution.metadata.get('License-Expression') or distribution.metadata.get('License', ''),
                     'licenseFiles': [str(f) for f in (distribution.files or []) if any(x in str(f).lower() for x in ('license', 'copying', 'notice'))]})
manifest = {'schema': 1, 'engine': 'BabelDOC', 'engineVersion': '0.6.4', 'pythonVersion': platform.python_version(),
            'source': 'https://github.com/funstory-ai/BabelDOC/tree/v0.6.4', 'license': 'AGPL-3.0',
            'requirementsSHA256': hashlib.sha256((source/'requirements.lock').read_bytes()).hexdigest(),
            'assetsManifestSHA256': hashlib.sha256((root/'assets/manifest.json').read_bytes()).hexdigest(),
            'packages': sorted(packages, key=lambda p: p['name'].lower())}
(root/'runtime-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2)+'\n')
PY
cp "$SOURCE/worker.py" "$SOURCE/requirements.lock" "$SOURCE"/LICENSE-*.txt "$DEPENDENCY/"
if [ "$(cd "$TARGET" && pwd)" != "$(cd "$DEPENDENCY" && pwd)" ]; then
  ditto "$DEPENDENCY" "$TARGET"
fi
python3 "$APP_ROOT/scripts/relocate-python.py" "$TARGET/runtime"
# Native wheels and standalone Python use relative loader paths. Sign every
# native object before the enclosing application is signed by build.sh.
"$PYTHON" -B - "$TARGET/runtime" <<'PY'
import pathlib, re, subprocess, sys
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for path in pathlib.Path(sys.argv[1]).rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as f:
        native = f.read(4) in magic
    if native:
        build = subprocess.run(['/usr/bin/xcrun', 'vtool', '-show-build', str(path)], check=True, capture_output=True, text=True).stdout
        for minimum in re.findall(r'^\s+minos ([0-9]+\.[0-9]+(?:\.[0-9]+)?)', build, re.M):
            version = tuple(map(int, minimum.split('.')))
            if version + (0,) * (3 - len(version)) > (14, 0, 0):
                raise SystemExit('BabelDOC native library requires newer than macOS 14: ' + str(path))
        subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(path)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
PY
"$TARGET/runtime/bin/python3" -I -B -c 'import babeldoc.const, pymupdf, onnxruntime, httpx, hyperscan; assert babeldoc.const.__version__ == "0.6.4"'
printf 'Bundled BabelDOC runtime: %s\n' "$TARGET"
