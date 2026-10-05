#!/usr/bin/env python3
"""Exercise the real cache sanitizer with path-bearing Python bytecode."""
import hashlib
import pathlib
import py_compile
import subprocess
import sys
import tempfile

helper = pathlib.Path(__file__).resolve().parents[1] / 'scripts/sanitize-python-caches.py'
with tempfile.TemporaryDirectory(prefix='ulecture-cache-hygiene-') as temporary:
    root = pathlib.Path(temporary)
    source = root / 'fictional.py'
    source.write_text('VALUE = "fictional module"\n')
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    cached = pathlib.Path(py_compile.compile(str(source), doraise=True))
    assert str(source).encode() in cached.read_bytes(), 'Fixture lacks the leaking compile filename'
    command = [sys.executable, '-B', str(helper), str(root)]
    assert subprocess.run(command + ['--check'], capture_output=True).returncode == 1
    subprocess.run(command, check=True)
    subprocess.run(command + ['--check'], check=True)
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original
    subprocess.run(command, check=True)  # Repeated staging cleanup is harmless.
    sourceless = root / 'required-module.pyc'
    sourceless.write_bytes(b'fictional sourceless dependency')
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert sourceless.exists(), 'Sourceless dependency was silently deleted'
print('PASS: leaking cache detected, source preserved, cleanup repeatable, sourceless bytecode refused')
