"""Run profile selection through the executable console caller."""
import json
from pathlib import Path
import sys
import unittest
from launcher_fixture import LauncherFixture

ENTRY = Path(sys.argv.pop(1)).resolve()

@unittest.skipUnless(sys.platform.startswith('linux'), 'native console caller qualification is Linux; profile logic is covered portably')
class StartupBoundaryTests(unittest.TestCase):
    def setUp(self): self.f = LauncherFixture(ENTRY)
    def tearDown(self): self.f.close()
    def console(self, **env):
        self.f.record(harness='codex')
        return self.f.run('--console', HERDR_PANE_ID='w7:p1', HERDR_SESSION='synthetic', **env)
    def evidence_console(self, pane):
        harness = self.f.tools/'bin/synthetic-harness'
        self.f.script(harness, 'printf "harness\\n" >> "$FIXTURE_ROOT/startup-effects"\n')
        projection = self.f.root/'projection.py'
        projection.write_text('import os\nfrom pathlib import Path\nwith (Path(os.environ["FIXTURE_ROOT"])/"startup-effects").open("a") as output: output.write("preparation\\n")\n')
        return self.f.run('--console', HERDR_PANE_ID=pane, HERDR_SESSION='synthetic',
                          FM_HARNESS=str(harness), FM_EXCHANGE_OWNER=str(projection))

    def test_missing_record_refuses_before_preparation(self):
        record = self.f.home/'state/captain-console.json'
        record.unlink()
        result = self.evidence_console('w7:p1')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('console ownership claim rejected', result.stderr)
        self.assertFalse(record.exists())
        self.assertFalse((self.f.root/'startup-effects').exists())
        self.assertFalse((self.f.home/'state/cold-start-arm.log').exists())
        self.assertFalse((self.f.home/'no-mistakes').exists())

    def test_wrong_pane_refuses_without_changing_owned_record(self):
        record = self.f.home/'state/captain-console.json'
        before = record.read_bytes()
        result = self.evidence_console('w9:p1')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('console ownership claim rejected', result.stderr)
        self.assertEqual(record.read_bytes(), before)
        self.assertFalse((self.f.root/'startup-effects').exists())
        self.assertFalse((self.f.home/'state/cold-start-arm.log').exists())
        self.assertFalse((self.f.home/'no-mistakes').exists())

    def test_owned_console_reaches_preparation_and_harness(self):
        result = self.evidence_console('w7:p1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.f.root/'startup-effects').read_text(), 'preparation\nharness\n')
        record = json.loads((self.f.home/'state/captain-console.json').read_text())
        self.assertEqual(record['launch_stage'], 'exited')
        self.assertEqual(record['exit_rc'], 0)

    def test_inherited_harness_keeps_selected_model_through_guard(self):
        result = self.console(FM_HARNESS='codex')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('firstmate native console refused', result.stderr)
        record = json.loads((self.f.home/'state/captain-console.json').read_text())
        self.assertIn('--model gpt-6-astra', record['argv'])
        self.assertEqual(record['exit_rc'], result.returncode)
        self.assertNotIn('UNGUARDED_LAUNCH', result.stderr)
    def test_nonlogin_primary_resolves_native_client_before_gate(self):
        result = self.console()
        self.assertIn('firstmate native console refused', result.stderr)
        self.assertNotIn('harness codex is not installed', result.stderr)
    def test_conflicting_native_harness_refuses(self):
        result = self.console(FM_HARNESS='claude')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('conflicts with selected profile', result.stderr)
    def test_unqualified_inherited_harness_refuses(self):
        (self.f.home/'config/console-qualified-profiles').write_text('opus-4-8\n')
        result = self.console(FM_HARNESS='codex')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not yet qualified', result.stderr)
    def test_api_environment_refuses_at_actual_guard(self):
        result = self.console(FM_HARNESS='codex', OPENAI_API_KEY='SYNTHETIC_SECRET')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('conflicting API/provider environment: OPENAI_API_KEY', result.stderr)
        self.assertNotIn('SYNTHETIC_SECRET', result.stderr)

if __name__ == '__main__': unittest.main(verbosity=2)
