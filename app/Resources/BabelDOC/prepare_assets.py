"""Verify and optionally fetch immutable, hash-locked BabelDOC assets."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
lock = json.loads(Path(__file__).with_name('assets.lock.json').read_text())
manifest = {}
for item in lock['files']:
    path = root / item['folder'] / item['name']
    def valid():
        if not path.is_file():
            return False
        with path.open('rb') as stream:
            return hashlib.file_digest(stream, 'sha3_256').hexdigest() == item['sha3_256']
    if not valid() and '--download' in sys.argv:
        path.parent.mkdir(parents=True, exist_ok=True)
        stage = path.with_suffix(path.suffix + '.partial')
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'ULecture-build'})
        with urllib.request.urlopen(request, timeout=120) as response, stage.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        with stage.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha3_256').hexdigest() != item['sha3_256']:
                stage.unlink()
                raise SystemExit('Asset checksum mismatch: ' + item['name'])
        stage.replace(path)
    if not valid():
        raise SystemExit('Missing or invalid bundled asset: ' + item['name'])
    manifest.setdefault(item['folder'], []).append({key: item[key] for key in ('name', 'sha3_256')})
(root / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
print('Verified BabelDOC offline assets:', len(lock['files']))
