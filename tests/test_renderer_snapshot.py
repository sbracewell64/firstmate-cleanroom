"""Exercise independent staging snapshots through the renderer executable."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from launcher_fixture import shellpath

RENDER = Path(sys.argv.pop(1)).resolve()
BASH = os.environ.get('FM_TEST_BASH', 'bash')

class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root/'home'
        (self.home/'config').mkdir(parents=True)
        (self.home/'config/code-root').write_text('/synthetic-donor\n')
        self.stage = self.home/'state/stage'

    def tearDown(self):
        self.tmp.cleanup()

    def render(self):
        return subprocess.run([BASH, shellpath(RENDER), '--fm-home', shellpath(self.home),
                               '--code-root', shellpath(RENDER.parent.parent), '--staging', shellpath(self.stage),
                               '--require-complete-config'], text=True, capture_output=True, timeout=10)

    def staged(self):
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('incomplete staged configuration: tools-root is required', result.stderr)

    @unittest.skipUnless(os.name == 'posix', 'requires symlink support')
    def test_live_symlink_is_materialized_without_changing_target(self):
        target = self.root/'live-root'
        target.write_text('/synthetic-donor\n')
        (self.home/'config/code-root').unlink()
        (self.home/'config/code-root').symlink_to(target)
        self.staged()
        self.assertEqual(target.read_text(), '/synthetic-donor\n')
        self.assertTrue((self.home/'config/code-root').is_symlink())
        self.assertFalse((self.stage/'config/code-root').is_symlink())
        self.assertEqual((self.stage/'config/code-root').read_text().strip(), shellpath(RENDER.parent.parent))

    def test_rerender_removes_revoked_grants_and_stale_nested_files(self):
        grant = self.home/'config/console-qualified-profiles'
        grant.write_text('codex-astra\n')
        nested = self.home/'config/nested'
        nested.mkdir()
        (nested/'setting').write_text('retired\n')
        self.staged()
        self.assertEqual((self.stage/'config/console-qualified-profiles').read_text(), 'codex-astra\n')
        first = list((self.stage/'rollback').iterdir())[0]
        grant.unlink()
        (nested/'setting').unlink()
        self.staged()
        self.assertFalse((self.stage/'config/console-qualified-profiles').exists())
        self.assertFalse((self.stage/'config/nested/setting').exists())
        self.assertEqual((first/'config/console-qualified-profiles').read_text(), 'codex-astra\n')
        self.assertEqual(len(list((self.stage/'rollback').iterdir())), 2)

    @unittest.skipUnless(os.name == 'posix', 'requires symlink support')
    def test_preexisting_staged_symlink_is_refused(self):
        (self.stage/'config').mkdir(parents=True)
        target = self.root/'unrelated'
        target.write_text('unchanged\n')
        (self.stage/'config/code-root').symlink_to(target)
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('linked staging destination refused', result.stderr)
        self.assertEqual(target.read_text(), 'unchanged\n')

    @unittest.skipUnless(os.name == 'posix', 'requires symlink support')
    def test_linked_staging_directory_is_refused(self):
        self.stage.parent.mkdir(parents=True)
        target = self.root/'unrelated-directory'
        target.mkdir()
        self.stage.symlink_to(target, target_is_directory=True)
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('linked staging destination refused', result.stderr)
        self.assertEqual(list(target.iterdir()), [])

if __name__ == '__main__':
    unittest.main(verbosity=2)
