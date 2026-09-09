import importlib.util, os, pathlib, subprocess, sys, tempfile, unittest
GUARD=pathlib.Path(sys.argv.pop(1)).resolve()
ENTRY=pathlib.Path(sys.argv.pop(1)).resolve()
spec=importlib.util.spec_from_file_location('guard',GUARD);guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
BASH=os.environ.get('FM_TEST_BASH','bash')
def sp(p):
    s=p.as_posix();return '/'+s[0].lower()+s[2:] if len(s)>1 and s[1]==':' else s
class GuardTests(unittest.TestCase):
    def test_package_pin_checks_every_member(self):
        import json, hashlib
        with tempfile.TemporaryDirectory() as d:
            home=pathlib.Path(d);(home/'config').mkdir()
            root=home/'package';files={}
            for name in ['bin/codex','bin/codex-code-mode-host','codex-package.json','codex-path/rg','codex-resources/bwrap','codex-resources/zsh/bin/zsh']:
                member=root/name;member.parent.mkdir(parents=True,exist_ok=True)
                data=b'{}' if name=='codex-package.json' else b'\x7fELFcontrolled-test-bytes'
                member.write_bytes(data);member.chmod(0o755)
                files[name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            pin={'path':str(root/'bin/codex'),'sha256':files['bin/codex']['sha256'],'files':files}
            (home/'config/console-codex-client.json').write_text(json.dumps(pin))
            self.assertEqual(guard.checked_pin(home)[0],root/'bin/codex')
            (root/'bin/codex-code-mode-host').write_bytes(b'\x7fELFchanged-helper')
            with self.assertRaises(guard.Refused):guard.checked_pin(home)
    def test_missing_package_helpers_refuse(self):
        import json, shutil, hashlib
        with tempfile.TemporaryDirectory() as d:
            home=pathlib.Path(d);(home/'config').mkdir()
            client=home/'codex';shutil.copyfile('/bin/true',client);client.chmod(0o755)
            (home/'config/console-codex-client.json').write_text(json.dumps({'path':str(client),'sha256':hashlib.sha256(client.read_bytes()).hexdigest()}))
            with self.assertRaises(guard.Refused):guard.checked_pin(home)
    def test_api_mode_override_refuses(self):
        with self.assertRaises(guard.Refused):guard.launch_args([guard.POSTURE,'--model','gpt-6-astra','-c','forced_login_method="api"'])
    def test_exact_native_args(self):
        self.assertEqual(guard.launch_args([guard.POSTURE,'--model','gpt-6-astra']),['-c','forced_login_method="chatgpt"','-c','model_provider="openai"',guard.POSTURE,'--model','gpt-6-astra'])
    def test_secret_environment_refuses_without_value(self):
        env={'OPENAI_API_KEY':'PRIVATE_SENTINEL'}
        with self.assertRaises(guard.Refused) as e:guard.subscription_environment(env)
        self.assertNotIn('PRIVATE_SENTINEL',str(e.exception));self.assertEqual(env['OPENAI_API_KEY'],'PRIVATE_SENTINEL')
    def test_effective_custom_provider_refuses(self):
        config={'model':'gpt-6-astra','forced_login_method':'chatgpt','model_provider':'openai','model_providers':{'openai':{'base_url':'https://private.invalid'}}}
        with self.assertRaises(guard.Refused):guard.check_config(config,'gpt-6-astra')
    def test_effective_root_endpoint_refuses(self):
        config={'model':'gpt-6-astra','forced_login_method':'chatgpt','model_provider':'openai','chatgpt_base_url':'https://private.invalid'}
        with self.assertRaises(guard.Refused):guard.check_config(config,'gpt-6-astra')
    def test_native_route_accepts_default_config(self):
        guard.check_config({'model':'gpt-6-astra','forced_login_method':'chatgpt','model_provider':'openai','model_providers':None},'gpt-6-astra')
    def test_missing_auth_is_unknown(self):
        with self.assertRaises(guard.Refused):guard.check_config({'model':'gpt-6-astra','model_provider':'openai'},'gpt-6-astra')
    def test_actual_console_propagates_guard_refusal(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'bin').mkdir()
            for name,body in [('codex','echo UNGUARDED_NATIVE_LAUNCH\nexit 0\n'),('python3','echo SUBSCRIPTION_GUARD_REFUSED\nexit 86\n')]:
                f=p/'bin'/name;f.write_text('#!/bin/sh\n'+body);f.chmod(0o755)
            text=ENTRY.read_text();function=text[text.index('console_run() {'):text.index('if [ "$MODE" = arm-owner ]; then')]
            runner=p/'call.sh'
            runner.write_text('FM_ENTRY_LIB=1 . "$1"\n'+function+'\nCONSOLE_RESUME_WINDOW=20\njq() { echo "{}"; }\nconsole_log() { :; }\nconsole_record_update() { :; }\nFM_HARNESS=codex\nFM_CONSOLE_MODEL=gpt-6-astra\nFM_CODE_ROOT=/controlled-code\nconsole_run\n')
            env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))};env['PATH']=sp(p/'bin')+':/usr/bin:/bin'
            r=subprocess.run([BASH,'--noprofile','--norc',sp(runner),sp(ENTRY)],env=env,text=True,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,86,r.stdout+r.stderr);self.assertIn('SUBSCRIPTION_GUARD_REFUSED',r.stdout);self.assertNotIn('UNGUARDED_NATIVE_LAUNCH',r.stdout)
if __name__=='__main__':unittest.main(verbosity=2)
