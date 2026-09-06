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
# Owner map: resolver = bin/fm-continuation-lib.sh + this script; hold
# durability and effect = bin/fm-captain-hold.sh; backend agent-status -> wake
# transitions = bin/fm-transition-lib.sh; distinct owners with no coupling.
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
#      only when `required_to_proceed` is true. Identity rule: each required
#      fact's durable identity is the task `--materialize` would hold (its
#      decision_key when that is a slug, else programme-action-axis), and it
#      is injective over required facts - one fact, one identity, one durable
#      binding - so two required facts resolving to one identity, keyed or
#      keyless, in one step or across steps, are refused at load; a
#      non-required enhancement never becomes a fact or a task, so its key
#      reuse is not load-bearing.
#      Located by --programme, then
#      FM_PROGRAMME, then the `programme=` line of $FM_HOME/config/programme.
#      Relative artifact roots resolve against a root paired with the source
#      that located the programme: --root always wins; a --programme or
#      FM_PROGRAMME programme then uses FM_PROGRAMME_ROOT; a config-located
#      programme then uses the config file's `root=` line; the fallback is the
#      programme file's own directory. The config `root=` never pairs with a
#      programme located elsewhere.
#      Structure refused at load (exit 1, naming the defect): a duplicated
#      step id; a `terminal_predicate.kind` outside the closed vocabulary
#      bin/fm-continuation-lib.sh owns (FM_CONTINUATION_EVIDENCE_KINDS); a
#      step `depends_on` (string or array) naming an unknown step, itself, or
#      a LATER step (the pinned order is the sequence; a dependency on a later
#      step is an order contradiction and a cycle is impossible once every
#      dependency points earlier). The walk itself stays sequential: the next
#      action is the first step in pinned order that is not terminal-good.
#      The optional top-level `project` (forge slug) and `binding` object are
#      data the evidence adapter and the callers consume (see 2b and BINDING).
#   2. Proof dispositions: <root>/<artifact_root>/attempt-<n>/disposition.json,
#      read for `.outcome` only; the highest-numbered attempt directory is the
#      current one (predicate kind latest_attempt_disposition_outcome_in), and
#      when it has no readable disposition the step is not terminal: it is the
#      next action with CNO, never an older attempt's authorization.
#   2b. Accepted owner evidence (predicate kind accepted_owner_evidence): the
#      CLOSED non-proof completion-evidence adapter. A step of this kind names
#      `terminal_predicate.evidence`, one owner-produced machine-readable JSON
#      record (schema fm-accepted-owner-evidence/v1) resolved against the
#      programme file's own directory when relative, since the programme owner
#      authors the record beside the programme; `accept[]` names the observed
#      outcomes that count as terminal-good. The record carries: `evidence_id`
#      (slug), `programme_id`, `step`, `project`, `work_id`, `owner`
#      {kind, ref} with kind in the closed owner vocabulary the library owns,
#      `outcome` in that owner kind's closed outcome vocabulary, and optionally
#      `generation` (integer), `candidate` {exact identities such as head,
#      merge_commit, base}, `policy` {id, digest}, `verifier` {tool, ...},
#      `qualification` {pipeline, evidence_refs[]} (required for
#      MERGED_QUALIFIED), `captures[]` (declared locators, byte counts and
#      sha256 of the owner bytes the producer read), `sources[]` (local files
#      under <root> the record binds: {kind:"local_file", path, sha256,
#      outcome?}, verified here by recomputed sha256 and, when `outcome` is
#      declared, by that file's own `.outcome`), `observed_bad[]`, and
#      `superseded_by`. The step may pin `owner_ref`, `candidate` {keys that
#      must equal the record's}, `policy_digest`, `evidence_sha256`, and
#      `evidence_generation`; every pin is verified. The adapter returns an
#      observed status and applicability ONLY and grants nothing:
#        ACCEPTED       outcome in accept[] and every check passed -> terminal-good
#        NOT_ACCEPTED   well-formed, verified, outcome not in accept[] (a
#                       landing or report without its qualification) -> the
#                       step is the next action under the ordinary law
#        REFUSED        unsupported schema, owner kind, or outcome; malformed;
#                       programme, step, project, work, owner, candidate,
#                       policy, digest, or generation mismatch; superseded;
#                       observed_bad recorded; bound source digest or outcome
#                       mismatch -> the step is the next action with CNO
#                       (reason OWNER_EVIDENCE_*), never AUTHORIZED
#        CNO            record absent (REQUIRED_BINDING_MISSING), unreadable,
#                       or a bound source unreadable -> the step is the next
#                       action with CNO, never AUTHORIZED
#      A missing record is CNO and a contradiction is a refusal; neither ever
#      becomes CAPTAIN. No command, predicate registry, plugin, or workflow
#      language is read from a record; an owner kind or outcome outside the
#      closed tables is refused, not interpreted.
#   3. Durable hold state through tasks-axi in FM_HOME, the same backlog the
#      captain-hold owner (bin/fm-captain-hold.sh) writes. A hold binds to an
#      action only through the typed `Continuation-binding:` body line that
#      owner records; an unbound hold, a hold on another action or programme, a
#      lifted hold (task unheld), and a closed task gate nothing. The same
#      store also carries the captain's recorded answer to a typed step fact:
#      the fact's decision task (its decision_key, else programme-action-axis)
#      retires the fact when it is closed with a resolution record, or open,
#      newest-recorded as released, and not under a live captain hold, and only when that task's own
#      Continuation-binding names this action and this programme (or no
#      programme); an answer bound to another action or programme, an unbound
#      record, and a plain closure without a record are not answers for this
#      action.
#   Control rulings reach this resolver through those stores: a ruling that
#   changes the sequence or grant is a programme-file change, and a ruling that
#   opens or closes a wait is a bound hold written through the captain-hold owner.
#
# BINDING (programme `binding` object, required whenever any step uses
# accepted_owner_evidence, tolerated absent for a proof-only programme):
#   {commission:{work_id, work_generation}, grant:{owner, ref, id},
#    ruling:{owner, ref, id}, consumer:{contract, projection},
#    evidence_kinds[], programme_generation, ...}
#   Verified at load: `consumer.contract` must equal this resolver's result
#   schema, `evidence_kinds` must be a subset of the closed vocabulary and
#   cover every step's kind, and `programme_generation` when present must equal
#   `schema`; a mismatch is refused (exit 1). A programme with an
#   accepted_owner_evidence step and no binding is refused with
#   REQUIRED_BINDING_MISSING. The result's `binding` field carries the object
#   with `present: true`, or `{present:false, reason:"REQUIRED_BINDING_MISSING"}`
#   for a legacy proof-only programme, which every caller prints loudly rather
#   than as an optional N/A. The result's `runtime` names this resolver's own
#   path, sha256, and supported evidence kinds, so a caller can tell a landed
#   resolver from the one it is actually running.
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
#   programme                        {id, generation, path, root, sha256}: the
#                                    programme as located, so a composition layer
#                                    (bin/fm-programme-projection.sh) reads the
#                                    same file and artifact root this run used
#                                    instead of re-deriving the location rules
#   holds                            {considered, gating[], ignored[{task, reason}]}
#   cno                              null, or {reason_code, detail} when a
#                                    canonical input could not be observed
#   materialize / materialized       the captain hold a CAPTAIN result from a
#                                    typed step fact requires / has created
#   evidence                         null, or the adapter's observed reading of
#                                    the next action's owner evidence record
#                                    (path, sha256, status, outcome, reason_code,
#                                    detail, owner, sources[])
#   binding, runtime                 see BINDING above
#   accountable_owner                the one owner accountable for the next
#                                    action (library projection; never authority)
#   material_identity                sha256 of the clock-free canonical tuple
#                                    {programme, binding ids, next action and
#                                    generation, classification, authority,
#                                    reason, cno, accountable owner, predecessor,
#                                    current, evidence, gating holds, answered
#                                    facts, materialize axes, completed ids}. It
#                                    excludes `today` and every path, so a
#                                    presentation caller can key "already
#                                    presented" on material state alone
#   why                              PRESENTATION ONLY, rendered from
#                                    reason_code + basis_refs + applicability
#
# LAW: the hold-effect, step-default, dominance, and authority tables live in
# bin/fm-continuation-lib.sh and are applied here unchanged. What this script
# adds on top of them: the standing grant pre-authorizes the next step on its
# predecessor's terminal-good disposition; a reserved axis the step's own typed
# facts declare fires CAPTAIN with no pre-existing hold, and `--materialize`
# then creates the durable hold through the captain-hold owner (idempotent);
# once the captain's answer is recorded on that fact's decision task the fact
# is retired (listed in basis_refs as answered, fires nothing, and is never
# materialized again), so an answered call cannot re-manufacture the gate;
# retirement survives later non-captain holds on that task (an external wait
# or a parked hold gates through the hold path, never re-fires the fact);
# ONE IDENTITY: a fact is identified everywhere by its own task
# (fact_task_id) - coverage by a gating captain hold, answer lookup, and
# materialization all key on that task, so a foreign hold that merely shares
# the axis gates on its own but never stands in for the fact, each distinct
# fact materializes exactly one canonical hold, and it is answered through
# that same task; `--materialize` never replaces a live non-captain hold and
# never rebinds a decision task whose binding names another action or
# programme (it fails naming both), so replay converges on one binding;
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
PROOF_KIND='latest_attempt_disposition_outcome_in'
OWNER_KIND='accepted_owner_evidence'

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
  local root_default='' prog_id reserved facts shared
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
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$PROGRAMME" ] || fail "programme file does not exist: $PROGRAMME"
  ROOT=${ROOT_OPT:-$root_default}
  [ -n "$ROOT" ] || ROOT=$(cd "$(dirname "$PROGRAMME")" && pwd)
  [ -d "$ROOT" ] || fail "programme root does not exist: $ROOT"
  jq -e '.programme_id and .schema and (.steps | type == "array" and length > 0)' "$PROGRAMME" >/dev/null 2>&1 \
    || fail "programme file is not a valid programme (programme_id, schema, steps[] required): $PROGRAMME"
  prog_id=$(jq -r '.programme_id' "$PROGRAMME")
  reserved=$(jq -r '.reserved_axes[]? | select(type == "string")' "$PROGRAMME")
  facts=$(jq -r '
    .steps[] | select(type == "object") | (.id // "?") as $step
      | ((.captain_axes // [] | map(select(type == "object")))
         + (.optional_captain_enhancements // [] | map(select(type == "object" and .required_to_proceed == true))))[]
      | [$step, (.axis // "" | tostring), (.decision_key // "" | tostring)] | @tsv' "$PROGRAMME" 2>/dev/null)
  shared=$(while IFS=$'\t' read -r step axis key; do
      [ -n "$step" ] || continue
      fm_continuation_is_slug "$axis" || continue
      fm_continuation_axis_reserved "$axis" "$reserved" || continue
      printf '%s\t%s/%s\n' "$(fact_task_id "$key" "$prog_id" "$step" "$axis")" "$step" "$axis"
    done <<EOF | awk -F'\t' '
      { n[$1]++; f[$1] = (f[$1] == "" ? $2 : f[$1] ", " $2) }
      END { for (id in n) if (n[id] > 1) printf "%s (facts %s)\n", id, f[id] }' | sort | paste -sd ';' -
$facts
EOF
  )
  [ -z "$shared" ] || fail "a required fact's durable identity (decision_key when a slug, else programme-action-axis) must be unique; shared in $PROGRAMME: $shared"
  validate_structure
  validate_binding
}

PROGRAMME_DIR=''
# Step ids, predicate kinds, per-kind required fields, and explicit dependencies.
validate_structure() {
  local dup rows i sid kind dep deps j seen=''
  PROGRAMME_DIR=$(cd "$(dirname "$PROGRAMME")" && pwd)
  dup=$(jq -r '[.steps[] | select(type == "object") | .id | select(type == "string")] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$PROGRAMME")
  [ -z "$dup" ] || fail "step ids must be unique in $PROGRAMME; duplicated: $dup"
  # Joined on the unit separator, not a tab: an empty middle field (a proof
  # step has no evidence path, an owner step no artifact root) would collapse
  # under a whitespace IFS and shift the columns.
  rows=$(jq -r '.steps[] | [(.id // ""), (.terminal_predicate.kind // ""), (.artifact_root // "" | tostring), (.terminal_predicate.evidence // "" | tostring),
                            ((.depends_on // []) | if type == "string" then [.] elif type == "array" then . else ["<invalid>"] end | map(tostring) | join(" "))] | join("\u001f")' "$PROGRAMME")
  i=0
  while IFS=$'\x1f' read -r sid kind root evidence deps; do
    fm_continuation_is_slug "$sid" || fail "steps[$i].id must be a slug"
    fm_continuation_is_evidence_kind "$kind" \
      || fail "steps[$i] ($sid) terminal_predicate.kind must be one of: $FM_CONTINUATION_EVIDENCE_KINDS (got ${kind:-absent})"
    case "$kind" in
      "$PROOF_KIND") [ -n "$root" ] || fail "steps[$i] ($sid) has no artifact_root" ;;
      "$OWNER_KIND") [ -n "$evidence" ] || fail "steps[$i] ($sid) names no terminal_predicate.evidence record" ;;
    esac
    for dep in $deps; do
      [ "$dep" != '<invalid>' ] || fail "steps[$i] ($sid) depends_on must be a step id or an array of step ids"
      [ "$dep" != "$sid" ] || fail "steps[$i] ($sid) depends on itself (cycle)"
      j=$(printf '%s\n' "$seen" | grep -nx -- "$dep" | head -1 | cut -d: -f1) || true
      if [ -z "$j" ]; then
        if jq -e --arg d "$dep" '[.steps[] | .id] | index($d) != null' "$PROGRAMME" >/dev/null; then
          fail "steps[$i] ($sid) depends on a LATER step $dep; the pinned order is the sequence, so this is an order contradiction (or a cycle)"
        fi
        fail "steps[$i] ($sid) depends on an unknown step $dep"
      fi
    done
    seen="$seen$sid
"
    i=$((i + 1))
  done <<EOF
$rows
EOF
}

BINDING_JSON='{"present":false}'
# The commission/grant/consumer binding: required for any owner-evidence step,
# verified against this resolver's contract and supported kinds.
validate_binding() {
  local has_owner kinds kind step_kinds contract gen
  has_owner=$(jq -r --arg k "$OWNER_KIND" '[.steps[] | .terminal_predicate.kind] | index($k) != null' "$PROGRAMME")
  if [ "$(jq -r '.binding | type' "$PROGRAMME")" = null ]; then
    if [ "$has_owner" = true ]; then
      fail "REQUIRED_BINDING_MISSING: $PROGRAMME uses $OWNER_KIND steps but declares no binding {commission, grant, consumer.contract, evidence_kinds}; nothing is accepted from an unbound programme"
    fi
    BINDING_JSON=$(jq -n '{present:false, reason:"REQUIRED_BINDING_MISSING", detail:"the programme declares no commission/grant/consumer binding; authority derives from the grant refs alone and the binding must be recorded by the programme owner"}')
    return 0
  fi
  [ "$(jq -r '.binding | type' "$PROGRAMME")" = object ] || fail "binding must be an object in $PROGRAMME"
  contract=$(jq -r '.binding.consumer.contract // ""' "$PROGRAMME")
  [ "$contract" = "$RESOLUTION_SCHEMA" ] \
    || fail "binding.consumer.contract must name this resolver's result contract $RESOLUTION_SCHEMA (got ${contract:-absent}); a different consumer contract or version cannot be consumed here"
  gen=$(jq -r '.binding.programme_generation // ""' "$PROGRAMME")
  [ -z "$gen" ] || [ "$gen" = "$(jq -r '.schema' "$PROGRAMME")" ] \
    || fail "binding.programme_generation $gen does not match the programme schema $(jq -r '.schema' "$PROGRAMME")"
  [ "$(jq -r '.binding.evidence_kinds | type' "$PROGRAMME")" = array ] || fail "binding.evidence_kinds must be an array"
  kinds=$(jq -r '.binding.evidence_kinds[] | tostring' "$PROGRAMME")
  for kind in $kinds; do
    fm_continuation_is_evidence_kind "$kind" || fail "binding.evidence_kinds names an unsupported completion-evidence kind $kind; this resolver supports: $FM_CONTINUATION_EVIDENCE_KINDS"
  done
  step_kinds=$(jq -r '[.steps[] | .terminal_predicate.kind] | unique[]' "$PROGRAMME")
  for kind in $step_kinds; do
    case " $(printf '%s' "$kinds" | tr '\n' ' ') " in
      *" $kind "*) ;;
      *) fail "a step uses completion-evidence kind $kind that binding.evidence_kinds does not declare" ;;
    esac
  done
  fm_continuation_is_slug "$(jq -r '.binding.commission.work_id // ""' "$PROGRAMME")" || fail "binding.commission.work_id must be a slug"
  [ -n "$(jq -r '.binding.grant.id // ""' "$PROGRAMME")" ] && [ -n "$(jq -r '.binding.grant.ref // ""' "$PROGRAMME")" ] \
    || fail "binding.grant must name the controlling grant's id and ref"
  BINDING_JSON=$(jq -c '.binding + {present:true}' "$PROGRAMME")
}

# --- proof dispositions -------------------------------------------------------

# Prints "<attempt>\t<outcome>\t<path>\t<sha256>" for the highest-numbered
# attempt directory, "" when none, and returns 1 with an empty outcome when
# that newest attempt has no disposition or one that cannot be read as JSON
# with an outcome: an in-flight or broken newest attempt is never terminal,
# and an older attempt's disposition never stands in for it.
latest_disposition() {  # <artifact-root>
  local rel=$1 dir best=-1 best_dir='' n d disp outcome
  case "$rel" in
    /*) dir=$rel ;;
    *) dir="$ROOT/$rel" ;;
  esac
  [ -d "$dir" ] || return 0
  for d in "$dir"/attempt-*; do
    [ -d "$d" ] || continue
    n=${d##*/attempt-}
    case "$n" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$n" -gt "$best" ]; then best=$n; best_dir=$d; fi
  done
  [ "$best" -ge 0 ] || return 0
  disp="$best_dir/disposition.json"
  [ -f "$disp" ] || { printf '%s\t\t%s\t\n' "$best" "$disp"; return 1; }
  outcome=$(jq -r 'if (.outcome | type) == "string" then .outcome else empty end' "$disp" 2>/dev/null) || outcome=''
  [ -n "$outcome" ] || { printf '%s\t\t%s\t\n' "$best" "$disp"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$best" "$outcome" "$disp" "$(sha256_file "$disp")"
}

# --- accepted owner evidence ---------------------------------------------------

# One JSON object describing the adapter's reading of a step's owner evidence
# record: {path, sha256, status, outcome, reason_code, detail, evidence_id,
# owner, generation, candidate, policy, verifier, qualification, captures,
# sources}. Always prints; status carries the verdict (ACCEPTED, NOT_ACCEPTED,
# REFUSED, CNO). Every check is a closed comparison of record fields against
# the programme step, the binding, and local bytes; nothing in the record is
# executed or interpreted.
read_owner_evidence() {  # <step-index> <step-id>
  local i=$1 sid=$2 rel path sha doc status='' reason='' detail='' outcome=''
  local kind ref accept pin_ref pin_cand pin_policy pin_sha pin_gen work_id prog_project ev_project ev_work
  local sources n j src spath ssha sout sfile fsha fout
  rel=$(jq -r ".steps[$i].terminal_predicate.evidence // \"\"" "$PROGRAMME")
  case "$rel" in
    /*) path=$rel ;;
    *) path="$PROGRAMME_DIR/$rel" ;;
  esac
  emit() {  # <status> <reason> <detail> <doc-or-null> <sha> <outcome>
    jq -n -c --arg path "$path" --arg status "$1" --arg reason "$2" --arg detail "$3" --argjson doc "${4:-null}" --arg sha "$5" --arg outcome "$6" '
      {path:$path, sha256:(if $sha == "" then null else $sha end), status:$status, outcome:(if $outcome == "" then null else $outcome end),
       reason_code:(if $reason == "" then null else $reason end), detail:(if $detail == "" then null else $detail end),
       evidence_id:($doc.evidence_id // null), owner:($doc.owner // null), generation:($doc.generation // null),
       candidate:($doc.candidate // null), policy:($doc.policy // null), verifier:($doc.verifier // null),
       qualification:($doc.qualification // null), captures:($doc.captures // []),
       sources:[($doc.sources // [])[] | {kind, path, sha256, outcome:(.outcome // null)}]}'
  }
  if [ ! -f "$path" ]; then
    emit CNO REQUIRED_BINDING_MISSING "no owner-produced evidence record is bound at $path for step $sid (accepted owner kinds: $FM_CONTINUATION_OWNER_KINDS)" null '' ''
    return 0
  fi
  sha=$(sha256_file "$path")
  if ! doc=$(jq -c 'if type == "object" then . else error("not an object") end' "$path" 2>/dev/null); then
    emit CNO OWNER_EVIDENCE_UNREADABLE "$path is not a readable JSON object" null "$sha" ''
    return 0
  fi
  refuse() {  # <reason> <detail>
    emit REFUSED "$1" "$2" "$doc" "$sha" "$(printf '%s' "$doc" | jq -r 'if (.outcome | type) == "string" then .outcome else "" end')"
  }
  if [ "$(printf '%s' "$doc" | jq -r '.schema // ""')" != "$FM_CONTINUATION_EVIDENCE_SCHEMA" ]; then
    refuse OWNER_EVIDENCE_SCHEMA_UNSUPPORTED "schema $(printf '%s' "$doc" | jq -r '.schema // "absent"') is not $FM_CONTINUATION_EVIDENCE_SCHEMA"; return 0
  fi
  if ! printf '%s' "$doc" | jq -e '(.evidence_id | type) == "string" and (.programme_id | type) == "string" and (.step | type) == "string"
        and (.owner | type) == "object" and (.owner.kind | type) == "string" and (.owner.ref | type) == "string" and (.outcome | type) == "string"' >/dev/null 2>&1; then
    refuse OWNER_EVIDENCE_MALFORMED "evidence_id, programme_id, step, owner{kind, ref}, and outcome are required strings"; return 0
  fi
  fm_continuation_is_slug "$(printf '%s' "$doc" | jq -r '.evidence_id')" || { refuse OWNER_EVIDENCE_MALFORMED "evidence_id must be a slug"; return 0; }
  kind=$(printf '%s' "$doc" | jq -r '.owner.kind'); ref=$(printf '%s' "$doc" | jq -r '.owner.ref'); outcome=$(printf '%s' "$doc" | jq -r '.outcome')
  fm_continuation_is_owner_kind "$kind" || { refuse OWNER_EVIDENCE_OWNER_KIND_UNSUPPORTED "owner kind $kind is not one of: $FM_CONTINUATION_OWNER_KINDS"; return 0; }
  fm_continuation_owner_outcome_supported "$kind" "$outcome" \
    || { refuse OWNER_EVIDENCE_OUTCOME_UNSUPPORTED "outcome $outcome is not in the $kind vocabulary ($(fm_continuation_owner_outcomes "$kind"))"; return 0; }
  if [ "$outcome" = MERGED_QUALIFIED ] && ! printf '%s' "$doc" | jq -e '(.qualification.pipeline | type) == "string" and (.qualification.evidence_refs | type) == "array" and (.qualification.evidence_refs | length) > 0' >/dev/null 2>&1; then
    refuse OWNER_EVIDENCE_MALFORMED "MERGED_QUALIFIED requires qualification{pipeline, evidence_refs[]} binding the qualification record"; return 0
  fi
  [ "$(printf '%s' "$doc" | jq -r '.programme_id')" = "$(jq -r '.programme_id' "$PROGRAMME")" ] \
    || { refuse OWNER_EVIDENCE_PROGRAMME_MISMATCH "record names programme $(printf '%s' "$doc" | jq -r '.programme_id'), not $(jq -r '.programme_id' "$PROGRAMME")"; return 0; }
  [ "$(printf '%s' "$doc" | jq -r '.step')" = "$sid" ] \
    || { refuse OWNER_EVIDENCE_STEP_MISMATCH "record names step $(printf '%s' "$doc" | jq -r '.step'), not $sid"; return 0; }
  prog_project=$(jq -r '.project // ""' "$PROGRAMME"); ev_project=$(printf '%s' "$doc" | jq -r '.project // ""')
  if [ -n "$prog_project" ] && [ "$ev_project" != "$prog_project" ]; then
    refuse OWNER_EVIDENCE_PROJECT_MISMATCH "record names project ${ev_project:-<none>}, not $prog_project"; return 0
  fi
  work_id=$(printf '%s' "$BINDING_JSON" | jq -r '.commission.work_id // ""'); ev_work=$(printf '%s' "$doc" | jq -r '.work_id // ""')
  if [ -n "$work_id" ] && [ "$ev_work" != "$work_id" ]; then
    refuse OWNER_EVIDENCE_WORK_MISMATCH "record names work ${ev_work:-<none>}, not the bound commission $work_id"; return 0
  fi
  pin_ref=$(jq -r ".steps[$i].terminal_predicate.owner_ref // \"\"" "$PROGRAMME")
  if [ -n "$pin_ref" ] && [ "$pin_ref" != "$ref" ]; then
    refuse OWNER_EVIDENCE_OWNER_MISMATCH "record owner $ref is not the pinned owner $pin_ref"; return 0
  fi
  pin_cand=$(jq -c ".steps[$i].terminal_predicate.candidate // {}" "$PROGRAMME")
  if [ "$pin_cand" != '{}' ]; then
    detail=$(printf '%s' "$doc" | jq -r --argjson pin "$pin_cand" '(.candidate // {}) as $c | [$pin | to_entries[] | select((.value | tostring) != (($c[.key] // null) | tostring)) | .key + "=" + (.value | tostring) + " (record " + (($c[.key] // "absent") | tostring) + ")"] | join(", ")')
    if [ -n "$detail" ]; then refuse OWNER_EVIDENCE_CANDIDATE_MISMATCH "pinned candidate identity differs: $detail"; return 0; fi
  fi
  pin_policy=$(jq -r ".steps[$i].terminal_predicate.policy_digest // \"\"" "$PROGRAMME")
  if [ -n "$pin_policy" ] && [ "$(printf '%s' "$doc" | jq -r '.policy.digest // ""')" != "$pin_policy" ]; then
    refuse OWNER_EVIDENCE_POLICY_MISMATCH "record policy digest $(printf '%s' "$doc" | jq -r '.policy.digest // "absent"') is not the pinned $pin_policy"; return 0
  fi
  pin_sha=$(jq -r ".steps[$i].terminal_predicate.evidence_sha256 // \"\"" "$PROGRAMME")
  if [ -n "$pin_sha" ] && [ "$pin_sha" != "$sha" ]; then
    refuse OWNER_EVIDENCE_DIGEST_MISMATCH "record bytes sha256 $sha differ from the pinned evidence generation $pin_sha"; return 0
  fi
  pin_gen=$(jq -r ".steps[$i].terminal_predicate.evidence_generation // \"\"" "$PROGRAMME")
  if [ -n "$pin_gen" ] && [ "$(printf '%s' "$doc" | jq -r '.generation // ""')" != "$pin_gen" ]; then
    refuse OWNER_EVIDENCE_GENERATION_MISMATCH "record generation $(printf '%s' "$doc" | jq -r '.generation // "absent"') is not the pinned $pin_gen"; return 0
  fi
  if [ -n "$(printf '%s' "$doc" | jq -r '.superseded_by // ""')" ]; then
    refuse OWNER_EVIDENCE_SUPERSEDED "record is superseded by $(printf '%s' "$doc" | jq -r '.superseded_by')"; return 0
  fi
  if [ "$(printf '%s' "$doc" | jq -r '(.observed_bad // []) | length')" != 0 ]; then
    refuse OWNER_EVIDENCE_CONTRADICTORY "record carries observed_bad: $(printf '%s' "$doc" | jq -c '.observed_bad')"; return 0
  fi
  sources=$(printf '%s' "$doc" | jq -c '.sources // []')
  [ "$(printf '%s' "$sources" | jq -r 'type')" = array ] || { refuse OWNER_EVIDENCE_MALFORMED "sources must be an array"; return 0; }
  n=$(printf '%s' "$sources" | jq 'length'); j=0
  while [ "$j" -lt "$n" ]; do
    src=$(printf '%s' "$sources" | jq -c ".[$j]"); j=$((j + 1))
    [ "$(printf '%s' "$src" | jq -r '.kind // ""')" = local_file ] || { refuse OWNER_EVIDENCE_MALFORMED "source kind $(printf '%s' "$src" | jq -r '.kind // "absent"') is not local_file"; return 0; }
    spath=$(printf '%s' "$src" | jq -r '.path // ""'); ssha=$(printf '%s' "$src" | jq -r '.sha256 // ""'); sout=$(printf '%s' "$src" | jq -r '.outcome // ""')
    { [ -n "$spath" ] && [ -n "$ssha" ]; } || { refuse OWNER_EVIDENCE_MALFORMED "every bound source needs path and sha256"; return 0; }
    case "$spath" in
      /*) sfile=$spath ;;
      *) sfile="$ROOT/$spath" ;;
    esac
    if [ ! -f "$sfile" ]; then
      emit CNO OWNER_EVIDENCE_SOURCE_UNREADABLE "bound source $spath is not readable under root $ROOT" "$doc" "$sha" "$outcome"; return 0
    fi
    fsha=$(sha256_file "$sfile")
    [ "$fsha" = "$ssha" ] || { refuse OWNER_EVIDENCE_SOURCE_DIGEST_MISMATCH "bound source $spath sha256 $fsha differs from the recorded $ssha"; return 0; }
    if [ -n "$sout" ]; then
      fout=$(jq -r 'if (.outcome | type) == "string" then .outcome else "" end' "$sfile" 2>/dev/null) || fout=''
      [ -n "$fout" ] || { emit CNO OWNER_EVIDENCE_SOURCE_UNREADABLE "bound source $spath carries no readable outcome" "$doc" "$sha" "$outcome"; return 0; }
      [ "$fout" = "$sout" ] || { refuse OWNER_EVIDENCE_SOURCE_OUTCOME_MISMATCH "bound source $spath records outcome $fout, not the declared $sout"; return 0; }
    fi
  done
  accept=$(jq -c ".steps[$i].terminal_predicate.accept // []" "$PROGRAMME")
  if [ "$(jq -n --argjson a "$accept" --arg o "$outcome" '($a | index($o)) != null')" = true ]; then status=ACCEPTED; else status=NOT_ACCEPTED; fi
  emit "$status" '' '' "$doc" "$sha" "$outcome"
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
# with binding fields empty when the task has no typed binding line. A kind
# that can never gate (load, parked, unknown) is emitted from the listing alone
# without a show, since its binding cannot change its effect. Returns 1
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
    if ! fm_continuation_hold_kind_gates "$kind"; then
      row=$(jq -n --arg task "$id" --arg kind "$kind" \
        '{task:$task, hold_kind:$kind, hold_until:"", action:"", programme:"", axis:"", wait:""}')
      rows=$(jq -n --argjson a "$rows" --argjson r "$row" '$a + [$r]')
      continue
    fi
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

# The durable task a typed step fact's captain call lives on: its decision_key
# when that is a slug, else programme-action-axis.
fact_task_id() {  # <decision-key> <programme-id> <action> <axis>
  if fm_continuation_is_slug "$1"; then printf '%s' "$1"
  else printf '%s-%s-%s' "$2" "$3" "$4" | tr '_' '-'; fi
}

# Whether the captain has already answered a step fact for THIS action on its
# task: closed with a recorded answer, or open, newest-recorded as released,
# and not under a live captain hold (a later external or parked hold gates
# through the hold path and leaves the answer standing), and bound by its own
# Continuation-binding to this action and this programme (or none). Prints
# the recorded mode and returns 0 when answered. Returns 1 otherwise, printing
# the reason when a record exists but is bound elsewhere or unbound; a missing
# task, a live captain hold, or a closure without a record prints nothing.
fact_answered() {  # <task-id> <action> <programme-id>
  local show state kind body mode binding action programme
  show=$(tasks_axi show "$1" --full 2>/dev/null) || return 1
  state=$(show_field "$show" state)
  kind=$(shown_value "$show" hold_kind)
  body=$(shown_value "$show" body)
  fm_continuation_answer_recorded "$body" || return 1
  mode=$(fm_continuation_answer_mode "$body") || mode=''
  if [ "$state" = "done" ]; then mode=${mode:-answered}
  elif [ "$kind" != captain ] && [ "$mode" = released ]; then :
  else return 1; fi
  binding=$(fm_continuation_binding_from_body "$body")
  action=$(fm_continuation_binding_field "$binding" action)
  programme=$(fm_continuation_binding_field "$binding" programme)
  if [ -z "$action" ]; then printf 'ANSWER_UNBOUND'; return 1; fi
  if [ "$action" != "$2" ]; then printf 'ANSWER_OTHER_ACTION'; return 1; fi
  if [ -n "$programme" ] && [ "$programme" != "$3" ]; then printf 'ANSWER_OTHER_PROGRAMME'; return 1; fi
  printf '%s' "$mode"
}

# --- resolution ---------------------------------------------------------------

RESULT=''
RUNTIME_JSON='null'

resolve_json() {
  local today prog_sha prog_id prog_gen grant_kind grant_refs grant_superseded grant_gen
  local cno_reason='' cno_detail='' completed='[]' next_id='' next_title='' next_index=-1
  local steps_n i sid title root pred_line pred_attempt pred_outcome pred_path pred_sha accept good
  local cur_attempt=0 cur_outcome='' cur_path='' cur_sha=''
  local reserved candidates='[]' holds_json='' holds_ok=0 gating='[]' ignored='[]' hold_count=0
  local n row kind until action programme axis wait active is_reserved effect eff_cls eff_reason
  local facts fact fact_axis fact_key fact_effect fact_task answered retired='[]' unanswered='[]' claimed default_pair def_cls def_reason
  local winner cls authority reason_code detail_text materialize='[]' pred_json current_json applicability digest why basis
  local kind evidence_json=null ev_status

  today=${FM_CONTINUATION_TODAY:-$(date -u +%Y-%m-%d)}
  prog_sha=$(sha256_file "$PROGRAMME")
  RUNTIME_JSON=$(jq -n -c --arg path "$SCRIPT_DIR/fm-continuation-resolve.sh" --arg sha "$(sha256_file "$SCRIPT_DIR/fm-continuation-resolve.sh")" \
    --arg lib "$(sha256_file "$SCRIPT_DIR/fm-continuation-lib.sh")" --arg kinds "$FM_CONTINUATION_EVIDENCE_KINDS" --arg owners "$FM_CONTINUATION_OWNER_KINDS" \
    '{resolver:$path, resolver_sha256:$sha, lib_sha256:$lib, supported_evidence_kinds:($kinds | split(" ")), supported_owner_kinds:($owners | split(" "))}')
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
    kind=$(jq -r ".steps[$i].terminal_predicate.kind // \"\"" "$PROGRAMME")
    if [ "$kind" = "$OWNER_KIND" ]; then
      # The closed owner-evidence adapter: an ACCEPTED record completes the
      # step; anything else makes it the next action, with CNO for a missing,
      # unreadable, or refused record and the ordinary law for a well-formed
      # record whose outcome is simply not accepted.
      evidence_json=$(read_owner_evidence "$i" "$sid")
      ev_status=$(printf '%s' "$evidence_json" | jq -r '.status')
      if [ "$ev_status" = ACCEPTED ]; then
        completed=$(jq -n --argjson c "$completed" --arg id "$sid" --argjson ev "$evidence_json" \
          '$c + [{id:$id, attempt:null, outcome:$ev.outcome, disposition:$ev.path, sha256:$ev.sha256, evidence_kind:"accepted_owner_evidence", evidence_id:$ev.evidence_id, owner:$ev.owner}]')
        evidence_json=null
        i=$((i + 1))
        continue
      fi
      next_id=$sid; next_title=$title; next_index=$i
      cur_attempt=0; cur_outcome=$(printf '%s' "$evidence_json" | jq -r '.outcome // ""'); cur_path=$(printf '%s' "$evidence_json" | jq -r '.path'); cur_sha=$(printf '%s' "$evidence_json" | jq -r '.sha256 // ""')
      if [ "$ev_status" != NOT_ACCEPTED ] && [ -z "$cno_reason" ]; then
        cno_reason=$(printf '%s' "$evidence_json" | jq -r '.reason_code'); cno_detail=$(printf '%s' "$evidence_json" | jq -r '.detail')
      fi
      break
    fi
    if pred_line=$(latest_disposition "$root"); then
      pred_attempt=$(printf '%s' "$pred_line" | cut -f1)
      pred_outcome=$(printf '%s' "$pred_line" | cut -f2)
      pred_path=$(printf '%s' "$pred_line" | cut -f3)
      pred_sha=$(printf '%s' "$pred_line" | cut -f4)
    else
      # The newest attempt has no readable disposition: this step is the next
      # action and its state could not be observed.
      pred_path=$(printf '%s' "$pred_line" | cut -f3)
      next_id=$sid; next_title=$title; next_index=$i
      cur_attempt=$(printf '%s' "$pred_line" | cut -f1); cur_outcome=''; cur_path=$pred_path; cur_sha=''
      if [ -z "$cno_reason" ]; then
        if [ -f "$pred_path" ]; then cno_reason=PREDECESSOR_DISPOSITION_UNREADABLE
        else cno_reason=NEWER_ATTEMPT_WITHOUT_DISPOSITION; fi
        cno_detail=$pred_path
      fi
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
      --arg path "$PROGRAMME" --arg root "$ROOT" --arg sha "$prog_sha" --argjson completed "$completed" \
      --argjson refs "$grant_refs" --arg today "$today" \
      --arg why "$(fm_continuation_render_reason PROGRAMME_COMPLETE '' '' '')" '
      {schema:$schema,
       programme:{id:$pid, generation:$gen, path:$path, root:$root, sha256:$sha},
       next_action:null, next_action_title:null, action_generation:null,
       classification:"SELF_HANDLE", authority_state:"AUTHORIZED", reason_code:"PROGRAMME_COMPLETE",
       basis_refs:([$refs[] | {kind:"programme_grant", ref:.}] + [$completed[] | {kind:"terminal_disposition"} + .]),
       applicability:{action:null, programme_id:$pid, programme_generation:$gen, action_generation:null,
                      predecessor:($completed | last), current:null, gating_holds:[], today:$today},
       completed:$completed, holds:{considered:0, gating:[], ignored:[]}, cno:null,
       materialize:[], evidence:null, why:$why}
      | .applicability_digest = (.applicability | tojson)')
    RESULT=$(printf '%s' "$RESULT" | jq --arg d "$(sha256_text "$(printf '%s' "$RESULT" | jq -r '.applicability_digest')")" '.applicability_digest = $d')
    finish_result
    return 0
  fi

  # Durable holds bound to THIS action.
  if holds_json=$(hold_rows_json); then
    holds_ok=1
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
      if ! fm_continuation_hold_kind_gates "$kind"; then
        effect=$(fm_continuation_hold_effect "$kind" 0 '' 1); eff_reason=${effect#* }
        ignored=$(jq -n --argjson a "$ignored" --argjson r "$row" --arg reason "$eff_reason" '$a + [{task:$r.task, reason:$reason}]'); continue
      fi
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
  # with no pre-existing hold; a declared non-reserved axis is a refused claim;
  # a reserved axis whose decision task already records the captain's answer
  # is retired. A fact is identified only by its own task: when that task
  # carries a gating captain hold the fact is covered by it and needs nothing
  # more; a foreign hold that merely shares the axis gates on its own and
  # never stands in for the fact.
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
      fact_task=$(fact_task_id "$fact_key" "$prog_id" "$next_id" "$fact_axis")
      answered=''
      if [ "$(printf '%s' "$gating" | jq --arg t "$fact_task" '[.[] | select(.task == $t and .classification == "CAPTAIN")] | length')" != 0 ]; then
        continue
      fi
      if [ "$holds_ok" = 1 ]; then
        if answered=$(fact_answered "$fact_task" "$next_id" "$prog_id"); then
          retired=$(jq -n --argjson r "$retired" --arg axis "$fact_axis" --arg key "$fact_key" --arg task "$fact_task" --arg mode "$answered" \
            '$r + [{axis:$axis, decision_key:$key, task:$task, mode:$mode}]')
          continue
        elif [ -n "$answered" ]; then
          unanswered=$(jq -n --argjson u "$unanswered" --arg axis "$fact_axis" --arg key "$fact_key" --arg task "$fact_task" --arg reason "$answered" \
            '$u + [{axis:$axis, decision_key:$key, task:$task, reason:$reason}]')
        fi
      fi
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
  # Only a CAPTAIN result materializes, and only the facts whose own task
  # carries no gating captain hold yet; a foreign hold never covers a fact.
  [ "$cls" = CAPTAIN ] || materialize='[]'

  pred_json=$(printf '%s' "$completed" | jq -c 'last')
  current_json=$(jq -n --argjson attempt "${cur_attempt:-0}" --arg outcome "$cur_outcome" --arg path "$cur_path" --arg sha "$cur_sha" \
    'if $attempt == 0 then null else {attempt:$attempt, outcome:(if $outcome == "" then null else $outcome end), disposition:(if $path == "" then null else $path end), sha256:(if $sha == "" then null else $sha end)} end')
  applicability=$(jq -n -c --arg action "$next_id" --arg pid "$prog_id" --arg gen "$prog_gen" \
    --argjson action_generation "$((cur_attempt + 1))" --argjson pred "$pred_json" --argjson current "$current_json" \
    --argjson gating "$gating" --argjson retired "$retired" --arg today "$today" --arg psha "$prog_sha" \
    --argjson evidence "$evidence_json" \
    '{action:$action, programme_id:$pid, programme_generation:$gen, programme_sha256:$psha, action_generation:$action_generation,
      predecessor:$pred, current:$current,
      evidence:(if $evidence == null then null else {path:$evidence.path, sha256:$evidence.sha256, status:$evidence.status, outcome:$evidence.outcome, reason_code:$evidence.reason_code} end),
      gating_holds:[$gating[] | .task], answered_facts:[$retired[] | .task], today:$today}')
  digest=$(sha256_text "$applicability")
  why=$(fm_continuation_render_reason "$reason_code" "$next_id" \
    "$(printf '%s' "$pred_json" | jq -r 'if . == null then "" elif .attempt == null then .id + " " + .outcome + " by " + (.owner.kind // "owner") + " " + (.owner.ref // "") else .id + " attempt " + (.attempt | tostring) + " " + .outcome end')" \
    "$detail_text")
  basis=$(jq -n -c --argjson refs "$grant_refs" --argjson pred "$pred_json" --argjson gating "$gating" --argjson winner "$winner" \
    --argjson facts "$facts" --argjson retired "$retired" --argjson unanswered "$unanswered" --arg reserved "$(printf '%s' "$reserved" | tr '\n' ' ')" '
    [$refs[] | {kind:"programme_grant", ref:.}]
    + (if $pred == null then [] else [{kind:"predecessor_disposition"} + $pred] end)
    + [$gating[] | {kind:"hold", task, hold_kind, axis, wait, classification, reason_code}]
    + [$facts[] | select(.axis != null) | .axis as $ax | (.decision_key // "") as $key
       | ([$retired[] | select(.axis == $ax and .decision_key == $key)] | first) as $a
       | ([$unanswered[] | select(.axis == $ax and .decision_key == $key)] | first) as $u
       | {kind:"step_fact", axis:$ax, decision_key:(if $key == "" then null else $key end), reserved:((($reserved | split(" ")) | index($ax)) != null)}
         + (if $a != null then {answered:true, answered_task:$a.task, answered_mode:$a.mode}
            elif $u != null then {answered:false, answer_ignored:{task:$u.task, reason:$u.reason}}
            else {answered:false} end)]')

  RESULT=$(jq -n --arg schema "$RESOLUTION_SCHEMA" --arg pid "$prog_id" --arg gen "$prog_gen" --arg path "$PROGRAMME" --arg root "$ROOT" --arg sha "$prog_sha" \
    --arg next "$next_id" --arg title "$next_title" --argjson action_generation "$((cur_attempt + 1))" \
    --arg cls "$cls" --arg authority "$authority" --arg reason "$reason_code" \
    --argjson basis "$basis" --argjson applicability "$applicability" --arg digest "$digest" \
    --argjson completed "$completed" --argjson considered "${hold_count:-0}" --argjson gating "$gating" --argjson ignored "$ignored" \
    --arg cno_reason "$cno_reason" --arg cno_detail "$cno_detail" --argjson materialize "$materialize" --argjson evidence "$evidence_json" --arg why "$why" '
    {schema:$schema,
     programme:{id:$pid, generation:$gen, path:$path, root:$root, sha256:$sha},
     next_action:$next, next_action_title:(if $title == "" then null else $title end), action_generation:$action_generation,
     classification:$cls, authority_state:$authority, reason_code:$reason,
     basis_refs:$basis, applicability:$applicability, applicability_digest:$digest,
     completed:$completed,
     holds:{considered:$considered, gating:$gating, ignored:$ignored},
     cno:(if $cno_reason == "" then null else {reason_code:$cno_reason, detail:$cno_detail} end),
     materialize:$materialize, evidence:$evidence, why:$why}')
  finish_result
}

# The fields every result carries beyond the typed authority: the verified
# binding, this resolver's runtime identity, the accountable owner, and the
# clock-free material identity a presentation caller keys on.
finish_result() {
  local owner material
  owner=$(fm_continuation_accountable_owner "$(printf '%s' "$RESULT" | jq -r '.classification')" \
    "$(printf '%s' "$RESULT" | jq -r '.authority_state')" "$(printf '%s' "$RESULT" | jq -r '.reason_code')")
  RESULT=$(printf '%s' "$RESULT" | jq --argjson binding "$BINDING_JSON" --argjson runtime "$RUNTIME_JSON" --arg owner "$owner" \
    '. + {binding:$binding, runtime:$runtime, accountable_owner:$owner}')
  material=$(printf '%s' "$RESULT" | jq -c -S '
    {programme_id:.programme.id, programme_generation:.programme.generation, programme_sha256:.programme.sha256,
     binding:{work_id:(.binding.commission.work_id // null), work_generation:(.binding.commission.work_generation // null),
              grant_id:(.binding.grant.id // null), ruling_id:(.binding.ruling.id // null), present:.binding.present},
     next_action, action_generation, classification, authority_state, reason_code, cno, accountable_owner,
     predecessor:(.applicability.predecessor | if . == null then null else {id, attempt, outcome, sha256} end),
     current:(.applicability.current | if . == null then null else {attempt, outcome, sha256} end),
     evidence:(.evidence | if . == null then null else {sha256, status, outcome, reason_code} end),
     gating_holds:[.holds.gating[]? | {task, hold_kind, hold_until, axis, wait, classification, reason_code}],
     answered_facts:(.applicability.answered_facts // []),
     materialize:[.materialize[]? | .axis],
     completed:[.completed[]? | {id, attempt, outcome, sha256}]}')
  RESULT=$(printf '%s' "$RESULT" | jq --arg m "$(sha256_text "$material")" '. + {material_identity:$m}')
}

# Create the durable captain hold a CAPTAIN result from a typed step fact
# requires, through the captain-hold owner only. Idempotent: an existing bound
# hold is left as it is; a decision task under a live non-captain hold is
# never re-held (that hold and its binding belong to another wait), and one
# whose binding names another action or programme is never rebound (that
# call belongs to the other action or programme) - both fail loudly.
materialize_holds() {
  local n i item axis key effect task title reason created='[]' show kind action programme binding bound_action bound_programme
  action=$(printf '%s' "$RESULT" | jq -r '.next_action')
  programme=$(printf '%s' "$RESULT" | jq -r '.programme.id')
  n=$(printf '%s' "$RESULT" | jq '.materialize | length')
  [ "$n" -gt 0 ] || { RESULT=$(printf '%s' "$RESULT" | jq '.materialized = []'); return 0; }
  i=0
  while [ "$i" -lt "$n" ]; do
    item=$(printf '%s' "$RESULT" | jq -c ".materialize[$i]")
    i=$((i + 1))
    axis=$(printf '%s' "$item" | jq -r '.axis')
    key=$(printf '%s' "$item" | jq -r '.decision_key')
    effect=$(printf '%s' "$item" | jq -r '.effect')
    task=$(fact_task_id "$key" "$(printf '%s' "$RESULT" | jq -r '.programme.id')" "$(printf '%s' "$RESULT" | jq -r '.next_action')" "$axis")
    title=$(printf 'Captain decision for %s: %s' "$(printf '%s' "$RESULT" | jq -r '.next_action')" "${effect:-reserved axis $axis}" | tr '()' '[]')
    reason=$(printf 'reserved axis %s on programme step %s' "$axis" "$(printf '%s' "$RESULT" | jq -r '.next_action')")
    if show=$(tasks_axi show "$task" --full 2>/dev/null); then
      kind=$(shown_value "$show" hold_kind)
      [ -z "$kind" ] || [ "$kind" = captain ] \
        || fail "cannot materialize captain hold $task: it carries a live $kind hold that must not be replaced"
      binding=$(fm_continuation_binding_from_body "$(shown_value "$show" body)")
      bound_action=$(fm_continuation_binding_field "$binding" action)
      bound_programme=$(fm_continuation_binding_field "$binding" programme)
      if [ -n "$bound_action" ] && { [ "$bound_action" != "$action" ] || { [ -n "$bound_programme" ] && [ "$bound_programme" != "$programme" ]; }; }; then
        fail "cannot materialize captain hold $task: it is bound to action $bound_action programme ${bound_programme:-any} and must not be rebound to action $action programme $programme"
      fi
    fi
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
    end
    + " binding=" + (if .binding.present then "grant:" + (.binding.grant.id | tostring) + "@" + (.binding.commission.work_generation // 0 | tostring) else "REQUIRED_BINDING_MISSING" end)
    + " identity=" + .material_identity[0:12]'
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
      elif (.kind == "predecessor_disposition" or .kind == "terminal_disposition") and .attempt == null then "owner evidence " + .id + " " + .outcome + " by " + (.owner.kind // "?") + " " + (.owner.ref // "?") + " (" + .sha256[0:12] + ")"
      elif .kind == "predecessor_disposition" or .kind == "terminal_disposition" then "disposition " + .id + " attempt " + (.attempt | tostring) + " " + .outcome + " (" + .sha256[0:12] + ")"
      elif .kind == "hold" then "hold " + .task + " (" + .hold_kind + (if .axis != "" then ", axis " + .axis else "" end) + (if .wait != "" then ", wait " + .wait else "" end) + ") -> " + .classification
      elif .kind == "step_fact" then "step fact axis " + .axis + (if .reserved then " (reserved)" else " (not reserved)" end)
        + (if .answered then ", answered by " + .answered_task + " (" + .answered_mode + ")"
           elif .answer_ignored then ", answer on " + .answer_ignored.task + " ignored (" + .answer_ignored.reason + ")"
           else "" end)
      else tojson end)),
    (if .evidence != null then "Evidence for " + .next_action + ": " + .evidence.status
        + (if .evidence.outcome then " outcome " + .evidence.outcome else "" end)
        + (if .evidence.owner then " by " + .evidence.owner.kind + " " + .evidence.owner.ref else "" end)
        + (if .evidence.reason_code then " [" + .evidence.reason_code + "] " + (.evidence.detail // "") else "" end)
        + " (" + ((.evidence.sha256 // "absent")[0:12]) + ")." else empty end),
    (if (.materialize | length) > 0 then "Durable captain hold required: run fm-continuation-resolve.sh resolve --materialize." else empty end),
    "Accountable owner: " + .accountable_owner + ".",
    (if .binding.present then "Binding: commission " + .binding.commission.work_id + "@" + ((.binding.commission.work_generation // 0) | tostring)
        + " under grant " + (.binding.grant.id | tostring) + " (" + .binding.grant.ref + ")"
        + (if .binding.ruling then ", ruling " + (.binding.ruling.id | tostring) else "" end)
        + "; consumer contract " + .binding.consumer.contract + "; evidence kinds " + (.binding.evidence_kinds | join(", ")) + "."
     else "Binding: REQUIRED_BINDING_MISSING - " + .binding.detail + "." end),
    "Applicability " + .applicability_digest[0:12] + ": action " + (.applicability.action // "none") + ", generation " + ((.applicability.action_generation // "-") | tostring) + ", programme " + .applicability.programme_generation + ".",
    "Material identity " + .material_identity + " (clock-free; a presentation caller keys quiet handling on it)."'
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
