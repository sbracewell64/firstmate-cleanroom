#!/usr/bin/env bash
# shellcheck disable=SC2034 # Typed-exit constants and FM_WORK_CONTEXT_* result globals are consumed by the sourcing caller (bin/fm-work-context.sh), not within this library.
# fm-work-context-lib.sh - the machine-readable work-context contract, enforced
# at the real caller BEFORE a dependent effect (one owner).
#
# WHY. Sol 5574009225 part 1 (Captain-authorized) asks for a machine-readable
# work-context per admitted task so a dependent effect - a dispatch, a landing,
# a material-Sol engineering change - cannot proceed on stale source identity,
# a missing reference, a superseded preference, or unruled authority. The
# task-selection producer slice (fm-fleet-snapshot's eligible_queued, PR #19)
# exposes per-task readiness as OBSERVABILITY only; this library is the CALLER
# enforcement the producer slice deliberately left to the actual selection
# caller.
#
# WHAT THIS IS NOT. It does not create a second context or task store, and it
# does not reimplement eligibility, authority, hold-law, qualification, landing,
# or programme semantics - those owners stay canonical:
#   - per-task readiness -> fm-backlog-transition-lib.sh (fm_backlog_row_probe /
#     fm_backlog_row_dispatchable), the SAME predicate fm-spawn.sh dispatches on,
#     whose home-level complement is fm-fleet-snapshot's eligible_queued.
#   - qualification -> no-mistakes; landing authority -> the guarded landing
#     owner; the routed material-Sol request + lease-bound ruling -> the
#     canonical fm-sol-control path (which lives in the control-plane project,
#     NOT this repo). This library enforces the Class-C PREREQUISITE at the
#     effect boundary - a consumed-ruling RECEIPT must exist - it never routes
#     or rules a request itself.
# The work-context is ASSEMBLED (composed) from existing owners at consumption
# time: state/<id>.meta (worktree/project), live git in that worktree
# (head/tree), and the backlog owner. An OPTIONAL per-task declaration sidecar
# data/<id>/work-context.json carries only what the current owners cannot supply
# - the declared source locator/integrity/owner, the required reference set and
# its generation, the qualification and activation owners, the applicability
# identity, and the authority bases. It carries source identity + applicability,
# NEVER tasks or authority to act. A task with no sidecar is Class A
# standing-grant work: the preflight passes and existing behavior is unchanged.
#
# COMPOSITIONAL AUTHORITY (Sol 5575378618 / 5575438538). The authority bases
# COEXIST; this is not an exactly-one-class enum. Class A (standing grant) and
# Class B (recorded Captain consent) proceed, but neither waives a Class-C
# prerequisite: a material Sol decision requires a routed request + a
# lease-bound typed ruling + the consume/apply path BEFORE the dependent effect,
# and prose - a request id, a label, a queued task, a Captain tag, local-green
# tests - never substitutes for the consumed ruling. Emitting the routed request
# is NOT gated by the ruling it seeks; only the dependent EFFECT is. A
# missing/stale ruling blocks ONLY the dependent effect; independent authorized
# work continues.
#
# EFFECT CLASSES (the caller declares which it is about to perform):
#   recovery    - safety/control recovery (a stuck-worker relaunch, a guard
#                 repair). NEVER blocked, whatever the context state.
#   independent - authorized work with no declared dependency on the context.
#                 Missing/stale context does NOT block it (only dependent work).
#   dependent   - an effect that depends on the declared context/ruling. This is
#                 the only class the context/authority refusals gate.
#
# CONTRACT. All functions are set -u / set -e safe and have NO side effects on
# source except reconcile, which writes one per-task receipt atomically.
# Callers must have sourced fm-tasks-axi-lib.sh, fm-backlog-transition-lib.sh,
# and fm-backend.sh first (for fm_backlog_row_probe / fm_backlog_row_dispatchable
# / fm_backlog_transition_applies / fm_meta_get); the front-end
# bin/fm-work-context.sh does this. jq is required (as it is fleet-wide).
#
# INSTALLED / ACTIVE distinction. bin/fm-work-context.sh is the installed caller
# proving every watched-red end to end. Live adoption in the fm-spawn dispatch
# hot path (the read-only insertion point is documented in bin/fm-spawn.sh right
# after its backlog-dispatchability probe) and the caller read-back against real
# tasks are the SEPARATE downstream ACTIVE steps; a merge is not activation.

# Distinct typed exits (mirroring fm-gate-refuse-lib.sh's exit-3 refusal grade):
FM_WORK_CONTEXT_PASS_EXIT=0
FM_WORK_CONTEXT_USAGE_EXIT=2
FM_WORK_CONTEXT_REFUSE_EXIT=3   # a dependent effect is refused (typed detail)
FM_WORK_CONTEXT_NOOP_EXIT=4     # nothing eligible to dispatch (no wake loop)

# Result variables (set by the functions below, read by the front-end).
FM_WORK_CONTEXT_VERDICT=
FM_WORK_CONTEXT_DETAIL=
FM_WORK_CONTEXT_CLASSES=
FM_WORK_CONTEXT_CLASS_C_RULING=
FM_WORK_CONTEXT_RECONCILE=
FM_WORK_CONTEXT_LOCATOR=

# The canonical owner tokens this contract recognizes. The actual qualification
# and landing SEMANTICS remain owned by no-mistakes and the guarded landing
# owner; these tokens only let the contract refuse a descriptor that names the
# WRONG owner instead of silently trusting stale prose.
FM_WORK_CONTEXT_QUALIFICATION_OWNERS="no-mistakes control-plane-reds"
FM_WORK_CONTEXT_ACTIVATION_OWNERS="firstmate delegated-landing"

fm_work_context_reset() {
  FM_WORK_CONTEXT_VERDICT=
  FM_WORK_CONTEXT_DETAIL=
}

fm_work_context_descriptor_path() {  # <data-dir> <id>
  printf '%s/%s/work-context.json\n' "$1" "$2"
}

# Read one jq path from the descriptor; prints the value, or empty when the
# field is absent or the descriptor is malformed. This is a pure printer safe to
# call inside command substitution; descriptor validity is checked once, in
# scope, by _fm_wc_descriptor_valid before any field is read for an effect.
_fm_wc_desc() {  # <descriptor-file> <jq-filter>
  local file=$1 filter=$2
  [ -f "$file" ] || return 0
  jq -r "$filter // empty" "$file" 2>/dev/null || true
}

# Refuse a descriptor that exists but is not valid JSON, in function scope so the
# typed detail survives (never selected around).
_fm_wc_descriptor_valid() {  # <descriptor-file>
  local file=$1
  [ -f "$file" ] || return 0
  if ! jq empty "$file" >/dev/null 2>&1; then
    FM_WORK_CONTEXT_DETAIL="malformed work-context descriptor: $file"
    return 1
  fi
  return 0
}

# Compositional authority classification. Sets FM_WORK_CONTEXT_CLASSES (the
# declared bases, defaulting to "A") and FM_WORK_CONTEXT_CLASS_C_RULING to
# present|absent|prose-only for a Class-C task. A consumed ruling is proven only
# by a receipt FILE that is valid JSON with consumed==true and a non-empty
# ruling and lease; a bare request id, label, or Captain tag in the descriptor
# is prose and never counts.
fm_work_context_authority_classify() {  # <data-dir> <id>
  local data=$1 id=$2 desc classes receipt
  desc=$(fm_work_context_descriptor_path "$data" "$id")
  FM_WORK_CONTEXT_CLASSES=A
  FM_WORK_CONTEXT_CLASS_C_RULING=
  [ -f "$desc" ] || return 0
  classes=$(jq -r '(.authority.classes // ["A"]) | join(" ")' "$desc" 2>/dev/null) || {
    FM_WORK_CONTEXT_DETAIL="malformed work-context descriptor: $desc"
    return 1
  }
  [ -n "$classes" ] || classes=A
  FM_WORK_CONTEXT_CLASSES=$classes
  case " $classes " in
    *" C "*) ;;
    *) return 0 ;;
  esac
  # Class C is required: locate and validate the consumed-ruling receipt.
  receipt=$(_fm_wc_desc "$desc" '.authority.ruling_receipt')
  if [ -z "$receipt" ]; then
    FM_WORK_CONTEXT_CLASS_C_RULING=absent
    return 0
  fi
  case "$receipt" in
    /*) : ;;
    *) receipt="$data/$id/$receipt" ;;   # relative to the task's data dir
  esac
  if [ ! -f "$receipt" ] \
    || ! jq -e '(.consumed == true) and ((.ruling // "") != "") and ((.lease // "") != "")' \
         "$receipt" >/dev/null 2>&1; then
    FM_WORK_CONTEXT_CLASS_C_RULING=prose-only
    return 0
  fi
  FM_WORK_CONTEXT_CLASS_C_RULING=present
  return 0
}

# Resolve the DECLARED source locator FIRST (no heuristic crawl). The declared
# locator is the descriptor's source.locator when present, otherwise the current
# handoff's declared worktree from state/<id>.meta. Sets FM_WORK_CONTEXT_DETAIL
# with a typed condition and returns 1 on any declared-locator failure.
_fm_wc_resolve_locator() {  # <state-dir> <data-dir> <id>
  local state=$1 data=$2 id=$3 desc meta locator owner head tree
  desc=$(fm_work_context_descriptor_path "$data" "$id")
  meta="$state/$id.meta"
  locator=$(_fm_wc_desc "$desc" '.source.locator')
  if [ -z "$locator" ]; then
    locator=$(fm_meta_get "$meta" worktree)
  fi
  if [ -z "$locator" ]; then
    FM_WORK_CONTEXT_DETAIL="declared-location-missing: no source locator in descriptor or meta"
    return 1
  fi
  if [ ! -e "$locator" ]; then
    FM_WORK_CONTEXT_DETAIL="declared-location-missing: $locator"
    return 1
  fi
  if [ ! -d "$locator" ] || [ ! -r "$locator" ]; then
    FM_WORK_CONTEXT_DETAIL="declared-location-inaccessible: $locator"
    return 1
  fi
  # Integrity + canonical-owner identity, only when the descriptor declares them.
  owner=$(_fm_wc_desc "$desc" '.source.owner')
  if [ -n "$owner" ]; then
    local declared_project
    declared_project=$(fm_meta_get "$meta" project)
    if [ -n "$declared_project" ] && [ "$owner" != "$declared_project" ]; then
      FM_WORK_CONTEXT_DETAIL="declared-owner-mismatch: descriptor $owner vs meta $declared_project"
      return 1
    fi
  fi
  FM_WORK_CONTEXT_LOCATOR=$locator
  return 0
}

# Validate declared source identity (repo/head/tree) against the live worktree.
# Each mismatch is a distinct typed refusal. Undeclared fields ("any" or empty)
# are not checked.
_fm_wc_check_source() {  # <descriptor-file> <locator>
  local desc=$1 locator=$2 want_repo want_head want_tree have_head have_tree have_repo
  want_repo=$(_fm_wc_desc "$desc" '.source.repo')
  want_head=$(_fm_wc_desc "$desc" '.source.head')
  want_tree=$(_fm_wc_desc "$desc" '.source.tree')
  if [ -n "$want_repo" ] && [ "$want_repo" != any ]; then
    have_repo=$(git -C "$locator" remote get-url origin 2>/dev/null || true)
    [ -n "$have_repo" ] || have_repo=$(basename "$(git -C "$locator" rev-parse --show-toplevel 2>/dev/null || echo "$locator")")
    if [ "$want_repo" != "$have_repo" ]; then
      FM_WORK_CONTEXT_DETAIL="wrong-repo: declared $want_repo vs current $have_repo"
      return 1
    fi
  fi
  if [ -n "$want_head" ] && [ "$want_head" != any ]; then
    have_head=$(git -C "$locator" rev-parse HEAD 2>/dev/null || true)
    if [ "$want_head" != "$have_head" ]; then
      FM_WORK_CONTEXT_DETAIL="wrong-head: declared $want_head vs current ${have_head:-none}"
      return 1
    fi
  fi
  if [ -n "$want_tree" ] && [ "$want_tree" != any ]; then
    have_tree=$(git -C "$locator" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
    if [ "$want_tree" != "$have_tree" ]; then
      FM_WORK_CONTEXT_DETAIL="wrong-tree: declared $want_tree vs current ${have_tree:-none}"
      return 1
    fi
  fi
  return 0
}

# Validate the required reference set: every declared reference path must exist
# and be readable (missing-reference), and when the descriptor declares a
# reference generation marker, the marker's current token must equal the
# expected one (stale-reference-generation). The generation marker is an
# EXISTING producer artifact, not a new store.
_fm_wc_check_references() {  # <descriptor-file>
  local desc=$1 refs ref marker expected current
  refs=$(jq -r '(.required_references // []) | .[]' "$desc" 2>/dev/null) || {
    FM_WORK_CONTEXT_DETAIL="malformed work-context descriptor: $desc"; return 1; }
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if [ ! -e "$ref" ] || [ ! -r "$ref" ]; then
        FM_WORK_CONTEXT_DETAIL="missing-reference: $ref"
        return 1
      fi
    done <<EOF
$refs
EOF
  fi
  marker=$(_fm_wc_desc "$desc" '.reference_generation.marker')
  expected=$(_fm_wc_desc "$desc" '.reference_generation.expected')
  if [ -n "$marker" ] && [ -n "$expected" ]; then
    if [ ! -r "$marker" ]; then
      FM_WORK_CONTEXT_DETAIL="stale-reference-generation: generation marker unreadable $marker"
      return 1
    fi
    current=$(head -1 "$marker" 2>/dev/null | tr -d '[:space:]')
    if [ "$current" != "$expected" ]; then
      FM_WORK_CONTEXT_DETAIL="stale-reference-generation: marker $current vs expected $expected"
      return 1
    fi
  fi
  return 0
}

# Validate the declared qualification and activation owners name a recognized
# canonical owner. A wrong or empty owner is a typed refusal.
_fm_wc_check_owners() {  # <descriptor-file>
  local desc=$1 qual act
  qual=$(_fm_wc_desc "$desc" '.qualification_owner')
  act=$(_fm_wc_desc "$desc" '.activation_owner')
  if [ -n "$qual" ]; then
    case " $FM_WORK_CONTEXT_QUALIFICATION_OWNERS " in
      *" $qual "*) : ;;
      *) FM_WORK_CONTEXT_DETAIL="wrong-qualification-owner: $qual"; return 1 ;;
    esac
  fi
  if [ -n "$act" ]; then
    case " $FM_WORK_CONTEXT_ACTIVATION_OWNERS " in
      *" $act "*) : ;;
      *) FM_WORK_CONTEXT_DETAIL="wrong-activation-owner: $act"; return 1 ;;
    esac
  fi
  return 0
}

# The current-state readiness/duplicate predicate, reusing the SAME per-task
# owner fm-spawn.sh dispatches on. Sets FM_WORK_CONTEXT_DETAIL and returns:
#   0 eligible (queued, not held, not blocked)
#   3 refused: duplicate-dispatch (already in flight) OR held/blocked on its own
#     row (a genuine current hold/dependency - NOT the informational aggregate)
#   4 noop: no backlog item to dispatch (nothing to loop on)
#   2 the backlog owner could not be read (fail closed, preserved as error)
_fm_wc_check_readiness() {  # <config-dir> <data-dir> <id> <kind>
  local config=$1 data=$2 id=$3 kind=$4 state held blocked
  if ! fm_backlog_transition_applies "$config" "$data" "$kind"; then
    # The backlog gate does not apply here (manual backend, secondmate, no
    # backlog); readiness is owned elsewhere, so do not synthesize a refusal.
    FM_WORK_CONTEXT_DETAIL="readiness-not-gated: ${FM_BACKLOG_TRANSITION_SKIP:-not applicable}"
    return 0
  fi
  # fm_backlog_row_probe returns non-zero for a NOT_FOUND row too, so branch on
  # the result variable, not the exit status: a missing item is a no-op, only a
  # genuinely unreadable owner is an error.
  fm_backlog_row_probe "$data" "$id" || true
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    FM_WORK_CONTEXT_DETAIL="no-eligible-work: no backlog item for $id"
    return 4
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" != found ]; then
    FM_WORK_CONTEXT_DETAIL="backlog-owner-unreadable: ${FM_BACKLOG_ROW_ERROR:-unknown}"
    return 2
  fi
  read -r state held blocked <<EOF
$FM_BACKLOG_ROW_STATE
EOF
  case "$state" in
    in_flight)
      FM_WORK_CONTEXT_DETAIL="duplicate-dispatch: $id already in flight"
      return 3 ;;
  esac
  if [ "$held" = yes ]; then
    FM_WORK_CONTEXT_DETAIL="held: $id is held on its own row"
    return 3
  fi
  if [ "$blocked" = yes ]; then
    FM_WORK_CONTEXT_DETAIL="blocked: $id has an unresolved dependency"
    return 3
  fi
  if ! fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE"; then
    FM_WORK_CONTEXT_DETAIL="not-dispatchable: $id in state '$FM_BACKLOG_ROW_STATE'"
    return 3
  fi
  return 0
}

# The full preflight the caller consults before a dependent effect. Sets
# FM_WORK_CONTEXT_VERDICT + FM_WORK_CONTEXT_DETAIL and returns PASS/REFUSE/NOOP.
fm_work_context_preflight() {  # <state> <data> <config> <id> <effect>
  local state=$1 data=$2 config=$3 id=$4 effect=$5 desc kind rc
  fm_work_context_reset
  FM_WORK_CONTEXT_LOCATOR=

  # (R5) Safety/control recovery is never blocked, whatever the context state.
  if [ "$effect" = recovery ]; then
    FM_WORK_CONTEXT_VERDICT=proceed-recovery
    FM_WORK_CONTEXT_DETAIL="recovery effect is never gated"
    return "$FM_WORK_CONTEXT_PASS_EXIT"
  fi

  desc=$(fm_work_context_descriptor_path "$data" "$id")
  kind=$(fm_meta_get "$state/$id.meta" kind)
  [ -n "$kind" ] || kind=ship

  # (R4) Readiness/duplicate first, for every non-recovery effect: never dispatch
  # a duplicate, never loop on nothing. A genuine hold/dependency on the task's
  # OWN row refuses; the informational aggregate never does (R2).
  _fm_wc_check_readiness "$config" "$data" "$id" "$kind"
  rc=$?
  case "$rc" in
    2) FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT" ;;
    3) FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT" ;;
    4) FM_WORK_CONTEXT_VERDICT=noop;   return "$FM_WORK_CONTEXT_NOOP_EXIT" ;;
  esac

  # (R6/R2) Context and authority refusals gate ONLY dependent effects.
  # Independent authorized work continues even when context is missing/stale.
  if [ "$effect" != dependent ]; then
    FM_WORK_CONTEXT_VERDICT=proceed
    FM_WORK_CONTEXT_DETAIL="independent authorized work; context not required"
    return "$FM_WORK_CONTEXT_PASS_EXIT"
  fi

  # The declared source-identity, reference, generation, and owner checks are
  # opt-in through the descriptor: a task that declares no work-context has no
  # dependency on one (a fresh dispatch has no worktree yet), so only readiness
  # and authority gate it. A descriptor-carrying task resolves its declared
  # locator FIRST (no heuristic crawl), then each identity facet is a distinct
  # typed refusal.
  if [ -f "$desc" ]; then
    if ! _fm_wc_descriptor_valid "$desc"; then
      FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
    if ! _fm_wc_resolve_locator "$state" "$data" "$id"; then
      FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
    if ! _fm_wc_check_source "$desc" "$FM_WORK_CONTEXT_LOCATOR"; then
      FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
    if ! _fm_wc_check_references "$desc"; then
      FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
    if ! _fm_wc_check_owners "$desc"; then
      FM_WORK_CONTEXT_VERDICT=refuse; return "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
  fi

  # (R1) Compositional authority: a required Class-C material decision needs a
  # consumed-ruling receipt BEFORE the dependent effect. Class B consent does
  # not waive it; prose does not substitute.
  if ! fm_work_context_authority_classify "$data" "$id"; then
    FM_WORK_CONTEXT_VERDICT=refuse
    FM_WORK_CONTEXT_DETAIL=${FM_WORK_CONTEXT_DETAIL:-malformed authority declaration}
    return "$FM_WORK_CONTEXT_REFUSE_EXIT"
  fi
  case " $FM_WORK_CONTEXT_CLASSES " in
    *" C "*)
      if [ "$FM_WORK_CONTEXT_CLASS_C_RULING" != present ]; then
        FM_WORK_CONTEXT_VERDICT=refuse
        FM_WORK_CONTEXT_DETAIL="class-c-prose-only: material Sol decision needs a consumed routed ruling (ruling=$FM_WORK_CONTEXT_CLASS_C_RULING); prose/consent/labels do not substitute"
        return "$FM_WORK_CONTEXT_REFUSE_EXIT"
      fi ;;
  esac

  FM_WORK_CONTEXT_VERDICT=proceed
  FM_WORK_CONTEXT_DETAIL="dependent effect authorized: source, references, owners, and authority current"
  return "$FM_WORK_CONTEXT_PASS_EXIT"
}

# (R3) Completion -> parent/reference currentness reconciliation. When a child
# materially transitions, refresh a durable currentness receipt bound to that
# child transition, PROVEN by an INDEPENDENT read-back of the authoritative
# backlog owner (fm_backlog_row_probe), and do it idempotently so a replay after
# a crash converges rather than double-applying. It never rewrites parent prose
# (history is preserved); it records machine-checkable currentness the
# next-selection preflight can consult. Returns 0 when the read-back CONFIRMS the
# transition, non-zero when it cannot (the receipt still records the
# discrepancy, so completion is never silently trusted).
fm_work_context_reconcile() {  # <state> <data> <id> <transition>
  local state=$1 data=$2 id=$3 transition=$4 receipt tmp child_state readback currentness rc=0
  receipt="$state/$id.parent-currentness"
  FM_WORK_CONTEXT_RECONCILE=

  if fm_backlog_row_probe "$data" "$id"; then
    readback=$FM_BACKLOG_ROW_RESULT
    child_state=${FM_BACKLOG_ROW_STATE%% *}
  else
    readback=error
    child_state=
  fi

  # For a completion transition, "confirmed" means the authoritative owner no
  # longer shows the child open (the row is closed/done, i.e. not found as an
  # In-flight item, or explicitly done).
  case "$transition" in
    done|merged|closed|landed|activated)
      if [ "$readback" = not_found ] || [ "$child_state" = "done" ]; then
        currentness=confirmed
      else
        currentness=unconfirmed; rc=1
      fi ;;
    *)
      # A non-terminal transition: confirmed only means we got a clean read-back.
      if [ "$readback" = error ]; then currentness=unconfirmed; rc=1; else currentness=confirmed; fi ;;
  esac

  tmp="$receipt.tmp.$$"
  {
    printf 'schema=fm-work-context-currentness.v1\n'
    printf 'id=%s\n' "$id"
    printf 'transition=%s\n' "$transition"
    printf 'child_state=%s\n' "${child_state:-none}"
    printf 'read_back=%s\n' "$readback"
    printf 'currentness=%s\n' "$currentness"
    printf 'epoch=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    FM_WORK_CONTEXT_DETAIL="could not stage currentness receipt for $id"
    FM_WORK_CONTEXT_RECONCILE=error
    return 2
  }
  # Idempotent publish: replacing the receipt with the same transition+state is a
  # no-op in effect; a replay after a crash simply re-confirms the same fact.
  mv -f "$tmp" "$receipt" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    FM_WORK_CONTEXT_DETAIL="could not publish currentness receipt for $id"
    FM_WORK_CONTEXT_RECONCILE=error
    return 2
  }
  FM_WORK_CONTEXT_RECONCILE=$currentness
  FM_WORK_CONTEXT_DETAIL="currentness=$currentness read_back=$readback child_state=${child_state:-none}"
  return "$rc"
}
