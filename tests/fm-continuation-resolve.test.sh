#!/usr/bin/env bash
# tests/fm-continuation-resolve.test.sh - the watched-red fixtures and consumer
# closure for the programme continuation/authority owner
# (bin/fm-continuation-resolve.sh) over canonical inputs only: a pinned programme
# file, proof dispositions, and durable holds written through the captain-hold
# owner (bin/fm-captain-hold.sh) into a real tasks-axi backlog.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$ROOT/bin/fm-continuation-resolve.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-continuation)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# --- fixtures ------------------------------------------------------------------

# make_home <name>: an isolated FM_HOME with an empty tasks-axi backlog, a
# programme root, and config/programme pointing at the pinned programme file.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/cleanroom/artifacts/proofs"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  write_programme "$home"
  printf 'programme=%s\nroot=%s\n' "$home/cleanroom/programme.json" "$home/cleanroom" > "$home/config/programme"
  printf '%s\n' "$home"
}

# write_programme <home> [extra-jq-filter]: the pinned two-proof sequence with
# the same reserved axes as the requalification programme; the filter mutates it.
write_programme() {  # <home> [jq-filter]
  local home=$1 filter=${2:-.}
  jq "$filter" <<'JSON' > "$home/cleanroom/programme.json"
{
  "schema": "fm-requal-programme/v1",
  "programme_id": "cleanroom-requalification",
  "authorization_basis": {
    "kind": "standing_sequence_grant",
    "refs": ["control#3 requalification programme", "control#3 comment 5546589797"]
  },
  "reserved_axes": ["new_paid_spend", "security_control_weakening", "privacy_exposure",
                    "credential_or_identity_provisioning", "destructive_or_irreversible", "personal_or_product_preference"],
  "steps": [
    {"id": "proof-a", "title": "fresh Proof A", "artifact_root": "artifacts/proofs/proof-a",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED"]},
     "classification_when_next": "SELF_HANDLE"},
    {"id": "proof-b", "title": "fresh Proof B", "artifact_root": "artifacts/proofs/proof-b", "depends_on": "proof-a",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED"]},
     "classification_when_next": "SELF_HANDLE",
     "optional_captain_enhancements": [
       {"axis": "credential_or_identity_provisioning", "decision_key": "proof-sol-identity",
        "effect": "provision a second GitHub identity for Browser Sol", "required_to_proceed": false}]},
    {"id": "architecture-re-review", "title": "reissue the architecture review",
     "artifact_root": "artifacts/proofs/architecture-re-review", "depends_on": "proof-b",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED", "COMPLETE"]},
     "classification_when_next": "SELF_HANDLE"}
  ]
}
JSON
}

# disposition <home> <proof> <attempt> <outcome>: one read-only proof record.
disposition() {  # <home> <proof> <attempt> <outcome>
  local dir="$1/cleanroom/artifacts/proofs/$2/attempt-$3"
  mkdir -p "$dir"
  jq -n --arg o "$4" --arg p "$2" --argjson a "$3" '{schema:"fm-proof-disposition/v1", proof_id:$p, attempt:$a, outcome:$o}' > "$dir/disposition.json"
}

run_resolve() {  # <home> [args...]
  local home=$1
  shift
  # The resolver never probes tasks-axi itself, but `--materialize` hands the
  # hold to the captain-hold owner, which does; the same verdict run_hold passes
  # is forwarded so the owner skips its probes here too and the suite does not
  # depend on the installed tool clearing the version floor.
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$RESOLVE" "$@"
}

run_hold() {  # <home> [args...]
  local home=$1
  shift
  # The compatibility verdict is passed in (bin/fm-tasks-axi-lib.sh consumes it)
  # so each captain-hold call skips three ~1s tasks-axi probes; the suite's
  # skip guard above already proved the tool present.
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@"
}

tasks_in() {  # <home> [tasks-axi args...]
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# bound_hold <home> <id> <kind> <action> <axis> <programme> <wait> [--until <date>]:
# a held task carrying the typed binding line, written in two tasks-axi calls.
# The captain-hold owner's writer is exercised separately below; the fixtures
# here only need the durable shape it produces, and tasks-axi costs about a
# second per call.
# shellcheck source=bin/fm-continuation-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-continuation-lib.sh"
bound_hold() {  # <home> <id> <kind> <action> <axis> <programme> <wait> [hold flags...]
  local home=$1 id=$2 kind=$3 line
  line=$(fm_continuation_binding_line "$4" "$6" "$5" "$7")
  shift 7
  tasks_in "$home" add "$id" "fixture $id" --kind task --body "$line" >/dev/null || fail "could not add $id"
  tasks_in "$home" hold "$id" --reason "fixture hold on $id" --kind "$kind" "$@" >/dev/null || fail "could not hold $id"
}

field() {  # <json> <jq-path>
  printf '%s' "$1" | jq -r "$2"
}

expect_typed() {  # <json> <next> <classification> <authority> <reason> <label>
  local json=$1
  [ "$(field "$json" '.next_action')" = "$2" ] || fail "$6: next_action $(field "$json" '.next_action') != $2"
  [ "$(field "$json" '.classification')" = "$3" ] || fail "$6: classification $(field "$json" '.classification') != $3"
  [ "$(field "$json" '.authority_state')" = "$4" ] || fail "$6: authority_state $(field "$json" '.authority_state') != $4"
  [ "$(field "$json" '.reason_code')" = "$5" ] || fail "$6: reason_code $(field "$json" '.reason_code') != $5"
  [ "$(field "$json" '.why')" != "null" ] && [ -n "$(field "$json" '.why')" ] || fail "$6: why must be rendered"
}

# --- F1: Proof A PROVED + standing grant -> Proof B SELF_HANDLE / AUTHORIZED ------

test_f1_authorized_continuation() {
  local home out
  home=$(make_home f1)
  disposition "$home" proof-a 1 REFUSED_AT_A-S11
  disposition "$home" proof-a 2 PROVED
  disposition "$home" proof-b 1 CNO_AT_B-S3
  out=$(run_resolve "$home" resolve) || fail "F1 resolve failed: $out"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT F1
  [ "$(field "$out" '.action_generation')" = 2 ] || fail "F1: proof-b would run as attempt 2"
  [ "$(field "$out" '.applicability.predecessor.id')" = proof-a ] || fail "F1: predecessor is proof-a"
  [ "$(field "$out" '.applicability.predecessor.attempt')" = 2 ] || fail "F1: predecessor is the LATEST attempt (2), not the first"
  [ "$(field "$out" '.applicability.predecessor.outcome')" = PROVED ] || fail "F1: predecessor outcome PROVED"
  [ "$(field "$out" '.applicability.current.outcome')" = CNO_AT_B-S3 ] || fail "F1: current proof-b state is carried"
  [ "$(field "$out" '.basis_refs | map(select(.kind == "predecessor_disposition")) | length')" = 1 ] || fail "F1: basis names the predecessor disposition"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "predecessor_disposition") | .sha256 | length')" = 64 ] || fail "F1: disposition identity is a sha256"
  [ "$(field "$out" '.basis_refs | map(select(.kind == "programme_grant")) | length')" = 2 ] || fail "F1: basis names the grant refs"
  [ "$(field "$out" '.applicability_digest | length')" = 64 ] || fail "F1: applicability digest is a sha256"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "F1: nothing to materialize"
  [ "$(field "$out" '.cno')" = null ] || fail "F1: no CNO"
  printf '%s' "$(field "$out" '.why')" | grep -qiE 'your word|captain required|awaiting captain' && fail "F1: why must not assert a captain gate"
  pass "F1 Proof A PROVED under the standing grant resolves Proof B as SELF_HANDLE/AUTHORIZED with the exact predecessor disposition as basis"

  # A second resolution over unchanged state is byte-identical in its typed
  # fields and applicability digest: restart/replay converges.
  local again
  again=$(run_resolve "$home" resolve) || fail "F1 replay failed"
  [ "$(field "$out" '.applicability_digest')" = "$(field "$again" '.applicability_digest')" ] || fail "F1: replay must produce the same applicability digest"
  pass "F1 replay over unchanged canonical state converges on the same applicability digest"

  # A new attempt changes the applicability tuple, so a stale resolution is
  # detectable by digest.
  disposition "$home" proof-b 2 CNO_AT_B-S5
  again=$(run_resolve "$home" resolve) || fail "F1 moved-state resolve failed"
  [ "$(field "$out" '.applicability_digest')" != "$(field "$again" '.applicability_digest')" ] || fail "F1: a new attempt must change the applicability digest"
  [ "$(field "$again" '.action_generation')" = 3 ] || fail "F1: action generation advances with attempts"
  pass "F1 a later attempt changes action_generation and the applicability digest, so a stale resolution cannot be reused"
}

# --- F2 / F6: an old hold before Proof A, later lifted, cannot revive -----------

test_f2_lifted_hold_is_not_authoritative() {
  local home out
  home=$(make_home f2)
  # The old hold: captain, reserved axis, bound to proof-a, before any proof ran.
  run_hold "$home" hold old-hold-before-a --title "old hold before Proof A" \
    --reason "destructive concern raised before Proof A" \
    --action proof-a --axis destructive_or_irreversible --programme cleanroom-requalification >/dev/null \
    || fail "F2: could not record the old hold"
  out=$(run_resolve "$home" resolve) || fail "F2 resolve failed: $out"
  expect_typed "$out" proof-a CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "F2 (before lift)"
  [ "$(field "$out" '.holds.gating[0].task')" = old-hold-before-a ] || fail "F2: the live hold gates proof-a"
  pass "F2 before the lift, the bound reserved-axis captain hold gates Proof A as CAPTAIN"

  # The captain's explicit lift: AUTHORIZE_FRESH_PROOF_A, recorded as a
  # released answer through the captain-hold owner.
  printf 'AUTHORIZE_FRESH_PROOF_A - proceed, the destructive concern is addressed.\n' > "$home/lift.txt"
  run_hold "$home" answer old-hold-before-a --decision-file "$home/lift.txt" --release >/dev/null \
    || fail "F2: could not record the lift"
  out=$(run_resolve "$home" resolve) || fail "F2 post-lift resolve failed: $out"
  expect_typed "$out" proof-a SELF_HANDLE AUTHORIZED FIRST_STEP_STANDING_GRANT "F2 (after lift)"
  [ "$(field "$out" '.holds.gating | length')" = 0 ] || fail "F2: a lifted hold gates nothing"
  pass "F2 after the explicit lift the old hold is non-authoritative and Proof A proceeds under the standing grant"

  # A superseded hold that was closed outright is equally non-authoritative.
  bound_hold "$home" superseded-hold captain proof-a new_paid_spend '' ''
  tasks_in "$home" "done" superseded-hold >/dev/null || fail "F6: could not close the superseded hold"
  out=$(run_resolve "$home" resolve) || fail "F6 resolve failed"
  expect_typed "$out" proof-a SELF_HANDLE AUTHORIZED FIRST_STEP_STANDING_GRANT F6
  pass "F6 a closed (superseded) hold is not read as a live gate"
}

# --- F3 / F4: reversible ambiguity -> BROWSER_SOL; external wait -> EXTERNAL_DEPENDENCY

test_f3_f4_ruling_and_external_waits() {
  local home out
  home=$(make_home f3f4)
  disposition "$home" proof-a 1 PROVED
  bound_hold "$home" sol-ruling-wait external proof-b '' '' ruling
  out=$(run_resolve "$home" resolve) || fail "F3 resolve failed: $out"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING HOLD_RULING_WAIT F3
  pass "F3 a bound ruling wait resolves Proof B as BROWSER_SOL/REQUIRES_RULING, never CAPTAIN"

  tasks_in "$home" unhold sol-ruling-wait >/dev/null
  bound_hold "$home" ci-queue-wait external proof-b '' '' external
  out=$(run_resolve "$home" resolve) || fail "F4 resolve failed: $out"
  expect_typed "$out" proof-b EXTERNAL_DEPENDENCY WAITING_EXTERNAL HOLD_EXTERNAL_WAIT F4
  pass "F4 a bound external wait resolves Proof B as EXTERNAL_DEPENDENCY/WAITING_EXTERNAL, never CAPTAIN"

  # A ruling wait outranks an external wait on the same action; both are basis.
  tasks_in "$home" hold sol-ruling-wait --reason "ambiguity referred to Browser Sol" --kind external >/dev/null
  out=$(run_resolve "$home" resolve) || fail "F3+F4 resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING HOLD_RULING_WAIT "F3+F4"
  [ "$(field "$out" '.holds.gating | length')" = 2 ] || fail "F3+F4: both bound holds are gating basis"
  pass "F3+F4 with both waits bound, the ruling wait dominates and both holds remain in the basis"

  # A date-gated future hold is an external wait while live and ignored once expired.
  tasks_in "$home" unhold sol-ruling-wait >/dev/null
  tasks_in "$home" unhold ci-queue-wait >/dev/null
  bound_hold "$home" window-wait future proof-b '' '' '' --until 2026-09-10
  out=$(run_resolve "$home" resolve) || fail "date gate resolve failed"
  expect_typed "$out" proof-b EXTERNAL_DEPENDENCY WAITING_EXTERNAL HOLD_DATE_GATE "date gate live"
  out=$(FM_CONTINUATION_TODAY=2026-09-10 FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$RESOLVE" resolve) || fail "expired date gate resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "date gate expired"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "window-wait") | .reason')" = HOLD_DATE_EXPIRED ] || fail "expired date gate is listed as ignored"
  pass "a bound date gate is an external wait while live and non-authoritative once its date has passed"
}

# --- F5 / F9: a reserved axis with NO pre-existing hold -> CAPTAIN, then materialized

test_f5_f9_reserved_axis_without_hold_materializes() {
  local home out out2 show body
  home=$(make_home f5)
  disposition "$home" proof-a 1 PROVED
  # The programme's typed action fact: Proof B requires a new paid service.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]'
  [ "$(tasks_in "$home" list 2>/dev/null | grep -c '^  [A-Za-z]')" = 0 ] || fail "F5 precondition: no tasks exist yet"
  out=$(run_resolve "$home" resolve) || fail "F5 resolve failed: $out"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS F5
  [ "$(field "$out" '.holds.considered')" = 0 ] || fail "F5: CAPTAIN fired with zero holds in the store"
  [ "$(field "$out" '.materialize[0].axis')" = new_paid_spend ] || fail "F5: the result names the hold to materialize"
  pass "F5 a typed reserved axis on the next action fires CAPTAIN/REQUIRES_CAPTAIN with no pre-existing hold"

  # Read-only resolve created nothing.
  [ "$(tasks_in "$home" list 2>/dev/null | grep -c '^  [A-Za-z]')" = 0 ] || fail "F5: a plain resolve must not write a hold"
  pass "F5 a plain resolve is read-only"

  # F9 positive non-vacuity: --materialize creates the canonical durable hold
  # through the captain-hold owner, bound to the exact action and axis.
  out=$(run_resolve "$home" resolve --materialize) || fail "F9 materialize failed: $out"
  [ "$(field "$out" '.materialized[0].task')" = proof-b-paid-runner ] || fail "F9: the decision_key names the hold task"
  show=$(tasks_in "$home" show proof-b-paid-runner --full) || fail "F9: the hold task does not exist"
  printf '%s\n' "$show" | grep -q '^  hold_kind: captain$' || fail "F9: the materialized task is captain-held"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r '.')
  printf '%s\n' "$body" | grep -qx 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' \
    || fail "F9: the materialized hold carries the typed binding: $body"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "F9 (after materialize)"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "F9: once durable, nothing remains to materialize"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = false ] || fail "F9: a live captain hold on the exact fact keeps it outstanding, not answered"
  [ "$(field "$out" '.materialized | length')" = 1 ] || fail "F9: exactly one canonical hold was materialized"
  pass "F9 non-vacuity: --materialize creates the canonical captain hold through fm-captain-hold.sh and the result then rests on that durable hold"

  # Idempotent and convergent: a second and third materialize create nothing
  # new, return the identical typed result, and leave one stable binding.
  out=$(run_resolve "$home" resolve --materialize) || fail "F9 second materialize failed"
  [ "$(tasks_in "$home" list 2>/dev/null | grep -c '^  [A-Za-z]')" = 1 ] || fail "F9: materialize must be idempotent"
  out2=$(run_resolve "$home" resolve --materialize) || fail "F9 third materialize failed"
  [ "$out" = "$out2" ] || fail "F9: the second and third materialize must return the identical result"
  [ "$(field "$out" '.applicability_digest')" = "$(field "$out2" '.applicability_digest')" ] || fail "F9: the applicability digest must be stable across replays"
  body=$(tasks_in "$home" show proof-b-paid-runner --full | sed -n 's/^  body: //p' | jq -r '.')
  [ "$(printf '%s\n' "$body" | grep -c '^Continuation-binding: ')" = 1 ] || fail "F9: replay must leave exactly one binding line"
  printf '%s\n' "$body" | grep -qx 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' \
    || fail "F9: replay must not move the binding: $body"
  pass "F9 materialize is idempotent and converges on one stable binding across replays"

  # The captain's recorded answer (release mode: the task stays open, unheld)
  # retires the typed fact through the same store, with no programme-file edit.
  printf 'Approved: use the paid runner tier.\n' > "$home/ok.txt"
  run_hold "$home" answer proof-b-paid-runner --decision-file "$home/ok.txt" --release >/dev/null || fail "F9: could not answer"
  out=$(run_resolve "$home" resolve) || fail "F9 post-answer resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "F9 (answered by release)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = true ] || fail "F9: the answered fact is listed in the basis"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered_task')" = proof-b-paid-runner ] || fail "F9: the basis names the answering task"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered_mode')" = released ] || fail "F9: the basis carries the recorded mode"
  [ "$(field "$out" '.applicability.answered_facts[0]')" = proof-b-paid-runner ] || fail "F9: applicability binds to the answered task"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "F9: an answered fact is not materialized again"
  out=$(run_resolve "$home" resolve --materialize) || fail "F9 post-answer materialize failed"
  [ "$(field "$out" '.materialized | length')" = 0 ] || fail "F9: materialize skips an answered fact"
  [ "$(tasks_in "$home" list 2>/dev/null | grep -c '^  [A-Za-z]')" = 1 ] || fail "F9: materialize after the answer must create nothing"
  out=$(run_resolve "$home" render) || fail "F9 post-answer render failed"
  assert_contains "$out" "step fact axis new_paid_spend (reserved), answered by proof-b-paid-runner (released)" "render marks the answered fact"
  pass "F9 a captain answer recorded in release mode retires the typed fact: SELF_HANDLE/AUTHORIZED with no programme-file edit"

  # The released task is a resumed work item: a later external wait on it gates
  # through the hold path and never re-fires the answered fact, and materialize
  # leaves that hold and its binding untouched.
  tasks_in "$home" hold proof-b-paid-runner --reason "waiting on the runner quota" --kind external >/dev/null || fail "F9: could not re-hold externally"
  out=$(run_resolve "$home" resolve) || fail "F9 external re-hold resolve failed"
  expect_typed "$out" proof-b EXTERNAL_DEPENDENCY WAITING_EXTERNAL HOLD_EXTERNAL_WAIT "F9 (external wait after the answer)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = true ] || fail "F9: the answer stands across a later external hold"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "F9: nothing to materialize while the answer stands"
  out=$(run_resolve "$home" resolve --materialize) || fail "F9 materialize over external hold failed"
  [ "$(field "$out" '.materialized | length')" = 0 ] || fail "F9: materialize must not touch the external hold"
  show=$(tasks_in "$home" show proof-b-paid-runner --full) || fail "F9: the task disappeared"
  printf '%s\n' "$show" | grep -q '^  hold_kind: external$' || fail "F9: the external hold must stay intact after materialize"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r '.')
  printf '%s\n' "$body" | grep -qx 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' \
    || fail "F9: the external hold keeps its binding after materialize: $body"
  pass "F9 an answered fact stays retired under a later external hold, which gates as EXTERNAL_DEPENDENCY and survives materialize"

  # An unrelated non-authority hold on the same task leaves the fact retired too.
  tasks_in "$home" unhold proof-b-paid-runner >/dev/null || fail "F9: could not lift the external hold"
  tasks_in "$home" hold proof-b-paid-runner --reason "parked for later" --kind parked >/dev/null || fail "F9: could not park"
  out=$(run_resolve "$home" resolve) || fail "F9 parked re-hold resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "F9 (parked after the answer)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = true ] || fail "F9: the answer stands across a parked hold"
  pass "F9 an answered fact stays retired under an unrelated non-captain hold"

  # Close mode: the answered task is done and carries the record.
  home=$(make_home f9-close)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]'
  run_resolve "$home" resolve --materialize >/dev/null || fail "F9 close: materialize failed"
  printf 'Approved: use the paid runner tier.\n' > "$home/ok.txt"
  run_hold "$home" answer proof-b-paid-runner --decision-file "$home/ok.txt" >/dev/null || fail "F9 close: could not answer"
  out=$(run_resolve "$home" resolve) || fail "F9 close: post-answer resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "F9 (answered by close)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered_mode')" = answered ] || fail "F9 close: the basis carries the recorded mode"
  pass "F9 a captain answer recorded in close mode retires the typed fact"

  # The same answered task does not answer for another programme id ...
  write_programme "$home" '.programme_id = "other-programme" | .steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]'
  out=$(run_resolve "$home" resolve) || fail "F9 other programme resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "F9 (answer bound to another programme)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answer_ignored.reason')" = ANSWER_OTHER_PROGRAMME ] || fail "F9: the foreign answer is listed as ignored"
  out=$(run_resolve "$home" render) || fail "F9 other programme render failed"
  assert_contains "$out" "answer on proof-b-paid-runner ignored (ANSWER_OTHER_PROGRAMME)" "render names the ignored answer"
  pass "F9 an answer bound to another programme does not retire this programme's fact"

  # ... nor for a later action whose own decision task was answered while
  # bound to proof-b: the answer's typed binding, not the key, names the action.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]
    | .steps[2].captain_axes = [{"axis":"new_paid_spend","decision_key":"re-review-paid-runner","effect":"a paid CI runner tier"}]'
  run_hold "$home" hold re-review-paid-runner --title "Captain decision for proof-b: paid runner" --reason "fixture" \
    --action proof-b --axis new_paid_spend --programme cleanroom-requalification >/dev/null || fail "F9: could not hold re-review-paid-runner"
  run_hold "$home" answer re-review-paid-runner --decision-file "$home/ok.txt" >/dev/null || fail "F9: could not answer re-review-paid-runner"
  disposition "$home" proof-b 1 PROVED
  out=$(run_resolve "$home" resolve) || fail "F9 later action resolve failed"
  expect_typed "$out" architecture-re-review CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "F9 (answer bound to an earlier action)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answer_ignored.reason')" = ANSWER_OTHER_ACTION ] || fail "F9: the proof-b-bound answer is listed as ignored for architecture-re-review"
  [ "$(field "$out" '.applicability.answered_facts | length')" = 0 ] || fail "F9: an ignored answer is not an answered fact"
  pass "F9 an answer bound to proof-b does not retire a later action's fact even on that action's own decision task"

  # An unbound record (no Continuation-binding line) is not an answer for any action.
  home=$(make_home f9-unbound)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]'
  tasks_in "$home" add proof-b-paid-runner "hand-made captain call" --kind task >/dev/null || fail "F9 unbound: could not add"
  tasks_in "$home" hold proof-b-paid-runner --reason "hand-made" --kind captain >/dev/null || fail "F9 unbound: could not hold"
  printf 'Approved.\n' > "$home/ok.txt"
  run_hold "$home" answer proof-b-paid-runner --decision-file "$home/ok.txt" >/dev/null || fail "F9 unbound: could not answer"
  out=$(run_resolve "$home" resolve) || fail "F9 unbound resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "F9 (unbound answer)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answer_ignored.reason')" = ANSWER_UNBOUND ] || fail "F9 unbound: the record is listed as unbound"
  pass "F9 a recorded answer without a typed binding does not retire the fact"

  # A plain closure without a recorded answer is not an answer: the fact still fires.
  home=$(make_home f9-plain)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"a paid CI runner tier"}]'
  run_resolve "$home" resolve --materialize >/dev/null || fail "F9 plain: materialize failed"
  tasks_in "$home" "done" proof-b-paid-runner >/dev/null || fail "F9 plain: could not close the task"
  out=$(run_resolve "$home" resolve) || fail "F9 plain: post-close resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "F9 (plain closure)"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = false ] || fail "F9 plain: a closure without a record is not an answer"
  pass "F9 a decision task closed without a recorded answer does not retire the typed fact"
}

# --- one identity: a foreign hold sharing the axis never stands in for a fact ---

test_foreign_hold_sharing_axis_does_not_cover_fact() {
  local home out
  home=$(make_home foreign-axis)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier"}]'
  run_hold "$home" hold foreign-spend --title "Hand-made paid spend call" --reason "someone asked" \
    --action proof-b --axis new_paid_spend --programme cleanroom-requalification >/dev/null || fail "foreign: could not hold"
  out=$(run_resolve "$home" resolve) || fail "foreign resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "foreign hold gates on its own"
  [ "$(field "$out" '.materialize[0].decision_key')" = runner-b ] || fail "foreign: the fact's own task is still to materialize"
  out=$(run_resolve "$home" resolve --materialize) || fail "foreign materialize failed"
  [ "$(field "$out" '.materialized[0].task')" = runner-b ] || fail "foreign: materialize creates the fact's own task"
  [ "$(field "$out" '.holds.gating | map(.task) | sort | join(" ")')" = "foreign-spend runner-b" ] || fail "foreign: both holds gate"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "foreign: once its own task is held, the fact is covered"
  pass "a foreign captain hold sharing the axis gates on its own while the fact still materializes its own task"

  printf 'Approved.\n' > "$home/ok.txt"
  run_hold "$home" answer foreign-spend --decision-file "$home/ok.txt" >/dev/null || fail "foreign: could not answer the foreign hold"
  out=$(run_resolve "$home" resolve) || fail "foreign post-answer resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "fact outstanding after the foreign answer"
  [ "$(field "$out" '.holds.gating | map(.task) | join(" ")')" = runner-b ] || fail "foreign: only the fact's own hold gates now"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered')" = false ] || fail "foreign: answering the foreign hold does not answer the fact"
  pass "answering the foreign hold alone leaves the fact outstanding"

  run_hold "$home" answer runner-b --decision-file "$home/ok.txt" >/dev/null || fail "foreign: could not answer the fact's task"
  out=$(run_resolve "$home" resolve) || fail "foreign final resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "fact retired through its own task"
  [ "$(field "$out" '.basis_refs[] | select(.kind == "step_fact") | .answered_task')" = runner-b ] || fail "foreign: the fact is answered through its own task"
  pass "answering the fact's own task retires it"
}

# --- materialize never rebinds a decision task bound elsewhere ------------------

test_materialize_never_rebinds_foreign_binding() {
  local home out out2 rc before after
  home=$(make_home rebind)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier"}]'
  run_resolve "$home" resolve --materialize >/dev/null || fail "rebind: first materialize failed"
  before=$(tasks_in "$home" show runner-b --full | sed -n 's/^  body: //p')

  # A programme generation bump that keeps the step id, key, and effect text
  # but changes the programme id must not take over the outstanding call.
  write_programme "$home" '.programme_id = "cleanroom-requalification-v2"
    | .steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier"}]'
  out=$(run_resolve "$home" resolve) || fail "rebind: v2 resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "v2 sees the old hold as another programme's"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "runner-b") | .reason')" = HOLD_OTHER_PROGRAMME ] || fail "rebind: the old hold is ignored as another programme's"
  out=$(run_resolve "$home" resolve --materialize 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "rebind: materialize over a foreign-programme binding must exit 1, got $rc: $out"
  assert_contains "$out" "runner-b" "the refusal names the task"
  assert_contains "$out" "bound to action proof-b programme cleanroom-requalification" "the refusal names the recorded binding"
  assert_contains "$out" "must not be rebound to action proof-b programme cleanroom-requalification-v2" "the refusal names the fact's action and programme"
  after=$(tasks_in "$home" show runner-b --full | sed -n 's/^  body: //p')
  [ "$before" = "$after" ] || fail "rebind: the old binding must stay byte-identical: $after"
  pass "materialize refuses to rebind a live captain hold bound to another programme and leaves its binding untouched"

  # The old programme still sees its own hold, unchanged: no flip.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier"}]'
  out=$(run_resolve "$home" resolve --materialize) || fail "rebind: old programme replay failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "old programme keeps its own hold"
  [ "$(field "$out" '.materialized | length')" = 0 ] || fail "rebind: the old programme has nothing to materialize"
  after=$(tasks_in "$home" show runner-b --full | sed -n 's/^  body: //p')
  [ "$before" = "$after" ] || fail "rebind: the old programme's replay must not move the binding: $after"
  pass "the old programme's replay still sees its own hold unchanged"

  # A live captain hold on the fact's task bound to another action refuses too.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-c","effect":"a paid CI runner tier"}]'
  run_hold "$home" hold runner-c --title "Captain decision for proof-b: a paid CI runner tier" --reason "earlier call" \
    --action proof-a --axis new_paid_spend --programme cleanroom-requalification >/dev/null || fail "rebind: could not hold runner-c"
  before=$(tasks_in "$home" show runner-c --full | sed -n 's/^  body: //p')
  out=$(run_resolve "$home" resolve --materialize 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "rebind: materialize over a foreign-action binding must exit 1, got $rc: $out"
  assert_contains "$out" "runner-c: it is bound to action proof-a programme cleanroom-requalification" "the refusal names the other action"
  after=$(tasks_in "$home" show runner-c --full | sed -n 's/^  body: //p')
  [ "$before" = "$after" ] || fail "rebind: the other action's binding must stay byte-identical"
  pass "materialize refuses to rebind a live captain hold bound to another action"

  # A same-action same-programme binding missing the axis converges through the owner.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-d","effect":"a paid CI runner tier"}]'
  run_hold "$home" hold runner-d --title "Captain decision for proof-b: a paid CI runner tier" --reason "axis-less call" \
    --action proof-b --programme cleanroom-requalification >/dev/null || fail "rebind: could not hold runner-d"
  out=$(run_resolve "$home" resolve --materialize) || fail "rebind: axis-less binding must converge: $out"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "axis-less binding converged"
  [ "$(field "$out" '.materialized[0].task')" = runner-d ] || fail "rebind: the axis-less task was materialized"
  after=$(tasks_in "$home" show runner-d --full | sed -n 's/^  body: //p' | jq -r '.')
  [ "$(printf '%s\n' "$after" | grep -c '^Continuation-binding: ')" = 1 ] || fail "rebind: exactly one binding line after convergence"
  printf '%s\n' "$after" | grep -qx 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' \
    || fail "rebind: the converged binding carries the axis: $after"
  out2=$(run_resolve "$home" resolve --materialize) || fail "rebind: replay failed"
  [ "$(field "$out2" '.applicability_digest')" = "$(field "$out" '.applicability_digest')" ] || fail "rebind: replay digest must be stable"
  pass "a same-action same-programme binding missing the axis converges to one binding"
}

# --- F7: a hold scoped to one action does not gate another ---------------------

test_f7_scoped_hold_does_not_leak() {
  local home out
  home=$(make_home f7)
  disposition "$home" proof-a 1 PROVED
  bound_hold "$home" spend-on-a captain proof-a new_paid_spend '' ''
  out=$(run_resolve "$home" resolve) || fail "F7 resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT F7
  [ "$(field "$out" '.holds.ignored[] | select(.task == "spend-on-a") | .reason')" = HOLD_OTHER_ACTION ] || fail "F7: the proof-a hold is listed as another action's"
  pass "F7 a reserved-axis hold bound to Proof A does not gate Proof B"

  # A hold bound to the same action id in ANOTHER programme does not leak either.
  bound_hold "$home" spend-elsewhere captain proof-b new_paid_spend other-programme ''
  out=$(run_resolve "$home" resolve) || fail "F7 foreign resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "F7 (other programme)"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "spend-elsewhere") | .reason')" = HOLD_OTHER_PROGRAMME ] || fail "F7: the foreign hold is listed as another programme's"
  pass "F7 a hold bound to another programme's action of the same name does not gate this programme"

  # An unbound captain hold - the pre-repair shape - gates nothing.
  tasks_in "$home" add vague-caution "generic caution" --kind task >/dev/null
  tasks_in "$home" hold vague-caution --reason "should we really proceed" --kind captain >/dev/null
  out=$(run_resolve "$home" resolve) || fail "F7 unbound resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "F7 (unbound)"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "vague-caution") | .reason')" = HOLD_UNBOUND ] || fail "F7: the unbound hold is listed as unbound"
  pass "F7 an unbound captain hold (generic caution) cannot gate a programme action"
}

# --- F8: a captain claim without a reserved axis cannot manufacture CAPTAIN -----

test_f8_captain_claim_without_axis_is_refused() {
  local home out
  home=$(make_home f8)
  disposition "$home" proof-a 1 PROVED
  bound_hold "$home" claims-captain captain proof-b '' '' ''
  out=$(run_resolve "$home" resolve) || fail "F8 resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS F8
  pass "F8 a bound captain hold with no reserved axis is refused to BROWSER_SOL"

  bound_hold "$home" claims-captain-odd-axis captain proof-b engineering_taste '' ''
  out=$(run_resolve "$home" resolve) || fail "F8 odd axis resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS "F8 (unreserved axis)"
  pass "F8 a captain hold naming an axis outside the reserved set is refused to BROWSER_SOL"

  # The programme step itself may not claim CAPTAIN without a reserved axis.
  tasks_in "$home" "done" claims-captain >/dev/null 2>&1 || true
  tasks_in "$home" "done" claims-captain-odd-axis >/dev/null 2>&1 || true
  write_programme "$home" '.steps[1].classification_when_next = "CAPTAIN"'
  out=$(run_resolve "$home" resolve) || fail "F8 step claim resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING STEP_CLASSIFICATION_REFUSED "F8 (step claim)"
  pass "F8 a programme step claiming CAPTAIN without a typed reserved axis is refused to BROWSER_SOL"

  # A step fact naming a non-reserved axis is a refused claim, not CAPTAIN.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"engineering_taste"}]'
  out=$(run_resolve "$home" resolve) || fail "F8 fact claim resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS "F8 (fact claim)"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "F8: a refused claim materializes nothing"
  pass "F8 a typed step fact on a non-reserved axis is refused and materializes no hold"
}

# --- grant applicability: superseded or wrong-generation grants cannot authorize

test_grant_applicability_is_cno() {
  local home out
  home=$(make_home grant)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.authorization_basis.superseded_by = "control#3 comment 9999 (revoked)"'
  out=$(run_resolve "$home" resolve) || fail "superseded grant resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO GRANT_SUPERSEDED "superseded grant"
  [ "$(field "$out" '.cno.reason_code')" = GRANT_SUPERSEDED ] || fail "cno record names the failure"
  pass "a superseded grant cannot authorize: CNO with BROWSER_SOL, never AUTHORIZED and never CAPTAIN"

  write_programme "$home" '.authorization_basis.programme_generation = "fm-requal-programme/v0"'
  out=$(run_resolve "$home" resolve) || fail "wrong-generation grant resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO GRANT_GENERATION_MISMATCH "wrong generation"
  pass "a grant pinned to another programme generation cannot authorize: CNO"

  write_programme "$home" '.authorization_basis.programme_generation = "fm-requal-programme/v1"'
  out=$(run_resolve "$home" resolve) || fail "matching generation resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "matching generation"
  pass "a grant pinned to the current programme generation authorizes"

  # A reserved-axis captain hold still yields CAPTAIN under a CNO grant: the
  # captain's own record dominates uncertainty.
  write_programme "$home" '.authorization_basis.superseded_by = "revoked"'
  bound_hold "$home" spend-b captain proof-b new_paid_spend '' ''
  out=$(run_resolve "$home" resolve) || fail "CNO + captain hold resolve failed"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "CNO + captain hold"
  pass "a bound reserved-axis captain hold dominates a CNO grant"
}

# --- unreadable canonical inputs are CNO, never AUTHORIZED ----------------------

test_unreadable_inputs_are_cno() {
  local home out fakebin
  home=$(make_home cno)
  disposition "$home" proof-a 1 PROVED
  printf 'not json' > "$home/cleanroom/artifacts/proofs/proof-b/attempt-1/disposition.json" 2>/dev/null \
    || { mkdir -p "$home/cleanroom/artifacts/proofs/proof-b/attempt-1"; printf 'not json' > "$home/cleanroom/artifacts/proofs/proof-b/attempt-1/disposition.json"; }
  out=$(run_resolve "$home" resolve) || fail "unreadable disposition resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO PREDECESSOR_DISPOSITION_UNREADABLE "unreadable disposition"
  pass "an unreadable current disposition makes the continuation CNO rather than authorized"

  # A newer attempt directory without a terminal disposition means the proof is
  # in flight: the step is the next action with CNO, never authorized from an
  # older PROVED attempt.
  rm -rf "$home/cleanroom/artifacts/proofs/proof-b"
  mkdir -p "$home/cleanroom/artifacts/proofs/proof-a/attempt-2"
  out=$(run_resolve "$home" resolve) || fail "in-flight attempt resolve failed"
  expect_typed "$out" proof-a BROWSER_SOL CNO NEWER_ATTEMPT_WITHOUT_DISPOSITION "in-flight newest attempt"
  [ "$(field "$out" '.applicability.current.attempt')" = 2 ] || fail "in-flight: the newest attempt is the current one"
  [ "$(field "$out" '.completed | length')" = 0 ] || fail "in-flight: attempt 1 PROVED must not count as terminal"
  assert_contains "$(field "$out" '.cno.detail')" "attempt-2" "the CNO detail names the missing disposition"
  pass "a newer attempt without a terminal disposition is CNO, never an older-PROVED fallback"
  rm -rf "$home/cleanroom/artifacts/proofs/proof-a/attempt-2"

  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" run_resolve "$home" resolve) || fail "unreadable hold store resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO HOLD_STORE_UNREADABLE "unreadable hold store"
  pass "an unreadable hold store cannot prove the absence of a captain hold: CNO, never AUTHORIZED"

  # A tool that exits 0 but prints no listing is equally unreadable: silence is
  # never read as "no holds".
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  out=$(PATH="$fakebin:$PATH" run_resolve "$home" resolve) || fail "silent hold store resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO HOLD_STORE_UNREADABLE "silent hold store"
  pass "a silent hold store (exit 0, no listing) is unreadable, not empty"

  # A store that lists a held task but cannot show it is partially unreadable:
  # the hold it names might be a bound captain hold, so the task is never
  # skipped and the result is CNO naming that task, never AUTHORIZED.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf 'count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind}:\n  ghost-hold,queued,task,"-",fixture ghost-hold,captain\n'
    exit 0 ;;
  *) exit 1 ;;
esac
SH
  out=$(PATH="$fakebin:$PATH" run_resolve "$home" resolve) || fail "partially unreadable hold store resolve failed"
  expect_typed "$out" proof-b BROWSER_SOL CNO HOLD_STORE_UNREADABLE "partially unreadable hold store"
  assert_contains "$(field "$out" '.cno.detail')" "ghost-hold" "the CNO detail names the task that could not be shown"
  pass "a listed held task whose record cannot be shown is an unreadable store, not a skipped hold"

  # A kind that can never gate (parked, load) is read from the listing alone:
  # the same store that cannot show it still resolves, with the hold counted
  # and listed as ignored.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf 'count: 2\ntasks[2]{id,state,kind,repo,title,hold_kind}:\n  parked-item,queued,task,"-",fixture parked-item,parked\n  load-item,queued,task,"-",fixture load-item,load\n'
    exit 0 ;;
  *) exit 1 ;;
esac
SH
  out=$(PATH="$fakebin:$PATH" run_resolve "$home" resolve) || fail "listing-only non-authority holds resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "listing-only non-authority holds"
  [ "$(field "$out" '.holds.considered')" = 2 ] || fail "non-authority holds are still counted"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "parked-item") | .reason')" = HOLD_NOT_AUTHORITY ] || fail "the parked hold is listed as not authority"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "load-item") | .reason')" = HOLD_NOT_AUTHORITY ] || fail "the load hold is listed as not authority"
  pass "parked and load holds are read from the listing alone, never shown, and stay counted and ignored"
}

# --- programme completion and configuration ----------------------------------------

test_completion_and_configuration() {
  local home other out rc fakebin tool
  home=$(make_home complete)
  disposition "$home" proof-a 1 PROVED
  disposition "$home" proof-b 1 PROVED
  disposition "$home" architecture-re-review 1 COMPLETE
  out=$(run_resolve "$home" resolve) || fail "complete resolve failed"
  [ "$(field "$out" '.next_action')" = null ] || fail "complete: no next action"
  [ "$(field "$out" '.reason_code')" = PROGRAMME_COMPLETE ] || fail "complete: reason"
  [ "$(field "$out" '.completed | length')" = 3 ] || fail "complete: three terminal steps"
  pass "every step terminal-good resolves to PROGRAMME_COMPLETE with no next action"

  # The artifact root pairs with the source that located the programme: with
  # config/programme still pinning the fully-proved tree, an environment- or
  # flag-located programme in another tree must read that tree's dispositions.
  other=$(make_home config-other-tree)
  disposition "$other" proof-a 1 PROVED
  out=$(FM_PROGRAMME="$other/cleanroom/programme.json" FM_PROGRAMME_ROOT="$other/cleanroom" run_resolve "$home" resolve) || fail "env-overridden programme failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "env programme with env root over config root"
  [ "$(field "$out" '.applicability.predecessor.disposition')" = "$other/cleanroom/artifacts/proofs/proof-a/attempt-1/disposition.json" ] \
    || fail "env programme read its predecessor from the config root tree"
  pass "FM_PROGRAMME pairs with FM_PROGRAMME_ROOT, never with the config root= line"

  out=$(FM_PROGRAMME="$other/cleanroom/programme.json" run_resolve "$home" resolve) || fail "env programme without root failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "env programme falls back to its own directory"
  pass "FM_PROGRAMME without FM_PROGRAMME_ROOT resolves against its own directory, not the config root"

  out=$(run_resolve "$home" resolve --programme "$other/cleanroom/programme.json") || fail "flag programme failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "flag programme falls back to its own directory"
  pass "--programme pairs with --root or FM_PROGRAMME_ROOT, then its own directory"

  out=$(FM_PROGRAMME="$other/cleanroom/programme.json" run_resolve "$home" resolve --root "$home/cleanroom") || fail "flag root failed"
  [ "$(field "$out" '.reason_code')" = PROGRAMME_COMPLETE ] || fail "--root must override the paired root"
  pass "--root overrides every paired root"

  rm "$home/config/programme"
  out=$(run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 3 ] || fail "no programme configured must exit 3, got $rc: $out"
  assert_contains "$out" "no programme configured" "exit 3 names the missing configuration"
  pass "a home without config/programme exits 3 so every consumer stays silent"

  out=$(FM_PROGRAMME="$home/cleanroom/programme.json" FM_PROGRAMME_ROOT="$home/cleanroom" run_resolve "$home" summary) || fail "env-located programme failed"
  assert_contains "$out" "programme cleanroom-requalification@fm-requal-programme/v1: complete" "summary renders the completion token"
  pass "FM_PROGRAMME and FM_PROGRAMME_ROOT locate a programme without the config file"

  # Identity rule: a decision_key is injective over required facts. A key
  # shared by two required facts across steps, or by two in one step, is
  # refused at load naming the key and the steps; distinct keys resolve.
  home=$(make_home shared-key)
  disposition "$home" proof-a 1 PROVED
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"shared-runner","effect":"x"}]
    | .steps[2].optional_captain_enhancements = [{"axis":"new_paid_spend","decision_key":"shared-runner","effect":"x","required_to_proceed":true}]'
  out=$(run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "a shared decision_key must exit 1, got $rc: $out"
  assert_contains "$out" "shared-runner" "the refusal names the shared key"
  assert_contains "$out" "proof-b" "the refusal names the first step"
  assert_contains "$out" "architecture-re-review" "the refusal names the second step"
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"shared-runner","effect":"x"},
                                                     {"axis":"privacy_exposure","decision_key":"shared-runner","effect":"y"}]'
  out=$(run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "two required facts in one step sharing a key must exit 1, got $rc: $out"
  assert_contains "$out" "shared-runner (facts proof-b/new_paid_spend, proof-b/privacy_exposure)" "the refusal names the key and each fact's step and axis"
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"x"}]
    | .steps[2].optional_captain_enhancements = [{"axis":"new_paid_spend","decision_key":"runner-c","effect":"x","required_to_proceed":true}]'
  out=$(run_resolve "$home" resolve) || fail "distinct decision keys must resolve"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN STEP_RESERVED_AXIS "distinct decision keys"
  pass "a decision_key shared by two required facts, across steps or in one step, is refused at load; distinct keys resolve"

  # The identity is the task materialize would hold, so two keyless required
  # facts on one reserved axis alias one derived task and are refused, as is a
  # key equal to another fact's derived identity; distinct identities, keyed
  # or keyless, materialize their own holds.
  other=$(make_home identity)
  disposition "$other" proof-a 1 PROVED
  write_programme "$other" '.steps[1].captain_axes = [{"axis":"new_paid_spend","effect":"a paid runner"},
                                                      {"axis":"new_paid_spend","effect":"paid storage"}]'
  out=$(run_resolve "$other" resolve 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "two keyless facts on one axis must exit 1, got $rc: $out"
  assert_contains "$out" "cleanroom-requalification-proof-b-new-paid-spend (facts proof-b/new_paid_spend, proof-b/new_paid_spend)" "the refusal names the derived identity and both facts"
  write_programme "$other" '.steps[1].captain_axes = [{"axis":"new_paid_spend","effect":"a paid runner"}]
    | .steps[2].captain_axes = [{"axis":"privacy_exposure","decision_key":"cleanroom-requalification-proof-b-new-paid-spend","effect":"y"}]'
  out=$(run_resolve "$other" resolve 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "a key equal to another fact's derived identity must exit 1, got $rc: $out"
  assert_contains "$out" "cleanroom-requalification-proof-b-new-paid-spend (facts proof-b/new_paid_spend, architecture-re-review/privacy_exposure)" "the refusal names the aliased identity across steps"
  write_programme "$other" '.steps[1].captain_axes = [{"axis":"engineering_taste","effect":"tabs"}, {"axis":"engineering_taste","effect":"spaces"}]'
  out=$(run_resolve "$other" resolve) || fail "keyless facts on a non-reserved axis must load: $out"
  expect_typed "$out" proof-b BROWSER_SOL REQUIRES_RULING CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS "non-reserved facts are not load-bearing"
  write_programme "$other" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid runner"},
                                                      {"axis":"privacy_exposure","effect":"telemetry export"}]'
  out=$(run_resolve "$other" resolve --materialize) || fail "distinct identities must resolve and materialize: $out"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "distinct identities"
  [ "$(field "$out" '.materialized | length')" = 2 ] || fail "distinct identities: two holds are materialized"
  [ "$(field "$out" '[.materialized[].task] | sort | join(" ")')" = "cleanroom-requalification-proof-b-privacy-exposure runner-b" ] || fail "distinct identities: keyed and derived tasks"
  [ "$(tasks_in "$other" list 2>/dev/null | grep -c '^  [A-Za-z]')" = 2 ] || fail "distinct identities: exactly two tasks exist"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "distinct identities: both holds are durable after one materialize"
  pass "the identity rule runs over the task materialize would hold: keyless aliases are refused, distinct identities materialize their own holds"

  # A non-required enhancement reusing a required fact's key is not load-bearing:
  # it loads, never fires, never retires the required fact, and cannot move
  # the durable binding the required fact materialized.
  write_programme "$home" '.steps[1].captain_axes = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier"}]
    | .steps[2].optional_captain_enhancements = [{"axis":"new_paid_spend","decision_key":"runner-b","effect":"a paid CI runner tier","required_to_proceed":false}]'
  out=$(run_resolve "$home" resolve --materialize) || fail "optional key reuse must load and materialize: $out"
  [ "$(field "$out" '.materialized[0].task')" = runner-b ] || fail "optional key reuse: the required fact materialized its task"
  expect_typed "$out" proof-b CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "optional key reuse (required fact outstanding)"
  printf 'Approved.\n' > "$home/ok.txt"
  run_hold "$home" answer runner-b --decision-file "$home/ok.txt" >/dev/null || fail "optional key reuse: could not answer"
  disposition "$home" proof-b 1 PROVED
  out=$(run_resolve "$home" resolve --materialize) || fail "optional key reuse: later step resolve failed"
  expect_typed "$out" architecture-re-review SELF_HANDLE AUTHORIZED STANDING_GRANT "optional key reuse (later step)"
  [ "$(field "$out" '.basis_refs | map(select(.kind == "step_fact")) | length')" = 0 ] || fail "optional key reuse: a non-required enhancement is not a fact"
  [ "$(field "$out" '.materialized | length')" = 0 ] || fail "optional key reuse: nothing is materialized for a non-required enhancement"
  body=$(tasks_in "$home" show runner-b --full | sed -n 's/^  body: //p' | jq -r '.')
  printf '%s\n' "$body" | grep -qx 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' \
    || fail "optional key reuse: the required fact's binding must stay bound to proof-b: $body"
  pass "a non-required enhancement reusing a key cannot overwrite, alias, or retire the required fact's binding"

  # Without jq on PATH a pinned home fails loudly, but an unpinned home still
  # exits 3 so every consumer stays silent regardless of the toolchain.
  home=$(make_home nojq)
  fakebin=$(fm_fakebin "$home")
  for tool in bash dirname grep tail cut; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "a pinned home without jq must exit 1, got $rc: $out"
  assert_contains "$out" "jq is required" "a pinned home without jq names the missing tool"
  rm "$home/config/programme"
  out=$(PATH="$fakebin" run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 3 ] || fail "an unpinned home without jq must exit 3, got $rc: $out"
  out=$(PATH="$fakebin" run_resolve "$home" summary 2>&1); rc=$?
  [ "$rc" = 3 ] || fail "an unpinned home without jq must exit 3 for summary, got $rc: $out"
  pass "an unpinned home exits 3 even without jq on PATH, so consumers stay silent"
}

# --- presentation cannot override or contradict the typed result ------------------

test_render_and_check_prose() {
  local home out rc
  home=$(make_home prose)
  disposition "$home" proof-a 1 PROVED
  out=$(run_resolve "$home" render) || fail "render failed"
  assert_contains "$out" "Typed result: SELF_HANDLE / AUTHORIZED [STANDING_GRANT]" "render states the typed result"
  assert_contains "$out" "next action proof-b" "render names the next action"
  assert_contains "$out" "disposition proof-a attempt 1 PROVED" "render lists the predecessor basis"
  printf '%s' "$out" | grep -qiE 'your word|captain required|awaiting captain' && fail "render must not assert a captain gate for an AUTHORIZED result"
  pass "render is derived from the typed fields and asserts no captain gate for an authorized continuation"

  out=$(run_resolve "$home" summary) || fail "summary failed"
  assert_contains "$out" "next=proof-b SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT applicability=" "summary token shape"
  pass "summary prints the one-line typed token"

  printf 'Fresh Proof B is prepared but, like the re-review, nothing further runs without your word.\n' > "$home/report.md"
  out=$(run_resolve "$home" check-prose "$home/report.md" 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "check-prose must refuse a captain gate over an AUTHORIZED result (rc=$rc): $out"
  assert_contains "$out" "REFUSED" "check-prose names the refusal"
  assert_contains "$out" "without your word" "check-prose quotes the offending line"
  pass "check-prose refuses report prose that manufactures a captain gate for an authorized continuation"

  printf 'Fresh Proof B proceeds under the standing grant; Proof A is PROVED.\n' | run_resolve "$home" check-prose - >/dev/null \
    || fail "check-prose must accept consistent prose"
  pass "check-prose accepts prose that makes no captain-gate claim"

  bound_hold "$home" spend-b captain proof-b new_paid_spend '' ''
  printf 'Proof B needs your word on the paid runner.\n' | run_resolve "$home" check-prose - >/dev/null \
    || fail "check-prose must accept a captain gate when the typed result is CAPTAIN"
  pass "check-prose accepts captain-gate phrasing exactly when the typed resolution is CAPTAIN"
}

# --- the captain-hold owner records and guards the binding --------------------------

test_captain_hold_binding_mechanics() {
  local home show body out
  home=$(make_home binding)
  run_hold "$home" hold t1 --title "T one" --reason "spend" --axis new_paid_spend >/dev/null 2>&1 \
    && fail "--axis without --action must be refused"
  run_hold "$home" bind-action t1 --action proof-b --wait captain >/dev/null 2>&1 \
    && fail "--wait must be ruling or external"
  run_hold "$home" bind-action t1 --action 'proof b' >/dev/null 2>&1 \
    && fail "a non-slug action must be refused"
  pass "the binding writer validates its tokens and refuses malformed input"

  tasks_in "$home" add t1 "T one" --kind task --body $'Observed: something.\nSecond line.' >/dev/null
  tasks_in "$home" hold t1 --reason "waiting on CI" --kind external >/dev/null
  run_hold "$home" bind-action t1 --action proof-b --wait external >/dev/null || fail "bind-action failed"
  show=$(tasks_in "$home" show t1 --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r '.')
  [ "$body" = $'Observed: something.\nSecond line.\nContinuation-binding: action=proof-b wait=external' ] || fail "binding appended after the existing body: $body"
  pass "bind-action appends the one binding line after the existing body"

  run_hold "$home" bind-action t1 --action proof-b --wait external >/dev/null || fail "idempotent bind failed"
  show=$(tasks_in "$home" show t1 --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r '.')
  [ "$(printf '%s\n' "$body" | grep -c '^Continuation-binding:')" = 1 ] || fail "repeating the same binding must not duplicate it"
  pass "bind-action is idempotent for an identical binding"

  run_hold "$home" bind-action t1 --action proof-b --wait ruling >/dev/null || fail "replacing bind failed"
  show=$(tasks_in "$home" show t1 --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r '.')
  [ "$(printf '%s\n' "$body" | grep -c '^Continuation-binding:')" = 1 ] || fail "a replaced binding leaves exactly one line"
  printf '%s\n' "$body" | grep -qx 'Continuation-binding: action=proof-b wait=ruling' || fail "the newest binding wins: $body"
  pass "bind-action replaces a different binding with exactly one current line"

  tasks_in "$home" "done" t1 >/dev/null
  out=$(run_hold "$home" bind-action t1 --action proof-b 2>&1) && fail "binding a closed task must be refused"
  assert_contains "$out" "already closed" "closed-task refusal names the cause"
  pass "bind-action refuses a closed task"
}

# --- consumer closure: snapshot, bearings, fleet view, away digest -------------------

test_consumers_project_the_typed_result() {
  local home snap bearings view token
  home=$(make_home consumers)
  disposition "$home" proof-a 1 PROVED
  snap=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$SNAPSHOT" --json) || fail "fleet snapshot failed"
  [ "$(field "$snap" '.programme_continuation.configured')" = true ] || fail "snapshot carries the configured programme"
  [ "$(field "$snap" '.programme_continuation.next_action')" = proof-b ] || fail "snapshot next_action"
  [ "$(field "$snap" '.programme_continuation.classification')" = SELF_HANDLE ] || fail "snapshot classification"
  [ "$(field "$snap" '.programme_continuation.authority_state')" = AUTHORIZED ] || fail "snapshot authority_state"
  [ "$(field "$snap" '.programme_continuation.schema')" = 'fm-continuation-resolution/v1' ] || fail "snapshot embeds the typed schema verbatim"
  pass "the canonical fleet snapshot embeds the typed resolution verbatim under programme_continuation"

  bearings=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$BEARINGS") || fail "bearings failed"
  assert_contains "$bearings" "programme[1]{programme,next_action,classification,authority_state,reason_code,applicability}:" "bearings renders the typed programme row"
  assert_contains "$bearings" "cleanroom-requalification,proof-b,SELF_HANDLE,AUTHORIZED,STANDING_GRANT," "bearings row values"
  printf '%s' "$bearings" | grep -qiE 'your word|captain required' && fail "bearings must not assert a captain gate"
  pass "bearings projects the typed row from the snapshot and asserts no captain gate"

  view=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$VIEW") || fail "fleet view failed"
  assert_contains "$view" "## Programme continuation" "fleet view has the programme section"
  assert_contains "$view" "cleanroom-requalification: next action proof-b - SELF_HANDLE / AUTHORIZED [STANDING_GRANT]" "fleet view line"
  pass "the fleet view renders the typed programme line"

  # Away continuation: the daemon's digest token comes from the same owner.
  token=$(
    # shellcheck source=bin/fm-supervise-daemon.sh
    # shellcheck disable=SC1091
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 bash -c '
      . "$1"; programme_digest_token' _ "$ROOT/bin/fm-supervise-daemon.sh"
  ) || fail "daemon token failed"
  assert_contains "$token" " | programme cleanroom-requalification@fm-requal-programme/v1: next=proof-b SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT" "away digest token"
  pass "the away-mode digest embeds the typed summary token from the same owner"

  # No programme: the snapshot says so and the digest token is empty.
  rm "$home/config/programme"
  snap=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$SNAPSHOT" --json) || fail "unconfigured snapshot failed"
  [ "$(field "$snap" '.programme_continuation | tojson')" = '{"configured":false}' ] || fail "unconfigured snapshot marks configured:false"
  token=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" bash -c '. "$1"; programme_digest_token' _ "$ROOT/bin/fm-supervise-daemon.sh")
  [ -z "$token" ] || fail "unconfigured digest token must be empty: $token"
  bearings=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$BEARINGS") || fail "unconfigured bearings failed"
  assert_contains "$bearings" "programme: []" "bearings shows an empty programme row set"
  pass "with no programme configured every consumer stays silent rather than inventing a state"
}

# --- accepted owner evidence: the A-F package binding ----------------------------
#
# Fixtures for the CLOSED non-proof completion-evidence adapter. The programme
# mirrors the A-F package shape: a predecessor ruling step bound to the real
# Proof-B adverse disposition by exact bytes, two package slices bound to
# owner records, and a proof-shaped pilot step F. Evidence records are authored
# beside the programme (resolved against its directory); bound sources resolve
# against the artifact root.
af_programme_path() { printf '%s/cleanroom/af/programme.json' "$1"; }
af_evidence_dir() { printf '%s/cleanroom/af/evidence' "$1"; }

write_af_programme() {  # <home> [jq-filter]
  local home=$1 filter=${2:-.}
  mkdir -p "$(af_evidence_dir "$home")"
  jq "$filter" <<'JSON' > "$(af_programme_path "$home")"
{
  "schema": "fm-af-programme/v1",
  "programme_id": "cleanroom-af-package",
  "project": "sbracewell64/firstmate-cleanroom",
  "authorization_basis": {"kind": "standing_sequence_grant", "programme_generation": "fm-af-programme/v1",
    "refs": ["control#3#issuecomment-5554812621 (grant)", "control#3#issuecomment-5554585623 (ruling)"]},
  "binding": {
    "commission": {"work_id": "cleanroom-af-package", "work_generation": 1},
    "grant": {"owner": "control_grant", "ref": "control#3#issuecomment-5554812621", "id": 5554812621},
    "ruling": {"owner": "control_ruling", "ref": "control#3#issuecomment-5554585623", "id": 5554585623},
    "consumer": {"contract": "fm-continuation-resolution/v1", "projection": "fm-programme-projection/v1"},
    "evidence_kinds": ["latest_attempt_disposition_outcome_in", "accepted_owner_evidence"],
    "programme_generation": "fm-af-programme/v1"
  },
  "reserved_axes": ["new_paid_spend", "security_control_weakening", "privacy_exposure",
                    "credential_or_identity_provisioning", "destructive_or_irreversible", "personal_or_product_preference"],
  "delegation": {"max_concurrency": 2},
  "steps": [
    {"id": "architecture-re-review-ruling", "title": "completed architecture re-review", "phase": "predecessor-obligations",
     "terminal_predicate": {"kind": "accepted_owner_evidence", "evidence": "evidence/ruling.json", "accept": ["PROCEED_WITH_CONDITIONS"],
                            "owner_ref": "control#3#issuecomment-5554585623", "policy_digest": "POLICYDIGEST"},
     "classification_when_next": "BROWSER_SOL"},
    {"id": "slice-c", "title": "C / S3 landing", "phase": "package-qualification", "depends_on": ["architecture-re-review-ruling"],
     "terminal_predicate": {"kind": "accepted_owner_evidence", "evidence": "evidence/slice-c.json", "accept": ["MERGED_QUALIFIED"],
                            "owner_ref": "sbracewell64/firstmate-cleanroom#5", "candidate": {"merge_commit": "dc66ba5ce35be4917424a529a45e61f4a9fa556c"}},
     "classification_when_next": "SELF_HANDLE"},
    {"id": "slice-a", "title": "A / S1 qualification", "phase": "package-qualification", "depends_on": "architecture-re-review-ruling",
     "terminal_predicate": {"kind": "accepted_owner_evidence", "evidence": "evidence/slice-a.json", "accept": ["MERGED_QUALIFIED", "ADOPT_OPTION"]},
     "classification_when_next": "SELF_HANDLE"},
    {"id": "pilot-f", "title": "F pilot", "phase": "pilot", "depends_on": ["slice-c", "slice-a"],
     "artifact_root": "artifacts/proofs/af-pilot-f",
     "terminal_predicate": {"kind": "latest_attempt_disposition_outcome_in", "accept": ["PROVED", "COMPLETE"]},
     "classification_when_next": "SELF_HANDLE", "delegation": {"max_concurrency": 2}}
  ]
}
JSON
}

# The real Proof-B adverse shape: attempt-3 CNO_AT_B-S9 with zero observed-bad,
# written under the artifact root exactly as the proof owner would.
write_proof_b_adverse() {  # <home>
  local dir="$1/cleanroom/artifacts/proofs/proof-b/attempt-3"
  mkdir -p "$dir"
  jq -n '{schema:"fm-proof-disposition/v1", proof_id:"proof-b", attempt:3, outcome:"CNO_AT_B-S9", counts:{observed_good:39, observed_bad:0, could_not_observe:1}}' > "$dir/disposition.json"
  printf 'policy bytes\n' > "$1/cleanroom/policy.md"
}

sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

# write_evidence <home> <file> <jq-program>: one owner record built from a
# well-formed base by a jq program (so a case mutates exactly one thing).
write_evidence() {  # <home> <file> <step> <owner-kind> <owner-ref> <outcome> [jq-filter]
  local home=$1 file=$2 step=$3 kind=$4 ref=$5 outcome=$6 filter=${7:-.}
  jq -n --arg step "$step" --arg kind "$kind" --arg ref "$ref" --arg outcome "$outcome" '
    {schema:"fm-accepted-owner-evidence/v1", evidence_id:("ev-" + $step), programme_id:"cleanroom-af-package", step:$step,
     project:"sbracewell64/firstmate-cleanroom", work_id:"cleanroom-af-package", generation:1,
     owner:{kind:$kind, ref:$ref}, outcome:$outcome, candidate:{}, policy:null, verifier:{tool:"fixture"},
     captures:[], sources:[], observed_bad:[], superseded_by:null}' | jq "$filter" > "$(af_evidence_dir "$home")/$file"
}

# The accepted A-E shape: ruling bound to Proof-B by bytes and outcome, C landed
# and qualified, A qualified.
write_af_accepted_evidence() {  # <home>
  local home=$1 psha policy
  write_proof_b_adverse "$home"
  psha=$(sha_of "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json")
  policy=$(sha_of "$home/cleanroom/policy.md")
  write_evidence "$home" ruling.json architecture-re-review-ruling control_ruling control#3#issuecomment-5554585623 PROCEED_WITH_CONDITIONS \
    ".policy = {id:\"architecture-review-acceptance-v1\", digest:\"$policy\"}
     | .sources = [{kind:\"local_file\", path:\"artifacts/proofs/proof-b/attempt-3/disposition.json\", sha256:\"$psha\", outcome:\"CNO_AT_B-S9\"},
                   {kind:\"local_file\", path:\"policy.md\", sha256:\"$policy\"}]"
  write_af_programme "$home" ".steps[0].terminal_predicate.policy_digest = \"$policy\""
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {head:"9ce75aa2edcea3e94981c35fd217102a8fe26585", merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"}
     | .qualification = {pipeline:"no-mistakes", evidence_refs:["https://example.invalid/evidence"]}'
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"1111111111111111111111111111111111111111"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["https://example.invalid/e"]}'
}

make_af_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/cleanroom/artifacts/proofs"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  write_af_programme "$home"
  printf 'programme=%s\nroot=%s\n' "$(af_programme_path "$home")" "$home/cleanroom" > "$home/config/programme"
  printf '%s\n' "$home"
}

expect_cno_refusal() {  # <json> <next> <reason> <label>
  expect_typed "$1" "$2" BROWSER_SOL CNO "$3" "$4"
  [ "$(field "$1" '.cno.reason_code')" = "$3" ] || fail "$4: cno.reason_code $(field "$1" '.cno.reason_code') != $3"
  [ "$(field "$1" '.evidence.reason_code')" = "$3" ] || fail "$4: evidence.reason_code carries the refusal"
  printf '%s' "$(field "$1" '.accountable_owner')" | grep -q 'never the captain' || fail "$4: accountable owner must name engineering, never the captain"
  printf '%s' "$(field "$1" '.why')" | grep -qiE 'your word|captain required|awaiting captain' && fail "$4: why must not assert a captain gate"
  return 0
}

test_af_accepted_owner_evidence_yields_f() {
  local home out again prose rc
  home=$(make_af_home af-yield)
  write_af_accepted_evidence "$home"
  out=$(run_resolve "$home" resolve) || fail "AF yield resolve failed: $out"
  expect_typed "$out" pilot-f SELF_HANDLE AUTHORIZED STANDING_GRANT "AF yield"
  [ "$(field "$out" '.completed | map(.id) | join(",")')" = "architecture-re-review-ruling,slice-c,slice-a" ] || fail "AF yield: A-E steps complete: $(field "$out" '.completed')"
  [ "$(field "$out" '.completed[0].outcome')" = PROCEED_WITH_CONDITIONS ] || fail "AF yield: the ruling's own decision token is the outcome"
  [ "$(field "$out" '.completed[0].attempt')" = null ] || fail "AF yield: an owner record is not a proof attempt"
  [ "$(field "$out" '.completed[0].evidence_kind')" = accepted_owner_evidence ] || fail "AF yield: completion names the evidence kind"
  [ "$(field "$out" '.action_generation')" = 1 ] || fail "AF yield: the pilot would run as attempt 1"
  [ "$(field "$out" '.binding.present')" = true ] && [ "$(field "$out" '.binding.grant.id')" = 5554812621 ] || fail "AF yield: binding carries the controlling grant"
  [ "$(field "$out" '.runtime.supported_evidence_kinds | join(" ")')" = "latest_attempt_disposition_outcome_in accepted_owner_evidence" ] || fail "AF yield: runtime names the supported kinds"
  [ "$(field "$out" '.evidence')" = null ] || fail "AF yield: a proof-shaped next action carries no owner evidence reading"
  [ "$(field "$out" '.materialize | length')" = 0 ] || fail "AF yield: nothing to materialize"
  printf '%s' "$(field "$out" '.accountable_owner')" | grep -q 'firstmate under the standing programme grant' || fail "AF yield: accountable owner is firstmate under the grant"
  [ "$(jq -r '.outcome' "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json")" = CNO_AT_B-S9 ] || fail "AF yield: the adverse Proof-B record is untouched"
  pass "AF real accepted-owner evidence for A-E under the grant with no gating hold resolves the pilot F as SELF_HANDLE/AUTHORIZED; the Proof-B CNO_AT_B-S9 transition is accepted through the ruling owner without rewriting it"

  out=$(run_resolve "$home" render) || fail "AF render failed"
  assert_contains "$out" "owner evidence slice-a MERGED_QUALIFIED by pull_request_merge sbracewell64/firstmate-cleanroom#9" "render names the owner evidence predecessor"
  assert_contains "$out" "Binding: commission cleanroom-af-package@1 under grant 5554812621" "render states the binding"
  assert_contains "$out" "Material identity " "render carries the material identity"
  printf 'Pilot F needs your word before it runs.\n' > "$home/prose.md"
  prose=$(run_resolve "$home" check-prose "$home/prose.md" 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "check-prose must refuse a captain gate for an authorized pilot (rc=$rc): $prose"
  pass "AF render and check-prose refuse to manufacture a captain gate for the authorized pilot"

  # Replay converges; the material identity ignores the clock while the
  # applicability tuple still carries the date.
  again=$(FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-30 "$RESOLVE" resolve) || fail "AF replay failed"
  [ "$(field "$out" '.material_identity' 2>/dev/null)" != "" ] || true
  out=$(run_resolve "$home" resolve) || fail "AF re-resolve failed"
  [ "$(field "$out" '.material_identity')" = "$(field "$again" '.material_identity')" ] || fail "AF: a different day must not change the material identity"
  [ "$(field "$out" '.applicability_digest')" != "$(field "$again" '.applicability_digest')" ] || fail "AF: the applicability tuple still binds the date"
  pass "AF the material identity is clock-free while applicability stays date-bound"

  # A genuine reserved-axis hold on THIS pilot still reaches the captain, once,
  # while a hold on the historical programme's same-titled step never does.
  run_hold "$home" hold old-pilot-hold --title "old pilot hold" --reason "old programme" \
    --action phase-manager-pilot --axis new_paid_spend --programme cleanroom-requalification >/dev/null || fail "AF: could not hold old pilot"
  out=$(run_resolve "$home" resolve) || fail "AF old hold resolve failed"
  expect_typed "$out" pilot-f SELF_HANDLE AUTHORIZED STANDING_GRANT "AF (old programme hold)"
  [ "$(field "$out" '.holds.ignored[] | select(.task == "old-pilot-hold") | .reason')" = HOLD_OTHER_ACTION ] || fail "AF: the old programme's pilot hold is ignored"
  run_hold "$home" hold pilot-spend --title "pilot paid runner" --reason "paid runner for the pilot" \
    --action pilot-f --axis new_paid_spend --programme cleanroom-af-package >/dev/null || fail "AF: could not hold pilot-f"
  out=$(run_resolve "$home" resolve) || fail "AF reserved hold resolve failed"
  expect_typed "$out" pilot-f CAPTAIN REQUIRES_CAPTAIN HOLD_RESERVED_AXIS "AF (reserved hold on pilot-f)"
  pass "AF a same-title-different-id hold from the historical programme never gates the pilot, while a reserved-axis hold bound to pilot-f still reaches the captain"
}

test_af_landing_without_qualification_cannot_yield_f() {
  local home out
  home=$(make_af_home af-landing)
  write_af_accepted_evidence "$home"
  # Slice A merely landed: MERGED, no bound qualification.
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED
  out=$(run_resolve "$home" resolve) || fail "landing resolve failed: $out"
  expect_typed "$out" slice-a SELF_HANDLE AUTHORIZED STANDING_GRANT "landing only"
  [ "$(field "$out" '.evidence.status')" = NOT_ACCEPTED ] && [ "$(field "$out" '.evidence.outcome')" = MERGED ] || fail "landing: the record is read as observed but not accepted"
  [ "$(field "$out" '.completed | length')" = 2 ] || fail "landing: only the ruling and C are complete"
  [ "$(field "$out" '.cno')" = null ] || fail "landing: an observed landing is not CNO"
  pass "a mere landing without its bound qualification record leaves the slice as the next action and cannot yield F"

  # Claiming qualification without binding it is malformed, and a self-report
  # cannot claim a qualification outcome at all (forged receipt).
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED_QUALIFIED
  out=$(run_resolve "$home" resolve) || fail "unbound qualification resolve failed"
  expect_cno_refusal "$out" slice-a OWNER_EVIDENCE_MALFORMED "unbound qualification"
  write_evidence "$home" slice-a.json slice-a control_report 'control#3#issuecomment-5554936473' MERGED_QUALIFIED
  out=$(run_resolve "$home" resolve) || fail "forged report resolve failed"
  expect_cno_refusal "$out" slice-a OWNER_EVIDENCE_OUTCOME_UNSUPPORTED "forged self-report"
  write_evidence "$home" slice-a.json slice-a control_report 'control#3#issuecomment-5554936473' REPORTED_SELF_TESTED
  out=$(run_resolve "$home" resolve) || fail "self-report resolve failed"
  expect_typed "$out" slice-a SELF_HANDLE AUTHORIZED STANDING_GRANT "self-report"
  [ "$(field "$out" '.evidence.status')" = NOT_ACCEPTED ] || fail "self-report: observed, not accepted"
  pass "a qualification claim without its binding is refused, a self-report cannot claim qualification, and an honest self-report is observed but never accepted"

  # No record at all: the required binding is missing, CNO, never a captain gate.
  rm "$(af_evidence_dir "$home")/slice-a.json"
  out=$(run_resolve "$home" resolve) || fail "missing evidence resolve failed"
  expect_cno_refusal "$out" slice-a REQUIRED_BINDING_MISSING "missing evidence"
  out=$(run_resolve "$home" render) || fail "missing evidence render failed"
  assert_contains "$out" "Typed result: BROWSER_SOL / CNO [REQUIRED_BINDING_MISSING]" "render states the missing binding"
  assert_contains "$out" "Evidence for slice-a: CNO [REQUIRED_BINDING_MISSING]" "render names the missing record"
  printf 'not json' > "$(af_evidence_dir "$home")/slice-a.json"
  out=$(run_resolve "$home" resolve) || fail "unreadable evidence resolve failed"
  expect_cno_refusal "$out" slice-a OWNER_EVIDENCE_UNREADABLE "unreadable evidence"
  pass "a slice whose qualification evidence is absent or unreadable resolves as REQUIRED_BINDING_MISSING / CNO, never PASS and never CAPTAIN"
}

test_af_refusal_matrix() {
  local home out psha case_name filter reason
  home=$(make_af_home af-refuse)
  write_af_accepted_evidence "$home"
  psha=$(sha_of "$home/cleanroom/artifacts/proofs/proof-b/attempt-3/disposition.json")
  # Each row mutates exactly one thing in the otherwise-accepted slice-c record.
  while IFS='|' read -r case_name reason filter; do
    [ -n "$case_name" ] || continue
    write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
      ".candidate = {head:\"9ce75aa2edcea3e94981c35fd217102a8fe26585\", merge_commit:\"dc66ba5ce35be4917424a529a45e61f4a9fa556c\"}
       | .qualification = {pipeline:\"no-mistakes\", evidence_refs:[\"https://example.invalid/evidence\"]} | $filter"
    out=$(run_resolve "$home" resolve) || fail "$case_name resolve failed: $out"
    expect_cno_refusal "$out" slice-c "$reason" "$case_name"
    pass "refused: $case_name -> $reason (BROWSER_SOL/CNO, never CAPTAIN)"
  done <<'ROWS'
wrong programme|OWNER_EVIDENCE_PROGRAMME_MISMATCH|.programme_id = "cleanroom-requalification"
wrong slice (same title, different id)|OWNER_EVIDENCE_STEP_MISMATCH|.step = "phase-manager-pilot"
wrong project|OWNER_EVIDENCE_PROJECT_MISMATCH|.project = "someone-else/firstmate-cleanroom"
wrong commission|OWNER_EVIDENCE_WORK_MISMATCH|.work_id = "cleanroom-f-execution-subject-adoption"
wrong owner|OWNER_EVIDENCE_OWNER_MISMATCH|.owner.ref = "sbracewell64/firstmate-cleanroom#6"
wrong candidate|OWNER_EVIDENCE_CANDIDATE_MISMATCH|.candidate.merge_commit = "9783fc78f0873ec436c32268ec0f10f42366033f"
superseded record|OWNER_EVIDENCE_SUPERSEDED|.superseded_by = "ev-slice-c-2"
contradictory record|OWNER_EVIDENCE_CONTRADICTORY|.observed_bad = [{predicate:"exact head", value:"observed-bad"}]
unsupported owner kind|OWNER_EVIDENCE_OWNER_KIND_UNSUPPORTED|.owner.kind = "shell_command"
unsupported schema|OWNER_EVIDENCE_SCHEMA_UNSUPPORTED|.schema = "fm-accepted-owner-evidence/v2"
malformed record|OWNER_EVIDENCE_MALFORMED|del(.owner.ref)
sources not an array|OWNER_EVIDENCE_MALFORMED|.sources = "nope"
source entry not an object|OWNER_EVIDENCE_MALFORMED|.sources = ["x"]
ROWS
  # The two malformed source shapes are refused with their precise detail and
  # a typed result (exit 0), never a resolver crash.
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]} | .sources = {kind:"local_file"}'
  out=$(run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 0 ] || fail "non-array sources must resolve to a typed result, not exit $rc: $out"
  expect_cno_refusal "$out" slice-c OWNER_EVIDENCE_MALFORMED "non-array sources"
  assert_contains "$(field "$out" '.cno.detail')" "sources must be an array (got object)" "non-array sources detail is precise"
  [ "$(field "$out" '.evidence.sources | length')" = 0 ] || fail "a non-array sources projects as no bound sources"
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]} | .sources = [{kind:"local_file", path:"policy.md", sha256:"'"$(sha_of "$home/cleanroom/policy.md")"'"}, 7]'
  out=$(run_resolve "$home" resolve 2>&1); rc=$?
  [ "$rc" = 0 ] || fail "non-object source entry must resolve to a typed result, not exit $rc: $out"
  expect_cno_refusal "$out" slice-c OWNER_EVIDENCE_MALFORMED "non-object source entry"
  assert_contains "$(field "$out" '.cno.detail')" "source entry 2 must be an object (got number)" "non-object source detail is precise"
  [ "$(field "$out" '.evidence.sources | length')" = 2 ] && [ "$(field "$out" '.evidence.sources[1].kind')" = null ] || fail "a non-object source entry projects as a null-shaped entry"
  pass "refused: malformed sources shapes (non-array, non-object entry) yield a precise OWNER_EVIDENCE_MALFORMED CNO instead of a crash"
  # An unpinned generation is not compared; pin generation 1 on the step and
  # a generation-2 record is refused.
  write_af_programme "$home" '.steps[1].terminal_predicate.evidence_generation = 1 | .steps[0].terminal_predicate.policy_digest = "'"$(sha_of "$home/cleanroom/policy.md")"'"'
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]} | .generation = 2'
  out=$(run_resolve "$home" resolve) || fail "generation pin resolve failed"
  expect_cno_refusal "$out" slice-c OWNER_EVIDENCE_GENERATION_MISMATCH "pinned evidence generation"
  pass "refused: a record from another evidence generation than the programme pins"

  # Byte pin: the exact record bytes are the evidence generation.
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]}'
  write_af_programme "$home" '.steps[1].terminal_predicate.evidence_sha256 = "'"$(sha_of "$(af_evidence_dir "$home")/slice-c.json")"'" | .steps[0].terminal_predicate.policy_digest = "'"$(sha_of "$home/cleanroom/policy.md")"'"'
  out=$(run_resolve "$home" resolve) || fail "byte pin resolve failed"
  [ "$(field "$out" '.next_action')" = pilot-f ] || fail "byte pin: the pinned bytes are accepted"
  write_evidence "$home" slice-c.json slice-c pull_request_merge 'sbracewell64/firstmate-cleanroom#5' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"dc66ba5ce35be4917424a529a45e61f4a9fa556c"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]} | .verifier.tool = "forged"'
  out=$(run_resolve "$home" resolve) || fail "forged bytes resolve failed"
  expect_cno_refusal "$out" slice-c OWNER_EVIDENCE_DIGEST_MISMATCH "forged receipt bytes"
  pass "refused: a receipt whose bytes differ from the pinned evidence generation (forged receipt)"

  # The ruling step: policy digest, bound-source digest, bound-source outcome,
  # and a wrong root.
  write_af_programme "$home" '.steps[0].terminal_predicate.policy_digest = "0000000000000000000000000000000000000000000000000000000000000000"'
  out=$(run_resolve "$home" resolve) || fail "policy resolve failed"
  expect_cno_refusal "$out" architecture-re-review-ruling OWNER_EVIDENCE_POLICY_MISMATCH "wrong policy"
  pass "refused: a ruling record under a different acceptance policy digest"
  write_af_programme "$home" '.steps[0].terminal_predicate.policy_digest = "'"$(sha_of "$home/cleanroom/policy.md")"'"'
  write_evidence "$home" ruling.json architecture-re-review-ruling control_ruling control#3#issuecomment-5554585623 PROCEED_WITH_CONDITIONS \
    ".policy = {digest:\"$(sha_of "$home/cleanroom/policy.md")\"} | .sources = [{kind:\"local_file\", path:\"artifacts/proofs/proof-b/attempt-3/disposition.json\", sha256:\"$psha\", outcome:\"CNO_AT_B-S3\"}]"
  out=$(run_resolve "$home" resolve) || fail "source outcome resolve failed"
  expect_cno_refusal "$out" architecture-re-review-ruling OWNER_EVIDENCE_SOURCE_OUTCOME_MISMATCH "unrelated CNO"
  pass "refused: a ruling record claiming a different CNO than the bound Proof-B disposition records (unrelated CNO is never accepted)"
  write_evidence "$home" ruling.json architecture-re-review-ruling control_ruling control#3#issuecomment-5554585623 PROCEED_WITH_CONDITIONS \
    ".policy = {digest:\"$(sha_of "$home/cleanroom/policy.md")\"} | .sources = [{kind:\"local_file\", path:\"artifacts/proofs/proof-b/attempt-3/disposition.json\", sha256:\"0000000000000000000000000000000000000000000000000000000000000000\", outcome:\"CNO_AT_B-S9\"}]"
  out=$(run_resolve "$home" resolve) || fail "source digest resolve failed"
  expect_cno_refusal "$out" architecture-re-review-ruling OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH "source digest"
  pass "refused: a bound source whose bytes moved (the adverse record is bound exactly, never loosely)"
  write_evidence "$home" ruling.json architecture-re-review-ruling control_ruling control#3#issuecomment-5554585623 PROCEED_WITH_CONDITIONS \
    ".policy = {digest:\"$(sha_of "$home/cleanroom/policy.md")\"} | .sources = [{kind:\"local_file\", path:\"artifacts/proofs/proof-b/attempt-3/disposition.json\", sha256:\"$psha\", outcome:\"CNO_AT_B-S9\"}]"
  mkdir -p "$home/elsewhere"
  out=$(run_resolve "$home" resolve --root "$home/elsewhere") || fail "wrong root resolve failed"
  expect_cno_refusal "$out" architecture-re-review-ruling OWNER_EVIDENCE_SOURCE_UNREADABLE "wrong root"
  pass "refused: a wrong artifact root cannot observe the bound source (CNO, never authorized)"
  write_evidence "$home" ruling.json architecture-re-review-ruling control_ruling control#3#issuecomment-5554585623 OUT_OF_SCOPE_CAPTAIN_RESERVED \
    ".policy = {digest:\"$(sha_of "$home/cleanroom/policy.md")\"}"
  out=$(run_resolve "$home" resolve) || fail "ruling not accepted resolve failed"
  expect_typed "$out" architecture-re-review-ruling BROWSER_SOL REQUIRES_RULING STEP_REQUIRES_RULING "ruling not accepted"
  [ "$(field "$out" '.evidence.status')" = NOT_ACCEPTED ] || fail "a recorded reserved-directive ruling is observed, not accepted, and waits on Browser Sol"
  pass "a ruling record whose decision is not the accepted one leaves the predecessor step waiting on Browser Sol rather than fabricating a proof attempt or a captain gate"
}

test_af_structure_and_binding_refusals() {
  local home err rc
  home=$(make_af_home af-structure)
  write_af_accepted_evidence "$home"
  refuse_load() {  # <label> <jq-filter> <expected-text>
    write_af_programme "$home" "$2 | .steps[0].terminal_predicate.policy_digest = \"$(sha_of "$home/cleanroom/policy.md")\""
    err=$(run_resolve "$home" resolve 2>&1 >/dev/null); rc=$?
    [ "$rc" = 1 ] || fail "$1: expected refusal exit 1, got $rc"
    assert_contains "$err" "$3" "$1 refusal names the defect"
    pass "refused at load: $1"
  }
  refuse_load "duplicate step ids" '.steps[2].id = "slice-c"' "duplicated: slice-c"
  refuse_load "unsupported evidence kind" '.steps[2].terminal_predicate.kind = "shell_predicate"' "terminal_predicate.kind must be one of"
  refuse_load "dependency on a later step (order contradiction)" '.steps[1].depends_on = ["pilot-f"]' "depends on a LATER step pilot-f"
  refuse_load "dependency on itself (cycle)" '.steps[1].depends_on = ["slice-c"]' "depends on itself"
  refuse_load "dependency on an unknown step" '.steps[1].depends_on = ["slice-z"]' "depends on an unknown step slice-z"
  refuse_load "missing required binding" 'del(.binding)' "REQUIRED_BINDING_MISSING"
  refuse_load "consumer contract mismatch" '.binding.consumer.contract = "fm-continuation-resolution/v2"' "binding.consumer.contract must name"
  refuse_load "unsupported bound evidence kind" '.binding.evidence_kinds += ["arbitrary_command"]' "unsupported completion-evidence kind arbitrary_command"
  refuse_load "binding does not cover a step kind" '.binding.evidence_kinds = ["latest_attempt_disposition_outcome_in"]' "does not declare"
  refuse_load "binding generation mismatch" '.binding.programme_generation = "fm-af-programme/v0"' "does not match the programme schema"
  refuse_load "binding without a programme generation" 'del(.binding.programme_generation)' "binding.programme_generation is required"
  refuse_load "owner step without an evidence path" 'del(.steps[2].terminal_predicate.evidence)' "names no terminal_predicate.evidence record"

  # A legacy proof-only programme still resolves, and every reader sees the
  # missing binding loudly rather than as an optional N/A.
  local legacy out
  legacy=$(make_home af-legacy)
  disposition "$legacy" proof-a 1 PROVED
  out=$(run_resolve "$legacy" resolve) || fail "legacy resolve failed"
  expect_typed "$out" proof-b SELF_HANDLE AUTHORIZED STANDING_GRANT "legacy"
  [ "$(field "$out" '.binding.present')" = false ] && [ "$(field "$out" '.binding.reason')" = REQUIRED_BINDING_MISSING ] || fail "legacy: binding reported missing"
  out=$(run_resolve "$legacy" render) || fail "legacy render failed"
  assert_contains "$out" "Binding: REQUIRED_BINDING_MISSING" "legacy render prints the missing binding"
  out=$(run_resolve "$legacy" summary) || fail "legacy summary failed"
  assert_contains "$out" "binding=REQUIRED_BINDING_MISSING" "legacy summary prints the missing binding"
  pass "a legacy proof-only programme resolves with REQUIRED_BINDING_MISSING printed by every reader, never a silent N/A"
}

test_af_applicability_invalidation() {
  local home base out
  home=$(make_af_home af-applicability)
  write_af_accepted_evidence "$home"
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED
  base=$(run_resolve "$home" resolve) || fail "base resolve failed"
  [ "$(field "$base" '.next_action')" = slice-a ] || fail "base: slice-a is next"
  # Evidence change (the record is re-issued): both digests move.
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED '.generation = 2'
  out=$(run_resolve "$home" resolve) || fail "evidence-change resolve failed"
  [ "$(field "$out" '.applicability_digest')" != "$(field "$base" '.applicability_digest')" ] || fail "an evidence change must move the applicability digest"
  [ "$(field "$out" '.material_identity')" != "$(field "$base" '.material_identity')" ] || fail "an evidence change must move the material identity"
  [ "$(field "$out" '.applicability.evidence.sha256')" != "$(field "$base" '.applicability.evidence.sha256')" ] || fail "applicability binds the evidence bytes"
  pass "a re-issued evidence record invalidates the prior applicability and material identity"
  # Grant supersession invalidates authority.
  write_af_programme "$home" '.authorization_basis.superseded_by = "control#3#issuecomment-9999" | .steps[0].terminal_predicate.policy_digest = "'"$(sha_of "$home/cleanroom/policy.md")"'"'
  out=$(run_resolve "$home" resolve) || fail "superseded grant resolve failed"
  expect_typed "$out" slice-a BROWSER_SOL CNO GRANT_SUPERSEDED "superseded grant"
  pass "a superseded grant cannot authorize any A-F step"
  write_af_programme "$home" '.steps[0].terminal_predicate.policy_digest = "'"$(sha_of "$home/cleanroom/policy.md")"'"'
  # A newly bound hold moves the identity; lifting it restores it.
  bound_hold "$home" slice-a-wait external slice-a '' cleanroom-af-package external
  out=$(run_resolve "$home" resolve) || fail "hold resolve failed"
  expect_typed "$out" slice-a EXTERNAL_DEPENDENCY WAITING_EXTERNAL HOLD_EXTERNAL_WAIT "hold on slice-a"
  [ "$(field "$out" '.material_identity')" != "$(field "$base" '.material_identity')" ] || fail "a gating hold must move the material identity"
  tasks_in "$home" unhold slice-a-wait >/dev/null
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED
  out=$(run_resolve "$home" resolve) || fail "restored resolve failed"
  [ "$(field "$out" '.material_identity')" = "$(field "$base" '.material_identity')" ] || fail "restored state converges on the same identity"
  pass "hold supersession and restoration move and restore the material identity deterministically"
  # The identity excludes every path: the same material state resolved from a
  # copy of the home at another absolute path (a CNO whose detail names the
  # missing record's path) yields the same identity.
  local moved
  rm -f "$(af_evidence_dir "$home")/slice-a.json"
  base=$(run_resolve "$home" resolve) || fail "unbound resolve failed"
  expect_cno_refusal "$base" slice-a REQUIRED_BINDING_MISSING "unbound slice-a"
  moved="$TMP_ROOT/af-applicability-moved-elsewhere"
  cp -R "$home" "$moved"
  printf 'programme=%s\nroot=%s\n' "$(af_programme_path "$moved")" "$moved/cleanroom" > "$moved/config/programme"
  out=$(run_resolve "$moved" resolve) || fail "moved-home resolve failed"
  expect_cno_refusal "$out" slice-a REQUIRED_BINDING_MISSING "unbound slice-a from the moved home"
  [ "$(field "$out" '.cno.detail')" != "$(field "$base" '.cno.detail')" ] || fail "the CNO detail names the home's own path"
  [ "$(field "$out" '.programme.path')" != "$(field "$base" '.programme.path')" ] || fail "the moved home is located at its own path"
  [ "$(field "$out" '.material_identity')" = "$(field "$base" '.material_identity')" ] || fail "the material identity must not change with the home's absolute path"
  pass "the material identity is the same for the same material state resolved from a home at another absolute path"
}

# --- quiet presentation: present once, stay quiet, ack only what was presented ---

DRAIN="$ROOT/bin/fm-wake-drain.sh"

run_drain() {  # <home> [drain args...]
  local home=$1
  shift
  # FM_ROOT_OVERRIDE points fm-guard's tangle check at a non-git directory so
  # the drain prints no spurious banner (the same trick tests/wake-helpers.sh uses).
  FM_TASKS_AXI_COMPATIBLE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$home/tangle-root" FM_CONTINUATION_TODAY=2026-09-04 "$DRAIN" "$@"
}

queue_wake() {  # <home>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append heartbeat fixture "fixture wake"
  ' _ "$ROOT/bin/fm-wake-lib.sh"
}

test_af_presentation_quiet_and_ack_race() {
  local home out ack first second third presented snap view token
  home=$(make_af_home af-present)
  mkdir -p "$home/tangle-root"
  write_af_accepted_evidence "$home"
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED
  first=$(run_resolve "$home" resolve | jq -r '.material_identity')

  # Empty queue, nothing to acknowledge later: presented once and committed.
  out=$(run_drain "$home" 2>/dev/null) || fail "first drain failed"
  assert_contains "$out" "PROGRAMME CONTINUATION (material state changed since last presented" "first drain presents the programme once"
  assert_contains "$out" "next action slice-a" "the presentation carries the typed next action"
  assert_contains "$out" "presented identity ${first:0:12} (acknowledged with this presentation" "a no-ack turn commits at presentation"
  [ "$(jq -r '.material_identity' "$home/state/.programme-presented")" = "$first" ] || fail "the presented record carries the exact identity"
  out=$(run_drain "$home" 2>/dev/null) || fail "second drain failed"
  printf '%s' "$out" | grep -q "PROGRAMME CONTINUATION" && fail "an unchanged poll must stay quiet: $out"
  out=$(run_drain "$home" 2>/dev/null) || fail "third drain failed"
  printf '%s' "$out" | grep -q "PROGRAMME CONTINUATION" && fail "a restart over unchanged state must stay quiet"
  pass "unchanged programme state is presented once and then stays quiet across polls and restarts"

  # The snapshot, view, and away digest read the same presented identity.
  snap=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$SNAPSHOT" --json) || fail "snapshot failed"
  [ "$(field "$snap" '.programme_continuation.presentation.state')" = unchanged ] || fail "snapshot marks the presented state unchanged"
  [ "$(field "$snap" '.programme_continuation.presentation.presented_identity')" = "$first" ] || fail "snapshot carries the presented identity"
  view=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 "$VIEW") || fail "view failed"
  assert_contains "$view" "Binding: grant 5554812621 commission cleanroom-af-package." "view prints the binding"
  assert_contains "$view" "Presentation: unchanged since last presented (identity ${first:0:12}); not news." "view marks unchanged state as not news"
  token=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 bash -c '. "$1"; programme_digest_token "$2"' _ "$ROOT/bin/fm-supervise-daemon.sh" "$home/state")
  [ -z "$token" ] || fail "the away digest must not re-announce presented state: $token"
  pass "status and away-digest readers key on the presented identity and do not recap unchanged state"

  # A material change with a queued wake: presented as pending, acknowledged
  # only by the printed ack, and the identity acknowledged is the one
  # presented even when state moves again in between (the race).
  write_evidence "$home" slice-a.json slice-a pull_request_merge 'sbracewell64/firstmate-cleanroom#9' MERGED_QUALIFIED \
    '.candidate = {merge_commit:"1111111111111111111111111111111111111111"} | .qualification = {pipeline:"no-mistakes", evidence_refs:["x"]}'
  second=$(run_resolve "$home" resolve | jq -r '.material_identity')
  [ "$second" != "$first" ] || fail "fixture: qualification must change the identity"
  token=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CONTINUATION_TODAY=2026-09-04 bash -c '. "$1"; programme_digest_token "$2"' _ "$ROOT/bin/fm-supervise-daemon.sh" "$home/state")
  assert_contains "$token" "next=pilot-f SELF_HANDLE/AUTHORIZED" "the away digest announces a material change"
  queue_wake "$home"
  out=$(run_drain "$home" 2>"$home/drain.err") || fail "wake drain failed"
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' "$home/drain.err")
  [ -n "$ack" ] || fail "the wake drain must print its acknowledgement command"
  assert_contains "$out" "next action pilot-f" "the changed state is presented with the wake"
  assert_contains "$out" "presented identity ${second:0:12}; it is acknowledged by the WAKE_ACK_REQUIRED command" "an ack turn records a pending identity"
  [ "$(jq -r '.material_identity' "$home/state/.programme-presented.pending")" = "$second" ] || fail "the pending record carries the presented identity"
  [ "$(jq -r '.material_identity' "$home/state/.programme-presented")" = "$first" ] || fail "the acknowledged record is untouched until the ack"
  out=$(run_drain "$home" 2>/dev/null) || fail "re-drain failed"
  printf '%s' "$out" | grep -q "PROGRAMME CONTINUATION" && fail "a duplicate drain before the ack must not re-present the pending identity"
  # State moves again between presentation and acknowledgement.
  bound_hold "$home" pilot-wait external pilot-f '' cleanroom-af-package external
  third=$(run_resolve "$home" resolve | jq -r '.material_identity')
  [ "$third" != "$second" ] || fail "fixture: the hold must change the identity"
  # shellcheck disable=SC2086
  run_drain "$home" $ack >/dev/null 2>&1 || fail "ack failed"
  presented=$(jq -r '.material_identity' "$home/state/.programme-presented")
  [ "$presented" = "$second" ] || fail "the ack must acknowledge exactly the presented identity, not the newer state"
  [ ! -e "$home/state/.programme-presented.pending" ] || fail "the pending record is consumed by the ack"
  out=$(run_drain "$home" 2>/dev/null) || fail "post-ack drain failed"
  assert_contains "$out" "PROGRAMME CONTINUATION (material state changed" "state that moved between presentation and ack surfaces at the next drain"
  assert_contains "$out" "EXTERNAL_DEPENDENCY / WAITING_EXTERNAL" "the newer state is what surfaces"
  [ "$(jq -r '.material_identity' "$home/state/.programme-presented")" = "$third" ] || fail "the newer identity is committed by the no-ack drain"
  pass "a material change is presented once per identity, acknowledged only as presented, and state that moves between presentation and acknowledgement surfaces again instead of being swallowed"
}

timed() {  # <test-function>
  local start=$SECONDS
  "$1"
  [ -z "${FM_TEST_TIMING:-}" ] || printf '# %s: %ss\n' "$1" "$((SECONDS - start))"
}

timed test_f1_authorized_continuation
timed test_f2_lifted_hold_is_not_authoritative
timed test_f3_f4_ruling_and_external_waits
timed test_f5_f9_reserved_axis_without_hold_materializes
timed test_foreign_hold_sharing_axis_does_not_cover_fact
timed test_materialize_never_rebinds_foreign_binding
timed test_f7_scoped_hold_does_not_leak
timed test_f8_captain_claim_without_axis_is_refused
timed test_grant_applicability_is_cno
timed test_unreadable_inputs_are_cno
timed test_completion_and_configuration
timed test_render_and_check_prose
timed test_captain_hold_binding_mechanics
timed test_consumers_project_the_typed_result
timed test_af_accepted_owner_evidence_yields_f
timed test_af_landing_without_qualification_cannot_yield_f
timed test_af_refusal_matrix
timed test_af_structure_and_binding_refusals
timed test_af_applicability_invalidation
timed test_af_presentation_quiet_and_ack_race

echo "# fm-continuation-resolve.test.sh: all assertions passed"
