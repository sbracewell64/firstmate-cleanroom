#!/usr/bin/env bash
# fm-stage.sh - single owner of a ship task's lifecycle stage transitions: the
# stage a task is at (recorded in state/<id>.meta), the transition receipt that
# moved it there (one status-log line per transition), and the code-issued
# validation admission that lets a no-mistakes worker start the pipeline on its
# committed candidate without waiting for a conversational steer.
#
# Usage (FM_HOME must be explicit, exactly as bin/fm-send.sh requires, so a
# worker's shell can never resolve the wrong home):
#   FM_HOME=<home> fm-stage.sh <task-id> committed [--retry]
#                              [--expect-nm-home <path>] [--expect-path0 <dir>]
#   FM_HOME=<home> fm-stage.sh <task-id> running [--run <run-id>]
#   FM_HOME=<home> fm-stage.sh <task-id> ci-ready --pr <url>
#   FM_HOME=<home> fm-stage.sh <task-id> landing [--pr <url>]
#   FM_HOME=<home> fm-stage.sh <task-id> activated
#   FM_HOME=<home> fm-stage.sh <task-id> show
#   fm-stage.sh --help
#
# Stages, in order:
#   candidate-committed -> validation-pending | validation-admitted
#                       -> validation-running -> ci-ready -> landing -> activated
# bin/fm-classify-lib.sh owns how each stage verb classifies (progress, wait,
# terminal); bin/fm-dod-lib.sh renders the worker's stage commands into every
# ship brief and every promoted scout's ship instructions; bin/fm-crew-state.sh
# renders the recorded stage as current state when no run outranks it.
#
# Every transition prints one typed line and exits 0:
#   STAGE: <stage>: task=<id> ... (the receipt line as appended)   issued
#   STAGE_UNCHANGED: <stage> task=<id> ...                        the same
#                    transition was already recorded: duplicate delivery is a
#                    no-op, nothing is appended or rewritten
# followed by `next: <what the named owner does now>`. A transition that cannot
# be proven prints one typed refusal and exits 1 with nothing recorded:
#   STAGE_REFUSED: transition=<t> task=<id> reason=<CODE> <detail>
# Reason codes: NOT_SHIP, NO_WORKTREE, DETACHED, UNCOMMITTED, STALE_CANDIDATE
# (the recorded candidate head is no longer an ancestor of the worktree head:
# the worker rewrote or reset the candidate under an admitted attempt),
# NOT_ADMITTED, RUN_ACTIVE, HOLD_APPEARED, MISSING_BINDING, DAEMON_RESET,
# RUN_BOUND, NOT_CI_READY, BAD_PR, NO_READBACK. Exit 2 is a usage error or an
# unreadable record.
#
# Transitions:
#   committed  The worker runs this after its implementation commit. It records
#              the candidate (branch, head, tree) of the task worktree named in
#              the task record as `candidate-committed`, then issues the
#              validation transition ITSELF when the task's standing authority
#              admits it: a `mode=no-mistakes` delivery contract plus the
#              admitted resource allocation (the recorded dispatch: harness,
#              model, effort, backend). Admission is refused into an explicit
#              `validation-pending` wait when a real hold exists (an open keyed
#              needs-decision or blocked in this task's status fold, read through
#              bin/fm-classify-lib.sh's status_open_decisions) or when capacity
#              is missing (the observer's launch admission, bin/fm-nm-observe.sh
#              `launch`, refused the qualified tool profile or daemon identity).
#              Both facts are re-read immediately before the admitted line is
#              written, so a hold that appeared or a head that moved during the
#              admission read refuses instead of admitting a stale candidate. On
#              `validation-admitted` the worker starts `no-mistakes axi run` at
#              once; on `validation-pending` it stops and waits, and re-runs this
#              same command when firstmate says the wait cleared. direct-PR and
#              local-only tasks record only `candidate-committed` and continue
#              with their own definition of done. Repeating the command at the
#              same head is a no-op; --retry opens a new observer attempt for a
#              genuinely new run (a failed or cancelled run, or a re-committed
#              candidate after custody was returned).
#   running    The worker runs this as soon as the pipeline created the run.
#              It binds the actual run id through the observer (`bind`, under
#              bin/fm-nm-run-lib.sh's attribution rules; --run names it) and
#              records `validation-running` with the run id, canonical status,
#              and class. A head that is no longer a descendant of the admitted
#              candidate refuses as STALE_CANDIDATE; pipeline fix commits on top
#              of the candidate are descendants and are fine.
#   ci-ready   The worker runs this when the pipeline reports CI green. The
#              verdict is the canonical one bin/fm-crew-state.sh renders from the
#              run step (`state: done` from `source: run-step`), never the
#              worker's narration, the command's exit status, or a status-log
#              line; the observer's `refresh` records the run's status and class
#              beside it. Records `ci-ready` with the PR and stops the worker:
#              the configured merge authority owns landing.
#   landing    Firstmate runs this when the configured merge authority is
#              landing the change (before bin/fm-pr-merge.sh or
#              bin/fm-merge-local.sh). Records `landing`; never merges anything.
#   activated  Firstmate runs this after landing to record the read-back:
#              the merge-notification marker bin/fm-pr-lib.sh writes with the PR
#              identity, or the candidate head reachable from the project
#              clone's checked-out head. No read-back refuses as NO_READBACK;
#              nothing here fetches, merges, or syncs.
#   show       Prints the recorded stage and its `next:` line; changes nothing.
#              A worker resuming after a restart runs this first and continues
#              from the recorded stage.
#
# Task-record fields (this script is their only writer; docs/configuration.md
# routes the record's other owners):
#   stage=<stage>              stage_epoch=<epoch of the last transition>
#   stage_branch=<branch>      stage_head=<full candidate head>
#   stage_tree=<full tree>     stage_gen=<spawn_gen at the last transition>
#   stage_attempt=<observer attempt id>   stage_run=<bound run id>
#   stage_pr=<PR url>          stage_reason=<validation-pending reason, or the
#                                            activated read-back evidence>
#
# Receipt fields, in this order on every stage line (`-` when not applicable;
# values percent-encode space, percent, and tab, and the classifier decodes
# them): task, gen (worker epoch: the record's spawn_gen), branch, head, tree
# (12-character prefixes; the record holds the full ids), intent (12-character
# SHA-256 of data/<id>/brief.md plus data/<id>/ship-instructions.md when
# present: the accepted intent identity), decisions (comma-separated keys of
# decisions this task opened that are now closed), mode, yolo, alloc
# (harness/model/effort/backend: the admitted resource allocation), nm_home,
# profile (<no-mistakes version>+<build> from the observer's qualified-profile
# read), attempt, run, step (the run's canonical status), outcome (the
# observer's outcome class), pr, owner (who acts next: worker, firstmate, or
# merge-authority), reason.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

die_usage() {
  echo "error: $1" >&2
  echo "usage: FM_HOME=<home> fm-stage.sh <task-id> committed|running|ci-ready|landing|activated|show [flags] | --help" >&2
  exit 2
}

[ "$#" -ge 2 ] || die_usage "a task id and a transition are required"
ID=$1
TRANSITION=$2
shift 2
case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.*|-*) die_usage "invalid task id '$ID'" ;;
esac

if [ -z "${FM_HOME:-}" ] && [ -z "${FM_STATE_OVERRIDE:-}" ]; then
  echo "error: FM_HOME is not set; fm-stage refuses to resolve a task's home implicitly (the brief's stage commands carry it)" >&2
  exit 2
fi
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 2; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-work-context-lib.sh
. "$SCRIPT_DIR/fm-work-context-lib.sh"

RETRY=0
RUN_ARG=
PR_ARG=
EXPECT_NM_HOME=
EXPECT_PATH0=
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in --*) die_usage "--$want_value requires a value" ;; esac
    case "$want_value" in
      run) RUN_ARG=$a ;;
      pr) PR_ARG=$a ;;
      expect-nm-home) EXPECT_NM_HOME=$a ;;
      expect-path0) EXPECT_PATH0=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --retry) RETRY=1 ;;
    --run) want_value=run ;;
    --run=*) RUN_ARG=${a#--run=} ;;
    --pr) want_value='pr' ;;
    --pr=*) PR_ARG=${a#--pr=} ;;
    --expect-nm-home) want_value=expect-nm-home ;;
    --expect-path0) want_value=expect-path0 ;;
    *) die_usage "unknown argument '$a'" ;;
  esac
done
[ -z "$want_value" ] || die_usage "--$want_value requires a value"

META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
OBLIGATION="$STATE/$ID.nm-observe"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no task record for $ID ($META)" >&2; exit 2; }

meta() { fm_meta_get "$META" "$1"; }
obs() { [ -f "$OBLIGATION" ] || return 0; grep "^$1=" "$OBLIGATION" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
now_epoch() { date +%s; }
short() { printf '%s' "${1:0:12}"; }
enc() {  # percent-encode space, percent, tab; a value is never multi-line
  [ -n "$1" ] || { printf -- '-'; return 0; }
  printf '%s' "$1" | tr -d '\n' | sed -e 's/%/%25/g' -e 's/ /%20/g' -e "s/$(printf '\t')/%09/g"
}
dash() { [ -n "${1:-}" ] && printf '%s' "$1" || printf -- '-'; }

KIND=$(meta kind); [ -n "$KIND" ] || KIND=ship
MODE=$(meta mode)
YOLO=$(meta yolo)
WT=$(meta worktree)
PROJECT=$(meta project)
GEN=$(meta spawn_gen)
SELF_CMD="FM_HOME=$(printf '%q' "$FM_HOME") $(printf '%q' "$SCRIPT_DIR/fm-stage.sh") $(printf '%q' "$ID")"
STAGE_PR_VALUE=
BRANCH=
HEAD=
TREE=
OBS_RC=0
OBS_OUT=

refuse() {  # <transition> <CODE> <detail>
  printf 'STAGE_REFUSED: transition=%s task=%s reason=%s %s\n' "$1" "$ID" "$2" "$3"
  exit 1
}

# --- candidate facts ---------------------------------------------------------

require_ship() {  # <transition>
  [ "$KIND" = ship ] || refuse "$1" NOT_SHIP "kind=$KIND carries no ship lifecycle"
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    *) refuse "$1" NOT_SHIP "mode='$MODE' is not a ship delivery mode" ;;
  esac
}

require_worktree() {  # <transition>
  [ -n "$WT" ] && [ -d "$WT" ] || refuse "$1" NO_WORKTREE "the task worktree is gone (${WT:-unrecorded})"
}

read_candidate() {  # sets BRANCH HEAD TREE from the worktree
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  HEAD=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
  TREE=$(git -C "$WT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
}

worktree_dirty() { [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; }

# 0 when the recorded candidate head is an ancestor of (or equal to) the
# worktree head: pipeline fix commits advance the candidate, a rewrite or reset
# abandons it.
candidate_current() {  # <recorded-head> <head>
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 0
  git -C "$WT" merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

sha256_of() {  # <file...>
  if command -v shasum >/dev/null 2>&1; then
    cat "$@" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    cat "$@" | sha256sum | awk '{print $1}'
  else
    cat "$@" | cksum | awk '{print $1}'
  fi
}

intent_identity() {
  local files=()
  [ -f "$DATA/$ID/brief.md" ] && files+=("$DATA/$ID/brief.md")
  [ -f "$DATA/$ID/ship-instructions.md" ] && files+=("$DATA/$ID/ship-instructions.md")
  [ "${#files[@]}" -gt 0 ] || { printf -- '-'; return 0; }
  short "$(sha256_of "${files[@]}")"
}

open_hold_keys() {  # comma-separated keys of still-open decisions, or empty
  local key _verb _note out=''
  [ -f "$STATUS" ] || return 0
  while IFS=$'\t' read -r key _verb _note; do
    [ -n "$key" ] || continue
    out="${out:+$out,}$key"
  done <<FOLD
$(status_open_decisions "$STATUS")
FOLD
  printf '%s' "$out"
}

closed_decision_keys() {  # comma-separated keys opened by this task and now closed
  local line verb key opened='' open out=''
  [ -f "$STATUS" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(status_line_verb "$line")
    case "$verb" in needs-decision|blocked) ;; *) continue ;; esac
    key=$(_fm_decision_key "$line") || continue
    case ",$opened," in *",$key,"*) ;; *) opened="${opened:+$opened,}$key" ;; esac
  done < "$STATUS"
  open=",$(open_hold_keys),"
  for key in ${opened//,/ }; do
    case "$open" in *",$key,"*) ;; *) out="${out:+$out,}$key" ;; esac
  done
  printf '%s' "$out"
}

alloc_identity() {
  printf '%s/%s/%s/%s' "$(dash "$(meta harness)")" "$(dash "$(meta model)")" "$(dash "$(meta effort)")" "$(fm_backend_of_meta "$META")"
}

profile_identity() {
  local v b
  v=$(obs nm_version); b=$(obs nm_build)
  [ -n "$v" ] || { printf -- '-'; return 0; }
  printf '%s+%s' "$v" "${b:--}"
}

# --- receipt and record -----------------------------------------------------

receipt_line() {  # <stage> <owner> <reason> <branch> <head> <tree>
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6
  printf '%s: task=%s gen=%s branch=%s head=%s tree=%s intent=%s decisions=%s mode=%s yolo=%s alloc=%s nm_home=%s profile=%s attempt=%s run=%s step=%s outcome=%s pr=%s owner=%s reason=%s\n' \
    "$stage" "$ID" "$(enc "$GEN")" "$(enc "$branch")" "$(enc "$(short "$head")")" "$(enc "$(short "$tree")")" \
    "$(intent_identity)" "$(enc "$(closed_decision_keys)")" "$(enc "$MODE")" "$(enc "$YOLO")" "$(enc "$(alloc_identity)")" \
    "$(enc "$(obs nm_home)")" "$(enc "$(profile_identity)")" "$(enc "$(obs attempt_id)")" "$(enc "$(obs run_id)")" \
    "$(enc "$(obs run_status)")" "$(enc "$(obs outcome_class)")" "$(enc "$STAGE_PR_VALUE")" "$owner" "$(enc "$reason")"
}

# Append the receipt, then publish the record. A crash between the two leaves a
# receipt without its record, and the next run appends it again: a bounded
# duplicate, never a lost transition.
issue() {  # <stage> <owner> <reason> <branch> <head> <tree> [extra key=value...]
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6 line tmp lock kv
  shift 6
  line=$(receipt_line "$stage" "$owner" "$reason" "$branch" "$head" "$tree")
  printf '%s\n' "$line" >> "$STATUS"
  lock=$(fm_meta_lock_path "$META") || exit 2
  fm_lock_acquire_wait "$lock"
  tmp="$STATE/.$ID.meta.stage.${BASHPID:-$$}"
  if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
    fm_lock_release "$lock"
    echo "error: task record for $ID is unsafe ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 2
  fi
  grep -v -e '^stage=' -e '^stage_' "$META" > "$tmp" || true
  {
    printf 'stage=%s\n' "$stage"
    printf 'stage_epoch=%s\n' "$(now_epoch)"
    printf 'stage_branch=%s\n' "$branch"
    printf 'stage_head=%s\n' "$head"
    printf 'stage_tree=%s\n' "$tree"
    printf 'stage_gen=%s\n' "$GEN"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } >> "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 2
  fi
  fm_lock_release "$lock"
  printf 'STAGE: %s\n' "$line"
}

unchanged() {  # <stage>
  printf 'STAGE_UNCHANGED: %s task=%s gen=%s head=%s attempt=%s run=%s\n' \
    "$1" "$ID" "$(dash "$(meta stage_gen)")" "$(dash "$(short "$(meta stage_head)")")" "$(dash "$(meta stage_attempt)")" "$(dash "$(meta stage_run)")"
}

# shellcheck disable=SC2016  # backticks are literal command quoting in the next: line the reader copies
next_for() {  # <stage>
  case "$1" in
    candidate-committed)
      case "$MODE" in
        direct-PR) printf 'next: worker pushes the branch and opens the PR with gh-axi, then appends `done: PR <url>` and stops\n' ;;
        local-only) printf 'next: worker appends `done: ready in branch %s` and stops; the configured merge authority approves the landing\n' "$(dash "$(meta stage_branch)")" ;;
        *) printf 'next: worker re-runs `%s committed` (validation was not issued)\n' "$SELF_CMD" ;;
      esac ;;
    validation-pending)
      printf 'next: worker stops and waits (%s); firstmate clears the hold or repairs the environment, then the worker re-runs `%s committed`\n' "$(dash "$(meta stage_reason)")" "$SELF_CMD" ;;
    validation-admitted)
      printf 'next: worker starts the pipeline now on head %s: `no-mistakes axi run --intent <the accepted intent>` (never --yes); as soon as the run exists, run `%s running`\n' "$(short "$(meta stage_head)")" "$SELF_CMD" ;;
    validation-running)
      printf 'next: worker drives the gates with `no-mistakes axi respond` (an ask-user finding goes to firstmate as needs-decision, never answered by the worker); when the pipeline reports CI green, run `%s ci-ready --pr <url>`\n' "$SELF_CMD" ;;
    ci-ready)
      printf 'next: worker stops; firstmate runs bin/fm-pr-check.sh and the configured merge authority owns landing (`%s landing` when it lands)\n' "$SELF_CMD" ;;
    landing)
      printf 'next: firstmate confirms the landing, then runs `%s activated`\n' "$SELF_CMD" ;;
    activated)
      printf 'next: nothing; cleanup follows through bin/fm-teardown.sh\n' ;;
    *)
      printf 'next: worker runs `%s committed` after its implementation commit\n' "$SELF_CMD" ;;
  esac
}

# --- observer and current-state seams --------------------------------------

observe() {  # <verb> [args...] -> OBS_OUT, OBS_RC
  OBS_RC=0
  OBS_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-nm-observe.sh" "$@" 2>&1) || OBS_RC=$?
}

crew_state() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true
}

# --- transitions ------------------------------------------------------------

do_committed() {
  local current recorded_head
  require_ship committed
  require_worktree committed
  read_candidate
  [ -n "$BRANCH" ] || refuse committed DETACHED "HEAD is detached; a candidate lives on a branch"
  ! worktree_dirty || refuse committed UNCOMMITTED "the worktree has uncommitted changes; commit the candidate first"
  current=$(meta stage)
  recorded_head=$(meta stage_head)
  case "$current" in
    validation-admitted|validation-running|ci-ready|landing|activated)
      if [ "$RETRY" -eq 0 ]; then
        candidate_current "$recorded_head" "$HEAD" \
          || refuse committed STALE_CANDIDATE "recorded candidate $(short "$recorded_head") is not an ancestor of head $(short "$HEAD") while attempt $(dash "$(meta stage_attempt)") is admitted; the admitted run owns that candidate (settle custody through the pipeline's supported abort, then re-run with --retry for a new attempt)"
        unchanged "$current"
        next_for "$current"
        return 0
      fi
      ;;
  esac
  if [ -z "$current" ] || [ "$recorded_head" != "$HEAD" ] || [ "$(meta stage_branch)" != "$BRANCH" ] \
      || { [ "$RETRY" -eq 1 ] && [ "$current" != candidate-committed ] && [ "$current" != validation-pending ]; }; then
    issue candidate-committed worker "" "$BRANCH" "$HEAD" "$TREE"
  else
    unchanged candidate-committed
  fi
  if [ "$MODE" != no-mistakes ]; then
    next_for candidate-committed
    return 0
  fi
  admit_validation
}

pending() {  # <reason>
  local reason=$1
  if [ "$(meta stage)" = validation-pending ] && [ "$(meta stage_head)" = "$HEAD" ] && [ "$(meta stage_reason)" = "$reason" ]; then
    unchanged validation-pending
  else
    issue validation-pending firstmate "$reason" "$BRANCH" "$HEAD" "$TREE" "stage_reason=$reason"
  fi
  next_for validation-pending
  return 0
}

admit_validation() {
  local holds attempt head2 tree2
  holds=$(open_hold_keys)
  [ -z "$holds" ] || { pending "hold:$holds"; return 0; }
  set -- launch "$ID" --entrypoint stage
  [ "$RETRY" -eq 0 ] || set -- "$@" --retry
  [ -z "$EXPECT_NM_HOME" ] || set -- "$@" --expect-nm-home "$EXPECT_NM_HOME"
  [ -z "$EXPECT_PATH0" ] || set -- "$@" --expect-path0 "$EXPECT_PATH0"
  observe "$@"
  case "$OBS_RC" in
    0) ;;
    1)
      case "$OBS_OUT" in
        *PREFLIGHT_REFUSED*) pending "capacity:$(printf '%s' "$OBS_OUT" | grep -o 'PREFLIGHT_REFUSED.*' | head -1)"; return 0 ;;
        *RUN_BOUND*) refuse validation-admitted RUN_ACTIVE "an active run is already bound to this task ($OBS_OUT); continue that run and record it with \`$SELF_CMD running\`" ;;
        *) refuse validation-admitted NOT_ADMITTED "$OBS_OUT" ;;
      esac ;;
    *) echo "error: bin/fm-nm-observe.sh launch failed (exit $OBS_RC): $OBS_OUT" >&2; exit 2 ;;
  esac
  attempt=$(obs attempt_id)
  [ -n "$attempt" ] || refuse validation-admitted NOT_ADMITTED "the observer accepted the launch but recorded no attempt id"
  # Revalidate immediately before issuing: the head, the tree, and the fold.
  head2=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
  tree2=$(git -C "$WT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  if [ "$head2" != "$HEAD" ] || [ "$tree2" != "$TREE" ] || worktree_dirty; then
    refuse validation-admitted STALE_CANDIDATE "the candidate changed during admission (recorded $(short "$HEAD"), now $(short "$head2")); commit and re-run"
  fi
  holds=$(open_hold_keys)
  [ -z "$holds" ] || refuse validation-admitted HOLD_APPEARED "hold:$holds opened during admission; re-run once it is resolved"
  if [ "$(meta stage)" = validation-admitted ] && [ "$(meta stage_attempt)" = "$attempt" ] && [ "$(meta stage_head)" = "$HEAD" ]; then
    unchanged validation-admitted
  else
    issue validation-admitted worker "" "$BRANCH" "$HEAD" "$TREE" "stage_attempt=$attempt"
  fi
  next_for validation-admitted
}

do_running() {  # <transition-label>
  local label=${1:-running} current run
  require_ship "$label"
  [ "$MODE" = no-mistakes ] || refuse "$label" NOT_ADMITTED "mode=$MODE has no validation run"
  require_worktree "$label"
  read_candidate
  current=$(meta stage)
  case "$current" in
    validation-admitted|validation-running|ci-ready) ;;
    *) refuse "$label" NOT_ADMITTED "stage=${current:-none}; validation must be admitted first (\`$SELF_CMD committed\`)" ;;
  esac
  candidate_current "$(meta stage_head)" "$HEAD" \
    || refuse "$label" STALE_CANDIDATE "recorded candidate $(short "$(meta stage_head)") is not an ancestor of head $(short "$HEAD")"
  set -- bind "$ID"
  [ -z "$RUN_ARG" ] || set -- "$@" --run "$RUN_ARG"
  observe "$@"
  if [ "$OBS_RC" -ne 0 ]; then
    case "$OBS_OUT" in
      *DAEMON_RESET*) refuse "$label" DAEMON_RESET "$OBS_OUT" ;;
      *RUN_BOUND*) refuse "$label" RUN_BOUND "$OBS_OUT" ;;
      *MISSING_BINDING*) refuse "$label" MISSING_BINDING "$OBS_OUT (retry once \`no-mistakes axi status\` lists the run; if it still refuses, append blocked:)" ;;
      *) echo "error: bin/fm-nm-observe.sh bind failed (exit $OBS_RC): $OBS_OUT" >&2; exit 2 ;;
    esac
  fi
  run=$(obs run_id)
  [ -n "$run" ] || refuse "$label" MISSING_BINDING "the observer bound no run id"
  if [ "$current" != validation-admitted ] && [ "$(meta stage_run)" = "$run" ]; then
    [ "$label" != running ] || { unchanged "$current"; next_for "$current"; }
    return 0
  fi
  issue validation-running worker "" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" "stage_attempt=$(obs attempt_id)" "stage_run=$run"
  [ "$label" != running ] || next_for validation-running
  return 0
}

do_ci_ready() {
  local current verdict
  require_ship ci-ready
  [ "$MODE" = no-mistakes ] || refuse ci-ready NOT_ADMITTED "mode=$MODE reports its PR with done:, not a ci-ready stage"
  [ -n "$PR_ARG" ] || refuse ci-ready BAD_PR "--pr <url> is required"
  fm_pr_url_parse "$PR_ARG" >/dev/null 2>&1 || refuse ci-ready BAD_PR "not a canonical PR URL: $PR_ARG"
  require_worktree ci-ready
  read_candidate
  current=$(meta stage)
  case "$current" in
    validation-admitted) do_running ci-ready; current=validation-running ;;
    validation-running|ci-ready) ;;
    *) refuse ci-ready NOT_ADMITTED "stage=${current:-none}; validation must be admitted and running first" ;;
  esac
  candidate_current "$(meta stage_head)" "$HEAD" \
    || refuse ci-ready STALE_CANDIDATE "recorded candidate $(short "$(meta stage_head)") is not an ancestor of head $(short "$HEAD")"
  verdict=$(crew_state)
  case "$verdict" in
    "state: done"*"source: run-step"*) ;;
    *) refuse ci-ready NOT_CI_READY "canonical state is not checks green from the run step: ${verdict:-no verdict}" ;;
  esac
  observe refresh "$ID"
  STAGE_PR_VALUE=$PR_ARG
  if [ "$current" = ci-ready ] && [ "$(meta stage_pr)" = "$PR_ARG" ]; then
    unchanged ci-ready
  else
    issue ci-ready merge-authority "" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(obs attempt_id)" "stage_run=$(obs run_id)" "stage_pr=$PR_ARG"
  fi
  next_for ci-ready
}

do_landing() {
  local current
  require_ship landing
  current=$(meta stage)
  [ -n "$current" ] || refuse landing NOT_ADMITTED "no candidate is recorded"
  [ "$current" != activated ] || { unchanged activated; next_for activated; return 0; }
  [ -z "$PR_ARG" ] || fm_pr_url_parse "$PR_ARG" >/dev/null 2>&1 || refuse landing BAD_PR "not a canonical PR URL: $PR_ARG"
  STAGE_PR_VALUE=${PR_ARG:-$(meta stage_pr)}
  if [ "$current" = landing ] && [ "$(meta stage_pr)" = "$STAGE_PR_VALUE" ]; then
    unchanged landing
  else
    issue landing merge-authority "" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(meta stage_attempt)" "stage_run=$(meta stage_run)" "stage_pr=$STAGE_PR_VALUE"
  fi
  next_for landing
}

readback_evidence() {  # prints the evidence, or 1
  local marker="$STATE/$ID.pr-poll-merge-notified" version provider host path number extra head main
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    if { IFS= read -r version && IFS= read -r provider && IFS= read -r host && IFS= read -r path && IFS= read -r number && ! IFS= read -r extra; } < "$marker" \
        && [ "$version" = fm-pr-poll-merge-notified-v1 ] && [ -n "$provider" ] && [ -n "$host" ] && [ -n "$path" ] && [ -n "$number" ]; then
      printf 'merged:%s:%s:%s:%s' "$provider" "$host" "$path" "$number"
      return 0
    fi
  fi
  head=$(meta stage_head)
  if [ -n "$head" ] && [ -n "$PROJECT" ] && [ -d "$PROJECT" ]; then
    main=$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$main" ] && git -C "$PROJECT" merge-base --is-ancestor "$head" "$main" 2>/dev/null; then
      printf 'ancestor-of:%s' "$(short "$main")"
      return 0
    fi
  fi
  return 1
}

# Completion -> parent/roadmap currentness reconciliation at the terminal
# transition seam (bin/fm-work-context-lib.sh). When the landed child declares a
# work-context reconcile block, this refreshes the parent/reference/roadmap
# currentness through the SAME owner fm-spawn and the selection preflight read,
# via an independent backlog read-back, so stale open-child wording does not
# persist as current state. It is inert for a task with no descriptor, never
# changes this stage transition's own exit status (the transition is already the
# authority), and records any discrepancy in the receipt rather than trusting the
# caller's say-so.
reconcile_currentness() {  # <transition>
  local transition=$1 desc
  desc="$DATA/$ID/work-context.json"
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$desc" ] || return 0
  jq -e '.reconcile != null' "$desc" >/dev/null 2>&1 || return 0
  # The stage transition is already the authority; a reconcile that cannot
  # confirm records the discrepancy in the receipt rather than failing the stage.
  fm_work_context_reconcile "$STATE" "$DATA" "$ID" "$transition" || true
  printf 'currentness: %s (%s)\n' "${FM_WORK_CONTEXT_RECONCILE:-unknown}" "${FM_WORK_CONTEXT_DETAIL:-}"
  return 0
}

do_activated() {
  local current evidence
  require_ship activated
  current=$(meta stage)
  [ -n "$current" ] || refuse activated NOT_ADMITTED "no candidate is recorded"
  evidence=$(readback_evidence) || refuse activated NO_READBACK "neither a merge-notification marker with PR identity nor the candidate head reachable from the project clone's checked-out head"
  STAGE_PR_VALUE=$(meta stage_pr)
  if [ "$current" = activated ] && [ "$(meta stage_reason)" = "$evidence" ]; then
    unchanged activated
  else
    issue activated firstmate "$evidence" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(meta stage_attempt)" "stage_run=$(meta stage_run)" "stage_pr=$STAGE_PR_VALUE" "stage_reason=$evidence"
  fi
  reconcile_currentness activated
  next_for activated
}

do_show() {
  local current
  current=$(meta stage)
  printf 'STAGE_RECORDED: %s task=%s gen=%s branch=%s head=%s attempt=%s run=%s pr=%s reason=%s\n' \
    "${current:-none}" "$ID" "$(dash "$(meta stage_gen)")" "$(dash "$(meta stage_branch)")" \
    "$(dash "$(short "$(meta stage_head)")")" "$(dash "$(meta stage_attempt)")" "$(dash "$(meta stage_run)")" \
    "$(dash "$(meta stage_pr)")" "$(dash "$(meta stage_reason)")"
  next_for "$current"
}

case "$TRANSITION" in
  committed) do_committed ;;
  running) do_running running ;;
  ci-ready) do_ci_ready ;;
  landing) do_landing ;;
  activated) do_activated ;;
  show) do_show ;;
  *) die_usage "unknown transition '$TRANSITION'" ;;
esac
