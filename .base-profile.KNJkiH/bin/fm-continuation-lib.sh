# shellcheck shell=bash
# fm-continuation-lib.sh - the typed vocabulary and classification law behind
# programme continuation authority. Pure functions, no I/O, sourced by
# bin/fm-continuation-resolve.sh (the resolver that reads canonical state) and
# by bin/fm-captain-hold.sh (which records typed hold bindings).
#
# WHY THIS EXISTS. A recurring defect class: captain-facing synthesis said a
# programme step "needs your word" for a continuation the standing programme
# grant had already authorized, deriving that stop from prose and generic
# caution rather than from typed state. The invariant this library enforces:
#
#   A continuation or stop decision that depends on authority MUST be derived
#   from current typed authority/hold state for the exact next action and
#   generation. Historical prose, generic caution, or model inference may NOT
#   manufacture a captain gate.
#
# This file is the SINGLE OWNER of:
#
#   1. The classification enum   SELF_HANDLE | BROWSER_SOL | CAPTAIN | EXTERNAL_DEPENDENCY
#   2. The authority-state enum  AUTHORIZED | REQUIRES_RULING | REQUIRES_CAPTAIN | WAITING_EXTERNAL | CNO
#   3. The classification -> authority-state mapping (fm_continuation_authority_for).
#   4. The dominance order when several typed facts gate one action
#      (fm_continuation_rank): CAPTAIN > BROWSER_SOL > EXTERNAL_DEPENDENCY > SELF_HANDLE.
#   5. The HOLD-EFFECT LAW (fm_continuation_hold_effect): how one durable
#      backlog hold, bound to the exact next action, affects that action:
#        captain hold + reserved axis          -> CAPTAIN               (reason HOLD_RESERVED_AXIS)
#        captain hold + no reserved axis       -> BROWSER_SOL           (reason CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS)
#                                                 a captain claim cannot manufacture a captain gate
#        external hold, wait=ruling            -> BROWSER_SOL           (reason HOLD_RULING_WAIT)
#        external hold, other wait, active     -> EXTERNAL_DEPENDENCY   (reason HOLD_EXTERNAL_WAIT)
#        future hold with a live date gate     -> EXTERNAL_DEPENDENCY   (reason HOLD_DATE_GATE)
#        future/external hold, date expired    -> IGNORE                (reason HOLD_DATE_EXPIRED)
#        load or parked hold                   -> IGNORE                (reason HOLD_NOT_AUTHORITY)
#      A hold not bound to the exact next action never reaches this table: the
#      resolver drops it first (reason HOLD_OTHER_ACTION / HOLD_UNBOUND), so
#      authority for action A cannot leak to action B. A lifted hold (task
#      unheld or closed) is not a hold at all and never reaches it either.
#   6. The STEP-DEFAULT LAW (fm_continuation_step_default): what a programme
#      step's own `classification_when_next` may claim when nothing gates it:
#      SELF_HANDLE or BROWSER_SOL verbatim; anything else (including a bare
#      CAPTAIN claim) is refused to BROWSER_SOL with reason STEP_CLASSIFICATION_REFUSED,
#      because only a typed reserved axis may yield CAPTAIN.
#   7. The typed hold BINDING LINE the captain-hold owner writes into a task
#      body and the resolver reads back:
#        Continuation-binding: action=<step-id> [programme=<programme-id>] [axis=<axis>] [wait=ruling|external]
#      One line, space-separated key=value tokens, slug values only. It is the
#      ONLY way a backlog hold binds to a programme action; a hold without it is
#      unbound and gates nothing.
#   8. Reason codes and their presentation templates (fm_continuation_render_reason).
#      The rendered sentence is PRESENTATION ONLY: it is derived from the typed
#      result and can never change it.
#   9. The captain-gate phrase pattern (FM_CONTINUATION_GATE_PHRASE_RE) that
#      `fm-continuation-resolve.sh check-prose` refuses in captain-facing text
#      when the typed result is not CAPTAIN.
#  10. The recorded-answer contract readers (fm_continuation_answer_recorded,
#      fm_continuation_answer_digest, fm_continuation_answer_mode): the one
#      reading of the resolution record bin/fm-captain-hold.sh `answer` writes,
#      shared by that writer and by the resolver's fact retirement so the two
#      cannot drift.
#  11. The CLOSED completion-evidence vocabulary (FM_CONTINUATION_EVIDENCE_KINDS):
#      the terminal_predicate kinds the resolver can represent, and for the
#      accepted_owner_evidence kind the closed owner kinds
#      (FM_CONTINUATION_OWNER_KINDS) with each owner kind's closed observed-
#      outcome vocabulary (fm_continuation_owner_outcomes). An evidence record
#      is owner-produced machine-readable data the resolver reads and binds;
#      it never names a command, predicate, plugin, or workflow, and an owner
#      kind or outcome outside these tables is refused, never interpreted.
#  12. The accountable-owner projection (fm_continuation_accountable_owner):
#      the one owner a typed result names as accountable for the next action,
#      derived from classification, authority state, and reason code only. It
#      is PRESENTATION and identity material, never authority: CNO names the
#      engineering owner of the unobservable input, never the captain.
#
# Every consumer reads these tables; none re-encodes them. Adding or changing a
# rule is a one-line edit here and changes every consumer at once.

FM_CONTINUATION_CLASSIFICATIONS='SELF_HANDLE BROWSER_SOL CAPTAIN EXTERNAL_DEPENDENCY'
FM_CONTINUATION_AUTHORITY_STATES='AUTHORIZED REQUIRES_RULING REQUIRES_CAPTAIN WAITING_EXTERNAL CNO'
FM_CONTINUATION_HOLD_WAITS='ruling external'
FM_CONTINUATION_BINDING_KEY='Continuation-binding:'
FM_CONTINUATION_EVIDENCE_KINDS='latest_attempt_disposition_outcome_in accepted_owner_evidence'
# shellcheck disable=SC2034  # consumed by fm-continuation-resolve.sh's evidence adapter
FM_CONTINUATION_EVIDENCE_SCHEMA='fm-accepted-owner-evidence/v1'
FM_CONTINUATION_OWNER_KINDS='control_ruling control_report pull_request_merge'

# Phrases that assert a captain gate. Matched case-insensitively against
# captain-facing prose by check-prose; a match is refused unless the typed
# resolution for that programme is CAPTAIN.
# shellcheck disable=SC2034  # consumed by fm-continuation-resolve.sh check-prose
FM_CONTINUATION_GATE_PHRASE_RE='needs? your word|without your word|captain[ -]required|captain_required|awaiting (the )?captain|wait(ing)? (for|on) (the )?captain|(needs?|requires?|awaits?|waiting for|pending) (your|captain(.s)?) (authori[sz]ation|approval|permission|decision|say-so|go-ahead)'

fm_continuation_is_classification() {  # <token>
  case " $FM_CONTINUATION_CLASSIFICATIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_continuation_is_authority_state() {  # <token>
  case " $FM_CONTINUATION_AUTHORITY_STATES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_continuation_is_wait() {  # <token>
  case " $FM_CONTINUATION_HOLD_WAITS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_continuation_is_evidence_kind() {  # <terminal_predicate.kind>
  case " $FM_CONTINUATION_EVIDENCE_KINDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_continuation_is_owner_kind() {  # <owner.kind>
  case " $FM_CONTINUATION_OWNER_KINDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# THE closed observed-outcome vocabulary per owner kind, space-separated. An
# evidence record whose outcome is not in its owner kind's vocabulary is a
# forged or unsupported receipt and is refused; a programme step's accept[]
# then names which of these count as terminal-good for that step.
#   control_ruling      the decision token a Browser Sol ruling comment records
#   control_report      a self-report posted on the control venue; it can never
#                       say it is qualified, so a step that accepts only a
#                       qualification outcome cannot be completed by one
#   pull_request_merge  a forge pull-request record; MERGED_QUALIFIED requires
#                       the record to bind its qualification evidence, else the
#                       resolver refuses it as malformed
fm_continuation_owner_outcomes() {  # <owner.kind>
  case "$1" in
    control_ruling) printf 'PROCEED_WITH_CONDITIONS ADOPT_OPTION REFUSED OUT_OF_SCOPE_CAPTAIN_RESERVED NO_ANSWER' ;;
    control_report) printf 'REPORTED REPORTED_SELF_TESTED' ;;
    pull_request_merge) printf 'OPEN CLOSED_UNMERGED MERGED MERGED_QUALIFIED' ;;
    *) return 1 ;;
  esac
}

fm_continuation_owner_outcome_supported() {  # <owner.kind> <outcome>
  local vocab
  vocab=$(fm_continuation_owner_outcomes "$1") || return 1
  case " $vocab " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# The accountable owner for a typed result, by fixed precedence. Presentation
# and identity material only.
fm_continuation_accountable_owner() {  # <classification> <authority-state> <reason-code>
  local cls=$1 authority=$2 reason=$3
  if [ "$authority" = CNO ]; then
    case "$reason" in
      REQUIRED_BINDING_MISSING|OWNER_EVIDENCE_*) printf 'engineering: the qualification or landing owner that produces the bound completion evidence (no-mistakes, the exact-head merge owner, or the control ruling owner); never the captain' ;;
      GRANT_*) printf 'engineering: the programme owner that records the grant and its generation; never the captain' ;;
      HOLD_STORE_UNREADABLE) printf 'engineering: the backlog store owner (tasks-axi in this home); never the captain' ;;
      *) printf 'engineering: the proof-attempt owner whose newest disposition is unreadable; never the captain' ;;
    esac
    return 0
  fi
  case "$cls" in
    SELF_HANDLE) printf 'firstmate under the standing programme grant (delegated engineering)' ;;
    BROWSER_SOL) printf 'Browser Sol (engineering ruling through the control plane)' ;;
    CAPTAIN) printf 'the captain (reserved axis)' ;;
    EXTERNAL_DEPENDENCY) printf 'the external dependency named by the bound hold' ;;
    *) return 1 ;;
  esac
}

# The one classification -> authority-state mapping. CNO is never produced
# here: the resolver assigns CNO directly when a canonical input could not be
# observed, and pairs it with BROWSER_SOL (uncertainty is never CAPTAIN).
fm_continuation_authority_for() {  # <classification>
  case "$1" in
    SELF_HANDLE) printf 'AUTHORIZED' ;;
    BROWSER_SOL) printf 'REQUIRES_RULING' ;;
    CAPTAIN) printf 'REQUIRES_CAPTAIN' ;;
    EXTERNAL_DEPENDENCY) printf 'WAITING_EXTERNAL' ;;
    *) return 1 ;;
  esac
}

# Dominance when several typed facts gate one action: the highest rank wins.
fm_continuation_rank() {  # <classification>
  case "$1" in
    CAPTAIN) printf '3' ;;
    BROWSER_SOL) printf '2' ;;
    EXTERNAL_DEPENDENCY) printf '1' ;;
    SELF_HANDLE) printf '0' ;;
    *) return 1 ;;
  esac
}

# Is <axis> one of the programme's reserved axes (newline- or space-separated list)?
fm_continuation_axis_reserved() {  # <axis> <reserved-axes>
  local axis=$1 reserved=$2
  [ -n "$axis" ] || return 1
  case " $(printf '%s' "$reserved" | tr '\n' ' ') " in
    *" $axis "*) return 0 ;;
    *) return 1 ;;
  esac
}

# THE hold-effect law. Prints "<classification-or-IGNORE> <reason-code>".
#   <hold-kind>     tasks-axi hold kind: captain|external|load|parked|future
#   <axis-reserved> 1 when the binding's axis is a programme reserved axis, else 0
#   <wait>          the binding's wait token (ruling|external|empty)
#   <date-active>   1 when the hold has no date gate or its date is still ahead,
#                   0 when its --until date has passed
fm_continuation_hold_effect() {  # <hold-kind> <axis-reserved> <wait> <date-active>
  local kind=$1 reserved=$2 wait=$3 active=$4
  case "$kind" in
    captain)
      # A captain hold is the captain's own record; its date gate defers the
      # answer, it never lifts the hold (the captain-hold owner treats an
      # expired deferral as still answerable). Only a reserved axis makes it
      # a captain gate.
      if [ "$reserved" = 1 ]; then printf 'CAPTAIN HOLD_RESERVED_AXIS'
      else printf 'BROWSER_SOL CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS'; fi
      ;;
    external)
      if [ "$active" != 1 ]; then printf 'IGNORE HOLD_DATE_EXPIRED'
      elif [ "$wait" = ruling ]; then printf 'BROWSER_SOL HOLD_RULING_WAIT'
      else printf 'EXTERNAL_DEPENDENCY HOLD_EXTERNAL_WAIT'; fi
      ;;
    future)
      if [ "$active" != 1 ]; then printf 'IGNORE HOLD_DATE_EXPIRED'
      else printf 'EXTERNAL_DEPENDENCY HOLD_DATE_GATE'; fi
      ;;
    load|parked) printf 'IGNORE HOLD_NOT_AUTHORITY' ;;
    *) printf 'IGNORE HOLD_KIND_UNKNOWN' ;;
  esac
}

# Whether a hold kind can gate an action at all, derived from the hold-effect
# law with every gating condition satisfied so the two cannot drift; a kind
# that cannot gate needs no binding read.
fm_continuation_hold_kind_gates() {  # <hold-kind>
  case "$(fm_continuation_hold_effect "$1" 1 ruling 1)" in
    IGNORE*) return 1 ;;
    *) return 0 ;;
  esac
}

# THE recorded-answer contract, read by its writer (bin/fm-captain-hold.sh)
# and by the resolver alike: a task body carrying the resolution record the
# captain-hold owner (or the retired fm-decision-hold.sh) writes when the
# captain answers. The body may be decoded (real newlines) or still
# show-escaped (one quoted line with \n escapes). Records are prepended, so
# the first field match is the newest record.
fm_continuation_answer_recorded() {  # <body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
  esac
  return 1
}

# The newest record's one-line field value, or return 1 when absent.
fm_continuation_answer_field() {  # <body> <field-label>
  local rest=$1
  case "$rest" in
    *"$2: "*) rest=${rest#*"$2: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# The newest record's decision digest.
fm_continuation_answer_digest() {  # <body>
  fm_continuation_answer_field "$1" "Decision digest"
}

# The newest record's resolution mode (answered, released, or repaired);
# return 1 for a record predating the field.
fm_continuation_answer_mode() {  # <body>
  fm_continuation_answer_field "$1" "Resolution mode"
}

# THE step-default law. Prints "<classification> <reason-code>" for a step's
# own claimed classification when no typed fact gates it.
fm_continuation_step_default() {  # <classification_when_next-or-empty>
  case "${1:-SELF_HANDLE}" in
    SELF_HANDLE) printf 'SELF_HANDLE STANDING_GRANT' ;;
    BROWSER_SOL) printf 'BROWSER_SOL STEP_REQUIRES_RULING' ;;
    *) printf 'BROWSER_SOL STEP_CLASSIFICATION_REFUSED' ;;
  esac
}

# Build the typed binding line. Values must be slugs; the writer validates.
fm_continuation_binding_line() {  # <action> <programme> <axis> <wait>
  local action=$1 programme=$2 axis=$3 wait=$4 line
  line="$FM_CONTINUATION_BINDING_KEY action=$action"
  [ -z "$programme" ] || line="$line programme=$programme"
  [ -z "$axis" ] || line="$line axis=$axis"
  [ -z "$wait" ] || line="$line wait=$wait"
  printf '%s' "$line"
}

# The first binding line in a body (newline-separated text), or nothing.
fm_continuation_binding_from_body() {  # <body>
  printf '%s\n' "$1" | grep -m1 "^$FM_CONTINUATION_BINDING_KEY " || true
}

# One key's value from a binding line, or nothing.
fm_continuation_binding_field() {  # <binding-line> <key>
  local line=$1 key=$2 tok
  for tok in $line; do
    case "$tok" in
      "$key="*) printf '%s' "${tok#"$key="}"; return 0 ;;
    esac
  done
  return 0
}

# Slug check shared by the writer and the reader: a binding value that is not
# a slug is treated as absent, never as a wildcard.
fm_continuation_is_slug() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Presentation templates, keyed by reason code. Arguments are the typed
# fields already decided; the sentence can add nothing the fields do not say.
fm_continuation_render_reason() {  # <reason-code> <next-action> <predecessor-summary> <detail>
  local code=$1 action=$2 pred=$3 detail=$4
  case "$code" in
    STANDING_GRANT)
      printf 'The standing programme grant pre-authorizes %s on the terminal-good predecessor (%s); no typed fact gates it, so it proceeds without a fresh captain word.' "$action" "${pred:-no predecessor}" ;;
    FIRST_STEP_STANDING_GRANT)
      printf 'The standing programme grant pre-authorizes %s as the first step; no typed fact gates it, so it proceeds without a fresh captain word.' "$action" ;;
    PROGRAMME_COMPLETE)
      printf 'Every programme step is terminal-good; there is no next action.' ;;
    HOLD_RESERVED_AXIS)
      printf '%s is held for the captain on a reserved axis (%s); it waits for the captain'"'"'s own answer.' "$action" "$detail" ;;
    STEP_RESERVED_AXIS)
      printf '%s declares a reserved axis (%s) that only the captain may decide; it waits for the captain'"'"'s own answer.' "$action" "$detail" ;;
    CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS)
      printf 'A hold on %s claims the captain but names no reserved axis (%s); the claim is refused and the question goes to Browser Sol as an engineering ruling instead.' "$action" "$detail" ;;
    STEP_CLASSIFICATION_REFUSED)
      printf 'The programme step %s claims a classification that only a typed reserved axis could grant (%s); the claim is refused and the step waits on a Browser Sol ruling.' "$action" "$detail" ;;
    STEP_REQUIRES_RULING)
      printf 'The programme step %s is defined to wait on a Browser Sol ruling before it runs.' "$action" ;;
    HOLD_RULING_WAIT)
      printf '%s waits on a Browser Sol ruling (%s); no captain word is involved.' "$action" "$detail" ;;
    HOLD_EXTERNAL_WAIT)
      printf '%s waits on an external dependency (%s); no captain word is involved.' "$action" "$detail" ;;
    HOLD_DATE_GATE)
      printf '%s waits on a date gate (%s); no captain word is involved.' "$action" "$detail" ;;
    GRANT_SUPERSEDED)
      printf 'The programme grant is recorded as superseded (%s), so it cannot authorize %s; the continuation is unproven and goes to Browser Sol.' "$detail" "$action" ;;
    GRANT_GENERATION_MISMATCH)
      printf 'The programme grant names a different programme generation (%s), so it cannot authorize %s; the continuation is unproven and goes to Browser Sol.' "$detail" "$action" ;;
    GRANT_KIND_UNKNOWN)
      printf 'The programme grant kind is not one this resolver recognizes (%s), so it cannot authorize %s; the continuation is unproven and goes to Browser Sol.' "$detail" "$action" ;;
    HOLD_STORE_UNREADABLE)
      printf 'The durable hold store could not be read (%s), so the absence of a captain hold on %s cannot be proven; the continuation is unproven and goes to Browser Sol.' "$detail" "$action" ;;
    PREDECESSOR_DISPOSITION_UNREADABLE)
      printf 'The predecessor disposition for %s could not be read (%s); the continuation is unproven and goes to Browser Sol.' "$action" "$detail" ;;
    NEWER_ATTEMPT_WITHOUT_DISPOSITION)
      printf 'The newest attempt of %s has no terminal disposition yet (%s), so no older attempt can stand for it; the continuation is unproven and goes to Browser Sol.' "$action" "$detail" ;;
    REQUIRED_BINDING_MISSING)
      printf 'The completion evidence %s requires is not bound (%s); a landing or report without its bound qualification record is never treated as complete, the continuation is unproven and goes to Browser Sol, and no captain word is involved.' "$action" "$detail" ;;
    OWNER_EVIDENCE_UNREADABLE|OWNER_EVIDENCE_SOURCE_UNREADABLE)
      printf 'The completion evidence bound to %s could not be read (%s); the continuation is unproven and goes to Browser Sol, never the captain.' "$action" "$detail" ;;
    OWNER_EVIDENCE_CONTRADICTORY)
      printf 'The completion evidence bound to %s records an observed-bad contradiction (%s); the adverse record is preserved as it stands, the step is not complete, and the continuation goes to Browser Sol, never the captain.' "$action" "$detail" ;;
    OWNER_EVIDENCE_*)
      printf 'The completion evidence bound to %s was refused (%s: %s); nothing is accepted from a record that does not bind this exact work, and the continuation goes to Browser Sol, never the captain.' "$action" "$code" "$detail" ;;
    *)
      printf '%s: %s (%s).' "$code" "$action" "$detail" ;;
  esac
}
