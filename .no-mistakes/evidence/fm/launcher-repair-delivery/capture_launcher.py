"""Sanitized synthetic CLI evidence; run from the repository root."""
import os, sys, json, subprocess, time, pty, select
from pathlib import Path
sys.path.insert(0, str(Path.cwd()/'tests'))
from launcher_fixture import LauncherFixture
repo=Path.cwd()
lines=['Synthetic launcher caller evidence (Linux; no inference or live deployment).']
def record(label,result,f):
    lines.append('\n$ '+label)
    output=result.stdout+result.stderr
    output=output.replace(str(f.root),'<fixture>').replace(str(repo),'<release>')
    lines.append(output.strip())
    lines.append('exit status: '+str(result.returncode))
f=LauncherFixture(repo/'bin/enter-firstmate.sh')
try:
    env=dict(f.env,STARTUP_DELAY='25')
    children=[subprocess.Popen(['bash',str(f.entry)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
    for i,c in enumerate(children):
        out,err=c.communicate(timeout=45)
        record('Desktop launcher click '+str(i+1),subprocess.CompletedProcess([],c.returncode,out,err),f)
        assert c.returncode==0
    effects=f.effects();assert effects=='create\nrun\n'
    lines.append('Herdr mutation journal:\n'+effects.strip())
    data=json.loads((f.home/'state/captain-console.json').read_text())
    lines.append('Recorded selection: '+json.dumps({k:data[k] for k in ['harness','profile','model']}))
finally:f.close()
f=LauncherFixture(repo/'bin/enter-firstmate.sh')
try:
    result=f.run(FAIL_RESTART='1',FAIL_RESTART_STATUS='79')
    record('Desktop launcher with child failure 79',result,f);assert result.returncode==79
    (f.home/'state/captain-console.json').unlink()
    result=f.run('--console',HERDR_PANE_ID='w7:p1',HERDR_SESSION='synthetic')
    record('console caller with missing ownership',result,f);assert result.returncode==1
finally:f.close()
f=LauncherFixture(repo/'bin/enter-firstmate.sh')
try:
    # Render a consumer into an isolated synthetic home; execute it without activation.
    (f.home/'config/code-root').write_text('/synthetic-donor\n')
    (f.home/'config/tools-root').unlink()
    env=dict(f.env,PATH='/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1')
    render=subprocess.Popen(['bash',str(repo/'bin/fm-render-launcher.sh'),'--fm-home',str(f.home),'--code-root',str(repo),'--console-profile','codex-astra'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    consumer=f.home/'state/launcher-staging/enter-firstmate.sh'
    deadline=time.monotonic()+10
    while not consumer.exists() and time.monotonic()<deadline:time.sleep(.05)
    assert consumer.exists()
    master,slave=pty.openpty()
    child=subprocess.Popen(['bash',str(consumer)],env=env,stdin=slave,stdout=slave,stderr=slave)
    os.close(slave);output=b''
    try:
        deadline=time.monotonic()+8
        while b'Press Enter to close' not in output and time.monotonic()<deadline:
            if select.select([master],[],[],.1)[0]:output+=os.read(master,65536)
        assert b'Press Enter to close' in output and child.poll() is None
        lines.append('\n$ generated-consumer (PTY)')
        lines.append(output.decode().replace(str(f.root),'<fixture>').replace(str(repo),'<release>').strip())
        lines.append('Process remains alive with diagnostics visible before acknowledgement.')
        os.write(master,b'\n');assert child.wait(timeout=5)==1
        lines.append('After Enter: exit status 1')
    finally:
        if child.poll() is None:child.terminate();child.wait(timeout=5)
        os.close(master)
    result=subprocess.run(['bash',str(consumer)],env=env,text=True,capture_output=True,timeout=5)
    record('generated-consumer (noninteractive)',result,f);assert result.returncode==1 and 'Press Enter' not in result.stderr
    out,err=render.communicate(timeout=240)
    assert render.returncode==0, (out+err).replace(str(f.root),'<fixture>').replace(str(repo),'<release>')
    lines.append('Renderer completed staged qualification; no activation performed.')
finally:f.close()
Path(__file__).with_name('launcher-transcript.txt').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
