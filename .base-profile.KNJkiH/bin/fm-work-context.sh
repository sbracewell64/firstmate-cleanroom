#!/usr/bin/env bash
# fm-work-context.sh - the installed caller for the machine-readable
# work-context contract. It composes the existing reference, readiness, and
# dispatch owners into one typed pre-effect verdict; bin/fm-work-context-lib.sh
# owns the contract itself and documents the composition and the
# implemented/qualified/landed/active distinction.
#
# Usage:
#   fm-work-context.sh preflight <id> [--effect dependent|independent|recovery]
#   fm-work-context.sh classify  <id>
#   fm-work-context.sh reconcile <id> <transition>
#   fm-work-context.sh engineering <id> <worker|reviewer|all> <stage|all>
#   fm-work-context.sh select
#
# preflight prints one `verdict=<type> detail=<...>` line and exits:
#   0 proceed        - the effect is authorized
#   3 refuse         - a dependent effect is refused (the detail names the typed
#                      condition: duplicate-dispatch, held, blocked, wrong-repo,
#                      wrong-head, wrong-tree, declared-location-missing,
#                      missing-reference, stale-reference-generation,
#                      wrong-qualification-owner, wrong-activation-owner,
#                      class-c-prose-only, ...)
#   4 noop           - nothing eligible to dispatch (no idle wake loop)
#   2 usage error
# --effect defaults to dependent (the strictest). recovery is never blocked.
#
# reconcile refreshes the per-task parent/reference currentness receipt after a
# child transition, proven by an independent read-back of the backlog owner;
# exit 0 when the read-back confirms, 1 when it cannot (the receipt still
# records the discrepancy), 2 on a receipt write failure.
#
# select composes the EXISTING per-task selection producer (fm-fleet-snapshot's
# eligible_queued) with the per-task preflight and prints, for the no-active-
# worker case, which queued tasks are independently selectable now. It is
# read-only: it never dispatches, routes, or holds, and the aggregate home state
# is reported for context only, NEVER read as a global hold. Priority and
# capacity stay with the caller. Output:
#   aggregate_state=<state> eligible_candidates=<n>
#   selectable=<id,...>   (candidates whose per-task read-back proceeds)
#   gated=<id:detail;...> (candidates a per-task refusal holds back)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-work-context-lib.sh
. "$SCRIPT_DIR/fm-work-context-lib.sh"

usage() {
  sed -n '2,39p' "$SCRIPT_DIR/fm-work-context.sh" | sed 's/^# \{0,1\}//'
}

emit_verdict() {
  printf 'verdict=%s detail=%s\n' "${FM_WORK_CONTEXT_VERDICT:-unknown}" "${FM_WORK_CONTEXT_DETAIL:-}"
}

require_id() {
  if [ -z "${1:-}" ]; then
    printf 'fm-work-context.sh: an id is required\n' >&2
    exit "$FM_WORK_CONTEXT_USAGE_EXIT"
  fi
}

case "${1:-}" in
  engineering)
    [ "$#" -eq 4 ] || { echo 'usage: engineering <id> <worker|reviewer|all> <stage|all>' >&2; exit 2; }
    if ! fm_work_context_engineering_render "$DATA" "$2" "$3" "$4"; then
      printf 'verdict=refuse detail=%s\n' "$FM_WORK_CONTEXT_DETAIL" >&2
      exit 3
    fi
    ;;
  preflight)
    shift
    id=${1:-}; require_id "$id"; shift || true
    effect=dependent
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --effect) effect=${2:-}; shift 2 || { printf 'fm-work-context.sh: --effect needs a value\n' >&2; exit "$FM_WORK_CONTEXT_USAGE_EXIT"; } ;;
        *) printf 'fm-work-context.sh: unknown argument %s\n' "$1" >&2; exit "$FM_WORK_CONTEXT_USAGE_EXIT" ;;
      esac
    done
    case "$effect" in
      dependent|independent|recovery) ;;
      *) printf 'fm-work-context.sh: --effect must be dependent, independent, or recovery\n' >&2; exit "$FM_WORK_CONTEXT_USAGE_EXIT" ;;
    esac
    fm_work_context_preflight "$STATE" "$DATA" "$CONFIG" "$id" "$effect"
    rc=$?
    emit_verdict
    exit "$rc"
    ;;
  classify)
    shift
    id=${1:-}; require_id "$id"
    if ! fm_work_context_authority_classify "$STATE" "$DATA" "$id" "$CONFIG"; then
      printf 'classes=error detail=%s\n' "${FM_WORK_CONTEXT_DETAIL:-malformed}" >&2
      exit "$FM_WORK_CONTEXT_REFUSE_EXIT"
    fi
    printf 'classes=%s class_c_ruling=%s\n' \
      "$FM_WORK_CONTEXT_CLASSES" "${FM_WORK_CONTEXT_CLASS_C_RULING:-n/a}"
    ;;
  reconcile)
    shift
    id=${1:-}; require_id "$id"; shift || true
    transition=${1:-}
    if [ -z "$transition" ]; then
      printf 'fm-work-context.sh: reconcile needs a transition\n' >&2
      exit "$FM_WORK_CONTEXT_USAGE_EXIT"
    fi
    fm_work_context_reconcile "$STATE" "$DATA" "$id" "$transition"
    rc=$?
    printf 'reconcile=%s detail=%s\n' "${FM_WORK_CONTEXT_RECONCILE:-error}" "${FM_WORK_CONTEXT_DETAIL:-}"
    exit "$rc"
    ;;
  select)
    if ! command -v jq >/dev/null 2>&1; then
      printf 'fm-work-context.sh: jq is required for select\n' >&2
      exit "$FM_WORK_CONTEXT_USAGE_EXIT"
    fi
    # Read the EXISTING per-task selection producer (fm-fleet-snapshot's
    # eligible_queued): the aggregation-hazard complement that already excludes
    # held/blocked rows, so the aggregate state is never a global hold here.
    snapshot=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) || {
        printf 'select=error detail=eligible-queued-producer-unavailable\n' >&2
        exit "$FM_WORK_CONTEXT_REFUSE_EXIT"
      }
    aggregate=$(printf '%s' "$snapshot" | jq -r '.state // "unknown"' 2>/dev/null)
    candidate_ids=$(printf '%s' "$snapshot" | jq -r '.eligible_queued[]?.id // empty' 2>/dev/null)
    candidate_count=0
    selectable=
    gated=
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      candidate_count=$((candidate_count + 1))
      # Per-task read-back: the source/authority/currentness layer the producer
      # deliberately leaves to the actual selection caller.
      if fm_work_context_preflight "$STATE" "$DATA" "$CONFIG" "$cand" dependent; then
        selectable="$selectable${selectable:+,}$cand"
      else
        gated="$gated${gated:+;}$cand:${FM_WORK_CONTEXT_DETAIL}"
      fi
    done <<EOF
$candidate_ids
EOF
    printf 'aggregate_state=%s eligible_candidates=%s\n' "${aggregate:-unknown}" "$candidate_count"
    printf 'selectable=%s\n' "$selectable"
    printf 'gated=%s\n' "$gated"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit "$FM_WORK_CONTEXT_USAGE_EXIT"
    ;;
esac
