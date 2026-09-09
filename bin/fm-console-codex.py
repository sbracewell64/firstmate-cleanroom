#!/usr/bin/env python3
"""Qualify and launch the primary native Codex subscription route.
This owner is primary-only: workers and no-mistakes retain their own configuration.
Client pin: FM_HOME/config/console-codex-client.json. No paid fallback is provided.
"""
import hashlib, json, os, selectors, subprocess, sys, time
from pathlib import Path
MODELS={'gpt-6-astra','gpt-5.6-sol'}
POSTURE='--dangerously-bypass-approvals-and-sandbox'
class Refused(Exception): pass

def launch_args(argv):
    if len(argv)!=3 or argv[0]!=POSTURE or argv[1]!='--model' or argv[2] not in MODELS:
        raise Refused('primary Codex arguments must match the selected profile exactly')
    return ['-c','forced_login_method="chatgpt"','-c','model_provider="openai"',*argv]

def subscription_environment(environ):
    env=dict(environ)
    bad=[k for k,v in env.items() if v and (k.startswith(('OPENAI_','AZURE_OPENAI_','CODEX_API_')) or k in
        {'CODEX_RESPONSES_API_PROXY_URL','CODEX_MODEL_PROVIDER','CHATGPT_BASE_URL'})]
    if bad:raise Refused('conflicting API/provider environment: '+', '.join(sorted(bad)))
    expected=Path.home()/'.codex'
    if env.get('CODEX_HOME') and Path(env['CODEX_HOME']).resolve()!=expected.resolve():
        raise Refused('nonstandard CODEX_HOME needs separate native qualification')
    env['CODEX_HOME']=str(expected)
    return env

def check_config(config,model):
    if config.get('forced_login_method')!='chatgpt' or config.get('model_provider')!='openai' or config.get('model')!=model:
        raise Refused('effective model/auth/provider does not match the selected subscription profile')
    if (config.get('model_providers') or {}).get('openai'):
        raise Refused('built-in OpenAI provider has an override')
    for key,allowed in [('openai_base_url',{None,'','https://api.openai.com/v1'}),
                        ('chatgpt_base_url',{None,'','https://chatgpt.com/backend-api','https://chatgpt.com/backend-api/'})]:
        if config.get(key) not in allowed:raise Refused('custom endpoint at '+key)

def checked_pin(home):
    f=home/'config/console-codex-client.json'
    if f.is_symlink():raise Refused('client pin must be a regular managed file')
    pin=json.loads(f.read_text())
    p=Path(pin['path'])
    if not p.is_absolute() or p.is_symlink() or not p.is_file():raise Refused('native client pin is not a regular absolute file')
    required={'bin/codex','bin/codex-code-mode-host','codex-package.json',
              'codex-path/rg','codex-resources/bwrap','codex-resources/zsh/bin/zsh'}
    files=pin.get('files')
    if not isinstance(files,dict) or set(files)!=required:
        raise Refused('complete managed runtime package inventory is required')
    root=p.parent.parent
    if p!=root/'bin/codex':raise Refused('client must use the managed package layout')
    for name in sorted(required):
        member=root/name
        if member.is_symlink() or not member.is_file() or member.resolve()!=member:
            raise Refused('runtime package member is not a regular managed file')
        data=member.read_bytes();expected=files[name]
        if len(data)!=expected['bytes'] or hashlib.sha256(data).hexdigest()!=expected['sha256']:
            raise Refused('runtime package bytes do not match the managed pin')
        if name!='codex-package.json' and (data[:4]!=b'\x7fELF' or not os.access(member,os.X_OK)):
            raise Refused('runtime package executable is unavailable')
    if files['bin/codex']['sha256']!=pin['sha256']:
        raise Refused('client and package pins disagree')
    return p,pin

class Rpc:
    def __init__(self,client,env,model):
        self.p=subprocess.Popen([str(client),'-c','forced_login_method="chatgpt"','-c','model_provider="openai"','-c','model='+json.dumps(model),'app-server','--listen','stdio://'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        self.s=selectors.DefaultSelector();self.s.register(self.p.stdout,selectors.EVENT_READ);self.buf=b'';self.i=0
    def call(self,method,params):
        self.i+=1;i=self.i
        self.p.stdin.write((json.dumps({'id':i,'method':method,'params':params})+'\n').encode());self.p.stdin.flush()
        until=time.monotonic()+25
        while time.monotonic()<until:
            while b'\n' in self.buf:
                line,self.buf=self.buf.split(b'\n',1)
                try:r=json.loads(line)
                except ValueError:continue
                if r.get('id')==i:
                    if 'error' in r:raise Refused('native metadata read failed: '+method)
                    return r.get('result',{})
            if not self.s.select(timeout=.25):continue
            b=os.read(self.p.stdout.fileno(),65536)
            if not b:raise Refused('native metadata process exited')
            self.buf+=b
            if len(self.buf)>4*1024*1024:raise Refused('native metadata output exceeded bound')
        raise Refused('native metadata read timed out: '+method)
    def close(self):
        self.s.close();self.p.terminate()
        try:self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:self.p.kill();self.p.wait()

def preflight(client,env,model):
    rpc=Rpc(client,env,model)
    try:
        rpc.call('initialize',{'clientInfo':{'name':'firstmate-console-subscription','version':'1'},'capabilities':{'experimentalApi':True}})
        rpc.p.stdin.write(b'{"method":"initialized","params":{}}\n');rpc.p.stdin.flush()
        account=rpc.call('account/read',{'refreshToken':False})
        if (account.get('account') or {}).get('type')!='chatgpt':raise Refused('native ChatGPT login not established')
        resolved=rpc.call('config/read',{'includeLayers':False,'cwd':os.getcwd()})
        check_config(resolved.get('config') or {},model)
        catalog=rpc.call('model/list',{'limit':100,'includeHidden':False})
        if catalog.get('nextCursor') or model not in {m.get('id') for m in catalog.get('data',[])}:
            raise Refused('selected model availability not established')
        return {'account_type':'chatgpt','model':model,'model_provider':'openai','scope':'prelaunch metadata; actual consumer proof is separate'}
    finally:rpc.close()

def main(argv):
    check_only=bool(argv and argv[0]=='--check')
    if check_only:argv=argv[1:]
    args=launch_args(argv);model=argv[2]
    env=subscription_environment(os.environ)
    if 'FM_HOME' not in env:raise Refused('FM_HOME must be explicit')
    client,pin=checked_pin(Path(env['FM_HOME']))
    evidence=preflight(client,env,model)
    if check_only:
        print(json.dumps({**evidence,'client_sha256':pin['sha256'],'argv':args,'agent_started':False}));return
    os.execve(client,[str(client),*args],env)
if __name__=='__main__':
    try:main(sys.argv[1:])
    except (Refused,OSError,ValueError,KeyError,TypeError) as e:
        # Values from credentials/config are never echoed in errors.
        msg=str(e) if isinstance(e,Refused) else type(e).__name__
        print('firstmate native console refused: '+msg,file=sys.stderr);sys.exit(1)
