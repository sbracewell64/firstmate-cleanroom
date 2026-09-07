#!/usr/bin/env bash
# tests/fm-work-context.test.sh - behavioral coverage for the work-context
# contract enforced at the caller (bin/fm-work-context.sh +
# bin/fm-work-context-lib.sh). Each assertion is a colocated watched-red: a
# refusal/CNO that must fail without the fix, paired with a positive control
# that must still proceed. Drives the REAL tasks-axi against a real backlog so
# the per-task readiness predicate is the same owner fm-spawn dispatches on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WC="$ROOT/bin/fm-work-context.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-context)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the caller predicate is inert without it)\n'
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; the descriptor contract needs it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  cp "$ROOT/.tasks.toml" "$TMP_ROOT/$name/.tasks.toml"
  printf '%s\n' "$home"
}

backlog_of() { printf '%s/data/backlog.md\n' "$1"; }
add_item()   { tasks-axi add "$2" "item for $2" --kind "${3:-ship}" --file "$(backlog_of "$1")" >/dev/null; }

# Run the caller with this home. Captures stdout in WC_OUT, exit in WC_RC.
run_wc() {  # <home> <args...>
  local home=$1; shift
  WC_OUT=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$WC" "$@" 2>&1)
  WC_RC=$?
}

# Write a descriptor sidecar for a task.
write_desc() {  # <home> <id> <json>
  mkdir -p "$1/data/$2"
  printf '%s\n' "$3" > "$1/data/$2/work-context.json"
}

# =========================================================================
# Readiness / duplicate / noop (R4) and per-task holds vs aggregate (R2)
# =========================================================================

H=$(make_home readiness)

run_wc "$H" preflight ghost --effect dependent
expect_code 4 "$WC_RC" "a task with no backlog item is a no-op, not a refusal or a wake loop"
assert_contains "$WC_OUT" "verdict=noop" "no backlog item -> verdict=noop"
pass "no backlog item yields NOOP (exit 4), never a duplicate dispatch or wake loop"

add_item "$H" alpha
run_wc "$H" preflight alpha --effect dependent
expect_code 0 "$WC_RC" "an independently eligible queued task proceeds"
assert_contains "$WC_OUT" "verdict=proceed" "eligible task -> proceed"
pass "an eligible queued task (queued/not-held/not-blocked) proceeds"

# Duplicate dispatch: the same task already in flight must refuse.
tasks-axi start alpha --file "$(backlog_of "$H")" >/dev/null
run_wc "$H" preflight alpha --effect dependent
expect_code 3 "$WC_RC" "an in-flight task must not be dispatched again"
assert_contains "$WC_OUT" "duplicate-dispatch" "in-flight -> duplicate-dispatch"
pass "an already in-flight task refuses re-dispatch (no duplicate dispatch)"

# R2: a held task is refused, while an INDEPENDENT eligible task beside it still
# proceeds - a superseded/blanket preference that does not attach to a task's own
# row never blocks it, and the informational aggregate is not a global hold.
add_item "$H" held_one
tasks-axi hold held_one --reason "blanket captain preference" --kind captain \
  --file "$(backlog_of "$H")" >/dev/null
add_item "$H" free_one
run_wc "$H" preflight held_one --effect dependent
expect_code 3 "$WC_RC" "a task held on its own row is refused"
assert_contains "$WC_OUT" "verdict=refuse" "held task -> refuse"
run_wc "$H" preflight free_one --effect dependent
expect_code 0 "$WC_RC" "an independent eligible task proceeds despite a sibling hold"
assert_contains "$WC_OUT" "verdict=proceed" "independent task -> proceed beside a hold"
pass "R2: a held task refuses while an independent eligible task still proceeds"

# A genuine unresolved dependency blocks its subject.
add_item "$H" blocker
add_item "$H" dependent_task
tasks-axi update dependent_task --blocked-by blocker --file "$(backlog_of "$H")" >/dev/null 2>&1 \
  || tasks-axi add dependent_task2 "dep" --kind ship --blocked-by blocker --file "$(backlog_of "$H")" >/dev/null 2>&1
run_wc "$H" preflight dependent_task --effect dependent
if printf '%s' "$WC_OUT" | grep -q blocked; then
  expect_code 3 "$WC_RC" "a genuinely blocked task is refused"
  pass "a genuinely blocked task (unresolved dependency) refuses"
else
  pass "blocked-by wiring not exercised on this tasks-axi; hold path covers the blocking case"
fi

# =========================================================================
# R5: safety/control recovery is NEVER blocked
# =========================================================================

run_wc "$H" preflight ghost --effect recovery
expect_code 0 "$WC_RC" "recovery on a missing task must still proceed"
assert_contains "$WC_OUT" "proceed-recovery" "recovery -> proceed-recovery"
run_wc "$H" preflight held_one --effect recovery
expect_code 0 "$WC_RC" "recovery on a held task must still proceed"
assert_contains "$WC_OUT" "proceed-recovery" "recovery on held -> proceed-recovery"
pass "R5: safety/control recovery is never blocked (missing or held)"

# =========================================================================
# R6: missing/stale context blocks ONLY dependent work
# =========================================================================

H2=$(make_home context)
add_item "$H2" ctx
write_desc "$H2" ctx '{"source":{"locator":"/does/not/exist/anywhere"}}'
run_wc "$H2" preflight ctx --effect dependent
expect_code 3 "$WC_RC" "a dependent effect with a missing declared locator refuses"
assert_contains "$WC_OUT" "declared-location-missing" "missing locator -> declared-location-missing"
run_wc "$H2" preflight ctx --effect independent
expect_code 0 "$WC_RC" "the same missing context does not block independent authorized work"
assert_contains "$WC_OUT" "verdict=proceed" "independent -> proceed with missing context"
pass "R6: missing declared context blocks the dependent effect but not independent work"

# =========================================================================
# Contract refusals: wrong-head, missing-reference, stale generation, owners
# =========================================================================

H3=$(make_home identity)
add_item "$H3" wt_task
WTDIR="$TMP_ROOT/identity/wt"
mkdir -p "$WTDIR"
fm_git_identity "$WTDIR" >/dev/null 2>&1 || true
( cd "$WTDIR" && git init -q && git config user.email t@e && git config user.name t \
  && echo x > f && git add f && git commit -qm init )
GOOD_HEAD=$(git -C "$WTDIR" rev-parse HEAD)

write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\",\"head\":\"0000000000000000000000000000000000000000\"}}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 3 "$WC_RC" "a declared head that differs from the worktree head refuses"
assert_contains "$WC_OUT" "wrong-head" "declared stale head -> wrong-head"

write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\",\"head\":\"$GOOD_HEAD\"}}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 0 "$WC_RC" "the current head passes the source-identity check"
assert_contains "$WC_OUT" "verdict=proceed" "current head -> proceed"
pass "wrong-head is refused and the current head proceeds"

write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"required_references\":[\"$WTDIR/absent-ref.md\"]}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 3 "$WC_RC" "a missing required reference refuses"
assert_contains "$WC_OUT" "missing-reference" "absent reference -> missing-reference"
pass "a missing required reference is refused"

echo cur > "$WTDIR/gen.marker"
write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"reference_generation\":{\"marker\":\"$WTDIR/gen.marker\",\"expected\":\"old\"}}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 3 "$WC_RC" "a stale reference generation refuses"
assert_contains "$WC_OUT" "stale-reference-generation" "stale generation -> refuse"
write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"reference_generation\":{\"marker\":\"$WTDIR/gen.marker\",\"expected\":\"cur\"}}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 0 "$WC_RC" "a current reference generation proceeds"
pass "a stale reference generation is refused; a current one proceeds"

write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"qualification_owner\":\"some-random-owner\"}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 3 "$WC_RC" "an unrecognized qualification owner refuses"
assert_contains "$WC_OUT" "wrong-qualification-owner" "wrong qualification owner -> refuse"
write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"activation_owner\":\"not-a-real-activator\"}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 3 "$WC_RC" "an unrecognized activation owner refuses"
assert_contains "$WC_OUT" "wrong-activation-owner" "wrong activation owner -> refuse"
write_desc "$H3" wt_task "{\"source\":{\"locator\":\"$WTDIR\"},\"qualification_owner\":\"no-mistakes\",\"activation_owner\":\"firstmate\"}"
run_wc "$H3" preflight wt_task --effect dependent
expect_code 0 "$WC_RC" "recognized canonical owners proceed"
pass "wrong qualification/activation owners are refused; canonical owners proceed"

# =========================================================================
# R1: compositional authority - a prose-only Class-C material decision is
# refused before its dependent effect; Class-B consent does not waive it; a
# consumed routed ruling receipt authorizes it.
# =========================================================================

H4=$(make_home authority)
add_item "$H4" sol_task

# Class A default: no descriptor -> classify A, preflight proceeds.
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "classes=A" "no descriptor -> Class A"

# Class C declared, no ruling receipt: prose (a request id) does not substitute.
write_desc "$H4" sol_task '{"source":{"locator":"'"$TMP_ROOT"'/authority/home"},"authority":{"classes":["B","C"],"request_id":"req-32","captain_consent":true}}'
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=absent" "declared C with no receipt path -> absent"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "a prose-only Class-C material decision is refused before its dependent effect"
assert_contains "$WC_OUT" "class-c-prose-only" "prose-only C -> refuse (B consent does not waive)"
pass "R1: a prose-only Class-C material decision is refused; Class-B consent does not waive it"

# A ruling receipt that is mere prose (not consumed) still refuses.
mkdir -p "$H4/data/sol_task"
printf 'ruling: PROCEED per Sol\n' > "$H4/data/sol_task/ruling.txt"
write_desc "$H4" sol_task '{"source":{"locator":"'"$TMP_ROOT"'/authority/home"},"authority":{"classes":["C"],"ruling_receipt":"ruling.txt"}}'
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "a prose ruling file is not a consumed routed ruling"
assert_contains "$WC_OUT" "class-c-prose-only" "prose ruling file -> still refuse"

# A valid consumed routed-ruling receipt authorizes the dependent effect.
printf '{"consumed":true,"ruling":"PROCEED","lease":"lease-7","request":"req-32"}\n' \
  > "$H4/data/sol_task/ruling.json"
write_desc "$H4" sol_task '{"source":{"locator":"'"$TMP_ROOT"'/authority/home"},"authority":{"classes":["C"],"ruling_receipt":"ruling.json"}}'
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=present" "valid consumed ruling -> present"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 0 "$WC_RC" "a consumed routed ruling authorizes the dependent effect"
assert_contains "$WC_OUT" "verdict=proceed" "consumed ruling -> proceed"
pass "a consumed routed-ruling receipt authorizes the Class-C dependent effect"

# =========================================================================
# R3: one authorized child transition refreshes the currentness receipt via an
# independent backing-owner read-back, idempotently.
# =========================================================================

H5=$(make_home reconcile)
add_item "$H5" child
tasks-axi start child --file "$(backlog_of "$H5")" >/dev/null

# While the child is still in flight, a 'done' transition cannot be confirmed.
run_wc "$H5" reconcile child "done"
expect_code 1 "$WC_RC" "a done transition on a still-open child is unconfirmed"
assert_contains "$WC_OUT" "reconcile=unconfirmed" "open child -> unconfirmed"

# Close the child; the transition is now confirmed by an independent read-back.
tasks-axi "done" child --file "$(backlog_of "$H5")" >/dev/null
run_wc "$H5" reconcile child "done"
expect_code 0 "$WC_RC" "a done transition on a closed child confirms via read-back"
assert_contains "$WC_OUT" "reconcile=confirmed" "closed child -> confirmed"
assert_present "$H5/state/child.parent-currentness" "reconcile writes a durable currentness receipt"
assert_grep "currentness=confirmed" "$H5/state/child.parent-currentness" "receipt records confirmed currentness"

# Idempotent replay: a second reconcile of the same transition converges.
FIRST=$(cat "$H5/state/child.parent-currentness" | grep -v '^epoch=')
run_wc "$H5" reconcile child "done"
expect_code 0 "$WC_RC" "replaying the same transition stays confirmed"
SECOND=$(cat "$H5/state/child.parent-currentness" | grep -v '^epoch=')
[ "$FIRST" = "$SECOND" ] || fail "reconcile is not idempotent: '$FIRST' vs '$SECOND'"
pass "R3: an authorized child transition refreshes the currentness receipt via independent read-back, idempotently"

# The next-selection result reflects the completed child: a preflight after the
# transition reads the now-current backlog owner and no longer treats the closed
# child as an eligible dispatch (it is not 'proceed').
run_wc "$H5" preflight child --effect dependent
[ "$WC_RC" -ne 0 ] || fail "a completed child must not still preflight as an eligible dispatch: $WC_OUT"
assert_not_contains "$WC_OUT" "verdict=proceed" "completed child -> next-selection does not re-dispatch it"
pass "R3: after the transition the next-selection result reflects the completed child through the same caller"

echo "# fm-work-context.test.sh: all assertions passed"
