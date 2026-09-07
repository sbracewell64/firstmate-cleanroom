#!/usr/bin/env bash
# Tests for bin/fm-nm-assess.sh, the continual per-run two-level assessment
# owner that sits on top of the NMF-OBS-1 observation obligation.
#
# Regression origin (2026-09-07, no-mistakes friction programme NMF-OBS-2):
# a landed run carried an observation obligation but no durable assessment, so
# the immediate boundary (what actually failed or blocked, what executed vs
# never started, the carried residual finding, the next owner) and the one
# owner level above it were never recorded, finding recurrence was invisible,
# a provider-capacity block was indistinguishable from a candidate repair
# failure, a late merge could be missed because a run record cached pr_state
# OPEN, and nothing mechanically enforced that every launch is observed, every
# assessment disposed, and every remediation owned.
#
# These cases pin the assessment over isolated fixtures: a real throwaway git
# worktree, an NMF-OBS-1 obligation record written by hand in the exact
# fm-nm-observation/v1 shape the landed owner produces, a fake `no-mistakes`
# that serves only read-only `axi status --run` and logs every argv, and a
# merge-notification marker in bin/fm-pr-lib.sh's exact shape. No case starts,
# answers, aborts, or reruns a pipeline or approves a gate, and the closing
# cases prove the observer sent no mutating verb and manufactured no PASS.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSESS="$ROOT/bin/fm-nm-assess.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-assess)
fm_git_identity fmtest fmtest@example.invalid

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NM_LOG="$TMP_ROOT/no-mistakes.argv"
: > "$NM_LOG"

# The fake no-mistakes serves exactly the one read-only read the assessor is
# allowed to make and records every argv so the negative case can prove no
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
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_NM_LOG="$NM_LOG"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
export FM_NM_OBSERVE_TIMEOUT=5
# Exported once; each case reassigns it (a reassignment stays exported and
# avoids masking the command-substitution return value).
export FM_FAKE_AXI_STATUS_RUN=""

# A single-run TOON block shaped like the installed CLI's `axi status --run`.
axi_run_toon() {  # <id> <branch> <status> <head> <outcome> [pr]
  printf 'current_branch: %s\n' "$2"
  printf 'other_branch_run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: %s\n  pr: "%s"\n' "$1" "$2" "$3" "$4" "${6:-}"
  printf '  steps[1]{step,status,findings,duration_ms}:\n    intent,completed,0,9\n'
  [ -z "$5" ] || printf 'outcome: %s\n' "$5"
}

make_worktree() {  # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" checkout -q -b "$2"
}

make_task() {  # <id> <worktree>
  fm_write_meta "$STATE/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$2" "project=$2" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
}

# Write an NMF-OBS-1 obligation record in the exact landed shape.
write_obligation() {  # <id> <stage> <k=v>...
  local id=$1 stage=$2 f
  shift 2
  f="$STATE/$id.nm-observe"
  {
    printf 'record=fm-nm-observation/v1\n'
    printf 'task=%s\n' "$id"
    printf 'home=%s\n' "$HOME_DIR"
    printf 'project=%s\n' "$WT"
    printf 'repo_remote=git@example:proj.git\n'
    printf 'entrypoint=stage\n'
    printf 'stage=%s\n' "$stage"
    printf 'attempt_id=att-%s\n' "$id"
    printf 'candidate_branch=fm/%s\n' "$id"
    printf 'candidate_head=%s\n' "$HEAD"
    printf 'nm_version=1.61.0\n'
    printf 'nm_build=0af0be6\n'
    printf 'daemon_epoch=4242@2026-09-06T00:00:00Z\n'
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$f"
}

record_get() { grep "^$2=" "$1" | tail -1 | cut -d= -f2-; }
assess_get() { grep "^$2=" "$STATE/$1.nm-assessment" | tail -1 | cut -d= -f2-; }

# Count / pick the first path matching a glob without ls (SC2012-clean).
count_glob() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }
first_glob() { local f; for f in "$@"; do [ -e "$f" ] && { printf '%s' "$f"; return 0; }; done; }

WT="$TMP_ROOT/wt"
make_worktree "$WT" fm/t1
HEAD=$(git -C "$WT" rev-parse HEAD)

# --- both levels + identity, from a bound run's canonical read ------------------

make_task t1 "$WT"
write_obligation t1 run-bound \
  "run_id=01RUN" "run_branch=fm/t1" "run_head=$HEAD" \
  "run_status=running" "run_outcome=" "outcome_class=active" "outcome_epoch=1000"
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon 01RUN fm/t1 running "$HEAD" "" "")
out=$("$ASSESS" assess t1 2>&1); rc=$?
expect_code 0 "$rc" "assess a bound run"
assert_contains "$out" "NM_ASSESS: ASSESSED task=t1" "assess prints the typed line"
RECEIPT="$DATA/t1/nm-assessment-receipt.md"
assert_present "$RECEIPT" "receipt rendered"
assert_grep "## Immediate boundary" "$RECEIPT" "receipt carries the immediate boundary"
assert_grep "## One owner level above" "$RECEIPT" "receipt carries the owner level above"
assert_grep "run: 01RUN (branch fm/t1" "$RECEIPT" "receipt carries the run identity envelope"
assert_grep "no anomaly within measured coverage" "$RECEIPT" "a clean run reports no anomaly above"
[ "$(assess_get t1 disposition)" = no-actionable-anomaly ] || fail "clean run disposition"
[ "$(assess_get t1 imm_run)" = 01RUN ] || fail "immediate boundary run identity"
pass "assess: per-run receipt carries both levels and the run identity envelope"

# --- provider-capacity: typed / paused / budget-separate / unknown-cost ---------

make_task pc "$WT"
write_obligation pc run-bound \
  "run_id=02RUN" "run_branch=fm/pc" "run_head=$HEAD" \
  "run_status=running" "run_outcome=" "outcome_class=active" "outcome_epoch=1000"
out=$("$ASSESS" assess pc --no-query --provider-capacity "out of usage credits" \
  --repair-attempts 3 --gate ci 2>&1); rc=$?
expect_code 0 "$rc" "assess a provider-capacity block"
assert_contains "$out" "disposition=linked-existing-repair" "provider-capacity routes to an existing repair"
[ "$(assess_get pc provider_capacity)" = "out of usage credits" ] || fail "typed provider condition recorded"
[ "$(assess_get pc provider_completed_repair)" = false ] || fail "no completed repair"
[ "$(assess_get pc provider_attempts)" = 3 ] || fail "real invocation attempts preserved"
[ "$(assess_get pc provider_usage_cost)" = unknown ] || fail "unknown usage cost, never fabricated"
[ "$(assess_get pc gate_paused)" = ci ] || fail "affected gate paused"
[ "$(assess_get pc transition)" = stall ] || fail "provider-capacity is a stall transition"
RPC="$DATA/pc/nm-assessment-receipt.md"
assert_grep "typed external resource-blocked condition" "$RPC" "provider-capacity typed"
assert_grep "budgeted separately from candidate repair attempts" "$RPC" "budget is separate"
assert_grep "UNKNOWN is never fabricated to zero" "$RPC" "unknown cost stated"
# A usage cost of literal zero is treated as unknown, never as a real zero.
"$ASSESS" assess pc --no-query --provider-capacity "out of usage credits" --usage-cost 0 --gate ci >/dev/null 2>&1
[ "$(assess_get pc provider_usage_cost)" = unknown ] || fail "a zero usage cost is not trusted as measured zero"
pass "assess: provider-capacity is typed, paused, budget-separate, and never fabricates zero cost"

# --- finding families: dedup by owner+invariant+family+applicability, attach -----

FAMDIR="$DATA/nm-finding-families"
famfile=$(first_glob "$FAMDIR"/provider-capacity-*)
[ -n "$famfile" ] || fail "provider-capacity family recorded"
[ "$(grep -c '^occurrence' "$famfile")" = 1 ] || fail "one occurrence for pc so far (re-assess must not duplicate): $(grep -c '^occurrence' "$famfile")"
# A second task hitting the same profile-scoped condition attaches a new
# occurrence to the SAME family without losing the first.
make_task pc2 "$WT"
write_obligation pc2 run-bound \
  "run_id=03RUN" "run_branch=fm/pc2" "run_head=$HEAD" \
  "run_status=running" "outcome_class=active" "outcome_epoch=1000"
"$ASSESS" assess pc2 --no-query --provider-capacity "out of usage credits" --repair-attempts 1 --gate review >/dev/null 2>&1
[ "$(count_glob "$FAMDIR"/provider-capacity-*)" = 1 ] || fail "same family, not a new one"
[ "$(grep -c '^occurrence' "$famfile")" = 2 ] || fail "the second occurrence attached; history preserved: $(grep -c '^occurrence' "$famfile")"
grep -q $'\t01RUN\t\|\t02RUN\t' "$famfile" || true
grep -q '02RUN' "$famfile" || fail "first occurrence (pc/02RUN) still present"
grep -q '03RUN' "$famfile" || fail "second occurrence (pc2/03RUN) present"
fam=$("$ASSESS" families 2>&1)
assert_contains "$fam" "FAMILY key=provider-capacity-" "families lists the family"
assert_contains "$fam" "occurrence epoch=" "families lists occurrences"
# A profile-scoped difference is a DIFFERENT family (dedup dimension).
make_task pc3 "$WT"
write_obligation pc3 run-bound \
  "run_id=04RUN" "run_branch=fm/pc3" "run_head=$HEAD" "outcome_class=active" "outcome_epoch=1000" \
  "nm_version=1.64.0" "nm_build=deadbee"
sed -i 's/^nm_version=1.61.0/nm_version=1.64.0/; s/^nm_build=0af0be6/nm_build=deadbee/' "$STATE/pc3.nm-observe"
"$ASSESS" assess pc3 --no-query --provider-capacity "out of usage credits" --gate ci >/dev/null 2>&1
[ "$(count_glob "$FAMDIR"/provider-capacity-*)" = 2 ] || fail "a different profile applicability is a different family"
pass "assess: finding families dedup by dimensions and attach later occurrences without loss"

# --- late-merge: cached pr_state OPEN reconciled to canonical merged ------------

make_task lm "$WT"
write_obligation lm run-bound \
  "run_id=05RUN" "run_branch=fm/lm" "run_head=$HEAD" \
  "run_status=completed" "run_outcome=passed" "outcome_class=successful" "outcome_epoch=2000" \
  "pr=https://github.com/x/y/pull/12"
# The daemon's own run record still reports the PR (cached OPEN) after the merge.
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon 05RUN fm/lm completed "$HEAD" passed "https://github.com/x/y/pull/12")
# Provider/canonical truth: the merge-notification marker bin/fm-pr-lib.sh writes.
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nx/y\n12\n' > "$STATE/lm.pr-poll-merge-notified"
out=$("$ASSESS" assess lm 2>&1); rc=$?
expect_code 0 "$rc" "assess a late merge"
[ "$(assess_get lm reconciled_publication)" = "merged:github:github.com:x/y:12" ] || fail "terminal reconciled to canonical merged"
[ "$(assess_get lm cached_pr_state)" = "https://github.com/x/y/pull/12" ] || fail "the stale cached pr is recorded as untrusted"
RLM="$DATA/lm/nm-assessment-receipt.md"
assert_grep "## Late-merge reconciliation" "$RLM" "late-merge section rendered"
assert_grep "never the stale cached run record" "$RLM" "reconciliation prefers canonical over cache"
# Without a marker, no merge is fabricated.
make_task nom "$WT"
write_obligation nom run-bound "run_id=06RUN" "run_branch=fm/nom" "run_head=$HEAD" \
  "run_status=completed" "run_outcome=passed" "outcome_class=successful" "outcome_epoch=2000" \
  "pr=https://github.com/x/y/pull/13"
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon 06RUN fm/nom completed "$HEAD" passed "https://github.com/x/y/pull/13")
"$ASSESS" assess nom >/dev/null 2>&1
[ -z "$(assess_get nom reconciled_publication)" ] || fail "no marker means no fabricated merge"
pass "assess: a late merge reconciles the cached-open pr against the canonical merge marker"

# --- carried residual finding + routed check-normalization finding --------------

make_task cn "$WT"
write_obligation cn run-bound \
  "run_id=07RUN" "run_branch=fm/cn" "run_head=$HEAD" \
  "run_status=completed" "run_outcome=checks-passed" "outcome_class=ci-ready" "outcome_epoch=3000"
FM_FAKE_AXI_STATUS_RUN=$(axi_run_toon 07RUN fm/cn completed "$HEAD" checks-passed "")
out=$("$ASSESS" assess cn \
  --carried-finding nmf-remote-job-reap-race \
  --finding "nmf-observer-check-normalization:completed-is-not-success:check-normalization:rerun-on-same-head" 2>&1)
[ "$(assess_get cn imm_carried_finding)" = nmf-remote-job-reap-race ] || fail "carried residual finding recorded"
assert_grep "nmf-observer-check-normalization" "$DATA/cn/nm-assessment-receipt.md" "check-normalization finding routed to its owner"
[ "$(assess_get cn disposition)" = linked-existing-repair ] || fail "known-owner finding links an existing repair"
assert_grep "a green rerun does not close a carried finding" "$DATA/cn/nm-assessment-receipt.md" "ci-ready next owner names the carried-defect disposition rule"
pass "assess: carries a residual finding and routes a check-normalization finding to its owner"

# --- coverage enforcement -------------------------------------------------------

# Fresh home so the enforcement scan sees exactly the fixtures we plant.
CH="$TMP_ROOT/cov-home"
mkdir -p "$CH/state" "$CH/data"
cov() { FM_HOME="$CH" FM_STATE_OVERRIDE="$CH/state" FM_DATA_OVERRIDE="$CH/data" "$ASSESS" "$@"; }
# An admitted launch with no observation and no error state is a gap.
cat > "$CH/state/g1.nm-observe" <<EOF
record=fm-nm-observation/v1
task=g1
stage=launch-accepted
candidate_branch=fm/g1
EOF
out=$(cov coverage 2>&1)
assert_contains "$out" "COVERAGE_GAP task=g1" "an admitted launch with no observation is a gap"
assert_contains "$out" "no observation or explicit pending" "the gap names the missing observation"
# A bound run with no assessment is a gap.
cat > "$CH/state/g2.nm-observe" <<EOF
record=fm-nm-observation/v1
task=g2
stage=run-bound
run_id=99RUN
outcome_class=active
EOF
out=$(cov coverage 2>&1)
assert_contains "$out" "COVERAGE_GAP task=g2 reason=bound run has no assessment" "a bound run with no assessment is a gap"
# An assessment with no disposition is a gap.
printf 'record=fm-nm-assessment/v1\ntask=g3\ndisposition=\n' > "$CH/state/g3.nm-assessment"
out=$(cov coverage 2>&1)
assert_contains "$out" "COVERAGE_GAP task=g3 reason=assessment has no disposition" "an undisposed assessment is a gap"
# A finding family with no owner is a gap.
mkdir -p "$CH/data/nm-finding-families"
printf 'record=fm-nm-finding-family/v1\nfamily_key=orphan-1\nowner=unassigned\ninvariant=x\nfailure_family=other\napplicability=z\nnext_gate=n\n' > "$CH/data/nm-finding-families/orphan-1"
out=$(cov coverage 2>&1)
assert_contains "$out" "COVERAGE_GAP family=orphan-1" "a remediation with no owner is a gap"
# A clean home reports ok.
CLEAN="$TMP_ROOT/clean-home"
mkdir -p "$CLEAN/state" "$CLEAN/data"
out=$(FM_HOME="$CLEAN" FM_STATE_OVERRIDE="$CLEAN/state" FM_DATA_OVERRIDE="$CLEAN/data" "$ASSESS" coverage 2>&1)
assert_contains "$out" "COVERAGE ok" "a clean home reports coverage ok"
pass "coverage: launch-without-observation, assessment-without-disposition, remediation-without-owner all caught"

# --- negative: the observer never mutates a pipeline or manufactures a PASS -----

: > "$NM_LOG"
"$ASSESS" assess t1 >/dev/null 2>&1 || true
"$ASSESS" assess lm >/dev/null 2>&1 || true
"$ASSESS" assess pc --no-query --provider-capacity "out of usage credits" >/dev/null 2>&1 || true
"$ASSESS" coverage >/dev/null 2>&1 || true
"$ASSESS" families >/dev/null 2>&1 || true
while IFS= read -r line; do
  case "$line" in
    "axi status"|"axi status --run "*) ;;
    *) fail "assessor sent a non-read verb to no-mistakes: $line" ;;
  esac
done < "$NM_LOG"
[ -s "$NM_LOG" ] || fail "negative case checked nothing"
# The assessor never records a manufactured PASS: a disposition is one of the
# five defined values and is never a gate verdict, and the recorded state comes
# only from the canonical read (here 'active'/'successful'/'ci-ready'), never
# invented.
for d in "$STATE"/*.nm-assessment; do
  case "$(record_get "$d" disposition)" in
    handled-in-run|linked-existing-repair|bounded-owner-task|accepted-deferred-with-authority|no-actionable-anomaly) ;;
    *) fail "assessment $d carries a disposition outside the defined set: $(record_get "$d" disposition)" ;;
  esac
  case "$(record_get "$d" disposition)" in
    *PASS*|*passed*|*approved*) fail "assessment $d manufactured a PASS-like disposition" ;;
  esac
done
pass "negative: only read-only status reads were sent; no gate, merge, or manufactured PASS"

fm_test_cleanup
