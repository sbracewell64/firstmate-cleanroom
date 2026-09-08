#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

# --- typed input-mode gate script -------------------------------------------
#
# bin/fm-nmf-verify-input.sh owns the typed input mode the workflow wraps around
# the pinned verifier: which events are judged on their historical event
# snapshot, which are re-bound to the live PR subject, and the identity,
# superseded-subject, and read-back guards that keep a stale event from being
# reinterpreted against newer PR state. These fixtures exercise it through its
# real executable interface, including end to end into the fetched verifier.

NMF_HELPER="$ROOT/bin/fm-nmf-verify-input.sh"

attested_body() {
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->' \
    "$SIGNATURE" "$1" "$COMPLETED_STEPS"
}

# Parse a head_sha= line and a body<<DELIM ... DELIM block out of resolve's
# GITHUB_OUTPUT-format stdout, so a test can feed exactly what the workflow
# would hand the verifier.
extract_output_head() {
  printf '%s\n' "$1" | sed -n 's/^head_sha=//p' | head -1
}
extract_output_body() {
  printf '%s\n' "$1" | awk '
    /^body<</ { delim = substr($0, index($0, "<<") + 2); grab = 1; next }
    grab && $0 == delim { grab = 0; next }
    grab { print }
  '
}

test_classify_opened_and_edited_are_historical() {
  local action out
  for action in opened edited; do
    out=$(NMF_EVENT_ACTION="$action" "$NMF_HELPER" classify) \
      || fail "classify $action exited non-zero"
    [ "$out" = "mode=historical" ] \
      || fail "classify $action should be historical, got: $out"
  done
  pass "opened and edited classify as historical event-snapshot mode"
}

test_classify_synchronize_and_reopened_are_current() {
  local action out
  for action in synchronize reopened; do
    out=$(NMF_EVENT_ACTION="$action" "$NMF_HELPER" classify) \
      || fail "classify $action exited non-zero"
    [ "$out" = "mode=current" ] \
      || fail "classify $action should be current, got: $out"
  done
  pass "synchronize and reopened classify as current-state recovery mode"
}

test_classify_unknown_action_fails_closed() {
  local rc=0
  NMF_EVENT_ACTION=labeled "$NMF_HELPER" classify >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "classify accepted an unrecognized event action"
  pass "classify fails closed on an unrecognized event action"
}

test_resolve_matching_subject_emits_live_body_and_subject_head() {
  local body out rc
  body=$(attested_body "$NEW_SHA")
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$body" \
    "$NMF_HELPER" resolve) || rc=$?
  expect_code 0 "$rc" "resolve rejected a live subject that matches the event subject"
  [ "$(extract_output_head "$out")" = "$NEW_SHA" ] \
    || fail "resolve did not emit the subject head"
  assert_contains "$out" "subject_head=$NEW_SHA" "resolve did not carry the subject head for read-back"
  assert_contains "$out" "subject_number=3006" "resolve did not carry the subject number for read-back"
  assert_contains "$(extract_output_body "$out")" "$NEW_SHA" \
    "resolve did not emit the live body carrying the current-head attestation"
  pass "resolve binds a matching subject and emits the live body and subject head"
}

test_resolve_superseded_head_fails_closed() {
  local rc=0 out
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$OLD_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$(attested_body "$NEW_SHA")" \
    "$NMF_HELPER" resolve 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve let an old-head event bind a newer advanced head"
  assert_contains "$out" "superseded" "superseded failure did not name the condition"
  pass "resolve refuses a superseded subject so an old-head run cannot publish for a newer head"
}

test_resolve_identity_mismatch_fails_closed() {
  local rc=0 out
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=9999 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$(attested_body "$NEW_SHA")" \
    "$NMF_HELPER" resolve 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve accepted a live read for a different PR"
  assert_contains "$out" "identity" "identity-mismatch failure did not name the condition"
  pass "resolve fails closed when the live read is a different PR than the event subject"
}

test_resolve_missing_input_fails_closed() {
  local rc=0
  NMF_EVENT_NUMBER=3006 "$NMF_HELPER" resolve >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve accepted a partial input set"
  pass "resolve fails closed on a missing required input"
}

test_resolve_empty_live_body_fails_closed() {
  local rc=0 out
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="" \
    "$NMF_HELPER" resolve 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve emitted a result for an empty live body in current mode"
  case "$out" in
    *"body<<"*) fail "resolve emitted a body block for an empty live body, which the verifier resolves through the frozen event" ;;
  esac
  pass "resolve fails closed on an empty live body so it cannot pass via the frozen event"
}

test_readback_unchanged_subject_passes() {
  local rc=0
  NMF_SUBJECT_NUMBER=3006 NMF_SUBJECT_HEAD="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" \
    "$NMF_HELPER" readback >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "read-back failed for a subject that did not move"
  pass "read-back passes when the verified subject is still current"
}

test_readback_advanced_subject_fails_closed() {
  local rc=0 out
  out=$(NMF_SUBJECT_NUMBER=3006 NMF_SUBJECT_HEAD="$OLD_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" \
    "$NMF_HELPER" readback 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "read-back let a result stand after the subject advanced"
  assert_contains "$out" "advanced" "read-back failure did not name the advance"
  pass "read-back refuses to publish a result after the subject advanced during verification"
}

# End to end: a current-state event whose event payload would be one generation
# late still PASSES when the live body is soundly attested to the live head. The
# gate script re-binds to the live subject; the verifier then judges live state.
test_current_mode_sound_live_proof_passes() {
  local body out rc verifier_out
  body=$(attested_body "$NEW_SHA")
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$body" \
    "$NMF_HELPER" resolve) || rc=$?
  expect_code 0 "$rc" "resolve rejected a sound current-head subject"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  expect_code 0 "$rc" "the verifier false-failed a sound current-head live proof"
  assert_contains "$verifier_out" "Found structurally compliant pipeline step attestation." \
    "the verifier did not accept the bound live proof"
  pass "current mode passes a stale-event PR whose live body is soundly attested to the live head"
}

# A current-state event whose live body is attested to a DIFFERENT head than the
# live head is held in the publication-timing window (PENDING, exit 3) rather
# than bound. This is the FAIL-then-SUCCESS race: 'git push no-mistakes' advances
# the head, then re-publishes the body attestation for it, so a synchronize event
# can read the body between those steps. resolve emits no body block in this
# state, so a not-yet-bound body can never reach the verifier as bound; the
# caller re-reads within its bounded window (or fails closed at the deadline).
test_resolve_pending_when_attestation_bound_to_other_head() {
  local body out rc
  body=$(attested_body "$OLD_SHA")
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$body" \
    "$NMF_HELPER" resolve 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "resolve should report PENDING (exit 3) for a body not yet bound to the live head, got rc=$rc"
  case "$out" in
    *"body<<"*) fail "PENDING resolve emitted a body block; a not-yet-bound body must never be handed to the verifier as bound" ;;
    *"head_sha="*) fail "PENDING resolve emitted a head_sha output; it must emit no resolved subject" ;;
  esac
  pass "resolve holds a body bound to another head as PENDING and emits no subject"
}

# The PENDING notice names both the attested head and the live head, so a
# workflow log makes the publication-window wait diagnosable.
test_resolve_pending_notice_names_both_heads() {
  local err rc
  rc=0
  err=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$(attested_body "$OLD_SHA")" \
    "$NMF_HELPER" resolve 2>&1 >/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "expected PENDING exit 3, got rc=$rc"
  assert_contains "$err" "$OLD_SHA" "PENDING notice did not name the attested head"
  assert_contains "$err" "$NEW_SHA" "PENDING notice did not name the live head"
  assert_contains "$err" "::notice::" "PENDING must annotate as ::notice::, not a hard ::error::"
  pass "resolve PENDING notice names the attested and live heads for diagnosis"
}

# A non-empty live body with no pipeline attestation yet published is also
# PENDING, not a pass: mid-publication the body may carry the signature line
# before the attestation comment lands. It never binds, so the caller's bounded
# window fails closed at the deadline - a genuinely non-no-mistakes body can
# never pass this way.
test_resolve_pending_when_no_attestation_published_yet() {
  local out rc
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="a body with no attestation comment" \
    "$NMF_HELPER" resolve 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "resolve should report PENDING (exit 3) when no attestation is published yet, got rc=$rc"
  case "$out" in
    *"body<<"*) fail "PENDING resolve emitted a body block for an unattested body" ;;
  esac
  pass "resolve holds an unattested body as PENDING within the publication window"
}

# End to end: once the live body binds the live head (publication landed), resolve
# is BOUND and the verifier passes - the race resolves green with no re-attest,
# restart, or manual step. This is the positive watched case.
test_current_mode_race_resolves_green_once_body_binds_live_head() {
  local out rc verifier_out
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$(attested_body "$NEW_SHA")" \
    "$NMF_HELPER" resolve) || rc=$?
  expect_code 0 "$rc" "resolve should be BOUND once the body binds the live head"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  expect_code 0 "$rc" "the verifier should pass the bound live proof after the publication window"
  assert_contains "$verifier_out" "Found structurally compliant pipeline step attestation." \
    "the verifier did not accept the bound live proof after the race resolved"
  pass "the publication-timing race resolves green once the body binds the live head"
}

# End to end: a historically invalid opened/edited body stays invalid. Those
# events are classified historical, so the gate never substitutes a later clean
# live body; the verifier judges the event-snapshot body, which is invalid.
test_historical_invalid_body_is_not_rescued_by_a_clean_live_body() {
  local mode invalid_event_body rc verifier_out
  mode=$(NMF_EVENT_ACTION=edited "$NMF_HELPER" classify)
  [ "$mode" = "mode=historical" ] || fail "edited must stay historical so a clean live body cannot rescue it"
  # The event-snapshot body attests an older head than the event head: invalid.
  invalid_event_body=$(attested_body "$OLD_SHA")
  rc=0
  verifier_out=$(run_verifier "$invalid_event_body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "a historically invalid event-snapshot body was accepted"
  pass "a historically invalid opened/edited body stays invalid under the event snapshot"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_classify_opened_and_edited_are_historical
test_classify_synchronize_and_reopened_are_current
test_classify_unknown_action_fails_closed
test_resolve_matching_subject_emits_live_body_and_subject_head
test_resolve_superseded_head_fails_closed
test_resolve_identity_mismatch_fails_closed
test_resolve_missing_input_fails_closed
test_resolve_empty_live_body_fails_closed
test_readback_unchanged_subject_passes
test_readback_advanced_subject_fails_closed
test_current_mode_sound_live_proof_passes
test_resolve_pending_when_attestation_bound_to_other_head
test_resolve_pending_notice_names_both_heads
test_resolve_pending_when_no_attestation_published_yet
test_current_mode_race_resolves_green_once_body_binds_live_head
test_historical_invalid_body_is_not_rescued_by_a_clean_live_body
