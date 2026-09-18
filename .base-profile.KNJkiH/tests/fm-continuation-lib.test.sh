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

# --- the closed completion-evidence and owner vocabularies -------------------

for k in latest_attempt_disposition_outcome_in accepted_owner_evidence; do
  fm_continuation_is_evidence_kind "$k" || fail "$k must be a completion-evidence kind"
done
for k in shell_predicate arbitrary_command '' accepted_owner; do
  fm_continuation_is_evidence_kind "$k" && fail "'$k' must not be a completion-evidence kind"
done
[ "$(printf '%s' "$FM_CONTINUATION_EVIDENCE_KINDS" | wc -w | tr -d ' ')" = 2 ] || fail "the completion-evidence vocabulary is exactly two kinds"
pass "the completion-evidence vocabulary is closed to the two kinds the resolver represents"

for k in control_ruling control_report pull_request_merge; do
  fm_continuation_is_owner_kind "$k" || fail "$k must be an owner kind"
  [ -n "$(fm_continuation_owner_outcomes "$k")" ] || fail "$k must carry an outcome vocabulary"
done
for k in shell_command captain_word '' control; do
  fm_continuation_is_owner_kind "$k" && fail "'$k' must not be an owner kind"
  fm_continuation_owner_outcomes "$k" >/dev/null 2>&1 && fail "'$k' must have no outcome vocabulary"
  fm_continuation_owner_outcome_supported "$k" MERGED_QUALIFIED && fail "an unknown owner kind supports no outcome"
done
[ "$(printf '%s' "$FM_CONTINUATION_OWNER_KINDS" | wc -w | tr -d ' ')" = 3 ] || fail "the owner vocabulary is exactly three kinds"
pass "the owner vocabulary is closed to the three governed owner kinds"

for o in PROCEED_WITH_CONDITIONS ADOPT_OPTION REFUSED OUT_OF_SCOPE_CAPTAIN_RESERVED NO_ANSWER; do
  fm_continuation_owner_outcome_supported control_ruling "$o" || fail "control_ruling supports $o"
done
for o in REPORTED REPORTED_SELF_TESTED; do
  fm_continuation_owner_outcome_supported control_report "$o" || fail "control_report supports $o"
done
for o in OPEN CLOSED_UNMERGED MERGED MERGED_QUALIFIED; do
  fm_continuation_owner_outcome_supported pull_request_merge "$o" || fail "pull_request_merge supports $o"
done
fm_continuation_owner_outcome_supported control_report MERGED_QUALIFIED && fail "a self-report can never claim MERGED_QUALIFIED"
fm_continuation_owner_outcome_supported control_report PROCEED_WITH_CONDITIONS && fail "a self-report can never rule"
fm_continuation_owner_outcome_supported pull_request_merge PROCEED_WITH_CONDITIONS && fail "a merge record can never rule"
fm_continuation_owner_outcome_supported control_ruling MERGED_QUALIFIED && fail "a ruling can never qualify a landing"
fm_continuation_owner_outcome_supported pull_request_merge MERGED_QUALIFIE && fail "an outcome prefix is not an outcome"
fm_continuation_owner_outcome_supported pull_request_merge '' && fail "an empty outcome is never supported"
pass "each owner kind's outcome vocabulary is closed, exact-token, and disjoint from the others' authority tokens"

# --- the accountable-owner projection ------------------------------------------

owner_of() { fm_continuation_accountable_owner "$@"; }
for code in REQUIRED_BINDING_MISSING OWNER_EVIDENCE_MALFORMED OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH OWNER_EVIDENCE_CONTRADICTORY; do
  text=$(owner_of BROWSER_SOL CNO "$code")
  printf '%s' "$text" | grep -q '^engineering: the qualification or landing owner' || fail "$code names the evidence owner: $text"
done
printf '%s' "$(owner_of BROWSER_SOL CNO GRANT_SUPERSEDED)" | grep -q '^engineering: the programme owner' || fail "GRANT_* names the programme owner"
printf '%s' "$(owner_of BROWSER_SOL CNO HOLD_STORE_UNREADABLE)" | grep -q '^engineering: the backlog store owner' || fail "HOLD_STORE_UNREADABLE names the backlog owner"
printf '%s' "$(owner_of BROWSER_SOL CNO PREDECESSOR_DISPOSITION_UNREADABLE)" | grep -q '^engineering: the proof-attempt owner' || fail "an unreadable disposition names the proof-attempt owner"
for code in REQUIRED_BINDING_MISSING OWNER_EVIDENCE_MALFORMED GRANT_SUPERSEDED HOLD_STORE_UNREADABLE NEWER_ATTEMPT_WITHOUT_DISPOSITION; do
  text=$(owner_of BROWSER_SOL CNO "$code")
  printf '%s' "$text" | grep -q 'never the captain' || fail "CNO owner $code must say never the captain: $text"
  printf '%s' "$text" | grep -qi '^captain' && fail "CNO must never name the captain as owner: $text"
done
pass "every CNO names an engineering owner and never the captain"
for code in HOLD_RESERVED_AXIS STEP_RESERVED_AXIS; do
  printf '%s' "$(owner_of CAPTAIN REQUIRES_CAPTAIN "$code")" | grep -qi 'captain' || fail "$code is the captain's own"
done
printf '%s' "$(owner_of BROWSER_SOL REQUIRES_RULING STEP_REQUIRES_RULING)" | grep -qi 'browser sol' || fail "a ruling wait names Browser Sol"
printf '%s' "$(owner_of BROWSER_SOL REQUIRES_RULING STEP_REQUIRES_RULING)" | grep -qi 'captain' && fail "a ruling wait never names the captain"
printf '%s' "$(owner_of EXTERNAL_DEPENDENCY WAITING_EXTERNAL HOLD_EXTERNAL_WAIT)" | grep -qi 'captain' && fail "an external wait never names the captain"
[ -n "$(owner_of SELF_HANDLE AUTHORIZED STANDING_GRANT)" ] || fail "an authorized step still names its owner"
printf '%s' "$(owner_of SELF_HANDLE AUTHORIZED STANDING_GRANT)" | grep -qi 'captain' && fail "an authorized step never names the captain"
pass "the accountable owner follows classification and authority: the captain only for a CAPTAIN result"

# --- presentation never asserts a captain gate for a non-captain reason -------

for code in STANDING_GRANT FIRST_STEP_STANDING_GRANT PROGRAMME_COMPLETE CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS \
            STEP_CLASSIFICATION_REFUSED STEP_REQUIRES_RULING HOLD_RULING_WAIT HOLD_EXTERNAL_WAIT HOLD_DATE_GATE \
            GRANT_SUPERSEDED GRANT_GENERATION_MISMATCH GRANT_KIND_UNKNOWN HOLD_STORE_UNREADABLE PREDECESSOR_DISPOSITION_UNREADABLE \
            NEWER_ATTEMPT_WITHOUT_DISPOSITION REQUIRED_BINDING_MISSING OWNER_EVIDENCE_UNREADABLE OWNER_EVIDENCE_SOURCE_UNREADABLE \
            OWNER_EVIDENCE_CONTRADICTORY OWNER_EVIDENCE_MALFORMED OWNER_EVIDENCE_STEP_MISMATCH OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH; do
  text=$(fm_continuation_render_reason "$code" proof-b 'proof-a attempt 3 PROVED' 'detail')
  [ -n "$text" ] || fail "$code renders a sentence"
  printf '%s' "$text" | grep -qiE "$FM_CONTINUATION_GATE_PHRASE_RE" && fail "$code rendered a captain-gate phrase: $text"
done
pass "no non-captain reason code renders captain-gate phrasing"

text=$(fm_continuation_render_reason REQUIRED_BINDING_MISSING slice-a '' 'no record at evidence/slice-a.json')
printf '%s' "$text" | grep -q 'never treated as complete' || fail "REQUIRED_BINDING_MISSING says a landing is never complete: $text"
printf '%s' "$text" | grep -q 'no record at evidence/slice-a.json' || fail "REQUIRED_BINDING_MISSING carries the detail"
for code in OWNER_EVIDENCE_UNREADABLE OWNER_EVIDENCE_SOURCE_UNREADABLE; do
  text=$(fm_continuation_render_reason "$code" slice-c '' 'bytes')
  printf '%s' "$text" | grep -q 'could not be read (bytes)' || fail "$code renders as unreadable: $text"
done
text=$(fm_continuation_render_reason OWNER_EVIDENCE_CONTRADICTORY slice-c '' 'observed-bad')
printf '%s' "$text" | grep -q 'adverse record is preserved' || fail "OWNER_EVIDENCE_CONTRADICTORY preserves the adverse record: $text"
text=$(fm_continuation_render_reason OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH ruling '' 'moved bytes')
printf '%s' "$text" | grep -q 'refused (OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH: moved bytes)' || fail "an OWNER_EVIDENCE_* refusal names its code and detail: $text"
for code in REQUIRED_BINDING_MISSING OWNER_EVIDENCE_UNREADABLE OWNER_EVIDENCE_CONTRADICTORY OWNER_EVIDENCE_POLICY_MISMATCH; do
  printf '%s' "$(fm_continuation_render_reason "$code" x '' d)" | grep -q 'Browser Sol' || fail "$code routes to Browser Sol"
done
pass "the owner-evidence reason codes render the refusal, its detail, and the Browser Sol route, never a captain gate"

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
