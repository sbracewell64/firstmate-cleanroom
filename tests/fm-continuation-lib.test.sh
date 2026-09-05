#!/usr/bin/env bash
# tests/fm-continuation-lib.test.sh - unit tests for the single-owner programme
# continuation vocabulary and classification tables (bin/fm-continuation-lib.sh).
# Pure functions, no backend, no tasks-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-continuation-lib.sh"

# --- enums and the classification -> authority mapping -----------------------

for c in SELF_HANDLE BROWSER_SOL CAPTAIN EXTERNAL_DEPENDENCY; do
  fm_continuation_is_classification "$c" || fail "$c must be a classification"
done
fm_continuation_is_classification CAPTAIN_REQUIRED && fail "CAPTAIN_REQUIRED is not a classification"
for a in AUTHORIZED REQUIRES_RULING REQUIRES_CAPTAIN WAITING_EXTERNAL CNO; do
  fm_continuation_is_authority_state "$a" || fail "$a must be an authority state"
done
[ "$(fm_continuation_authority_for SELF_HANDLE)" = AUTHORIZED ] || fail "SELF_HANDLE -> AUTHORIZED"
[ "$(fm_continuation_authority_for BROWSER_SOL)" = REQUIRES_RULING ] || fail "BROWSER_SOL -> REQUIRES_RULING"
[ "$(fm_continuation_authority_for CAPTAIN)" = REQUIRES_CAPTAIN ] || fail "CAPTAIN -> REQUIRES_CAPTAIN"
[ "$(fm_continuation_authority_for EXTERNAL_DEPENDENCY)" = WAITING_EXTERNAL ] || fail "EXTERNAL_DEPENDENCY -> WAITING_EXTERNAL"
fm_continuation_authority_for bogus >/dev/null 2>&1 && fail "an unknown classification must have no authority state"
pass "the four classifications map one-to-one onto their authority states and nothing else maps"

# --- dominance ---------------------------------------------------------------

[ "$(fm_continuation_rank CAPTAIN)" -gt "$(fm_continuation_rank BROWSER_SOL)" ] || fail "CAPTAIN must outrank BROWSER_SOL"
[ "$(fm_continuation_rank BROWSER_SOL)" -gt "$(fm_continuation_rank EXTERNAL_DEPENDENCY)" ] || fail "BROWSER_SOL must outrank EXTERNAL_DEPENDENCY"
[ "$(fm_continuation_rank EXTERNAL_DEPENDENCY)" -gt "$(fm_continuation_rank SELF_HANDLE)" ] || fail "EXTERNAL_DEPENDENCY must outrank SELF_HANDLE"
pass "dominance is CAPTAIN > BROWSER_SOL > EXTERNAL_DEPENDENCY > SELF_HANDLE"

# --- reserved axes -----------------------------------------------------------

RESERVED=$'new_paid_spend\nsecurity_control_weakening\ncredential_or_identity_provisioning'
fm_continuation_axis_reserved new_paid_spend "$RESERVED" || fail "new_paid_spend is reserved"
fm_continuation_axis_reserved credential_or_identity_provisioning "$RESERVED" || fail "credential axis is reserved"
fm_continuation_axis_reserved engineering_ambiguity "$RESERVED" && fail "an unlisted axis is not reserved"
fm_continuation_axis_reserved "" "$RESERVED" && fail "an empty axis is not reserved"
fm_continuation_axis_reserved spend "$RESERVED" && fail "a substring of a reserved axis is not reserved"
pass "reserved-axis membership is exact-token, never substring or empty"

# --- the hold-effect law ------------------------------------------------------

[ "$(fm_continuation_hold_effect captain 1 '' 1)" = 'CAPTAIN HOLD_RESERVED_AXIS' ] || fail "captain hold + reserved axis -> CAPTAIN"
[ "$(fm_continuation_hold_effect captain 0 '' 1)" = 'BROWSER_SOL CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS' ] || fail "captain hold without reserved axis is refused to BROWSER_SOL"
[ "$(fm_continuation_hold_effect captain 1 '' 0)" = 'CAPTAIN HOLD_RESERVED_AXIS' ] || fail "an expired captain deferral is still the captain's hold"
[ "$(fm_continuation_hold_effect external 0 ruling 1)" = 'BROWSER_SOL HOLD_RULING_WAIT' ] || fail "external hold waiting on a ruling -> BROWSER_SOL"
[ "$(fm_continuation_hold_effect external 0 external 1)" = 'EXTERNAL_DEPENDENCY HOLD_EXTERNAL_WAIT' ] || fail "external hold -> EXTERNAL_DEPENDENCY"
[ "$(fm_continuation_hold_effect external 0 '' 1)" = 'EXTERNAL_DEPENDENCY HOLD_EXTERNAL_WAIT' ] || fail "external hold with no wait token -> EXTERNAL_DEPENDENCY"
[ "$(fm_continuation_hold_effect external 1 '' 1)" = 'EXTERNAL_DEPENDENCY HOLD_EXTERNAL_WAIT' ] || fail "an external hold never becomes CAPTAIN even with a reserved axis"
[ "$(fm_continuation_hold_effect external 0 ruling 0)" = 'IGNORE HOLD_DATE_EXPIRED' ] || fail "expired external wait is ignored"
[ "$(fm_continuation_hold_effect future 0 '' 1)" = 'EXTERNAL_DEPENDENCY HOLD_DATE_GATE' ] || fail "live date gate -> EXTERNAL_DEPENDENCY"
[ "$(fm_continuation_hold_effect future 0 '' 0)" = 'IGNORE HOLD_DATE_EXPIRED' ] || fail "expired date gate is ignored"
[ "$(fm_continuation_hold_effect load 1 '' 1)" = 'IGNORE HOLD_NOT_AUTHORITY' ] || fail "load hold is not authority"
[ "$(fm_continuation_hold_effect parked 1 '' 1)" = 'IGNORE HOLD_NOT_AUTHORITY' ] || fail "parked hold is not authority"
[ "$(fm_continuation_hold_effect mystery 1 '' 1)" = 'IGNORE HOLD_KIND_UNKNOWN' ] || fail "an unknown kind is ignored, never a gate"
pass "the hold-effect table yields CAPTAIN only for a captain hold on a reserved axis and refuses every other captain claim"

# --- the step-default law -----------------------------------------------------

[ "$(fm_continuation_step_default SELF_HANDLE)" = 'SELF_HANDLE STANDING_GRANT' ] || fail "SELF_HANDLE default"
[ "$(fm_continuation_step_default '')" = 'SELF_HANDLE STANDING_GRANT' ] || fail "absent claim defaults to SELF_HANDLE"
[ "$(fm_continuation_step_default BROWSER_SOL)" = 'BROWSER_SOL STEP_REQUIRES_RULING' ] || fail "BROWSER_SOL default"
[ "$(fm_continuation_step_default CAPTAIN)" = 'BROWSER_SOL STEP_CLASSIFICATION_REFUSED' ] || fail "a bare CAPTAIN claim on a step is refused"
[ "$(fm_continuation_step_default EXTERNAL_DEPENDENCY)" = 'BROWSER_SOL STEP_CLASSIFICATION_REFUSED' ] || fail "a static EXTERNAL_DEPENDENCY claim is refused"
pass "a step may claim SELF_HANDLE or BROWSER_SOL; any other claim is refused to BROWSER_SOL"

# --- the binding line ----------------------------------------------------------

LINE=$(fm_continuation_binding_line proof-b cleanroom-requalification new_paid_spend '')
[ "$LINE" = 'Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend' ] || fail "binding line shape: $LINE"
[ "$(fm_continuation_binding_field "$LINE" action)" = proof-b ] || fail "action field"
[ "$(fm_continuation_binding_field "$LINE" axis)" = new_paid_spend ] || fail "axis field"
[ "$(fm_continuation_binding_field "$LINE" wait)" = '' ] || fail "absent wait field is empty"
LINE2=$(fm_continuation_binding_line proof-b '' '' ruling)
[ "$LINE2" = 'Continuation-binding: action=proof-b wait=ruling' ] || fail "minimal binding line: $LINE2"
BODY=$'Observed something.\nContinuation-binding: action=proof-b wait=ruling\nMore notes about action=proof-a.'
[ "$(fm_continuation_binding_from_body "$BODY")" = "$LINE2" ] || fail "binding extracted from a body"
[ -z "$(fm_continuation_binding_from_body $'prose mentioning Continuation-binding: in passing\nno line starts with it')" ] || fail "a mention inside prose is not a binding"
fm_continuation_is_slug proof-b || fail "proof-b is a slug"
fm_continuation_is_slug 'proof b' && fail "a value with a space is not a slug"
fm_continuation_is_wait ruling || fail "ruling is a wait token"
fm_continuation_is_wait external || fail "external is a wait token"
fm_continuation_is_wait captain && fail "captain is not a wait token"
pass "the binding line round-trips through build, body extraction, and field access with slug-only values"

# --- presentation never asserts a captain gate for a non-captain reason -------

for code in STANDING_GRANT FIRST_STEP_STANDING_GRANT PROGRAMME_COMPLETE CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS \
            STEP_CLASSIFICATION_REFUSED STEP_REQUIRES_RULING HOLD_RULING_WAIT HOLD_EXTERNAL_WAIT HOLD_DATE_GATE \
            GRANT_SUPERSEDED GRANT_GENERATION_MISMATCH GRANT_KIND_UNKNOWN HOLD_STORE_UNREADABLE PREDECESSOR_DISPOSITION_UNREADABLE \
            NEWER_ATTEMPT_WITHOUT_DISPOSITION; do
  text=$(fm_continuation_render_reason "$code" proof-b 'proof-a attempt 3 PROVED' 'detail')
  [ -n "$text" ] || fail "$code renders a sentence"
  printf '%s' "$text" | grep -qiE "$FM_CONTINUATION_GATE_PHRASE_RE" && fail "$code rendered a captain-gate phrase: $text"
done
pass "no non-captain reason code renders captain-gate phrasing"

for code in HOLD_RESERVED_AXIS STEP_RESERVED_AXIS; do
  text=$(fm_continuation_render_reason "$code" proof-b '' new_paid_spend)
  printf '%s' "$text" | grep -q "captain's own answer" || fail "$code must name the captain's answer: $text"
done
pass "captain reason codes render the captain's answer as the wait"

# The gate pattern catches the observed defect sentence and its common variants
# while leaving ordinary progress prose alone.
for bad in 'nothing further runs without your word' 'Proof B needs your word' 'CAPTAIN_REQUIRED' 'captain required before proof-b' \
           'waiting for the captain to approve' 'awaiting captain authorization' 'pending your approval' 'requires your go-ahead'; do
  printf '%s' "$bad" | grep -qiE "$FM_CONTINUATION_GATE_PHRASE_RE" || fail "gate pattern must match: $bad"
done
for ok in 'proof-b proceeds under the standing grant' 'the captain merged the PR yesterday' 'Captain, shipshape.' \
          'waiting on CI' 'Browser Sol ruling pending'; do
  printf '%s' "$ok" | grep -qiE "$FM_CONTINUATION_GATE_PHRASE_RE" && fail "gate pattern must not match: $ok"
done
pass "the captain-gate phrase pattern matches gate assertions and not ordinary captain mentions"

echo "# fm-continuation-lib.test.sh: all assertions passed"
