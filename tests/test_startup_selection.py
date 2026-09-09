import os, pathlib, subprocess, sys, tempfile, unittest
SOURCE=pathlib.Path(sys.argv.pop(1)).resolve()
BASH=os.environ.get('FM_TEST_BASH','bash')
def shellpath(p):
    s=p.as_posix()
    return '/'+s[0].lower()+s[2:] if len(s)>1 and s[1]==':' else s
class StartupBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name)
        for x in ['home/config','code/bin','tools/bin','user/.local/bin','windows-bin']:(self.p/x).mkdir(parents=True,exist_ok=True)
        values={'code-root':shellpath(self.p/'code'),'tools-root':shellpath(self.p/'tools'),'backend':'herdr','herdr-session':'firstmate-cleanroom','console-profile':'codex-astra','console-qualified-profiles':'codex-astra'}
        for k,v in values.items():(self.p/'home/config'/k).write_text(v+'\n')
        client=self.p/'user/.local/bin/codex';client.write_text('#!/bin/sh\nexit 90\n');client.chmod(0o755)
        prefix=SOURCE.read_text().split('# --- Console record and launch log',1)[0]
        self.probe=self.p/'selection.sh';self.probe.write_text(prefix+'\nprintf "HARNESS=%s\\nMODEL=%s\\nPATH0=%s\\nCLIENT=%s\\n" "$FM_HARNESS" "$FM_CONSOLE_MODEL" "${PATH%%:*}" "$(command -v codex || true)"\n')
    def tearDown(self):self.tmp.cleanup()
    def run_case(self,harness=None,path=None):
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
        env.update(FM_HOME=shellpath(self.p/'home'),HOME=shellpath(self.p/'user'),PATH=path or '/usr/bin:/bin')
        if harness is not None:env['FM_HARNESS']=harness
        return subprocess.run([BASH,'--noprofile','--norc',shellpath(self.probe)],env=env,text=True,capture_output=True,timeout=10)
    def test_inner_primary_keeps_selected_model(self):
        p=self.run_case('codex');self.assertEqual(p.returncode,0,p.stderr);self.assertIn('MODEL=gpt-6-astra',p.stdout)
    def test_nonlogin_primary_resolves_native_client_before_gate(self):
        p=self.run_case();self.assertEqual(p.returncode,0,p.stderr);self.assertIn('MODEL=gpt-6-astra',p.stdout);self.assertIn('PATH0='+shellpath(self.p/'tools/bin'),p.stdout)
    def test_evidence_harness_override_remains_explicit(self):
        p=self.run_case('bash');self.assertEqual(p.returncode,0,p.stderr);self.assertIn('HARNESS=bash\nMODEL=\n',p.stdout)
    def test_conflicting_native_harness_refuses(self):
        p=self.run_case('claude');self.assertNotEqual(p.returncode,0);self.assertIn('conflicts with selected profile',p.stderr)
    def test_existing_late_native_path_is_promoted(self):
        other=self.p/'windows-bin/codex';other.write_text('#!/bin/sh\nexit 91\n');other.chmod(0o755)
        path=shellpath(self.p/'windows-bin')+':/usr/bin:/bin:'+shellpath(self.p/'user/.local/bin')
        p=self.run_case('codex',path);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('CLIENT='+shellpath(self.p/'user/.local/bin/codex'),p.stdout)
    def test_unqualified_inherited_native_harness_still_refuses(self):
        (self.p/'home/config/console-qualified-profiles').write_text('opus-4-8\n')
        p=self.run_case('codex');self.assertNotEqual(p.returncode,0);self.assertIn('not yet qualified',p.stderr)
if __name__=='__main__':unittest.main(verbosity=2)
