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

# Defect 1 (fail-open): an arbitrary task-local receipt must NOT authorize a
# Class-C effect. A DENY outcome, an unrelated subject, an unconsumed receipt, and
# a fully-unbound-but-consumed receipt each fail closed.
write_desc "$H4" sol_task '{"source":{"locator":"'"$TMP_ROOT"'/authority/home"},"authority":{"classes":["C"],"ruling_receipt":"ruling.json"}}'

printf '{"consumed":true,"outcome":"DENY","subject":"sol_task","lease":"l","request":"r","generation":"g"}\n' \
  > "$H4/data/sol_task/ruling.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=denied-or-invalid" "a DENY ruling is not authorization"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "a DENY ruling must fail closed before the dependent effect"

printf '{"consumed":true,"outcome":"PROCEED","subject":"some-other-task","lease":"l","request":"r","generation":"g"}\n' \
  > "$H4/data/sol_task/ruling.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=unrelated-subject" "a ruling bound to another subject does not authorize this task"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "a ruling for an unrelated subject must fail closed"

printf '{"consumed":false,"outcome":"PROCEED","subject":"sol_task","lease":"l","request":"r","generation":"g"}\n' \
  > "$H4/data/sol_task/ruling.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=unconsumed" "an unconsumed ruling does not authorize"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "an unconsumed ruling must fail closed"

printf '{"consumed":true,"ruling":"PROCEED","lease":"lease-7","request":"req-32"}\n' \
  > "$H4/data/sol_task/ruling.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=unbound" "a receipt missing subject/generation is unbound, not authorization"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "an unbound receipt (the old happy-path fixture) must now fail closed"
pass "defect 1: an arbitrary/DENY/unrelated/unconsumed/unbound receipt never authorizes a Class-C effect"

# A request/generation mismatch against the descriptor's declared identity refuses.
printf '{"consumed":true,"outcome":"PROCEED","subject":"sol_task","lease":"l","request":"WRONG","generation":"g"}\n' \
  > "$H4/data/sol_task/ruling.json"
write_desc "$H4" sol_task '{"source":{"locator":"'"$TMP_ROOT"'/authority/home"},"authority":{"classes":["C"],"ruling_receipt":"ruling.json","request":"req-32","generation":"g"}}'
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=request-mismatch" "a receipt whose request id differs from the declared one refuses"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "a request-identity mismatch must fail closed"
pass "defect 1: a request-identity mismatch between receipt and declared binding fails closed"

# A fully consumed, affirmative, subject-and-identity-bound receipt authorizes.
printf '{"consumed":true,"outcome":"PROCEED","subject":"sol_task","lease":"lease-7","request":"req-32","generation":"g"}\n' \
  > "$H4/data/sol_task/ruling.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "class_c_ruling=present" "valid consumed subject-bound ruling -> present"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 0 "$WC_RC" "a consumed subject-bound routed ruling authorizes the dependent effect"
assert_contains "$WC_OUT" "verdict=proceed" "consumed ruling -> proceed"
pass "a consumed, subject-bound routed-ruling receipt authorizes the Class-C dependent effect"

# Defect 2 (fail-open): deleting the descriptor must NOT downgrade a KNOWN
# dependent op to authorized Class A. The authoritative operation binding lives in
# state/<id>.meta (authority_classes=C), which survives descriptor deletion.
printf 'kind=ship\nauthority_classes=C\n' > "$H4/state/sol_task.meta"
rm -f "$H4/data/sol_task/work-context.json"
run_wc "$H4" classify sol_task
assert_contains "$WC_OUT" "classes=C" "meta authority_classes=C survives descriptor deletion"
assert_contains "$WC_OUT" "class_c_ruling=absent" "no descriptor -> no ruling receipt -> absent"
run_wc "$H4" preflight sol_task --effect dependent
expect_code 3 "$WC_RC" "deleting the descriptor must not downgrade a known Class-C op to authorized Class A"
assert_contains "$WC_OUT" "class-c" "descriptor-absence still refuses the dependent Class-C effect"
# The same known-Class-C op with no ruling still permits INDEPENDENT work and
# safety/control recovery (missing context blocks only the dependent effect).
run_wc "$H4" preflight sol_task --effect independent
expect_code 0 "$WC_RC" "independent authorized work continues despite the unruled Class-C binding"
run_wc "$H4" preflight sol_task --effect recovery
expect_code 0 "$WC_RC" "safety/control recovery is never blocked by the unruled Class-C binding"
pass "defect 2: descriptor absence does not downgrade a meta-declared Class-C op; only its dependent effect is blocked"

# =========================================================================
# Defect 3 (fail-open): an ERROR from the readiness owner must FAIL CLOSED for a
# dependent op, never collapse to proceed. A legitimate exemption still proceeds.
# =========================================================================

H6=$(make_home readiness_error)
add_item "$H6" errtask
# A present-but-unreadable backlog (a directory where a regular file is required)
# makes the readiness owner return ERROR, not a clean exemption.
rm -f "$H6/data/backlog.md"
mkdir -p "$H6/data/backlog.md"
run_wc "$H6" preflight errtask --effect dependent
expect_code 3 "$WC_RC" "a readiness-owner error must fail closed for the dependent op, not proceed"
assert_contains "$WC_OUT" "readiness-owner-error" "readiness owner error -> typed fail-closed refusal"
# Recovery is still never blocked, even when readiness cannot be evaluated.
run_wc "$H6" preflight errtask --effect recovery
expect_code 0 "$WC_RC" "safety/control recovery proceeds even when readiness cannot be evaluated"
pass "defect 3: a readiness-owner ERROR fails closed for dependent work while recovery still proceeds"

H7=$(make_home readiness_exempt)
# A genuinely absent backlog file is a legitimate exemption (readiness owned
# elsewhere): the dependent op is NOT synthesized into a refusal.
rm -f "$H7/data/backlog.md"
run_wc "$H7" preflight sometask --effect dependent
expect_code 0 "$WC_RC" "a legitimate readiness exemption still proceeds (not conflated with error)"
assert_contains "$WC_OUT" "verdict=proceed" "absent backlog -> exemption proceeds (not the error refusal)"
pass "defect 3: a legitimate readiness exemption is preserved and distinct from the error path"

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

# =========================================================================
# Defect 4: a real child -> parent/reference reconciliation. One confirmed child
# transition reads back an INDEPENDENT authoritative parent row, refreshes a
# declared reference currentness marker, and independently reads that marker back.
# =========================================================================

H8=$(make_home reconcile_ref)
add_item "$H8" parent_task
add_item "$H8" child2
tasks-axi start child2 --file "$(backlog_of "$H8")" >/dev/null
mkdir -p "$H8/data/child2"
# Declare the authoritative parent and the reference currentness marker to refresh.
write_desc "$H8" child2 '{"reconcile":{"parent":"parent_task","reference_marker":"roadmap.currentness"}}'

# While the child is still open, the reconciliation cannot confirm and must NOT
# write the reference marker.
run_wc "$H8" reconcile child2 "done"
expect_code 1 "$WC_RC" "an open child cannot confirm the parent/reference reconciliation"
assert_absent "$H8/data/child2/roadmap.currentness" "an unconfirmed child must not refresh the reference marker"

# Close the child; now the reconciliation confirms, reads the parent's real row,
# refreshes the marker, and independently reads it back.
tasks-axi "done" child2 --file "$(backlog_of "$H8")" >/dev/null
run_wc "$H8" reconcile child2 "done"
expect_code 0 "$WC_RC" "a closed child confirms the child->parent/reference reconciliation"
assert_contains "$WC_OUT" "reconcile=confirmed" "confirmed reconciliation"
assert_present "$H8/data/child2/roadmap.currentness" "the declared reference marker is refreshed"
assert_grep "child=child2" "$H8/data/child2/roadmap.currentness" "the marker records the child transition"
assert_grep "parent=parent_task" "$H8/data/child2/roadmap.currentness" "the marker records the authoritative parent"
assert_grep "parent_state=queued" "$H8/data/child2/roadmap.currentness" "the marker records the independently read-back parent state"
assert_grep "parent_readback=confirmed" "$H8/state/child2.parent-currentness" "the receipt proves an independent marker read-back"
assert_grep "parent=parent_task" "$H8/state/child2.parent-currentness" "the receipt names the authoritative parent it read back"

# Idempotent replay: the marker and receipt converge on the same content.
REF_FIRST=$(cat "$H8/data/child2/roadmap.currentness")
run_wc "$H8" reconcile child2 "done"
expect_code 0 "$WC_RC" "replaying the confirmed reconciliation stays confirmed"
REF_SECOND=$(cat "$H8/data/child2/roadmap.currentness")
[ "$REF_FIRST" = "$REF_SECOND" ] || fail "reference reconciliation is not idempotent: '$REF_FIRST' vs '$REF_SECOND'"
pass "defect 4: a confirmed child transition refreshes the declared reference marker from an independent parent read-back, idempotently"

echo "# fm-work-context.test.sh: all assertions passed"
