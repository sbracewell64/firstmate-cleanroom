"""Executable launcher fixture: only vendor tools and process observations are fake."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

BASH = os.environ.get('FM_TEST_BASH', 'bash')

def shellpath(path):
    value = Path(path).as_posix()
    return '/' + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ':' else value

class LauncherFixture:
    def __init__(self, entry):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.entry = Path(entry).resolve()
        self.home = self.root/'home'
        self.tools = self.root/'tools'
        self.code = self.root/'code'
        self.user = self.root/'user'
        for path in [self.home/'config', self.home/'state', self.tools/'bin', self.code/'bin', self.user/'.local/bin']:
            path.mkdir(parents=True)
        for name, value in {'code-root': self.code, 'tools-root': self.tools, 'backend': 'herdr',
                            'herdr-session': 'synthetic', 'console-profile': 'codex-astra',
                            'console-qualified-profiles': 'codex-astra'}.items():
            (self.home/'config'/name).write_text(shellpath(value)+'\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'OPENAI_', 'CODEX_', 'AZURE_OPENAI_'))}
        self.env.update(FM_HOME=shellpath(self.home), HOME=shellpath(self.user),
                        PATH='/usr/bin:/bin', FM_ENTRY_NO_ATTACH='1', FIXTURE_ROOT=str(self.root))
        self.script(self.tools/'bin/no-mistakes', 'echo "daemon running"\n')
        self.script(self.tools/'tool-policy.sh', "echo '{\"tools\":[{\"tool\":\"no-mistakes\",\"state\":\"QUALIFIED\"}]}'\n")
        self.script(self.code/'bin/fm-tool-profile.sh', 'exit 0\n')
        self.script(self.user/'.local/bin/codex', 'echo UNGUARDED_LAUNCH >&2; exit 91\n')
        for owner in self.entry.parent.glob('*.sh'):
            if owner.name != 'fm-tool-profile.sh':
                shutil.copy2(owner, self.code/'bin'/owner.name)
        shutil.copytree(self.entry.parent/'backends', self.code/'bin/backends')
        shutil.copy2(self.entry.parent/'fm-console-codex.py', self.code/'bin/fm-console-codex.py')
        self.script(self.tools/'bin/pgrep', 'test -n "${FIXTURE_SERVER_PID:-}" && echo "$FIXTURE_SERVER_PID"\n')
        herdr = self.tools/'bin/herdr'
        herdr.write_text('#!'+sys.executable+'\n'+r'''
import json, os, pathlib, sys, time
p=pathlib.Path(os.environ['FIXTURE_ROOT']); args=sys.argv[1:]
if len(args)<2 or args[-2:]!=['--session','synthetic']:
    print('unscoped fixture Herdr call',file=sys.stderr);sys.exit(92)
args=args[:-2]
if not args:sys.exit(int(os.environ.get('FAIL_ATTACH','0')))
if args[:2]==['session','list']: out={'sessions':[{'name':'synthetic','socket_path':'/synthetic.sock'}]}
elif args[:1]==['server']: sys.exit(0)
elif args[:1]==['status']:
    stopped=os.environ.get('START_SERVER') and not (p/'started').exists()
    (p/'started').touch()
    out={'server':{'running':not stopped}}
elif args[:2]==['pane','list']:
    if os.environ.get('FAIL_LIST'):sys.exit(73)
    out=json.loads((p/'inventory').read_text())
elif args[:2]==['workspace','create']:
    with (p/'effects').open('a') as f:f.write('create\n')
    if os.environ.get('FAIL_CREATE'):sys.exit(74)
    (p/'workspace-env').write_text(json.dumps(args))
    (p/'workspaces').write_text('[{"workspace_id":"w8","label":"firstmate"}]')
    if os.environ.get('LOST_CREATE'): print('{}');sys.exit(0)
    time.sleep(.1)
    out={'result':{'workspace':{'workspace_id':'w8'},'root_pane':{'pane_id':'w8:p1'}}}
    (p/'inventory').write_text(json.dumps({'result':{'panes':[{'workspace_id':'w8','pane_id':'w8:p1'}]}}))
elif args[:2]==['pane','run']:
    with (p/'effects').open('a') as f:f.write('run\n')
    (p/'pane-command').write_text(args[-1])
    if os.environ.get('FAIL_RUN'):sys.exit(76)
    if os.environ.get('UNCONFIRMED'):print('{}');sys.exit(0)
    record=p/'home/state/captain-console.json';data=json.loads(record.read_text());data['console_pid']=int(os.environ['FIXTURE_CONSOLE_PID']);record.write_text(json.dumps(data));out={}
elif args[:2]==['pane','process-info']:
    if os.environ.get('FAIL_CONVERGE'):sys.exit(75)
    out={'result':{'type':'pane_process_info','process_info':{'pane_id':args[-1], 'shell_pid':1,'foreground_processes':[{'name':'codex','pid':int(os.environ['FIXTURE_CONSOLE_PID'])}]}}}
    if os.environ.get('IDLE_SHELL_PID'):
        pid=int(os.environ['IDLE_SHELL_PID']);out['result']['process_info'].update(shell_pid=pid,foreground_process_group_id=pid,foreground_processes=[{'name':'bash','argv0':'bash','pid':pid}])
elif args[:2]==['workspace','list']:out={'result':{'workspaces':json.loads((p/'workspaces').read_text() if (p/'workspaces').exists() else os.environ.get('FIXTURE_WORKSPACES','[]'))}}
else:print('unexpected fixture command '+repr(args),file=sys.stderr);sys.exit(93)
print(json.dumps(out))
''')
        herdr.chmod(0o755)
        self.env['FIXTURE_CONSOLE_PID'] = str(os.getpid())
        self.server = None
        if sys.platform.startswith('linux'):
            env = dict(self.env, HERDR_SESSION='synthetic', NM_HOME=shellpath(self.home/'no-mistakes'),
                       PATH=shellpath(self.tools/'bin')+':'+shellpath(self.user/'.local/bin')+':/usr/bin:/bin')
            self.server = subprocess.Popen(['/bin/sleep', '120'], env=env)
            self.env['FIXTURE_SERVER_PID'] = str(self.server.pid)
        self.inventory([])
        self.record()

    def script(self, path, body):
        path.write_text('#!/usr/bin/env bash\n'+body)
        path.chmod(0o755)

    def record(self, **changes):
        data = dict(workspace_id='w7', pane_id='w7:p1', session='synthetic', harness='claude', profile='codex-astra', model='gpt-6-astra')
        data.update(changes)
        (self.home/'state/captain-console.json').write_text(json.dumps(data))

    def inventory(self, panes):
        (self.root/'inventory').write_text(json.dumps({'result': {'panes': panes}}))

    def run(self, *args, **env):
        return subprocess.run([BASH, '--noprofile', '--norc', shellpath(self.entry), *args],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=35)

    def effects(self):
        p = self.root/'effects'
        return p.read_text() if p.exists() else ''

    def close(self):
        if self.server:
            self.server.terminate(); self.server.wait(timeout=5)
        self.tmp.cleanup()
