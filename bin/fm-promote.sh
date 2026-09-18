#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Promotion also writes the crewmate's ship instructions to
# data/<task-id>/ship-instructions.md and prints the fm-send.sh command that
# delivers them. Those instructions carry the scratch-state inventory, the clean
# default-branch base, the fm/<task-id> branch, and - rendered from
# bin/fm-dod-lib.sh, the single owner an ordinary ship brief also uses - the
# mode-specific Definition of done, so a promoted worker receives exactly the same
# delivery contract as a briefed one, including the lifecycle stage commands
# (bin/fm-stage.sh) and the no-mistakes mode's ask-user escalation rule and
# --yes ban.
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# The same instructions compile and render ship worker discipline from
# bin/fm-work-context-discipline-lib.sh, the single owner an ordinary ship brief
# uses. Typed task facts select the fragments, so a promoted worker receives the
# same engineering contract as a freshly briefed one.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--discipline-fact <fact>] [--proof-kind <accepted-surface|verification-lever> --proof-surface <text>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-work-context-discipline-lib.sh
. "$SCRIPT_DIR/fm-work-context-discipline-lib.sh"
# shellcheck source=bin/fm-work-context-engineering-lib.sh
. "$SCRIPT_DIR/fm-work-context-engineering-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
DISCIPLINE_ARGS=()
PROOF_KIND=
PROOF_SURFACE=
PROOF_KIND_SET=0
PROOF_SURFACE_SET=0
DISCIPLINE_SELECTION_EXPLICIT=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      discipline-fact) DISCIPLINE_ARGS+=(--fact "$a") ;;
      proof-kind)
        [ "$PROOF_KIND_SET" -eq 0 ] || { echo "error: duplicate --proof-kind" >&2; exit 1; }
        [ -n "$a" ] || { echo "error: --proof-kind requires a non-empty value" >&2; exit 1; }
        PROOF_KIND=$a; PROOF_KIND_SET=1
        ;;
      proof-surface)
        [ "$PROOF_SURFACE_SET" -eq 0 ] || { echo "error: duplicate --proof-surface" >&2; exit 1; }
        [ -n "$a" ] || { echo "error: --proof-surface requires a non-empty value" >&2; exit 1; }
        PROOF_SURFACE=$a; PROOF_SURFACE_SET=1
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --discipline-fact) want_value="discipline-fact" ;;
    --discipline-fact=*) DISCIPLINE_ARGS+=(--fact "${a#--discipline-fact=}") ;;
    --proof-kind) want_value="proof-kind" ;;
    --proof-kind=*)
      [ "$PROOF_KIND_SET" -eq 0 ] || { echo "error: duplicate --proof-kind" >&2; exit 1; }
      [ -n "${a#--proof-kind=}" ] || { echo "error: --proof-kind requires a non-empty value" >&2; exit 1; }
      PROOF_KIND=${a#--proof-kind=}; PROOF_KIND_SET=1
      ;;
    --proof-surface) want_value="proof-surface" ;;
    --proof-surface=*)
      [ "$PROOF_SURFACE_SET" -eq 0 ] || { echo "error: duplicate --proof-surface" >&2; exit 1; }
      [ -n "${a#--proof-surface=}" ] || { echo "error: --proof-surface requires a non-empty value" >&2; exit 1; }
      PROOF_SURFACE=${a#--proof-surface=}; PROOF_SURFACE_SET=1
      ;;
    --shared-boundary) echo "error: --shared-boundary is manual level selection; pass a typed --discipline-fact instead" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--discipline-fact <fact>] [--proof-kind <accepted-surface|verification-lever> --proof-surface <text>]" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it records posture only; authority is resolved separately" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

ID=${POS[0]}
if [ "${#DISCIPLINE_ARGS[@]}" -gt 0 ] || [ "$PROOF_KIND_SET" -eq 1 ] || [ "$PROOF_SURFACE_SET" -eq 1 ]; then
  DISCIPLINE_SELECTION_EXPLICIT=1
fi
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
FM_DISCIPLINE_WRITER_LOCK_PATH="$CONTROL_LOCK"
FM_DISCIPLINE_WRITER_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
DESC=
DESC_SNAPSHOT=
DESC_EXISTED=0
INSTRUCTIONS_SNAPSHOT=
INSTRUCTIONS_EXISTED=0
META_SNAPSHOT=
META_EXISTED=0
PROMOTE_DATA_TMP_DIR=
PROMOTE_STATE_TMP_DIR=
promote_cleanup() {
  local status=$?
  local rollback_failed=0 rollback_tmp
  promote_snapshot_matches() {
    local snapshot=$1 target=$2
    [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$snapshot" "$target" &&
      [ "$(stat -c %a "$snapshot" 2>/dev/null || stat -f %Lp "$snapshot")" = "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" ]
  }
  promote_restore_regular() {
    local target=$1 snapshot=$2 existed=$3 directory
    directory=${target%/*}
    if [ "$existed" -eq 0 ]; then
      rm -f -- "$target" || return 1
    else
      rollback_tmp=$(umask 077; mktemp "$directory/.rollback.XXXXXX") || return 1
      cp -p -- "$snapshot" "$rollback_tmp" || { rm -f -- "$rollback_tmp"; return 1; }
      [ -f "$rollback_tmp" ] && [ ! -L "$rollback_tmp" ] || { rm -f -- "$rollback_tmp"; return 1; }
      mv -f -- "$rollback_tmp" "$target" || { rm -f -- "$rollback_tmp"; return 1; }
    fi
    if [ "$existed" -eq 0 ]; then
      [ ! -e "$target" ] && [ ! -L "$target" ]
    else
      promote_snapshot_matches "$snapshot" "$target"
    fi
  }
  if [ "$status" -ne 0 ]; then
    if [ -n "$DESC_SNAPSHOT" ]; then
      promote_restore_regular "$DESC" "$DESC_SNAPSHOT" "$DESC_EXISTED" || { echo "error: promotion rollback failed for work context" >&2; rollback_failed=1; }
    fi
    if [ -n "$INSTRUCTIONS_SNAPSHOT" ]; then
      promote_restore_regular "$INSTRUCTIONS" "$INSTRUCTIONS_SNAPSHOT" "$INSTRUCTIONS_EXISTED" || { echo "error: promotion rollback failed for ship instructions" >&2; rollback_failed=1; }
    fi
    if [ -n "$META_SNAPSHOT" ]; then
      if [ "$META_EXISTED" -eq 1 ]; then
        rollback_tmp=$(umask 077; mktemp "$PROMOTE_STATE_TMP_DIR/meta-rollback.XXXXXX") || rollback_failed=1
        if [ "$rollback_failed" -eq 0 ]; then
          cp -p -- "$META_SNAPSHOT" "$rollback_tmp" || rollback_failed=1
          [ -f "$rollback_tmp" ] && [ ! -L "$rollback_tmp" ] || rollback_failed=1
          if [ "$rollback_failed" -eq 0 ] && ! fm_backlog_atomic_transition publish "$rollback_tmp" "$META" "task record rollback" "$STATE"; then
            rollback_failed=1
          fi
          [ "$rollback_failed" -eq 0 ] || rm -f -- "$rollback_tmp" 2>/dev/null || true
        fi
        if [ "$rollback_failed" -eq 0 ]; then
          promote_snapshot_matches "$META_SNAPSHOT" "$META" || { echo "error: promotion rollback failed for task metadata" >&2; rollback_failed=1; }
        fi
      else
        rm -f -- "$META" || rollback_failed=1
      fi
    fi
  fi
  [ "$rollback_failed" -eq 0 ] || status=70
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$DESC_SNAPSHOT" ] || rm -f -- "$DESC_SNAPSHOT" 2>/dev/null || true
  [ -z "$INSTRUCTIONS_SNAPSHOT" ] || rm -f -- "$INSTRUCTIONS_SNAPSHOT" 2>/dev/null || true
  [ -z "$META_SNAPSHOT" ] || rm -f -- "$META_SNAPSHOT" 2>/dev/null || true
  [ -z "$PROMOTE_DATA_TMP_DIR" ] || rmdir "$PROMOTE_DATA_TMP_DIR" 2>/dev/null || true
  [ -z "$PROMOTE_STATE_TMP_DIR" ] || rmdir "$PROMOTE_STATE_TMP_DIR" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
FM_DISCIPLINE_WRITER_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
META_EXISTED=1
PROMOTE_STATE_TMP_DIR=$(umask 077; mktemp -d "$STATE/.promote-$ID.XXXXXX") || { echo "error: could not create metadata staging directory" >&2; exit 1; }
[ -d "$PROMOTE_STATE_TMP_DIR" ] && [ ! -L "$PROMOTE_STATE_TMP_DIR" ] || { echo "error: unsafe metadata staging directory" >&2; exit 1; }
META_SNAPSHOT=$(mktemp "$STATE/.${ID}.meta.promote.XXXXXX") || { echo "error: could not stage task metadata" >&2; exit 1; }
cp -p -- "$META" "$META_SNAPSHOT" || { echo "error: could not snapshot task metadata" >&2; exit 1; }

# The promoted worker must receive the same delivery contract an ordinary ship
# brief carries, so the mode-specific Definition of done is rendered from its
# single owner (bin/fm-dod-lib.sh) rather than summarised into a hint line. A
# promoted no-mistakes worker that never received the ask-user escalation rule or
# the --yes ban is the delivery hole this file used to leave open.
INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
DESC="$DATA/$ID/work-context.json"
if [ -f "$DESC" ] && [ ! -L "$DESC" ] &&
  jq -e '.engineering.discipline != null' "$DESC" >/dev/null 2>&1; then
  if [ "$DISCIPLINE_SELECTION_EXPLICIT" -eq 0 ]; then
    fm_discipline_load "$DATA" "$ID" ship implementation || {
      echo "error: ${FM_WORK_CONTEXT_DETAIL:-persisted discipline selection is invalid}" >&2
      exit 3
    }
    DISCIPLINE_ARGS=()
    while IFS= read -r fact; do
      [ -n "$fact" ] && DISCIPLINE_ARGS+=(--fact "$fact")
    done < <(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq -r '.facts[]?')
    persisted_proof_kind=$(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq -r '.proof_kind // empty')
    persisted_proof_surface=$(printf '%s' "$FM_DISCIPLINE_RECEIPT" | jq -j '.proof_surface // empty'; printf '\001')
    persisted_proof_surface=${persisted_proof_surface%$'\001'}
    [ -z "$persisted_proof_kind" ] || DISCIPLINE_ARGS+=(--proof-kind "$persisted_proof_kind" --proof-surface "$persisted_proof_surface")
  fi
fi
[ -z "$PROOF_KIND" ] || DISCIPLINE_ARGS+=(--proof-kind "$PROOF_KIND")
[ -z "$PROOF_SURFACE" ] || DISCIPLINE_ARGS+=(--proof-surface "$PROOF_SURFACE")
fm_discipline_compile "$ID" ship implementation "${DISCIPLINE_ARGS[@]+"${DISCIPLINE_ARGS[@]}"}" || {
  echo "error: ${FM_WORK_CONTEXT_DETAIL:-discipline selection failed}" >&2
  exit 3
}
mkdir -p "$DATA/$ID"
[ ! -L "$DATA/$ID" ] && [ -d "$DATA/$ID" ] || { echo "error: task data directory is unsafe: $DATA/$ID" >&2; exit 1; }
[ ! -e "$INSTRUCTIONS" ] && [ ! -L "$INSTRUCTIONS" ] || {
  [ -f "$INSTRUCTIONS" ] && [ ! -L "$INSTRUCTIONS" ] || { echo "error: ship instructions path is unsafe: $INSTRUCTIONS" >&2; exit 1; }
}
if [ -e "$DESC" ] || [ -L "$DESC" ]; then
  [ -f "$DESC" ] && [ ! -L "$DESC" ] || { echo "error: work context path is unsafe: $DESC" >&2; exit 1; }
  DESC_EXISTED=1
fi
PROMOTE_DATA_TMP_DIR=$(umask 077; mktemp -d "$DATA/$ID/.promote.XXXXXX") || { echo "error: could not create promotion staging directory" >&2; exit 1; }
[ -d "$PROMOTE_DATA_TMP_DIR" ] && [ ! -L "$PROMOTE_DATA_TMP_DIR" ] || { echo "error: unsafe promotion staging directory" >&2; exit 1; }
DESC_SNAPSHOT=$(umask 077; mktemp "$PROMOTE_DATA_TMP_DIR/work-context.snapshot.XXXXXX") || { echo "error: could not stage work context" >&2; exit 1; }
if [ "$DESC_EXISTED" -eq 1 ]; then
  cp -p -- "$DESC" "$DESC_SNAPSHOT" || { echo "error: could not snapshot work context" >&2; exit 1; }
fi
INSTRUCTIONS_SNAPSHOT=$(umask 077; mktemp "$PROMOTE_DATA_TMP_DIR/ship-instructions.snapshot.XXXXXX") || { echo "error: could not stage ship instructions" >&2; exit 1; }
if [ -f "$INSTRUCTIONS" ]; then
  INSTRUCTIONS_EXISTED=1
  cp -p -- "$INSTRUCTIONS" "$INSTRUCTIONS_SNAPSHOT" || { echo "error: could not snapshot ship instructions" >&2; exit 1; }
fi
fm_discipline_prepare "$DATA" "$ID" "${DISCIPLINE_ARGS[@]+"${DISCIPLINE_ARGS[@]}"}" || {
  echo "error: ${FM_WORK_CONTEXT_DETAIL:-discipline selection failed}" >&2
  exit 3
}
DISCIPLINE=$(fm_discipline_envelope_render "$DATA" "$ID") || {
  echo "error: discipline envelope rendering failed" >&2
  exit 3
}
ENGINEERING=$(fm_work_context_engineering_prompt "$DATA" "$ID" all all 0) || {
  echo "error: engineering context source verification failed; run fm-work-context.sh engineering $ID all all for the exact gap" >&2
  exit 3
}
TMP=$(umask 077; mktemp "$PROMOTE_DATA_TMP_DIR/ship-instructions.XXXXXX") || { echo "error: could not stage ship instructions" >&2; exit 1; }
[ -f "$TMP" ] && [ ! -L "$TMP" ] || { echo "error: unsafe ship instructions staging file" >&2; exit 1; }
{
  printf '%s\n' "$DISCIPLINE"
  printf 'You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.\n\n'
cat <<EOF
# Ship instructions
Your scout task has been promoted to a ship task, mode=$MODE. Your window, worktree, and context stay as they are; only the contract below changes.

1. **Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with \`git status\` and \`git log\` before changing anything.
3. Return to a clean default-branch base, then create your branch: \`git checkout -b fm/$ID\`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. These ship instructions supersede the scout delivery rules and report-based Definition of done.
The worker discipline below replaces the scout evidence subset. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule.

EOF
  printf '%s\n' "$ENGINEERING"
  fm_dod_block "$MODE" "$ID"
} > "$TMP" || { echo "error: could not render ship instructions for mode=$MODE" >&2; exit 1; }
mv "$TMP" "$INSTRUCTIONS"
TMP=
[ -f "$INSTRUCTIONS" ] && [ -r "$INSTRUCTIONS" ] || { echo "error: ship instructions were not published as a readable file: $INSTRUCTIONS" >&2; exit 1; }

TMP=$(umask 077; mktemp "$PROMOTE_STATE_TMP_DIR/meta.XXXXXX") || { echo "error: could not stage task metadata" >&2; exit 1; }
[ -f "$TMP" ] && [ ! -L "$TMP" ] || { echo "error: unsafe task metadata staging file" >&2; exit 1; }
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "origin=scout-to-ship"
} >> "$TMP"
if ! fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  rm -f -- "$TMP"
  TMP=
  echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

# A promoted no-mistakes task now carries the observation obligation its
# delivery contract implies (bin/fm-nm-observe.sh). Enrolment failing does not
# undo the promotion; the reconcile pass reports the task as UNENROLLED.
if [ "$MODE" = no-mistakes ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-nm-observe.sh" enrol "$ID" --entrypoint promote >/dev/null 2>&1 \
    || echo "warning: observation obligation for $ID was not enrolled; run bin/fm-nm-observe.sh enrol $ID" >&2
fi

HOME_Q=$(printf '%q' "$FM_HOME")
INSTRUCTIONS_Q=$(printf '%q' "$INSTRUCTIONS")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "wrote ship instructions for mode=$MODE: $INSTRUCTIONS"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID \"\$(cat $INSTRUCTIONS_Q)\""

promote_print_rechain_hint() {
  local consent_home=$1 work_home=$2 task_id=$3 id prefix
  prefix=
  [ "$consent_home" = "$FM_HOME" ] || prefix="FM_HOME=$(printf '%q' "$consent_home") "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(fm_pf_registry_get "$consent_home/state" "$id" state)" = delivered ] || continue
    echo "next: ${prefix}bin/fm-public-followup.sh rechain <new-obligation-id> --from $id --work-home $work_home --work-id $task_id --expected pr-merged"
  done <<EOF
$(fm_pf_registry_ids_for_work "$consent_home/state" "$work_home" "$task_id")
EOF
}

promote_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

promote_resolve_primary_home() {
  local parent=$1 child=$2 mate_id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$mate_id" || return 1
  parent=$(promote_canonical_home "$parent") || return 1
  child=$(promote_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$mate_id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fmx_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fmx_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key \
    "$mate_id" "$child" || return 1
  printf '%s\n' "$parent"
}

promote_warn_parent_unresolved() {
  echo "warning: could not resolve the consent-holding parent home for secondmate $1; promotion succeeded, but any open public loop must be inspected and rechained from the parent." >&2
}

if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
  PROMOTE_MATE_ID=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
  PROMOTE_PARENT_RECORD=absent
  PROMOTE_PARENT_ROUTE=
  PROMOTE_DURABLE_PARENT=
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    PROMOTE_PARENT_RECORD=invalid
    if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
      PROMOTE_PARENT_RECORD=valid
      PROMOTE_PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PROMOTE_DURABLE_PARENT=$FM_SECONDMATE_PARENT_HOME
    fi
  fi
  if [ "$PROMOTE_PARENT_RECORD" = invalid ]; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  elif [ "$PROMOTE_PARENT_ROUTE" = local ]; then
    PROMOTE_PARENT_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PROMOTE_DURABLE_PARENT}
    PROMOTE_PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      PROMOTE_LIVE_PARENT=$(promote_canonical_home "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      PROMOTE_RECORDED_PARENT=$(promote_canonical_home "$PROMOTE_DURABLE_PARENT") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
          && [ "$PROMOTE_LIVE_PARENT" != "$PROMOTE_RECORDED_PARENT" ]; then
        PROMOTE_PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
        && PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$PROMOTE_PARENT_CANDIDATE" "$FM_HOME" "$PROMOTE_MATE_ID"); then
      if fm_pf_relay_active "$PROMOTE_PARENT"; then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      fi
    else
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ "$PROMOTE_PARENT_ROUTE" = remote ]; then
    PROMOTE_HOME_ENV_TOKEN=
    if [ -f "$FM_HOME/.env" ]; then
      PROMOTE_HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
    fi
    if [ -n "$PROMOTE_HOME_ENV_TOKEN" ]; then
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if fm_pf_relay_active "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      if PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME" "$FM_HOME" "$PROMOTE_MATE_ID"); then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      else
        promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
      fi
    fi
  elif fm_pf_relay_active "$FM_HOME"; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  fi
elif fm_pf_relay_active "$FM_HOME"; then
  promote_print_rechain_hint "$FM_HOME" main "$ID"
fi
