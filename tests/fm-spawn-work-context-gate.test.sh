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

# --- 4. a Class-C op whose CONFIGURED canonical verifier PROCEEDs spawns ------
# The trusted authority path is consulted at the REAL dispatch seam and is
# authoritative over the local schema: the receipt here is locally INVALID
# (unconsumed DENY), yet a reachable verifier that PROCEEDs lets the op spawn.

VSTUB="$TMP_ROOT/verifier-stub.sh"
cat > "$VSTUB" <<'STUB'
#!/usr/bin/env bash
# Stub canonical verifier: it never reads the receipt schema, so a spawn here on
# a locally-invalid receipt proves the trusted path is actually consulted.
exit "${VSTUB_EXIT:-0}"
STUB
chmod +x "$VSTUB"

ID=wcgate-vok-z4
REC=$(make_case wcgate-vok "$ID"); read_case "$REC"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/config"
printf '%s\n' "$VSTUB" > "$HOME_DIR/config/work-context-ruling-verifier"
printf '{"consumed":false,"outcome":"DENY"}\n' > "$HOME_DIR/data/$ID/ruling.json"
write_desc "$HOME_DIR" "$ID" '{"authority":{"classes":["C"],"ruling_receipt":"ruling.json"}}'
OUT=$(VSTUB_EXIT=0 run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
STATUS=$?
expect_code 0 "$STATUS" "a Class-C op whose configured canonical verifier PROCEEDs spawns at the real dispatch seam"
assert_contains "$OUT" "spawned $ID" "verifier-authorized Class-C spawn reports success"
assert_present "$HOME_DIR/state/$ID.meta" "verifier-authorized Class-C spawn writes its meta"
pass "runtime adoption: a configured canonical verifier is consulted at real dispatch and is authoritative over the local schema"

# --- 5. a DECLARED-but-unreachable verifier is refused BEFORE any record ------
# The receipt is locally VALID, so without the trusted path it would authorize;
# but the operator DECLARED a canonical verifier and it is unreachable, so the
# gate fails closed rather than downgrading to the schema-shaped local proof.

ID=wcgate-vunreach-z5
REC=$(make_case wcgate-vunreach "$ID"); read_case "$REC"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/config"
printf '%s\n' "$TMP_ROOT/no-such-verifier-xyz" > "$HOME_DIR/config/work-context-ruling-verifier"
printf '{"consumed":true,"outcome":"PROCEED","subject":"%s","lease":"l-1","request":"req-1","generation":"g-1"}\n' "$ID" \
  > "$HOME_DIR/data/$ID/ruling.json"
write_desc "$HOME_DIR" "$ID" '{"authority":{"classes":["C"],"ruling_receipt":"ruling.json"}}'
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
STATUS=$?
expect_code 1 "$STATUS" "a declared-but-unreachable canonical verifier must be refused before dispatch"
assert_contains "$OUT" "verifier-unavailable" "the refusal names the unreachable trusted path, not a schema verdict"
assert_absent "$HOME_DIR/state/$ID.meta" "the trusted-path refusal happens before any meta/endpoint is written"
[ ! -s "$LAUNCH_LOG" ] || fail "the refused op must not launch a worker"
pass "finding A at the real caller: a declared-but-unreachable verifier fails closed before any record, never downgrading to the schema-shaped receipt"

echo "# fm-spawn-work-context-gate.test.sh: all assertions passed"

# Exact source and current generated context are prerequisites at the actual
# dispatcher. The fake harness is only the external process-launch boundary.
ID=wcgate-engineering-z6
REC=$(make_case wcgate-engineering "$ID"); read_case "$REC"
printf abc > "$HOME_DIR/skill.md"
write_desc "$HOME_DIR" "$ID" "{\"engineering\":{\"generation\":\"g1\",\"triggers\":[\"test-change\"],\"skills\":[{\"id\":\"tdd\",\"path\":\"$HOME_DIR/skill.md\",\"release\":\"fixture-r1\",\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\",\"role\":\"worker\",\"stage\":\"test\",\"trigger\":\"test-change\"}],\"verification\":[]}}"
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR"); STATUS=$?
expect_code 1 "$STATUS" "an old brief must not bypass current engineering delivery"
assert_contains "$OUT" 'stale-engineering-brief' "dispatch identifies the stale brief"
assert_absent "$HOME_DIR/state/$ID.meta" "stale brief created a task record"
[ ! -s "$LAUNCH_LOG" ] || fail "stale brief reached the harness"
rm "$HOME_DIR/data/$ID/brief.md"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$ID" receiver --mode no-mistakes >/dev/null || fail "real generator failed"
sed -i.bak 's/{TASK}/authorized receiver fixture/g' "$HOME_DIR/data/$ID/brief.md"
printf stale > "$HOME_DIR/skill.md"
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR"); STATUS=$?
expect_code 1 "$STATUS" "stale selected bytes must refuse actual dispatch"
assert_contains "$OUT" 'stale-skill-source' "dispatch identifies the stale skill"
assert_absent "$HOME_DIR/state/$ID.meta" "stale source created a task record"
[ ! -s "$LAUNCH_LOG" ] || fail "stale source reached the harness"
printf abc > "$HOME_DIR/skill.md"
OUT=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR"); STATUS=$?
expect_code 0 "$STATUS" "current source and generated brief dispatch: $OUT"
assert_present "$HOME_DIR/state/$ID.meta" "valid source/brief never reached actual dispatch"
pass "engineering source and fresh brief are checked by actual dispatch before endpoint effects"
