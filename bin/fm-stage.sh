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
#   FM_HOME=<home> fm-stage.sh <task-id> landing [--pr <url>]   (--pr must be the
#                              recorded qualified destination; a different URL is
#                              refused as DESTINATION_MISMATCH, not a revocation)
#   FM_HOME=<home> fm-stage.sh <task-id> activated
#   FM_HOME=<home> fm-stage.sh <task-id> show
#   FM_HOME=<home> fm-stage.sh <task-id> handoff --handoff-json <file>
#   FM_HOME=<home> fm-stage.sh <task-id> handoff-release --identity <sha256>
#   FM_HOME=<home> fm-stage.sh <task-id> resume-handoff
#   fm-stage.sh --help
#
# bin/fm-completion-lib.sh owns the durable report/action contract and the
# completion_handoff metadata field. Handoff release is manager-owned capacity
# admission for one exact identity. Resume refreshes the canonical run and
# reconciles admitted effects; show and successful transitions do the same.
# Programme projection remains read-only and never supplies an execution receipt.
# A following COMPLETION_CNO may return 1 after a successful STAGE receipt;
# that preserves the already applied lifecycle effect and reports the separate
# unresolved handoff. It is not a STAGE_REFUSED rollback of that effect.
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
# (the worktree head is neither the admitted candidate nor its descendant nor
# the current head of its bound active pipeline-owned run; CI-ready also
# accepts a mechanically verified completed successor through fm-nm-run-lib.sh),
# NOT_ADMITTED, RUN_ACTIVE, HOLD_APPEARED, MISSING_BINDING, DAEMON_RESET,
# RUN_BOUND, NOT_CI_READY, BAD_PR, NO_READBACK, ENGINEERING_CONTEXT,
# ENGINEERING_EVIDENCE. Exit 2 is a usage error or an
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
#              Candidate and hold checks run at the admission boundary; a retry
#              uses the observer's guarded launch before replacing either
#              owner's attempt bindings. On
#              `validation-admitted` the worker starts `no-mistakes axi run` at
#              once; on `validation-pending` it stops and waits, and re-runs this
#              same command when firstmate says the wait cleared. direct-PR and
#              local-only tasks record only `candidate-committed` and continue
#              with their own definition of done. Repeating the command at the
#              same head is a no-op; --retry opens a new observer attempt for a
#              genuinely new run (a failed or cancelled run, or a re-committed
#              candidate after custody was returned).
#              When replacing a recorded no-mistakes attempt, retained custody,
#              an open hold, or failed admission refuses without replacing its
#              stage or observer bindings, rather than recording a pending stage.
#   running    The worker runs this as soon as the pipeline created the run.
#              It binds the actual run id through the observer (`bind`, under
#              bin/fm-nm-run-lib.sh's attribution rules; --run names it) and
#              records `validation-running` with the run id, canonical status,
#              and class. Candidate currentness uses the STALE_CANDIDATE rule
#              above, with pipeline custody owned by bin/fm-nm-run-lib.sh.
#   ci-ready   The worker runs this when the pipeline reports CI green. The
#              verdict is the producer qualification bin/fm-nm-run-lib.sh reads
#              for the exact run/head/branch/PR, never the worker's narration,
#              the command's exit status, or a status-log line; the observer's
#              `refresh` records the run's status and class beside it. Records
#              `ci-ready` with the PR and stops the worker: the configured merge
#              authority owns landing.
#   landing    Firstmate runs this when the configured merge authority is
#              landing the change (before bin/fm-pr-merge.sh or
#              bin/fm-merge-local.sh). Records `landing`; never merges anything.
#   activated  Firstmate runs this after landing to record the read-back:
#              the merge-notification marker bin/fm-pr-lib.sh writes with the PR
#              identity, or the candidate head reachable from the project
#              clone's checked-out head. No read-back refuses as NO_READBACK;
#              nothing here fetches, merges, or syncs.
#   show       Revalidates the recorded qualification first, so a revoked
#              qualification refuses before anything is printed; otherwise
#              prints the recorded stage and its `next:` line, then reconciles
#              canonical observations and admitted completion handoffs.
#              A worker resuming after a restart runs this first and continues
#              from the recorded stage.
#
# Engineering declarations are checked before stage effects and on resumed show;
# stage_context binds the canonical engineering JSON SHA256 for the admitted attempt;
# stage_evidence binds the admitted evidence-index bytes, refreshed even on a
# repeated CI-ready call when valid evidence changes. A supported new attempt
# replaces stage_context (including an empty context) and clears stage_evidence
# only after admission succeeds; tests/fm-stage.test.sh covers retry preservation.
# Status receipts include engineering (context hash) and residuals (open ids).
# CI-ready requires the declared local evidence at the current run/successor head;
# completed non-ancestor evidence requires the tooling owner's fresh successor
# proof and exact clean caller/preservation binding; sync-check may fetch its
# private ref but cannot move the caller. An exact full successor identity
# from the bound active pipeline-owned run need
# not have a commit object in the worker worktree (tests/fm-stage.test.sh).
# activated carries unfulfilled consumer obligations through work-context currentness.
# Task-record fields (this script is their only writer; docs/configuration.md
# routes the record's other owners):
#   stage=<stage>              stage_epoch=<epoch of the last transition>
#   stage_branch=<branch>      stage_head=<full candidate head>
#   stage_tree=<full tree>     stage_gen=<spawn_gen at the last transition>
#   stage_attempt=<observer attempt id>   stage_run=<bound run id>
#   stage_pr=<PR url>          stage_reason=<validation-pending reason, or the
#                                            activated read-back evidence>
#   stage_ci_ready_effect=<admitted CI-ready effect JSON with its revocable
#                          producer qualification, carried through landing and
#                          activated>
#   completion_handoff=<durable handoff contract/receipt; bin/fm-completion-lib.sh
#                       is the only writer, under this script's metadata lock>
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
# merge-authority), reason, engineering, residuals.
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
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

RETRY=0
REPLACING_ATTEMPT=0
RUN_ARG=
PR_ARG=
EXPECT_NM_HOME=
EXPECT_PATH0=
HANDOFF_JSON=
HANDOFF_IDENTITY=
CI_READY_META_LOCK=
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in --*) die_usage "--$want_value requires a value" ;; esac
    case "$want_value" in
      run) RUN_ARG=$a ;;
      pr) PR_ARG=$a ;;
      expect-nm-home) EXPECT_NM_HOME=$a ;;
      expect-path0) EXPECT_PATH0=$a ;;
      handoff-json) HANDOFF_JSON=$a ;;
      identity) HANDOFF_IDENTITY=$a ;;
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
    --handoff-json) want_value=handoff-json ;;
    --identity) want_value=identity ;;
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
# abandons it unless an existing run-custody proof applies.
candidate_current() {  # <recorded-head> <head> [ci-ready]
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 0
  git -C "$WT" merge-base --is-ancestor "$1" "$2" 2>/dev/null && return 0
  local output run_head
  output=$(bound_run_status) || return 1
  if fm_nm_run_is_pipeline_owned_active "$output"; then
    run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
    [ "$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null)" = "$2" ]
  else
    [ "${3:-}" = ci-ready ] && completed_successor_current "$output" "$2"
  fi
}

bound_run_status() {
  local run output
  run=$(obs run_id)
  [ -n "$run" ] && [ "$run" = "$(meta stage_run)" ] || return 1
  [ -n "$(meta stage_attempt)" ] && [ "$(meta stage_attempt)" = "$(obs attempt_id)" ] || return 1
  [ "$(meta stage_head)" = "$(obs candidate_head)" ] || return 1
  [ "$(meta stage_branch)" = "$(obs candidate_branch)" ] || return 1
  output=$(NM_HOME="$(obs nm_home)" fm_nm_run_checked "$WT" 10 axi status --run "$run") || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" id)")" = "$run" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" branch)")" = "$(meta stage_branch)" ] || return 1
  printf '%s\n' "$output"
}

# Only CI-ready may consume a completed successor. The bound run read comes
# from bound_run_status; sync-check supplies fresh qualification readback.
completed_successor_current() { # <bound-run-toon> <expected-current-head>
  local output=$1 head=$2 home proof run_head
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" status)")" = completed ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" outcome)")" = passed ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  [ "$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null)" = "$head" ] || return 1
  home=$(obs nm_home)
  case "$home" in /*) ;; *) return 1 ;; esac
  [ -d "$home" ] || return 1
  proof=$(NM_HOME="$home" fm_nm_run_checked "$WT" 10 axi sync --check) || return 1
  fm_nm_verified_terminal_successor "$WT" "$(obs run_id)" "$(meta stage_head)" "$head" "$(meta stage_branch)" "$proof"
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
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6 residuals=
  if [ -n "$FM_WC_ENGINEERING" ]; then
    residuals=$(fm_work_context_engineering_residuals "$DATA/$ID/work-context.json" | jq -sr 'map(.id) | join(",")')
  fi
  printf '%s: task=%s gen=%s branch=%s head=%s tree=%s intent=%s decisions=%s mode=%s yolo=%s alloc=%s nm_home=%s profile=%s attempt=%s run=%s step=%s outcome=%s pr=%s owner=%s reason=%s engineering=%s residuals=%s\n' \
    "$stage" "$ID" "$(enc "$GEN")" "$(enc "$branch")" "$(enc "$(short "$head")")" "$(enc "$(short "$tree")")" \
    "$(intent_identity)" "$(enc "$(closed_decision_keys)")" "$(enc "$MODE")" "$(enc "$YOLO")" "$(enc "$(alloc_identity)")" \
    "$(enc "$(obs nm_home)")" "$(enc "$(profile_identity)")" "$(enc "$(obs attempt_id)")" "$(enc "$(obs run_id)")" \
    "$(enc "$(obs run_status)")" "$(enc "$(obs outcome_class)")" "$(enc "$STAGE_PR_VALUE")" "$owner" "$(enc "$reason")" "$(enc "${FM_WC_ENGINEERING_DIGEST:-}")" "$(enc "$residuals")"
}

# Append the receipt, then publish the record. A crash between the two leaves a
# receipt without its record, and the next run appends it again: a bounded
# duplicate, never a lost transition.
issue() {  # <stage> <owner> <reason> <branch> <head> <tree> [extra key=value...]
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6 line tmp lock own_lock= kv ci_effect=
  shift 6
  line=$(receipt_line "$stage" "$owner" "$reason" "$branch" "$head" "$tree")
  lock=$(fm_meta_lock_path "$META") || exit 2
  if [ "$lock" != "$CI_READY_META_LOCK" ]; then
    fm_lock_acquire_wait "$lock"
    own_lock=$lock
  fi
  tmp="$STATE/.$ID.meta.stage.${BASHPID:-$$}"
  if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
    [ "$lock" = "$CI_READY_META_LOCK" ] || fm_lock_release "$lock"
    echo "error: task record for $ID is unsafe ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 2
  fi
  if [ "$stage" = ci-ready ]; then
    for kv in "$@"; do
      case "$kv" in stage_ci_ready_effect=*) ci_effect=${kv#*=} ;; esac
    done
    if ! printf '%s' "$ci_effect" | jq -se --arg task "$ID" --arg generation "$(meta spawn_gen)" \
      --arg attempt "$(meta stage_attempt)" --arg run "$(meta stage_run)" --arg candidate "$(meta stage_head)" '
      length == 1 and (.[0] | .task == $task and .generation == $generation and .attempt == $attempt and
      .run == $run and .candidate == $candidate)
    ' >/dev/null 2>&1; then
      [ "$lock" = "$CI_READY_META_LOCK" ] || fm_lock_release "$lock"
      refuse ci-ready STALE_BINDING 'task identity changed during qualification'
    fi
  fi
  case "$stage" in
    ci-ready)
      NM_HOME="$(obs nm_home)" NO_MISTAKES_HOME="$(obs nm_home)" fm_nm_qualification_read \
        "$WT" "$(meta stage_run)" "$(printf '%s' "$ci_effect" | jq -r .source_head)" \
        "$(meta stage_branch)" "$(printf '%s' "$ci_effect" | jq -r .pr)" \
        "$(printf '%s' "$ci_effect" | jq -c .qualification)" >/dev/null \
        || refuse ci-ready QUALIFICATION_REVOKED 'exact producer qualification changed before publication'
      ;;
    landing|activated) require_current_qualification "$stage" "$STAGE_PR_VALUE" "$own_lock" ;;
  esac
  case "$stage" in
    ci-ready|landing|activated)
      [ -n "$ci_effect" ] || ci_effect=$(meta stage_ci_ready_effect)
      if [ -n "$ci_effect" ]; then
        line="$line qualification=revocable qualified_head=$(printf '%s' "$ci_effect" | jq -r .source_head)"
      fi ;;
  esac
  if [ "$stage" = ci-ready ] && [ -n "$HANDOFF_IDENTITY" ]; then
    fm_completion_report_current "$contract" || exit 1
  fi
  printf '%s\n' "$line" >> "$STATUS"
  grep -v -e '^stage=' -e '^stage_' "$META" > "$tmp" || true
  {
    printf 'stage=%s\n' "$stage"
    printf 'stage_epoch=%s\n' "$(now_epoch)"
    printf 'stage_branch=%s\n' "$branch"
    printf 'stage_head=%s\n' "$head"
    printf 'stage_tree=%s\n' "$tree"
    printf 'stage_gen=%s\n' "$GEN"
    printf 'stage_context=%s\n' "$FM_WC_ENGINEERING_DIGEST"
    if [ "$stage" = candidate-committed ]; then
      printf 'stage_evidence=\n'
    else
      printf 'stage_evidence=%s\n' "${FM_WC_ENGINEERING_EVIDENCE_DIGEST:-$(meta stage_evidence)}"
    fi
    case "$stage" in
      landing|activated) printf 'stage_ci_ready_effect=%s\n' "$(meta stage_ci_ready_effect)" ;;
    esac
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } >> "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
    rm -f -- "$tmp"
    [ "$lock" = "$CI_READY_META_LOCK" ] || fm_lock_release "$lock"
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 2
  fi
  [ "$lock" = "$CI_READY_META_LOCK" ] || fm_lock_release "$lock"
  printf 'STAGE: %s\n' "$line"
}

unchanged() {  # <stage>
  case "$1" in ci-ready|landing|activated) require_current_qualification "$1" ;; esac
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
      if [ -n "$FM_WC_ENGINEERING" ]; then
        fm_work_context_engineering_render "$DATA" "$ID" all all || refuse validation-admitted ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
        printf 'intent: include this checked engineering context and its verification obligations in the existing no-mistakes --intent; its review owner loads the reviewer source.\n'
      fi
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

# Reuse the work-context owner at existing stage boundaries. The canonical
# engineering hash survives every transition; deleting/changing an admitted
# declaration cannot downgrade its obligations. Only a supported new attempt
# may accept a changed context, after custody returns to the worker.
engineering_context() { # <transition>
  local transition=$1 pin
  fm_work_context_engineering "$DATA" "$ID" all all || refuse "$transition" ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
  pin=$(meta stage_context)
  if [ -n "$pin" ] && [ "$pin" != "$FM_WC_ENGINEERING_DIGEST" ]; then
    if [ "$transition" != committed ] || [ "$RETRY" -ne 1 ]; then
      refuse "$transition" ENGINEERING_CONTEXT 'stale engineering context; retain the admitted contract or settle custody and admit a new attempt'
    fi
  fi
}

# The canonical run head, revalidated at every consuming boundary: only
# CI-ready calls this, so a completed (non-active) run may be consumed as a
# candidate successor only through the tooling owner's fresh proof in
# completed_successor_current.
canonical_run_head() {
  local output run_head
  output=$(bound_run_status) || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  [[ "$run_head" =~ ^[0-9a-f]{40}$ ]] || return 1
  if ! fm_nm_run_is_pipeline_owned_active "$output"; then
    fm_nm_head_matches_worktree "$WT" "$run_head" || return 1
    git -C "$WT" merge-base --is-ancestor "$(meta stage_head)" "$run_head" 2>/dev/null \
      || completed_successor_current "$output" "$run_head" || return 1
  fi
  printf '%s\n' "$run_head"
}

engineering_result() {
  local run actual=$1
  [ -n "$FM_WC_ENGINEERING" ] || return 0
  run=$(obs run_id)
  fm_work_context_engineering_evidence "$DATA" "$ID" "$run" "$actual" \
    || refuse ci-ready ENGINEERING_EVIDENCE "$FM_WORK_CONTEXT_DETAIL"
  if [ -f "$DATA/$ID/engineering-evidence.json" ]; then
    FM_WC_ENGINEERING_EVIDENCE_DIGEST=$(_fm_wc_engineering_sha "$DATA/$ID/engineering-evidence.json") \
      || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-unreadable: index changed during admission'
  fi
}

# --- transitions ------------------------------------------------------------

do_committed() {
  local current recorded_head output holds
  require_ship committed
  engineering_context committed
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
  if [ "$RETRY" -eq 1 ] && [ "$MODE" = no-mistakes ] && [ -n "$current" ]; then
    if [ -n "$(obs run_id)" ]; then
      output=$(bound_run_status) || refuse committed NOT_ADMITTED 'cannot verify custody of the bound run'
      if fm_nm_run_is_active "$output" || [ "$(fm_nm_branch_sync_state "$output")" = pipeline_owned ]; then
        refuse committed RUN_ACTIVE 'the bound run retains custody; existing stage bindings preserved'
      fi
    fi
    holds=$(open_hold_keys)
    [ -z "$holds" ] || refuse committed HOLD_APPEARED "hold:$holds prevents retry admission; existing stage bindings preserved"
    REPLACING_ATTEMPT=1
    admit_validation
    return 0
  fi
  if [ -z "$current" ] || [ "$(meta stage_context)" != "$FM_WC_ENGINEERING_DIGEST" ] || [ "$recorded_head" != "$HEAD" ] || [ "$(meta stage_branch)" != "$BRANCH" ] \
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
  [ "$REPLACING_ATTEMPT" -eq 0 ] || refuse validation-admitted NOT_ADMITTED "$reason; existing stage bindings preserved"
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
  if [ "$REPLACING_ATTEMPT" -eq 1 ]; then
    set -- "$@" --expect-head "$HEAD" --expect-tree "$TREE" --expect-branch "$BRANCH"
  fi
  [ "$RETRY" -eq 0 ] || set -- "$@" --retry
  [ -z "$EXPECT_NM_HOME" ] || set -- "$@" --expect-nm-home "$EXPECT_NM_HOME"
  [ -z "$EXPECT_PATH0" ] || set -- "$@" --expect-path0 "$EXPECT_PATH0"
  observe "$@"
  case "$OBS_RC" in
    0) ;;
    1)
      case "$OBS_OUT" in
        *STALE_CANDIDATE*) refuse validation-admitted STALE_CANDIDATE "$OBS_OUT" ;;
        *HOLD_APPEARED*) refuse validation-admitted HOLD_APPEARED "$OBS_OUT" ;;
        *PREFLIGHT_REFUSED*) pending "capacity:$(printf '%s' "$OBS_OUT" | grep -o 'PREFLIGHT_REFUSED.*' | head -1)"; return 0 ;;
        *RUN_BOUND*) refuse validation-admitted RUN_ACTIVE "an active run is already bound to this task ($OBS_OUT); continue that run and record it with \`$SELF_CMD running\`" ;;
        *) refuse validation-admitted NOT_ADMITTED "$OBS_OUT" ;;
      esac ;;
    *) echo "error: bin/fm-nm-observe.sh launch failed (exit $OBS_RC): $OBS_OUT" >&2; exit 2 ;;
  esac
  attempt=$(obs attempt_id)
  [ -n "$attempt" ] || refuse validation-admitted NOT_ADMITTED "the observer accepted the launch but recorded no attempt id"
  if [ "$REPLACING_ATTEMPT" -eq 0 ]; then
    # Revalidate immediately before issuing: the head, the tree, and the fold.
    head2=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
    tree2=$(git -C "$WT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
    if [ "$head2" != "$HEAD" ] || [ "$tree2" != "$TREE" ] || worktree_dirty; then
      refuse validation-admitted STALE_CANDIDATE "the candidate changed during admission (recorded $(short "$HEAD"), now $(short "$head2")); commit and re-run"
    fi
    holds=$(open_hold_keys)
    [ -z "$holds" ] || refuse validation-admitted HOLD_APPEARED "hold:$holds opened during admission; re-run once it is resolved"
  fi
  if [ "$REPLACING_ATTEMPT" -eq 1 ]; then
    issue candidate-committed worker "" "$BRANCH" "$HEAD" "$TREE"
  fi
  if [ "$(meta stage)" = validation-admitted ] && [ "$(meta stage_attempt)" = "$attempt" ] && [ "$(meta stage_head)" = "$HEAD" ]; then
    unchanged validation-admitted
  else
    issue validation-admitted worker "" "$BRANCH" "$HEAD" "$TREE" "stage_attempt=$attempt"
  fi
  next_for validation-admitted
}

do_running() {  # <transition-label>
  local label=${1:-running} current run
  engineering_context "$label"
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

do_ci_ready() (
  local current effect saved contract qualified_head qualification CI_READY_META_LOCK=
  CI_READY_META_LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait "$CI_READY_META_LOCK"
  trap 'fm_lock_release "$CI_READY_META_LOCK"' EXIT
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$GEN" = "$(meta spawn_gen)" ] \
    || refuse ci-ready STALE_BINDING 'task identity changed before qualification'
  if [ -n "$HANDOFF_IDENTITY" ]; then
    # shellcheck source=bin/fm-completion-lib.sh
    . "$SCRIPT_DIR/fm-completion-lib.sh"
    saved=$(meta completion_handoff)
    fm_completion_saved_valid "$saved" \
      && [ "$(printf '%s' "$saved" | jq -r .identity)" = "$HANDOFF_IDENTITY" ] \
      || refuse ci-ready STALE_BINDING 'admitted completion identity changed before qualification'
    contract=$(printf '%s' "$saved" | jq -c .contract)
    fm_completion_report_current "$contract" || exit 1
    printf '%s' "$saved" | jq -e --arg task "$ID" --arg pr "$PR_ARG" '
      .released == true and .contract.action.kind == "ci-ready" and
      .contract.action.owner == $task and .contract.action.generation == .contract.generation and
      .contract.action.pr == $pr
    ' >/dev/null || refuse ci-ready STALE_BINDING 'completion action does not authorize this transition'
  fi
  require_ship ci-ready
  engineering_context ci-ready
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
  candidate_current "$(meta stage_head)" "$HEAD" ci-ready \
    || refuse ci-ready STALE_CANDIDATE "recorded candidate $(short "$(meta stage_head)") is not an ancestor of head $(short "$HEAD")"
  qualified_head=$(canonical_run_head) \
    || refuse ci-ready STALE_BINDING 'run head is missing, unreadable, or not attributable to this candidate'
  qualification=$(NM_HOME="$(obs nm_home)" NO_MISTAKES_HOME="$(obs nm_home)" fm_nm_qualification_read \
    "$WT" "$(meta stage_run)" "$qualified_head" "$(meta stage_branch)" "$PR_ARG") \
    || refuse ci-ready NOT_CI_READY 'exact producer qualification unavailable or invalidated'
  if [ -n "$HANDOFF_IDENTITY" ]; then
    [ "$qualified_head" = "$(printf '%s' "$contract" | jq -r .source_head)" ] \
      || refuse ci-ready STALE_BINDING 'qualified head differs from admitted completion'
  fi
  observe refresh "$ID"
  engineering_result "$qualified_head"
  STAGE_PR_VALUE=$PR_ARG
  effect=$(jq -cn --arg task "$ID" --arg generation "$GEN" --arg attempt "$(obs attempt_id)" \
    --arg run "$(obs run_id)" --arg candidate "$(meta stage_head)" --arg source_head "$qualified_head" --arg pr "$PR_ARG" --argjson qualification "$qualification" \
    '{qualification:$qualification,task:$task,generation:$generation,attempt:$attempt,run:$run,candidate:$candidate,source_head:$source_head,pr:$pr}') || exit 1
  if [ -n "$HANDOFF_IDENTITY" ]; then
    fm_completion_report_current "$contract" || exit 1
  fi
  if [ "$current" = ci-ready ] && [ "$(meta stage_ci_ready_effect)" = "$effect" ] && [ "$(meta stage_pr)" = "$PR_ARG" ] \
      && [ "$(meta stage_evidence)" = "${FM_WC_ENGINEERING_EVIDENCE_DIGEST:-$(meta stage_evidence)}" ]; then
    unchanged ci-ready
  else
    issue ci-ready merge-authority "" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(obs attempt_id)" "stage_run=$(obs run_id)" "stage_pr=$PR_ARG" "stage_ci_ready_effect=$effect"
  fi
  require_current_qualification ci-ready
  next_for ci-ready
)

# A no-mistakes task may neither enter nor remain in a qualified stage without
# current producer qualification. Binding a validation run is not entering one.
qualification_applies() {  # <transition>
  fm_nm_recorded_qualification_obligated "$META" && return 0
  case "$1" in
    ci-ready|landing|activated) grep -qx 'mode=no-mistakes' "$META" ;;
    *) return 1 ;;
  esac
}

# Historical stage labels never substitute for current producer qualification.
require_current_qualification() {  # <transition> [expected PR] [lock to release before refusing]
  local expected_pr=${2:-$(meta stage_pr)} held_lock=${3:-}
  if qualification_applies "$1"; then
    if ! fm_nm_effect_current "$META" "$expected_pr" >/dev/null; then
      [ -z "$held_lock" ] || fm_lock_release "$held_lock"
      refuse "$1" QUALIFICATION_REVOKED 'exact stage qualification is missing or no longer current; historical record retained'
    fi
  fi
}

do_landing() {
  local current
  require_ship landing
  engineering_context landing
  current=$(meta stage)
  [ -n "$current" ] || refuse landing NOT_ADMITTED "no candidate is recorded"
  [ -z "$PR_ARG" ] || fm_pr_url_parse "$PR_ARG" >/dev/null 2>&1 || refuse landing BAD_PR "not a canonical PR URL: $PR_ARG"
  if [ -n "$PR_ARG" ] && [ "$PR_ARG" != "$(meta stage_pr)" ] && qualification_applies landing; then
    refuse landing DESTINATION_MISMATCH "--pr $PR_ARG is not the qualified destination $(dash "$(meta stage_pr)"); landing carries the destination CI-ready qualified"
  fi
  [ "$current" != activated ] || { unchanged activated; next_for activated; return 0; }
  require_current_qualification landing
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
      if fm_nm_recorded_qualification_obligated "$META"; then
        fm_pr_url_parse "$(meta stage_pr)" >/dev/null 2>&1 || return 1
        [ "$provider" = "$FM_PR_PROVIDER" ] && [ "$host" = "$FM_PR_HOST" ] \
          && [ "$path" = "$FM_PR_PATH" ] && [ "$number" = "$FM_PR_NUMBER" ] || return 1
      fi
      printf 'merged:%s:%s:%s:%s' "$provider" "$host" "$path" "$number"
      return 0
    fi
  fi
  head=$(meta stage_head)
  if fm_nm_recorded_qualification_obligated "$META"; then
    head=$(fm_nm_effect_current "$META" | jq -er .head) || return 1
  fi
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
  jq -e '.reconcile != null or .engineering != null' "$desc" >/dev/null 2>&1 || return 0
  # The stage transition is already the authority; a reconcile that cannot
  # confirm records the discrepancy in the receipt rather than failing the stage.
  fm_work_context_reconcile "$STATE" "$DATA" "$ID" "$transition" || true
  printf 'currentness: %s (%s)\n' "${FM_WORK_CONTEXT_RECONCILE:-unknown}" "${FM_WORK_CONTEXT_DETAIL:-}"
  return 0
}

do_activated() {
  local current evidence
  require_ship activated
  engineering_context activated
  current=$(meta stage)
  [ -n "$current" ] || refuse activated NOT_ADMITTED "no candidate is recorded"
  require_current_qualification activated
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
  case "$(meta stage)" in ci-ready|landing|activated) require_current_qualification show ;; esac
  engineering_context show
  fm_work_context_engineering_render "$DATA" "$ID" all all || refuse show ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
  local current
  current=$(meta stage)
  printf 'STAGE_RECORDED: %s task=%s gen=%s branch=%s head=%s attempt=%s run=%s pr=%s reason=%s\n' \
    "${current:-none}" "$ID" "$(dash "$(meta stage_gen)")" "$(dash "$(meta stage_branch)")" \
    "$(dash "$(short "$(meta stage_head)")")" "$(dash "$(meta stage_attempt)")" "$(dash "$(meta stage_run)")" \
    "$(dash "$(meta stage_pr)")" "$(dash "$(meta stage_reason)")"
  next_for "$current"
}

case "$TRANSITION" in
  handoff|handoff-release|resume-handoff)
    # shellcheck source=bin/fm-task-inbox-lib.sh
    . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
    # shellcheck source=bin/fm-completion-lib.sh
    . "$SCRIPT_DIR/fm-completion-lib.sh"
    fm_completion_transition "$TRANSITION"
    exit $? ;;
  committed) do_committed ;;
  running) do_running running ;;
  ci-ready) do_ci_ready ;;
  landing) do_landing ;;
  activated) do_activated ;;
  show) do_show ;;
  *) die_usage "unknown transition '$TRANSITION'" ;;
esac

if [ "${FM_COMPLETION_RECONCILING:-0}" != 1 ] && {
  [ -n "$(meta completion_handoff)" ] || { [ "$TRANSITION" = show ] && [ -f "$OBLIGATION" ]; }
}; then
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  # shellcheck source=bin/fm-completion-lib.sh
  . "$SCRIPT_DIR/fm-completion-lib.sh"
  fm_completion_transition resume-handoff
fi
