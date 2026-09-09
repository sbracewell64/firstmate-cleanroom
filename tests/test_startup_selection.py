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
