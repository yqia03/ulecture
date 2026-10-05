#!/usr/bin/env python3
"""A bounded, silent launch of this task's app with an isolated temporary library.
No UI automation, permission acceptance, keychain access or audio APIs are used.
"""
import datetime, hashlib, json, pathlib, signal, subprocess, tempfile, time, sys
root = pathlib.Path(__file__).resolve().parents[2]
binary = root / 'app/build/ULecture.app/Contents/MacOS/ULecture'
evidence = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root/'app/evidence'
evidence.mkdir(parents=True, exist_ok=True)
closed = []
folder = pathlib.Path(tempfile.mkdtemp(prefix='ulecture-package-launch-', dir='/private/tmp'))
started = time.monotonic()
with (evidence / 'package-launch.log').open('wb') as log:
    child = subprocess.Popen([str(binary), '--ui-test-workspace', str(folder), '--model-cache', str(folder / 'models')], cwd='/private/tmp', stdout=log, stderr=subprocess.STDOUT, env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(pathlib.Path.home()), 'TMPDIR':'/private/tmp', 'LANG':'en_US.UTF-8'})
    time.sleep(8)
    alive = child.poll() is None
    data_initialized = (folder / 'Workspace/library.sqlite3').exists()
    # Schema filename is observed below; all data belongs to this isolated run.
    files = [str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file()]
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(timeout=5)
report = {
    'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'binary': str(binary), 'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'testLibrary': str(folder/'Workspace'), 'processSurvivedEightSeconds': alive,
    'libraryFiles': files, 'wallSeconds': time.monotonic()-started,
    'stoppedOwnedEarlierTestPIDs': closed, 'testProcessExited': child.returncode is not None,
    'termination': 'SIGTERM after eight seconds, limited to explicitly created test process',
    'uiAutomation': False, 'captureRequested': False, 'playbackRequested': False,
    'cloudEnabled': False, 'credentialsAccessed': False,
    'doesNotProve': 'Native UI interactions, permissions, capture, playback, account or product acceptance'
}
(evidence/'package-launch.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
if not alive or not any('sqlite' in f for f in files):
    raise SystemExit(1)
