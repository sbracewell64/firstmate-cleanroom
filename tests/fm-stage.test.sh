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
# The task-record readers under test: the shared one every fm-*.sh script uses
# (fm_meta_get) and the record-shape owner the writers publish through
# (fm_meta_duplicate_key), so the cases below read the record the way production
# does instead of asserting against a function that is not even loaded.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# fm_pr_file_mode, the portable mode read the PR boundary itself validates a
# task record with, so a mode assertion here checks the same thing production
# checks rather than a second spelling of it.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

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
  --version)
    case "${FM_FAKE_PREFLIGHT_EFFECT:-}" in
      hold) printf 'needs-decision [key=late-retry]: opened during preflight\n' >> "$FM_STATE_OVERRIDE/engineering.status" ;;
      head) git -C "$FM_FAKE_PREFLIGHT_WT" commit -q --allow-empty -m 'head changed during preflight' ;;
    esac
    printf 'no-mistakes version v%s (0af0be6) 2026-08-31T14:04:25Z\n' "${FM_FAKE_NM_VERSION:-1.61.0}"; exit 0 ;;
  axi)
    shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; exit "${FM_FAKE_STATUS_EXIT:-0}" ;;
      sync) printf '%s\n' "${FM_FAKE_SYNC:-}"; exit "${FM_FAKE_SYNC_RC:-0}" ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}"; exit 0 ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
body=${FM_FAKE_PR_BODY:-}
body64=$(printf '%s' "$body" | base64 | tr -d '\n')
row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "${FM_FAKE_PR_NUMBER:-9}" "${FM_FAKE_PR_STATE:-open}" "${FM_FAKE_PR_MERGED:-false}" \
  "${FM_FAKE_PR_HEAD:-}" "${FM_FAKE_PR_BRANCH:-}" "${FM_FAKE_PR_URL:-https://github.com/o/r/pull/9}" "$body64")
printf 'api_response:\n  body: %s\n  truncated: false\n' "$(printf '%s' "$row" | jq -Rs .)"
SH
chmod +x "$FAKEBIN/gh-axi"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_NM_LOG="$NM_LOG"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
export NM_HOME="$NM_HOME_FAKE"
export FM_NM_OBSERVE_TIMEOUT=5 FM_NM_OBSERVE_BUDGET_SECS=10 FM_CREW_STATE_NM_TIMEOUT=5
export FM_FAKE_AXI_STATUS="" FM_FAKE_NM_VERSION="" FM_FAKE_CI_LOGS="" FM_FAKE_RUNS_LIST=""
export FM_FAKE_PR_NUMBER=9 FM_FAKE_PR_STATE=open FM_FAKE_PR_MERGED=false FM_FAKE_PR_HEAD="" FM_FAKE_PR_BRANCH="" FM_FAKE_PR_URL=https://github.com/o/r/pull/9 FM_FAKE_PR_BODY=""

make_worktree() {  # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m init
  # A deterministic integration branch, because `git init`'s default name varies
  # and the stage owner asks the default branch - not the checked-out HEAD -
  # whether a head landed.
  git -C "$1" branch -M main
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

# land_on_integration <repo> <commit>: move the integration branch of the repo at
# <repo> to <commit>, the way a merge does, without disturbing HEAD. `landed`
# means "reachable from the branch the project integrates onto", so a fixture
# that wants a head to have landed has to actually put it there.
land_on_integration() {  # <repo> <commit>
  if git -C "$1" show-ref --verify --quiet refs/remotes/origin/main; then
    git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    git -C "$1" update-ref refs/remotes/origin/main "$2"
  fi
  git -C "$1" update-ref refs/heads/main "$2"
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
  [ "$(printf '%s\n' $FM_CLASSIFY_STAGE_VERBS | wc -l | tr -d ' ')" = 8 ] || fail "stage vocabulary size changed; update this table"
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
  [ -z "$(meta_get a1 stage_successor_id)" ] || fail "ordinary descendant progress minted a successor transition"
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
  [ -z "$(meta_get a1 stage_successor_id)" ] || fail "equal/descendant CI readiness minted a successor transition"
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
    printf '%s\n' '{"reconcile":{"parent":"a1"},"engineering":{"generation":"legacy-g1","triggers":[],"skills":[],"verification":[]}}' > "$DATA/a1/work-context.json"
    out=$("$STAGE" a1 activated 2>&1)
    assert_contains "$out" "currentness:" "activated reconciles currentness when the child declares a reconcile block"
    assert_present "$STATE/a1.parent-currentness" "the terminal transition writes the currentness receipt through the work-context owner"
    assert_no_grep 'engineering_residual=.*worker-discipline:' "$STATE/a1.parent-currentness" \
      "legacy engineering context without discipline has no discipline residuals"
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
  for f in fm-wake-lib.sh fm-backend.sh fm-pr-lib.sh fm-tangle-lib.sh fm-tasks-axi-lib.sh fm-backlog-transition-lib.sh fm-work-context-lib.sh fm-work-context-engineering-lib.sh fm-work-context-discipline-lib.sh fm-classify-lib.sh fm-timeout-lib.sh fm-nm-run-lib.sh fm-crew-state.sh fm-tmux-lib.sh fm-busy-lib.sh fm-tool-profile.sh fm-workflow-yaml.sh fm-lint.sh fm-lint-workflows.sh fm-bootstrap.sh; do
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
  local saved_context saved_meta saved_observer saved_status retry_case
  saved_context=$(cat "$desc")
  saved_meta=$(cat "$STATE/engineering.meta")
  saved_observer=$(cat "$STATE/engineering.nm-observe")
  saved_status=$(cat "$STATE/engineering.status")
  for retry_case in changed removed; do
    if [ "$retry_case" = changed ]; then
      printf '%s' "$saved_context" | jq '.engineering.generation="replacement"' > "$desc"
    else
      printf '{}\n' > "$desc"
    fi
    printf 'needs-decision [key=retry-hold]: wait\n' >> "$STATE/engineering.status"
    out=$("$STAGE" engineering committed --retry 2>&1); rc=$?
    expect_code 1 "$rc" "active run with $retry_case context and hold refuses retry: $out"
    [ "$(cat "$STATE/engineering.meta")" = "$saved_meta" ] || fail "held retry replaced stage bindings"
    [ "$(cat "$STATE/engineering.nm-observe")" = "$saved_observer" ] || fail "held retry replaced run custody"
    printf '%s\n' "$saved_status" > "$STATE/engineering.status"
    out=$("$STAGE" engineering committed --retry 2>&1); rc=$?
    expect_code 1 "$rc" "active run with $retry_case context refuses retry without hold: $out"
    [ "$(cat "$STATE/engineering.meta")" = "$saved_meta" ] || fail "refused retry replaced stage bindings"
    [ "$(cat "$STATE/engineering.nm-observe")" = "$saved_observer" ] || fail "refused retry replaced run custody"
  done
  local active_status
  active_status=$FM_FAKE_AXI_STATUS
  FM_FAKE_AXI_STATUS=$(run_toon 01ENG fm/engineering completed "$head" checks-passed)
  printf 'needs-decision [key=retry-hold]: wait\n' >> "$STATE/engineering.status"
  out=$("$STAGE" engineering committed --retry 2>&1); rc=$?
  expect_code 1 "$rc" "released run with open hold preserves the previous attempt: $out"
  [ "$(cat "$STATE/engineering.meta")" = "$saved_meta" ] || fail "released held retry replaced bindings"
  printf '%s\n' "$saved_status" > "$STATE/engineering.status"
  FM_FAKE_NM_VERSION=1.0.0
  out=$("$STAGE" engineering committed --retry 2>&1); rc=$?
  FM_FAKE_NM_VERSION=
  expect_code 1 "$rc" "unqualified retry preserves the previous attempt: $out"
  [ "$(cat "$STATE/engineering.meta")" = "$saved_meta" ] || fail "preflight refusal replaced stage bindings"
  [ "$(cat "$STATE/engineering.nm-observe")" = "$saved_observer" ] || fail "preflight refusal replaced observer bindings"
  local late_case
  for late_case in hold head; do
    out=$(FM_FAKE_PREFLIGHT_EFFECT="$late_case" FM_FAKE_PREFLIGHT_WT="$wt" "$STAGE" engineering committed --retry 2>&1); rc=$?
    expect_code 1 "$rc" "late $late_case refuses released retry: $out"
    case "$late_case" in
      hold)
        assert_contains "$out" 'HOLD_APPEARED' "late hold was not checked at admission"
        assert_grep 'late-retry' "$STATE/engineering.status" "preflight did not inject the late hold" ;;
      head)
        assert_contains "$out" 'STALE_CANDIDATE' "late head was not checked at admission"
        [ "$(git -C "$wt" rev-parse HEAD)" != "$head" ] || fail "preflight did not move the candidate" ;;
    esac
    [ "$(cat "$STATE/engineering.meta")" = "$saved_meta" ] || fail "late refusal changed stage bindings"
    [ "$(cat "$STATE/engineering.nm-observe")" = "$saved_observer" ] || fail "late refusal changed observer bindings"
    printf '%s\n' "$saved_status" > "$STATE/engineering.status"
    git -C "$wt" reset -q --hard "$head"
  done
  printf '%s\n' "$saved_context" > "$desc"
  FM_FAKE_AXI_STATUS=$active_status
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
  [ "$(meta_get engineering stage_attempt)" = "$(obs_get engineering attempt_id)" ] || fail "successful retry published different attempts"
  [ "$(meta_get engineering stage_run)" = "$(obs_get engineering run_id)" ] || fail "successful retry published different run bindings"
  [ "$(obs_get engineering run_id)" = '' ] || fail "successful retry retained the predecessor run"
  out=$("$STAGE" engineering show 2>&1); rc=$?
  expect_code 0 "$rc" "new empty context resumes: $out"
  FM_FAKE_AXI_STATUS=$(run_toon 01ENGNEXT fm/engineering reviewing "$head")
  out=$("$STAGE" engineering running --run 01ENGNEXT 2>&1); rc=$?
  expect_code 0 "$rc" "new empty context binds the next run: $out"
  pass "engineering stage: rebase custody, exact evidence refresh, context replacement, and residuals"
}
test_engineering_stage_evidence_and_residuals

# Typed worker discipline is part of the same admitted engineering identity.
# Candidate proof is integrity-checked at CI-ready but never substitutes for the
# canonical run verdict, and an honest CNO stays labeled CNO in the receipt.
test_discipline_stage_identity_evidence_and_retry() {
  local wt head desc outer_generation generation fragment artifact out rc pin
  wt="$TMP_ROOT/wt-discipline"
  make_worktree "$wt" fm/discipline-stage
  head=$(git -C "$wt" rev-parse HEAD)
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" discipline-stage repo --mode no-mistakes \
    --discipline-fact schema --discipline-fact real-runtime-surface --proof-kind accepted-surface --proof-surface 'bin/example --status' >/dev/null \
    || fail "discipline stage fixture did not compile"
  make_task discipline-stage no-mistakes "$wt"
  desc="$DATA/discipline-stage/work-context.json"
  outer_generation=$(jq -r .engineering.generation "$desc")
  generation=$(jq -r .engineering.discipline.generation "$desc")
  fragment=$(jq -r .engineering.discipline.fragment_sha256 "$desc")

  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" discipline-stage committed 2>&1); rc=$?
  expect_code 0 "$rc" "discipline candidate did not admit: $out"
  pin=$(meta_get discipline-stage stage_context)
  [ -n "$pin" ] || fail "discipline attempt did not bind work-context identity"
  assert_contains "$(last_line discipline-stage)" "discipline=proof-surface@$generation@$fragment" \
    "stage receipt lost selected discipline identity"

  FM_FAKE_AXI_STATUS=$(run_toon 01DISCIPLINE fm/discipline-stage reviewing "$head")
  out=$("$STAGE" discipline-stage running --run 01DISCIPLINE 2>&1); rc=$?
  expect_code 0 "$rc" "discipline run did not bind: $out"
  FM_FAKE_AXI_STATUS="$(run_toon 01DISCIPLINE fm/discipline-stage ci "$head")
branch_sync:
  state: pipeline_owned"
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  out=$("$STAGE" discipline-stage ci-ready --pr https://github.com/o/r/pull/18 2>&1); rc=$?
  expect_code 1 "$rc" "CI-ready accepted worker narration without bound discipline evidence"
  assert_contains "$out" 'discipline-evidence' "missing candidate evidence refusal was not typed"

  artifact="$DATA/discipline-stage/proof.txt"
  printf 'CNO: runtime unavailable; schema safety fact remained unobserved\n' > "$artifact"
  jq -n --arg task discipline-stage --arg run 01DISCIPLINE --arg head "$head" \
    --arg outer_generation "$outer_generation" --arg discipline_generation "$generation" \
    --arg fragment "$fragment" --arg path "$artifact" \
    --arg sha "$(sha256sum < "$artifact" | cut -d' ' -f1)" \
    '{task:$task,generation:$outer_generation,run:$run,head:$head,results:[{id:"worker-discipline",discipline:{task:$task,role:"ship",stage:"implementation",generation:$discipline_generation,level:"proof-surface",fragment_sha256:$fragment,producer:"worker-candidate",outcome:"CNO",surface:"bin/example --status",command:"bin/example --status",oracle:"expected status response",path:$path,sha256:$sha,safety_facts:["schema reader rejects unknown state"]}}]}' \
    > "$DATA/discipline-stage/engineering-evidence.json"
  out=$("$STAGE" discipline-stage ci-ready --pr https://github.com/o/r/pull/18 2>&1); rc=$?
  expect_code 0 "$rc" "bound CNO evidence should reach the independent validator: $out"
  assert_contains "$(last_line discipline-stage)" 'discipline_proof=CNO' "CNO was rounded to PASS in the stage receipt"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n18\n' > "$STATE/discipline-stage.pr-poll-merge-notified"
  out=$("$STAGE" discipline-stage activated 2>&1); rc=$?
  expect_code 0 "$rc" "discipline source landing read-back failed: $out"
  assert_grep '"claim":"ACTIVE","evidence":"CNO"' "$STATE/discipline-stage.parent-currentness" \
    "source landing claimed runtime activation"
  assert_grep '"claim":"CONSUMED","evidence":"CNO"' "$STATE/discipline-stage.parent-currentness" \
    "source landing claimed fresh production consumption"
  assert_grep '"owner":"runtime-pin-adoption-gap"' "$STATE/discipline-stage.parent-currentness" \
    "runtime CNO residuals lost their qualified adoption owner"
  assert_grep "engineering_discipline=proof-surface@$generation@$fragment" \
    "$STATE/discipline-stage.parent-currentness" "landing receipt lost the selected discipline identity"

  cp "$STATE/discipline-stage.meta" "$STATE/discipline-stage.meta.valid"
  awk '{ if ($0 ~ /^stage_tree=/) print "stage_tree=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; else print }' \
    "$STATE/discipline-stage.meta.valid" > "$STATE/discipline-stage.meta"
  out=$("$STAGE" discipline-stage show 2>&1); rc=$?
  expect_code 1 "$rc" "wrong discipline candidate tree must refuse resume"
  assert_contains "$out" 'DISCIPLINE_IDENTITY' "wrong tree refusal was not typed"
  mv "$STATE/discipline-stage.meta.valid" "$STATE/discipline-stage.meta"

  git -C "$wt" commit -q --allow-empty -m 'unverified same-branch successor'
  out=$($STAGE discipline-stage show 2>&1); rc=$?
  expect_code 1 "$rc" "same-branch descendant must refuse resume"
  assert_contains "$out" 'DISCIPLINE_IDENTITY' "same-branch descendant refusal was not typed"
  git -C "$wt" reset -q --hard "$head"
  git -C "$wt" checkout -q --detach "$head"
  out=$($STAGE discipline-stage show 2>&1); rc=$?
  expect_code 1 "$rc" "detached task worktree must refuse resume"
  assert_contains "$out" 'DISCIPLINE_IDENTITY' "detached worktree refusal was not typed"
  git -C "$wt" checkout -q fm/discipline-stage

  jq '.engineering.discipline.generation="changed"' "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"
  out=$("$STAGE" discipline-stage show 2>&1); rc=$?
  expect_code 1 "$rc" "changed discipline identity must refuse resume"
  assert_contains "$out" 'ENGINEERING_CONTEXT' "changed discipline identity refusal did not name context"
  [ "$(meta_get discipline-stage stage_context)" = "$pin" ] || fail "refused resume rewrote admitted identity"
  jq --arg generation "$generation" '.engineering.discipline.generation=$generation' "$desc" > "$desc.tmp" && mv "$desc.tmp" "$desc"

  FM_FAKE_AXI_STATUS=$(run_toon 01DISCIPLINE fm/discipline-stage completed "$head" checks-passed)
  mkdir -p "$TMP_ROOT/alternate-discipline/data" "$TMP_ROOT/alternate-discipline/state"
  FM_HOME="$TMP_ROOT/alternate-discipline" FM_DATA_OVERRIDE="$TMP_ROOT/alternate-discipline/data" \
    FM_STATE_OVERRIDE="$TMP_ROOT/alternate-discipline/state" \
    "$ROOT/bin/fm-brief.sh" discipline-stage repo --mode no-mistakes \
    --discipline-fact local >/dev/null || fail "alternate discipline fixture did not compile"
  cp "$desc" "$desc.valid"
  jq --slurpfile alternate "$TMP_ROOT/alternate-discipline/data/discipline-stage/work-context.json" \
    --arg outer_generation "$outer_generation" \
    '.engineering.discipline=$alternate[0].engineering.discipline |
     .engineering.discipline.outer_generation=$outer_generation' "$desc.valid" > "$desc"
  out=$("$STAGE" discipline-stage committed --retry 2>&1); rc=$?
  expect_code 1 "$rc" "worker-selected discipline change must refuse retry"
  assert_contains "$out" 'discipline-identity' "retry self-upgrade refusal was not typed"
  mv "$desc.valid" "$desc"
  out=$("$STAGE" discipline-stage committed --retry 2>&1); rc=$?
  expect_code 0 "$rc" "retry with unchanged discipline identity did not admit: $out"
  [ "$(meta_get discipline-stage stage_context)" = "$pin" ] || fail "retry changed the selected discipline identity"
  [ -z "$(meta_get discipline-stage stage_evidence)" ] || fail "retry retained predecessor candidate evidence"
  pass "discipline stage: context survives resume/retry, exact CNO evidence is consumed, and self-proof never bypasses qualification"
}
test_discipline_stage_identity_evidence_and_retry


test_isolated_pipeline_successor() {
  local wt lane admitted head out rc valid_status mutation saved_attempt before
  wt="$TMP_ROOT/wt-isolated"
  lane="$TMP_ROOT/pipeline-isolated"
  make_worktree "$wt" fm/isolated
  admitted=$(git -C "$wt" rev-parse HEAD)
  make_task isolated no-mistakes "$wt"
  cp "$DATA/engineering/valid-evidence.json" "$DATA/isolated/engineering-evidence.json"
  jq -n --arg path "$DATA/engineering/skill.md" '{engineering:{generation:"g1",triggers:["test-change"],skills:[{id:"tdd",path:$path,release:"r1",sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",role:"worker",stage:"test",trigger:"test-change"}],verification:[{id:"caller",skill:"tdd",scope:"composition",public_seam:"fm-brief",inputs:"declared source",environment:"controlled and inherited",oracle:"literal expected bytes",allowed_effects:"scratch only",source_identity:"r1",caller_identity:"fixture",command:"receiver-test",negative:"stale source refuses",owner:"crewmate-boundary-repair",next_gate:"ci-ready"}]}}' > "$DATA/isolated/work-context.json"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" isolated committed 2>&1); rc=$?
  expect_code 0 "$rc" "isolated candidate admits: $out"
  FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated reviewing "$admitted")
  out=$("$STAGE" isolated running --run 01ISOLATED 2>&1); rc=$?
  expect_code 0 "$rc" "isolated candidate binds: $out"
  git clone -q --no-local "$wt" "$lane" || fail "isolated pipeline clone failed"
  git -C "$lane" checkout -q -b current-main HEAD^
  printf 'pipeline base advance\n' > "$lane/main.txt"
  git -C "$lane" add main.txt
  git -C "$lane" commit -q -m 'advance pipeline base'
  git -C "$lane" checkout -q fm/isolated
  git -C "$lane" rebase current-main >/dev/null 2>&1 || fail "isolated pipeline rebase failed"
  head=$(git -C "$lane" rev-parse HEAD)
  git -C "$lane" merge-base --is-ancestor "$admitted" "$head" && fail "pipeline history was not rewritten"
  git -C "$wt" cat-file -e "$head" 2>/dev/null && fail "successor unexpectedly exists in worker object store"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$admitted" ] || fail "worker moved from admitted candidate"
  jq --arg head "$head" '.task="isolated" | .run="01ISOLATED" | .head=$head' "$DATA/isolated/engineering-evidence.json" > "$DATA/isolated/index.tmp"
  mv "$DATA/isolated/index.tmp" "$DATA/isolated/engineering-evidence.json"
  valid_status="$(run_toon 01ISOLATED fm/isolated ci "$head")
branch_sync:
  state: pipeline_owned"
  FM_FAKE_AXI_STATUS=$valid_status
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  out=$("$STAGE" isolated ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "isolated successor evidence admits without a worker-local object: $out"
  before=$(meta_get isolated stage_evidence)
  for mutation in foreign-id foreign-branch stale-run wrong-head short-head malformed-head missing-head terminal released failed-read; do
    case "$mutation" in
      foreign-id|stale-run) FM_FAKE_AXI_STATUS=$(run_toon 01OTHER fm/isolated ci "$head") ;;
      foreign-branch) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/foreign ci "$head") ;;
      wrong-head) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated ci "$admitted") ;;
      short-head) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated ci "${head:0:8}") ;;
      malformed-head) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated ci HEAD) ;;
      missing-head) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated ci '') ;;
      terminal) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated completed "$head" checks-passed) ;;
      released|failed-read) FM_FAKE_AXI_STATUS=$(run_toon 01ISOLATED fm/isolated ci "$head") ;;
    esac
    if [ "$mutation" != released ]; then
      FM_FAKE_AXI_STATUS="$FM_FAKE_AXI_STATUS
branch_sync:
  state: pipeline_owned"
    fi
    export FM_FAKE_STATUS_EXIT=0
    [ "$mutation" != failed-read ] || FM_FAKE_STATUS_EXIT=1
    out=$("$STAGE" isolated ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
    expect_code 1 "$rc" "isolated successor refuses $mutation: $out"
    [ "$(meta_get isolated stage_evidence)" = "$before" ] || fail "refusal changed evidence binding"
  done
  FM_FAKE_STATUS_EXIT=0
  FM_FAKE_AXI_STATUS=$valid_status
  saved_attempt=$(obs_get isolated attempt_id)
  printf 'attempt_id=stale\n' >> "$STATE/isolated.nm-observe"
  out=$("$STAGE" isolated ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 1 "$rc" "isolated successor refuses stale attempt: $out"
  printf 'attempt_id=%s\n' "$saved_attempt" >> "$STATE/isolated.nm-observe"
  out=$("$STAGE" isolated ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "valid isolated successor remains admissible: $out"
  git -C "$wt" cat-file -e "$head" 2>/dev/null && fail "admission imported the pipeline successor"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$admitted" ] || fail "admission moved the worker"
  pass "isolated pipeline rebase admits exact current-run evidence without local objects and refuses invalid attribution"
}
test_isolated_pipeline_successor

# PR #69 regression: a pipeline rebase rewrites ancestry, then the run reaches
# exact synchronized local/remote/current/pushed equality while it remains in
# the CI monitoring state. The stage owner must advance through one typed
# successor receipt instead of requiring the admitted head to be an ancestor.
test_synchronized_rebased_successor_transition() {
  local wt submitted head tree out rc proof attempt receipt before saved_meta saved_obs saved_status mutation case_meta case_obs case_status
  local base foreign_parent foreign_head submitted_patch foreign_patch incident_run incident_branch incident_pr
  # Immutable incident bindings: submitted 2677ca88605e3ae4ff4c8706a2992008c2694476,
  # pipeline-rebased 9f63fdec964c98e8c0088186686d0c43c86bb54c,
  # qualified 54ec4e800485455744c6b926c75277aee4c49aa3, and qualified tree
  # 6b4b2592aa213accaa20c7cd02fb6a5baa8cfda1. The isolated repository below
  # realizes the same non-ancestor relation while the externally bound run,
  # branch, and PR retain their captured identities.
  incident_run=01M2YV2NQ7WTPK1MFZ302PAKMH
  incident_branch=fm/watcher-lock-trap-packet-bound-successor
  incident_pr=https://github.com/sbracewell64/firstmate-cleanroom/pull/69
  wt="$TMP_ROOT/wt-synchronized-successor"
  make_worktree "$wt" "$incident_branch"
  submitted=$(git -C "$wt" rev-parse HEAD)
  make_task synchronized-successor no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" synchronized-successor committed 2>&1); rc=$?
  expect_code 0 "$rc" "synchronized successor fixture admission: $out"
  FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" "$incident_branch" reviewing "$submitted")
  out=$("$STAGE" synchronized-successor running --run "$incident_run" 2>&1); rc=$?
  expect_code 0 "$rc" "synchronized successor fixture binding: $out"
  attempt=$(obs_get synchronized-successor attempt_id)
  git -C "$wt" checkout -q -b synchronized-main HEAD^
  printf 'upstream\n' > "$wt/upstream.txt"
  git -C "$wt" add upstream.txt
  git -C "$wt" commit -q -m upstream
  git -C "$wt" checkout -q "$incident_branch"
  git -C "$wt" rebase synchronized-main >/dev/null 2>&1 || fail 'synchronized successor fixture rebase'
  git -C "$wt" commit -q --allow-empty -m 'pipeline fix'
  head=$(git -C "$wt" rev-parse HEAD)
  tree=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  git -C "$wt" merge-base --is-ancestor "$submitted" "$head" && fail 'fixture did not rewrite ancestry'
  base=$(git -C "$wt" rev-parse "$submitted^")
  foreign_parent=$(printf 'foreign parent\n' | git -C "$wt" commit-tree "$(git -C "$wt" rev-parse "$base^{tree}")" -p "$base")
  foreign_head=$(printf 'patch-equivalent foreign candidate\n' | git -C "$wt" commit-tree "$(git -C "$wt" rev-parse "$submitted^{tree}")" -p "$foreign_parent")
  submitted_patch=$(git -C "$wt" show --pretty=format: "$submitted" | git patch-id --stable | awk '{print $1}')
  foreign_patch=$(git -C "$wt" show --pretty=format: "$foreign_head" | git patch-id --stable | awk '{print $1}')
  [ -n "$submitted_patch" ] && [ "$submitted_patch" = "$foreign_patch" ] || fail 'foreign-history negative control is not patch-equivalent'
  git -C "$wt" merge-base --is-ancestor "$submitted" "$foreign_head" && fail 'foreign-history negative control descends from the admitted candidate'
  FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" "$incident_branch" ci "$head" '' "$incident_pr")
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  proof="branch_sync:
  state: synchronized
  changed: false
  local:
    branch: $incident_branch
    head: $head
    clean: true
  pipeline:
    run: $incident_run
    status: running
    phase:
    submitted_head: $submitted
    current_head: $head
    pushed_head: $head
    pushed_at: 1
    push_generation: 2
  target:
    kind: upstream
    remote: origin
    url: https://github.com/sbracewell64/firstmate-cleanroom.git
    ref: refs/heads/$incident_branch
  remote:
    observed_head: $head
    freshness: live
    observed_at: 2
  relation: equal
  safety: already_synchronized
  pr_state: open
  successor:
    verified: false"
  FM_FAKE_SYNC=$proof FM_FAKE_SYNC_RC=0
  FM_FAKE_PR_NUMBER=69 FM_FAKE_PR_HEAD=$head FM_FAKE_PR_BRANCH=$incident_branch FM_FAKE_PR_URL=$incident_pr
  FM_FAKE_PR_BODY=$(printf 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s"} -->' "$head")
  export FM_FAKE_SYNC FM_FAKE_SYNC_RC FM_FAKE_AXI_STATUS FM_FAKE_CI_LOGS FM_FAKE_PR_HEAD FM_FAKE_PR_BRANCH FM_FAKE_PR_URL FM_FAKE_PR_BODY
  saved_meta=$(cat "$STATE/synchronized-successor.meta")
  saved_obs=$(cat "$STATE/synchronized-successor.nm-observe")
  saved_status=$(cat "$STATE/synchronized-successor.status")
  for mutation in wrong-run wrong-branch wrong-status-head wrong-attempt wrong-duty wrong-allocation predecessor-mutation local-disagreement remote-moved pipeline-disagreement dirty-worktree missing-qualification red-qualification missing-attestation wrong-pr-head closed-pr merged-pr branch-name-only pr-only narration-only green-only patch-equivalent-foreign stale-expected-head; do
    printf '%s\n' "$saved_meta" > "$STATE/synchronized-successor.meta"
    printf '%s\n' "$saved_obs" > "$STATE/synchronized-successor.nm-observe"
    printf '%s\n' "$saved_status" > "$STATE/synchronized-successor.status"
    FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" "$incident_branch" ci "$head" '' "$incident_pr")
    FM_FAKE_SYNC=$proof
    FM_FAKE_SYNC_RC=0
    FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
    FM_FAKE_PR_STATE=open
    FM_FAKE_PR_MERGED=false
    FM_FAKE_PR_HEAD=$head
    FM_FAKE_PR_BODY=$(printf 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s"} -->' "$head")
    case "$mutation" in
      wrong-run) FM_FAKE_AXI_STATUS=$(run_toon 01FOREIGN "$incident_branch" ci "$head" '' "$incident_pr") ;;
      wrong-branch) FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" fm/foreign ci "$head" '' "$incident_pr") ;;
      wrong-status-head) FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" "$incident_branch" ci "$submitted" '' "$incident_pr") ;;
      wrong-attempt) sed 's/^attempt_id=.*/attempt_id=foreign/' "$STATE/synchronized-successor.nm-observe" > "$STATE/.obs" && mv "$STATE/.obs" "$STATE/synchronized-successor.nm-observe" ;;
      wrong-duty) sed 's/^stage_duty=.*/stage_duty=publication/' "$STATE/synchronized-successor.meta" > "$STATE/.meta" && mv "$STATE/.meta" "$STATE/synchronized-successor.meta" ;;
      wrong-allocation) sed 's/^model=.*/model=foreign/' "$STATE/synchronized-successor.meta" > "$STATE/.meta" && mv "$STATE/.meta" "$STATE/synchronized-successor.meta" ;;
      predecessor-mutation) printf 'stage_predecessor_head=%s\n' "$foreign_head" >> "$STATE/synchronized-successor.meta" ;;
      local-disagreement) FM_FAKE_SYNC=${proof/    head: $head/    head: $submitted} ;;
      remote-moved) FM_FAKE_SYNC=${proof/    observed_head: $head/    observed_head: $submitted} ;;
      pipeline-disagreement) FM_FAKE_SYNC=${proof/    current_head: $head/    current_head: $submitted} ;;
      dirty-worktree) printf 'dirty\n' > "$wt/dirty.txt" ;;
      missing-qualification) FM_FAKE_CI_LOGS='' ;;
      red-qualification) FM_FAKE_CI_LOGS='hosted checks failed' ;;
      missing-attestation) FM_FAKE_PR_BODY='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)' ;;
      wrong-pr-head) FM_FAKE_PR_HEAD=$submitted ;;
      closed-pr) FM_FAKE_PR_STATE=closed ;;
      merged-pr) FM_FAKE_PR_MERGED=true ;;
      branch-name-only) FM_FAKE_SYNC=$(printf 'branch_sync:\n  state: synchronized\n  local:\n    branch: %s\n    head: %s\n    clean: true\n' "$incident_branch" "$head") ;;
      pr-only) FM_FAKE_SYNC='' ;;
      narration-only) FM_FAKE_CI_LOGS=''; printf 'done: PR %s checks green\n' "$incident_pr" >> "$STATE/synchronized-successor.status" ;;
      green-only) FM_FAKE_SYNC='' ;;
      patch-equivalent-foreign) git -C "$wt" reset -q --hard "$foreign_head" ;;
      stale-expected-head) git -C "$wt" commit -q --allow-empty -m 'moved after proof' ;;
    esac
    export FM_FAKE_AXI_STATUS FM_FAKE_SYNC FM_FAKE_SYNC_RC FM_FAKE_CI_LOGS FM_FAKE_PR_STATE FM_FAKE_PR_MERGED FM_FAKE_PR_HEAD FM_FAKE_PR_BODY
    case_meta=$(cat "$STATE/synchronized-successor.meta")
    case_obs=$(cat "$STATE/synchronized-successor.nm-observe")
    case_status=$(cat "$STATE/synchronized-successor.status")
    out=$("$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
    expect_code 1 "$rc" "synchronized successor must refuse $mutation: $out"
    case "$mutation" in
      branch-name-only|pr-only|green-only) assert_contains "$out" 'SUCCESSOR_CNO' "$mutation was not typed as unevaluable identity" ;;
      *) assert_contains "$out" 'SUCCESSOR_CONTRADICTION' "$mutation was not typed as contradictory identity" ;;
    esac
    [ "$(cat "$STATE/synchronized-successor.meta")" = "$case_meta" ] || fail "$mutation mutated stage authority"
    [ "$(cat "$STATE/synchronized-successor.nm-observe")" = "$case_obs" ] || fail "$mutation mutated observer authority"
    [ "$(cat "$STATE/synchronized-successor.status")" = "$case_status" ] || fail "$mutation appended a stage receipt"
    rm -f "$wt/dirty.txt"
    git -C "$wt" reset -q --hard "$head"
  done
  printf '%s\n' "$saved_meta" > "$STATE/synchronized-successor.meta"
  printf '%s\n' "$saved_obs" > "$STATE/synchronized-successor.nm-observe"
  printf '%s\n' "$saved_status" > "$STATE/synchronized-successor.status"
  FM_FAKE_AXI_STATUS=$(run_toon "$incident_run" "$incident_branch" ci "$head" '' "$incident_pr")
  FM_FAKE_SYNC=$proof
  FM_FAKE_CI_LOGS='all CI checks passed - still monitoring until merged or closed'
  FM_FAKE_PR_HEAD=$head
  FM_FAKE_PR_BODY=$(printf 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s"} -->' "$head")
  export FM_FAKE_AXI_STATUS FM_FAKE_SYNC FM_FAKE_CI_LOGS FM_FAKE_PR_HEAD FM_FAKE_PR_BODY
  out=$(FM_STAGE_TEST_INTERRUPT_AFTER_SUCCESSOR_PUBLISH=1 "$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
  expect_code 86 "$rc" "interrupted successor transition must stop after atomic publication: $out"
  [ "$(meta_get synchronized-successor stage)" = candidate-successor ] || fail 'interrupted transition did not atomically publish its typed result'
  [ "$(grep -c '^candidate-successor:' "$STATE/synchronized-successor.status" || true)" = 0 ] || fail 'interrupted transition exposed a partial status receipt'
  FM_FAKE_SYNC_RC=1 FM_FAKE_PR_STATE=closed
  export FM_FAKE_SYNC_RC FM_FAKE_PR_STATE
  out=$("$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
  expect_code 0 "$rc" "an atomically published successor must replay without borrowing mutable forge or synchronization evidence: $out"
  FM_FAKE_SYNC_RC=0 FM_FAKE_PR_STATE=open
  export FM_FAKE_SYNC_RC FM_FAKE_PR_STATE
  assert_contains "$out" 'candidate-successor:' 'typed successor transition was not replayed'
  assert_contains "$out" 'STAGE: ci-ready:' 'CI-ready was not issued after successor transition'
  [ "$(meta_get synchronized-successor stage_head)" = "$head" ] || fail 'current stage head did not advance through the owner'
  [ "$(meta_get synchronized-successor stage_tree)" = "$tree" ] || fail 'current stage tree did not advance through the owner'
  [ "$(meta_get synchronized-successor stage_predecessor_head)" = "$submitted" ] || fail 'predecessor head was not preserved'
  [ "$(meta_get synchronized-successor stage_predecessor_attempt)" = "$attempt" ] || fail 'predecessor attempt was not preserved'
  [ "$(meta_get synchronized-successor stage_predecessor_run)" = "$incident_run" ] || fail 'predecessor run was not preserved'
  [ "$(meta_get synchronized-successor stage_predecessor_tree)" = "$(git -C "$wt" rev-parse "$submitted^{tree}")" ] || fail 'predecessor tree was not preserved'
  [ "$(meta_get synchronized-successor stage_predecessor_duty)" = validation ] || fail 'predecessor duty was not preserved'
  [ "$(meta_get synchronized-successor stage_successor_branch)" = "$incident_branch" ] || fail 'successor branch was not bound'
  [ "$(meta_get synchronized-successor stage_successor_attempt)" = "$attempt" ] || fail 'successor current attempt was not bound'
  [ "$(meta_get synchronized-successor stage_successor_run)" = "$incident_run" ] || fail 'successor current run was not bound'
  [ "$(meta_get synchronized-successor stage_successor_authority)" = fm-stage/no-mistakes-bound-run ] || fail 'successor authority was not bound'
  [ "$(meta_get synchronized-successor stage_successor_action)" = authenticated-synchronized-successor ] || fail 'successor action was not bound'
  [ "$(meta_get synchronized-successor stage_successor_attested_head)" = "$head" ] || fail 'attested head was not bound'
  [ "$(meta_get synchronized-successor stage_successor_checked_head)" = "$head" ] || fail 'checked head was not bound'
  [ "$(meta_get synchronized-successor stage_successor_pipeline_submitted_head)" = "$submitted" ] || fail 'pipeline submitted head was not bound'
  [ "$(meta_get synchronized-successor stage_successor_pipeline_current_head)" = "$head" ] || fail 'pipeline current head was not bound'
  [ "$(meta_get synchronized-successor stage_successor_pipeline_pushed_head)" = "$head" ] || fail 'pipeline pushed head was not bound'
  [ "$(meta_get synchronized-successor stage_successor_local_head)" = "$head" ] || fail 'local equality was not bound'
  [ "$(meta_get synchronized-successor stage_successor_remote_head)" = "$head" ] || fail 'remote equality was not bound'
  [ "$(meta_get synchronized-successor stage_successor_push_generation)" = 2 ] || fail 'push generation was not bound'
  [[ "$(meta_get synchronized-successor stage_successor_input_sha)" =~ ^[0-9a-f]{64}$ ]] || fail 'input-to-outcome identity is malformed'
  receipt=$(grep '^candidate-successor:' "$STATE/synchronized-successor.status")
  [ "$(printf '%s\n' "$receipt" | wc -l | tr -d ' ')" = 1 ] || fail 'successor transition did not emit exactly one receipt'
  before=$(cat "$STATE/synchronized-successor.meta")
  out=$("$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
  expect_code 0 "$rc" "successor replay must be idempotent: $out"
  [ "$(cat "$STATE/synchronized-successor.meta")" = "$before" ] || fail 'successor replay mutated the authoritative record'
  [ "$(grep -c '^candidate-successor:' "$STATE/synchronized-successor.status")" = 1 ] || fail 'successor replay duplicated its receipt'
  cp "$STATE/synchronized-successor.meta" "$STATE/synchronized-successor.meta.valid"
  sed "s/^stage_predecessor_head=.*/stage_predecessor_head=$foreign_head/" "$STATE/synchronized-successor.meta.valid" > "$STATE/synchronized-successor.meta"
  out=$("$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
  expect_code 1 "$rc" "a mutated immutable predecessor must refuse replay: $out"
  assert_contains "$out" 'SUCCESSOR_COLLISION' 'mutated predecessor refusal was not typed'
  mv "$STATE/synchronized-successor.meta.valid" "$STATE/synchronized-successor.meta"
  before=$(cat "$STATE/synchronized-successor.meta")
  git -C "$wt" commit -q --allow-empty -m 'second distinct successor'
  out=$("$STAGE" synchronized-successor ci-ready --pr "$incident_pr" 2>&1); rc=$?
  expect_code 1 "$rc" "a second distinct synchronized successor must refuse: $out"
  assert_contains "$out" 'SUCCESSOR_COLLISION' 'second distinct successor refusal was not typed'
  [ "$(cat "$STATE/synchronized-successor.meta")" = "$before" ] || fail 'second distinct successor rewrote immutable lineage'
  git -C "$wt" reset -q --hard "$head"
  FM_FAKE_SYNC='' FM_FAKE_CI_LOGS='' FM_FAKE_PR_NUMBER=9 FM_FAKE_PR_HEAD='' FM_FAKE_PR_BRANCH='' FM_FAKE_PR_URL=https://github.com/o/r/pull/9 FM_FAKE_PR_BODY=''
  export FM_FAKE_SYNC FM_FAKE_CI_LOGS FM_FAKE_PR_NUMBER FM_FAKE_PR_HEAD FM_FAKE_PR_BRANCH FM_FAKE_PR_URL FM_FAKE_PR_BODY
  pass 'synchronized rebased same-run successor advances atomically with predecessor lineage and exact PR qualification'
}
test_synchronized_rebased_successor_transition

# A published terminal validation branch is not reused. The explicit successor
# command owns the deterministic branch name and its crash journal; admission
# remains a later committed --retry transition.
test_terminal_branch_requires_one_minted_successor() {
  local wt head out rc before terminal_outcome
  wt="$TMP_ROOT/wt-terminal-branch"
  make_worktree "$wt" fm/terminal-branch
  head=$(git -C "$wt" rev-parse HEAD)
  make_task terminal-branch no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=''
  out=$("$STAGE" terminal-branch committed 2>&1); rc=$?
  expect_code 0 "$rc" "terminal branch fixture admission: $out"
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINALBRANCH fm/terminal-branch reviewing "$head")
  out=$("$STAGE" terminal-branch running --run 01TERMINALBRANCH 2>&1); rc=$?
  expect_code 0 "$rc" "terminal branch fixture binding: $out"
  before=$(cat "$STATE/terminal-branch.meta")
  for terminal_outcome in passed cancelled; do
    FM_FAKE_AXI_STATUS=$(run_toon 01TERMINALBRANCH fm/terminal-branch completed "$head" "$terminal_outcome" https://github.com/o/r/pull/9)
    out=$("$STAGE" terminal-branch committed --retry 2>&1); rc=$?
    expect_code 1 "$rc" "terminal published branch ($terminal_outcome) must require a successor: $out"
    assert_contains "$out" 'reason=SUCCESSOR_REQUIRED' 'terminal branch refusal was not typed'
    [ "$(cat "$STATE/terminal-branch.meta")" = "$before" ] || fail 'successor-required refusal mutated the stage record'
  done
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINALBRANCH fm/terminal-branch completed "$head" passed https://github.com/o/r/pull/9)

  git -C "$wt" branch fm/terminal-branch-successor main
  out=$("$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 1 "$rc" "pre-existing successor name must refuse: $out"
  assert_contains "$out" 'SUCCESSOR_COLLISION' 'successor name collision was not typed'
  git -C "$wt" branch -D fm/terminal-branch-successor >/dev/null
  rm -f "$STATE/.terminal-branch.stage-successor-branch"

  out=$(FM_STAGE_TEST_INTERRUPT_AFTER_SUCCESSOR_BRANCH=1 "$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 86 "$rc" "interrupted branch successor must stop after the branch effect: $out"
  [ "$(git -C "$wt" branch --show-current)" = fm/terminal-branch-successor ] || fail 'interrupted successor did not leave the deterministic branch for recovery'
  [ "$(meta_get terminal-branch stage)" = validation-running ] || fail 'interrupted branch creation became authoritative before publication'
  assert_present "$STATE/.terminal-branch.stage-successor-branch" 'interrupted successor did not retain its recovery journal'
  out=$(FM_STAGE_TEST_INTERRUPT_AFTER_SUCCESSOR_PUBLISH=1 "$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 86 "$rc" "branch successor interruption after atomic publication must preserve a recoverable transition: $out"
  [ "$(meta_get terminal-branch stage)" = candidate-successor ] || fail 'published branch successor was not atomically authoritative'
  [ "$(grep -c '^candidate-successor:' "$STATE/terminal-branch.status" || true)" = 0 ] || fail 'interrupted branch successor exposed a partial receipt'
  assert_present "$STATE/.terminal-branch.stage-successor-branch" 'published interruption lost its recovery journal'
  out=$("$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 0 "$rc" "interrupted branch successor must recover idempotently: $out"
  assert_contains "$out" 'candidate-successor:' 'recovered branch transition emitted no typed receipt'
  [ "$(meta_get terminal-branch stage_branch)" = fm/terminal-branch-successor ] || fail 'successor branch was not published'
  [ "$(meta_get terminal-branch stage_predecessor_branch)" = fm/terminal-branch ] || fail 'predecessor branch lineage was not preserved'
  assert_absent "$STATE/.terminal-branch.stage-successor-branch" 'completed successor left its preparation journal'
  before=$(cat "$STATE/terminal-branch.meta")
  out=$("$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 0 "$rc" "duplicate branch successor must replay: $out"
  [ "$(cat "$STATE/terminal-branch.meta")" = "$before" ] || fail 'duplicate branch successor mutated the stage record'
  [ "$(grep -c '^candidate-successor:' "$STATE/terminal-branch.status")" = 1 ] || fail 'duplicate branch successor appended another receipt'
  out=$("$STAGE" terminal-branch committed --retry 2>&1); rc=$?
  expect_code 0 "$rc" "minted branch must admit a fresh attempt only at committed --retry: $out"
  assert_contains "$out" 'STAGE: validation-admitted:' 'fresh successor attempt was not admitted'
  [ "$(obs_get terminal-branch candidate_branch)" = fm/terminal-branch-successor ] || fail 'observer did not bind the minted branch candidate'
  [ "$(meta_get terminal-branch stage_predecessor_run)" = 01TERMINALBRANCH ] || fail 'fresh attempt erased predecessor run lineage'
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINALBRANCHNEXT fm/terminal-branch-successor reviewing "$head")
  out=$("$STAGE" terminal-branch running --run 01TERMINALBRANCHNEXT 2>&1); rc=$?
  expect_code 0 "$rc" "minted branch fresh run must bind independently: $out"
  [ "$(meta_get terminal-branch stage_run)" = 01TERMINALBRANCHNEXT ] || fail 'current run did not advance after final admission'
  [ "$(meta_get terminal-branch stage_predecessor_run)" = 01TERMINALBRANCH ] || fail 'current run advance rewrote predecessor lineage'
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINALBRANCHNEXT fm/terminal-branch-successor completed "$head" passed https://github.com/o/r/pull/10)
  out=$("$STAGE" terminal-branch committed --retry 2>&1); rc=$?
  expect_code 1 "$rc" "the minted branch cannot be reused after its own terminal publication: $out"
  assert_contains "$out" 'SUCCESSOR_REQUIRED' 'second terminal publication did not require a successor'
  out=$("$STAGE" terminal-branch successor 2>&1); rc=$?
  expect_code 1 "$rc" "a second distinct minted successor must refuse: $out"
  assert_contains "$out" 'SUCCESSOR_COLLISION' 'second minted successor refusal was not typed'
  pass 'terminal validation branch requires one explicit crash-safe successor and refuses name collisions'
}
test_terminal_branch_requires_one_minted_successor

# Terminal successors need the producer's explicit verified readback, not the
# active-only exemption or ordinary synchronized equality.
test_completed_successor_stage() {
  local wt submitted head out rc proof saved_meta saved_obs mutation valid_status desc indent
  wt="$TMP_ROOT/wt-terminal"
  make_worktree "$wt" fm/terminal
  submitted=$(git -C "$wt" rev-parse HEAD)
  make_task terminal no-mistakes "$wt"
  printf abc > "$DATA/terminal/skill.md"
  desc="$DATA/terminal/work-context.json"
  cat > "$desc" <<EOF
{"engineering":{"generation":"g1","triggers":["test-change"],"skills":[{"id":"tdd","path":"$DATA/terminal/skill.md","release":"r1","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","role":"worker","stage":"test","trigger":"test-change"}],"verification":[{"id":"caller","skill":"tdd","scope":"composition","public_seam":"fm-brief","inputs":"declared source","environment":"controlled and inherited","oracle":"literal expected bytes","allowed_effects":"scratch only","source_identity":"r1","caller_identity":"fixture","command":"receiver-test","negative":"stale source refuses","owner":"crewmate-boundary-repair","next_gate":"ci-ready"},{"id":"consumer","skill":"tdd","scope":"deployed-consumer","public_seam":"next-worker","inputs":"qualified release","environment":"native subscription","oracle":"actual worker artifact","allowed_effects":"authorized receiver work","source_identity":"r1","caller_identity":"next-worker","command":"qualified worker","negative":"old source refuses","owner":"runtime-pin-adoption-gap","next_gate":"next genuine dispatch"}]}}
EOF
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" terminal committed 2>&1); rc=$?
  expect_code 0 "$rc" "terminal fixture admission: $out"
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINAL00000000000000001 fm/terminal reviewing "$submitted")
  out=$("$STAGE" terminal running --run 01TERMINAL00000000000000001 2>&1); rc=$?
  expect_code 0 "$rc" "terminal fixture binding: $out"
  git -C "$wt" checkout -q -b new-base HEAD^
  printf 'upstream\n' > "$wt/upstream.txt"
  git -C "$wt" add upstream.txt
  git -C "$wt" commit -q -m upstream
  git -C "$wt" checkout -q fm/terminal
  git -C "$wt" rebase new-base >/dev/null 2>&1 || fail 'terminal fixture rebase'
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/no-mistakes/sync-anchor/01TERMINAL00000000000000001 "$submitted"
  FM_FAKE_AXI_STATUS=$(run_toon 01TERMINAL00000000000000001 fm/terminal completed "$head" passed)
  valid_status=$FM_FAKE_AXI_STATUS
  jq --arg head "$head" '.task="terminal" | .run="01TERMINAL00000000000000001" | .head=$head' \
    "$DATA/engineering/valid-evidence.json" > "$DATA/terminal/engineering-evidence.json"
  cp "$DATA/terminal/engineering-evidence.json" "$DATA/terminal/valid-evidence.json"
  proof="branch_sync:
  state: synchronized
  relation: equal
  safety: already_synchronized
  local:
    branch: fm/terminal
    head: $head
    clean: true
  pipeline:
    run: 01TERMINAL00000000000000001
    status: completed
    submitted_head: $submitted
    current_head: $head
    pushed_head: $head
    push_generation: 2
  target:
    kind: upstream
    ref: refs/heads/fm/terminal
  remote:
    freshness: live
    observed_head: $head
  successor:
    verified: true
    run_id: 01TERMINAL00000000000000001
    submitted_head: $submitted
    qualified_head: $head
    push_generation: 2
    target_kind: upstream
    target_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    target_ref: refs/heads/fm/terminal
    preserved_ref: refs/no-mistakes/sync-anchor/01TERMINAL00000000000000001
    preserved_head: $submitted"
  export FM_FAKE_SYNC="$proof" FM_FAKE_SYNC_RC=0
  saved_meta=$(cat "$STATE/terminal.meta")
  saved_obs=$(cat "$STATE/terminal.nm-observe")
  out=$("$STAGE" terminal ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "verified completed same-run rebase admits: $out"
  [ "$(meta_get terminal stage_head)" = "$submitted" ] || fail 'admission replaced original candidate'
  [ "$(obs_get terminal candidate_head)" = "$submitted" ] || fail 'admission replaced observer candidate'
  [ "$(meta_get terminal stage_run)" = 01TERMINAL00000000000000001 ] || fail 'admission replaced bound run'
  for mutation in absent false scalar-successor scalar-pipeline scalar-local scalar-target scalar-remote inline-object inline-array quoted-boolean padded-run padded-head padded-ref duplicate duplicate-root scalar-duplicate-root foreign-sibling indent-three indent-one indent-five indent-six indent-tab indent-mixed malformed-digest foreign-run foreign-submission foreign-head foreign-branch foreign-target stale-generation stale-attempt failed-read dirty manual-rewrite missing-anchor symbolic-anchor wrong-evidence; do
    printf '%s\n' "$saved_meta" > "$STATE/terminal.meta"
    printf '%s\n' "$saved_obs" > "$STATE/terminal.nm-observe"
    FM_FAKE_SYNC=$proof; FM_FAKE_SYNC_RC=0; FM_FAKE_AXI_STATUS=$valid_status
    case "$mutation" in
      absent) FM_FAKE_SYNC='' ;;
      scalar-successor) FM_FAKE_SYNC=${proof/  successor:/  successor: false} ;;
      scalar-pipeline) FM_FAKE_SYNC=${proof/  pipeline:/  pipeline: unavailable} ;;
      scalar-local) FM_FAKE_SYNC=${proof/  local:/  local: false} ;;
      scalar-target) FM_FAKE_SYNC=${proof/  target:/  target: unavailable} ;;
      scalar-remote) FM_FAKE_SYNC=${proof/  remote:/  remote: false} ;;
      inline-object) FM_FAKE_SYNC=${proof/  successor:/  successor: \{\}} ;;
      inline-array) FM_FAKE_SYNC=${proof/  successor:/  successor: []} ;;
      quoted-boolean) FM_FAKE_SYNC=${proof/verified: true/verified: \"true\"} ;;
      padded-run) FM_FAKE_SYNC=${proof/run_id: 01TERMINAL00000000000000001/run_id: \" 01TERMINAL00000000000000001 \"} ;;
      padded-head) FM_FAKE_SYNC=${proof/qualified_head: $head/qualified_head: \" $head \"} ;;
      padded-ref) FM_FAKE_SYNC=${proof/target_ref: refs\/heads\/fm\/terminal/target_ref: \" refs\/heads\/fm\/terminal \"} ;;
      duplicate-root) FM_FAKE_SYNC="$proof
branch_sync:
  state: synchronized" ;;
      scalar-duplicate-root) FM_FAKE_SYNC="$proof
branch_sync: false" ;;
      foreign-sibling) FM_FAKE_SYNC=${proof/    preserved_head:/  diagnostic-note:$'\n'    preserved_head:} ;;
      indent-*)
        case "$mutation" in
          indent-three) indent='   ' ;;
          indent-one) indent=' ' ;;
          indent-five) indent='     ' ;;
          indent-six) indent='      ' ;;
          indent-tab) indent=$'\t' ;;
          indent-mixed) indent=$'  \t' ;;
        esac
        FM_FAKE_SYNC=${proof/    preserved_head:/${indent}diagnostic-note:$'\n'    preserved_head:}
        ;;
      malformed-digest) FM_FAKE_SYNC=${proof/target_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/target_fingerprint: bad} ;;
      foreign-branch) FM_FAKE_AXI_STATUS=$(run_toon 01TERMINAL00000000000000001 fm/foreign completed "$head" passed) ;;
      symbolic-anchor) git -C "$wt" symbolic-ref refs/no-mistakes/sync-anchor/01TERMINAL00000000000000001 refs/heads/new-base ;;
      wrong-evidence) jq --arg head "$submitted" '.head=$head' "$DATA/terminal/valid-evidence.json" > "$DATA/terminal/engineering-evidence.json" ;;
      false) FM_FAKE_SYNC=${proof/verified: true/verified: false} ;;
      duplicate) FM_FAKE_SYNC="$proof
    verified: true" ;;
      foreign-run) FM_FAKE_SYNC=${proof/run_id: 01TERMINAL00000000000000001/run_id: 01FOREIGN000000000000000001} ;;
      foreign-submission) FM_FAKE_SYNC=$(printf '%s\n' "$proof" | sed "s/submitted_head: $submitted/submitted_head: $head/g") ;;
      foreign-head) FM_FAKE_SYNC=${proof/qualified_head: $head/qualified_head: $submitted} ;;
      foreign-target) FM_FAKE_SYNC=${proof/target_ref: refs\/heads\/fm\/terminal/target_ref: refs\/heads\/foreign} ;;
      stale-generation) FM_FAKE_SYNC=$(printf '%s\n' "$proof" | awk '!changed && /push_generation: 2/ { sub(/push_generation: 2/, "push_generation: 3"); changed=1 } { print }' ) ;;
      stale-attempt) printf 'attempt_id=foreign\n' >> "$STATE/terminal.nm-observe" ;;
      failed-read) FM_FAKE_SYNC_RC=1 ;;
      dirty) printf dirty > "$wt/untracked" ;;
      manual-rewrite) git -C "$wt" update-ref refs/heads/fm/terminal "$submitted" ;;
      missing-anchor) git -C "$wt" update-ref -d refs/no-mistakes/sync-anchor/01TERMINAL00000000000000001 ;;
    esac
    out=$("$STAGE" terminal ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
    expect_code 1 "$rc" "terminal successor refuses $mutation: $out"
    [ "$(meta_get terminal stage)" = validation-running ] || fail "$mutation admitted a stage"
    if [ "$mutation" = scalar-duplicate-root ] || [ "$mutation" = foreign-sibling ] || [[ "$mutation" = indent-* || "$mutation" = padded-* ]]; then
      [ "$(cat "$STATE/terminal.meta")" = "$saved_meta" ] || fail "$mutation changed stage identity"
      [ "$(cat "$STATE/terminal.nm-observe")" = "$saved_obs" ] || fail "$mutation changed observer identity"
    fi
    rm -f "$wt/untracked"
    git -C "$wt" update-ref refs/heads/fm/terminal "$head"
    git -C "$wt" update-ref --no-deref refs/no-mistakes/sync-anchor/01TERMINAL00000000000000001 "$submitted"
    cp "$DATA/terminal/valid-evidence.json" "$DATA/terminal/engineering-evidence.json"
  done
  FM_FAKE_SYNC=$proof; FM_FAKE_SYNC_RC=0; FM_FAKE_AXI_STATUS=$valid_status
  out=$("$STAGE" terminal ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "valid terminal successor remains admissible: $out"
  printf '%s\n' "$saved_meta" > "$STATE/terminal.meta"
  printf '%s\n' "$saved_obs" > "$STATE/terminal.nm-observe"
  FM_FAKE_SYNC=${proof/run_id: 01TERMINAL00000000000000001/run_id: \"01TERMINAL00000000000000001\"}
  FM_FAKE_SYNC=${FM_FAKE_SYNC/qualified_head: $head/qualified_head: \"$head\"}
  FM_FAKE_SYNC=${FM_FAKE_SYNC/target_ref: refs\/heads\/fm\/terminal/target_ref: \"refs\/heads\/fm\/terminal\"}
  out=$("$STAGE" terminal ci-ready --pr https://github.com/o/r/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "exact quoted terminal identities remain admissible: $out"
  FM_FAKE_SYNC=''; FM_FAKE_SYNC_RC=0
  pass 'completed same-run successor requires verified exact bindings and preserves original candidate'
}
test_completed_successor_stage

# --- the record holds one value per key, and one of them is the landed head ---
#
# Regression origin (2026-09-15): a live task record carried BOTH
# `stage=validation-running` and `stage=commissioned`; `show` rendered the
# second, while a reader taking the first line, or every line, got something
# else. The same family produced a landing record naming the head validation
# started from rather than the head that landed. Both are provenance defects:
# the record asserted a lifecycle fact that did not happen, and a later reader,
# a recovery, or an audit cannot tell that apart from a manufactured record.

test_a_record_cannot_hold_two_values_for_one_key() {
  local out rc wt line
  wt="$TMP_ROOT/wt-shadow"
  make_worktree "$wt" fm/shadow
  make_task shadow no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" shadow committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  [ "$(grep -c '^stage=' "$STATE/shadow.meta")" = 1 ] || fail "the stage owner records one stage line"

  # A second write of the same key must REPLACE, never append a shadow value.
  FM_FAKE_AXI_STATUS=$(run_toon 01RUNS fm/shadow running "$(git -C "$wt" rev-parse HEAD)")
  out=$("$STAGE" shadow running --run 01RUNS 2>&1); rc=$?
  expect_code 0 "$rc" "running binds: $out"
  [ "$(meta_get shadow stage)" = validation-running ] || fail "the second write changed the recorded stage"
  [ "$(grep -c '^stage=' "$STATE/shadow.meta")" = 1 ] \
    || fail "a second transition appended a shadow stage value instead of replacing it"
  FM_FAKE_AXI_STATUS=""

  # A writer that does append one cannot publish it. The publication boundary
  # every task-record writer crosses is what makes the shadow unrepresentable.
  cp "$STATE/shadow.meta" "$STATE/.shadow.staged"
  printf 'stage=commissioned\n' >> "$STATE/.shadow.staged"
  FM_BACKLOG_TRANSITION_ERROR=
  if fm_backlog_atomic_transition publish "$STATE/.shadow.staged" "$STATE/shadow.meta" "task record" "$STATE"; then
    fail "publication accepted a record answering stage= twice"
  fi
  case "$FM_BACKLOG_TRANSITION_ERROR" in
    *"stage="*"more than once"*) ;;
    *) fail "the refusal must name the duplicated key (got: $FM_BACKLOG_TRANSITION_ERROR)" ;;
  esac
  [ "$(grep -c '^stage=' "$STATE/shadow.meta")" = 1 ] || fail "the refused publication must not land"

  # A record corrupted out of band is refused by every reader rather than
  # resolved by position, so no two readers can report different stages.
  printf 'stage=commissioned\n' >> "$STATE/shadow.meta"
  out=$("$STAGE" shadow show 2>&1); rc=$?
  expect_code 1 "$rc" "show refuses a record with two stage values"
  assert_contains "$out" "reason=CONFLICTING_RECORD" "the refusal is typed"
  assert_contains "$out" "stage=" "the refusal names the key the record answers twice"
  assert_not_contains "$out" "commissioned" "the refusal must not report either answer as current"
  out=$("$STAGE" shadow landing 2>&1); rc=$?
  expect_code 1 "$rc" "a transition refuses the same conflicted record"
  assert_contains "$out" "reason=CONFLICTING_RECORD" "the transition refusal is typed"
  [ "$(status_line_stage "$(last_line shadow)")" != landing ] || fail "the refused transition recorded a receipt"
  # The classifier reads the same record and agrees there is no stage to read.
  crew_pipeline_wait_declared shadow "$STATE" \
    && fail "the classifier resolved a conflicted record by position"
  [ -z "$(fm_classify_meta_value "$STATE/shadow.meta" stage || true)" ] \
    || fail "the shared record reader answered a question the record answers twice"
  declare -F fm_meta_get >/dev/null || fail "the shared record reader is not loaded; this case would pass vacuously"
  declare -F fm_meta_duplicate_key >/dev/null || fail "the record-shape owner is not loaded; this case would pass vacuously"
  # fm_meta_get is deliberately PERMISSIVE and stays so: it is shared by
  # hundreds of callers, including guards that discard its status and bare
  # assignments under `set -e`, so refusing is opt-in at the strict readers
  # rather than imposed here. What carries the guarantee is the publication
  # guard and the strict readers above, not this one.
  fm_meta_get "$STATE/shadow.meta" stage >/dev/null 2>&1 \
    || fail "the permissive reader must not start refusing its hundred callers"
  [ "$(fm_meta_get "$STATE/shadow.meta" stage)" = commissioned ] \
    || fail "the permissive reader answers with the last value, as its contract says"
  [ "$(fm_meta_duplicate_key "$STATE/shadow.meta")" = stage ] \
    || fail "the record-shape owner must name the duplicated key"

  # Reconciling the record restores every reader at once.
  grep -v '^stage=commissioned$' "$STATE/shadow.meta" > "$TMP_ROOT/shadow.fixed"
  mv "$TMP_ROOT/shadow.fixed" "$STATE/shadow.meta"
  out=$("$STAGE" shadow show 2>&1); rc=$?
  expect_code 0 "$rc" "the reconciled record reads again"
  assert_contains "$out" "STAGE_RECORDED: validation-running" "the surviving value is the one the record holds"
  line=$(last_line shadow)
  [ -n "$line" ] || fail "status log kept its receipts"

  # Readers refuse PER KEY and agree per key. A record answering some unrelated
  # cosmetic key twice must not cost a supervision reader the key it came for:
  # a recovery path that refuses because other evidence is unavailable has
  # turned one duplicated field into total loss of stage classification. The
  # record-level condition stays detectable for the owners that need it.
  printf 'window=firstmate:fm-shadow-2\n' >> "$STATE/shadow.meta"
  [ "$(fm_classify_meta_value "$STATE/shadow.meta" stage)" = validation-running ] \
    || fail "an unrelated duplicated key must not make the stage unreadable"
  [ "$(fm_meta_get "$STATE/shadow.meta" stage)" = validation-running ] \
    || fail "the two shared readers must agree on the value of an unconflicted key"
  fm_classify_meta_value "$STATE/shadow.meta" window >/dev/null \
    && fail "the strict reader must refuse the duplicated key itself"
  [ "$(fm_meta_duplicate_key "$STATE/shadow.meta")" = window ] \
    || fail "the record-level duplicate must stay detectable"
  grep -v '^window=firstmate:fm-shadow-2$' "$STATE/shadow.meta" > "$TMP_ROOT/shadow.fixed2"
  mv "$TMP_ROOT/shadow.fixed2" "$STATE/shadow.meta"
  pass "fm-stage record: one value per key - a second write replaces it, an appended shadow cannot publish, the stage owner refuses a conflicted record, and the strict readers refuse the conflicted key while the permissive shared reader keeps its contract"
}

test_landing_names_the_head_that_landed() {
  local out rc wt submitted landed line
  wt="$TMP_ROOT/wt-landed"
  make_worktree "$wt" fm/landed
  make_task landed no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" landed committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  submitted=$(meta_get landed stage_head)
  [ -n "$submitted" ] || fail "the submitted candidate is recorded"

  # The pipeline's own fix commits advance the candidate while validation runs,
  # so the head that lands is a successor of the head that was submitted.
  git -C "$wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix'
  landed=$(git -C "$wt" rev-parse HEAD)
  [ "$landed" != "$submitted" ] || fail "the fixture must move the head"
  printf 'pr_head=%s\n' "$landed" >> "$STATE/landed.meta"
  printf 'stage_pr=%s\n' 'https://github.com/o/r/pull/9' >> "$STATE/landed.meta"

  out=$("$STAGE" landed landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records: $out"
  [ "$(meta_get landed stage_head)" = "$submitted" ] \
    || fail "the head validation started from must survive as recorded evidence"
  # The landed head is a DURABLE fact of the record, captured once at landing:
  # the sources it was resolved from are other writers' live state and may move
  # or vanish afterwards, so a record that re-derived it would not be a record.
  [ "$(meta_get landed stage_landed_head)" = "$landed" ] \
    || fail "the record must name the head that landed (got $(meta_get landed stage_landed_head))"
  [ "$(grep -c '^stage_landed_head=' "$STATE/landed.meta")" = 1 ] \
    || fail "the landed head must be recorded exactly once"
  line=$(last_line landed)
  [ "$(status_line_stage "$line")" = landing ] || fail "landing receipt issued"
  [ "$(status_stage_field "$line" head)" = "${submitted:0:12}" ] \
    || fail "the receipt keeps the submitted head (got $(status_stage_field "$line" head))"
  [ "$(status_stage_field "$line" landed_head)" = "${landed:0:12}" ] \
    || fail "the receipt must carry the landed head apart from it (got $(status_stage_field "$line" landed_head))"
  [ "$(status_stage_field "$line" landed_head)" != "$(status_stage_field "$line" head)" ] \
    || fail "the two heads must stay distinguishable"
  [ "$(status_stage_field "$line" reason)" = "landed-head:pr-head" ] \
    || fail "the receipt must say which evidence supplied the landed head (got $(status_stage_field "$line" reason))"
  out=$("$STAGE" landed show 2>&1)
  assert_contains "$out" "landed_head=${landed:0:12}" "show reports the landed head"
  assert_contains "$out" "head=${submitted:0:12}" "show still reports where validation started"

  # The record keeps naming the head that landed once the evidence it was
  # resolved from is gone. pr_head= belongs to bin/fm-pr-check.sh and is live
  # mutable state; rewriting it after the landing must not change history.
  grep -v '^pr_head=' "$STATE/landed.meta" > "$TMP_ROOT/landed.repr"
  printf 'pr_head=%s\n' "$(printf '%040d' 7)" >> "$TMP_ROOT/landed.repr"
  mv "$TMP_ROOT/landed.repr" "$STATE/landed.meta"
  out=$("$STAGE" landed show 2>&1)
  assert_contains "$out" "landed_head=${landed:0:12}" \
    "a rewritten pr_head= must not change the head the record says landed"

  # The landing fact survives the next transition rather than being dropped by
  # the record rewrite, and the read-back proves the LANDED head reachable.
  land_on_integration "$wt" "$landed"
  out=$("$STAGE" landed activated 2>&1); rc=$?
  expect_code 0 "$rc" "activated reads back the landed head: $out"
  [ "$(meta_get landed stage_landed_head)" = "$landed" ] \
    || fail "the landed head must survive the activated transition"
  # The head was made durable, so the evidence that proved it must be equally
  # durable: a record naming a head without naming what proved it leaves the
  # next reader unable to judge how well it is established.
  [ "$(meta_get landed stage_landed_head_source)" = pr-head ] \
    || fail "activated destroyed the landed-head provenance (got '$(meta_get landed stage_landed_head_source)')"
  [ "$(grep -c '^stage_landed_head_source=' "$STATE/landed.meta")" = 1 ] \
    || fail "the provenance must be carried forward once, not shadowed"
  [ "$(status_stage_field "$(last_line landed)" landed_head)" = "${landed:0:12}" ] \
    || fail "the activated receipt must still name the head that landed"
  [ "$(status_stage_field "$(last_line landed)" reason)" = "ancestor-of:${landed:0:12}:landed-head:${landed:0:12}" ] \
    || fail "the read-back must name the landed head (got $(status_stage_field "$(last_line landed)" reason))"
  # Before landing there is no landed head to name, even though the forge head
  # the merge will consume is already recorded.
  make_task notyet no-mistakes "$wt"
  printf 'pr_head=%s\n' "$landed" >> "$STATE/notyet.meta"
  out=$("$STAGE" notyet committed 2>&1); rc=$?
  expect_code 0 "$rc" "third candidate admits: $out"
  out=$("$STAGE" notyet show 2>&1)
  assert_contains "$out" "landed_head=-" "nothing has landed yet, so no landed head is claimed"

  # An unresolvable landed head is recorded as unknown, never filled in with the
  # candidate: that substitution is the defect, not a safe default.
  make_task unlanded no-mistakes "$wt"
  out=$("$STAGE" unlanded committed 2>&1); rc=$?
  expect_code 0 "$rc" "second candidate admits: $out"
  # No forge head recorded and the local copy is gone: nothing proves what
  # landed, which is a different answer from the candidate head.
  sed "s|^worktree=.*|worktree=$TMP_ROOT/gone-wt|" "$STATE/unlanded.meta" > "$STATE/.unlanded.rewrite"
  mv "$STATE/.unlanded.rewrite" "$STATE/unlanded.meta"
  out=$("$STAGE" unlanded landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records without provable head evidence: $out"
  line=$(last_line unlanded)
  [ "$(status_stage_field "$line" landed_head)" = "-" ] \
    || fail "an unproven landed head must read as unknown (got $(status_stage_field "$line" landed_head))"
  [ "$(status_stage_field "$line" reason)" = "landed-head:unresolved" ] \
    || fail "the receipt must say the landed head could not be proven"
  out=$("$STAGE" unlanded show 2>&1)
  assert_contains "$out" "landed_head=-" "show reports an unproven landed head as unknown"
  pass "fm-stage landing: the record names the head that landed and keeps the head validation started from, distinguishably"
}

# CAPTURE ONCE, FULL STOP. Nothing displaces a captured landed head - not a
# later worktree head, not the forge's own head, however well it descends from
# the capture. Every one of those is evidence read AFTER the landing, which is
# not evidence of what landed, and re-recording it would name a commit that
# never landed under a provenance label that says otherwise.
test_nothing_displaces_a_captured_landed_head() {
  local out rc wt first second
  wt="$TMP_ROOT/wt-moved"
  make_worktree "$wt" fm/moved
  make_task moved no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" moved committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  out=$("$STAGE" moved landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records: $out"
  first=$(meta_get moved stage_landed_head)
  [ "$first" = "$(git -C "$wt" rev-parse HEAD)" ] \
    || fail "landing must record the worktree head it proved (got $first)"
  [ "$(meta_get moved stage_landed_head_source)" = worktree ] \
    || fail "the record must name the evidence that proved the head"

  # A re-run with nothing moved stays unchanged: the recorded fact still holds.
  out=$("$STAGE" moved landing 2>&1); rc=$?
  expect_code 0 "$rc" "an unmoved re-run: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" "a re-run recording the same head is unchanged"

  # The merge lands the captured head, then the worker keeps working. That later
  # worktree head is a descendant, and it still must not displace the capture.
  git -C "$wt" commit -q --allow-empty -m 'worker keeps working after the merge'
  second=$(git -C "$wt" rev-parse HEAD)
  [ "$second" != "$first" ] || fail "the fixture must move the head"
  out=$("$STAGE" moved landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-run after the worktree moved: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" \
    "a post-merge worktree head must not displace a captured head"
  [ "$(meta_get moved stage_landed_head)" = "$first" ] \
    || fail "a later worktree head displaced the captured one (got $(meta_get moved stage_landed_head))"

  # The forge's own head for the PR is no different. bin/fm-pr-check.sh resolves
  # it live, so a re-run after the branch advanced records the POST-merge head;
  # adopting it would name a commit that never landed, under the strongest
  # provenance label there is.
  printf 'pr_head=%s\n' "$second" >> "$STATE/moved.meta"
  out=$("$STAGE" moved landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-run with a later forge head: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" \
    "a forge head read after the landing must not displace a captured head"
  [ "$(meta_get moved stage_landed_head)" = "$first" ] \
    || fail "the forge head displaced the captured one (got $(meta_get moved stage_landed_head))"
  [ "$(meta_get moved stage_landed_head_source)" = worktree ] \
    || fail "the captured provenance must stand too (got $(meta_get moved stage_landed_head_source))"
  [ "$(grep -c '^stage_landed_head=' "$STATE/moved.meta")" = 1 ] \
    || fail "the record must hold one landed head"
  [ "$(status_stage_field "$(last_line moved)" landed_head)" = "${first:0:12}" ] \
    || fail "the last receipt must still name the captured head"
  pass "fm-stage landing: a captured landed head stands against every later resolution, forge head included"
}

# The source a capture came from is provenance, never a licence to check it
# less. pr_head= is not a stage_* field, so it survives `committed --retry` onto
# a new candidate; accepting it on its syntax alone let an abandoned attempt's
# head be recorded as this task's landed head.
test_recorded_forge_head_must_be_on_the_candidate_lineage() {
  local out rc wt stale
  wt="$TMP_ROOT/wt-lineage"
  make_worktree "$wt" fm/lineage
  make_task lineage no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  # A head from an unrelated history, syntactically a perfectly good SHA.
  git -C "$wt" checkout -q --orphan fm/lineage-abandoned
  git -C "$wt" commit -q --allow-empty -m 'abandoned attempt'
  stale=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q fm/lineage
  out=$("$STAGE" lineage committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  printf 'pr_head=%s\n' "$stale" >> "$STATE/lineage.meta"

  out=$("$STAGE" lineage landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records: $out"
  [ "$(meta_get lineage stage_landed_head)" != "$stale" ] \
    || fail "a head off the candidate lineage was recorded as the landed head"
  # It falls through to the worktree, which IS on the candidate lineage, rather
  # than being pre-empted by the unusable one.
  [ "$(meta_get lineage stage_landed_head)" = "$(git -C "$wt" rev-parse fm/lineage)" ] \
    || fail "the usable evidence must still be reached"
  [ "$(meta_get lineage stage_landed_head_source)" = worktree ] \
    || fail "the recorded provenance must name the source that actually proved it"

  # With no fallback either, nothing is claimed at all.
  make_task lineage2 no-mistakes "$wt"
  out=$("$STAGE" lineage2 committed 2>&1); rc=$?
  expect_code 0 "$rc" "second candidate admits: $out"
  printf 'pr_head=%s\n' "$stale" >> "$STATE/lineage2.meta"
  sed "s|^worktree=.*|worktree=$TMP_ROOT/gone-lineage-wt|" "$STATE/lineage2.meta" > "$TMP_ROOT/lineage2.rw"
  mv "$TMP_ROOT/lineage2.rw" "$STATE/lineage2.meta"
  out=$("$STAGE" lineage2 landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing without usable evidence: $out"
  [ -z "$(meta_get lineage2 stage_landed_head)" ] \
    || fail "an off-lineage forge head was claimed as the landed head"
  [ "$(status_stage_field "$(last_line lineage2)" reason)" = "landed-head:unresolved" ] \
    || fail "the receipt must say nothing proved the landed head"
  pass "fm-stage landing: a recorded forge head is evidence only on the candidate lineage, never on its syntax alone"
}

# A captured landed head is a fact about the past, and `landing` is deliverable
# more than once against evidence that keeps moving: bin/fm-pr-merge.sh re-runs
# bin/fm-pr-check.sh, which drops a pr_head= it cannot resolve, while the
# worker's worktree advances past the head that actually merged. Every one of
# those later answers is evidence read AFTER the landing, so a re-delivery keeps
# what was captured rather than recording any of them.
# EMPTINESS IS NOT ABSENCE. A landing that looked and could prove nothing
# records `unresolved` - a positive fact about a decision that WAS made. Reading
# that empty head as "nothing was recorded" would let a later re-delivery fill
# it in, and the record would end up naming a head that never landed. Nothing
# fills an unresolved capture, the forge's own head included.
test_an_unresolved_capture_is_a_decision_not_a_blank() {
  local out rc wt landed gone
  wt="$TMP_ROOT/wt-unresolved"
  gone="$TMP_ROOT/gone-unresolved-wt"
  make_worktree "$wt" fm/unresolved
  make_task unresolvedcap no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" unresolvedcap committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"

  # Landing runs while the worktree is unreachable and no forge head is
  # recorded, so nothing proves a landed head.
  sed "s|^worktree=.*|worktree=$gone|" "$STATE/unresolvedcap.meta" > "$TMP_ROOT/uc.rw"
  mv "$TMP_ROOT/uc.rw" "$STATE/unresolvedcap.meta"
  out=$("$STAGE" unresolvedcap landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing records an unresolved head: $out"
  [ -z "$(meta_get unresolvedcap stage_landed_head)" ] || fail "nothing proved a head, so none may be named"
  [ "$(meta_get unresolvedcap stage_landed_head_source)" = unresolved ] \
    || fail "the record must say landing looked and proved nothing"

  # The merge happens, the worker keeps committing, and the worktree comes back.
  git -C "$wt" commit -q --allow-empty -m 'worker keeps working after the merge'
  landed=$(git -C "$wt" rev-parse HEAD)
  sed "s|^worktree=.*|worktree=$wt|" "$STATE/unresolvedcap.meta" > "$TMP_ROOT/uc.rw2"
  mv "$TMP_ROOT/uc.rw2" "$STATE/unresolvedcap.meta"
  out=$("$STAGE" unresolvedcap landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-delivery once the worktree is back: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" \
    "a post-merge worktree head must not fill an unresolved capture"
  [ -z "$(meta_get unresolvedcap stage_landed_head)" ] \
    || fail "the worktree filled an unresolved capture (got $(meta_get unresolvedcap stage_landed_head))"
  [ "$(meta_get unresolvedcap stage_landed_head_source)" = unresolved ] \
    || fail "the recorded decision must survive the re-delivery"

  # Nor by the forge's own head, which bin/fm-pr-check.sh resolves live and so
  # may equally have been written after the merge. The recorded decision stands;
  # what `activated` can prove about it is a separate fact it records separately.
  printf 'pr_head=%s\n' "$landed" >> "$STATE/unresolvedcap.meta"
  out=$("$STAGE" unresolvedcap landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-delivery with forge evidence: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" "a later forge head must not fill an unresolved capture"
  [ -z "$(meta_get unresolvedcap stage_landed_head)" ] \
    || fail "the forge head filled an unresolved capture (got $(meta_get unresolvedcap stage_landed_head))"
  [ "$(meta_get unresolvedcap stage_landed_head_source)" = unresolved ] \
    || fail "the recorded decision must stand against every later resolution"
  pass "fm-stage landing: a recorded unresolved landed head is a decision that stands, fillable by nothing"
}

# Every strictness rule needs an escape, and the escape must be honest rather
# than silent. A landed head captured from the worktree can be wrong - the
# worker's local commit was never the one pushed - and capture-once means
# nothing replaces it, so refusing forever would leave hand-editing a live fleet
# record as the only way out. Activation proceeds on what it CAN prove and
# records, in a field a consumer can match on, that the captured head was not
# among it.
test_activation_names_an_unconfirmed_landed_head_instead_of_refusing() {
  local out rc wt project submitted unpushed
  wt="$TMP_ROOT/wt-unconfirmed"
  project="$TMP_ROOT/project-unconfirmed"
  make_worktree "$wt" fm/unconfirmed
  make_task unconfirmed no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" unconfirmed committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  submitted=$(meta_get unconfirmed stage_head)

  # The worker commits something that is never pushed, and landing captures it
  # from the worktree because no forge head is recorded.
  git -C "$wt" commit -q --allow-empty -m 'local commit that never lands'
  unpushed=$(git -C "$wt" rev-parse HEAD)
  out=$("$STAGE" unconfirmed landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing captures the worktree head: $out"
  [ "$(meta_get unconfirmed stage_landed_head)" = "$unpushed" ] || fail "the worktree head was not captured"

  # The project integrated the SUBMITTED head instead, so the captured head is
  # not reachable from the branch that decides what landed.
  git clone -q --no-local "$wt" "$project" 2>/dev/null || fail "could not build the project clone"
  land_on_integration "$project" "$submitted"
  sed "s|^project=.*|project=$project|" "$STATE/unconfirmed.meta" > "$TMP_ROOT/unconf.rw"
  mv "$TMP_ROOT/unconf.rw" "$STATE/unconfirmed.meta"

  out=$("$STAGE" unconfirmed activated 2>&1); rc=$?
  expect_code 0 "$rc" "activation must proceed on what it can prove: $out"
  assert_not_contains "$out" "NO_READBACK" "activation must not refuse when the candidate head is provable"
  # Two facts, both present, neither inferable from the other: what WAS proven,
  # and that the captured landed head was not.
  [ "$(meta_get unconfirmed stage_landed_head_confirmed)" = unconfirmed ] \
    || fail "the record must say the captured landed head could not be confirmed (got '$(meta_get unconfirmed stage_landed_head_confirmed)')"
  [ "$(status_stage_field "$(last_line unconfirmed)" reason)" = "ancestor-of:${submitted:0:12}:candidate-head:${submitted:0:12}" ] \
    || fail "the record must say what it did prove (got $(status_stage_field "$(last_line unconfirmed)" reason))"
  [ "$(status_stage_field "$(last_line unconfirmed)" landed_confirmed)" = unconfirmed ] \
    || fail "the receipt must carry the disposition a consumer matches on"
  # The mis-captured head and its provenance are NOT rewritten to make the
  # record agree with itself.
  [ "$(meta_get unconfirmed stage_landed_head)" = "$unpushed" ] \
    || fail "activation rewrote the captured landed head"
  [ "$(meta_get unconfirmed stage_landed_head_source)" = worktree ] \
    || fail "activation rewrote the captured provenance"
  [ "$(status_stage_field "$(last_line unconfirmed)" landed_head)" = "${unpushed:0:12}" ] \
    || fail "the receipt must still name the captured head"
  out=$("$STAGE" unconfirmed show 2>&1)
  assert_contains "$out" "landed_confirmed=unconfirmed" "show reports the disposition"
  out=$("$STAGE" unconfirmed activated 2>&1); rc=$?
  expect_code 0 "$rc" "a repeat activation: $out"
  assert_contains "$out" "STAGE_UNCHANGED: activated" "a repeat activation stays a no-op"
  pass "fm-stage activated: an unprovable captured landed head is named as unconfirmed rather than refusing forever"
}

# THE PROOF MUST BE AS DURABLE AS THE THING PROVED. The landed head is captured
# once and never regresses because its sources are live mutable state - and the
# confirmation that establishes it is derived from state just as mutable, so it
# gets the same protection. A later delivery failing to re-prove a fact is not
# evidence against it: the project clone moving to another branch is ordinary
# housekeeping, not a discovery that the head did not land.
test_a_confirmed_landed_head_is_never_downgraded() {
  local out rc wt project landed other
  wt="$TMP_ROOT/wt-monotonic"
  project="$TMP_ROOT/project-monotonic"
  make_worktree "$wt" fm/monotonic
  make_task monotonic no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" monotonic committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  git -C "$wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix'
  landed=$(git -C "$wt" rev-parse HEAD)
  printf 'pr_head=%s\n' "$landed" >> "$STATE/monotonic.meta"
  out=$("$STAGE" monotonic landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing captures the forge head: $out"

  # The project integrated the landed head, so activation proves it.
  git clone -q --no-local "$wt" "$project" 2>/dev/null || fail "could not build the project clone"
  land_on_integration "$project" "$landed"
  sed "s|^project=.*|project=$project|" "$STATE/monotonic.meta" > "$TMP_ROOT/mono.rw"
  mv "$TMP_ROOT/mono.rw" "$STATE/monotonic.meta"
  out=$("$STAGE" monotonic activated 2>&1); rc=$?
  expect_code 0 "$rc" "activation proves the landed head: $out"
  [ "$(meta_get monotonic stage_landed_head_confirmed)" = confirmed ] \
    || fail "the landed head was not confirmed (got '$(meta_get monotonic stage_landed_head_confirmed)')"

  # The integration branch is then rewound to a history that does not contain
  # the landed head - the shape of a clone reset, a mirror rebuild, or any other
  # housekeeping - and the merge poll's marker is present. Re-delivering
  # activation must not read that as evidence the head never landed.
  git -C "$project" checkout -q --orphan other-branch
  git -C "$project" commit -q --allow-empty -m 'unrelated branch tip'
  other=$(git -C "$project" rev-parse HEAD)
  [ "$other" != "$landed" ] || fail "the fixture must move the integration branch off the landed head"
  land_on_integration "$project" "$other"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n9\n' \
    > "$STATE/monotonic.pr-poll-merge-notified"
  out=$("$STAGE" monotonic activated 2>&1); rc=$?
  expect_code 0 "$rc" "a re-delivery once the integration branch moved: $out"
  [ "$(meta_get monotonic stage_landed_head_confirmed)" = confirmed ] \
    || fail "a proven landed head was downgraded (got '$(meta_get monotonic stage_landed_head_confirmed)')"
  [ "$(meta_get monotonic stage_landed_head)" = "$landed" ] \
    || fail "the captured head must stand too"
  out=$("$STAGE" monotonic show 2>&1)
  assert_contains "$out" "landed_confirmed=confirmed" "show must keep reporting the proven disposition"

  # Now WITHOUT the merge marker, which is the case that tells the read-back
  # gate apart. The record still says confirmed, but the landed head is no
  # longer reachable, so a gate keyed on the recorded disposition would keep
  # reading back the unreachable head and refuse NO_READBACK forever. Reading
  # back what is still PROVABLE - the candidate head, which the integration
  # branch does contain - is what keeps the task movable, and the sticky
  # confirmation is untouched by it.
  rm -f "$STATE/monotonic.pr-poll-merge-notified"
  land_on_integration "$project" "$(meta_get monotonic stage_head)"
  out=$("$STAGE" monotonic activated 2>&1); rc=$?
  expect_code 0 "$rc" "a marker-free re-delivery must not refuse: $out"
  assert_not_contains "$out" "NO_READBACK" "the read-back must fall back to what it can still prove"
  [ "$(status_stage_field "$(last_line monotonic)" reason)" \
      = "ancestor-of:$(meta_get monotonic stage_head | cut -c1-12):candidate-head:$(meta_get monotonic stage_head | cut -c1-12)" ] \
    || fail "the read-back must name the candidate head it actually proved (got $(status_stage_field "$(last_line monotonic)" reason))"
  [ "$(meta_get monotonic stage_landed_head_confirmed)" = confirmed ] \
    || fail "falling back to the candidate head must not disturb the recorded proof"
  pass "fm-stage activated: a confirmed landed head is never downgraded, and a re-delivery that cannot re-prove it reads back what it can"
}

test_a_captured_landed_head_never_regresses() {
  local out rc wt merged captured
  wt="$TMP_ROOT/wt-capture"
  make_worktree "$wt" fm/capture
  make_task capture no-mistakes "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" capture committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  git -C "$wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix'
  merged=$(git -C "$wt" rev-parse HEAD)
  printf 'pr_head=%s\n' "$merged" >> "$STATE/capture.meta"
  out=$("$STAGE" capture landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing captures the forge head: $out"
  [ "$(meta_get capture stage_landed_head)" = "$merged" ] || fail "the forge head was not captured"
  [ "$(status_stage_field "$(last_line capture)" reason)" = "landed-head:pr-head" ] \
    || fail "the capture must name its source"

  # The forge head is gone from the record and the worktree has moved on past
  # the merge. That later worktree head is evidence read after the landing, so
  # it must not displace the capture.
  grep -v '^pr_head=' "$STATE/capture.meta" > "$TMP_ROOT/capture.norec"
  mv "$TMP_ROOT/capture.norec" "$STATE/capture.meta"
  git -C "$wt" commit -q --allow-empty -m 'worker keeps working after the merge'
  [ "$(git -C "$wt" rev-parse HEAD)" != "$merged" ] || fail "the fixture must move the worktree past the merge"
  out=$("$STAGE" capture landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-run on later evidence: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" "a later resolution must leave the record alone"
  [ "$(meta_get capture stage_landed_head)" = "$merged" ] \
    || fail "a later resolution overwrote the captured head (got $(meta_get capture stage_landed_head))"

  # Nothing resolves at all now. Unresolved must never erase a captured head.
  sed "s|^worktree=.*|worktree=$TMP_ROOT/gone-capture-wt|" "$STATE/capture.meta" > "$TMP_ROOT/capture.rw"
  mv "$TMP_ROOT/capture.rw" "$STATE/capture.meta"
  out=$("$STAGE" capture landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-run with no evidence at all: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" "an unresolvable re-run must leave the record alone"
  [ "$(meta_get capture stage_landed_head)" = "$merged" ] \
    || fail "unresolved erased the captured head (got '$(meta_get capture stage_landed_head)')"
  [ "$(status_stage_field "$(last_line capture)" reason)" = "landed-head:pr-head" ] \
    || fail "the captured provenance must survive an unresolvable re-run"
  out=$("$STAGE" capture show 2>&1)
  assert_contains "$out" "landed_head=${merged:0:12}" "show still reports the captured head"

  # A forge head off the candidate lineage is not evidence at all: it is a
  # different history, not a later one, and coming from the forge does not make
  # it usable.
  captured=$(meta_get capture stage_landed_head)
  git -C "$wt" checkout -q -b fm/capture-fork "$(git -C "$wt" rev-list --max-parents=0 HEAD | tail -1)"
  git -C "$wt" commit -q --allow-empty -m 'unrelated lineage'
  sed "s|^worktree=.*|worktree=$wt|" "$STATE/capture.meta" > "$TMP_ROOT/capture.rw2"
  mv "$TMP_ROOT/capture.rw2" "$STATE/capture.meta"
  printf 'pr_head=%s\n' "$(git -C "$wt" rev-parse HEAD)" >> "$STATE/capture.meta"
  out=$("$STAGE" capture landing 2>&1); rc=$?
  expect_code 0 "$rc" "a re-run on an unrelated lineage: $out"
  assert_contains "$out" "STAGE_UNCHANGED: landing" "an off-lineage head must leave the record alone"
  [ "$(meta_get capture stage_landed_head)" = "$captured" ] \
    || fail "an off-lineage head displaced the captured one (got $(meta_get capture stage_landed_head))"
  [ "$(meta_get capture stage_landed_head_source)" = pr-head ] \
    || fail "the captured provenance must survive every refused re-run"
  pass "fm-stage landing: a captured landed head survives every weaker, unresolvable, or off-lineage re-run"
}

# A commit present ONLY on the local integration branch confirms. That is the
# case a stale origin ref used to block: a local-only landing never pushes -
# bin/fm-merge-local.sh fast-forwards refs/heads/<default> in the project clone
# and nothing else - so refs/remotes/origin/<default> stays behind it forever.
# Asking only the ref that happens to EXIST let that stale remote ref answer for
# the branch that actually landed the work, and every local-only task refused
# NO_READBACK with no way through.
test_a_local_only_landing_is_confirmed_from_the_local_branch() {
  local out rc wt project landed
  wt="$TMP_ROOT/wt-localonly"
  project="$TMP_ROOT/project-localonly"
  make_worktree "$wt" fm/localonly
  make_task localonly local-only "$wt"
  FM_FAKE_AXI_STATUS=""
  out=$("$STAGE" localonly committed 2>&1); rc=$?
  expect_code 0 "$rc" "candidate admits: $out"
  landed=$(git -C "$wt" rev-parse HEAD)
  out=$("$STAGE" localonly landing 2>&1); rc=$?
  expect_code 0 "$rc" "landing captures the worktree head: $out"
  [ "$(meta_get localonly stage_landed_head)" = "$landed" ] || fail "the landed head was not captured"

  # The clone has an origin remote whose tracking ref is behind, which is
  # exactly the state a local merge leaves: the work is on refs/heads/main and
  # was never pushed.
  git clone -q --no-local "$wt" "$project" 2>/dev/null || fail "could not build the project clone"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$project" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse main)"
  git -C "$project" update-ref refs/heads/main "$landed"
  git -C "$project" merge-base --is-ancestor "$landed" "$(git -C "$project" rev-parse refs/remotes/origin/main)" \
    && fail "the fixture must leave the remote-tracking ref behind the landed head"
  sed "s|^project=.*|project=$project|" "$STATE/localonly.meta" > "$TMP_ROOT/lo.rw"
  mv "$TMP_ROOT/lo.rw" "$STATE/localonly.meta"

  out=$("$STAGE" localonly activated 2>&1); rc=$?
  expect_code 0 "$rc" "a local-only landing must be able to activate: $out"
  assert_not_contains "$out" "NO_READBACK" "a stale remote ref must not refuse a local-only landing"
  [ "$(meta_get localonly stage_landed_head_confirmed)" = confirmed ] \
    || fail "the local integration branch proves the landed head (got '$(meta_get localonly stage_landed_head_confirmed)')"
  [ "$(status_stage_field "$(last_line localonly)" reason)" = "ancestor-of:${landed:0:12}:landed-head:${landed:0:12}" ] \
    || fail "the read-back must name the ref that proved it (got $(status_stage_field "$(last_line localonly)" reason))"
  pass "fm-stage activated: a local-only landing is confirmed from the local integration branch a stale remote ref would have shadowed"
}

# A guard that cannot read the bytes has not proven the record clean. Read
# failure is its own answer and never a pass, at the stage preflight and at the
# publication boundary alike.
test_an_unreadable_record_is_refused_not_assumed_clean() {
  local out rc stub wt
  wt="$TMP_ROOT/wt-unreadable"
  make_worktree "$wt" fm/unreadable
  make_task unreadable no-mistakes "$wt"
  stub="$TMP_ROOT/blind-bin"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/awk"
  chmod +x "$stub/awk"

  out=$(PATH="$stub:$PATH" "$STAGE" unreadable show 2>&1); rc=$?
  expect_code 2 "$rc" "show must refuse a record it cannot read: $out"
  assert_contains "$out" "could not be read" "the refusal must say the record was unreadable"
  assert_not_contains "$out" "STAGE_RECORDED" "an unreadable record must report no stage"
  out=$(PATH="$stub:$PATH" "$STAGE" unreadable landing 2>&1); rc=$?
  expect_code 2 "$rc" "a transition must refuse a record it cannot read: $out"
  [ "$(status_line_stage "$(last_line unreadable)")" != landing ] \
    || fail "the refused transition recorded a receipt"

  # The publication boundary refuses for the same reason, so an unreadable
  # staged record cannot become the published one.
  cp "$STATE/unreadable.meta" "$STATE/.unreadable.staged"
  out=$(
    PATH="$stub:$PATH"
    if fm_backlog_atomic_transition publish "$STATE/.unreadable.staged" "$STATE/unreadable.meta" "task record" "$STATE"; then
      printf 'PUBLISHED'
    else
      printf 'REFUSED:%s' "$FM_BACKLOG_TRANSITION_ERROR"
    fi
  )
  case "$out" in
    REFUSED:*could\ not\ be\ read*) ;;
    *) fail "publication treated an unreadable record as clean (got: $out)" ;;
  esac
  [ -f "$STATE/.unreadable.staged" ] || fail "the refused publication must not have moved the staged record"
  rm -f "$STATE/.unreadable.staged"

  # Readable again, everything reads again.
  out=$("$STAGE" unreadable show 2>&1); rc=$?
  expect_code 0 "$rc" "the readable record reads again: $out"
  pass "fm-stage record: an unreadable record refuses at the stage preflight and at the publication boundary instead of passing as clean"
}

# The shared partial writer publishes the record it was handed, not a wider one.
# bin/fm-pr-check.sh establishes and validates 0600 for this exact file, so a
# partial write that relaxed the mode would quietly widen a private record.
test_meta_replace_preserves_the_record_mode_and_contract() {
  local meta out rc
  meta="$STATE/modecheck.meta"
  fm_write_meta "$meta" "window=fm-modecheck" "spawn_gen=s1.1.1" "decisions_reviewed=0"
  chmod 600 "$meta"
  FM_BACKLOG_TRANSITION_ERROR=
  fm_meta_replace "$meta" "$STATE" "decisions_reviewed=1" "decision_keys=a,b" \
    || fail "a partial write of a well-formed record failed ($FM_BACKLOG_TRANSITION_ERROR)"
  [ "$(fm_pr_file_mode "$meta")" = 600 ] \
    || fail "the partial write widened the record to $(fm_pr_file_mode "$meta")"
  # The mode comes from the RECORD, not from a constant this writer prefers, so
  # a record established wider stays exactly as wide.
  chmod 640 "$meta"
  fm_meta_replace "$meta" "$STATE" "decisions_reviewed=1" \
    || fail "a second partial write failed ($FM_BACKLOG_TRANSITION_ERROR)"
  [ "$(fm_pr_file_mode "$meta")" = 640 ] \
    || fail "the partial write did not keep the record's own mode (got $(fm_pr_file_mode "$meta"))"
  chmod 600 "$meta"
  [ "$(fm_meta_get "$meta" decisions_reviewed)" = 1 ] || fail "the replaced value was not recorded"
  [ "$(fm_meta_get "$meta" decision_keys)" = "a,b" ] || fail "the appended value was not recorded"
  [ "$(fm_meta_get "$meta" window)" = "fm-modecheck" ] || fail "an unnamed field was dropped"
  [ "$(grep -c '^decisions_reviewed=' "$meta")" = 1 ] || fail "the replaced key was shadowed"

  # An absent key is absent, not present-and-empty: the reader's stated contract
  # is what the next caller will use to tell those apart.
  fm_classify_meta_value "$meta" nosuchkey >/dev/null \
    && fail "the classifier reader reported a value for a key the record does not hold"
  [ "$(fm_classify_meta_value "$meta" window)" = "fm-modecheck" ] \
    || fail "the classifier reader must still read a key the record does hold"
  out=$(fm_meta_replace "$meta" "$STATE" "not-a-field" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed field was accepted: $out"
  [ "$(fm_pr_file_mode "$meta")" = 600 ] || fail "a refused partial write disturbed the record mode"
  pass "fm-backlog-transition: a partial task-record write keeps the record's own mode and its single-valued shape"
}

test_a_record_cannot_hold_two_values_for_one_key
test_landing_names_the_head_that_landed
test_nothing_displaces_a_captured_landed_head
test_recorded_forge_head_must_be_on_the_candidate_lineage
test_a_captured_landed_head_never_regresses
test_an_unresolved_capture_is_a_decision_not_a_blank
test_activation_names_an_unconfirmed_landed_head_instead_of_refusing
test_a_confirmed_landed_head_is_never_downgraded
test_a_local_only_landing_is_confirmed_from_the_local_branch
test_an_unreadable_record_is_refused_not_assumed_clean
test_meta_replace_preserves_the_record_mode_and_contract
