#!/usr/bin/env bash
# Behavior tests for the work-context authority gate WIRED into bin/fm-spawn.sh
# (the defect-5 caller integration). These prove the gate is real dispatch
# enforcement, not a manually-invoked helper: a Class-C op whose authoritative
# binding carries no consumed routed ruling is refused BEFORE any endpoint,
# worktree, or record exists, while an ordinary op and an authorized Class-C op
# both spawn unchanged. They drive fm-spawn through a fake tmux pane and a real
# isolated git worktree, exactly like the dispatch-profile suite.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-work-context-gate)

command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; the descriptor contract needs it)\n'
  exit 0
}

# Build a spawn case: a claude home, a real worktree, a fakebin, and a brief.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_ship_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

write_desc() {  # <home> <id> <json>
  mkdir -p "$1/data/$2"
  printf '%s\n' "$3" > "$1/data/$2/work-context.json"
}

# --- 1. an ordinary (Class A) op is unaffected: the gate is inert -----------

ID=wcgate-ok-z1
REC=$(make_case wcgate-ok "$ID"); read_case "$REC"
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
STATUS=$?
expect_code 0 "$STATUS" "an ordinary op with no Class-C binding spawns normally (gate inert)"
assert_contains "$OUT" "spawned $ID" "ordinary spawn still reports success"
assert_present "$HOME_DIR/state/$ID.meta" "ordinary spawn writes its meta"
pass "the work-context authority gate is inert for an ordinary Class-A op"

# --- 2. a Class-C op with NO ruling is refused BEFORE any record ------------

ID=wcgate-neg-z2
REC=$(make_case wcgate-neg "$ID"); read_case "$REC"
write_desc "$HOME_DIR" "$ID" '{"authority":{"classes":["C"],"request_id":"req-1","captain_consent":true}}'
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
STATUS=$?
expect_code 1 "$STATUS" "a Class-C op with no consumed ruling must be refused before dispatch"
assert_contains "$OUT" "work-context authority gate" "the refusal names the work-context authority gate"
assert_contains "$OUT" "class-c-authority" "the refusal is the typed Class-C authority condition"
assert_absent "$HOME_DIR/state/$ID.meta" "the Class-C refusal happens before any meta/endpoint is written"
[ ! -s "$LAUNCH_LOG" ] || fail "the refused Class-C op must not launch a worker"
pass "defect 5: a Class-C op without a consumed ruling is refused at the dispatch seam before any record"

# --- 3. an authorized Class-C op (consumed subject-bound ruling) spawns ------

ID=wcgate-pos-z3
REC=$(make_case wcgate-pos "$ID"); read_case "$REC"
mkdir -p "$HOME_DIR/data/$ID"
printf '{"consumed":true,"outcome":"PROCEED","subject":"%s","lease":"l-1","request":"req-1","generation":"g-1"}\n' "$ID" \
  > "$HOME_DIR/data/$ID/ruling.json"
write_desc "$HOME_DIR" "$ID" '{"authority":{"classes":["C"],"ruling_receipt":"ruling.json"}}'
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
STATUS=$?
expect_code 0 "$STATUS" "an authorized Class-C op spawns past the gate"
assert_contains "$OUT" "spawned $ID" "authorized Class-C spawn reports success"
assert_present "$HOME_DIR/state/$ID.meta" "authorized Class-C spawn writes its meta"
pass "defect 5: a consumed, subject-bound routed ruling lets an authorized Class-C op spawn"

echo "# fm-spawn-work-context-gate.test.sh: all assertions passed"
