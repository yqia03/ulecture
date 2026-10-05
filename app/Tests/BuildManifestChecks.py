#!/usr/bin/env python3
"""Isolated build-input provenance checks; no application build or network required."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/build-manifest.py'


class BuildManifestChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ulecture-build-manifest-')
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / 'app'
        self.snapshot = self.root / 'snapshot'
        for section in ('Sources', 'Native', 'Resources', 'scripts', 'DependencyLocks'):
            (self.app / section).mkdir(parents=True)
            (self.app / section / 'fixture.txt').write_text('fictional input\n')
        for name in ('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md'):
            (self.root / name).write_text('fictional notice\n')
        (self.app / 'build').mkdir()
        (self.app / 'build/libClassroomASR.a').write_bytes(b'fictional archive')
        for section in ('Sources', 'Native', 'Resources', 'scripts'):
            shutil.copytree(self.app / section, self.snapshot / section)
        self.manifest = self.root / 'build-manifest.json'

    def tearDown(self):
        self.temporary.cleanup()

    def run_script(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, arguments)],
                              capture_output=True, text=True)

    def capture(self):
        result = self.run_script('--capture-release-inputs', self.snapshot, self.app)
        self.assertEqual(result.returncode, 0, result.stderr)

    def finish(self):
        return self.run_script(self.snapshot, self.app, self.manifest)

    def test_no_git_checkout_records_locks_and_distribution_files(self):
        self.capture()
        result = self.finish()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.manifest.read_text())
        self.assertIn('DependencyLocks/fixture.txt', manifest['releaseInputs']['appFiles'])
        self.assertEqual(set(manifest['releaseInputs']['distributionFiles']),
                         {'LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md'})
        self.assertIsNone(manifest['sourceControl']['publicCommit'])
        result = self.run_script('--verify-inputs', self.manifest, self.app)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changes_during_build_block_release(self):
        self.capture()
        (self.app / 'DependencyLocks/fixture.txt').write_text('changed lock\n')
        (self.root / 'THIRD_PARTY_NOTICES.md').write_text('changed notice\n')
        result = self.finish()
        self.assertNotEqual(result.returncode, 0)
        manifest = json.loads(self.manifest.read_text())
        self.assertFalse(manifest['workspaceMatchesSnapshot'])
        self.assertEqual(manifest['changedDuringBuild'],
                         ['THIRD_PARTY_NOTICES.md', 'app/DependencyLocks/fixture.txt'])

    def test_added_or_deleted_lock_blocks_release(self):
        self.capture()
        (self.app / 'DependencyLocks/fixture.txt').unlink()
        (self.app / 'DependencyLocks/extra.txt').write_text('extra\n')
        result = self.finish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('app/DependencyLocks/extra.txt', result.stderr)
        self.assertIn('app/DependencyLocks/fixture.txt', result.stderr)

    def test_verify_detects_notice_change_after_build(self):
        self.capture()
        self.assertEqual(self.finish().returncode, 0)
        (self.root / 'COPYRIGHT').write_text('changed after build\n')
        result = self.run_script('--verify-inputs', self.manifest, self.app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('COPYRIGHT', result.stderr)

    def test_missing_build_start_capture_blocks_release(self):
        result = self.finish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing build-start release input capture', result.stderr)

    def test_models_not_in_public_git_inputs_but_still_verified(self):
        (self.app / 'Resources/Models').mkdir()
        (self.app / 'Resources/Models/fixture.bin').write_bytes(b'fictional model')
        shutil.copytree(self.app / 'Resources/Models', self.snapshot / 'Resources/Models')
        self.capture()
        self.assertEqual(self.finish().returncode, 0)
        manifest = json.loads(self.manifest.read_text())
        self.assertIn('Resources/Models/fixture.bin', manifest['sources'])
        self.assertNotIn('app/Resources/Models/fixture.bin', manifest['publicSourceInputs'])
        (self.app / 'Resources/Models/fixture.bin').write_bytes(b'changed model')
        result = self.run_script('--verify-inputs', self.manifest, self.app)
        self.assertNotEqual(result.returncode, 0)

    def test_running_verifier_does_not_add_script_bytecode_to_source_identity(self):
        self.capture()
        self.assertEqual(self.finish().returncode, 0)
        cache = self.app / 'scripts/__pycache__'
        cache.mkdir()
        (cache / 'build-manifest.cpython-test.pyc').write_bytes(b'generated bytecode')
        result = self.run_script('--verify-inputs', self.manifest, self.app)
        self.assertEqual(result.returncode, 0, result.stderr)

    def git(self, *arguments):
        return subprocess.check_output(['git', '-C', str(self.root),
                                        '-c', 'core.hooksPath=/dev/null',
                                        '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                                        '-c', 'commit.gpgsign=false', *arguments],
                                       text=True, stderr=subprocess.DEVNULL).strip()

    def test_public_commit_requires_matching_build_input_files(self):
        self.git('init', '-q')
        self.git('add', '--', 'app/Sources', 'app/Native', 'app/Resources', 'app/scripts',
                 'app/DependencyLocks', *('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md'))
        self.git('commit', '-qm', 'Fictional fixture')
        commit = self.git('rev-parse', 'HEAD')
        self.capture()
        self.assertEqual(self.finish().returncode, 0)
        result = self.run_script('--verify-inputs', self.manifest, self.app,
                                 '--public-commit', commit)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['publicCommit'], commit)
        # A later source tree cannot be advertised as the first commit.
        (self.app / 'Sources/fixture.txt').write_text('uncommitted source\n')
        (self.snapshot / 'Sources/fixture.txt').write_text('uncommitted source\n')
        self.assertEqual(self.finish().returncode, 0)
        result = self.run_script('--verify-inputs', self.manifest, self.app,
                                 '--public-commit', commit)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Public commit input differs: app/Sources/fixture.txt', result.stderr)

    def test_public_commit_cannot_have_extra_uncompiled_sources(self):
        self.git('init', '-q')
        extra = self.app / 'Sources/extra.swift'
        extra.write_text('// fictional uncompiled source\n')
        self.git('add', '--', 'app/Sources', 'app/Native', 'app/Resources', 'app/scripts',
                 'app/DependencyLocks', *('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md'))
        self.git('commit', '-qm', 'Fictional extra source')
        commit = self.git('rev-parse', 'HEAD')
        extra.unlink()
        self.capture()
        self.assertEqual(self.finish().returncode, 0)
        result = self.run_script('--verify-inputs', self.manifest, self.app,
                                 '--public-commit', commit)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Public commit input coverage differs', result.stderr)


if __name__ == '__main__':
    unittest.main()
