#!/usr/bin/env python3
"""Remove build-machine paths from copied Python resources before signing."""
import ast
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
removed = 0
for file in root.rglob('*.pyc'):
    file.unlink()
    removed += 1
for directory in sorted(root.rglob('__pycache__'), reverse=True):
    if not any(directory.iterdir()):
        directory.rmdir()

rewritten = 0
for file in (root/'bin').iterdir():
    if file.is_symlink() or not file.is_file():
        continue
    data = file.read_bytes()
    first, separator, body = data.partition(b'\n')
    # uv uses a shell/Python trampoline when the interpreter path is long or
    # contains spaces. Rewriting only a direct shebang leaves those launchers
    # pointing into the build checkout after the application is moved.
    if first == b'#!/bin/sh':
        lines = body.split(b'\n', 2)
        if (len(lines) == 3 and lines[0].startswith(b"'''exec' ")
                and b'/python' in lines[0] and lines[1] == b"' '''"):
            body = lines[2]
            first = b'#!/relocatable/python'
    if first.startswith(b'#!') and b'/python' in first and b'/usr/bin/' not in first:
        wrapper = b'''#!/bin/sh
''' + b"'''exec' \"$(dirname -- \"$0\")/python3\" \"$0\" \"$@\"\n' '''\n"
        file.write_bytes(wrapper + body)
        rewritten += 1

for file in (root/'lib').glob('python*/_sysconfigdata*.py'):
    text = file.read_text()
    if '@ULecturePythonPrefix@' in text:
        continue
    assignment = next(node for node in ast.parse(text).body
                      if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'build_time_vars' for target in node.targets))
    variables = ast.literal_eval(assignment.value)
    prefix = variables.get('prefix')
    if prefix:
        text = text.replace(prefix, '@ULecturePythonPrefix@')
        text += '''
# ULecture packaging: resolve the standalone runtime after relocation.
import sys as _sys
build_time_vars = {key: value.replace('@ULecturePythonPrefix@', _sys.base_prefix)
                   if isinstance(value, str) else value
                   for key, value in build_time_vars.items()}
'''
        file.write_text(text)
print('Python relocated:', rewritten, 'entry points;', removed, 'compiled caches removed')
