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
# IMPLEMENTED / ACTIVE distinction. bin/fm-work-context.sh is the installed
# caller proving every watched-red end to end, and the dispatch authority gate
# (fm_work_context_dispatch_authority_gate) is WIRED into bin/fm-spawn.sh right
# after its backlog-dispatchability probe, before any endpoint/worktree/record -
# real caller enforcement in-candidate, covered by negative and positive spawn
# tests. The roadmap/backlog read-update duty is wired at the SAME seams, not as
# a second owner: fm_work_context_reconcile runs at the terminal `activated`
# transition in bin/fm-stage.sh (completion -> parent/roadmap refresh), and the
# `select` verb composes the existing eligible_queued producer with the per-task
# preflight for next-eligible-task selection. The trusted authority path is
# ADOPTED, not merely described: when a canonical control-plane ruling verifier is
# configured (config/work-context-ruling-verifier or FM_WORK_CONTEXT_RULING_VERIFIER)
# it is consulted before the dependent effect, bound to the declared applicability
# (subject + request/generation), and a verifier that is DECLARED but unreachable
# FAILS CLOSED rather than downgrading to the schema-shaped local validation - a
# schema-shaped receipt is never proof of the trusted path. Adverse and positive
# cases exercise this through the real fm-spawn dispatch caller, not a manually-
# invoked helper. What remains genuinely EXTERNAL is the control-plane verifier
# BINARY itself (it lives in the control-plane project, not this repo); the
# ACTIVE/READ-BACK claim is proven by the real-caller read-back the tests
# demonstrate, standing in for that binary. A merge is not activation, and the
# roadmap flip is `landed`, never `active`.

# shellcheck source=bin/fm-work-context-engineering-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-work-context-engineering-lib.sh"

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
FM_WC_ROADMAP_STATUS=

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

# The optional canonical-verifier command. When configured (env override or
# config/work-context-ruling-verifier naming an executable), it is AUTHORITATIVE
# and its non-zero exit fails closed; the strict local validation below is the
# fallback because the canonical fm-sol-control consume/apply path lives in the
# control-plane project, not this repo. It is never inferred from a name.
#
# Three outcomes are DISTINCT (audit finding A: a declared-but-unreachable
# verifier must never silently downgrade to the weaker schema-shaped local
# validation - opting into the trusted authority path is a decision to fail
# closed when that path cannot be reached, not to accept a local receipt as
# canonical proof):
#   return 0, prints cmd - configured AND reachable -> authoritative
#   return 1, prints nothing - NOT configured -> strict local validation is used
#   return 2, prints nothing - DECLARED but unreachable -> the caller fails closed
_fm_wc_verifier_command() {  # <config-dir>
  local config=$1 cmd
  cmd=${FM_WORK_CONTEXT_RULING_VERIFIER:-}
  if [ -z "$cmd" ] && [ -r "$config/work-context-ruling-verifier" ]; then
    cmd=$(head -1 "$config/work-context-ruling-verifier" 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$cmd" ] || return 1
  command -v "$cmd" >/dev/null 2>&1 || return 2
  printf '%s\n' "$cmd"
  return 0
}

# Compositional authority classification, driven by the AUTHORITATIVE operation
# owner. FM_WORK_CONTEXT_CLASSES is the union of the classes the operation's own
# meta declares (authority_classes=) and any the descriptor supplements; because
# meta is authoritative and survives descriptor deletion, deleting the descriptor
# can NOT downgrade a known dependent op to Class A. FM_WORK_CONTEXT_CLASS_C_RULING
# reports present only for a genuinely consumed, AFFIRMATIVE, subject-bound
# routed ruling; every other state (absent, denied-or-invalid, unconsumed,
# unbound, unrelated-subject, request/generation-mismatch, prose-only) fails
# closed. Returns 1 only on a malformed descriptor.
fm_work_context_authority_classify() {  # <state-dir> <data-dir> <id> [config-dir]
  local state=$1 data=$2 id=$3 config=${4:-} desc meta meta_classes desc_classes classes
  desc=$(fm_work_context_descriptor_path "$data" "$id")
  meta="$state/$id.meta"
  FM_WORK_CONTEXT_CLASSES=A
  FM_WORK_CONTEXT_CLASS_C_RULING=

  meta_classes=$(fm_meta_get "$meta" authority_classes | tr ',' ' ')
  desc_classes=
  if [ -f "$desc" ]; then
    if ! jq empty "$desc" >/dev/null 2>&1; then
      FM_WORK_CONTEXT_DETAIL="malformed work-context descriptor: $desc"
      return 1
    fi
    desc_classes=$(jq -r '(.authority.classes // []) | join(" ")' "$desc" 2>/dev/null)
  fi
  classes=$(printf '%s %s' "${meta_classes:-}" "${desc_classes:-}" | tr -s ' ')
  classes=${classes# }; classes=${classes% }
  [ -n "$classes" ] || classes=A
  FM_WORK_CONTEXT_CLASSES=$classes

  case " $classes " in
    *" C "*) ;;
    *) return 0 ;;
  esac
  _fm_wc_class_c_ruling "$state" "$data" "$id" "$desc" "$config"
  return 0
}

# Validate the consumed Class-C ruling receipt, failing closed on any doubt.
# <config-dir> is threaded from the caller (audit finding C) so the trusted-path
# lookup uses the SAME config dir the dispatch caller operates on, not whatever
# ambient FM_CONFIG_OVERRIDE happens to be set in the process; it falls back to
# the env only when the caller supplies nothing.
_fm_wc_class_c_ruling() {  # <state-dir> <data-dir> <id> <descriptor> [config-dir]
  local state=$1 data=$2 id=$3 desc=$4 config=${5:-} receipt verifier vrc
  local outcome subject lease request generation consumed
  local want_request want_generation
  FM_WORK_CONTEXT_CLASS_C_RULING=absent

  receipt=$(_fm_wc_desc "$desc" '.authority.ruling_receipt')
  [ -n "$receipt" ] || receipt=$(fm_meta_get "$state/$id.meta" ruling_receipt)
  [ -n "$receipt" ] || return 0
  case "$receipt" in
    /*) : ;;
    *) receipt="$data/$id/$receipt" ;;
  esac
  [ -f "$receipt" ] || return 0

  # Declared applicability identity, resolved ONCE and bound to BOTH the trusted
  # and local paths (audit finding B: the trusted verifier must not be told less
  # than the local path enforces, or adopting the authoritative path would
  # silently drop the request/generation binding a receipt is scoped to).
  want_request=$(_fm_wc_desc "$desc" '.authority.request')
  [ -n "$want_request" ] || want_request=$(fm_meta_get "$state/$id.meta" ruling_request)
  want_generation=$(_fm_wc_desc "$desc" '.authority.generation')
  [ -n "$want_generation" ] || want_generation=$(fm_meta_get "$state/$id.meta" ruling_generation)

  # A configured canonical verifier is authoritative; fail closed on its error.
  [ -n "$config" ] || config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}
  verifier=$(_fm_wc_verifier_command "$config"); vrc=$?
  case "$vrc" in
    0)
      # Bind the trusted path to the declared applicability the local path also
      # enforces: subject always, plus request/generation when declared.
      local vargs
      vargs=(verify --receipt "$receipt" --subject "$id")
      [ -n "$want_request" ] && vargs+=(--request "$want_request")
      [ -n "$want_generation" ] && vargs+=(--generation "$want_generation")
      if "$verifier" "${vargs[@]}" >/dev/null 2>&1; then
        FM_WORK_CONTEXT_CLASS_C_RULING=present
      else
        FM_WORK_CONTEXT_CLASS_C_RULING=denied-or-invalid
      fi
      return 0 ;;
    2)
      # A verifier was DECLARED but is unreachable: fail closed rather than
      # downgrade to the weaker schema-shaped local validation (audit finding A).
      FM_WORK_CONTEXT_CLASS_C_RULING="verifier-unavailable"
      return 0 ;;
    *) : ;;  # 1: no verifier configured -> strict local validation below.
  esac

  # Strict local validation. A bare {consumed:true,ruling:"x",lease:"y"} is NOT
  # enough: a DENY, an unrelated subject, or a mismatched request/generation all
  # fail closed.
  if ! jq empty "$receipt" >/dev/null 2>&1; then
    FM_WORK_CONTEXT_CLASS_C_RULING=prose-only
    return 0
  fi
  outcome=$(jq -r '(.outcome // .ruling // "") | ascii_upcase' "$receipt" 2>/dev/null)
  subject=$(jq -r '(.subject // .task // "")' "$receipt" 2>/dev/null)
  lease=$(jq -r '(.lease // "")' "$receipt" 2>/dev/null)
  request=$(jq -r '(.request // .request_id // "")' "$receipt" 2>/dev/null)
  generation=$(jq -r '(.generation // "")' "$receipt" 2>/dev/null)
  consumed=$(jq -r '(.consumed // false)' "$receipt" 2>/dev/null)

  case "$outcome" in
    PROCEED|PROCEED_WITH_CONDITIONS|PERMIT|PERMITTED|APPROVE|APPROVED|GRANT|GRANTED|ALLOW|ALLOWED) : ;;
    *) FM_WORK_CONTEXT_CLASS_C_RULING=denied-or-invalid; return 0 ;;
  esac
  [ "$consumed" = true ] || { FM_WORK_CONTEXT_CLASS_C_RULING=unconsumed; return 0; }
  if [ -z "$lease" ] || [ -z "$request" ] || [ -z "$generation" ] || [ -z "$subject" ]; then
    FM_WORK_CONTEXT_CLASS_C_RULING=unbound
    return 0
  fi
  if [ "$subject" != "$id" ]; then
    FM_WORK_CONTEXT_CLASS_C_RULING=unrelated-subject
    return 0
  fi
  if [ -n "$want_request" ] && [ "$want_request" != "$request" ]; then
    FM_WORK_CONTEXT_CLASS_C_RULING="request-mismatch"
    return 0
  fi
  if [ -n "$want_generation" ] && [ "$want_generation" != "$generation" ]; then
    FM_WORK_CONTEXT_CLASS_C_RULING="generation-mismatch"
    return 0
  fi
  FM_WORK_CONTEXT_CLASS_C_RULING=present
  return 0
}

# The dispatch-seam authority gate: the narrow predicate the fm-spawn dispatch
# path consults before the launch effect. It refuses ONLY when the operation's
# authoritative binding classifies it Class-C and no consumed affirmative bound
# ruling is present; it is inert (no jq, proceed) for every ordinary op whose
# meta declares no Class-C requirement, so existing dispatch behavior is
# unchanged. Sets FM_WORK_CONTEXT_VERDICT/DETAIL. Returns 0 proceed, 3 refuse.
fm_work_context_dispatch_authority_gate() {  # <state-dir> <data-dir> <id> [config-dir]
  local state=$1 data=$2 id=$3 config=${4:-}
  fm_work_context_reset
  if ! fm_work_context_authority_classify "$state" "$data" "$id" "$config"; then
    FM_WORK_CONTEXT_VERDICT=refuse
    FM_WORK_CONTEXT_DETAIL=${FM_WORK_CONTEXT_DETAIL:-malformed authority declaration}
    return "$FM_WORK_CONTEXT_REFUSE_EXIT"
  fi
  case " $FM_WORK_CONTEXT_CLASSES " in
    *" C "*)
      if [ "$FM_WORK_CONTEXT_CLASS_C_RULING" != present ]; then
        FM_WORK_CONTEXT_VERDICT=refuse
        FM_WORK_CONTEXT_DETAIL="class-c-authority: $id requires a consumed routed ruling before dispatch (ruling=$FM_WORK_CONTEXT_CLASS_C_RULING); prose, consent, labels, and queued tasks do not substitute"
        return "$FM_WORK_CONTEXT_REFUSE_EXIT"
      fi ;;
  esac
  FM_WORK_CONTEXT_VERDICT=proceed
  fm_work_context_engineering "$data" "$id" all all || return "$FM_WORK_CONTEXT_REFUSE_EXIT"
  fm_work_context_engineering_brief "$data" "$id" || return "$FM_WORK_CONTEXT_REFUSE_EXIT"
  FM_WORK_CONTEXT_DETAIL="dispatch authority satisfied (classes=$FM_WORK_CONTEXT_CLASSES)"
  return "$FM_WORK_CONTEXT_PASS_EXIT"
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
  local config=$1 data=$2 id=$3 kind=$4 state held blocked applies_rc=0
  fm_backlog_transition_applies "$config" "$data" "$kind" || applies_rc=$?
  if [ "$applies_rc" -eq 2 ]; then
    # An ERROR/CNO from the readiness owner (unresolvable data dir, unreadable
    # backlog, incompatible tasks-axi) must FAIL CLOSED for the dependent op -
    # never authorize on error - and surface the precise wait/recovery owner.
    FM_WORK_CONTEXT_DETAIL="readiness-owner-error: ${FM_BACKLOG_TRANSITION_ERROR:-backlog readiness owner unavailable}"
    return 2
  fi
  if [ "$applies_rc" -ne 0 ]; then
    # A legitimate exemption (manual backend, secondmate, this home keeps no
    # backlog): readiness is genuinely owned elsewhere, so do not synthesize a
    # refusal. This is distinct from the error path above.
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
  rc=0
  _fm_wc_check_readiness "$config" "$data" "$id" "$kind" || rc=$?
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
  if ! fm_work_context_authority_classify "$state" "$data" "$id" "$config"; then
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
  fm_work_context_engineering "$data" "$id" all all || return "$FM_WORK_CONTEXT_REFUSE_EXIT"
  FM_WORK_CONTEXT_DETAIL="dependent effect authorized: source, references, owners, and authority current"
  return "$FM_WORK_CONTEXT_PASS_EXIT"
}

# Per-obligation roadmap refresh. When the descriptor declares a maintained
# roadmap owner (.reconcile.roadmap) - an EXISTING producer artifact such as a
# commission-roadmap / sssf-map plan, NOT a new store - one CONFIRMED terminal
# child transition flips ONLY that child's matching obligation line from open to
# landed, leaving every unrelated obligation and all history in place (the line
# is edited in place and annotated, never deleted). An obligation line carries
# two space-separated tokens: `obligation=<key>` (the exact key this child
# fulfills, defaulting to the child id) and `status=open` | `status=landed`.
# Idempotent: a matching line already landed is untouched (already-landed). Two
# distinct discrepancies fail closed so a stale roadmap is never silently trusted
# as current: a declared obligation the roadmap does not carry at all
# (obligation-absent), and a matched obligation line whose status is neither open
# nor landed - e.g. status=in-progress, or an obligation tag with no status token
# (obligation-not-landed). Only a genuinely status=landed matched line confirms
# idempotently. Sets FM_WC_ROADMAP_STATUS and returns 0 only when the roadmap is
# now current for this obligation (applied or already-landed).
_fm_wc_roadmap_refresh() {  # <roadmap-file> <key> <child> <epoch>
  local file=$1 key=$2 child=$3 epoch=$4 tmp rc=0
  FM_WC_ROADMAP_STATUS=
  if [ ! -f "$file" ] || [ ! -r "$file" ] || [ ! -w "$file" ]; then
    FM_WC_ROADMAP_STATUS="missing:$file"
    return 1
  fi
  tmp="$file.wc.$$.$RANDOM"
  awk -v key="$key" -v child="$child" -v epoch="$epoch" '
    BEGIN { flipped = 0; landed_seen = 0; other_seen = 0 }
    {
      line = $0; is = 0
      n = split(line, t, /[ \t]+/)
      for (i = 1; i <= n; i++) if (t[i] == "obligation=" key) is = 1
      if (is && line ~ /(^|[ \t])status=open([ \t]|$)/) {
        if (!sub(/ status=open/, " status=landed", line)) {
          if (!sub(/\tstatus=open/, "\tstatus=landed", line)) {
            sub(/^status=open/, "status=landed", line)
          }
        }
        line = line " landed=" child "@" epoch
        flipped++
      } else if (is && line ~ /(^|[ \t])status=landed([ \t]|$)/) {
        landed_seen = 1
      } else if (is) {
        other_seen = 1
      }
      print line
    }
    END {
      if (flipped > 0) exit 0
      else if (other_seen > 0) exit 12
      else if (landed_seen > 0) exit 10
      else exit 11
    }
  ' "$file" > "$tmp" 2>/dev/null
  rc=$?
  case "$rc" in
    0) : ;;
    10) rm -f "$tmp" 2>/dev/null || true; FM_WC_ROADMAP_STATUS=already-landed; return 0 ;;
    11) rm -f "$tmp" 2>/dev/null || true; FM_WC_ROADMAP_STATUS="obligation-absent"; return 1 ;;
    12) rm -f "$tmp" 2>/dev/null || true; FM_WC_ROADMAP_STATUS="obligation-not-landed"; return 1 ;;
    *)  rm -f "$tmp" 2>/dev/null || true; FM_WC_ROADMAP_STATUS=refresh-error; return 1 ;;
  esac
  if mv -f "$tmp" "$file" 2>/dev/null; then
    FM_WC_ROADMAP_STATUS=applied
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  FM_WC_ROADMAP_STATUS=write-failed
  return 1
}

# (R3) Completion -> parent/reference currentness reconciliation. One authorized
# CHILD transition drives three independent steps, in order:
#   1. INDEPENDENT read-back of the CHILD's own authoritative backlog row
#      (fm_backlog_row_probe): the activation evidence that the child actually
#      transitioned, never the caller's say-so.
#   2. When the descriptor declares a parent (.reconcile.parent), an INDEPENDENT
#      read-back of that PARENT's authoritative backlog row - a different entity,
#      a genuinely independent owner - so the reconciled currentness is sourced
#      from the parent's real current state, not inferred.
#   3. When the descriptor declares a reference currentness marker
#      (.reconcile.reference_marker), REFRESH that marker atomically with the
#      reconciled child+parent state, then INDEPENDENTLY re-read it from disk
#      (not the value we believe we wrote) so a lost or partial write surfaces as
#      unconfirmed rather than silently trusted.
#   4. When the descriptor declares a maintained roadmap owner
#      (.reconcile.roadmap) and the transition is terminal, flip ONLY this
#      child's matching obligation (.reconcile.obligation, default the child id)
#      from open to landed in that owner via _fm_wc_roadmap_refresh, leaving
#      unrelated obligations and all history in place. It runs only when the
#      child transition is CONFIRMED, so stale open-child wording is never
#      cleared before the child actually landed, and a declared obligation the
#      roadmap does not carry downgrades the reconciliation to unconfirmed.
# It never rewrites parent prose or reimplements tasks-axi dependency semantics
# (the backlog owner stays canonical); it records a machine-checkable currentness
# the next-selection preflight can consult. Idempotent: a crash replay writes the
# same content and re-confirms the same fact. Returns 0 when every declared step
# CONFIRMS, non-zero when any cannot (the receipt still records the discrepancy,
# so completion is never silently trusted).
#
# HONEST BOUND: with no declared parent/marker this degrades to the child-only
# currentness receipt (parent=none reference=none) - the minimal form - rather
# than inventing a parent to update.
fm_work_context_reconcile() {  # <state> <data> <id> <transition>
  local state=$1 data=$2 id=$3 transition=$4
  local desc receipt tmp child_state readback currentness rc=0
  local parent parent_readback parent_state ref_marker ref_expect ref_dir rtmp
  local terminal=no roadmap roadmap_key roadmap_status=none
  desc=$(fm_work_context_descriptor_path "$data" "$id")
  receipt="$state/$id.parent-currentness"
  FM_WORK_CONTEXT_RECONCILE=

  # Step 1. fm_backlog_row_probe returns non-zero for a NOT_FOUND row too, so
  # branch on the result variable, not the exit status: a pruned/not_found row is
  # a confirmed completion, only a genuinely unreadable owner is an error.
  fm_backlog_row_probe "$data" "$id" || true
  readback=$FM_BACKLOG_ROW_RESULT
  if [ "$readback" = found ]; then
    child_state=${FM_BACKLOG_ROW_STATE%% *}
  else
    child_state=
  fi

  # For a completion transition, "confirmed" means the authoritative owner no
  # longer shows the child open (the row is closed/done, i.e. not found as an
  # In-flight item, or explicitly done).
  case "$transition" in
    done|merged|closed|landed|activated)
      terminal=yes
      if [ "$readback" = not_found ] || [ "$child_state" = "done" ]; then
        currentness=confirmed
      else
        currentness=unconfirmed; rc=1
      fi ;;
    *)
      # A non-terminal transition: confirmed only means we got a clean read-back.
      if [ "$readback" = error ]; then currentness=unconfirmed; rc=1; else currentness=confirmed; fi ;;
  esac

  # Step 2. INDEPENDENT read-back of the declared PARENT's authoritative row.
  parent=$(_fm_wc_desc "$desc" '.reconcile.parent')
  parent_state=none
  if [ -n "$parent" ]; then
    fm_backlog_row_probe "$data" "$parent" || true
    case "$FM_BACKLOG_ROW_RESULT" in
      found)     parent_state=${FM_BACKLOG_ROW_STATE%% *} ;;
      not_found) parent_state=absent ;;
      *)         parent_state=unreadable; currentness=unconfirmed; rc=1 ;;
    esac
  fi

  # Step 3. Refresh the declared reference currentness marker, then INDEPENDENTLY
  # re-read it. A write/read-back failure downgrades the reconciliation to
  # unconfirmed even when the child itself transitioned.
  ref_marker=$(_fm_wc_desc "$desc" '.reconcile.reference_marker')
  parent_readback=none
  if [ -n "$ref_marker" ]; then
    case "$ref_marker" in
      /*) : ;;
      *) ref_marker="$data/$id/$ref_marker" ;;
    esac
    if [ "$currentness" = confirmed ]; then
      ref_expect="child=$id transition=$transition child_state=${child_state:-done} parent=${parent:-none} parent_state=$parent_state"
      ref_dir=$(dirname "$ref_marker")
      rtmp="$ref_marker.tmp.$$"
      if mkdir -p "$ref_dir" 2>/dev/null \
        && ( umask 077; printf '%s\n' "$ref_expect" > "$rtmp" ) 2>/dev/null \
        && mv -f "$rtmp" "$ref_marker" 2>/dev/null; then
        parent_readback=$(head -1 "$ref_marker" 2>/dev/null || true)
        if [ "$parent_readback" = "$ref_expect" ]; then
          parent_readback=confirmed
        else
          currentness=unconfirmed; rc=1
          parent_readback="mismatch:${parent_readback:-empty}"
        fi
      else
        rm -f "$rtmp" 2>/dev/null || true
        currentness=unconfirmed; rc=1
        parent_readback=write-failed
      fi
    else
      parent_readback=skipped-unconfirmed-child
    fi
  fi

  # Step 4. Flip this child's matching obligation in the declared maintained
  # roadmap owner from open to landed, but only for a CONFIRMED terminal
  # transition: stale open-child wording must never be cleared before the child
  # actually landed. An obligation the roadmap does not carry, or a write that
  # fails, downgrades the reconciliation to unconfirmed so a stale roadmap is
  # never silently trusted as current.
  roadmap=$(_fm_wc_desc "$desc" '.reconcile.roadmap')
  if [ -n "$roadmap" ]; then
    case "$roadmap" in
      /*) : ;;
      *) roadmap="$data/$id/$roadmap" ;;
    esac
    roadmap_key=$(_fm_wc_desc "$desc" '.reconcile.obligation')
    [ -n "$roadmap_key" ] || roadmap_key=$id
    if [ "$terminal" != yes ]; then
      roadmap_status=skipped-nonterminal
    elif [ "$currentness" != confirmed ]; then
      roadmap_status=skipped-unconfirmed-child
    else
      if _fm_wc_roadmap_refresh "$roadmap" "$roadmap_key" "$id" "$(date +%s 2>/dev/null || echo 0)"; then
        roadmap_status=$FM_WC_ROADMAP_STATUS
      else
        roadmap_status=$FM_WC_ROADMAP_STATUS
        currentness=unconfirmed; rc=1
      fi
    fi
  fi

  tmp="$receipt.tmp.$$"
  {
    printf 'schema=fm-work-context-currentness.v1\n'
    printf 'id=%s\n' "$id"
    printf 'transition=%s\n' "$transition"
    printf 'child_state=%s\n' "${child_state:-none}"
    printf 'read_back=%s\n' "$readback"
    printf 'parent=%s\n' "${parent:-none}"
    printf 'parent_state=%s\n' "$parent_state"
    printf 'reference_marker=%s\n' "${ref_marker:-none}"
    printf 'parent_readback=%s\n' "$parent_readback"
    printf 'roadmap=%s\n' "${roadmap:-none}"
    printf 'roadmap_obligation=%s\n' "${roadmap_key:-none}"
    printf 'roadmap_refresh=%s\n' "$roadmap_status"
    printf 'currentness=%s\n' "$currentness"
    printf 'engineering_context=%s\n' "$(fm_meta_get "$state/$id.meta" stage_context)"
    printf 'engineering_evidence=%s\n' "$(fm_meta_get "$state/$id.meta" stage_evidence)"
    fm_work_context_engineering_residuals "$desc" | while IFS= read -r obligation; do
      printf 'engineering_residual=%s\n' "$obligation"
    done
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
  FM_WORK_CONTEXT_DETAIL="currentness=$currentness read_back=$readback child_state=${child_state:-none} parent=${parent:-none} parent_state=$parent_state reference=$parent_readback roadmap=$roadmap_status"
  return "$rc"
}
