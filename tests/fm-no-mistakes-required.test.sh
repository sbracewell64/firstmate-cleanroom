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

# A signature-bearing live body with no pipeline attestation yet published is
# also PENDING, not a pass: mid-publication the body may carry the signature line
# before the attestation comment lands. It never binds, so it can only ever reach
# the verifier through the deadline hand-off below, which refuses it.
test_resolve_pending_when_no_attestation_published_yet() {
  local out rc
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$SIGNATURE" \
    "$NMF_HELPER" resolve 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "resolve should report PENDING (exit 3) when no attestation is published yet, got rc=$rc"
  case "$out" in
    *"body<<"*) fail "PENDING resolve emitted a body block for an unattested body" ;;
  esac
  pass "resolve holds a signature-bearing unattested body as PENDING within the publication window"
}

# --- waiting only where a publication is in flight ---------------------------
#
# PENDING means "a no-mistakes publication owns this body and a rebind for the
# live head is in flight". The signature line is that evidence. Without it
# nothing is publishing, so waiting cannot change the outcome: resolve hands the
# live subject straight to the verifier, which refuses it on its own authority
# and with its own actionable message. This is what keeps the gate's primary
# case - a PR that did not come through no-mistakes - failing immediately rather
# than sitting out a publication window it can never satisfy.
test_resolve_unsigned_body_hands_off_instead_of_waiting() {
  local out err rc verifier_out
  rc=0
  err=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="a hand-written PR body" \
    "$NMF_HELPER" resolve 2>&1 >/dev/null) || rc=$?
  expect_code 0 "$rc" "resolve should hand off a body with no publication in flight, not wait for one"
  assert_contains "$err" "no no-mistakes signature" "the hand-off did not say why it is not waiting"
  rc=0
  out=$(NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="a hand-written PR body" \
    "$NMF_HELPER" resolve 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "resolve should emit a subject for an unsigned body"
  [ "$(extract_output_head "$out")" = "$NEW_SHA" ] \
    || fail "the hand-off did not carry the live head, so the verifier could not judge the right commit"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "the verifier accepted a PR body that was never raised through no-mistakes"
  assert_contains "$verifier_out" "was not raised through no-mistakes" \
    "the verifier did not produce its own refusal for the handed-off body"
  pass "a body with no publication in flight is judged immediately and fails closed"
}

# At the caller's deadline the wait is over, but the verdict is still the
# verifier's. resolve emits the live subject with a truthful warning and the
# pinned verifier refuses the unbound attestation naming both SHAs, so the
# fail-closed property is preserved by the component that owns it.
test_resolve_final_hands_off_an_unbound_body_and_the_verifier_refuses_it() {
  local out err rc verifier_out body
  body=$(attested_body "$OLD_SHA")
  rc=0
  err=$(NMF_PUBLICATION_FINAL=1 NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$body" \
    "$NMF_HELPER" resolve 2>&1 >/dev/null) || rc=$?
  expect_code 0 "$rc" "a closed publication window must still produce a judged subject"
  assert_contains "$err" "$OLD_SHA" "the closed-window warning did not name the attested head"
  assert_contains "$err" "$NEW_SHA" "the closed-window warning did not name the live head"
  rc=0
  out=$(NMF_PUBLICATION_FINAL=1 NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    NMF_LIVE_NUMBER=3006 NMF_LIVE_HEAD_SHA="$NEW_SHA" NMF_LIVE_BODY="$body" \
    "$NMF_HELPER" resolve 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a closed publication window must emit the live subject"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "the verifier accepted an attestation that never bound the live head"
  assert_contains "$verifier_out" "$OLD_SHA" "the refusal did not name the attestation head"
  assert_contains "$verifier_out" "$NEW_SHA" "the refusal did not name the live PR head"
  pass "a publication that never lands is refused by the verifier, naming both heads"
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

# --- the publication wait, through the await command -------------------------
#
# 'await' is the whole live-subject step the workflow runs, so these cases drive
# the real poll loop, deadline and hand-off through its executable interface with
# a scripted provider. Each case lays out the PR reads the provider returns in
# order (read-1.json, read-2.json, ... then read-default.json for every later
# read), so a race is expressed as data rather than as a timing coincidence.
# sleep is replaced by a recorder so a 600s window costs no wall-clock time while
# the loop's real read/wait/deadline arithmetic still runs.

AWAIT_ROOT="$TMP_ROOT/await"

await_case() {
  local name=$1
  AWAIT_CASE="$AWAIT_ROOT/$name"
  AWAIT_BIN="$AWAIT_CASE/bin"
  rm -rf "$AWAIT_CASE"
  mkdir -p "$AWAIT_BIN"
  cat > "$AWAIT_BIN/gh" <<SH
#!/usr/bin/env bash
printf 'x' >> "$AWAIT_CASE/reads"
reads=\$(wc -c < "$AWAIT_CASE/reads" | tr -d ' ')
response="$AWAIT_CASE/read-\$reads.json"
[ -f "\$response" ] || response="$AWAIT_CASE/read-default.json"
[ -f "\$response" ] || exit 1
cat "\$response"
SH
  cat > "$AWAIT_BIN/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$AWAIT_CASE/sleeps"
SH
  chmod +x "$AWAIT_BIN/gh" "$AWAIT_BIN/sleep"
  : > "$AWAIT_CASE/reads"
  : > "$AWAIT_CASE/sleeps"
}

# One scripted PR read. `which` is a read index (1, 2, ...) or "default".
await_read() {
  local which=$1 number=$2 head=$3 body=$4
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"number": int(sys.argv[1]), "head": {"sha": sys.argv[2]}, "body": sys.argv[3]}))' \
    "$number" "$head" "$body" > "$AWAIT_CASE/read-$which.json"
}

run_await() {
  PATH="$AWAIT_BIN:$PATH" GITHUB_REPOSITORY=regression/gate \
    NMF_EVENT_NUMBER=3006 NMF_EVENT_HEAD_SHA="$NEW_SHA" \
    "$NMF_HELPER" await
}

await_reads() { wc -c < "$AWAIT_CASE/reads" | tr -d ' '; }
await_sleeps() { wc -l < "$AWAIT_CASE/sleeps" | tr -d ' '; }

# The watched regression. A synchronize event whose push has landed but whose
# attestation has not been re-published yet must resolve green on its own, with
# no re-run: the loop keeps reading the same subject and binds the moment the
# publication lands.
test_await_binds_when_the_publication_lands_mid_wait() {
  local out rc verifier_out
  await_case race-resolves
  await_read 1 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  await_read 2 3006 "$NEW_SHA" "$SIGNATURE"
  await_read default 3006 "$NEW_SHA" "$(attested_body "$NEW_SHA")"
  rc=0
  out=$(run_await 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "await failed a PR whose attestation did publish, the exact race this fix is for"
  [ "$(await_reads)" -eq 3 ] || fail "await should bind on the first read that carries the published attestation, took $(await_reads)"
  [ "$(await_sleeps)" -eq 2 ] || fail "await should wait once per not-yet-published read, waited $(await_sleeps) times"
  [ "$(extract_output_head "$out")" = "$NEW_SHA" ] || fail "await did not emit the live head as the judged subject"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  expect_code 0 "$rc" "the verifier rejected the attestation await waited for"
  assert_contains "$verifier_out" "Found structurally compliant pipeline step attestation." \
    "the published attestation was not accepted after the wait"
  pass "a race-timed synchronize resolves green once the publication lands, with no re-run"
}

# The deadline is a real bound, not a longer guess: when the publication never
# lands the wait ends and the verifier refuses the live body.
test_await_stops_at_the_deadline_and_fails_closed() {
  local out rc verifier_out err
  await_case never-publishes
  await_read default 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  rc=0
  err=$(NMF_PUBLICATION_WINDOW_SECONDS=2 NMF_PUBLICATION_POLL_SECONDS=1 run_await 2>&1 >/dev/null) || rc=$?
  expect_code 0 "$rc" "await must still produce a judged subject when the window closes"
  assert_contains "$err" "publication window is closed" "the timeout message did not say the window closed"
  assert_contains "$err" "$NEW_SHA" "the timeout message did not name the head it waited for"
  # Every poll read soundly here, so the publisher is the only honest cause to
  # name; a read outage must not be implied when nothing failed to read.
  assert_contains "$err" "still unpublished" \
    "a wait whose every poll read soundly did not attribute the outcome to the publisher"
  case "$err" in
    *"could not be read"*) fail "a wait with no failed read reported unreadable polls" ;;
  esac
  await_case never-publishes-verdict
  await_read default 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  rc=0
  out=$(NMF_PUBLICATION_WINDOW_SECONDS=2 NMF_PUBLICATION_POLL_SECONDS=1 run_await 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "await must emit the live subject at the deadline"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "a PR whose attestation never published was allowed to pass the gate"
  pass "a publication that never lands ends the wait and still fails closed"
}

# A PR that did not come through no-mistakes is the gate's primary case and must
# not pay the publication window at all.
test_await_does_not_wait_when_no_publication_is_in_flight() {
  local out rc verifier_out
  await_case unsigned
  await_read default 3006 "$NEW_SHA" "a hand-written PR body"
  rc=0
  out=$(run_await 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "await should hand an unsigned body straight to the verifier"
  [ "$(await_reads)" -eq 1 ] || fail "await read the PR $(await_reads) times for a body nothing is publishing"
  [ "$(await_sleeps)" -eq 0 ] || fail "await waited for a publication that was never in flight"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "the verifier accepted a PR that was not raised through no-mistakes"
  pass "a PR with nothing publishing is judged on the first read, with no wait"
}

# Exact candidate/head association: if the head advances while we wait, this run
# is about a head that no longer exists on the PR. It must refuse immediately
# rather than keep waiting or judge the newer head, which fires its own run.
test_await_refuses_a_superseded_head_immediately() {
  local err rc
  await_case superseded
  await_read 1 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  await_read default 3006 "$OLD_SHA" "$(attested_body "$OLD_SHA")"
  rc=0
  err=$(run_await 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "await let a run continue after its subject head was superseded"
  assert_contains "$err" "superseded" "the refusal did not name the superseded subject"
  [ "$(await_reads)" -eq 2 ] || fail "await kept waiting after the head advanced, read $(await_reads) times"
  pass "await refuses a superseded head immediately instead of waiting or rebinding"
}

# No sound live read means no sound subject: the frozen event payload must never
# become the fallback.
test_await_fails_closed_when_the_live_pr_cannot_be_read() {
  local out err rc
  await_case unreadable
  rc=0
  out=$( export NMF_PUBLICATION_WINDOW_SECONDS=1 NMF_PUBLICATION_POLL_SECONDS=1
         run_await 2>"$AWAIT_CASE/err" ) || rc=$?
  err=$(cat "$AWAIT_CASE/err")
  [ "$rc" -ne 0 ] || fail "await produced a subject without a sound live read"
  assert_contains "$err" "no sound live read" "the read failure was not reported"
  case "$out" in
    *"body<<"*) fail "await emitted a body block without a live read" ;;
  esac
  pass "an unreadable live PR fails closed instead of falling back to the frozen event"
}

# A malformed bound must not silently become "judge immediately" or "wait
# forever". The settings are exported inside a subshell rather than passed as a
# `env NAME=v run_await` prefix: run_await is a shell function, so `env` would
# fail to exec it (127) and the case would pass without ever reaching await.
test_await_refuses_a_malformed_bound() {
  local rc out setting value
  for setting in NMF_PUBLICATION_WINDOW_SECONDS NMF_PUBLICATION_POLL_SECONDS \
                 NMF_LIVE_READ_ATTEMPTS NMF_LIVE_READ_BACKOFF_SECONDS; do
    for value in soon 0 -1; do
      await_case "malformed-$setting"
      await_read default 3006 "$NEW_SHA" "$(attested_body "$NEW_SHA")"
      rc=0
      out=$( export "$setting=$value"; run_await 2>&1 >/dev/null ) || rc=$?
      [ "$rc" -ne 0 ] || fail "await accepted $setting='$value'"
      assert_contains "$out" "$setting" "the refusal did not name the malformed setting $setting"
      [ "$(await_reads)" -eq 0 ] \
        || fail "await read the live PR before refusing a malformed $setting"
    done
  done
  pass "await refuses a non-numeric, zero or negative bound before reading anything"
}

# --- live-read retry: transient versus definitive -----------------------------
#
# The wait multiplies the live read, so one transient forge failure must not red
# a PR whose attestation does publish. The retry is deliberately narrow: only a
# failure that could answer differently next time is retried, and a definitive
# answer propagates at once. `await_fail` scripts a failing read at a given
# attempt index with the stderr gh would produce.

# `status` defaults to gh's generic failure exit 1; pass 4 for "authentication
# required" or 127 for a gh that is not on PATH, the two definitive failures
# that carry no HTTP status in their message.
await_fail() {
  local which=$1 message=$2 status=${3:-1}
  printf '%s' "$message" > "$AWAIT_CASE/fail-$which.txt"
  printf '%s' "$status" > "$AWAIT_CASE/fail-$which.rc"
}

# Extend the scripted provider with per-read failures. An entry scripted for an
# exact read index wins over the default entry, so a case can script a sound
# first read followed by a failing rest (or the reverse).
await_case_failing() {
  await_case "$1"
  cat > "$AWAIT_BIN/gh" <<SH
#!/usr/bin/env bash
printf 'x' >> "$AWAIT_CASE/reads"
reads=\$(wc -c < "$AWAIT_CASE/reads" | tr -d ' ')
for slot in "\$reads" default; do
  failure="$AWAIT_CASE/fail-\$slot.txt"
  if [ -f "\$failure" ]; then
    cat "\$failure" >&2
    exit "\$(cat "$AWAIT_CASE/fail-\$slot.rc")"
  fi
  response="$AWAIT_CASE/read-\$slot.json"
  if [ -f "\$response" ]; then cat "\$response"; exit 0; fi
done
exit 1
SH
  chmod +x "$AWAIT_BIN/gh"
}

test_await_retries_a_transient_read_and_still_binds() {
  local out rc verifier_out
  await_case_failing transient
  await_fail 1 "gh: Internal Server Error (HTTP 502)"
  await_fail 2 "error connecting to api.github.com"
  await_read default 3006 "$NEW_SHA" "$(attested_body "$NEW_SHA")"
  rc=0
  out=$(run_await 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a transient forge failure reddened a PR whose attestation was published"
  [ "$(await_reads)" -eq 3 ] || fail "await made $(await_reads) live reads, expected two retries then a good read"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  expect_code 0 "$rc" "the verifier rejected the attestation await retried for"
  pass "a transient live-read failure is retried and the sound subject still binds"
}

test_await_does_not_retry_a_definitive_read_failure() {
  local err rc
  await_case_failing definitive
  await_fail default "gh: Not Found (HTTP 404)"
  rc=0
  err=$(run_await 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "await produced a subject after a definitive read refusal"
  assert_contains "$err" "404" "the refusal did not carry the forge's definitive answer"
  [ "$(await_reads)" -eq 1 ] || fail "await retried a definitive 404 $(await_reads) times"
  pass "a definitive live-read refusal propagates immediately without retrying"
}

# The regression behind this case: a transient blip that outlasts one read's
# retry budget used to be fatal even with almost the whole window still open, so
# a few seconds of forge trouble reddened a PR whose attestation does publish -
# the very defect the wait exists to remove. The budget bounds ONE read, not the
# wait: when it is spent transiently the loop polls and re-reads.
test_await_absorbs_a_transient_blip_that_outlasts_one_reads_budget() {
  local out rc verifier_out sleeps
  await_case_failing blip-outlasts-budget
  await_fail 1 "gh: Bad Gateway (HTTP 502)"
  await_fail 2 "gh: Bad Gateway (HTTP 502)"
  await_fail 3 "gh: Bad Gateway (HTTP 502)"
  await_read default 3006 "$NEW_SHA" "$(attested_body "$NEW_SHA")"
  rc=0
  out=$( export NMF_PUBLICATION_POLL_SECONDS=9; run_await 2>/dev/null ) || rc=$?
  expect_code 0 "$rc" "a transient blip past one read's budget reddened a PR whose attestation did publish"
  [ "$(await_reads)" -eq 4 ] \
    || fail "await made $(await_reads) live reads, expected the 3-attempt budget then a re-read on the next poll"
  # The budget still bounds a single read: the third failure is followed by the
  # poll interval, not by a fourth doubled backoff inside the same read.
  sleeps=$(tr '\n' ' ' < "$AWAIT_CASE/sleeps")
  [ "$sleeps" = "2 4 9 " ] \
    || fail "expected two bounded backoffs then one poll wait, recorded waits were: $sleeps"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  expect_code 0 "$rc" "the verifier rejected the attestation await polled through the blip for"
  pass "a transient blip past one read's budget is absorbed and the publication still binds"
}

# The window boundary, not the first blip, is where fail-closed lives. A window
# that closes with no sound read has no live body to hand over, so it must exit
# non-zero with no subject and name that diagnosis rather than implying the
# attestation was absent.
test_await_fails_closed_when_the_window_closes_with_no_sound_read() {
  local out err rc widest
  await_case_failing no-sound-read
  await_fail default "gh: Bad Gateway (HTTP 502)"
  rc=0
  out=$( export NMF_PUBLICATION_WINDOW_SECONDS=1 NMF_PUBLICATION_POLL_SECONDS=1
         run_await 2>"$AWAIT_CASE/err" ) || rc=$?
  err=$(cat "$AWAIT_CASE/err")
  [ "$rc" -ne 0 ] || fail "await produced a subject with no sound live read at all"
  case "$out" in
    *"body<<"*) fail "await emitted a body block with no sound live read" ;;
  esac
  assert_contains "$err" "no sound live read" \
    "the refusal did not name the no-sound-read-within-the-window condition"
  assert_contains "$err" "publication window closed" \
    "the refusal did not say the window is what closed"
  # Every read still spent a bounded budget: 2s then 4s of backoff and never a
  # further doubling, so no single read can spin the window away.
  widest=$(sort -n "$AWAIT_CASE/sleeps" | tail -1)
  [ "$widest" -le 4 ] \
    || fail "a single read backed off for ${widest}s, past the bounded 2s/4s budget"
  pass "a window that closes with no sound live read fails closed and says so"
}

# A wait that went blind for part of the window is NOT a stalled publication:
# the unread stretch observed nothing and the publication may have landed
# unseen there. The deadline must still hand the most recent sound read to the
# verifier - fail-closed is unchanged - but it must report what it actually saw:
# how many polls could not be read, and what the last sound read observed and
# when. Calling this a stalled publisher would send the operator and the CI-fix
# loop after the wrong cause.
test_await_reports_a_trailing_read_outage_instead_of_blaming_the_publisher() {
  local out err rc verifier_out outage
  await_case_failing sound-then-outage
  await_read 1 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  await_fail default "gh: Bad Gateway (HTTP 502)"
  rc=0
  out=$( export NMF_PUBLICATION_WINDOW_SECONDS=1 NMF_PUBLICATION_POLL_SECONDS=1
         run_await 2>"$AWAIT_CASE/err" ) || rc=$?
  err=$(cat "$AWAIT_CASE/err")
  expect_code 0 "$rc" "the deadline refused the subject instead of letting the verifier judge it"
  case "$err" in
    *"no sound live read"*) fail "a wait that did read soundly was reported as having read nothing" ;;
    *"still unpublished"*) fail "a trailing read outage was attributed to the publisher" ;;
  esac
  outage=$(printf '%s\n' "$err" | grep 'could not be read') \
    || fail "the deadline never reported that any poll could not be read"
  assert_contains "$outage" "502" "the outage report did not name the read failure that caused it"
  assert_contains "$outage" "$OLD_SHA" \
    "the outage report did not say what the last sound read observed"
  assert_contains "$outage" "into the window" \
    "the outage report did not say when the last sound read was taken"
  # Exact-head association: the handed-over subject is the sound read's own head.
  [ "$(extract_output_head "$out")" = "$NEW_SHA" ] \
    || fail "the deadline handed over a head other than the sound read's live head"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "a PR whose attestation never bound the live head was allowed to pass the gate"
  assert_contains "$verifier_out" "$OLD_SHA" \
    "the verifier's authoritative refusal did not name the head the body was attested to"
  pass "a trailing read outage is reported as one, and the sound read still reaches the verifier"
}

# The unreadable-poll count must be COUNTED, not inferred from how the last poll
# happened to end. These two cases drive an outage that RECOVERS, so the final
# poll reads soundly: the deadline must still say how many polls observed
# nothing. The second is the shape that previously lied outright - the outage
# covers the start of the window and only the later polls read - and it reported
# "every one of which read soundly". Each failing poll spends the whole 3-attempt
# budget, so the unreadable-poll count is fixed by the scripted read sequence
# however many sound polls follow before the deadline.
assert_outage_report() {
  local err=$1 unread=$2 outage
  case "$err" in
    *"every one of which read soundly"*)
      fail "a wait with $unread unreadable poll(s) claimed every poll read soundly" ;;
    *"still unpublished"*)
      fail "a wait with $unread unreadable poll(s) was attributed to the publisher" ;;
    *"no sound live read"*)
      fail "a wait that did read soundly was reported as having read nothing" ;;
  esac
  outage=$(printf '%s\n' "$err" | grep 'could not be read') \
    || fail "the deadline never reported that any poll could not be read"
  assert_contains "$outage" "$unread of which could not be read" \
    "the deadline did not report the real number of unreadable polls"
  assert_contains "$outage" "502" "the outage report did not name the read failure"
  assert_contains "$outage" "$OLD_SHA" \
    "the outage report did not say what the last sound read observed"
  assert_contains "$outage" "into the window" \
    "the outage report did not say when the last sound read was taken"
}

run_recovering_outage_case() {
  local name=$1 failing_reads=$2 read_index
  await_case_failing "$name"
  for read_index in $(seq 1 "$failing_reads"); do
    await_fail "$read_index" "gh: Bad Gateway (HTTP 502)"
  done
  await_read default 3006 "$NEW_SHA" "$(attested_body "$OLD_SHA")"
  ( export NMF_PUBLICATION_WINDOW_SECONDS=2 NMF_PUBLICATION_POLL_SECONDS=1
    run_await 2>"$AWAIT_CASE/err" >"$AWAIT_CASE/out" )
}

test_await_counts_the_unreadable_polls_when_the_read_recovers() {
  local rc=0
  run_recovering_outage_case recovering-outage 3 || rc=$?
  expect_code 0 "$rc" "the deadline refused the subject instead of letting the verifier judge it"
  assert_outage_report "$(cat "$AWAIT_CASE/err")" 1
  pass "an outage that recovers is still counted and reported at the deadline"
}

# The regression: an outage covering the start of the window used to be erased
# because the marker it was read from is cleared by every sound read.
test_await_still_reports_an_early_outage_when_the_last_polls_read_soundly() {
  local rc=0 out verifier_out
  run_recovering_outage_case early-outage 6 || rc=$?
  expect_code 0 "$rc" "the deadline refused the subject instead of letting the verifier judge it"
  assert_outage_report "$(cat "$AWAIT_CASE/err")" 2
  out=$(cat "$AWAIT_CASE/out")
  # Fail-closed and exact-head association are unchanged on this path.
  [ "$(extract_output_head "$out")" = "$NEW_SHA" ] \
    || fail "the deadline handed over a head other than the sound read's live head"
  rc=0
  verifier_out=$(run_verifier "$(extract_output_body "$out")" "$(extract_output_head "$out")") || rc=$?
  [ "$rc" -ne 0 ] || fail "a PR whose attestation never bound the live head passed the gate"
  assert_contains "$verifier_out" "$OLD_SHA" \
    "the verifier's refusal did not name the head the body was attested to"
  pass "an early outage is still reported when the trailing polls read soundly"
}

# A definitive failure that carries no HTTP status - an absent or invalid
# GH_TOKEN is the reachable one - must be told apart from a transport blip by
# gh's exit status, not by its message text, and must never spend the window.
test_await_does_not_retry_a_definitive_non_http_failure() {
  local err rc
  await_case_failing auth-failure
  await_fail default \
    "gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable." 4
  rc=0
  err=$(run_await 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "await produced a subject after an authentication failure"
  assert_contains "$err" "GH_TOKEN" "the refusal did not carry the authentication failure"
  [ "$(await_reads)" -eq 1 ] \
    || fail "await retried an authentication failure $(await_reads) times instead of failing at once"
  [ "$(await_sleeps)" -eq 0 ] \
    || fail "await spent $(await_sleeps) wait(s) of the publication window on a misconfiguration"
  pass "an authentication failure propagates immediately without spending the window"
}

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the live-subject read the gate performs"
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
test_resolve_unsigned_body_hands_off_instead_of_waiting
test_resolve_final_hands_off_an_unbound_body_and_the_verifier_refuses_it
test_current_mode_race_resolves_green_once_body_binds_live_head
test_historical_invalid_body_is_not_rescued_by_a_clean_live_body
test_await_binds_when_the_publication_lands_mid_wait
test_await_stops_at_the_deadline_and_fails_closed
test_await_does_not_wait_when_no_publication_is_in_flight
test_await_refuses_a_superseded_head_immediately
test_await_fails_closed_when_the_live_pr_cannot_be_read
test_await_refuses_a_malformed_bound
test_await_retries_a_transient_read_and_still_binds
test_await_does_not_retry_a_definitive_read_failure
test_await_absorbs_a_transient_blip_that_outlasts_one_reads_budget
test_await_fails_closed_when_the_window_closes_with_no_sound_read
test_await_reports_a_trailing_read_outage_instead_of_blaming_the_publisher
test_await_counts_the_unreadable_polls_when_the_read_recovers
test_await_still_reports_an_early_outage_when_the_last_polls_read_soundly
test_await_does_not_retry_a_definitive_non_http_failure
