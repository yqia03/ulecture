"""Exercise installed console launchers after a real directory relocation."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/relocate-python.py'


class PythonRelocationChecks(unittest.TestCase):
    def test_console_launchers_survive_spaces_and_long_build_prefix(self):
        with tempfile.TemporaryDirectory(prefix='ulecture-python-') as directory:
            base = Path(directory)
            source = base / ('long build checkout ' * 9) / 'runtime'
            (source / 'bin').mkdir(parents=True)
            os.symlink(sys.executable, source / 'bin/python3')
            code = b'import sys\nprint("portable:" + sys.argv[1])\n'
            launchers = {
                'direct': b'#!' + str(source / 'bin/python3').encode() + b'\n' + code,
                'uv-trampoline': b"#!/bin/sh\n'''exec' '" + str(source / 'bin/python3').encode() + b"' \"$0\" \"$@\"\n' '''\n" + code,
                'already-relative': b"#!/bin/sh\n'''exec' \"$(dirname -- \"$0\")/python3\" \"$0\" \"$@\"\n' '''\n" + code,
            }
            for name, content in launchers.items():
                path = source / 'bin' / name
                path.write_bytes(content)
                path.chmod(0o755)
            subprocess.run([sys.executable, str(SCRIPT), str(source)], check=True, capture_output=True)
            destination = base / 'application copy with spaces' / 'runtime'
            destination.parent.mkdir()
            shutil.move(source, destination)
            for name in launchers:
                with self.subTest(launcher=name):
                    path = destination / 'bin' / name
                    self.assertNotIn(str(source).encode(), path.read_bytes())
                    result = subprocess.check_output([str(path), 'works'], text=True)
                    self.assertEqual(result.strip(), 'portable:works')
            first = {name: (destination / 'bin' / name).read_bytes() for name in launchers}
            subprocess.run([sys.executable, str(SCRIPT), str(destination)], check=True, capture_output=True)
            self.assertEqual(first, {name: (destination / 'bin' / name).read_bytes() for name in launchers})

    def test_removes_cache_preserves_system_shebang_and_relocates_config(self):
        with tempfile.TemporaryDirectory(prefix='ulecture-python-') as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            system = root / 'bin/system-tool'
            system.write_text('#!/usr/bin/python3\nprint("system")\n')
            lib = root / 'lib/python3.12'
            (lib / '__pycache__').mkdir(parents=True)
            (lib / '__pycache__/example.pyc').write_bytes(b'old-path-bytecode')
            config = lib / '_sysconfigdata__darwin_darwin.py'
            config.write_text("build_time_vars = {'prefix': '/original-build', 'LIBDIR': '/original-build/lib', 'VERSION': 312}\n")
            subprocess.run([sys.executable, str(SCRIPT), str(root)], check=True, capture_output=True)
            self.assertFalse((lib / '__pycache__').exists())
            self.assertTrue(system.read_text().startswith('#!/usr/bin/python3\n'))
            scope = {}
            exec(config.read_text(), scope)
            self.assertEqual(scope['build_time_vars']['LIBDIR'], sys.base_prefix + '/lib')
            self.assertEqual(scope['build_time_vars']['VERSION'], 312)
            self.assertNotIn('/original-build', config.read_text())


if __name__ == '__main__':
    unittest.main()
