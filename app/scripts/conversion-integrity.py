#!/usr/bin/env python3
"""Record the exact bundled converter tree for offline, same-build repair."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])
files = []
for path in sorted(root.rglob('*')):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        if not path.resolve().is_relative_to(root):
            raise ValueError(f'Converter link leaves resource root: {relative}')
        files.append(dict(path=relative, link=str(path.readlink())))
    elif path.is_file():
        files.append(dict(path=relative, sha256=hashlib.sha256(path.read_bytes()).hexdigest(), bytes=path.stat().st_size))
if not {'ul-pdfium', 'libpdfium.dylib', 'LibreOffice.app/Contents/MacOS/soffice'} <= {entry['path'] for entry in files}:
    raise ValueError('Missing converter executable or library')
data = json.dumps(dict(schema=1, files=files), sort_keys=True, separators=(',', ':')).encode()
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(data)
output.with_suffix('.id').write_text(hashlib.sha256(data).hexdigest() + '\n')
print(f'Converter integrity: {len(files)} entries; {hashlib.sha256(data).hexdigest()}')
