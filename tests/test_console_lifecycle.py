"""Drive the real Desktop caller through workspace ownership and convergence."""
import json
import os
import select
import time
import threading
from pathlib import Path
import subprocess
import sys
import unittest
from launcher_fixture import BASH, LauncherFixture, shellpath

ENTRY = Path(sys.argv.pop(1)).resolve()

@unittest.skipUnless(sys.platform.startswith('linux'), 'server ownership uses Linux /proc; native proof is Linux')
class LifecycleTests(unittest.TestCase):
    def setUp(self): self.f = LauncherFixture(ENTRY)
    def tearDown(self): self.f.close()
    def test_existing_shell_and_harness_attach_without_wait(self):
        # Real Herdr reports the wrapper and its harness in one foreground group.
        # Only this external process observation is substituted; the Desktop
        # caller, ownership validation, readiness and attach path all execute.
        child = subprocess.Popen(['/bin/sleep', '30'])
        try:
            self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='launching')
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            processes = [{'name':'bash','pid':os.getpid()}, {'name':'codex','pid':child.pid}]
            for rows in (processes, list(reversed(processes))):
                with self.subTest(order=[row['name'] for row in rows]):
                    (self.f.root/'attached').unlink(missing_ok=True)
                    (self.f.root/'process-info').write_text(json.dumps({'result': {
                        'type':'pane_process_info', 'process_info': {
                            'pane_id':'w7:p1', 'shell_pid':os.getpid(),
                            'foreground_process_group_id':os.getpid(),
                            'foreground_processes':rows}}}))
                    result = self.f.run(FM_ENTRY_STARTUP_WAIT='0', FM_ENTRY_NO_ATTACH='')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((self.f.root/'attached').exists())
                    self.assertEqual(self.f.effects(), '')
        finally:
            child.terminate(); child.wait(timeout=5)

    def test_ambiguous_or_unreadable_process_group_never_attaches(self):
        children = [subprocess.Popen(['/bin/sleep', '30']) for _ in range(2)]
        try:
            self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='launching')
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            rows = [{'name':'bash','pid':os.getpid()}] + [
                {'name':'codex','pid':child.pid} for child in children]
            cases = [rows, list(reversed(rows)), [],
                     [{'name':'codex','pid':children[0].pid}] * 2,
                     [{'name':'codex','pid':'not-a-pid'}],
                     [{'name':'codex','pid':children[0].pid + .5}]]
            for processes in cases:
                with self.subTest(processes=processes):
                    (self.f.root/'process-info').write_text(json.dumps({'result': {
                        'type':'pane_process_info', 'process_info': {
                            'pane_id':'w7:p1', 'shell_pid':os.getpid(),
                            'foreground_processes':processes}}}))
                    result = self.f.run(FM_ENTRY_STARTUP_WAIT='0', FM_ENTRY_NO_ATTACH='')
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertFalse((self.f.root/'attached').exists())
                    self.assertEqual(self.f.effects(), '')
        finally:
            for child in children:
                child.terminate(); child.wait(timeout=5)

    def test_foreign_harness_in_group_is_not_owned(self):
        console = subprocess.Popen(['/bin/sleep', '30'])
        try:
            self.f.record(harness='codex', console_pid=console.pid, launch_stage='launching')
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            (self.f.root/'process-info').write_text(json.dumps({'result': {
                'type':'pane_process_info', 'process_info': {
                    'pane_id':'w7:p1', 'shell_pid':console.pid,
                    'foreground_processes':[{'name':'bash','pid':console.pid},
                        {'name':'codex','pid':os.getpid()}]}}}))
            result = self.f.run(FM_ENTRY_STARTUP_WAIT='0', FM_ENTRY_NO_ATTACH='')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.f.root/'attached').exists())
            self.assertEqual(self.f.effects(), '')
        finally:
            console.terminate(); console.wait(timeout=5)

    def test_stale_other_harness_creates_successor(self):
        result = self.f.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('w8 pane w8:p1 (created)', result.stderr)
        self.assertEqual(self.f.effects(), 'create\nrun\n')
    def test_live_other_harness_refuses(self):
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_failed_inventory_refuses(self):
        result = self.f.run(FAIL_LIST='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.f.effects(), '')
    def test_malformed_inventory_refuses(self):
        (self.f.root/'inventory').write_text('{"error":"unavailable"}')
        result = self.f.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.f.effects(), '')
    def test_missing_record_with_existing_label_refuses(self):
        (self.f.home/'state/captain-console.json').unlink()
        result = self.f.run(FIXTURE_WORKSPACES='[{"workspace_id":"w7","label":"firstmate"}]')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_contradictory_pane_identity_refuses(self):
        self.f.inventory([{'workspace_id':'wrong','pane_id':'w7:p1'}])
        result = self.f.run()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_failed_creation_propagates(self):
        result = self.f.run(FAIL_CREATE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('(created)', result.stderr)
    def test_failed_launch_propagates(self):
        result = self.f.run(FAIL_RUN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('(created)', result.stderr)
    def test_failed_convergence_refuses(self):
        self.f.record(harness='codex')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run(FAIL_CONVERGE='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_unknown_server_owner_refuses(self):
        result = self.f.run(FIXTURE_SERVER_PID='')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_attach_failure_status_propagates(self):
        result = self.f.run(FM_ENTRY_NO_ATTACH='', FAIL_ATTACH='79')
        self.assertEqual(result.returncode, 79, result.stderr)
    def test_live_different_model_refuses(self):
        self.f.record(harness='codex', profile='codex-sol', model='gpt-5.6-sol')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
    def test_unknown_live_model_refuses(self):
        self.f.record(harness='codex', model=None)
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        self.assertNotEqual(self.f.run().returncode, 0)
        self.assertEqual(self.f.effects(), '')
    def test_creation_forwards_explicit_profile(self):
        (self.f.home/'config/console-profile').write_text('codex-sol\n')
        result = self.f.run(FM_CONSOLE_PROFILE='codex-astra')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.f.root/'workspace-env').read_text())
        forwarded = dict(value.split('=', 1) for index, value in enumerate(args) if index and args[index-1] == '--env')
        self.assertEqual(forwarded['FM_CONSOLE_PROFILE'], 'codex-astra')
        child = self.f.run('--console', **dict(forwarded, HERDR_PANE_ID='w8:p1', HERDR_SOCKET_PATH='/synthetic.sock'))
        self.assertIn('firstmate native console refused', child.stderr)
        record = json.loads((self.f.home/'state/captain-console.json').read_text())
        self.assertIn('--model gpt-6-astra', record['argv'])
    def test_stale_record_with_orphan_refuses(self):
        result = self.f.run(FIXTURE_WORKSPACES='[{"workspace_id":"orphan","label":"firstmate"}]')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.f.effects(), '')
    def test_lost_creation_response_does_not_duplicate(self):
        first = self.f.run(LOST_CREATE='1')
        second = self.f.run()
        self.assertNotEqual(first.returncode, 0)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(self.f.effects(), 'create\n')
    def test_unconfirmed_restart_fails(self):
        shell = subprocess.Popen([BASH, '--noprofile', '--norc', '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            result = self.f.run(IDLE_SHELL_PID=str(shell.pid), UNCONFIRMED='1', FM_ENTRY_STARTUP_WAIT='1')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('startup unconfirmed', result.stderr)
            self.assertEqual(self.f.effects(), 'run\n')
        finally:
            shell.terminate(); shell.communicate(timeout=5)
    def test_deferred_failure_reaches_final_caller(self):
        for no_attach in ('1', ''):
            with self.subTest(no_attach=no_attach):
                (self.f.root/'started').unlink(missing_ok=True)
                self.f.record(harness='codex')
                self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
                result = self.f.run(START_SERVER='1', FAIL_CONVERGE='1', FM_ENTRY_ATTACH_WAIT='0', FM_ENTRY_NO_ATTACH=no_attach)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn('convergence timed out', result.stderr)
                self.assertEqual(self.f.effects(), '')

    def check_failed_held_console(self, args):
        import pty
        master, slave = pty.openpty()
        self.f.record(harness='codex')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        child = subprocess.Popen([BASH, shellpath(ENTRY), '--console', *args],
                                 env=dict(self.f.env, HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/synthetic.sock'),
                                 stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and b'Press Enter to close' not in output:
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 65536)
            self.assertIn(b'FirstMate launch failed', output)
            self.assertIn(b'Press Enter to close', output)
            self.assertIsNone(child.poll())
            record = json.loads((self.f.home/'state/captain-console.json').read_text())
            self.assertEqual(record['launch_stage'], 'exited')
            self.assertEqual(record['exit_rc'], 1)
            result = self.f.run(IDLE_SHELL_PID=str(child.pid))
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('convergence is incomplete (failed)', result.stderr)
            self.assertEqual(self.f.effects(), '')
            self.assertIsNone(child.poll())
            os.write(master, b'\n')
            self.assertEqual(child.wait(timeout=5), 1)
        finally:
            if child.poll() is None:
                child.terminate(); child.wait(timeout=5)
            os.close(master)

    def test_failed_held_console_is_not_reused(self):
        self.check_failed_held_console([])

    def test_early_argument_failure_is_recorded_before_hold(self):
        self.check_failed_held_console(['--resume'])

    def test_missing_pin_fails_first_creation(self):
        result = self.f.run(REAL_CONSOLE='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn('console startup failed', result.stderr)
        self.assertIn('firstmate native console refused', (self.f.root/'console-output').read_text())
        self.assertEqual(self.f.effects(), 'create\nrun\n')

    def test_missing_pin_fails_restart(self):
        shell = subprocess.Popen([BASH, '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            result = self.f.run(REAL_CONSOLE='1', IDLE_SHELL_PID=str(shell.pid))
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('console startup failed', result.stderr)
            self.assertIn('firstmate native console refused', (self.f.root/'console-output').read_text())
            self.assertEqual(self.f.effects(), 'run\n')
        finally:
            shell.terminate(); shell.communicate(timeout=5)

    def test_delayed_startup_is_qualified_before_creation_returns(self):
        started = time.monotonic()
        result = self.f.run(STARTUP_DELAY='25')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(time.monotonic()-started, 25)

    def test_starting_console_reuse_waits_for_launch(self):
        self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='starting')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        ready = threading.Timer(2, lambda: self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='launching'))
        ready.start()
        try:
            started = time.monotonic()
            result = self.f.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(time.monotonic()-started, 2)
            self.assertEqual(result.stderr.count('Waiting for the console to become ready'), 1)
            self.assertEqual(self.f.effects(), '')
        finally:
            ready.cancel(); ready.join()

    def test_starting_pid_alone_is_unconfirmed(self):
        self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='starting')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run(FM_ENTRY_STARTUP_WAIT='0')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn('startup unconfirmed', result.stderr)
        self.assertEqual(self.f.effects(), '')

    def test_delayed_restart_is_qualified(self):
        shell = subprocess.Popen([BASH, '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            started = time.monotonic()
            result = self.f.run(STARTUP_DELAY='2', IDLE_SHELL_PID=str(shell.pid))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(time.monotonic()-started, 2)
            self.assertEqual(self.f.effects(), 'run\n')
        finally:
            shell.terminate(); shell.communicate(timeout=5)

    def test_failed_restart_with_live_pid_is_not_confirmed(self):
        shell = subprocess.Popen([BASH, '--noprofile', '--norc', '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            result = self.f.run(IDLE_SHELL_PID=str(shell.pid), FAIL_RESTART='1')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('console startup failed', result.stderr)
            self.assertEqual(self.f.effects(), 'run\n')
        finally:
            shell.terminate(); shell.communicate(timeout=5)

    def test_deferred_attach_failure_preserves_status_without_timeout(self):
        self.f.record(harness='codex')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        started = time.monotonic()
        result = self.f.run(START_SERVER='1', FAIL_CONVERGE='1', FM_ENTRY_ATTACH_WAIT='20',
                            FM_ENTRY_NO_ATTACH='', FAIL_ATTACH='79')
        self.assertEqual(result.returncode, 79, result.stderr)
        self.assertLess(time.monotonic() - started, 8)
        self.assertNotIn('convergence timed out', result.stderr)
        self.assertEqual(self.f.effects(), '')

    def test_creation_preserves_recorded_child_status(self):
        result = self.f.run(FAIL_RESTART='1', FAIL_RESTART_STATUS='79')
        self.assertEqual(result.returncode, 79, result.stderr)
        self.assertEqual(self.f.effects(), 'create\nrun\n')

    def test_restart_preserves_recorded_child_status(self):
        shell = subprocess.Popen([BASH, '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            result = self.f.run(IDLE_SHELL_PID=str(shell.pid), FAIL_RESTART='1', FAIL_RESTART_STATUS='79')
            self.assertEqual(result.returncode, 79, result.stderr)
            self.assertEqual(self.f.effects(), 'run\n')
        finally:
            shell.terminate(); shell.communicate(timeout=5)

    def test_reuse_preserves_valid_status_and_rejects_invalid_status(self):
        for status, expected in [(1, 1), (79, 79), (255, 255), (256, 1), (-1, 1),
                                 (1.5, 1), ('79', 1), ('malformed', 1), (None, 1), ({}, 1), (0, 1)]:
            with self.subTest(status=status):
                self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='exited', exit_rc=status)
                self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
                result = self.f.run(FM_ENTRY_STARTUP_WAIT='0')
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(self.f.effects(), '')

    def test_held_creation_lock_respects_shortened_bounds(self):
        import fcntl
        with (self.f.home/'state/console-launch.lock').open('w') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX)
            started = time.monotonic()
            result = self.f.run(FM_ENTRY_STARTUP_WAIT='0', FM_ENTRY_RESTORE_SETTLE='0',
                                FM_ENTRY_COMPOSER_WAIT='0', FM_ENTRY_EXIT_WAIT='0')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertLess(time.monotonic()-started, 15)
            self.assertIn('another launcher owns console creation', result.stderr)
            self.assertEqual(self.f.effects(), '')

    def test_two_clicks_create_one_console(self):
        children = [subprocess.Popen([BASH, shellpath(ENTRY)], env=dict(self.f.env, STARTUP_DELAY='25'),
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        try:
            outputs = [child.communicate(timeout=40) for child in children]
            for child, (out, err) in zip(children, outputs):
                self.assertEqual(child.returncode, 0, out+err)
            self.assertEqual(sum('(created)' in err for _, err in outputs), 1)
            self.assertEqual(sum('(existing)' in err for _, err in outputs), 1)
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    child.communicate(timeout=5)
        self.assertEqual(self.f.effects(), 'create\nrun\n')
        record = json.loads((self.f.home/'state/captain-console.json').read_text())
        self.assertEqual(record['harness'], 'codex')


    # --- console ownership handover and in-session launch (2026-09-13) -----------
    WORKERS = [{'workspace_id':'w7','pane_id':'w7:p4'}, {'workspace_id':'w7','pane_id':'w7:p5'}, {'workspace_id':'w7','pane_id':'w7:p6'}]
    LABELLED = '[{"workspace_id":"w7","label":"firstmate"}]'
    def relinquished(self, **changes):
        # The shape a departing console leaves behind: its pane is gone, its pid
        # is dead, and the stage plus handoff_at say the handover was explicit.
        data = dict(harness='codex', console_pid=0, launch_stage='handoff-relinquished', handoff_at='2026-09-13T12:52:04Z',
                    workspace_id='wC', pane_id='wC:p1')
        data.update(changes)
        self.f.record(**data)
    def inside(self, **env):
        # Herdr's injected ancestry for a shell in worker pane w7:p6 of the session.
        base = dict(HERDR_ENV='1', HERDR_PANE_ID='w7:p6', HERDR_WORKSPACE_ID='w7', HERDR_TAB_ID='w7:t6',
                    HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/synthetic.sock')
        base.update(env)
        return base
    def history(self):
        d = self.f.home/'state/console-history'
        return sorted(d.iterdir()) if d.exists() else []
    def record_json(self):
        return json.loads((self.f.home/'state/captain-console.json').read_text())

    def test_relinquished_record_is_superseded_by_outside_launch(self):
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_text()
        self.f.inventory(self.WORKERS)
        result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('w8 pane w8:p1 (created)', result.stderr)
        self.assertEqual(self.f.effects(), 'create\nrun\n')
        archived = self.history()
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), before)
        record = self.record_json()
        self.assertEqual((record['workspace_id'], record['pane_id'], record['session']), ('w8', 'w8:p1', 'synthetic'))
        self.assertEqual(record['established_from'], 'handoff-relinquished')
        self.assertEqual(record['placement'], 'new-workspace')
        self.assertEqual(Path(record['superseded_record']), archived[0])

    def test_relinquished_record_with_live_console_refuses(self):
        self.relinquished(console_pid=os.getpid())
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory(self.WORKERS)
        for env in ({}, self.inside()):
            with self.subTest(env=env):
                result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn('still alive', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_relinquished_record_without_timestamp_refuses(self):
        self.relinquished(handoff_at=None)
        self.f.inventory(self.WORKERS)
        for env in ({}, self.inside()):
            with self.subTest(env=env):
                result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn('malformed relinquishment', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])

    def test_relinquished_record_without_console_pid_refuses(self):
        for shape in ('null', 'absent'):
            with self.subTest(shape=shape):
                self.relinquished(console_pid=None)
                record = self.f.home/'state/captain-console.json'
                if shape == 'absent':
                    data = json.loads(record.read_text()); del data['console_pid']; record.write_text(json.dumps(data))
                before = record.read_bytes()
                self.f.inventory(self.WORKERS)
                for env in ({}, self.inside()):
                    result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn('console pid <unrecorded> is still alive or unverifiable', result.stderr)
                self.assertEqual(record.read_bytes(), before)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])

    def test_unwritable_archive_directory_refuses_before_creating(self):
        self.relinquished()
        (self.f.home/'state/console-history').write_text('not a directory\n')
        self.f.inventory(self.WORKERS)
        for env in ({}, self.inside()):
            with self.subTest(env=env):
                result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.record_json()['pane_id'], 'wC:p1')

    def test_failed_archive_closes_only_the_console_it_created(self):
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_bytes()
        history = self.f.home/'state/console-history'
        history.mkdir(); history.chmod(0o555)
        try:
            for env, expected in (({}, 'create\nworkspace-close\n'), (self.inside(), 'tab-create\ntab-close\n')):
                with self.subTest(env=env):
                    (self.f.root/'effects').unlink(missing_ok=True)
                    (self.f.root/'workspaces').unlink(missing_ok=True)
                    self.f.inventory(self.WORKERS)
                    result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn('could not archive the superseded console record', result.stderr)
                    self.assertEqual(self.f.effects(), expected)
                    self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)
                    self.assertEqual(self.history(), [])
        finally:
            history.chmod(0o755)

    def test_stale_record_beside_labelled_workspace_still_refuses(self):
        # An ordinary stale record (pane gone, no relinquishment) never adopts a
        # "firstmate"-labelled workspace, from outside or from inside the session.
        self.f.record(harness='codex', console_pid=0, workspace_id='wC', pane_id='wC:p1')
        self.f.inventory(self.WORKERS)
        for env in ({}, self.inside()):
            with self.subTest(env=env):
                result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])

    def test_multiple_labelled_workspaces_without_record_refuse(self):
        (self.f.home/'state/captain-console.json').unlink()
        self.f.inventory(self.WORKERS + [{'workspace_id':'w9','pane_id':'w9:p1'}])
        two = '[{"workspace_id":"w7","label":"firstmate"},{"workspace_id":"w9","label":"firstmate"}]'
        for env in ({}, self.inside()):
            with self.subTest(env=env):
                result = self.f.run(FIXTURE_WORKSPACES=two, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertFalse((self.f.home/'state/captain-console.json').exists())

    def test_inside_launch_places_console_tab_in_exact_live_workspace(self):
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_text()
        self.f.inventory(self.WORKERS)
        result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, FM_ENTRY_NO_ATTACH='', **self.inside())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('w7 pane w7:p9 (created)', result.stderr)
        self.assertIn('no TUI attached from inside the session', result.stderr)
        self.assertFalse((self.f.root/'attached').exists())
        self.assertEqual(self.f.effects(), 'tab-create\nrun\n')
        args = json.loads((self.f.root/'tab-env').read_text())
        self.assertEqual(args[args.index('--workspace')+1], 'w7')
        forwarded = dict(value.split('=', 1) for index, value in enumerate(args) if index and args[index-1] == '--env')
        self.assertEqual(forwarded['HERDR_SESSION'], 'synthetic')
        self.assertEqual(forwarded['FM_CONSOLE_PROFILE'], 'codex-astra')
        record = self.record_json()
        self.assertEqual((record['session'], record['workspace_id'], record['pane_id'], record['tab_id']), ('synthetic', 'w7', 'w7:p9', 'w7:t9'))
        self.assertEqual(record['placement'], 'inherited-workspace')
        self.assertEqual(record['launched_from_pane'], 'w7:p6')
        self.assertEqual(record['established_from'], 'handoff-relinquished')
        self.assertEqual((self.f.root/'focus').read_text(), 'w7:t9')
        archived = self.history()
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), before)
        # The worker panes are exactly as they were: only the console tab was added.
        panes = json.loads((self.f.root/'inventory').read_text())['result']['panes']
        self.assertEqual(panes[:3], self.WORKERS)
        self.assertEqual(len(panes), 4)

    def test_inside_launch_uses_live_workspace_not_environment_snapshot(self):
        self.relinquished()
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p6'}])
        result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **self.inside(HERDR_WORKSPACE_ID='w3', HERDR_TAB_ID='w3:t1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.f.root/'tab-env').read_text())
        self.assertEqual(args[args.index('--workspace')+1], 'w7')
        self.assertEqual(self.record_json()['workspace_id'], 'w7')

    def test_inside_launch_with_contradictory_identity_refuses(self):
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory(self.WORKERS)
        cases = {
            'foreign socket': dict(HERDR_SOCKET_PATH='/other/herdr.sock'),
            'no socket': dict(HERDR_SOCKET_PATH=None),
            'unknown pane': dict(HERDR_PANE_ID='w7:p77'),
            'pane and tab disagree': dict(FIXTURE_TAB_WORKSPACE='w2'),
        }
        for name, extra in cases.items():
            with self.subTest(case=name):
                env = self.inside(**extra)
                env = {k: v for k, v in env.items() if v is not None}
                result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('(created)', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_inside_launch_reuses_live_console_without_attach(self):
        self.f.record(harness='codex', console_pid=os.getpid(), launch_stage='launching')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}] + self.WORKERS)
        result = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, FM_ENTRY_NO_ATTACH='', **self.inside())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('w7 pane w7:p1 (existing)', result.stderr)
        self.assertFalse((self.f.root/'attached').exists())
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])
        self.assertEqual(self.record_json()['pane_id'], 'w7:p1')

    def test_repeated_inside_launch_is_idempotent_after_convergence(self):
        self.relinquished()
        self.f.inventory(self.WORKERS)
        first = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **self.inside())
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn('(created)', first.stderr)
        settled = (self.f.home/'state/captain-console.json').read_bytes()
        for _ in range(2):
            again = self.f.run(FIXTURE_WORKSPACES=self.LABELLED, **self.inside())
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertIn('w7 pane w7:p9 (existing)', again.stderr)
        self.assertEqual(self.f.effects(), 'tab-create\nrun\n')
        self.assertEqual(len(self.history()), 1)
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), settled)

    def test_console_in_unrecorded_pane_never_establishes_identity(self):
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory(self.WORKERS)
        result = self.f.run('--console', HERDR_PANE_ID='w7:p6', HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/synthetic.sock')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('console ownership claim rejected for pane w7:p6', result.stderr)
        self.assertIn('relinquished ownership at 2026-09-13T12:52:04Z', result.stderr)
        self.assertIn('(without --console)', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_console_in_relinquished_pane_never_reclaims_the_record(self):
        # The relinquished pane may still exist as an ordinary pane; a hand-run
        # --console there must not reclaim the record outside the archive/supersede seam.
        self.relinquished()
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory(self.WORKERS + [{'workspace_id':'wC','pane_id':'wC:p1'}])
        result = self.f.run('--console', HERDR_PANE_ID='wC:p1', HERDR_WORKSPACE_ID='wC', HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/synthetic.sock')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('console ownership claim rejected for pane wC:p1', result.stderr)
        self.assertIn('relinquished ownership at 2026-09-13T12:52:04Z', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual(self.history(), [])
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_doctor_reports_placement_of_a_launch_from_its_pane(self):
        self.relinquished()
        self.f.inventory(self.WORKERS)
        inside = self.f.run('--doctor', **self.inside())
        self.assertIn('launch placement:  inherited-workspace', inside.stdout, inside.stderr)
        outside = self.f.run('--doctor')
        self.assertIn('launch placement:  new-workspace', outside.stdout, outside.stderr)
        foreign = self.f.run('--doctor', **self.inside(HERDR_SOCKET_PATH='/other/herdr.sock'))
        self.assertIn('launch placement:  refused (pane w7:p6 belongs to the Herdr server at', foreign.stdout, foreign.stderr)
        unproven = self.f.run('--doctor', **{k: v for k, v in self.inside().items() if k != 'HERDR_SOCKET_PATH'})
        self.assertIn('launch placement:  refused (pane w7:p6 claims session', unproven.stdout, unproven.stderr)
        self.assertEqual(self.f.effects(), '')

    def test_console_from_foreign_socket_refuses_before_claiming(self):
        self.f.record(harness='codex', socket='/synthetic.sock')
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run('--console', HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/other/herdr.sock')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('cross-session ancestry', result.stderr)
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_console_without_injected_socket_refuses_before_claiming(self):
        self.f.record(harness='codex', socket='/synthetic.sock')
        before = (self.f.home/'state/captain-console.json').read_bytes()
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run('--console', HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('without an injected HERDR_SOCKET_PATH', result.stderr)
        self.assertEqual(self.f.effects(), '')
        self.assertEqual((self.f.home/'state/captain-console.json').read_bytes(), before)

    def test_fable_console_launches_with_canonical_arguments(self):
        (self.f.home/'config/console-profile').write_text('fable-5.1\n')
        (self.f.home/'config/console-qualified-profiles').write_text('fable-5.1\n')
        settings = self.f.home/'config/claude-settings.json'
        settings.write_text('{"outputStyle": "attention-kind"}\n')
        style = self.f.home/'config/output-styles/attention-kind.md'
        style.parent.mkdir()
        style.write_text('---\nname: attention-kind\nkeep-coding-instructions: true\n---\n')
        self.f.script(self.f.tools/'bin/claude', 'printf "%s\\n" "$@" > "$FIXTURE_ROOT/claude-argv"\n')
        self.f.record(harness='claude', profile='fable-5.1', model='fable')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        result = self.f.run('--console', HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic', HERDR_SOCKET_PATH='/synthetic.sock',
                            FM_CONSOLE_PROFILE='fable-5.1', FM_ENTRY_ARM_TIMEOUT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ['--dangerously-skip-permissions', '--model', 'fable', '--settings', shellpath(settings)]
        self.assertEqual((self.f.root/'claude-argv').read_text().split('\n')[:-1], expected)
        self.assertEqual((self.f.user/'.claude/output-styles/attention-kind.md').read_bytes(), style.read_bytes())
        record = self.record_json()
        self.assertEqual(record['argv'], ' '.join(expected))
        self.assertEqual((record['profile'], record['model'], record['launch_mode'], record['launch_stage'], record['exit_rc']), ('fable-5.1', 'fable', 'fresh', 'exited', 0))

if __name__ == '__main__': unittest.main(verbosity=2)
