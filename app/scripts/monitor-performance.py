"""Observe a macOS performance replay and request a safe drain if evidence becomes invalid.

Raw process observations may identify other local applications. Keep monitor.jsonl
private and publish only aggregate clock, power, and competition observations.
"""
import argparse
import ctypes
import datetime
import json
import pathlib
import re
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('run_directory', type=pathlib.Path, help='Fresh output directory also passed to check-performance.sh')
args = parser.parse_args()
run = args.run_directory.resolve()
run.mkdir(parents=True, exist_ok=True)
if (run / 'monitor.jsonl').exists():
    parser.error('monitor.jsonl already exists; use a fresh run directory to avoid mixing sessions')

lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

tb = Timebase()
lib.mach_timebase_info(ctypes.byref(tb))
lib.mach_absolute_time.restype = ctypes.c_uint64
lib.mach_continuous_time.restype = ctypes.c_uint64

def clocks():
    return {
        'awakeSeconds': lib.mach_absolute_time() * tb.numer / tb.denom / 1e9,
        'continuousSeconds': lib.mach_continuous_time() * tb.numer / tb.denom / 1e9,
        'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }

def read(name):
    try:
        return json.loads((run / name).read_text())
    except (OSError, ValueError):
        return None

def stop(reason, row):
    evidence = {'reason': reason, 'observation': row}
    (run / 'monitor-ineligible.json').write_text(json.dumps(evidence, indent=2))
    (run / 'stop-request').write_text(reason)

def interrupted(signum, _frame):
    raise RuntimeError(f'Independent monitor interrupted by signal {signum}')

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

origin = clocks()
previous = origin
last_power = 0
last_progress = None
last_advance = origin['awakeSeconds']
max_observer_gap = 0
max_sleep = 0
row = origin
observations = 0
active_observations = 0
completed = False
monitor_error = None

try:
    with (run / 'monitor.jsonl').open('x', buffering=1) as output:
        for _ in range(1500):
            row = clocks()
            row['monitorIntervalAwakeSeconds'] = row['awakeSeconds'] - previous['awakeSeconds']
            row['elapsedAwakeSeconds'] = row['awakeSeconds'] - origin['awakeSeconds']
            row['elapsedContinuousSeconds'] = row['continuousSeconds'] - origin['continuousSeconds']
            row['excludedSystemSleepSeconds'] = max(0, row['elapsedContinuousSeconds'] - row['elapsedAwakeSeconds'])
            max_observer_gap = max(max_observer_gap, row['monitorIntervalAwakeSeconds'])
            max_sleep = max(max_sleep, row['excludedSystemSleepSeconds'])
            for name in ['started.json', 'progress.json', 'results.json', 'failure.json', 'reopen.json']:
                value = read(name)
                if value:
                    row[name] = value
            started = row.get('started.json')
            if started and origin['awakeSeconds'] > started['uptime']:
                stop('Independent observer started after the replay; initial coverage is missing.', row)
            ps = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,pcpu=,comm='], text=True)
            processes = {}
            for line in ps.splitlines():
                parts = line.split(None, 4)
                if len(parts) == 5:
                    processes[int(parts[0])] = {
                        'ppid': int(parts[1]), 'rssKiB': int(parts[2]),
                        'cpuPercent': float(parts[3]), 'command': pathlib.Path(parts[4]).name,
                    }
            pid = row.get('started.json', {}).get('pid')
            chosen = {pid} if pid in processes else set()
            while True:
                extra = {k for k, v in processes.items() if v['ppid'] in chosen} - chosen
                if not extra:
                    break
                chosen |= extra
            row['processTree'] = {str(k): processes[k] for k in chosen}
            competitors = ['swift-frontend', 'ffmpeg', 'media_checks', 'promo', 'ULecture', 'codesign', 'ditto', 'zip', 'hdiutil']
            row['knownCompetitors'] = {str(k): v for k, v in processes.items() if k not in chosen and any(s in v['command'] for s in competitors)}
            busiest = sorted(processes.items(), key=lambda item: item[1]['cpuPercent'], reverse=True)[:12]
            row['highCPUProcesses'] = {str(k): v for k, v in busiest if k not in chosen and v['cpuPercent'] >= 10}
            if row['awakeSeconds'] - last_power >= 60:
                last_power = row['awakeSeconds']
                row['power'] = subprocess.check_output(['pmset', '-g', 'batt'], text=True)
                percentage = re.search(r'(\d+)%;', row['power'])
                if percentage and int(percentage[1]) < 10:
                    stop('Battery below 10%; safe drain required regardless of the AC power label.', row)
            if max_sleep > 2:
                stop('System sleep observed; this session cannot establish uninterrupted acceptance.', row)
            if max_observer_gap > 30:
                stop('Independent observer missed more than 30 awake seconds; continuous evidence is incomplete.', row)
            wall = row.get('progress.json', {}).get('wallSeconds')
            if wall is not None and not row.get('results.json') and not row.get('failure.json'):
                active_observations += 1
            if wall is not None and wall != last_progress:
                last_progress = wall
                last_advance = row['awakeSeconds']
            if pid in processes and not row.get('results.json') and not row.get('failure.json') and wall is not None and row['awakeSeconds'] - last_advance > 45:
                stop('Process progress has not advanced for more than 45 awake seconds.', row)
            output.write(json.dumps(row, ensure_ascii=False) + '\n')
            observations += 1
            previous = row
            if row.get('reopen.json') or (row.get('failure.json') and pid not in processes):
                completed = True
                break
            time.sleep(10)
        if not completed:
            stop('Independent observer reached its time limit before a terminal result.', row)
except (Exception, KeyboardInterrupt) as error:
    monitor_error = f'{type(error).__name__}: {error}'
    (run / 'monitor-failure.json').write_text(json.dumps({'utc': clocks()['utc'], 'error': monitor_error}, indent=2))
    stop('Independent observer failed; continuous verification is invalid.', row)
finally:
    started = row.get('started.json', {})
    started_before_replay = bool(started and origin['awakeSeconds'] <= started['uptime'])
    requested_seconds = started.get('requestedSeconds', 0)
    observed_replay_seconds = max(0, row['awakeSeconds'] - started['uptime']) if started else 0
    full_period_observed = started_before_replay and requested_seconds > 0 and observed_replay_seconds >= requested_seconds
    reopened = bool(row.get('reopen.json', {}).get('passed'))
    successful_result = bool(row.get('results.json', {}).get('passed'))
    summary = {
        'monitorCompleted': completed,
        'monitorError': monitor_error,
        'evidenceEligible': completed and monitor_error is None and not (run / 'monitor-ineligible.json').exists()
            and full_period_observed and active_observations >= 2 and reopened and successful_result,
        'observations': observations,
        'activeReplayObservations': active_observations,
        'firstObservationUTC': origin['utc'],
        'lastObservationUTC': row['utc'],
        'largestObserverAwakeGapSeconds': max_observer_gap,
        'excludedSystemSleepSeconds': max_sleep,
        'startedBeforeReplay': started_before_replay,
        'observedReplaySeconds': observed_replay_seconds,
        'requestedSeconds': requested_seconds,
        'fullRequestedPeriodObserved': full_period_observed,
        'observedFreshProcessReopen': reopened,
        'boundary': 'Independent observer validity only; replay duration, data integrity, capture coverage and budgets must be checked separately.',
    }
    (run / 'monitor-summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))

sys.exit(1 if monitor_error or not summary['evidenceEligible'] else 0)
