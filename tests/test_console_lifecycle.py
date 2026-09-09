"""Exercise the console record/workspace caller with controlled Herdr replies."""
import json, os, pathlib, subprocess, sys, tempfile, unittest
ENTRY=pathlib.Path(sys.argv.pop(1)).resolve()
class LifecycleTests(unittest.TestCase):
    def run_case(self, reply, record=None, fail_list=False, fail_create=False, concurrent=False, fail_converge=False):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'state').mkdir()
            (p/'reply').write_text(json.dumps(reply))
            if record is None:record={'workspace_id':'w7','pane_id':'w7:p1','session':'firstmate-cleanroom','harness':'claude'}
            (p/'state/captain-console.json').write_text(json.dumps(record))
            source=ENTRY.read_text()
            functions=source[source.index('console_record_pane() {'):source.index('# --- Cold-start supervision arm', source.index('console_record_pane() {'))]
            runner=p/'run.sh'
            runner.write_text("""#!/usr/bin/env bash
set -eu
FM_HOME=$1
CONSOLE_RECORD=$1/state/captain-console.json
FM_HERDR_SESSION=firstmate-cleanroom
FM_HARNESS=codex
FM_CODE_ROOT=/controlled-code
FM_CONSOLE_LABEL=firstmate
NM_HOME=$1/nm
SESSION_STARTED_NOW=0
die() { echo "$*" >&2; exit 1; }
session_socket() { echo /controlled-socket; }
console_converge_plan() { echo immediate; }
console_converge() { [ "$FAIL_CONVERGE" = 0 ] || return 75; printf '%s %s existing\\n' "$1" "$2"; }
console_workspaces() { :; }
hs() {
 case "$1 $2" in
  'pane list') [ "$FAIL_LIST" = 0 ] || return 73; if [ -f "$FM_HOME/created" ]; then echo '{"result":{"panes":[{"workspace_id":"w8","pane_id":"w8:p1"}]}}'; else cat "$FM_HOME/reply"; fi ;;
  'workspace create') sleep 0.1; touch "$FM_HOME/created"; echo create >> "$FM_HOME/effects"; [ "$FAIL_CREATE" = 0 ] || return 74; echo '{"result":{"workspace":{"workspace_id":"w8"},"root_pane":{"pane_id":"w8:p1"}}}' ;;
  'pane run') echo run >> "$FM_HOME/effects" ;;
 esac
}
"""+functions+'\n'+source[source.index('console_location=$(ensure_console_workspace)'):source.index("printf 'enter-firstmate: console workspace")]+'printf \'%s %s %s\\n\' "$ws" "$pane" "$how"\n')
            env={**os.environ,'FAIL_LIST':str(int(fail_list)),'FAIL_CREATE':str(int(fail_create)),'FAIL_CONVERGE':str(int(fail_converge))}
            if concurrent:
                children=[subprocess.Popen(['bash',str(runner),str(p)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
                for child in children:
                    out,err=child.communicate(timeout=5)
                    self.assertEqual(child.returncode,0,err)
                r=subprocess.CompletedProcess([],0,out,err)
            else:
                r=subprocess.run(['bash',str(runner),str(p)],env=env,text=True,capture_output=True,timeout=5)
            effects=(p/'effects').read_text() if (p/'effects').exists() else ''
            return r,effects
    def test_failed_existing_console_convergence_propagates(self):
        record={'workspace_id':'w7','pane_id':'w7:p1','session':'firstmate-cleanroom','harness':'codex'}
        r,e=self.run_case({'result':{'panes':[{'workspace_id':'w7','pane_id':'w7:p1'}]}},record=record,fail_converge=True)
        self.assertEqual(r.returncode,75,r.stderr);self.assertEqual(e,'')
    def test_two_clicks_create_one_console(self):
        r,e=self.run_case({'result':{'panes':[]}},concurrent=True)
        self.assertEqual(e.count('create\n'),1,e)
    def test_stale_other_harness_creates_successor(self):
        r,e=self.run_case({'result':{'panes':[]}})
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn('w8 w8:p1 created',r.stdout);self.assertNotIn('close that workspace',r.stderr)
    def test_live_other_harness_refuses_without_creating(self):
        r,e=self.run_case({'result':{'panes':[{'workspace_id':'w7','pane_id':'w7:p1'}]}})
        self.assertNotEqual(r.returncode,0);self.assertEqual(e,'')
    def test_failed_inventory_refuses_without_creating(self):
        r,e=self.run_case({},fail_list=True)
        self.assertNotEqual(r.returncode,0);self.assertEqual(e,'')
    def test_malformed_inventory_refuses_without_creating(self):
        r,e=self.run_case({'error':'unavailable'})
        self.assertNotEqual(r.returncode,0);self.assertEqual(e,'')
    def test_failed_child_status_propagates(self):
        r,e=self.run_case({'result':{'panes':[]}},fail_create=True)
        self.assertNotEqual(r.returncode,0);self.assertNotIn('created',r.stdout)
if __name__=='__main__':unittest.main(verbosity=2)
