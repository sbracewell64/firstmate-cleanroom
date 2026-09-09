"""Drive the real Desktop caller through workspace ownership and convergence."""
import json
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
