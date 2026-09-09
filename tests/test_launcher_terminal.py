"""Exercise terminal lifetime and status through the real launcher executable."""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest

BASH = os.environ.get('FM_TEST_BASH', 'bash')
ENTRY = Path(sys.argv.pop(1)).resolve()
EXPECTED = sys.argv.pop(1) if len(sys.argv) > 1 else 'code root is unset'

@unittest.skipUnless(os.name == 'posix', 'PTY caller requires a POSIX terminal')
class TerminalTests(unittest.TestCase):
    def test_failure_remains_visible_until_acknowledged(self):
        import pty
        with tempfile.TemporaryDirectory() as directory:
            env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            env['FM_HOME'] = directory
            master, slave = pty.openpty()
            child = subprocess.Popen([BASH, str(ENTRY)], env=env, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = b''
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if select.select([master], [], [], .1)[0]:
                        try:
                            output += os.read(master, 65536)
                        except OSError:
                            break
                    if b'Press Enter to close' in output:
                        break
                self.assertIn(EXPECTED.encode(), output)
                self.assertIsNone(child.poll(), output.decode())
                self.assertIn(b'Press Enter to close', output)
                os.write(master, b'\n')
                self.assertEqual(child.wait(timeout=5), 1)
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
                os.close(master)

    def test_noninteractive_failure_does_not_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            env['FM_HOME'] = directory
            result = subprocess.run([BASH, str(ENTRY)], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn(EXPECTED, result.stderr)
            self.assertNotIn('Press Enter', result.stderr)

if __name__ == '__main__':
    unittest.main(verbosity=2)
