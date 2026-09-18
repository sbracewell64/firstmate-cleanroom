"""Real launch barrier and public cleanup CLI; only fixture-owned processes."""
from datetime import datetime, timezone
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time

HOST, ROOT = Path(sys.argv[1]), Path(sys.argv[2])
if sys.platform != 'linux':
    print('SKIP: historical recovery requires Linux proc identities')
    sys.exit(0)
import resource

MODE = sys.argv[3] if len(sys.argv) > 3 else 'graceful'
ROOT = ROOT / MODE
ROOT.mkdir()
HOME = ROOT / 'home'
HOME.mkdir()
EVIDENCE = HOME / 'evidence.txt'
EVIDENCE.write_text('Fixture owns every launched child; source and observations retained here.\n')
EVIDENCE.chmod(0o600)
ENV = dict(os.environ, FM_HOME=str(HOME))
ENV.pop('FM_STATE_OVERRIDE', None)
NODE = shutil.which('node')


def sha(raw):
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


def write(file, value):
    file.write_text(json.dumps(value) + '\n')
    file.chmod(0o600)


def wait_for(predicate):
    until = time.monotonic() + 5
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError('fixture readiness/exit deadline')


def identity(pid):
    p = Path('/proc') / str(pid)
    stat = (p / 'stat').read_text().rsplit(')', 1)[1].split()
    return dict(pid=pid, start_ticks=stat[19], ppid=int(stat[1]), pgid=int(stat[2]),
                sid=int(stat[3]), uid=p.stat().st_uid, exe=os.readlink(p / 'exe'),
                exe_sha256=sha((p / 'exe').read_bytes()),
                cmdline_sha256=sha((p / 'cmdline').read_bytes()), cwd=os.readlink(p / 'cwd'))


def call(record, *args):
    return subprocess.run([NODE, str(HOST), 'cleanup-invocations', '--historical',
                           str(record), *args], env=ENV, capture_output=True, text=True, timeout=10)


fixture = ROOT / 'deleted-fixture'
fixture.mkdir()
ready = ROOT / 'child-ready'
terminated = ROOT / 'child-term'
extra_pid = ROOT / 'extra-pid'
entry = fixture / 'entrypoint.py'
entry.write_text(f'''#!/usr/bin/env python3
import os,signal,time
from pathlib import Path
def stop(*args):
 Path({str(terminated)!r}).write_text('TERM')
 if {MODE!r} in ['stubborn', 'journal-escalation']: return
 if {MODE!r} == 'root-churn':
  Path({str(fixture)!r}).mkdir(exist_ok=True)
  return
 if {MODE!r} == 'member-churn':
  pid=os.fork()
  if pid == 0:
   signal.signal(signal.SIGTERM,signal.SIG_IGN)
   Path({str(extra_pid)!r}).write_text(str(os.getpid()))
   while True: time.sleep(.01)
  return
 raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
Path({str(ready)!r}).write_text(str(os.getpid()))
while True: time.sleep(.01)
''')
entry.chmod(0o700)
host = subprocess.Popen(['sleep', '60'])
token = sha(b'owned fixture recovery')
paths = [fixture / (token[7:] + suffix) for suffix in ['.owner.json', '.ready.json', '.release.json']]
barrier = HOST.with_name('fm-extension-launch-barrier.mjs')
child = subprocess.Popen([NODE, str(barrier), token, *map(str, paths), str(host.pid),
                          str(entry), str(fixture), 'invoke'], cwd=fixture,
                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
# Reap the owned leader concurrently so kernel absence is observable to cleanup.
reaper = threading.Thread(target=child.wait, daemon=True)
reaper.start()
try:
    wait_for(paths[1].exists)
    original = dict(schema='firstmate.extension-invocation-owner.v1', token=token,
                    phase='group', host_pid=host.pid, host_identity='fixture-host',
                    group_pid=child.pid, group_identity='barrier-token:' + token,
                    extension_id='org.example.fixture', binding_digest=sha(b'binding'),
                    request_id=sha(b'request'), source_id='fixture', operation='source.poll')
    write(paths[0], original)
    write(paths[2], dict(schema='firstmate.extension-invocation-release.v1', token=token))
    wait_for(ready.exists)
    member = int(ready.read_text())
    # Retain actual launch-time evidence; never synthesize it during recovery.
    write(HOME / 'original-owner.json', original)
    host.terminate()
    host.wait()
    shutil.rmtree(fixture)
    record = HOME / 'recovery.json'
    snapshot = dict(schema='firstmate.extension-historical-evidence.v1', home=str(HOME),
                    observed_at=datetime.now(timezone.utc).isoformat(),
                    boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                    pid_namespace=os.readlink('/proc/self/ns/pid'),
                    mount_namespace=os.readlink('/proc/self/ns/mnt'), pgid=child.pid,
                    root=str(fixture), launcher=str(barrier), token=token, host_pid=host.pid,
                    members=[identity(child.pid), identity(member)], protected_pids=[os.getpid()],
                    predicates=[dict(established=True, path=str(EVIDENCE), digest=sha(EVIDENCE.read_bytes())) for _ in range(7)])
    write(record, snapshot)
    result = call(record)
    assert result.returncode != 0, result.stdout
    assert json.loads(result.stdout)['reason'] == 'retrospective-authorization-required', result.stderr
    assert child.poll() is None and not terminated.exists()
    print('PASS missing original custody cannot authorize ordinary or evidence-only cleanup')
    ordinary = subprocess.run([NODE, str(HOST), 'cleanup-invocations'], env=ENV,
                              capture_output=True, text=True, timeout=10)
    assert ordinary.returncode == 0 and ordinary.stdout == 'cleaned-invocations: 0\n'
    assert child.poll() is None
    inspected = call(record, '--retrospective')
    assert inspected.returncode == 0, inspected.stdout
    approved = json.loads(inspected.stdout)
    assert approved['status'] == 'ready' and approved['effects'] == []
    if MODE == "graceful":
        def refused(change, reason):
            altered = copy.deepcopy(snapshot)
            change(altered)
            write(record, altered)
            denied = call(record, '--retrospective', '--apply', sha(record.read_bytes()))
            assert denied.returncode != 0, denied.stdout
            result = json.loads(denied.stdout)
            assert result['status'] == 'refused' and result['effects'] == [], result
            assert result['reason'] == reason, result
            assert child.poll() is None and not terminated.exists()
            write(record, snapshot)

        refused(lambda r: r.update(boot_id='changed-boot'), 'historical-namespace-changed')
        refused(lambda r: r.update(pid_namespace='pid:[0]'), 'historical-namespace-changed')
        refused(lambda r: r.update(mount_namespace='mnt:[0]'), 'historical-namespace-changed')
        refused(lambda r: r['members'][0].update(start_ticks='1'), 'historical-identity-changed')
        refused(lambda r: r['members'][1].update(cmdline_sha256=sha(b'other')), 'historical-identity-changed')
        refused(lambda r: r['members'][1].update(exe_sha256=sha(b'other')), 'historical-identity-changed')
        refused(lambda r: r['members'][1].update(uid=0), 'historical-evidence-invalid')
        refused(lambda r: r['members'].pop(), 'historical-members-changed')
        refused(lambda r: r.update(protected_pids=[child.pid, os.getpid()]), 'historical-protected-owner')
        refused(lambda r: r.update(host_pid=os.getpid()), 'historical-host-live')
        refused(lambda r: r.update(home=str(ROOT)), 'historical-home-mismatch')
        refused(lambda r: r.update(observed_at='2000-01-01T00:00:00Z'), 'historical-evidence-stale')
        for i in range(7):
            refused(lambda r, i=i: r['predicates'][i].update(established=False), 'historical-predicate-unproved')
        refused(lambda r: r['predicates'][0].update(digest=sha(b'changed')), 'historical-predicate-changed')
        fixture.mkdir()
        refused(lambda r: None, 'historical-root-recreated')
        fixture.rmdir()
        fixture.symlink_to(HOME, target_is_directory=True)
        refused(lambda r: None, 'historical-root-recreated')
        fixture.unlink()
        registry = HOME / 'state/extension-invocations'
        registry.mkdir(parents=True)
        claim = registry / 'current.owner.json'
        write(claim, original)
        refused(lambda r: None, 'historical-live-claim')
        claim.unlink()
        claim.write_text('malformed current owner')
        claim.chmod(0o600)
        rejected = call(record, '--retrospective')
        assert rejected.returncode != 0 and child.poll() is None
        claim.unlink()
        hardlink = HOME / 'hardlink.json'
        os.link(record, hardlink)
        rejected = call(record, '--retrospective')
        assert json.loads(rejected.stdout)['reason'] == 'historical-file-unsafe'
        hardlink.unlink()
        fifo = HOME / 'fifo'
        os.mkfifo(fifo, 0o600)
        rejected = call(fifo, '--retrospective')
        assert json.loads(rejected.stdout)['reason'] == 'historical-file-unsafe'
        denied = call(record, '--retrospective', '--apply', sha(b'old inspection'))
        assert json.loads(denied.stdout)['reason'] == 'historical-inspection-mismatch'
        assert child.poll() is None and not terminated.exists()
        print('PASS boot/namespace/member identity, protected owner, live/malformed claims, roots, predicates and unsafe evidence refuse without signals')
    if MODE.startswith('journal-'):
        # Impose a real kernel file-size limit, without replacing any file API.
        # Size complete public journal frames, then allow only a 100-byte prefix
        # of the next frame. Field ordering does not affect the encoded length.
        def frame(value):
            return (json.dumps(value, separators=(',', ':'), ensure_ascii=False) + '\n').encode()

        prepared = dict(approved, status='prepared', journal=str(record) + '.retirement.jsonl')
        term_intent = dict(status='signal-intent', signal='SIGTERM', members=approved['before'])
        term_sent = dict(status='signal-sent', signal='SIGTERM')
        complete = []
        if MODE != 'journal-prepared':
            complete.append(prepared)
        if MODE == 'journal-escalation':
            complete.extend([term_intent, term_sent])
        limit = sum(len(frame(row)) for row in complete) + 100

        def bound_journal_file():
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

        completed = subprocess.run([NODE, str(HOST), 'cleanup-invocations', '--historical',
                                    str(record), '--retrospective', '--apply', approved['evidence_digest']],
                                   env=ENV, capture_output=True, text=True, timeout=10,
                                   preexec_fn=bound_journal_file)
        raw = Path(str(record) + '.retirement.jsonl').read_bytes()
        lines = raw.splitlines(keepends=True)
        valid = [json.loads(line) for line in lines if line.endswith(b'\n')]
        # Ensure this exercised the intended short-write boundary, rather than
        # an unrelated earlier refusal or a fixture setup failure.
        assert len(raw) == limit and len(lines[-1]) == 100 and not raw.endswith(b'\n')
        assert [row['status'] for row in valid] == [row['status'] for row in complete]
        receipt = json.loads(completed.stdout)
        evidence = dict(mode=MODE, limit=limit, journal_bytes=len(raw), journal=raw.decode(),
                        complete_records=valid, receipt=receipt, term_observed=terminated.exists(),
                        leader_alive=child.poll() is None, member_alive=Path('/proc', str(member)).exists())
        write(ROOT / 'short-write-result.json', evidence)
        print(json.dumps(evidence), flush=True)
        assert completed.returncode != 0 and receipt['status'] != 'completed', receipt
        if MODE == 'journal-escalation':
            assert terminated.exists() and Path('/proc', str(member)).exists(), 'KILL sent without complete durable escalation intent'
            assert receipt['status'] == 'partial' and receipt['effects'] == ['SIGTERM'], receipt
        else:
            assert not terminated.exists() and child.poll() is None, 'TERM sent without complete durable prepared custody/intent'
            assert receipt['effects'] == [], receipt
        print('PASS ' + MODE + ' short write preserves journal and prevents the next signal')
        sys.exit(0)
    completed = call(record, '--retrospective', '--apply', approved['evidence_digest'])
    receipt = json.loads(completed.stdout)
    journal = [json.loads(line) for line in Path(str(record) + '.retirement.jsonl').read_text().splitlines()]
    assert journal[0]['status'] == 'prepared' and journal[0]['before']
    assert journal[1]['status'] == 'signal-intent' and journal[1]['signal'] == 'SIGTERM'
    assert journal[-1] == receipt
    if MODE in ['root-churn', 'member-churn']:
        assert completed.returncode != 0 and receipt['status'] == 'partial', receipt
        reason = 'historical-root-recreated' if MODE == 'root-churn' else 'historical-members-changed'
        assert receipt['reason'] == reason and receipt['effects'] == ['SIGTERM'], receipt
        assert Path('/proc', str(member)).exists()
        assert not any(row.get('signal') == 'SIGKILL' for row in journal)
        print('PASS post-TERM ' + MODE + ' refuses escalation and preserves partial custody')
    else:
        assert completed.returncode == 0, completed.stdout
        expected_signals = ['SIGTERM', 'SIGKILL'] if MODE == 'stubborn' else ['SIGTERM']
        assert receipt['status'] == 'completed' and receipt['effects'] == expected_signals, receipt
        assert terminated.read_text() == 'TERM'
        assert not Path('/proc', str(child.pid)).exists()
        assert not Path('/proc', str(member)).exists()
        assert (HOME / 'original-owner.json').exists() and EVIDENCE.exists()
        consumed = call(record)
        assert consumed.returncode == 0 and json.loads(consumed.stdout)['status'] == 'absent'
        print('PASS explicit retrospective recovery ' + MODE + ' proves actual extinction and preserves journal')

finally:
    if host.poll() is None:
        host.terminate()
        host.wait()
    # Only this fixture's launch owns the group; no process-table scavenging.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    reaper.join(timeout=5)
    tracked = [child.pid]
    if ready.exists():
        tracked.append(int(ready.read_text()))
    if extra_pid.exists():
        tracked.append(int(extra_pid.read_text()))
    until = time.monotonic() + 5
    while time.monotonic() < until and any(Path('/proc', str(pid)).exists() for pid in tracked):
        time.sleep(.02)
    if any(Path('/proc', str(pid)).exists() for pid in tracked):
        (ROOT.parent / 'historical-cleanup-retain').write_text(str(ROOT))
        raise AssertionError('fixture extinction unproved; retain root and authentic custody evidence')
