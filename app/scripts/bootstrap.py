#!/usr/bin/env python3
"""Fetch exact build inputs. Never stores large dependencies in Git."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

APP = Path(__file__).resolve().parents[1]
LOCK = json.loads((APP / 'DependencyLocks/native.lock.json').read_text())

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()

def fetch(url, expected, path):
    if path.is_file() and digest(path) == expected:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_suffix(path.suffix + '.partial')
    request = urllib.request.Request(url, headers={'User-Agent': 'ULecture-build'})
    print('Downloading', path.name, flush=True)
    with urllib.request.urlopen(request, timeout=120) as response, stage.open('wb') as output:
        for chunk in iter(lambda: response.read(1024 * 1024), b''):
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    if digest(stage) != expected:
        stage.unlink()
        raise SystemExit('Checksum mismatch: ' + path.name)
    stage.replace(path)
    return path

def archive(key, name):
    item = LOCK[key]
    return fetch(item.get('url', item.get('artifactURL')),
                 item.get('sha256', item.get('artifactSHA256')), DEP / name)

def extract(archive_path, destination, strip=0):
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/tar', '-xf', str(archive_path), '-C', str(destination),
                    '--strip-components=' + str(strip)], check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-only', action='store_true')
    parser.add_argument('--skip-runtime', action='store_true')
    args = parser.parse_args()
    DEP.mkdir(exist_ok=True)
    uv = archive('uv', 'downloads/uv-0.11.7.tar.gz')
    if not (DEP / 'babeldoc-tools/bin/uv').is_file():
        extract(uv, DEP / 'babeldoc-tools/bin', 1)
    python = archive('python', 'downloads/python-3.12.12-20260211.tar.gz')
    if not (DEP / 'babeldoc-runtime/runtime/bin/python3').is_file():
        extract(python, DEP / 'babeldoc-runtime/runtime', 1)
    if args.python_only:
        return
    whisper = archive('whisper.cpp', 'whisper.cpp-927cfce.tar.gz')
    source = DEP / ('whisper.cpp-' + LOCK['whisper.cpp']['version'])
    if not (source / 'CMakeLists.txt').is_file():
        extract(whisper, DEP)
    cmake = archive('cmake', 'downloads/cmake-3.31.6.tar.gz')
    if not (DEP / 'cmake-3.31.6/bin/cmake').is_file():
        extract(cmake, DEP / 'cmake-3.31.6', 3)
    pdfium = archive('pdfium-7999', 'pdfium-7999/pdfium-mac-arm64.tgz')
    if not (DEP / 'pdfium-7999/lib/libpdfium.dylib').is_file():
        extract(pdfium, DEP / 'pdfium-7999')
    office = archive('libreoffice-26.8.0', 'libreoffice-26.8.0/LibreOffice.dmg')
    if not (DEP / 'libreoffice-26.8.0/LibreOffice.app/Contents/MacOS/soffice').is_file():
        with tempfile.TemporaryDirectory(prefix='ulecture-mount-') as mount:
            subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse',
                            '-mountpoint', mount, str(office)], check=True)
            try:
                subprocess.run(['/usr/bin/ditto', str(Path(mount) / 'LibreOffice.app'),
                                str(DEP / 'libreoffice-26.8.0/LibreOffice.app')], check=True)
            finally:
                subprocess.run(['/usr/bin/hdiutil', 'detach', mount], check=True)
    for name in ('pdfium-7999', 'libreoffice-26.8.0'):
        (DEP / name / 'dependency-lock.json').write_text(json.dumps(LOCK[name], indent=2) + '\n')
    models = json.loads((APP / 'DependencyLocks/models.lock.json').read_text())
    for item in models:
        fetch(item['url'], item['sha256'], APP / 'Resources/Models' / item['name'])
    if not args.skip_runtime:
        subprocess.run(['bash', str(APP / 'scripts/build-babeldoc-runtime.sh')], check=True)
    print('Pinned build inputs are ready.')

DEP = APP / 'Dependencies'
if __name__ == '__main__':
    main()
