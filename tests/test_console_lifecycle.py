"""Drive the real Desktop caller through workspace ownership and convergence."""
import json
import os
import select
import time
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
        child = self.f.run('--console', **dict(forwarded, HERDR_PANE_ID='w8:p1'))
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
            result = self.f.run(IDLE_SHELL_PID=str(shell.pid), UNCONFIRMED='1')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('did not claim the console record', result.stderr)
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

    def test_failed_held_console_is_not_reused(self):
        import pty
        master, slave = pty.openpty()
        self.f.record(harness='codex')
        self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
        child = subprocess.Popen([BASH, shellpath(ENTRY), '--console'],
                                 env=dict(self.f.env, HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic'),
                                 stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and b'Press Enter to close' not in output:
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 65536)
            self.assertIn(b'firstmate native console refused', output)
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

    def test_failed_restart_with_live_pid_is_not_confirmed(self):
        shell = subprocess.Popen([BASH, '--noprofile', '--norc', '-c', 'read -r line'], stdin=subprocess.PIPE)
        try:
            self.f.record(harness='codex', console_pid=0)
            self.f.inventory([{'workspace_id':'w7','pane_id':'w7:p1'}])
            result = self.f.run(IDLE_SHELL_PID=str(shell.pid), FAIL_RESTART='1')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn('console restart failed', result.stderr)
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

    def test_two_clicks_create_one_console(self):
        children = [subprocess.Popen([BASH, shellpath(ENTRY)], env=self.f.env,
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        try:
            outputs = [child.communicate(timeout=15) for child in children]
            for child, (out, err) in zip(children, outputs):
                self.assertEqual(child.returncode, 0, out+err)
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    child.communicate(timeout=5)
        self.assertEqual(self.f.effects(), 'create\nrun\n')
        record = json.loads((self.f.home/'state/captain-console.json').read_text())
        self.assertEqual(record['harness'], 'codex')

if __name__ == '__main__': unittest.main(verbosity=2)
