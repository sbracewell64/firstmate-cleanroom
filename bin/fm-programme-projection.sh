#!/usr/bin/env bash
# fm-programme-projection.sh - the stateless programme PROJECTION substrate: one
# typed tuple, recomputed from canonical records on every call, that a manager
# loop reads to learn what the pinned programme's next action is, under whose
# authority, whether an earlier reading still applies, and which delegation
# bounds the next phase may use.
#
# It holds NO durable state, writes NOTHING, and carries ZERO protected-effect
# authority: it never merges, spawns, holds, transitions, picks a model or an
# effort, or enforces a bound. It is not a workflow database, scheduler,
# authority store, acceptance owner, merge authority, graph, memory, or second
# orchestrator. A renderer may turn reason_code + basis_refs + applicability
# into prose but may not override the typed result, and no path may re-derive
# these fields from prose.
#
# COMPOSITION, NOT RE-DERIVATION. Every field below is read from an existing
# canonical owner and passed through, or assembled from canonical records this
# script only reads:
#   - bin/fm-continuation-resolve.sh (+ bin/fm-continuation-lib.sh) owns
#     next_action, action_generation, classification, authority_state,
#     reason_code, and basis_refs. Its `resolve` output is consumed verbatim;
#     the classification tables and hold-effect law are never reimplemented
#     here, and `--materialize` is refused because this layer has no authority
#     to create a hold. Its exit 3 (no programme configured) is "not
#     applicable" and is mirrored as exit 3 with nothing on stdout.
#   - bin/fm-captain-hold.sh owns hold durability and effect; the resolver
#     already consumed them, so this script reads only the resolver's gating
#     hold rows and answered-fact identities.
#   - Qualification and landing state stay with no-mistakes and the exact-head
#     merge owners; the task's state/<id>.meta `pr_head=` (bin/fm-pr-check.sh)
#     and its worktree's git head are READ for identity, never judged.
#   - Dispatch profiles (config/crew-dispatch.json) and quota own model and
#     effort; this script reports only whether profiles are configured.
# The resolver stays narrow: nothing here promotes it into phase, delegation,
# concurrency, or plan-drift ownership. Those are this layer's own, separately
# qualified additions, assembled from the records named below.
#
# Usage:
#   fm-programme-projection.sh project [--programme <file>] [--root <dir>]
#   fm-programme-projection.sh summary [--programme <file>] [--root <dir>]
#
# --programme and --root are handed to the resolver unchanged; programme
# location precedence is the resolver's (docs/configuration.md "Programme
# continuation"), and the file and artifact root this run used are read back
# from its result's `programme.path` / `programme.root`, never re-located.
#
# Exit codes: 0 projected; 3 no programme is configured (silent, mirrors the
# resolver); 2 usage; 1 any other error, including malformed delegation
# configuration, which is refused rather than selected around.
#
# CANONICAL INPUTS, read only:
#   1. The resolver's typed result (schema fm-continuation-resolution/v1).
#   2. The pinned programme file (JSON), for the OPTIONAL fields this layer
#      owns; the resolver ignores them and its own schema is unchanged:
#        steps[].phase                 slug naming the phase the step belongs
#                                      to; default: the step's own id
#        steps[].task_id               slug of the durable task whose
#                                      state/<task_id>.meta carries the
#                                      worker epoch and candidate for this
#                                      step; default: the step's own id
#        delegation.max_concurrency    programme-level concurrency ceiling
#        steps[].delegation.max_concurrency
#                                      per-step override
#      A ceiling must be one measured ladder rung (2, 3, 4, 6; hard max 6);
#      absent means the ladder floor (2). Any other value, or a `delegation`
#      that is not an object, is refused (exit 1). This script never ramps.
#   3. Proof attempt directories <root>/<artifact_root>/attempt-<n> of every
#      step in the next action's phase, COUNTED only (their dispositions are
#      the resolver's to read).
#   4. state/<task_id>.meta (FM_STATE_OVERRIDE, else $FM_HOME/state): the
#      `spawn_gen=` worker epoch bin/fm-spawn.sh records, the `pr_head=`
#      bin/fm-pr-check.sh records, and the `worktree=` whose git HEAD commit
#      and tree are read with `git rev-parse`. Absent meta or fields are null.
#
# RESULT (schema fm-programme-projection/v1), one JSON object:
#   programme                {id, generation, path, root, sha256} from the resolver
#   next_action, next_action_title, action_generation
#                            verbatim from the resolver (null when complete)
#   phase                    the next action's phase id (null when complete)
#   phase_generation         attempt directories counted across the phase's steps
#   work_generation          the bound task's spawn_gen worker epoch, or null
#   classification, authority_state, reason_code, basis_refs[]
#                            verbatim from the resolver
#   applicability            {programme_id, programme_generation, programme_sha256,
#                             phase_id, phase_generation, action, action_generation,
#                             work_generation, candidate_identity{task, spawn_gen,
#                             pr_head, worktree, head, tree}, predecessor_disposition,
#                             hold_grant_generation, resolver_applicability_digest}
#                            The exact tuple this projection is bound to. It is
#                            usable ONLY while every member still holds: a moved
#                            head or tree, a new attempt, a new worker epoch, or a
#                            superseded, lifted, or newly gating hold or grant
#                            yields a different tuple, so a stale projection is
#                            structurally unusable rather than merely old.
#   applicability_digest     sha256 of the canonical (key-sorted) applicability JSON
#   delegation               {phase, phase_steps[], concurrency{ceiling, ladder[],
#                             hard_max, source, hidden_fanout_counts_under_ceiling,
#                             ramps}, dispatch_profiles_configured, picks_model_or_effort,
#                             model_effort_owner, enforces, enforcer}
#                            Bounds RETURNED for the next phase; bin/fm-spawn.sh
#                            is the enforcer, and hidden fan-out counts under the
#                            ceiling.
#   resolver                 {schema, applicability_digest, cno, holds{considered,
#                             gating}} for traceability back to the owner
#   hold_grant_generation is the sha256 of the canonical JSON of the grant
#   (kind, refs, programme_generation, superseded_by) plus the resolver's
#   gating hold rows and answered-fact identities: superseded and lifted
#   markers live on those canonical records, never in a second store, and a
#   record carrying one is already non-authoritative in the resolver's rows.
#
# `summary` prints the one-line token a digest can embed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RESOLVER="$SCRIPT_DIR/fm-continuation-resolve.sh"

PROJECTION_SCHEMA='fm-programme-projection/v1'
# The measured concurrency ladder and its hard maximum. This script reports a
# rung; it never ramps between rungs.
CONCURRENCY_LADDER='2 3 4 6'
CONCURRENCY_HARD_MAX=6
CONCURRENCY_FLOOR=2

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-programme-projection: %s\n' "$*" >&2
  exit 1
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

is_slug() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- arguments ----------------------------------------------------------------

RESOLVER_ARGS=()
parse_common() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --programme|--root)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        RESOLVER_ARGS+=("$1" "$2"); shift ;;
      --materialize)
        printf 'fm-programme-projection: --materialize is refused; this layer has no authority to create a hold (use fm-continuation-resolve.sh resolve --materialize)\n' >&2
        exit 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
}

# --- the resolver's typed result -----------------------------------------------

RESOLUTION=''
read_resolution() {
  local out rc=0
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -x "$RESOLVER" ] || fail "resolver not found: $RESOLVER"
  out=$("$RESOLVER" resolve ${RESOLVER_ARGS[@]+"${RESOLVER_ARGS[@]}"} 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    3) printf '%s\n' "$out" >&2; exit 3 ;;
    *) fail "resolver failed (exit $rc): $out" ;;
  esac
  printf '%s' "$out" | jq -e '.schema == "fm-continuation-resolution/v1"' >/dev/null 2>&1 \
    || fail "resolver printed an unrecognized result schema"
  RESOLUTION=$(printf '%s' "$out" | jq -c '.')
}

rfield() {  # <jq-path>
  printf '%s' "$RESOLUTION" | jq -r "$1"
}

# --- programme-file fields this layer owns --------------------------------------

PROGRAMME=''
ROOT=''
NEXT_ID=''
NEXT_INDEX=-1
PHASE_ID=''
TASK_ID=''

read_programme_fields() {
  PROGRAMME=$(rfield '.programme.path')
  ROOT=$(rfield '.programme.root // ""')
  [ -f "$PROGRAMME" ] || fail "programme file the resolver used does not exist: $PROGRAMME"
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || fail "programme root the resolver used does not exist: $ROOT"
  NEXT_ID=$(rfield '.next_action // ""')
  [ -n "$NEXT_ID" ] || return 0
  NEXT_INDEX=$(jq --arg id "$NEXT_ID" '[.steps[] | .id] | index($id) // -1' "$PROGRAMME")
  [ "$NEXT_INDEX" -ge 0 ] || fail "next action $NEXT_ID is not a step of $PROGRAMME"
  PHASE_ID=$(jq -r ".steps[$NEXT_INDEX].phase // \"\"" "$PROGRAMME")
  if [ -n "$PHASE_ID" ]; then
    is_slug "$PHASE_ID" || fail "steps[$NEXT_INDEX].phase must be a slug: $PHASE_ID"
  else
    PHASE_ID=$NEXT_ID
  fi
  TASK_ID=$(jq -r ".steps[$NEXT_INDEX].task_id // \"\"" "$PROGRAMME")
  if [ -n "$TASK_ID" ]; then
    is_slug "$TASK_ID" || fail "steps[$NEXT_INDEX].task_id must be a slug: $TASK_ID"
  else
    TASK_ID=$NEXT_ID
  fi
}

# Steps sharing the next action's phase (a step with no phase field is its own
# phase), as a JSON array of ids.
phase_steps_json() {
  [ -n "$NEXT_ID" ] || { printf '[]'; return 0; }
  jq -c --arg phase "$PHASE_ID" '[.steps[] | select(type == "object") | select((.phase // .id) == $phase) | .id]' "$PROGRAMME"
}

# Attempt directories counted across the phase's artifact roots. Only the
# count is this layer's; dispositions are the resolver's to read.
phase_generation() {
  local ids id root dir d n total=0
  ids=$(phase_steps_json | jq -r '.[]')
  for id in $ids; do
    root=$(jq -r --arg id "$id" '.steps[] | select(.id == $id) | .artifact_root // ""' "$PROGRAMME")
    [ -n "$root" ] || continue
    case "$root" in
      /*) dir=$root ;;
      *) dir="$ROOT/$root" ;;
    esac
    [ -d "$dir" ] || continue
    for d in "$dir"/attempt-*; do
      [ -d "$d" ] || continue
      n=${d##*/attempt-}
      case "$n" in
        ''|*[!0-9]*) continue ;;
      esac
      total=$((total + 1))
    done
  done
  printf '%s' "$total"
}

# --- delegation bounds ---------------------------------------------------------

ladder_json() {
  printf '%s' "$CONCURRENCY_LADDER" | tr ' ' '\n' | jq -c -s '.'
}

is_rung() {  # <value>
  case " $CONCURRENCY_LADDER " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# A configured ceiling at <jq-path>: prints the rung, "" when absent, and
# fails on anything that is not a ladder rung.
configured_ceiling() {  # <jq-path-to-delegation> <label>
  local kind value
  kind=$(jq -r "$1 | type" "$PROGRAMME")
  case "$kind" in
    null) printf ''; return 0 ;;
    object) ;;
    *) fail "$2 delegation must be an object in $PROGRAMME (got $kind)" ;;
  esac
  value=$(jq -r "$1.max_concurrency | if . == null then \"\" elif (type == \"number\" and . == floor) then tostring else \"INVALID:\" + tojson end" "$PROGRAMME")
  [ -n "$value" ] || { printf ''; return 0; }
  case "$value" in
    INVALID:*) fail "$2 delegation.max_concurrency must be a ladder rung ($CONCURRENCY_LADDER; hard max $CONCURRENCY_HARD_MAX) in $PROGRAMME, got ${value#INVALID:}" ;;
  esac
  is_rung "$value" || fail "$2 delegation.max_concurrency must be a ladder rung ($CONCURRENCY_LADDER; hard max $CONCURRENCY_HARD_MAX) in $PROGRAMME, got $value"
  printf '%s' "$value"
}

delegation_json() {
  local ceiling source step_ceiling='' prog_ceiling profiles=false
  # Explicit status checks: this function runs inside a command substitution,
  # where bash does not inherit errexit, so a refused ceiling must be
  # propagated by hand rather than trusted to set -e.
  prog_ceiling=$(configured_ceiling '.delegation' 'programme') || exit 1
  if [ "$NEXT_INDEX" -ge 0 ]; then
    step_ceiling=$(configured_ceiling ".steps[$NEXT_INDEX].delegation" "steps[$NEXT_INDEX]") || exit 1
  fi
  if [ -n "$step_ceiling" ]; then
    ceiling=$step_ceiling; source="programme:steps[$NEXT_INDEX].delegation.max_concurrency"
  elif [ -n "$prog_ceiling" ]; then
    ceiling=$prog_ceiling; source='programme:delegation.max_concurrency'
  else
    ceiling=$CONCURRENCY_FLOOR; source='ladder_floor'
  fi
  [ -f "$CONFIG/crew-dispatch.json" ] && profiles=true
  jq -n -c --arg phase "$PHASE_ID" --argjson steps "$(phase_steps_json)" \
    --argjson ceiling "$ceiling" --argjson ladder "$(ladder_json)" --argjson hard_max "$CONCURRENCY_HARD_MAX" \
    --arg source "$source" --argjson profiles "$profiles" '
    {phase:(if $phase == "" then null else $phase end),
     phase_steps:$steps,
     concurrency:{ceiling:$ceiling, ladder:$ladder, hard_max:$hard_max, source:$source,
                  hidden_fanout_counts_under_ceiling:true, ramps:false},
     dispatch_profiles_configured:$profiles,
     picks_model_or_effort:false,
     model_effort_owner:"config/crew-dispatch.json + quota-axi (AGENTS.md section 4)",
     enforces:false,
     enforcer:"bin/fm-spawn.sh"}'
}

# --- worker epoch and candidate identity ------------------------------------------

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

candidate_json() {
  local meta spawn_gen='' pr_head='' worktree='' head='' tree='' revs
  [ -n "$NEXT_ID" ] || { printf 'null'; return 0; }
  meta="$STATE/$TASK_ID.meta"
  if [ -f "$meta" ]; then
    spawn_gen=$(meta_value "$meta" spawn_gen)
    pr_head=$(meta_value "$meta" pr_head)
    worktree=$(meta_value "$meta" worktree)
    if [ -n "$worktree" ] && [ -d "$worktree" ] \
      && revs=$(git -C "$worktree" rev-parse HEAD 'HEAD^{tree}' 2>/dev/null); then
      head=$(printf '%s\n' "$revs" | sed -n 1p)
      tree=$(printf '%s\n' "$revs" | sed -n 2p)
      case "$head:$tree" in
        *[!0-9a-f:]*) head=''; tree='' ;;
      esac
    fi
  fi
  jq -n -c --arg task "$TASK_ID" --arg spawn_gen "$spawn_gen" --arg pr_head "$pr_head" \
    --arg worktree "$worktree" --arg head "$head" --arg tree "$tree" '
    def nz: if . == "" then null else . end;
    {task:$task, spawn_gen:($spawn_gen | nz), pr_head:($pr_head | nz),
     worktree:($worktree | nz), head:($head | nz), tree:($tree | nz)}'
}

# --- hold/grant generation -------------------------------------------------------

hold_grant_generation() {
  local grant canonical
  grant=$(jq -c -S '{kind:(.authorization_basis.kind // null),
                     refs:[.authorization_basis.refs[]? | select(type == "string")],
                     programme_generation:(.authorization_basis.programme_generation // null),
                     superseded_by:(.authorization_basis.superseded_by // null)}' "$PROGRAMME")
  canonical=$(printf '%s' "$RESOLUTION" | jq -c -S --argjson grant "$grant" '
    {grant:$grant,
     gating:[.holds.gating[]? | {task, hold_kind, hold_until, action, programme, axis, wait, classification, reason_code}],
     answered_facts:(.applicability.answered_facts // []),
     cno:(.cno // null)}')
  sha256_text "$canonical"
}

# --- projection ------------------------------------------------------------------

PROJECTION=''
project_json() {
  local phase_gen candidate work_gen hg applicability digest delegation
  read_resolution
  read_programme_fields
  if [ -n "$NEXT_ID" ]; then
    phase_gen=$(phase_generation) || exit 1
  else
    phase_gen=null
  fi
  candidate=$(candidate_json) || exit 1
  work_gen=$(printf '%s' "$candidate" | jq -c '.spawn_gen // null') || exit 1
  hg=$(hold_grant_generation) || exit 1
  delegation=$(delegation_json) || exit 1
  applicability=$(printf '%s' "$RESOLUTION" | jq -c -S --arg phase "$PHASE_ID" --argjson phase_gen "$phase_gen" \
    --argjson work_gen "$work_gen" --argjson candidate "$candidate" --arg hg "$hg" '
    {programme_id:.programme.id, programme_generation:.programme.generation, programme_sha256:.programme.sha256,
     phase_id:(if $phase == "" then null else $phase end), phase_generation:$phase_gen,
     action:.next_action, action_generation:.action_generation,
     work_generation:$work_gen, candidate_identity:$candidate,
     predecessor_disposition:(.applicability.predecessor // null),
     hold_grant_generation:$hg,
     resolver_applicability_digest:.applicability_digest}')
  digest=$(sha256_text "$applicability")
  PROJECTION=$(printf '%s' "$RESOLUTION" | jq --arg schema "$PROJECTION_SCHEMA" --arg phase "$PHASE_ID" \
    --argjson phase_gen "$phase_gen" --argjson work_gen "$work_gen" \
    --argjson applicability "$applicability" --arg digest "$digest" --argjson delegation "$delegation" '
    {schema:$schema,
     programme:.programme,
     next_action:.next_action, next_action_title:.next_action_title,
     phase:(if $phase == "" then null else $phase end), phase_generation:$phase_gen,
     action_generation:.action_generation, work_generation:$work_gen,
     classification:.classification, authority_state:.authority_state, reason_code:.reason_code,
     basis_refs:.basis_refs,
     applicability:$applicability, applicability_digest:$digest,
     delegation:$delegation,
     resolver:{schema:.schema, applicability_digest:.applicability_digest, cno:.cno,
               holds:{considered:.holds.considered, gating:[.holds.gating[]? | .task]}}}')
}

command_project() {
  parse_common "$@"
  project_json
  printf '%s\n' "$PROJECTION" | jq '.'
}

command_summary() {
  parse_common "$@"
  project_json
  printf '%s' "$PROJECTION" | jq -r '
    "projection " + .programme.id + "@" + .programme.generation + ": "
    + (if .next_action == null then "complete (" + .reason_code + ")"
       else "next=" + .next_action + " phase=" + .phase + "@" + (.phase_generation | tostring)
            + " gen=" + (.action_generation | tostring) + "/" + ((.work_generation // "-") | tostring)
            + " " + .classification + "/" + .authority_state + " reason=" + .reason_code end)
    + " ceiling=" + (.delegation.concurrency.ceiling | tostring)
    + " applicability=" + .applicability_digest[0:12]'
}

case "${1:-}" in
  project) shift; command_project "$@" ;;
  summary) shift; command_summary "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
