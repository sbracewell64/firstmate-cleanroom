#!/usr/bin/env bash
# Tests for bin/fm-stage.sh, the ship-task lifecycle stage owner, and for the
# stage vocabulary bin/fm-classify-lib.sh classifies.
#
# Regression origin (2026-09-06, no-mistakes friction programme NMF-3): the
# first `done:` milestone of a no-mistakes ship task meant "committed, now wait
# for firstmate to say start validation", so the handoff was a conversational
# steer that a restart, a duplicate delivery, or a rewritten candidate could
# lose or double. These cases pin the explicit stage sequence over isolated
# fixtures: a real throwaway git worktree, a fake `no-mistakes` that answers the
# version probe and serves env-driven `axi status` TOON while logging every
# argv, and a fake NM_HOME whose daemon.pid the observer reads. Every stage line
# is read back through the classifier's public functions, never by matching the
# scripts' source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

STAGE="$ROOT/bin/fm-stage.sh"
TMP_ROOT=$(fm_test_tmproot fm-stage)
fm_git_identity fmtest fmtest@example.invalid

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NM_LOG="$TMP_ROOT/no-mistakes.argv"
: > "$NM_LOG"
NM_HOME_FAKE="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME_FAKE"
printf '{"pid":4242,"started_at":"2026-09-06T00:00:00Z"}\n' > "$NM_HOME_FAKE/daemon.pid"

# The fake answers exactly what the lifecycle's consumers read: the version
# probe (bin/fm-tool-profile.sh) and the read-only `axi status` reads (the
# observer's bind/refresh and bin/fm-crew-state.sh). It never serves a run
# verb, and the closing case proves none was ever sent.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
case "${1:-}" in
  --version) printf 'no-mistakes version v%s (0af0be6) 2026-08-31T14:04:25Z\n' "${FM_FAKE_NM_VERSION:-1.61.0}"; exit 0 ;;
  axi)
    shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; exit 0 ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}"; exit 0 ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_NM_LOG="$NM_LOG"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
export NM_HOME="$NM_HOME_FAKE"
export FM_NM_OBSERVE_TIMEOUT=5 FM_NM_OBSERVE_BUDGET_SECS=10 FM_CREW_STATE_NM_TIMEOUT=5
export FM_FAKE_AXI_STATUS="" FM_FAKE_NM_VERSION="" FM_FAKE_CI_LOGS="" FM_FAKE_RUNS_LIST=""

make_worktree() {  # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" checkout -q -b "$2"
  printf 'commands:\n  lint: true\n' > "$1/.no-mistakes.yaml"
  git -C "$1" add .no-mistakes.yaml
  git -C "$1" commit -q -m candidate
}

make_task() {  # <id> <mode> <worktree> [gen]
  fm_write_meta "$STATE/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$3" "project=$3" \
    "harness=echo" "kind=ship" "mode=$2" "yolo=off" "model=default" "effort=low" "spawn_gen=${4:-s1.1.1}"
  mkdir -p "$DATA/$1"
  printf '# Task\nbuild the thing\n' > "$DATA/$1/brief.md"
  : > "$STATE/$1.status"
}

meta_get() { grep "^$2=" "$STATE/$1.meta" | tail -1 | cut -d= -f2-; }
obs_get() { grep "^$2=" "$STATE/$1.nm-observe" 2>/dev/null | tail -1 | cut -d= -f2-; }
stage_lines() { grep -c '' "$STATE/$1.status"; }
last_line() { tail -1 "$STATE/$1.status"; }

# A `run:` block shaped as `axi status` emits it for the current branch.
run_toon() {  # <id> <branch> <status> <head> [outcome] [pr]
  printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: "%s"\n  pr: "%s"\n  findings: none\n' "$1" "$2" "$3" "$4" "${6:-}"
  [ -z "${5:-}" ] || printf 'outcome: %s\n' "$5"
}

# --- the classifier's stage table ------------------------------------------

test_each_stage_verb_classifies_exactly_one_way() {
  local verb cls line
  for verb in $FM_CLASSIFY_STAGE_VERBS; do
    cls=$(status_stage_class "$verb") || fail "$verb: no stage class"
    line="$verb: task=t gen=s1 branch=fm/t head=abc tree=def intent=- decisions=- mode=no-mistakes yolo=off alloc=echo/default/low/tmux nm_home=%2Fnm%20home profile=- attempt=- run=- step=- outcome=- pr=- owner=worker reason=merged%20PR%20ready"
    [ "$(status_line_stage "$line")" = "$verb" ] || fail "$verb: status_line_stage did not read the verb"
    [ "$(status_line_verb "$line")" = "$verb" ] || fail "$verb: status_line_verb changed"
    case "$cls" in
      progress)
        status_is_captain_relevant "$line" && fail "$verb (progress) must not be captain-relevant even though its receipt text says merged/PR ready"
        status_is_terminal_verb "$line" && fail "$verb (progress) must not be a terminal verb"
        ;;
      wait|terminal)
        status_is_captain_relevant "$line" || fail "$verb ($cls) must be captain-relevant"
        status_is_terminal_verb "$line" || fail "$verb ($cls) must end the worker's turn like blocked:/done:"
        ;;
      *) fail "$verb: unexpected class $cls" ;;
    esac
    status_is_paused "$line" && fail "$verb must never read as paused"
    [ "$(status_stage_field "$line" nm_home)" = "/nm home" ] || fail "$verb: receipt field did not decode"
    [ "$(status_stage_field "$line" reason)" = "merged PR ready" ] || fail "$verb: reason field did not decode"
    status_stage_field "$line" nope >/dev/null && fail "$verb: absent field must fail"
    printf '%s\n' "$line" > "$TMP_ROOT/cls-$verb.status"
    [ -z "$(status_open_decisions "$TMP_ROOT/cls-$verb.status")" ] || fail "$verb must never open a decision"
  done
  # The table, not the receipt text, decides: an override of the captain regex
  # still classifies a progress line as progress and a wait line as relevant.
  FM_CAPTAIN_RE='candidate-committed' status_is_captain_relevant "candidate-committed: task=t" \
    && fail "a captain regex override must not promote a progress stage line"
  FM_CAPTAIN_RE='nothing-matches' status_is_captain_relevant "validation-pending: task=t reason=hold" \
    || fail "a captain regex override must not demote a wait stage line"
  status_line_stage "working: candidate-committed soon" >/dev/null && fail "prose mentioning a stage is not a stage line"
  status_stage_field "done: PR x checks green task=t" task >/dev/null && fail "a non-stage line has no receipt fields"
  # The progress/wait/terminal split covers the vocabulary completely.
  # shellcheck disable=SC2086 # deliberate word-split: one verb per line so wc -l counts the vocabulary
  [ "$(printf '%s\n' $FM_CLASSIFY_STAGE_VERBS | wc -l | tr -d ' ')" = 7 ] || fail "stage vocabulary size changed; update this table"
  pass "classify: each stage verb classifies exactly one way and its receipt decodes"
}

# --- committed: candidate recorded, validation issued by code -------------------

WT1="$TMP_ROOT/wt-a1"
make_worktree "$WT1" fm/a1
HEAD1=$(git -C "$WT1" rev-parse HEAD)

test_fm_home_is_required() {
  local out rc
  out=$(env -u FM_HOME -u FM_STATE_OVERRIDE "$STAGE" a1 show 2>&1); rc=$?
  expect_code 2 "$rc" "no FM_HOME must refuse"
  assert_contains "$out" "FM_HOME is not set" "refusal names FM_HOME"
  pass "fm-stage: FM_HOME must be explicit"
}

test_committed_refuses_unprovable_candidates() {
  local out rc
  make_task a1 no-mistakes "$WT1"
  printf 'dirty\n' > "$WT1/dirty.txt"
  out=$("$STAGE" a1 committed 2>&1); rc=$?
  expect_code 1 "$rc" "uncommitted candidate refuses"
  assert_contains "$out" "STAGE_REFUSED: transition=committed task=a1 reason=UNCOMMITTED" "typed refusal for an uncommitted candidate"
  [ "$(stage_lines a1)" = 0 ] || fail "a refusal must append nothing"
  assert_absent "$STATE/a1.nm-observe" "a refusal must not admit a launch"
  rm -f "$WT1/dirty.txt"
  git -C "$WT1" checkout -q --detach
  out=$("$STAGE" a1 committed 2>&1); rc=$?
  expect_code 1 "$rc" "detached HEAD refuses"
  assert_contains "$out" "reason=DETACHED" "typed refusal for a detached candidate"
  git -C "$WT1" checkout -q fm/a1
  fm_write_meta "$STATE/scout1.meta" "window=firstmate:fm-scout1" "worktree=$WT1" "kind=scout"
  out=$("$STAGE" scout1 committed 2>&1); rc=$?
  expect_code 1 "$rc" "a scout has no ship lifecycle"
  assert_contains "$out" "reason=NOT_SHIP" "typed refusal for a scout"
  pass "fm-stage committed: uncommitted, detached, and non-ship candidates refuse with a typed line and record nothing"
}

test_committed_issues_validation_admitted_with_receipt() {
  local out rc committed admitted
  : > "$NM_LOG"
  out=$("$STAGE" a1 committed 2>&1); rc=$?
  expect_code 0 "$rc" "committed admits validation (got: $out)"
  assert_contains "$out" "STAGE: candidate-committed: task=a1" "candidate-committed issued"
  assert_contains "$out" "STAGE: validation-admitted: task=a1" "validation-admitted issued by code"
  assert_contains "$out" "next: worker starts the pipeline now on head ${HEAD1:0:12}" "next line tells the worker to start now"
  assert_contains "$out" "never --yes" "next line keeps the --yes ban"
  [ "$(stage_lines a1)" = 2 ] || fail "exactly two receipts appended (got $(stage_lines a1))"
  committed=$(sed -n 1p "$STATE/a1.status")
  admitted=$(sed -n 2p "$STATE/a1.status")
  [ "$(status_line_stage "$committed")" = candidate-committed ] || fail "first line is the candidate receipt"
  [ "$(status_line_stage "$admitted")" = validation-admitted ] || fail "second line is the admitted receipt"
  # The identity envelope on the receipt.
  [ "$(status_stage_field "$admitted" task)" = a1 ] || fail "receipt task"
  [ "$(status_stage_field "$admitted" gen)" = s1.1.1 ] || fail "receipt worker epoch (spawn_gen)"
  [ "$(status_stage_field "$admitted" branch)" = fm/a1 ] || fail "receipt branch"
  [ "$(status_stage_field "$admitted" head)" = "${HEAD1:0:12}" ] || fail "receipt head"
  [ "$(status_stage_field "$admitted" tree)" = "$(git -C "$WT1" rev-parse 'HEAD^{tree}' | cut -c1-12)" ] || fail "receipt tree"
  [ "$(status_stage_field "$admitted" intent)" != - ] || fail "receipt carries the accepted intent identity"
  [ "$(status_stage_field "$admitted" mode)" = no-mistakes ] || fail "receipt mode"
  [ "$(status_stage_field "$admitted" yolo)" = off ] || fail "receipt yolo"
  [ "$(status_stage_field "$admitted" alloc)" = echo/default/low/tmux ] || fail "receipt resource allocation (got $(status_stage_field "$admitted" alloc))"
  [ "$(status_stage_field "$admitted" nm_home)" = "$NM_HOME_FAKE" ] || fail "receipt NM_HOME from the qualified profile (got $(status_stage_field "$admitted" nm_home))"
  [ "$(status_stage_field "$admitted" profile)" = "1.61.0+0af0be6" ] || fail "receipt runtime/profile identity (got $(status_stage_field "$admitted" profile))"
  [ "$(status_stage_field "$admitted" owner)" = worker ] || fail "receipt next owner"
  [ "$(status_stage_field "$admitted" run)" = - ] || fail "no run yet"
  # The observer's obligation binds the same launch-attempt identity.
  assert_present "$STATE/a1.nm-observe" "the observer admitted the launch"
  [ "$(obs_get a1 stage)" = launch-accepted ] || fail "observer stage launch-accepted"
  [ "$(obs_get a1 entrypoint)" = stage ] || fail "observer entrypoint names the stage owner"
  [ -n "$(obs_get a1 attempt_id)" ] || fail "observer attempt id"
  [ "$(status_stage_field "$admitted" attempt)" = "$(obs_get a1 attempt_id)" ] || fail "receipt attempt equals the observer attempt"
  [ "$(meta_get a1 stage_attempt)" = "$(obs_get a1 attempt_id)" ] || fail "record attempt equals the observer attempt"
  [ "$(obs_get a1 candidate_head)" = "$HEAD1" ] || fail "observer candidate head equals the receipt candidate"
  # The record carries the stage and the full identities.
  [ "$(meta_get a1 stage)" = validation-admitted ] || fail "record stage"
  [ "$(meta_get a1 stage_head)" = "$HEAD1" ] || fail "record full head"
  [ "$(meta_get a1 stage_gen)" = s1.1.1 ] || fail "record worker epoch"
  grep -q '^kind=ship$' "$STATE/a1.meta" || fail "record kept its other fields"
  # Nothing here started a pipeline.
  ! grep -qE '^axi (run|respond|abort|sync)' "$NM_LOG" || fail "the stage owner must never start or answer a run"
  pass "fm-stage committed: records the candidate, issues validation-admitted with the identity envelope, and shares the observer's attempt"
}

test_duplicate_delivery_is_a_no_op() {
  local before out rc
  before=$(cat "$STATE/a1.status")
  out=$("$STAGE" a1 committed 2>&1); rc=$?
  expect_code 0 "$rc" "duplicate committed exits 0"
  assert_contains "$out" "STAGE_UNCHANGED: validation-admitted task=a1" "duplicate reports unchanged"
  assert_not_contains "$out" "STAGE: " "duplicate issues nothing"
  [ "$(cat "$STATE/a1.status")" = "$before" ] || fail "duplicate delivery appended a receipt"
  [ "$(meta_get a1 stage)" = validation-admitted ] || fail "duplicate left the stage alone"
  out=$("$STAGE" a1 show 2>&1); rc=$?
  expect_code 0 "$rc" "show exits 0"
  assert_contains "$out" "STAGE_RECORDED: validation-admitted task=a1" "show prints the recorded stage"
  assert_contains "$out" "next: worker starts the pipeline now" "show repeats the recorded stage's next step"
  [ "$(cat "$STATE/a1.status")" = "$before" ] || fail "show appended a receipt"
  pass "fm-stage: duplicate delivery of the same transition is a no-op and show changes nothing"
}

test_restart_resumes_at_recorded_stage_under_new_worker_epoch() {
  local before out
  before=$(cat "$STATE/a1.status")
  # A relaunch republishes the record with a new spawn_gen; the stage survives.
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s2.2.2/' "$STATE/a1.meta" && rm -f "$STATE/a1.meta.bak"
  out=$("$STAGE" a1 show 2>&1)
  assert_contains "$out" "STAGE_RECORDED: validation-admitted task=a1 gen=s1.1.1" "the recorded stage names the epoch that issued it"
  out=$("$STAGE" a1 committed 2>&1)
  assert_contains "$out" "STAGE_UNCHANGED: validation-admitted" "the replacement worker resumes at the recorded stage"
  [ "$(cat "$STATE/a1.status")" = "$before" ] || fail "a restart must not re-issue the admitted transition"
  pass "fm-stage: a restart mid-stage resumes at the recorded stage"
}

test_stale_candidate_head_refuses_typed() {
  local out rc before
  before=$(cat "$STATE/a1.status")
  git -C "$WT1" commit -q --amend --allow-empty -m 'rewritten candidate'
  out=$("$STAGE" a1 committed 2>&1); rc=$?
  expect_code 1 "$rc" "a rewritten candidate under an admitted attempt refuses"
  assert_contains "$out" "STAGE_REFUSED: transition=committed task=a1 reason=STALE_CANDIDATE" "typed stale-candidate refusal"
  assert_contains "$out" "${HEAD1:0:12}" "refusal names the recorded candidate"
  [ "$(cat "$STATE/a1.status")" = "$before" ] || fail "a stale refusal records nothing"
  out=$("$STAGE" a1 running 2>&1); rc=$?
  expect_code 1 "$rc" "running on a rewritten candidate refuses"
  assert_contains "$out" "reason=STALE_CANDIDATE" "running refuses the stale head"
  # Restore the admitted candidate so the sequence can continue.
  git -C "$WT1" reset -q --hard "$HEAD1"
  pass "fm-stage: a candidate head that moved off the admitted candidate refuses with a typed line"
}

test_running_binds_the_observer_run_and_descendant_fix_commits_stay_current() {
  local out rc line
  # A pipeline fix commit on top of the candidate is a descendant: still current.
  printf 'fix\n' > "$WT1/fix.txt"
  git -C "$WT1" add fix.txt
  git -C "$WT1" commit -q -m 'pipeline fix'
  FM_FAKE_AXI_STATUS=$(run_toon 01RUNA fm/a1 running "$(git -C "$WT1" rev-parse HEAD)")
  out=$("$STAGE" a1 running 2>&1); rc=$?
  expect_code 0 "$rc" "running binds (got: $out)"
  assert_contains "$out" "STAGE: validation-running: task=a1" "validation-running issued"
  line=$(last_line a1)
  [ "$(status_stage_field "$line" run)" = 01RUNA ] || fail "receipt run id from the canonical read"
  [ "$(status_stage_field "$line" step)" = running ] || fail "receipt step from the canonical read"
  [ "$(status_stage_field "$line" outcome)" = active ] || fail "receipt outcome class"
  [ "$(status_stage_field "$line" attempt)" = "$(obs_get a1 attempt_id)" ] || fail "same attempt across stages"
  [ "$(obs_get a1 run_id)" = 01RUNA ] || fail "observer bound the same run"
  [ "$(meta_get a1 stage_run)" = 01RUNA ] || fail "record run id"
  out=$("$STAGE" a1 running 2>&1); rc=$?
  expect_code 0 "$rc" "duplicate running exits 0"
  assert_contains "$out" "STAGE_UNCHANGED: validation-running" "duplicate running is a no-op"
  [ "$(stage_lines a1)" = 3 ] || fail "duplicate running appended nothing"
  pass "fm-stage running: binds the observer's run, keeps descendant fix commits current, deduplicates"
}

test_ci_ready_needs_the_canonical_verdict_never_narration() {
  local out rc line head
  head=$(git -C "$WT1" rev-parse HEAD)
  FM_FAKE_AXI_STATUS=$(run_toon 01RUNA fm/a1 running "$head")
  # A hand-written done: line must not certify CI readiness.
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' >> "$STATE/a1.status"
  out=$("$STAGE" a1 ci-ready --pr https://github.com/o/r/pull/7 2>&1); rc=$?
  expect_code 1 "$rc" "ci-ready without a canonical green refuses"
  assert_contains "$out" "reason=NOT_CI_READY" "typed refusal names the missing canonical verdict"
  out=$("$STAGE" a1 ci-ready --pr 'not a url' 2>&1); rc=$?
  expect_code 1 "$rc" "ci-ready with a bad PR refuses"
  assert_contains "$out" "reason=BAD_PR" "typed refusal for a malformed PR"
  FM_FAKE_AXI_STATUS=$(run_toon 01RUNA fm/a1 completed "$head" checks-passed https://github.com/o/r/pull/7)
  out=$("$STAGE" a1 ci-ready --pr https://github.com/o/r/pull/7 2>&1); rc=$?
  expect_code 0 "$rc" "ci-ready with canonical checks-passed issues (got: $out)"
  assert_contains "$out" "STAGE: ci-ready: task=a1" "ci-ready issued"
  line=$(last_line a1)
  [ "$(status_stage_field "$line" pr)" = https://github.com/o/r/pull/7 ] || fail "receipt PR"
  [ "$(status_stage_field "$line" outcome)" = ci-ready ] || fail "receipt outcome class from the observer refresh (got $(status_stage_field "$line" outcome))"
  [ "$(status_stage_field "$line" owner)" = merge-authority ] || fail "landing belongs to the merge authority"
  status_is_captain_relevant "$line" || fail "the ci-ready receipt wakes firstmate"
  [ "$(meta_get a1 stage)" = ci-ready ] || fail "record stage ci-ready"
  out=$("$STAGE" a1 ci-ready --pr https://github.com/o/r/pull/7 2>&1); rc=$?
  assert_contains "$out" "STAGE_UNCHANGED: ci-ready" "duplicate ci-ready is a no-op"
  ! grep -qE '^axi (run|respond|abort|sync)' "$NM_LOG" || fail "the stage owner must never start or answer a run"
  pass "fm-stage ci-ready: only the canonical run-step verdict certifies, never a hand-written line"
}

test_landing_and_activated_need_readback() {
  local out rc line proj
  # The project clone is a separate checkout that does not contain the candidate
  # yet, so nothing can be read back until the merge marker or the clone says so.
  proj="$TMP_ROOT/proj-a1"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" commit -q --allow-empty -m other-history
  sed -i.bak "s|^project=.*|project=$proj|" "$STATE/a1.meta" && rm -f "$STATE/a1.meta.bak"
  out=$("$STAGE" a1 activated 2>&1); rc=$?
  expect_code 1 "$rc" "activated without read-back refuses"
  assert_contains "$out" "reason=NO_READBACK" "typed refusal names the missing read-back"
  out=$("$STAGE" a1 landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records"
  assert_contains "$out" "STAGE: landing: task=a1" "landing issued"
  line=$(last_line a1)
  [ "$(status_stage_field "$line" pr)" = https://github.com/o/r/pull/7 ] || fail "landing keeps the recorded PR"
  status_is_captain_relevant "$line" && fail "landing is progress, not a wake"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n7\n' > "$STATE/a1.pr-poll-merge-notified"
  out=$("$STAGE" a1 activated 2>&1); rc=$?
  expect_code 0 "$rc" "activated with the merge marker records (got: $out)"
  line=$(last_line a1)
  [ "$(status_line_stage "$line")" = activated ] || fail "activated issued"
  [ "$(status_stage_field "$line" reason)" = "merged:github:github.com:o/r:7" ] || fail "read-back evidence carried (got $(status_stage_field "$line" reason))"
  out=$("$STAGE" a1 activated 2>&1)
  assert_contains "$out" "STAGE_UNCHANGED: activated" "duplicate activated is a no-op"
  # Completion -> currentness wiring at the terminal transition seam: the
  # activated transition is inert for a task with no work-context descriptor, and
  # refreshes the currentness receipt through the same owner when the landed child
  # declares a reconcile block. The per-obligation roadmap flip itself is covered
  # in tests/fm-work-context.test.sh; here we prove the seam invokes that owner.
  if command -v jq >/dev/null 2>&1; then
    assert_not_contains "$out" "currentness:" "activated is inert for a task with no work-context descriptor"
    mkdir -p "$DATA/a1"
    printf '{"reconcile":{"parent":"a1"}}\n' > "$DATA/a1/work-context.json"
    out=$("$STAGE" a1 activated 2>&1)
    assert_contains "$out" "currentness:" "activated reconciles currentness when the child declares a reconcile block"
    assert_present "$STATE/a1.parent-currentness" "the terminal transition writes the currentness receipt through the work-context owner"
    rm -f "$DATA/a1/work-context.json"
  fi
  pass "fm-stage landing/activated: landing records, activated needs read-back evidence and refreshes declared currentness"
}

# --- validation-pending: a hold or missing capacity never starts validation ------

WT2="$TMP_ROOT/wt-b1"
make_worktree "$WT2" fm/b1

test_open_hold_produces_pending_and_no_launch() {
  local out rc line
  make_task b1 no-mistakes "$WT2"
  printf 'needs-decision [key=api-shape]: pick one\n' >> "$STATE/b1.status"
  : > "$NM_LOG"
  out=$("$STAGE" b1 committed 2>&1); rc=$?
  expect_code 0 "$rc" "a held candidate still records and waits (got: $out)"
  assert_contains "$out" "STAGE: candidate-committed: task=b1" "candidate recorded"
  assert_contains "$out" "STAGE: validation-pending: task=b1" "explicit wait stage"
  assert_contains "$out" "next: worker stops and waits (hold:api-shape)" "next line names the hold"
  line=$(last_line b1)
  [ "$(status_stage_field "$line" reason)" = "hold:api-shape" ] || fail "pending reason names the open decision"
  [ "$(status_stage_field "$line" owner)" = firstmate ] || fail "the wait belongs to firstmate"
  status_is_captain_relevant "$line" || fail "the wait wakes firstmate"
  assert_absent "$STATE/b1.nm-observe" "a hold never reaches the observer's launch admission"
  [ ! -s "$NM_LOG" ] || fail "a hold never touches no-mistakes"
  [ "$(meta_get b1 stage)" = validation-pending ] || fail "record stage pending"
  out=$("$STAGE" b1 committed 2>&1)
  assert_contains "$out" "STAGE_UNCHANGED: validation-pending" "the same wait is not re-appended"
  [ "$(grep -c '^validation-pending' "$STATE/b1.status")" = 1 ] || fail "duplicate wait appended"
  # The decision closes; the same command now admits, and the receipt carries the
  # closed decision as a decision reference.
  printf 'resolved [key=api-shape]: REST\n' >> "$STATE/b1.status"
  out=$("$STAGE" b1 committed 2>&1); rc=$?
  expect_code 0 "$rc" "cleared hold admits (got: $out)"
  assert_contains "$out" "STAGE: validation-admitted: task=b1" "admitted after the hold cleared"
  line=$(last_line b1)
  [ "$(status_stage_field "$line" decisions)" = api-shape ] || fail "receipt carries the closed decision reference (got $(status_stage_field "$line" decisions))"
  [ "$(grep -c '^candidate-committed' "$STATE/b1.status")" = 1 ] || fail "the unchanged candidate was not re-recorded"
  pass "fm-stage: an open hold yields validation-pending with no launch, and clearing it admits with the decision reference"
}

test_missing_capacity_produces_pending_and_no_launch() {
  local out rc line wt
  wt="$TMP_ROOT/wt-c1"
  make_worktree "$wt" fm/c1
  make_task c1 no-mistakes "$wt"
  : > "$NM_LOG"
  FM_FAKE_NM_VERSION=1.0.0
  out=$("$STAGE" c1 committed 2>&1); rc=$?
  FM_FAKE_NM_VERSION=
  expect_code 0 "$rc" "missing capacity records and waits (got: $out)"
  assert_contains "$out" "STAGE: validation-pending: task=c1" "explicit wait stage on capacity"
  line=$(last_line c1)
  case "$(status_stage_field "$line" reason)" in
    capacity:PREFLIGHT_REFUSED*) ;;
    *) fail "pending reason names the preflight refusal (got $(status_stage_field "$line" reason))" ;;
  esac
  [ "$(obs_get c1 stage)" = launch-refused ] || fail "the observer recorded the refused attempt (got $(obs_get c1 stage))"
  [ "$(status_stage_field "$line" attempt)" = "$(obs_get c1 attempt_id)" ] || fail "the refused attempt identity is on the receipt"
  ! grep -qE '^axi (run|respond|abort|sync)' "$NM_LOG" || fail "no validation was started"
  [ "$(meta_get c1 stage)" = validation-pending ] || fail "record stage pending"
  pass "fm-stage: missing capacity yields validation-pending with the refused attempt and no validation start"
}

test_hold_appearing_during_admission_refuses() {
  local out rc wt
  wt="$TMP_ROOT/wt-d1"
  make_worktree "$wt" fm/d1
  make_task d1 no-mistakes "$wt"
  # An observer stub that opens a hold on the task while admitting the launch,
  # standing in for a decision that lands between the two reads.
  mkdir -p "$TMP_ROOT/racebin"
  cat > "$TMP_ROOT/racebin/fm-nm-observe.sh" <<SH
#!/usr/bin/env bash
printf 'needs-decision [key=late]: appeared during admission\n' >> "$STATE/d1.status"
exec "$ROOT/bin/fm-nm-observe.sh" "\$@"
SH
  chmod +x "$TMP_ROOT/racebin/fm-nm-observe.sh"
  cp "$ROOT/bin/fm-stage.sh" "$TMP_ROOT/racebin/fm-stage.sh"
  for f in fm-wake-lib.sh fm-backend.sh fm-pr-lib.sh fm-tasks-axi-lib.sh fm-backlog-transition-lib.sh fm-work-context-lib.sh fm-work-context-engineering-lib.sh fm-classify-lib.sh fm-timeout-lib.sh fm-nm-run-lib.sh fm-crew-state.sh fm-tmux-lib.sh fm-busy-lib.sh fm-tool-profile.sh fm-workflow-yaml.sh fm-lint.sh fm-lint-workflows.sh fm-bootstrap.sh; do
    [ -e "$ROOT/bin/$f" ] && ln -sf "$ROOT/bin/$f" "$TMP_ROOT/racebin/$f"
  done
  out=$("$TMP_ROOT/racebin/fm-stage.sh" d1 committed 2>&1); rc=$?
  expect_code 1 "$rc" "a hold that appears during admission refuses (got: $out)"
  assert_contains "$out" "reason=HOLD_APPEARED" "typed refusal for the late hold"
  assert_contains "$out" "hold:late" "refusal names the hold"
  ! grep -q '^validation-admitted' "$STATE/d1.status" || fail "the admitted line must not be written past a late hold"
  [ "$(meta_get d1 stage)" = candidate-committed ] || fail "the record stays at the candidate"
  pass "fm-stage: hold and candidate applicability are re-read immediately before the admitted line is issued"
}

# --- other delivery modes record the candidate only ------------------------------

test_direct_pr_and_local_only_record_candidate_only() {
  local out rc wt mode id
  for mode in direct-PR local-only; do
    id="e-${mode%%-*}"
    wt="$TMP_ROOT/wt-$id"
    make_worktree "$wt" "fm/$id"
    make_task "$id" "$mode" "$wt"
    : > "$NM_LOG"
    out=$("$STAGE" "$id" committed 2>&1); rc=$?
    expect_code 0 "$rc" "$mode committed records"
    assert_contains "$out" "STAGE: candidate-committed: task=$id" "$mode: candidate recorded"
    assert_not_contains "$out" "validation-" "$mode: no validation stage"
    [ "$(stage_lines "$id")" = 1 ] || fail "$mode: exactly one receipt"
    [ ! -s "$NM_LOG" ] || fail "$mode never touches no-mistakes"
    assert_absent "$STATE/$id.nm-observe" "$mode carries no observation obligation"
    out=$("$STAGE" "$id" running 2>&1); rc=$?
    expect_code 1 "$rc" "$mode has no running stage"
    assert_contains "$out" "reason=NOT_ADMITTED" "$mode: typed refusal"
  done
  assert_contains "$("$STAGE" e-direct show)" 'next: worker pushes the branch and opens the PR' "direct-PR next step"
  # shellcheck disable=SC2016 # literal assertion text: backticks are part of the expected next: line
  assert_contains "$("$STAGE" e-local show)" 'next: worker appends `done: ready in branch fm/e-local`' "local-only next step"
  pass "fm-stage: direct-PR and local-only record the candidate and keep their own definition of done"
}

test_only_read_only_verbs_were_sent() {
  local bad
  bad=$(grep -vE '^(--version|axi status( --run [^ ]+)?|axi logs.*|runs.*)$' "$NM_LOG" || true)
  [ -z "$bad" ] || fail "unexpected no-mistakes verbs were sent: $bad"
  pass "fm-stage: only the version probe and read-only status reads ever reached no-mistakes"
}

test_each_stage_verb_classifies_exactly_one_way
test_fm_home_is_required
test_committed_refuses_unprovable_candidates
test_committed_issues_validation_admitted_with_receipt
test_duplicate_delivery_is_a_no_op
test_restart_resumes_at_recorded_stage_under_new_worker_epoch
test_stale_candidate_head_refuses_typed
test_running_binds_the_observer_run_and_descendant_fix_commits_stay_current
test_ci_ready_needs_the_canonical_verdict_never_narration
test_landing_and_activated_need_readback
test_open_hold_produces_pending_and_no_launch
test_missing_capacity_produces_pending_and_no_launch
test_hold_appearing_during_admission_refuses
test_direct_pr_and_local_only_record_candidate_only
test_only_read_only_verbs_were_sent

# The result owner must distinguish checked pointers from observed consumption.
test_engineering_stage_evidence_and_residuals() {
  local wt head out rc desc pin mutation
  wt="$TMP_ROOT/wt-engineering"
  make_worktree "$wt" fm/engineering
  head=$(git -C "$wt" rev-parse HEAD)
  make_task engineering no-mistakes "$wt"
  printf abc > "$DATA/engineering/skill.md"
  desc="$DATA/engineering/work-context.json"
  cat > "$desc" <<EOF
{"engineering":{"generation":"g1","triggers":["test-change"],"skills":[{"id":"tdd","path":"$DATA/engineering/skill.md","release":"r1","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","role":"worker","stage":"test","trigger":"test-change"}],"verification":[{"id":"caller","skill":"tdd","scope":"composition","public_seam":"fm-brief","inputs":"declared source","environment":"controlled and inherited","oracle":"literal expected bytes","allowed_effects":"scratch only","source_identity":"r1","caller_identity":"fixture","command":"receiver-test","negative":"stale source refuses","owner":"crewmate-boundary-repair","next_gate":"ci-ready"},{"id":"consumer","skill":"tdd","scope":"deployed-consumer","public_seam":"next-worker","inputs":"qualified release","environment":"native subscription","oracle":"actual worker artifact","allowed_effects":"authorized receiver work","source_identity":"r1","caller_identity":"next-worker","command":"qualified worker","negative":"old source refuses","owner":"runtime-pin-adoption-gap","next_gate":"next genuine dispatch"}]}}
EOF
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" engineering committed 2>&1); rc=$?
  expect_code 0 "$rc" "valid engineering candidate admits: $out"
  pin=$(meta_get engineering stage_context)
  [ -n "$pin" ] || fail "stage must bind the declared engineering context"
  jq '.engineering.generation="g2"' "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  out=$("$STAGE" engineering show 2>&1); rc=$?
  expect_code 1 "$rc" "resume must refuse a changed admitted context"
  assert_contains "$out" 'ENGINEERING_CONTEXT' "resume names stale context"
  jq '.engineering.generation="g1"' "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  # Canonical JSON formatting is not a semantic generation change.
  FM_FAKE_AXI_STATUS=$(run_toon 01ENG fm/engineering reviewing "$head")
  out=$("$STAGE" engineering running --run 01ENG 2>&1); rc=$?
  expect_code 0 "$rc" "run binding survives unchanged engineering contract: $out"
  git -C "$wt" checkout -q -b newer-main HEAD^
  printf 'new main\n' > "$wt/main.txt"
  git -C "$wt" add main.txt
  git -C "$wt" commit -q -m 'advance main'
  git -C "$wt" checkout -q fm/engineering
  git -C "$wt" rebase newer-main >/dev/null 2>&1 || fail "normal current-base rebase failed"
  git -C "$wt" merge-base --is-ancestor "$head" HEAD && fail "fixture did not rewrite admitted history"
  head=$(git -C "$wt" rev-parse HEAD)
  FM_FAKE_AXI_STATUS="$(run_toon 01ENG fm/engineering ci "$head")
branch_sync:
  state: pipeline_owned"
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  out=$("$STAGE" engineering running --run 01ENG 2>&1); rc=$?
  expect_code 0 "$rc" "same-run normal rebase remains current: $out"
  out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
  expect_code 1 "$rc" "green run without required behavioral evidence refuses"
  assert_contains "$out" 'engineering-evidence' "CI-ready names missing evidence"
  printf 'native tool read observed\n' > "$DATA/engineering/read.log"
  printf 'receiver-test: expected stale source refusal and matching bytes\n' > "$DATA/engineering/test.log"
  jq -n --arg task engineering --arg head "$head" --arg load "$DATA/engineering/read.log" \
    --arg lsha "$(sha256sum < "$DATA/engineering/read.log" | cut -d' ' -f1)" \
    --arg behavior "$DATA/engineering/test.log" --arg bsha "$(sha256sum < "$DATA/engineering/test.log" | cut -d' ' -f1)" \
    '{task:$task,generation:"g1",run:"01ENG",head:$head,results:[{id:"caller",load:{kind:"tool-read",path:$load,sha256:$lsha,source_sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",role:"worker",stage:"test"},behavior:{scope:"composition",path:$behavior,sha256:$bsha,command:"receiver-test",oracle:"literal expected bytes",exit_code:0}}]}' \
    > "$DATA/engineering/engineering-evidence.json"
  cp "$DATA/engineering/engineering-evidence.json" "$DATA/engineering/valid-evidence.json"
  for mutation in '.results=[]' '.results[0].load.kind="self-report"' '.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' '.results[0].behavior.exit_code=9' '.results[0].behavior.scope="component"'; do
    jq "$mutation" "$DATA/engineering/valid-evidence.json" > "$DATA/engineering/engineering-evidence.json"
    out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
    expect_code 1 "$rc" "incomplete/stale/self-reported/failed/wrong-scope evidence must refuse: $mutation"
  done
  cp "$DATA/engineering/valid-evidence.json" "$DATA/engineering/engineering-evidence.json"
  printf 'changed after indexing' >> "$DATA/engineering/test.log"
  out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
  expect_code 1 "$rc" "artifact changes after indexing must refuse"
  printf 'receiver-test: expected stale source refusal and matching bytes\n' > "$DATA/engineering/test.log"
  out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
  expect_code 0 "$rc" "bound independent artifacts allow CI-ready: $out"
  pin=$(meta_get engineering stage_evidence)
  jq '.receipt="refreshed"' "$DATA/engineering/engineering-evidence.json" > "$desc.tmp" && mv "$desc.tmp" "$DATA/engineering/engineering-evidence.json"
  out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
  expect_code 0 "$rc" "repeated CI-ready accepts a new valid evidence index: $out"
  [ "$(meta_get engineering stage_evidence)" != "$pin" ] || fail "CI-ready retained obsolete evidence identity"
  [ "$(meta_get engineering stage_evidence)" = "$(sha256sum < "$DATA/engineering/engineering-evidence.json" | cut -d' ' -f1)" ] || fail "CI-ready did not persist exact evidence bytes"
  local valid_status saved_attempt
  valid_status=$FM_FAKE_AXI_STATUS
  for mutation in foreign-id foreign-branch terminal wrong-head; do
    case "$mutation" in
      foreign-id) FM_FAKE_AXI_STATUS="$(run_toon 01FOREIGN fm/engineering ci "$head")" ;;
      foreign-branch) FM_FAKE_AXI_STATUS="$(run_toon 01ENG fm/foreign ci "$head")" ;;
      terminal) FM_FAKE_AXI_STATUS="$(run_toon 01ENG fm/engineering completed "$head" checks-passed)" ;;
      wrong-head) FM_FAKE_AXI_STATUS="$(run_toon 01ENG fm/engineering ci "$(git -C "$wt" rev-parse HEAD^)")" ;;
    esac
    FM_FAKE_AXI_STATUS="$FM_FAKE_AXI_STATUS
branch_sync:
  state: pipeline_owned"
    out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
    expect_code 1 "$rc" "rebased candidate refuses $mutation attribution: $out"
  done
  FM_FAKE_AXI_STATUS=$valid_status
  saved_attempt=$(obs_get engineering attempt_id)
  printf 'attempt_id=stale-attempt\n' >> "$STATE/engineering.nm-observe"
  out=$("$STAGE" engineering ci-ready --pr https://github.com/o/r/pull/8 2>&1); rc=$?
  expect_code 1 "$rc" "rebased candidate refuses stale attempt"
  printf 'attempt_id=%s\n' "$saved_attempt" >> "$STATE/engineering.nm-observe"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n8\n' > "$STATE/engineering.pr-poll-merge-notified"
  out=$("$STAGE" engineering activated 2>&1); rc=$?
  expect_code 0 "$rc" "landed source can record its existing readback: $out"
  assert_grep 'runtime-pin-adoption-gap' "$STATE/engineering.parent-currentness" "completion lost the actual consumer owner"
  assert_grep 'consumer' "$STATE/engineering.parent-currentness" "completion lost the open consumer obligation"
  FM_FAKE_AXI_STATUS=$(run_toon 01ENG fm/engineering completed "$head" checks-passed)
  printf '{}\n' > "$desc"
  out=$("$STAGE" engineering committed --retry 2>&1); rc=$?
  expect_code 0 "$rc" "new attempt can remove engineering context: $out"
  [ -z "$(meta_get engineering stage_context)" ] || fail "new attempt retained old context"
  [ -z "$(meta_get engineering stage_evidence)" ] || fail "new attempt retained old evidence"
  out=$("$STAGE" engineering show 2>&1); rc=$?
  expect_code 0 "$rc" "new empty context resumes: $out"
  FM_FAKE_AXI_STATUS=$(run_toon 01ENGNEXT fm/engineering reviewing "$head")
  out=$("$STAGE" engineering running --run 01ENGNEXT 2>&1); rc=$?
  expect_code 0 "$rc" "new empty context binds the next run: $out"
  pass "engineering stage: rebase custody, exact evidence refresh, context replacement, and residuals"
}
test_engineering_stage_evidence_and_residuals
