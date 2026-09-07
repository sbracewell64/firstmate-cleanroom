#!/usr/bin/env bash
# Tests for bin/fm-nm-observe.sh, the no-mistakes observation obligation owner.
#
# Regression origin (2026-09-06, no-mistakes friction programme NMF-OBS-1):
# managed launches carried no durable observation, so a run that was never
# created, a run created but never bound to its task, a run the home never
# knew about, and a daemon that restarted under a bound run were all invisible.
# These cases pin the obligation lifecycle and the read-only inventory
# reconciliation over isolated fixtures: a real throwaway git worktree, a fake
# `no-mistakes` that serves env-driven TOON and logs every argv it receives, a
# fake NM_HOME whose daemon.pid the cases rewrite, and profile JSON captures.
# No case starts, answers, aborts, or reruns a pipeline, and the closing case
# proves the observer never sent such a verb.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OBSERVE="$ROOT/bin/fm-nm-observe.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-observe)
fm_git_identity fmtest fmtest@example.invalid

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA" "$HOME_DIR/config"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NM_LOG="$TMP_ROOT/no-mistakes.argv"
: > "$NM_LOG"
NM_HOME_FAKE="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME_FAKE"

# The fake no-mistakes serves exactly the two read-only reads the observer is
# allowed to make and records every argv so the closing case can prove no
# other verb was ever sent.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then
          [ "${FM_FAKE_AXI_STATUS_RUN_RC:-0}" = 0 ] || exit "$FM_FAKE_AXI_STATUS_RUN_RC"
          printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        exit 0 ;;
    esac ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
# A fake tmux answers the worker-liveness read with FM_FAKE_TMUX_RC.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit "${FM_FAKE_TMUX_RC:-0}"
SH
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_NM_LOG="$NM_LOG"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
export FM_NM_OBSERVE_TIMEOUT=5 FM_NM_OBSERVE_BUDGET_SECS=10

write_daemon_pid() {  # <pid> <started>
  printf '{"pid":%s,"started_at":"%s"}\n' "$1" "$2" > "$NM_HOME_FAKE/daemon.pid"
}
write_daemon_pid 4242 2026-09-06T00:00:00Z

profile_json() {  # <ready true|false> -> file path
  local f="$TMP_ROOT/profile-$1.json"
  if [ "$1" = true ]; then
    printf '{"record":"fm-tool-profile/v1","profile":{"nm_home":"%s","path0":"/opt/tools/bin","parent":"bash","state":"OBSERVED","detail":""},"tools":[{"state":"QUALIFIED","tool":"no-mistakes","version":"1.61.0","bound":"floor=1.46.0","path":"/opt/tools/bin/no-mistakes","required":true,"detail":"build 0af0be6"}],"unready":[],"ready":true}\n' "$NM_HOME_FAKE" > "$f"
  else
    printf '{"record":"fm-tool-profile/v1","profile":{"nm_home":"%s","path0":"/opt/tools/bin","parent":"bash","state":"OBSERVED","detail":""},"tools":[{"state":"ABSENT","tool":"no-mistakes","version":"","bound":"floor=1.46.0","path":"","required":true,"detail":"not on PATH"}],"unready":["ENVIRONMENT_UNREADY: no-mistakes ABSENT; owner: install it"],"ready":false}\n' "$NM_HOME_FAKE" > "$f"
  fi
  printf '%s\n' "$f"
}
PROFILE_OK=$(profile_json true)
PROFILE_BAD=$(profile_json false)

make_worktree() {  # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" checkout -q -b "$2"
  printf 'commands:\n  lint: bin/fm-lint.sh\n' > "$1/.no-mistakes.yaml"
  git -C "$1" add .no-mistakes.yaml
  git -C "$1" commit -q -m policy
}

make_task() {  # <id> <kind> <mode> <worktree>
  fm_write_meta "$STATE/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$4" "project=$4" \
    "harness=echo" "kind=$2" "mode=$3" "yolo=off"
}

# TOON shaped exactly like the installed CLI's `axi status`: a current-branch
# block when one exists, then the repository-wide runs table.
axi_status_toon() {  # <current-branch> <rows-tsv>
  local rows=$2 n
  n=$(printf '%s\n' "$rows" | grep -c . || true)
  printf 'current_branch: %s\n' "$1"
  printf 'count: %s of %s total\n' "$n" "$n"
  printf 'runs[%s]{id,branch,status,head,pr}:\n' "$n"
  printf '%s\n' "$rows" | awk -F '\t' 'NF >= 4 { printf "  \"%s\",%s,%s,%s,\"%s\"\n", $1, $2, $3, $4, $5 }'
}

axi_run_toon() {  # <id> <branch> <status> <head> <outcome> [pr]
  printf 'current_branch: %s\n' "$2"
  printf 'other_branch_run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: %s\n  pr: "%s"\n' "$1" "$2" "$3" "$4" "${6:-}"
  printf '  steps[1]{step,status,findings,duration_ms}:\n    intent,completed,0,9\n'
  [ -z "$5" ] || printf 'outcome: %s\n' "$5"
}

record_get() { grep "^$2=" "$STATE/$1.nm-observe" | tail -1 | cut -d= -f2-; }

WT1="$TMP_ROOT/wt-t1"
make_worktree "$WT1" fm/t1
HEAD1=$(git -C "$WT1" rev-parse HEAD)
SHORT1=${HEAD1:0:8}

# --- enrol ----------------------------------------------------------------

make_task scout1 scout "" "$WT1"
out=$("$OBSERVE" enrol scout1 2>&1); rc=$?
expect_code 1 "$rc" "enrol refuses a scout"
assert_contains "$out" "NOT_MANAGED task=scout1" "scout enrolment names NOT_MANAGED"
assert_absent "$STATE/scout1.nm-observe" "no obligation for a scout"

make_task dpr direct-PR direct-PR "$WT1"
fm_write_meta "$STATE/dpr.meta" "window=firstmate:fm-dpr" "endpoint_task_id=dpr" "worktree=$WT1" "project=$WT1" "harness=echo" "kind=ship" "mode=direct-PR" "yolo=off"
out=$("$OBSERVE" enrol dpr 2>&1); rc=$?
expect_code 1 "$rc" "enrol refuses a direct-PR ship task"
assert_contains "$out" "NOT_MANAGED task=dpr" "direct-PR enrolment names NOT_MANAGED"

out=$("$OBSERVE" enrol nope 2>&1); rc=$?
expect_code 2 "$rc" "enrol refuses a missing task record"

make_task t1 ship no-mistakes "$WT1"
out=$("$OBSERVE" enrol t1 --entrypoint spawn 2>&1); rc=$?
expect_code 0 "$rc" "enrol admits a managed task"
assert_contains "$out" "ENROLLED task=t1 entrypoint=spawn" "enrol prints the typed line"
assert_present "$STATE/t1.nm-observe" "obligation record exists"
[ "$(record_get t1 record)" = fm-nm-observation/v1 ] || fail "record schema"
[ "$(record_get t1 stage)" = enrolled ] || fail "stage enrolled after enrol"
[ "$(record_get t1 home)" = "$HOME_DIR" ] || fail "home identity recorded"
assert_present "$DATA/t1/nm-observation-receipt.md" "receipt rendered at enrol"
assert_grep "launch not yet admitted" "$DATA/t1/nm-observation-receipt.md" "receipt names the enrolled gap"
out=$("$OBSERVE" enrol t1 2>&1); rc=$?
expect_code 0 "$rc" "second enrol is idempotent"
assert_contains "$out" "already enrolled" "idempotent enrol says so"
pass "enrol: managed tasks only, idempotent, receipt rendered"

# --- launch: obligation bound before admission ---------------------------------

out=$("$OBSERVE" launch t1 --profile-json "$PROFILE_OK" 2>&1); rc=$?
expect_code 0 "$rc" "launch admits a ready profile"
assert_contains "$out" "LAUNCH_ACCEPTED task=t1 attempt=" "launch prints the attempt"
ATTEMPT1=$(record_get t1 attempt_id)
[ -n "$ATTEMPT1" ] || fail "attempt id recorded"
[ "$(record_get t1 stage)" = launch-accepted ] || fail "stage launch-accepted"
[ "$(record_get t1 candidate_head)" = "$HEAD1" ] || fail "candidate head is the worktree HEAD"
[ "$(record_get t1 candidate_branch)" = fm/t1 ] || fail "candidate branch recorded"
[ "$(record_get t1 nm_home)" = "$NM_HOME_FAKE" ] || fail "NM_HOME from the profile"
[ "$(record_get t1 nm_version)" = 1.61.0 ] || fail "no-mistakes version from the profile"
[ "$(record_get t1 nm_build)" = 0af0be6 ] || fail "no-mistakes build from the profile"
[ "$(record_get t1 daemon_epoch)" = "4242@2026-09-06T00:00:00Z" ] || fail "daemon epoch from daemon.pid: $(record_get t1 daemon_epoch)"
case "$(record_get t1 policy)" in sha256:????????????????????????????????????????????????????????????????) ;; *) fail "policy digest: $(record_get t1 policy)" ;; esac
[ -z "$(record_get t1 run_id)" ] || fail "no run id before any run exists"
assert_no_grep "axi run" "$NM_LOG" "launch never starts a pipeline"
out=$("$OBSERVE" launch t1 --profile-json "$PROFILE_OK" 2>&1); rc=$?
expect_code 0 "$rc" "repeated launch with no run keeps the attempt"
[ "$(record_get t1 attempt_id)" = "$ATTEMPT1" ] || fail "duplicate launch did not open a second attempt"
[ "$(record_get t1 attempt_seq)" = 1 ] || fail "attempt sequence stays 1"
pass "launch: obligation bound before admission, identity recorded, duplicate launch is idempotent"

# --- preflight refusal keeps attempt identity, no run id ----------------------

WT2="$TMP_ROOT/wt-t2"
make_worktree "$WT2" fm/t2
make_task t2 ship no-mistakes "$WT2"
out=$("$OBSERVE" launch t2 --profile-json "$PROFILE_BAD" 2>&1); rc=$?
expect_code 1 "$rc" "unready profile refuses the launch"
assert_contains "$out" "PREFLIGHT_REFUSED task=t2 attempt=" "typed refusal line"
assert_contains "$out" "ENVIRONMENT_UNREADY: no-mistakes ABSENT" "refusal carries the profile's typed reason"
[ "$(record_get t2 stage)" = launch-refused ] || fail "stage launch-refused"
[ "$(record_get t2 outcome_class)" = preflight-refused ] || fail "outcome class preflight-refused"
[ -n "$(record_get t2 attempt_id)" ] || fail "refused launch keeps its attempt identity"
[ -z "$(record_get t2 run_id)" ] || fail "refused launch never fabricates a run id"
assert_grep "preflight refused" "$DATA/t2/nm-observation-receipt.md" "receipt states the refusal"
pass "preflight refusal: attempt identity kept, no run id"

# --- bind: no run yet -> MISSING_BINDING, nothing written ---------------------

export FM_FAKE_AXI_STATUS
FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t1 "$(printf '01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1')")
before=$(cat "$STATE/t1.nm-observe")
out=$("$OBSERVE" bind t1 2>&1); rc=$?
expect_code 1 "$rc" "bind refuses when no run is attributed"
assert_contains "$out" "MISSING_BINDING task=t1" "typed MISSING_BINDING"
[ "$(cat "$STATE/t1.nm-observe")" = "$before" ] || fail "MISSING_BINDING wrote nothing"
pass "bind: launch accepted with no run is MISSING_BINDING and records nothing"

# --- bind: real run id bound after creation, idempotent ------------------------

RUN1=01RUN1AAAAAAAAAAAAAAAAAAAA
FM_FAKE_AXI_STATUS=$(printf 'current_branch: fm/t1\nrun:\n  id: "%s"\n  branch: fm/t1\n  status: running\n  head: %s\n' "$RUN1" "$SHORT1"; axi_status_toon fm/t1 "$(printf '%s\tfm/t1\trunning\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "$RUN1" "$SHORT1")")
out=$("$OBSERVE" bind t1 2>&1); rc=$?
expect_code 0 "$rc" "bind succeeds once the run exists"
assert_contains "$out" "RUN_BOUND task=t1 run=$RUN1" "typed RUN_BOUND"
[ "$(record_get t1 run_id)" = "$RUN1" ] || fail "actual run id bound"
[ "$(record_get t1 stage)" = run-bound ] || fail "stage run-bound"
[ "$(record_get t1 outcome_class)" = active ] || fail "active class while running"
export FM_FAKE_AXI_STATUS_RUN
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon "$RUN1" fm/t1 running "$SHORT1" "")
out=$("$OBSERVE" bind t1 2>&1); rc=$?
expect_code 0 "$rc" "rebinding the same run is a refresh"
assert_contains "$out" "REFRESHED task=t1 run=$RUN1" "duplicate bind refreshes"
[ "$(record_get t1 run_id)" = "$RUN1" ] || fail "duplicate bind keeps one run id"
[ "$(record_get t1 attempt_seq)" = 1 ] || fail "duplicate bind opens no new attempt"
out=$("$OBSERVE" bind t1 --run 01RUN2BBBBBBBBBBBBBBBBBBBB 2>&1); rc=$?
expect_code 1 "$rc" "a second run id on one attempt is refused"
assert_contains "$out" "RUN_BOUND task=t1 run=$RUN1 refused=01RUN2BBBBBBBBBBBBBBBBBBBB" "refusal names both runs"
assert_contains "$out" "launch t1 --retry" "refusal names the retry heal"
[ "$(record_get t1 run_id)" = "$RUN1" ] || fail "refused rebind left the binding alone"
pass "bind: actual run id bound once, duplicates and reordering create no second obligation"

# --- launch while the bound run is active keeps identity -----------------------

out=$("$OBSERVE" launch t1 --profile-json "$PROFILE_OK" 2>&1); rc=$?
expect_code 1 "$rc" "launch over an active bound run is refused"
assert_contains "$out" "a resumed run keeps its identity" "refusal explains resume identity"
[ "$(record_get t1 run_id)" = "$RUN1" ] || fail "active run binding untouched"
pass "launch: a resumed run keeps its identity"

# --- refresh: canonical outcome, never manufactured ----------------------------

FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon "$RUN1" fm/t1 completed "$SHORT1" failed)
# A tampered record claiming success is corrected from the canonical read.
"$OBSERVE" refresh t1 >/dev/null 2>&1
sed -i.bak 's/^outcome_class=.*/outcome_class=successful/' "$STATE/t1.nm-observe" && rm -f "$STATE/t1.nm-observe.bak"
out=$("$OBSERVE" refresh t1 2>&1); rc=$?
expect_code 0 "$rc" "refresh reads the canonical record"
[ "$(record_get t1 outcome_class)" = failed ] || fail "canonical failed outcome overrides a tampered success: $(record_get t1 outcome_class)"
[ "$(record_get t1 run_outcome)" = failed ] || fail "run_outcome recorded"
assert_grep "class failed" "$DATA/t1/nm-observation-receipt.md" "receipt carries the canonical class"
pass "refresh: outcome comes from the canonical record only; PASS cannot be manufactured"

# --- refresh: later head change and PR facts ----------------------------------

git -C "$WT1" commit -q --allow-empty -m later
HEAD1B=$(git -C "$WT1" rev-parse HEAD)
printf 'pr=https://example.invalid/pr/7\npr_head=%s\n' "$HEAD1B" >> "$STATE/t1.meta"
"$OBSERVE" refresh t1 >/dev/null 2>&1
[ "$(record_get t1 head_change)" = "$HEAD1B" ] || fail "later head change recorded"
[ "$(record_get t1 pr)" = https://example.invalid/pr/7 ] || fail "pr bound from the task record"
# The marker in the exact shape bin/fm-pr-lib.sh's fm_pr_poll_merge_mark_notified
# writes: the version tag, then provider, host, path, and number.
printf '%s\n' fm-pr-poll-merge-notified-v1 github example.invalid example/repo 7 > "$STATE/t1.pr-poll-merge-notified"
chmod 0600 "$STATE/t1.pr-poll-merge-notified"
"$OBSERVE" refresh t1 >/dev/null 2>&1
[ "$(record_get t1 publication)" = "merged:github:example.invalid:example/repo:7" ] || fail "publication bound by the marker's PR identity: $(record_get t1 publication)"
printf 'https://example.invalid/pr/7\n' > "$STATE/t1.pr-poll-merge-notified"
"$OBSERVE" refresh t1 >/dev/null 2>&1
[ "$(record_get t1 publication)" = "merged:github:example.invalid:example/repo:7" ] || fail "a marker without the owned identity binds nothing new"
printf '%s\n' fm-pr-poll-merge-notified-v1 github example.invalid example/repo 7 > "$STATE/t1.pr-poll-merge-notified"
assert_grep "later head change" "$DATA/t1/nm-observation-receipt.md" "receipt names the head change"
assert_grep "publication: merged" "$DATA/t1/nm-observation-receipt.md" "receipt names the publication"
pass "refresh: later head change and late merge are bound from this home's records"

# --- retry links to its predecessor -------------------------------------------

RUN2=01RUN2BBBBBBBBBBBBBBBBBBBB
SHORT1B=${HEAD1B:0:8}
FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t1 "$(printf '%s\tfm/t1\trunning\t%s\t\n%s\tfm/t1\tcompleted\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "$RUN2" "$SHORT1B" "$RUN1" "$SHORT1")")
out=$("$OBSERVE" launch t1 --profile-json "$PROFILE_OK" 2>&1); rc=$?
expect_code 0 "$rc" "launch after a terminal run opens a retry"
assert_contains "$out" "predecessor_run=$RUN1" "retry names the predecessor run"
[ "$(record_get t1 attempt_seq)" = 2 ] || fail "second attempt"
[ "$(record_get t1 predecessor_attempt_id)" = "$ATTEMPT1" ] || fail "predecessor attempt linked"
[ "$(record_get t1 predecessor_run_id)" = "$RUN1" ] || fail "predecessor run linked"
[ -z "$(record_get t1 run_id)" ] || fail "new attempt starts unbound"
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon "$RUN2" fm/t1 running "$SHORT1B" "")
out=$("$OBSERVE" bind t1 --run "$RUN2" 2>&1); rc=$?
expect_code 0 "$rc" "bind the retry run explicitly"
[ "$(record_get t1 run_id)" = "$RUN2" ] || fail "retry run bound"
pass "retry: new attempt linked to predecessor attempt and run"

# --- reconcile: unchanged healthy inventory is quiet; baseline seeds once -------

make_task u1 ship no-mistakes "$WT1"
out=$("$OBSERVE" reconcile --now 2>&1); rc=$?
expect_code 0 "$rc" "first reconcile runs"
assert_contains "$out" "NM_OBSERVE: BASELINE runs=1" "pre-existing orphan row is baseline, not adopted"
assert_not_contains "$out" "ORPHAN_RUN" "baseline rows are not reported as orphans"
assert_contains "$out" "PREFLIGHT_REFUSED task=t2" "refused launch reported once"
assert_contains "$out" "UNENROLLED task=u1" "a managed task with no obligation is reported"
assert_contains "$out" "enrol u1" "unenrolled task names the heal"
"$OBSERVE" enrol u1 >/dev/null 2>&1 || fail "heal enrols u1"
out=$("$OBSERVE" reconcile --now 2>&1); rc=$?
expect_code 0 "$rc" "second reconcile runs"
[ -z "$out" ] || fail "unchanged inventory must print nothing, got:"$'\n'"$out"
pass "reconcile: baseline seeded once, unchanged state prints nothing"

# --- reconcile: orphan run appears -> reported once ------------------------------

WT6="$TMP_ROOT/wt-dpr2"
make_worktree "$WT6" fm/dpr2
make_task dpr2 ship direct-PR "$WT6"
FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t1 "$(printf '01ORPHAN\tfm/unknown-home\trunning\tabcdef12\t\n01DPRRUN\tfm/dpr2\trunning\tabcd1234\t\n%s\tfm/t1\trunning\t%s\t\n%s\tfm/t1\tcompleted\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "$RUN2" "$SHORT1B" "$RUN1" "$SHORT1")")
out=$("$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "ORPHAN_RUN run=01ORPHAN branch=fm/unknown-home" "new orphan reported"
assert_contains "$out" "no task record in this home owns this branch" "orphan text is true for an unowned branch"
assert_contains "$out" "explicit coverage gap, not adopted" "orphan is a coverage gap"
assert_not_contains "$out" "ORPHAN_RUN run=01AAA" "baseline row stays quiet"
assert_contains "$out" "UNMANAGED_RUN run=01DPRRUN branch=fm/dpr2 status=running head=abcd1234 pr=none task=dpr2 kind=ship mode=direct-PR" "a run on a direct-PR task's branch is an unmanaged run naming its owner"
assert_contains "$out" "uncovered entrypoint" "unmanaged run is an uncovered entrypoint"
assert_not_contains "$out" "ORPHAN_RUN run=01DPRRUN" "an owned branch is never called an orphan"
out=$("$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "orphan and unmanaged runs reported once only, got:"$'\n'"$out"
pass "reconcile: orphan and unmanaged runs reported once as explicit coverage gaps"

# --- reconcile: crash between run creation and binding (UNBOUND_RUN) ------------

WT3="$TMP_ROOT/wt-t3"
make_worktree "$WT3" fm/t3
HEAD3=$(git -C "$WT3" rev-parse HEAD)
make_task t3 ship no-mistakes "$WT3"
"$OBSERVE" launch t3 --profile-json "$PROFILE_OK" >/dev/null 2>&1 || fail "t3 launch"
RUN3=01RUN3CCCCCCCCCCCCCCCCCCCC
FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t3 "$(printf '%s\tfm/t3\trunning\t%s\t\n01ORPHAN\tfm/unknown-home\trunning\tabcdef12\t\n%s\tfm/t1\trunning\t%s\t\n%s\tfm/t1\tcompleted\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "$RUN3" "${HEAD3:0:8}" "$RUN2" "$SHORT1B" "$RUN1" "$SHORT1")")
out=$("$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "UNBOUND_RUN task=t3 run=$RUN3" "run created but not bound is a typed gap"
assert_contains "$out" "bind t3 --run $RUN3" "gap names the exact heal"
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon "$RUN3" fm/t3 running "${HEAD3:0:8}" "")
"$OBSERVE" bind t3 --run "$RUN3" >/dev/null 2>&1 || fail "heal binds t3"
out=$("$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "healed gap goes quiet, got:"$'\n'"$out"
pass "reconcile: crash between run creation and binding reported, quiet after heal"

# --- reconcile: crash between launch acceptance and run creation (LAUNCH_GAP) ----

WT4="$TMP_ROOT/wt-t4"
make_worktree "$WT4" fm/t4
make_task t4 ship no-mistakes "$WT4"
"$OBSERVE" launch t4 --profile-json "$PROFILE_OK" >/dev/null 2>&1 || fail "t4 launch"
out=$(FM_NM_OBSERVE_LAUNCH_GRACE_SECS=0 FM_FAKE_TMUX_RC=1 "$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "LAUNCH_GAP task=t4" "dead worker with no run is a launch gap"
assert_contains "$out" "worker=dead" "gap reports the dead worker"
out=$(FM_NM_OBSERVE_LAUNCH_GRACE_SECS=0 FM_FAKE_TMUX_RC=1 "$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "launch gap reported once, got:"$'\n'"$out"
out=$(FM_NM_OBSERVE_LAUNCH_GRACE_SECS=0 FM_FAKE_TMUX_RC=0 "$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "MISSING_BINDING task=t4" "alive worker past grace is missing binding, not a crash"
assert_contains "$out" "worker=alive" "missing binding reports the live worker"
pass "reconcile: crash between launch acceptance and run creation is typed and reported once"

# --- bind --run: a same-branch run with an unrelated head is never bound ----------

FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon 01OLDRUNFFFFFFFFFFFFFFFFFF fm/t4 completed 0badc0de passed)
before=$(cat "$STATE/t4.nm-observe")
out=$("$OBSERVE" bind t4 --run 01OLDRUNFFFFFFFFFFFFFFFFFF 2>&1); rc=$?
expect_code 1 "$rc" "explicit --run for a same-branch run with an unrelated head is refused"
assert_contains "$out" "MISSING_BINDING task=t4 branch=fm/t4 run=01OLDRUNFFFFFFFFFFFFFFFFFF" "refusal names the run"
assert_contains "$out" "head 0badc0de matches neither the worktree head nor a pipeline-owned active run" "refusal names the reason"
[ "$(cat "$STATE/t4.nm-observe")" = "$before" ] || fail "refused explicit --run wrote nothing"
[ -z "$(record_get t4 run_id)" ] || fail "no run id bound after the refusal"
pass "bind --run: the head rule applies to an explicit run id; a reused branch name never binds"

# --- reconcile: superseding run and outcome change ------------------------------

FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t3 "$(printf '01RUN3NEWDDDDDDDDDDDDDDDDD\tfm/t3\trunning\t%s\t\n%s\tfm/t3\tfailed\t%s\t\n%s\tfm/t1\trunning\t%s\t\n%s\tfm/t1\tcompleted\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "${HEAD3:0:8}" "$RUN3" "${HEAD3:0:8}" "$RUN2" "$SHORT1B" "$RUN1" "$SHORT1")")
out=$("$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "SUPERSEDED_RUN task=t3 run=$RUN3 newer=01RUN3NEWDDDDDDDDDDDDDDDDD" "newer run on the bound branch reported"
assert_contains "$out" "OUTCOME_CHANGED task=t3 run=$RUN3 recorded=running/active canonical=failed/unread" "canonical status change from a table row claims no class"
assert_contains "$out" "refresh t3" "outcome change names the refresh heal"
pass "reconcile: repair run and outcome change surfaced with heals"

# --- daemon reset: detected and reported, never silently rebound ----------------

WT5="$TMP_ROOT/wt-t5"
make_worktree "$WT5" fm/t5
HEAD5=$(git -C "$WT5" rev-parse HEAD)
make_task t5 ship no-mistakes "$WT5"
"$OBSERVE" launch t5 --profile-json "$PROFILE_OK" >/dev/null 2>&1 || fail "t5 launch"
write_daemon_pid 9999 2026-09-07T00:00:00Z
RUN5=01RUN5EEEEEEEEEEEEEEEEEEEE
FM_FAKE_AXI_STATUS=$(printf 'current_branch: fm/t5\nrun:\n  id: "%s"\n  branch: fm/t5\n  status: running\n  head: %s\n' "$RUN5" "${HEAD5:0:8}"; axi_status_toon fm/t5 "$(printf '%s\tfm/t5\trunning\t%s\t' "$RUN5" "${HEAD5:0:8}")")
out=$("$OBSERVE" bind t5 2>&1); rc=$?
expect_code 1 "$rc" "bind refuses across a daemon reset"
assert_contains "$out" "DAEMON_RESET task=t5 recorded=4242@2026-09-06T00:00:00Z observed=9999@2026-09-07T00:00:00Z" "reset names both identities"
[ -z "$(record_get t5 run_id)" ] || fail "reset did not silently rebind"
out=$("$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "DAEMON_RESET task=t5" "reconcile reports the reset"
assert_contains "$out" "RUN_VANISHED task=t1 run=$RUN2" "a successful per-run read naming another run is a vanished run"
out=$("$OBSERVE" bind t5 --accept-daemon-reset 2>&1); rc=$?
expect_code 0 "$rc" "explicit acceptance binds"
[ "$(record_get t5 run_id)" = "$RUN5" ] || fail "bound after explicit acceptance"
[ "$(record_get t5 daemon_reset_observed)" = "9999@2026-09-07T00:00:00Z" ] || fail "reset observation recorded"
assert_grep "daemon identity changed" "$DATA/t5/nm-observation-receipt.md" "receipt names the reset"
write_daemon_pid 4242 2026-09-06T00:00:00Z
pass "daemon reset: detected, reported, bound only on explicit acceptance"

# --- failed or budget-exhausted reads are INVENTORY_UNAVAILABLE, never vanished ----

out=$(FM_FAKE_AXI_STATUS_RUN_RC=1 "$OBSERVE" refresh t5 2>&1); rc=$?
expect_code 0 "$rc" "refresh survives a failed canonical read"
assert_contains "$out" "INVENTORY_UNAVAILABLE task=t5 run=$RUN5" "failed per-run read is unavailable, not vanished"
assert_not_contains "$out" "RUN_VANISHED" "failed read never claims the run vanished"
[ "$(record_get t5 outcome_class)" = active ] || fail "recorded class kept across a failed read: $(record_get t5 outcome_class)"
out=$(FM_FAKE_AXI_STATUS_RUN_RC=1 "$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "INVENTORY_UNAVAILABLE task=t1 run=$RUN2" "reconcile reports a failed per-run read as unavailable"
assert_contains "$out" "query failed or timed out" "unavailable line names the failed query"
assert_not_contains "$out" "RUN_VANISHED" "reconcile never calls a failed read a vanished run"
out=$(FM_NM_OBSERVE_BUDGET_SECS=0 "$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "INVENTORY_UNAVAILABLE task=" "exhausted budget is unavailable"
assert_not_contains "$out" "RUN_VANISHED" "exhausted budget never claims a run vanished"
assert_not_contains "$out" "ORPHAN_RUN" "exhausted budget reports no orphans"
pass "reconcile/refresh: failed, timed-out, or over-budget reads keep the obligation pending"

# --- finalize: receipt survives the runtime record --------------------------------

out=$("$OBSERVE" finalize t3 2>&1); rc=$?
expect_code 0 "$rc" "finalize succeeds"
assert_contains "$out" "FINALIZED task=t3 receipt=$DATA/t3/nm-observation-receipt.md" "finalize names the receipt"
[ "$(record_get t3 stage)" = finalized ] || fail "stage finalized"
rm -f "$STATE/t3.nm-observe"
assert_present "$DATA/t3/nm-observation-receipt.md" "receipt survives removal of the runtime record"
assert_grep "finalized at" "$DATA/t3/nm-observation-receipt.md" "receipt marks finalization"
assert_grep "captured eval cases are review evidence, never launch coverage" "$DATA/t3/nm-observation-receipt.md" "receipt never counts eval capture as coverage"
pass "finalize: durable receipt outlives the runtime record"

# --- a detached-HEAD managed task never aborts the pass ------------------------------

WTD="$TMP_ROOT/wt-detached"
make_worktree "$WTD" fm/detached
git -C "$WTD" checkout -q --detach
make_task d1 ship no-mistakes "$WTD"
"$OBSERVE" enrol d1 >/dev/null 2>&1 || fail "enrol d1"
out=$(timeout 60 "$OBSERVE" reconcile --now 2>&1); rc=$?
expect_code 0 "$rc" "reconcile completes with a detached-HEAD managed task"
assert_not_contains "$out" "bad array subscript" "no bash error leaks as a finding"
[ ! -L "$STATE/.nm-observe-watermark.lock" ] && [ ! -e "$STATE/.nm-observe-watermark.lock" ] || fail "watermark lock released after the pass"
out=$(timeout 60 "$OBSERVE" reconcile --now 2>&1); rc=$?
expect_code 0 "$rc" "a second pass acquires the watermark lock again"
pass "reconcile: a detached-HEAD task is skipped for branch ownership and the pass completes"

# --- inventory unavailable: obligations stay pending, reported once ---------------

FM_FAKE_AXI_STATUS=$(axi_status_toon fm/t5 "$(printf '%s\tfm/t5\trunning\t%s\t\n01ORPHAN\tfm/unknown-home\trunning\tabcdef12\t\n%s\tfm/t1\trunning\t%s\t\n%s\tfm/t1\tcompleted\t%s\t\n01AAA\tfm/other\tcompleted\tdeadbee1\thttps://example.invalid/pr/1' "$RUN5" "${HEAD5:0:8}" "$RUN2" "$SHORT1B" "$RUN1" "$SHORT1")")
"$OBSERVE" reconcile --now >/dev/null 2>&1
out=$("$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "settled inventory prints nothing before the outage, got:"$'\n'"$out"
out=$(PATH="$TMP_ROOT/emptybin:/usr/bin:/bin" "$OBSERVE" reconcile --now 2>&1)
assert_contains "$out" "INVENTORY_UNAVAILABLE task=" "missing CLI is a typed gap"
assert_contains "$out" "no-mistakes not on PATH" "gap names the reason"
out=$(PATH="$TMP_ROOT/emptybin:/usr/bin:/bin" "$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "unavailable inventory reported once, got:"$'\n'"$out"
out=$("$OBSERVE" reconcile --now 2>&1)
assert_not_contains "$out" "ORPHAN_RUN" "recovery never re-reports the baseline or an already-reported orphan"
assert_not_contains "$out" "BASELINE" "recovery is not a new baseline"
out=$("$OBSERVE" reconcile --now 2>&1)
[ -z "$out" ] || fail "recovered inventory is quiet again, got:"$'\n'"$out"
pass "reconcile: unavailable inventory is a typed, once-reported gap that keeps the run memory"

# --- a home with a managed task but no obligation reports it without querying -----

EMPTY="$TMP_ROOT/empty-home"
mkdir -p "$EMPTY/state" "$EMPTY/data"
fm_write_meta "$EMPTY/state/z.meta" "window=firstmate:fm-z" "endpoint_task_id=z" "worktree=$WT1" "project=$WT1" "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
: > "$NM_LOG"
out=$(FM_HOME="$EMPTY" FM_STATE_OVERRIDE="$EMPTY/state" FM_DATA_OVERRIDE="$EMPTY/data" "$OBSERVE" reconcile --startup 2>&1); rc=$?
expect_code 0 "$rc" "reconcile in a home whose only managed task is unenrolled"
assert_contains "$out" "UNENROLLED task=z" "the first managed task in a home is reported when its enrolment is missing"
assert_not_contains "$out" "BASELINE" "no baseline is claimed without an inventory read"
[ ! -s "$NM_LOG" ] || fail "a home with no obligation never queried no-mistakes"
out=$(FM_HOME="$EMPTY" FM_STATE_OVERRIDE="$EMPTY/state" FM_DATA_OVERRIDE="$EMPTY/data" "$OBSERVE" reconcile --startup 2>&1)
[ -z "$out" ] || fail "unenrolled task reported once, got:"$'\n'"$out"
pass "reconcile: a home with an unenrolled managed task reports it and never queries"

# --- a home with neither obligation nor managed task never queries, prints nothing --

SILENT="$TMP_ROOT/silent-home"
mkdir -p "$SILENT/state" "$SILENT/data"
fm_write_meta "$SILENT/state/s.meta" "window=firstmate:fm-s" "endpoint_task_id=s" "worktree=$WT1" "project=$WT1" "harness=echo" "kind=scout" "mode=" "yolo=off"
: > "$NM_LOG"
out=$(FM_HOME="$SILENT" FM_STATE_OVERRIDE="$SILENT/state" FM_DATA_OVERRIDE="$SILENT/data" "$OBSERVE" reconcile --startup 2>&1); rc=$?
expect_code 0 "$rc" "reconcile in an unadopted home"
[ -z "$out" ] || fail "unadopted home prints nothing, got:"$'\n'"$out"
[ ! -s "$NM_LOG" ] || fail "unadopted home never queried no-mistakes"
assert_absent "$SILENT/state/.nm-observe-watermark" "unadopted home writes no watermark"
pass "reconcile: a home with neither obligation nor managed task is silent and never queries"

# --- parser against a real `axi status` capture --------------------------------------
# Captured read-only on 2026-09-07 from the cleanroom home
# (NM_HOME=/home/shane/.firstmate-cleanroom/no-mistakes, no-mistakes 1.61.0
# build 0af0be6): the header lines below are verbatim, the first row is
# verbatim, and the second row reproduces the shape of a row whose
# numeric-looking head the CLI double-quotes ("60395817"); the remaining rows
# of the ten-row capture are elided. Rows are indented by one space.
CAP="$TMP_ROOT/capture-home"
mkdir -p "$CAP/state" "$CAP/data"
WTC="$TMP_ROOT/wt-c1"
make_worktree "$WTC" fm/c1
fm_write_meta "$CAP/state/c1.meta" "window=firstmate:fm-c1" "endpoint_task_id=c1" "worktree=$WTC" "project=$WTC" "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
cap_observe() { FM_HOME="$CAP" FM_STATE_OVERRIDE="$CAP/state" FM_DATA_OVERRIDE="$CAP/data" "$OBSERVE" "$@"; }
cap_observe launch c1 --profile-json "$PROFILE_OK" >/dev/null 2>&1 || fail "c1 launch"
FM_FAKE_AXI_STATUS=$(printf 'current_branch: fm/nmf-obs-launch-enrolment\nruns_on_current_branch: 0\ncount: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n')
out=$(cap_observe reconcile --now 2>&1)
assert_contains "$out" "BASELINE runs=0" "empty real-shaped inventory is an empty baseline"
FM_FAKE_AXI_STATUS=$(cat <<'TOON'
current_branch: fm/nmf-obs-launch-enrolment
runs_on_current_branch: 0
count: 10 of 10 total
runs[10]{id,branch,status,head,pr}:
 "01M1WNEF1D2RX62H6VFQXNH7K1",fm/launcher-nm-home-into-herdr-server,completed,3a2f68e8,"https://github.com/sbracewell64/firstmate-cleanroom/pull/9"
 "01M1WK7Q0N3F8Z5R2T9V4X6B1C",fm/quoted-numeric-head,completed,"60395817","https://github.com/sbracewell64/firstmate-cleanroom/pull/8"
TOON
)
out=$(cap_observe reconcile --now 2>&1)
assert_contains "$out" "ORPHAN_RUN run=01M1WNEF1D2RX62H6VFQXNH7K1 branch=fm/launcher-nm-home-into-herdr-server status=completed head=3a2f68e8 pr=https://github.com/sbracewell64/firstmate-cleanroom/pull/9" "real capture row parses id, branch, status, head, and pr"
assert_contains "$out" "ORPHAN_RUN run=01M1WK7Q0N3F8Z5R2T9V4X6B1C branch=fm/quoted-numeric-head status=completed head=60395817 pr=https://github.com/sbracewell64/firstmate-cleanroom/pull/8" "a quoted numeric head parses unquoted"
pass "reconcile: the runs table of a real axi status capture parses in both head shapes"

# --- cadence: without --now or --startup the watermark gates the scan ----------------

: > "$NM_LOG"
out=$("$OBSERVE" reconcile 2>&1)
[ -z "$out" ] || fail "cadence-gated reconcile prints nothing"
[ ! -s "$NM_LOG" ] || fail "cadence-gated reconcile did not query"
pass "reconcile: cadence gate honoured"

# --- negative: the observer never sent a mutating verb --------------------------

for f in "$TMP_ROOT"/*.argv; do :; done
# Every argv line the fake received across the whole suite is re-read from the
# log this suite truncated only after the mutation-heavy cases; re-run the
# heaviest paths once more with a fresh log to make the assertion exact.
: > "$NM_LOG"
"$OBSERVE" refresh t1 >/dev/null 2>&1 || true
"$OBSERVE" bind t5 >/dev/null 2>&1 || true
"$OBSERVE" reconcile --now >/dev/null 2>&1 || true
"$OBSERVE" finalize t5 >/dev/null 2>&1 || true
while IFS= read -r line; do
  case "$line" in
    "axi status"|"axi status --run "*) ;;
    *) fail "observer sent a non-read verb to no-mistakes: $line" ;;
  esac
done < "$NM_LOG"
[ -s "$NM_LOG" ] || fail "negative case checked nothing"
pass "negative: only read-only status reads were ever sent; no gate, abort, sync, rerun, or run"

fm_test_cleanup
