#!/usr/bin/env python3
"""Record exact packaged inputs, and reject publication when the workspace changed during build."""
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys

SOURCE_SECTIONS = ('Sources', 'Native', 'Resources', 'scripts')
DISTRIBUTION_FILES = ('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md')
CAPTURE_NAME = '.release-inputs.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()

def files(root):
    return {str(file.relative_to(root)): digest(file) for section in SOURCE_SECTIONS
            for file in sorted((root / section).rglob('*')) if file.is_file()
            and not (section == 'scripts' and ('__pycache__' in file.parts or file.suffix == '.pyc'))}


def release_inputs(app):
    return {
        'appFiles': {str(file.relative_to(app)): digest(file)
                     for file in sorted((app / 'DependencyLocks').rglob('*')) if file.is_file()},
        'distributionFiles': {name: digest(app.parent / name) for name in DISTRIBUTION_FILES},
    }


def input_tree(sources, release):
    return {**{'app/' + name: value for name, value in sources.items()},
            **{'app/' + name: value for name, value in release['appFiles'].items()},
            **release['distributionFiles']}


def tree_digest(entries):
    # Canonical UTF-8 JSON path -> SHA-256 map; independent of checkout path and Git.
    return hashlib.sha256(json.dumps(entries, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode('utf-8')).hexdigest()


def public_inputs(entries):
    # Models are materialized from committed model locks, never stored in Git.
    return {name: value for name, value in entries.items()
            if not name.startswith('app/Resources/Models/')}


def changed_paths(expected, current):
    return sorted(key for key in set(expected) | set(current)
                  if expected.get(key) != current.get(key))


def verify_inputs(manifest, app, public_commit=None):
    if manifest.get('version') != 2 or not manifest.get('workspaceMatchesSnapshot'):
        raise ValueError('Missing verified version 2 build input manifest')
    expected = input_tree(manifest['sources'], manifest['releaseInputs'])
    current = input_tree(files(app), release_inputs(app))
    changed = changed_paths(expected, current)
    if changed:
        raise ValueError('Build input differs: ' + ', '.join(changed))
    if manifest['buildInputTreeSHA256'] != tree_digest(expected):
        raise ValueError('Build input tree identity differs')
    if manifest['publicSourceInputs'] != public_inputs(expected):
        raise ValueError('Public source input coverage differs')
    if manifest['publicSourceTreeSHA256'] != tree_digest(manifest['publicSourceInputs']):
        raise ValueError('Public source input tree identity differs')
    if public_commit is not None:
        if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', public_commit):
            raise ValueError('Public commit must be a full Git commit hash')
        resolved = subprocess.check_output(['git', '-C', str(app.parent), 'rev-parse',
                                            '--verify', public_commit + '^{commit}'], text=True).strip()
        if resolved != public_commit.lower():
            raise ValueError('Public commit identity differs')
        listing = subprocess.check_output(['git', '-C', str(app.parent), 'ls-tree', '-rz',
                                            '--name-only', resolved, '--',
                                            *('app/' + section for section in SOURCE_SECTIONS),
                                            'app/DependencyLocks', *DISTRIBUTION_FILES])
        committed_paths = {name.decode('utf-8') for name in listing.split(b'\0') if name
                           and not name.startswith(b'app/Resources/Models/')}
        if committed_paths != set(manifest['publicSourceInputs']):
            raise ValueError('Public commit input coverage differs: ' +
                             ', '.join(sorted(committed_paths ^ set(manifest['publicSourceInputs']))))
        for name, expected_hash in manifest['publicSourceInputs'].items():
            content = subprocess.run(['git', '-C', str(app.parent), 'show', resolved + ':' + name],
                                     capture_output=True)
            if content.returncode != 0 or hashlib.sha256(content.stdout).hexdigest() != expected_hash:
                raise ValueError('Public commit input differs: ' + name)
        public_commit = resolved
    return {'buildInputTreeSHA256': manifest['buildInputTreeSHA256'],
            'publicSourceTreeSHA256': manifest['publicSourceTreeSHA256'],
            'publicCommit': public_commit,
            'publicCommitVerified': public_commit is not None}


def finish(snapshot, app, output):
    capture = snapshot / CAPTURE_NAME
    if not capture.is_file():
        raise ValueError('Missing build-start release input capture; call --capture-release-inputs before compilation')
    release = json.loads(capture.read_text())
    sources = files(snapshot)
    inputs = input_tree(sources, release)
    current = input_tree(files(app), release_inputs(app))
    changed = changed_paths(inputs, current)
    locks = {str(path.relative_to(app)): json.loads(path.read_text())
             for path in sorted((app / 'Dependencies').glob('*/dependency-lock.json'))}
    published = public_inputs(inputs)
    manifest = {
        'format': 'ulecture-build-manifest', 'version': 2,
        'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'deploymentTarget': 'arm64-apple-macos14.0', 'sources': sources,
        'releaseInputs': release, 'dependencies': locks,
        'buildInputTreeSHA256': tree_digest(inputs),
        'publicSourceInputs': published, 'publicSourceTreeSHA256': tree_digest(published),
        'sourceControl': {'publicCommit': None,
                          'association': 'Verify the public commit against publicSourceInputs after publication; no local development commit is claimed as the release commit.',
                          'coverage': 'Build input files only; models are covered by buildInputTreeSHA256 and committed locks. Documentation and media outside these inputs are not part of this identity.'},
        'treeHashEncoding': 'SHA-256 of UTF-8 JSON path-to-SHA256 map, sorted keys, ensure_ascii=false, separators=(comma,colon)',
        'nativeArchiveSHA256': digest(app / 'build/libClassroomASR.a'),
        'compiler': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'workspaceMatchesSnapshot': not changed, 'changedDuringBuild': changed,
    }
    output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    if changed:
        raise ValueError('Source or release inputs changed during compilation; rebuild before delivery: ' + ', '.join(changed))


def main(arguments):
    if len(arguments) == 3 and arguments[0] == '--capture-release-inputs':
        snapshot, app = map(pathlib.Path, arguments[1:])
        (snapshot / CAPTURE_NAME).write_text(json.dumps(release_inputs(app), sort_keys=True, indent=2) + '\n')
    elif len(arguments) in (3, 5) and arguments[0] == '--verify-inputs':
        manifest, app = map(pathlib.Path, arguments[1:3])
        if len(arguments) == 5 and arguments[3] != '--public-commit':
            raise ValueError('Expected --public-commit COMMIT')
        commit = arguments[4] if len(arguments) == 5 else None
        print(json.dumps(verify_inputs(json.loads(manifest.read_text()), app, commit), indent=2))
    elif len(arguments) == 3 and not arguments[0].startswith('--'):
        finish(*map(pathlib.Path, arguments))
    else:
        raise ValueError('Usage: build-manifest.py SNAPSHOT APP OUTPUT | --capture-release-inputs SNAPSHOT APP | --verify-inputs MANIFEST APP [--public-commit COMMIT]')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
