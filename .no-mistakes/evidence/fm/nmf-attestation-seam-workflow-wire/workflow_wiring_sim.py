#!/usr/bin/env python3
"""Faithful end-to-end simulation of .github/workflows/no-mistakes-required.yml.

This does NOT grep the YAML for strings. It:
  1. Parses the workflow into a semantic model (steps, if-conditions, env maps,
     the action `with:` inputs) and asserts the wiring MEANS what the intent
     requires (base-sha checkout, classify owns the mode mapping, resolve/readback
     gated on mode==current, action inputs bound to resolve outputs).
  2. EXECUTES the real `run:` blocks of the classify/resolve/readback steps for
     concrete PR events, with a stubbed `gh api` returning a live PR subject and
     the real bin/fm-nmf-verify-input.sh on disk, then feeds the resulting action
     inputs to the real pinned verifier -- reproducing what the GitHub runner does.
"""
import json, os, re, subprocess, sys, tempfile, textwrap, pathlib
import yaml

ROOT = pathlib.Path(sys.argv[1])
WF = ROOT / ".github/workflows/no-mistakes-required.yml"
VERIFY = pathlib.Path(sys.argv[2])  # fetched pinned verifier.py

SIGNATURE = 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
STEPS_JSON = '[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'
OLD_SHA = "1" * 40
NEW_SHA = "2" * 40

def attested_body(head):
    return f'{SIGNATURE}\n<!-- no-mistakes-pipeline-attestation:v1 {{"head_sha":"{head}","steps":{STEPS_JSON}}} -->'

wf = yaml.safe_load(WF.read_text())
job = wf["jobs"]["require-no-mistakes"] if "require-no-mistakes" in wf["jobs"] else list(wf["jobs"].values())[0]
steps = {s.get("name"): s for s in job["steps"]}

def check(label, cond):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {label}")
    if not cond:
        check.failed += 1
check.failed = 0

print("== 1. Semantic model assertions (parsed YAML, not substring grep) ==")
# permission for the live read
perms = wf["permissions"]
check("permissions grants pull-requests: read for the live PR read",
      perms.get("pull-requests") == "read")
check("permissions still restricts contents to read", perms.get("contents") == "read")

checkout = steps["Check out base gate helper"]
check("gate helper checked out from PR BASE sha (a PR cannot supply its own guard)",
      checkout["with"]["ref"] == "${{ github.event.pull_request.base.sha }}")
check("checkout uses persist-credentials: false",
      checkout["with"]["persist-credentials"] in (False, "false"))

classify = steps["Classify event input mode"]
check("classify is the single owner of the event->mode mapping (calls helper classify)",
      classify["run"].strip().startswith("bin/fm-nmf-verify-input.sh classify"))
check("classify feeds github.event.action to the helper",
      classify["env"]["NMF_EVENT_ACTION"] == "${{ github.event.action }}")

resolve = steps["Resolve live PR subject"]
check("resolve runs ONLY in current mode", resolve["if"] == "steps.classify.outputs.mode == 'current'")
check("resolve does the one live read via gh api repos/OWNER/REPO/pulls/N",
      "gh api" in resolve["run"] and "pulls/${NMF_EVENT_NUMBER}" in resolve["run"])
check("resolve hands live number/head/body to the helper resolve subcommand",
      "fm-nmf-verify-input.sh resolve" in resolve["run"])
check("resolve uses github.token for GH_TOKEN", resolve["env"]["GH_TOKEN"] == "${{ github.token }}")

action = steps["Verify no-mistakes signature and pipeline attestation"]
check("action is the pinned require-no-mistakes @32d396a (unchanged)",
      action["uses"].endswith("@32d396ac0f29135daf7fcb9964aba9d5f4e796d6"))
check("action pr-body is bound to resolve output (empty in historical when step skipped)",
      action["with"]["pr-body"] == "${{ steps.resolve.outputs.body }}")
check("action pr-head-sha is bound to resolve output",
      action["with"]["pr-head-sha"] == "${{ steps.resolve.outputs.head_sha }}")
check("pr-head-ref left on action event-payload default (exempt-branch unchanged)",
      "pr-head-ref" not in action["with"])
check("pr-author left on action event-payload default (fork-approval unchanged)",
      "pr-author" not in action["with"])

readback = steps["Read back live PR subject"]
check("readback runs ONLY in current mode", readback["if"] == "steps.classify.outputs.mode == 'current'")
check("readback re-reads live subject and calls helper readback",
      "gh api" in readback["run"] and "fm-nmf-verify-input.sh readback" in readback["run"])
check("readback is ordered AFTER the verify (action) step",
      list(steps).index("Read back live PR subject") > list(steps).index("Verify no-mistakes signature and pipeline attestation"))

# ---- executable helpers -------------------------------------------------------
def gh_stub_dir(live_json):
    d = tempfile.mkdtemp(prefix="ghstub-")
    stub = pathlib.Path(d) / "gh"
    stub.write_text('#!/usr/bin/env bash\ncat <<\'JSON\'\n' + json.dumps(live_json) + '\nJSON\n')
    stub.chmod(0o755)
    return d

def run_step(step, context, live_json=None, extra_env=None):
    """Execute a step's real run: block with its env resolved from context."""
    def sub(v):
        if not isinstance(v, str): return v
        def repl(m):
            expr = m.group(1).strip()
            return str(eval_expr(expr, context))
        return re.sub(r"\$\{\{(.*?)\}\}", repl, v)
    env = dict(os.environ)
    for k, val in (step.get("env") or {}).items():
        env[k] = sub(val)
    if extra_env: env.update(extra_env)
    env["GITHUB_REPOSITORY"] = "kunchenguid/firstmate-cleanroom"
    path = env["PATH"]
    if live_json is not None:
        path = gh_stub_dir(live_json) + os.pathsep + path
    env["PATH"] = path
    out = tempfile.NamedTemporaryFile("w+", delete=False, suffix=".ghout")
    env["GITHUB_OUTPUT"] = out.name
    proc = subprocess.run(["bash", "-c", step["run"]], cwd=ROOT, env=env,
                          capture_output=True, text=True)
    outputs = {}
    text = pathlib.Path(out.name).read_text()
    # parse GITHUB_OUTPUT (key=value and key<<DELIM..DELIM heredocs)
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = re.match(r"^([A-Za-z0-9_]+)<<(.+)$", ln)
        if m:
            key, delim = m.group(1), m.group(2)
            body = []
            i += 1
            while i < len(lines) and lines[i] != delim:
                body.append(lines[i]); i += 1
            outputs[key] = "\n".join(body)
        elif "=" in ln:
            k, _, v = ln.partition("=")
            outputs[k] = v
        i += 1
    return proc.returncode, proc.stdout, proc.stderr, outputs

def eval_expr(expr, ctx):
    # supports github.event.action, github.event.pull_request.*, github.token,
    # steps.resolve.outputs.*
    cur = ctx
    for part in expr.split("."):
        cur = cur[part]
    return cur

def run_verifier(body, head):
    env = dict(os.environ)
    env.update(PR_BODY=body, PR_HEAD_SHA=head, PR_AUTHOR="regression", PR_NUMBER="3006")
    return subprocess.run(["python3", str(VERIFY)], env=env, capture_output=True, text=True)

def eval_if(cond, ctx):
    m = re.match(r"steps\.classify\.outputs\.mode == '(\w+)'", cond)
    return ctx["steps"]["classify"]["outputs"]["mode"] == m.group(1)

print("\n== 2. Executed workflow orchestration: HISTORICAL event (edited) ==")
# opened/edited: classify->historical, resolve SKIPPED, action gets empty inputs,
# verifier judges the FROZEN event payload. A historically invalid body stays red.
ctx = {"github": {"event": {"action": "edited",
        "pull_request": {"number": 3006, "head": {"sha": NEW_SHA}, "base": {"sha": "base"}}},
        "token": "x"}, "steps": {}}
rc, so, se, outs = run_step(classify, ctx)
ctx["steps"]["classify"] = {"outputs": outs}
check("classify(edited) => mode=historical", outs.get("mode") == "historical")
resolve_runs = eval_if(resolve["if"], ctx)
check("resolve step is SKIPPED in historical mode (no live read)", not resolve_runs)
# action inputs: resolve outputs absent -> empty
pr_body_input = ctx["steps"].get("resolve", {}).get("outputs", {}).get("body", "")
pr_head_input = ctx["steps"].get("resolve", {}).get("outputs", {}).get("head_sha", "")
check("action pr-body input is EMPTY (action falls back to frozen event payload)", pr_body_input == "")
check("action pr-head-sha input is EMPTY (frozen event fallback)", pr_head_input == "")
# The frozen event payload body is historically invalid (attests OLD head at NEW head event)
frozen_body = attested_body(OLD_SHA)
v = run_verifier(frozen_body, NEW_SHA)
check("watched-red (a): historically-invalid frozen body stays RED even with a later clean live body",
      v.returncode != 0)
print("    verifier(frozen event payload) rc=%d :: %s" % (v.returncode, (v.stdout+v.stderr).strip().splitlines()[-1][:120]))

print("\n== 3. Executed workflow orchestration: CURRENT event (synchronize), sound ==")
ctx = {"github": {"event": {"action": "synchronize",
        "pull_request": {"number": 3006, "head": {"sha": NEW_SHA}, "base": {"sha": "base"}}},
        "token": "x"}, "steps": {}}
rc, so, se, outs = run_step(classify, ctx)
ctx["steps"]["classify"] = {"outputs": outs}
check("classify(synchronize) => mode=current", outs.get("mode") == "current")
check("resolve step RUNS in current mode", eval_if(resolve["if"], ctx))
live = {"number": 3006, "head": {"sha": NEW_SHA}, "body": attested_body(NEW_SHA)}
rc, so, se, outs = run_step(resolve, ctx, live_json=live)
ctx["steps"]["resolve"] = {"outputs": outs}
check("resolve binds subject and emits head_sha=live head", outs.get("head_sha") == NEW_SHA)
check("resolve emits subject_number/subject_head for readback",
      outs.get("subject_number") == "3006" and outs.get("subject_head") == NEW_SHA)
check("resolve emits the live body carrying the current-head attestation",
      NEW_SHA in (outs.get("body") or ""))
# action consumes resolve outputs
v = run_verifier(outs["body"], outs["head_sha"])
check("watched-red (c): current-mode matching live body/head/identity VERIFIES green", v.returncode == 0)
print("    verifier(live subject) rc=%d :: %s" % (v.returncode, (v.stdout+v.stderr).strip().splitlines()[-1][:120]))
# readback after verify: head unchanged -> green stands
rc, so, se, rb = run_step(readback, ctx, live_json=live)
check("readback passes when head did not advance during verification", rc == 0)

print("\n== 4. Executed workflow orchestration: CURRENT event, head advanced (readback) ==")
# verify ran against subject head NEW_SHA, but live head advanced to a 3rd sha.
adv = "3" * 40
live_adv = {"number": 3006, "head": {"sha": adv}, "body": attested_body(adv)}
rc, so, se, rb = run_step(readback, ctx, live_json=live_adv)
check("watched-red (b): readback REFUSES green after head advanced during verification", rc != 0)
print("    readback rc=%d :: %s" % (rc, (so+se).strip().splitlines()[-1][:120]))

print("\n== 5. Executed workflow orchestration: CURRENT event, superseded subject ==")
# event fired for OLD head, but live head is already NEW -> resolve fails closed.
ctx2 = {"github": {"event": {"action": "synchronize",
        "pull_request": {"number": 3006, "head": {"sha": OLD_SHA}, "base": {"sha": "base"}}},
        "token": "x"}, "steps": {"classify": {"outputs": {"mode": "current"}}}}
live_super = {"number": 3006, "head": {"sha": NEW_SHA}, "body": attested_body(NEW_SHA)}
rc, so, se, outs = run_step(resolve, ctx2, live_json=live_super)
check("watched-red (d): resolve FAILS CLOSED on a superseded subject (old event, advanced live head)", rc != 0)
print("    resolve rc=%d :: %s" % (rc, (so+se).strip().splitlines()[-1][:120]))
# and empty live body fails closed too
ctx3 = {"github": {"event": {"action": "reopened",
        "pull_request": {"number": 3006, "head": {"sha": NEW_SHA}, "base": {"sha": "base"}}},
        "token": "x"}, "steps": {"classify": {"outputs": {"mode": "current"}}}}
live_empty = {"number": 3006, "head": {"sha": NEW_SHA}, "body": ""}
rc, so, se, outs = run_step(resolve, ctx3, live_json=live_empty)
check("resolve FAILS CLOSED on empty live body (no silent frozen-event fallback)",
      rc != 0 and "body" not in outs)

print("\n== 6. Executed workflow orchestration: CURRENT event, genuinely stale live body ==")
# resolve binds (matching subject) but the live body attests an OLDER head -> verifier catches it.
ctx4 = {"github": {"event": {"action": "synchronize",
        "pull_request": {"number": 3006, "head": {"sha": NEW_SHA}, "base": {"sha": "base"}}},
        "token": "x"}, "steps": {"classify": {"outputs": {"mode": "current"}}}}
live_stale = {"number": 3006, "head": {"sha": NEW_SHA}, "body": attested_body(OLD_SHA)}
rc, so, se, outs = run_step(resolve, ctx4, live_json=live_stale)
check("resolve binds the matching subject before body is judged", rc == 0)
v = run_verifier(outs["body"], outs["head_sha"])
check("governance NOT weakened: genuinely stale live attestation still FAILS at the verifier", v.returncode != 0)
print("    verifier(stale live body) rc=%d :: %s" % (v.returncode, (v.stdout+v.stderr).strip().splitlines()[-1][:120]))

print("\n================ RESULT ================")
if check.failed:
    print(f"FAILED: {check.failed} assertion(s) failed")
    sys.exit(1)
print("ALL WORKFLOW-WIRING ASSERTIONS PASSED")
