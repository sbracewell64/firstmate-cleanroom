#!/usr/bin/env bash
# fm-continuation-resolve.sh - THE deterministic owner of "what runs next in a
# pinned programme, and under whose authority".
#
# Repairs a recurring defect: captain-facing synthesis manufacturing a captain
# gate ("needs your word") for a continuation the standing programme grant had
# already authorized, from prose and generic caution rather than typed state.
# Every path that tells firstmate to proceed, wait, escalate, or ask the captain
# about a programme step consumes THIS typed result (or an explicitly narrower
# canonical owner); none re-derives programme authority from prose.
# bin/fm-continuation-lib.sh owns the vocabulary and every classification table;
# this script only reads canonical state and applies them.
#
# Usage:
#   fm-continuation-resolve.sh resolve [--programme <file>] [--root <dir>] [--materialize]
#   fm-continuation-resolve.sh summary [--programme <file>] [--root <dir>]
#   fm-continuation-resolve.sh render  [--programme <file>] [--root <dir>]
#   fm-continuation-resolve.sh check-prose [<text-file>|-] [--programme <file>] [--root <dir>]
#
# Exit codes: 0 resolved; 3 no programme is configured for this home (every
# consumer treats 3 as "not applicable" and stays silent); 1 any other error.
#
# CANONICAL INPUTS, read only - this script keeps NO store of its own:
#   1. The pinned programme file (JSON): `programme_id`, `schema` (the programme
#      generation), `authorization_basis` {kind, refs[], and optionally
#      programme_generation, superseded_by}, `reserved_axes[]`, and ordered
#      `steps[]` {id, title, artifact_root, terminal_predicate{kind, accept[]},
#      classification_when_next, captain_axes[]{axis, decision_key, effect}}.
#      Legacy `optional_captain_enhancements[]` entries count as captain_axes
#      only when `required_to_proceed` is true. Located by --programme, then
#      FM_PROGRAMME, then the `programme=` line of $FM_HOME/config/programme.
#      Relative artifact roots resolve against a root paired with the source
#      that located the programme: --root always wins; a --programme or
#      FM_PROGRAMME programme then uses FM_PROGRAMME_ROOT; a config-located
#      programme then uses the config file's `root=` line; the fallback is the
#      programme file's own directory. The config `root=` never pairs with a
#      programme located elsewhere.
#   2. Proof dispositions: <root>/<artifact_root>/attempt-<n>/disposition.json,
#      read for `.outcome` only; the highest-numbered attempt is the current one
#      (predicate kind latest_attempt_disposition_outcome_in).
#   3. Durable hold state through tasks-axi in FM_HOME, the same backlog the
#      captain-hold owner (bin/fm-captain-hold.sh) writes. A hold binds to an
#      action only through the typed `Continuation-binding:` body line that
#      owner records; an unbound hold, a hold on another action or programme, a
#      lifted hold (task unheld), and a closed task gate nothing.
#   Control rulings reach this resolver through those stores: a ruling that
#   changes the sequence or grant is a programme-file change, and a ruling that
#   opens or closes a wait is a bound hold written through the captain-hold owner.
#
# RESULT (schema fm-continuation-resolution/v1), one JSON object:
#   next_action, next_action_title   the first step whose latest disposition is
#                                    not terminal-good; null when complete
#   action_generation                the attempt number the next action would run as
#   classification                   SELF_HANDLE | BROWSER_SOL | CAPTAIN | EXTERNAL_DEPENDENCY
#   authority_state                  AUTHORIZED | REQUIRES_RULING | REQUIRES_CAPTAIN | WAITING_EXTERNAL | CNO
#   reason_code                      the single typed reason the winner fired
#   basis_refs[]                     exact basis identities: the grant refs, the
#                                    predecessor disposition (path + sha256), every
#                                    gating hold (task id, kind, axis, wait), every
#                                    typed step fact that fired
#   applicability                    {action, programme_id, programme_generation,
#                                    action_generation, predecessor, current,
#                                    gating_holds[], today} - the exact tuple the
#                                    result is bound to; any change to it makes the
#                                    result stale
#   applicability_digest             sha256 of the canonical applicability JSON
#   holds                            {considered, gating[], ignored[{task, reason}]}
#   cno                              null, or {reason_code, detail} when a
#                                    canonical input could not be observed
#   materialize / materialized       the captain hold a CAPTAIN result from a
#                                    typed step fact requires / has created
#   why                              PRESENTATION ONLY, rendered from
#                                    reason_code + basis_refs + applicability
#
# LAW: the hold-effect, step-default, dominance, and authority tables live in
# bin/fm-continuation-lib.sh and are applied here unchanged. What this script
# adds on top of them: the standing grant pre-authorizes the next step on its
# predecessor's terminal-good disposition; a reserved axis the step's own typed
# facts declare fires CAPTAIN with no pre-existing hold, and `--materialize`
# then creates the durable hold through the captain-hold owner (idempotent);
# a superseded or wrong-generation grant, an unreadable disposition, or an
# unreadable hold store cannot authorize, so the result is CNO with
# BROWSER_SOL (uncertainty is never CAPTAIN) unless a reserved-axis fact
# independently yields CAPTAIN.
#
# `summary` prints the one-line typed token consumers embed (session start,
# the away-mode digest, fleet snapshot). `render` prints captain-facing prose
# derived from the typed result; it cannot override it. `check-prose` refuses
# (exit 1, naming the line) captain-facing text that asserts a captain gate
# when the typed result is not CAPTAIN, so a report path cannot say "needs your
# word" for an AUTHORIZED continuation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-continuation-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-continuation-lib.sh"
RESOLUTION_SCHEMA='fm-continuation-resolution/v1'
GRANT_KIND='standing_sequence_grant'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-continuation-resolve: %s\n' "$*" >&2
  exit 1
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

# --- locating the programme ---------------------------------------------------

PROGRAMME_OPT=''
ROOT_OPT=''
MATERIALIZE=0
PROSE_SOURCE=''

parse_common() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --programme) shift; PROGRAMME_OPT=${1:-} ;;
      --root) shift; ROOT_OPT=${1:-} ;;
      --materialize) MATERIALIZE=1 ;;
      -h|--help) usage; exit 0 ;;
      -) PROSE_SOURCE=- ;;
      -*) usage >&2; exit 2 ;;
      *) PROSE_SOURCE=$1 ;;
    esac
    shift
  done
}

config_value() {  # <key>
  [ -f "$CONFIG/programme" ] || return 0
  grep "^$1=" "$CONFIG/programme" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

PROGRAMME=''
ROOT=''
locate_programme() {
  local root_default=''
  if [ -n "$PROGRAMME_OPT" ]; then
    PROGRAMME=$PROGRAMME_OPT; root_default=${FM_PROGRAMME_ROOT:-}
  elif [ -n "${FM_PROGRAMME:-}" ]; then
    PROGRAMME=$FM_PROGRAMME; root_default=${FM_PROGRAMME_ROOT:-}
  else
    PROGRAMME=$(config_value programme); root_default=$(config_value root)
  fi
  if [ -z "$PROGRAMME" ]; then
    printf 'fm-continuation-resolve: no programme configured (set %s/programme with a programme= line, or pass --programme)\n' "$CONFIG" >&2
    exit 3
  fi
  [ -f "$PROGRAMME" ] || fail "programme file does not exist: $PROGRAMME"
  ROOT=${ROOT_OPT:-$root_default}
  [ -n "$ROOT" ] || ROOT=$(cd "$(dirname "$PROGRAMME")" && pwd)
  [ -d "$ROOT" ] || fail "programme root does not exist: $ROOT"
  jq -e '.programme_id and .schema and (.steps | type == "array" and length > 0)' "$PROGRAMME" >/dev/null 2>&1 \
    || fail "programme file is not a valid programme (programme_id, schema, steps[] required): $PROGRAMME"
}

# --- proof dispositions -------------------------------------------------------

# Prints "<attempt>\t<outcome>\t<path>\t<sha256>" for the highest-numbered
# attempt with a disposition, "" when none, and returns 1 when the newest
# disposition exists but cannot be read as JSON with an outcome.
latest_disposition() {  # <artifact-root>
  local rel=$1 dir best=-1 best_dir='' n d disp outcome
  case "$rel" in
    /*) dir=$rel ;;
    *) dir="$ROOT/$rel" ;;
  esac
  [ -d "$dir" ] || return 0
  for d in "$dir"/attempt-*; do
    [ -f "$d/disposition.json" ] || continue
    n=${d##*/attempt-}
    case "$n" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$n" -gt "$best" ]; then best=$n; best_dir=$d; fi
  done
  [ "$best" -ge 0 ] || return 0
  disp="$best_dir/disposition.json"
  outcome=$(jq -r 'if (.outcome | type) == "string" then .outcome else empty end' "$disp" 2>/dev/null) || outcome=''
  [ -n "$outcome" ] || { printf '%s\t\t%s\t\n' "$best" "$disp"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$best" "$outcome" "$disp" "$(sha256_file "$disp")"
}

# --- durable holds through tasks-axi -----------------------------------------

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

# Open tasks that carry a hold annotation, as "<id>\t<hold_kind>" lines, parsed
# from ONE captured listing. hold_kind is requested as the last column so a
# quoted comma in a title cannot shift it; an expired captain deferral still
# carries its kind here even though tasks-axi no longer reports it held.
# tasks-axi costs about a second per call, so only these tasks are shown in
# full afterwards.
held_task_ids() {  # <listing>
  printf '%s\n' "$1" | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      kind = $NF
      gsub(/"/, "", kind)
      if ($2 != "done" && kind != "-" && kind != "") printf "%s\t%s\n", id, kind
    }
  '
}

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

decode_shown() {  # <shown-value>
  local value=$1
  case "$value" in
    \"*\") printf '%s' "$value" | jq -r '.' ;;
    *) printf '%s' "$value" ;;
  esac
}

shown_value() {  # <show-output> <field>
  local value
  value=$(decode_shown "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

# Every open task carrying a hold, as JSON rows:
#   {task, hold_kind, hold_until, action, programme, axis, wait}
# with binding fields empty when the task has no typed binding line. Returns 1
# when the store cannot be read, printing the detail instead of rows so the
# caller records CNO naming what failed; a listed held task whose own record
# cannot be shown is such a failure, never a task to skip, because skipping it
# could authorize past a live bound hold.
hold_rows_json() {
  local listing ids id show kind until body binding action programme axis wait rows='[]' row
  # A read-only listing, so like the captain-hold owner's own read paths it skips
  # the mutation-oriented compatibility probe; a listing this parser cannot read
  # is an unreadable store (the caller records CNO), never an empty one.
  command -v tasks-axi >/dev/null 2>&1 || { printf 'tasks-axi not found on PATH'; return 1; }
  # tasks-axi always leads a listing with its count line; a stub or a broken
  # install that prints nothing is an unreadable store, never an empty one.
  listing=$(tasks_axi list --fields hold_kind 2>/dev/null) || { printf 'tasks-axi list failed in %s' "$FM_HOME"; return 1; }
  printf '%s\n' "$listing" | grep -q '^count: ' || { printf 'tasks-axi list printed no count: header in %s' "$FM_HOME"; return 1; }
  ids=$(held_task_ids "$listing")
  while IFS=$'\t' read -r id kind; do
    [ -n "$id" ] || continue
    show=$(tasks_axi show "$id" --full 2>/dev/null) || { printf 'tasks-axi show %s failed in %s' "$id" "$FM_HOME"; return 1; }
    [ "$(show_field "$show" state)" != "done" ] || continue
    kind=$(shown_value "$show" hold_kind)
    [ -n "$kind" ] || continue
    until=$(shown_value "$show" hold_until)
    body=$(shown_value "$show" body)
    binding=$(fm_continuation_binding_from_body "$body")
    action=$(fm_continuation_binding_field "$binding" action)
    programme=$(fm_continuation_binding_field "$binding" programme)
    axis=$(fm_continuation_binding_field "$binding" axis)
    wait=$(fm_continuation_binding_field "$binding" wait)
    fm_continuation_is_slug "$action" || action=''
    fm_continuation_is_slug "$programme" || programme=''
    fm_continuation_is_slug "$axis" || axis=''
    fm_continuation_is_wait "$wait" || wait=''
    row=$(jq -n --arg task "$id" --arg kind "$kind" --arg until "$until" \
      --arg action "$action" --arg programme "$programme" --arg axis "$axis" --arg wait "$wait" \
      '{task:$task, hold_kind:$kind, hold_until:$until, action:$action, programme:$programme, axis:$axis, wait:$wait}')
    rows=$(jq -n --argjson a "$rows" --argjson r "$row" '$a + [$r]')
  done <<EOF
$ids
EOF
  printf '%s' "$rows"
}

# --- resolution ---------------------------------------------------------------

RESULT=''

resolve_json() {
  local today prog_sha prog_id prog_gen grant_kind grant_refs grant_superseded grant_gen
  local cno_reason='' cno_detail='' completed='[]' next_id='' next_title='' next_index=-1
  local steps_n i sid title root pred_line pred_attempt pred_outcome pred_path pred_sha accept good
  local cur_attempt=0 cur_outcome='' cur_path='' cur_sha=''
  local reserved candidates='[]' holds_json='' gating='[]' ignored='[]' hold_count=0
  local n row kind until action programme axis wait active is_reserved effect eff_cls eff_reason
  local facts fact fact_axis fact_key fact_effect claimed default_pair def_cls def_reason
  local winner cls authority reason_code detail_text materialize='[]' pred_json current_json applicability digest why basis

  today=${FM_CONTINUATION_TODAY:-$(date -u +%Y-%m-%d)}
  prog_sha=$(sha256_file "$PROGRAMME")
  prog_id=$(jq -r '.programme_id' "$PROGRAMME")
  prog_gen=$(jq -r '.schema' "$PROGRAMME")
  fm_continuation_is_slug "$prog_id" || fail "programme_id must be a slug: $prog_id"
  grant_kind=$(jq -r '.authorization_basis.kind // ""' "$PROGRAMME")
  grant_refs=$(jq -c '[.authorization_basis.refs[]? | select(type == "string")]' "$PROGRAMME")
  grant_superseded=$(jq -r '.authorization_basis.superseded_by // ""' "$PROGRAMME")
  grant_gen=$(jq -r '.authorization_basis.programme_generation // ""' "$PROGRAMME")
  reserved=$(jq -r '.reserved_axes[]? | select(type == "string")' "$PROGRAMME")

  # Grant applicability: a superseded or wrong-generation grant cannot authorize.
  if [ -n "$grant_superseded" ]; then
    cno_reason=GRANT_SUPERSEDED; cno_detail=$grant_superseded
  elif [ -n "$grant_gen" ] && [ "$grant_gen" != "$prog_gen" ]; then
    cno_reason=GRANT_GENERATION_MISMATCH; cno_detail="grant $grant_gen vs programme $prog_gen"
  elif [ "$grant_kind" != "$GRANT_KIND" ]; then
    cno_reason=GRANT_KIND_UNKNOWN; cno_detail=${grant_kind:-absent}
  fi

  # Walk the pinned sequence: the first step whose latest disposition is not
  # terminal-good is the next action.
  steps_n=$(jq '.steps | length' "$PROGRAMME")
  i=0
  while [ "$i" -lt "$steps_n" ]; do
    sid=$(jq -r ".steps[$i].id // \"\"" "$PROGRAMME")
    fm_continuation_is_slug "$sid" || fail "steps[$i].id must be a slug"
    title=$(jq -r ".steps[$i].title // \"\"" "$PROGRAMME")
    root=$(jq -r ".steps[$i].artifact_root // \"\"" "$PROGRAMME")
    [ -n "$root" ] || fail "steps[$i] ($sid) has no artifact_root"
    [ "$(jq -r ".steps[$i].terminal_predicate.kind // \"\"" "$PROGRAMME")" = latest_attempt_disposition_outcome_in ] \
      || fail "steps[$i] ($sid) terminal_predicate.kind must be latest_attempt_disposition_outcome_in"
    if pred_line=$(latest_disposition "$root"); then
      pred_attempt=$(printf '%s' "$pred_line" | cut -f1)
      pred_outcome=$(printf '%s' "$pred_line" | cut -f2)
      pred_path=$(printf '%s' "$pred_line" | cut -f3)
      pred_sha=$(printf '%s' "$pred_line" | cut -f4)
    else
      # The newest disposition exists but is unreadable: this step is the next
      # action and its state could not be observed.
      pred_path=$(printf '%s' "$pred_line" | cut -f3)
      next_id=$sid; next_title=$title; next_index=$i
      cur_attempt=$(printf '%s' "$pred_line" | cut -f1); cur_outcome=''; cur_path=$pred_path; cur_sha=''
      [ -n "$cno_reason" ] || { cno_reason=PREDECESSOR_DISPOSITION_UNREADABLE; cno_detail=$pred_path; }
      break
    fi
    accept=$(jq -c ".steps[$i].terminal_predicate.accept // []" "$PROGRAMME")
    good=0
    if [ -n "${pred_outcome:-}" ]; then
      good=$(jq -n --argjson a "$accept" --arg o "$pred_outcome" '($a | index($o)) != null' | sed 's/true/1/; s/false/0/')
    fi
    if [ "$good" = 1 ]; then
      completed=$(jq -n --argjson c "$completed" --arg id "$sid" --argjson attempt "$pred_attempt" \
        --arg outcome "$pred_outcome" --arg path "$pred_path" --arg sha "$pred_sha" \
        '$c + [{id:$id, attempt:$attempt, outcome:$outcome, disposition:$path, sha256:$sha}]')
    else
      next_id=$sid; next_title=$title; next_index=$i
      cur_attempt=${pred_attempt:-0}; cur_outcome=${pred_outcome:-}; cur_path=${pred_path:-}; cur_sha=${pred_sha:-}
      break
    fi
    i=$((i + 1))
  done

  if [ -z "$next_id" ]; then
    RESULT=$(jq -n --arg schema "$RESOLUTION_SCHEMA" --arg pid "$prog_id" --arg gen "$prog_gen" \
      --arg path "$PROGRAMME" --arg sha "$prog_sha" --argjson completed "$completed" \
      --argjson refs "$grant_refs" --arg today "$today" \
      --arg why "$(fm_continuation_render_reason PROGRAMME_COMPLETE '' '' '')" '
      {schema:$schema,
       programme:{id:$pid, generation:$gen, path:$path, sha256:$sha},
       next_action:null, next_action_title:null, action_generation:null,
       classification:"SELF_HANDLE", authority_state:"AUTHORIZED", reason_code:"PROGRAMME_COMPLETE",
       basis_refs:([$refs[] | {kind:"programme_grant", ref:.}] + [$completed[] | {kind:"terminal_disposition"} + .]),
       applicability:{action:null, programme_id:$pid, programme_generation:$gen, action_generation:null,
                      predecessor:($completed | last), current:null, gating_holds:[], today:$today},
       completed:$completed, holds:{considered:0, gating:[], ignored:[]}, cno:null,
       materialize:[], why:$why}
      | .applicability_digest = (.applicability | tojson)')
    RESULT=$(printf '%s' "$RESULT" | jq --arg d "$(sha256_text "$(printf '%s' "$RESULT" | jq -r '.applicability_digest')")" '.applicability_digest = $d')
    return 0
  fi

  # Durable holds bound to THIS action.
  if holds_json=$(hold_rows_json); then
    hold_count=$(printf '%s' "$holds_json" | jq 'length')
    n=0
    while [ "$n" -lt "$hold_count" ]; do
      row=$(printf '%s' "$holds_json" | jq -c ".[$n]")
      n=$((n + 1))
      kind=$(printf '%s' "$row" | jq -r '.hold_kind')
      until=$(printf '%s' "$row" | jq -r '.hold_until')
      action=$(printf '%s' "$row" | jq -r '.action')
      programme=$(printf '%s' "$row" | jq -r '.programme')
      axis=$(printf '%s' "$row" | jq -r '.axis')
      wait=$(printf '%s' "$row" | jq -r '.wait')
      if [ -z "$action" ]; then
        ignored=$(jq -n --argjson a "$ignored" --argjson r "$row" '$a + [{task:$r.task, reason:"HOLD_UNBOUND"}]'); continue
      fi
      if [ "$action" != "$next_id" ]; then
        ignored=$(jq -n --argjson a "$ignored" --argjson r "$row" '$a + [{task:$r.task, reason:"HOLD_OTHER_ACTION", action:$r.action}]'); continue
      fi
      if [ -n "$programme" ] && [ "$programme" != "$prog_id" ]; then
        ignored=$(jq -n --argjson a "$ignored" --argjson r "$row" '$a + [{task:$r.task, reason:"HOLD_OTHER_PROGRAMME", programme:$r.programme}]'); continue
      fi
      active=1
      if [ -n "$until" ] && [ ! "$today" \< "$until" ]; then active=0; fi
      is_reserved=0
      fm_continuation_axis_reserved "$axis" "$reserved" && is_reserved=1
      effect=$(fm_continuation_hold_effect "$kind" "$is_reserved" "$wait" "$active")
      eff_cls=${effect%% *}; eff_reason=${effect#* }
      if [ "$eff_cls" = IGNORE ]; then
        ignored=$(jq -n --argjson a "$ignored" --argjson r "$row" --arg reason "$eff_reason" '$a + [{task:$r.task, reason:$reason}]'); continue
      fi
      gating=$(jq -n --argjson g "$gating" --argjson r "$row" --arg cls "$eff_cls" --arg reason "$eff_reason" \
        '$g + [$r + {classification:$cls, reason_code:$reason}]')
      candidates=$(jq -n --argjson c "$candidates" --argjson r "$row" --arg cls "$eff_cls" --arg reason "$eff_reason" \
        --argjson rank "$(fm_continuation_rank "$eff_cls")" \
        '$c + [{source:"hold", rank:$rank, classification:$cls, reason_code:$reason, task:$r.task, axis:$r.axis, wait:$r.wait, hold_kind:$r.hold_kind, detail:("task " + $r.task + (if $r.axis != "" then ", axis " + $r.axis else "" end))}]')
    done
  else
    [ -n "$cno_reason" ] || { cno_reason=HOLD_STORE_UNREADABLE; cno_detail=${holds_json:-tasks-axi unavailable or incompatible in $FM_HOME}; }
  fi

  # Typed step facts: a reserved axis the action itself declares fires CAPTAIN
  # with no pre-existing hold; a declared non-reserved axis is a refused claim.
  facts=$(jq -c "[(.steps[$next_index].captain_axes[]? | select(type == \"object\")),
                  (.steps[$next_index].optional_captain_enhancements[]? | select(type == \"object\" and .required_to_proceed == true))]" "$PROGRAMME")
  n=$(printf '%s' "$facts" | jq 'length')
  i=0
  while [ "$i" -lt "$n" ]; do
    fact=$(printf '%s' "$facts" | jq -c ".[$i]")
    i=$((i + 1))
    fact_axis=$(printf '%s' "$fact" | jq -r '.axis // ""')
    fact_key=$(printf '%s' "$fact" | jq -r '.decision_key // ""')
    fact_effect=$(printf '%s' "$fact" | jq -r '.effect // ""')
    fm_continuation_is_slug "$fact_axis" || continue
    if fm_continuation_axis_reserved "$fact_axis" "$reserved"; then
      candidates=$(jq -n --argjson c "$candidates" --arg axis "$fact_axis" --arg key "$fact_key" --arg effect "$fact_effect" \
        '$c + [{source:"step_fact", rank:3, classification:"CAPTAIN", reason_code:"STEP_RESERVED_AXIS", axis:$axis, decision_key:$key, effect:$effect, detail:("axis " + $axis)}]')
      materialize=$(jq -n --argjson m "$materialize" --arg axis "$fact_axis" --arg key "$fact_key" --arg effect "$fact_effect" \
        '$m + [{axis:$axis, decision_key:$key, effect:$effect}]')
    else
      candidates=$(jq -n --argjson c "$candidates" --arg axis "$fact_axis" \
        '$c + [{source:"step_fact", rank:2, classification:"BROWSER_SOL", reason_code:"CAPTAIN_CLAIM_WITHOUT_RESERVED_AXIS", axis:$axis, detail:("axis " + $axis + " is not a reserved axis")}]')
    fi
  done

  # The step's own default when nothing gates it.
  claimed=$(jq -r ".steps[$next_index].classification_when_next // \"\"" "$PROGRAMME")
  default_pair=$(fm_continuation_step_default "$claimed")
  def_cls=${default_pair%% *}; def_reason=${default_pair#* }
  if [ "$def_reason" = STANDING_GRANT ] && [ "$next_index" -eq 0 ]; then def_reason=FIRST_STEP_STANDING_GRANT; fi
  candidates=$(jq -n --argjson c "$candidates" --arg cls "$def_cls" --arg reason "$def_reason" --arg claimed "$claimed" \
    --argjson rank "$(fm_continuation_rank "$def_cls")" \
    '$c + [{source:"step_default", rank:$rank, classification:$cls, reason_code:$reason, detail:("claimed " + (if $claimed == "" then "SELF_HANDLE" else $claimed end))}]')

  # Dominance: highest rank wins; earlier candidate wins a tie (holds in task
  # order, then step facts, then the default), so the choice is deterministic.
  winner=$(printf '%s' "$candidates" | jq -c 'to_entries | max_by([.value.rank, -.key]) | .value')
  cls=$(printf '%s' "$winner" | jq -r '.classification')
  reason_code=$(printf '%s' "$winner" | jq -r '.reason_code')
  detail_text=$(printf '%s' "$winner" | jq -r '.detail // ""')
  authority=$(fm_continuation_authority_for "$cls")
  # A canonical input that could not be observed cannot authorize: CNO, and
  # never AUTHORIZED, unless a reserved-axis fact independently made this CAPTAIN.
  if [ -n "$cno_reason" ] && [ "$cls" != CAPTAIN ]; then
    cls=BROWSER_SOL; authority=CNO; reason_code=$cno_reason; detail_text=$cno_detail
  fi
  # Only a CAPTAIN winner from a typed step fact needs materializing; a CAPTAIN
  # from an existing hold is already durable, and any other class needs no hold.
  [ "$cls" = CAPTAIN ] || materialize='[]'
  if [ "$cls" = CAPTAIN ] && [ "$(printf '%s' "$winner" | jq -r '.source')" = hold ]; then
    # A hold already carries the captain gate; keep step-fact materialization
    # only for axes no gating hold covers yet.
    materialize=$(jq -n --argjson m "$materialize" --argjson g "$gating" \
      '[$m[] | . as $f | select(([$g[] | select(.classification == "CAPTAIN" and .axis == $f.axis)] | length) == 0)]')
  fi

  pred_json=$(printf '%s' "$completed" | jq -c 'last')
  current_json=$(jq -n --argjson attempt "${cur_attempt:-0}" --arg outcome "$cur_outcome" --arg path "$cur_path" --arg sha "$cur_sha" \
    'if $attempt == 0 then null else {attempt:$attempt, outcome:(if $outcome == "" then null else $outcome end), disposition:(if $path == "" then null else $path end), sha256:(if $sha == "" then null else $sha end)} end')
  applicability=$(jq -n -c --arg action "$next_id" --arg pid "$prog_id" --arg gen "$prog_gen" \
    --argjson action_generation "$((cur_attempt + 1))" --argjson pred "$pred_json" --argjson current "$current_json" \
    --argjson gating "$gating" --arg today "$today" --arg psha "$prog_sha" \
    '{action:$action, programme_id:$pid, programme_generation:$gen, programme_sha256:$psha, action_generation:$action_generation,
      predecessor:$pred, current:$current, gating_holds:[$gating[] | .task], today:$today}')
  digest=$(sha256_text "$applicability")
  why=$(fm_continuation_render_reason "$reason_code" "$next_id" \
    "$(printf '%s' "$pred_json" | jq -r 'if . == null then "" else .id + " attempt " + (.attempt | tostring) + " " + .outcome end')" \
    "$detail_text")
  basis=$(jq -n -c --argjson refs "$grant_refs" --argjson pred "$pred_json" --argjson gating "$gating" --argjson winner "$winner" \
    --argjson facts "$facts" --arg reserved "$(printf '%s' "$reserved" | tr '\n' ' ')" '
    [$refs[] | {kind:"programme_grant", ref:.}]
    + (if $pred == null then [] else [{kind:"predecessor_disposition"} + $pred] end)
    + [$gating[] | {kind:"hold", task, hold_kind, axis, wait, classification, reason_code}]
    + [$facts[] | select(.axis != null) | .axis as $ax | {kind:"step_fact", axis:$ax, decision_key:(.decision_key // null), reserved:((($reserved | split(" ")) | index($ax)) != null)}]')

  RESULT=$(jq -n --arg schema "$RESOLUTION_SCHEMA" --arg pid "$prog_id" --arg gen "$prog_gen" --arg path "$PROGRAMME" --arg sha "$prog_sha" \
    --arg next "$next_id" --arg title "$next_title" --argjson action_generation "$((cur_attempt + 1))" \
    --arg cls "$cls" --arg authority "$authority" --arg reason "$reason_code" \
    --argjson basis "$basis" --argjson applicability "$applicability" --arg digest "$digest" \
    --argjson completed "$completed" --argjson considered "${hold_count:-0}" --argjson gating "$gating" --argjson ignored "$ignored" \
    --arg cno_reason "$cno_reason" --arg cno_detail "$cno_detail" --argjson materialize "$materialize" --arg why "$why" '
    {schema:$schema,
     programme:{id:$pid, generation:$gen, path:$path, sha256:$sha},
     next_action:$next, next_action_title:(if $title == "" then null else $title end), action_generation:$action_generation,
     classification:$cls, authority_state:$authority, reason_code:$reason,
     basis_refs:$basis, applicability:$applicability, applicability_digest:$digest,
     completed:$completed,
     holds:{considered:$considered, gating:$gating, ignored:$ignored},
     cno:(if $cno_reason == "" then null else {reason_code:$cno_reason, detail:$cno_detail} end),
     materialize:$materialize, why:$why}')
}

# Create the durable captain hold a CAPTAIN result from a typed step fact
# requires, through the captain-hold owner only. Idempotent: an existing bound
# hold is left as it is.
materialize_holds() {
  local n i item axis key effect task title reason created='[]'
  n=$(printf '%s' "$RESULT" | jq '.materialize | length')
  [ "$n" -gt 0 ] || { RESULT=$(printf '%s' "$RESULT" | jq '.materialized = []'); return 0; }
  i=0
  while [ "$i" -lt "$n" ]; do
    item=$(printf '%s' "$RESULT" | jq -c ".materialize[$i]")
    i=$((i + 1))
    axis=$(printf '%s' "$item" | jq -r '.axis')
    key=$(printf '%s' "$item" | jq -r '.decision_key')
    effect=$(printf '%s' "$item" | jq -r '.effect')
    if fm_continuation_is_slug "$key"; then task=$key
    else task=$(printf '%s-%s-%s' "$(printf '%s' "$RESULT" | jq -r '.programme.id')" "$(printf '%s' "$RESULT" | jq -r '.next_action')" "$axis" | tr '_' '-'); fi
    title=$(printf 'Captain decision for %s: %s' "$(printf '%s' "$RESULT" | jq -r '.next_action')" "${effect:-reserved axis $axis}" | tr '()' '[]')
    reason=$(printf 'reserved axis %s on programme step %s' "$axis" "$(printf '%s' "$RESULT" | jq -r '.next_action')")
    "$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" --title "$title" --reason "$reason" \
      --action "$(printf '%s' "$RESULT" | jq -r '.next_action')" --axis "$axis" \
      --programme "$(printf '%s' "$RESULT" | jq -r '.programme.id')" >/dev/null \
      || fail "could not materialize captain hold $task through fm-captain-hold.sh"
    created=$(jq -n --argjson c "$created" --arg task "$task" --arg axis "$axis" '$c + [{task:$task, axis:$axis}]')
  done
  # Re-resolve so the result reflects the durable hold it just created.
  resolve_json
  RESULT=$(printf '%s' "$RESULT" | jq --argjson m "$created" '.materialized = $m')
}

# --- commands -----------------------------------------------------------------

command_resolve() {
  parse_common "$@"
  locate_programme
  resolve_json
  if [ "$MATERIALIZE" = 1 ]; then materialize_holds; fi
  printf '%s\n' "$RESULT" | jq '.'
}

summary_line() {  # <result-json>
  printf '%s' "$1" | jq -r '
    if .next_action == null then
      "programme " + .programme.id + "@" + .programme.generation + ": complete (" + .reason_code + ")"
    else
      "programme " + .programme.id + "@" + .programme.generation + ": next=" + .next_action
      + " " + .classification + "/" + .authority_state + " reason=" + .reason_code
      + " applicability=" + .applicability_digest[0:12]
    end'
}

command_summary() {
  parse_common "$@"
  locate_programme
  resolve_json
  summary_line "$RESULT"
}

render_text() {  # <result-json>
  printf '%s' "$1" | jq -r '
    (if .next_action == null then "Programme " + .programme.id + " is complete."
     else "Programme " + .programme.id + ": next action " + .next_action
          + (if .next_action_title then " (" + .next_action_title + ")" else "" end)
          + ", attempt " + (.action_generation | tostring) + "." end),
    "Typed result: " + .classification + " / " + .authority_state + " [" + .reason_code + "].",
    .why,
    "Basis:",
    (.basis_refs[] | "  - " + (
      if .kind == "programme_grant" then "grant " + .ref
      elif .kind == "predecessor_disposition" or .kind == "terminal_disposition" then "disposition " + .id + " attempt " + (.attempt | tostring) + " " + .outcome + " (" + .sha256[0:12] + ")"
      elif .kind == "hold" then "hold " + .task + " (" + .hold_kind + (if .axis != "" then ", axis " + .axis else "" end) + (if .wait != "" then ", wait " + .wait else "" end) + ") -> " + .classification
      elif .kind == "step_fact" then "step fact axis " + .axis + (if .reserved then " (reserved)" else " (not reserved)" end)
      else tojson end)),
    (if (.materialize | length) > 0 then "Durable captain hold required: run fm-continuation-resolve.sh resolve --materialize." else empty end),
    "Applicability " + .applicability_digest[0:12] + ": action " + (.applicability.action // "none") + ", generation " + ((.applicability.action_generation // "-") | tostring) + ", programme " + .applicability.programme_generation + "."'
}

command_render() {
  parse_common "$@"
  locate_programme
  resolve_json
  render_text "$RESULT"
}

command_check_prose() {
  local text cls offending
  parse_common "$@"
  locate_programme
  if [ -z "$PROSE_SOURCE" ] || [ "$PROSE_SOURCE" = - ]; then
    text=$(cat)
  else
    [ -f "$PROSE_SOURCE" ] || fail "text file does not exist: $PROSE_SOURCE"
    text=$(cat "$PROSE_SOURCE")
  fi
  resolve_json
  cls=$(printf '%s' "$RESULT" | jq -r '.classification')
  if [ "$cls" = CAPTAIN ]; then
    printf 'check-prose: typed resolution is CAPTAIN; captain-gate phrasing is consistent\n'
    return 0
  fi
  offending=$(printf '%s\n' "$text" | grep -inE "$FM_CONTINUATION_GATE_PHRASE_RE" || true)
  if [ -n "$offending" ]; then
    printf 'check-prose: REFUSED - text asserts a captain gate while the typed resolution is %s/%s for %s:\n' \
      "$cls" "$(printf '%s' "$RESULT" | jq -r '.authority_state')" "$(printf '%s' "$RESULT" | jq -r '.next_action // "programme complete"')" >&2
    printf '%s\n' "$offending" >&2
    return 1
  fi
  printf 'check-prose: no captain-gate phrasing; consistent with %s/%s\n' "$cls" "$(printf '%s' "$RESULT" | jq -r '.authority_state')"
}

case "${1:-}" in
  resolve) shift; command_resolve "$@" ;;
  summary) shift; command_summary "$@" ;;
  render) shift; command_render "$@" ;;
  check-prose) shift; command_check_prose "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
