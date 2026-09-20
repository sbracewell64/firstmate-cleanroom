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
#   FM_HOME=<home> fm-stage.sh <task-id> successor
#   FM_HOME=<home> fm-stage.sh <task-id> running [--run <run-id>]
#   FM_HOME=<home> fm-stage.sh <task-id> ci-ready --pr <url>
#   FM_HOME=<home> fm-stage.sh <task-id> landing [--pr <url>]
#   FM_HOME=<home> fm-stage.sh <task-id> activated
#   FM_HOME=<home> fm-stage.sh <task-id> show
#   fm-stage.sh --help
#
# Stages, in order:
#   candidate-committed -> validation-pending | validation-admitted
#                       -> validation-running -> [candidate-successor] -> ci-ready
#                       -> landing -> activated
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
# an authenticated successor issued by this owner), SUCCESSOR_REQUIRED,
# SUCCESSOR_CNO (an identity could not be evaluated), SUCCESSOR_CONTRADICTION,
# SUCCESSOR_COLLISION, NOT_ADMITTED, RUN_ACTIVE, HOLD_APPEARED, MISSING_BINDING, DAEMON_RESET,
# RUN_BOUND, NOT_CI_READY, BAD_PR, NO_READBACK, ENGINEERING_CONTEXT,
# ENGINEERING_EVIDENCE, CONFLICTING_RECORD (the task record holds more than one
# value for a single-valued key, so it has no single stage to read or advance).
# Exit 2 is a usage error or an unreadable record.
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
#   successor  Explicitly mints the one deterministic replacement branch after
#              a terminal validation makes its predecessor branch non-reusable.
#              It never starts a run. CI-ready issues the same typed transition
#              in-place when one already-bound run proves an exact synchronized,
#              attested, checks-green pipeline successor.
#   running    The worker runs this as soon as the pipeline created the run.
#              It binds the actual run id through the observer (`bind`, under
#              bin/fm-nm-run-lib.sh's attribution rules; --run names it) and
#              records `validation-running` with the run id, canonical status,
#              and class. Candidate currentness uses the STALE_CANDIDATE rule
#              above, with pipeline custody owned by bin/fm-nm-run-lib.sh.
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
#              It is also the one transition that resolves the landed head, and
#              it records what it found: the head validation started from is not
#              the head that lands whenever the pipeline advanced the candidate,
#              so the record and the receipt name both, and neither by
#              inference. Field schema below; resolve_landed_head owns the
#              evidence order and why an unproven head stays unresolved.
#   activated  Firstmate runs this after landing to record the read-back:
#              the merge-notification marker bin/fm-pr-lib.sh writes with the PR
#              identity, or the LANDED head reachable from the project clone's
#              INTEGRATION branch (landed_integration_proof owns which refs
#              answer that), falling back to the candidate head when the landed
#              head is absent or cannot be proven. No read-back at all refuses
#              as NO_READBACK; nothing here fetches, merges, or syncs.
#              Whether the captured landed head was itself proven is recorded
#              apart, in stage_landed_head_confirmed, so proceeding on the
#              candidate head never reads as having confirmed the landed one.
#   show       Prints the recorded stage and its `next:` line; changes nothing.
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
#   stage_branch=<branch>      stage_head=<full current candidate head; advances
#                                          only through candidate-successor>
#   stage_landed_head=<full head that actually LANDED, captured by the first
#                      landing that records a source and never replaced; empty
#                      when that landing could prove none>
#   stage_landed_head_source=<which evidence proved stage_landed_head: pr-head,
#                      worktree, or unresolved. As durable as the head itself,
#                      because it is what a later reader needs to judge how well
#                      that head is proven. Nothing consumes it as a ranking:
#                      the capture is never replaced, whatever its source>
#   stage_landed_head_confirmed=<what activation could prove about the captured
#                      landed head, written by `activated` alone: confirmed (an
#                      activation proved it reachable from the project clone's
#                      INTEGRATION branch - a fact about that moment, not a claim
#                      that it is reachable now), unconfirmed (a head is captured
#                      and activation could not prove it, so the read-back below
#                      came from elsewhere), or
#                      none (no landed head is captured, so there is nothing to
#                      confirm). A typed value rather than prose, so a consumer
#                      can find an activation with an unconfirmed landed head by
#                      matching rather than by reading. Only ever moves upward;
#                      a recorded `confirmed` is never taken back>
#   stage_tree=<full tree>     stage_gen=<spawn_gen at the last transition>
#   stage_discipline=<level@generation@fragment identity; immutable across retry>
#   stage_attempt=<current observer attempt id>   stage_run=<current bound run id>
#   stage_duty=validation       stage_alloc=<harness/model/effort/backend>
#   stage_predecessor_{branch,head,tree,attempt,run,duty,alloc}=<immutable admitted predecessor>
#   stage_successor_{id,gen,branch,head,tree,ref,attempt,run,alloc,pipeline_submitted_head,
#                    pipeline_current_head,pipeline_pushed_head,local_head,
#                    remote_head,sync_state,relation,push_generation,target_kind,
#                    authority,action,pr,attested_head,checked_head,qualification,input_sha}=
#                    <one immutable successor transition and its read-back lineage>
#   stage_pr=<PR url>          stage_reason=<validation-pending reason, the
#                                            landing `landed-head:<source>`
#                                            provenance naming which evidence
#                                            supplied stage_landed_head, or the
#                                            activated read-back evidence. This is the
#                                            human-readable rendering; the
#                                            durable provenance lives in
#                                            stage_landed_head_source>
#
# The record carries stage_head and stage_landed_head apart because both facts
# are real and neither is derivable from the other: validation starts at one
# head and, when the pipeline admits a successor, lands at another. A record
# naming only the submitted head asserts a landing that did not happen. The
# landed head is CAPTURED at landing, not recomputed on later reads: the values
# it is resolved from (pr_head= from bin/fm-pr-check.sh, the task worktree head)
# are live mutable state owned by other writers and may move or vanish after the
# landing, so a record that re-derived the fact would be a lookup that happens
# to agree today rather than a record of what happened. resolve_landed_head
# below owns how a capture is made and why nothing ever replaces it.
#
# ONE ANSWER PER QUESTION, AND NOT-KNOWN IS ONE OF THEM. Stated once here, at
# the owner of these records, because every guard in this file depends on it: a
# read failure, a missing input, a malformed input, a predicate that cannot be
# evaluated, and a fact that cannot be re-proven right now are EACH THEIR OWN
# ANSWER. None of them may collapse into a pass, into a miss, or into evidence
# against a fact already proven. A guard that cannot see is not a guard that
# saw nothing wrong.
# Receipt fields, in this order on every stage line (`-` when not applicable;
# values percent-encode space, percent, and tab, and the classifier decodes
# them): task, gen (worker epoch: the record's spawn_gen), branch, head,
# landed_head (the head that landed, `-` when this transition resolves none),
# landed_confirmed (stage_landed_head_confirmed, `-` outside activation), tree
# (12-character prefixes; the record holds the full ids), intent (12-character
# SHA-256 of data/<id>/brief.md plus data/<id>/ship-instructions.md when
# present: the accepted intent identity), decisions (comma-separated keys of
# decisions this task opened that are now closed), mode, yolo, alloc
# (harness/model/effort/backend: the admitted resource allocation), nm_home,
# profile (<no-mistakes version>+<build> from the observer's qualified-profile
# read), attempt, run, step (the run's canonical status), outcome (the
# observer's outcome class), pr, owner (who acts next: worker, firstmate, or
# merge-authority), reason, engineering, discipline (selected
# level@generation@fragment), discipline_proof (OBSERVED, CNO or absent), and
# residuals.
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
  echo "usage: FM_HOME=<home> fm-stage.sh <task-id> committed|successor|running|ci-ready|landing|activated|show [flags] | --help" >&2
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
# fm_default_branch, the owner of which branch a checkout integrates onto.
# shellcheck source=bin/fm-tangle-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

RETRY=0
REPLACING_ATTEMPT=0
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

# A record holding two values for one key answers the stage question twice, and
# reading either answer here would publish a lifecycle fact this script cannot
# prove. Refuse before any read, so `show` and every transition report the same
# conflict instead of each resolving it by position. A record whose bytes could
# not be read is refused too and never treated as clean: unproven is its own
# answer, and it is an unreadable record rather than a conflicted one.
# (bin/fm-backlog-transition-lib.sh owns what counts as duplicated.)
META_DUP_RC=0
META_DUP=$(fm_meta_duplicate_key "$META") || META_DUP_RC=$?
case "$META_DUP_RC" in
  0)
    printf 'STAGE_REFUSED: transition=%s task=%s reason=CONFLICTING_RECORD the task record holds more than one %s= value; it has no single %s, and nothing may be read from or written to it until the record is reconciled against the evidence\n' \
      "$TRANSITION" "$ID" "$META_DUP" "$META_DUP"
    exit 1
    ;;
  2)
    echo "error: task record for $ID could not be read ($META); whether it holds one value per key is unproven" >&2
    exit 2
    ;;
esac

meta() { fm_meta_get "$META" "$1"; }
obs() { [ -f "$OBLIGATION" ] || return 0; grep "^$1=" "$OBLIGATION" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
now_epoch() { date +%s; }
short() { printf '%s' "${1:0:12}"; }
enc() {  # percent-encode space, percent, tab; a value is never multi-line
  [ -n "$1" ] || { printf -- '-'; return 0; }
  printf '%s' "$1" | tr -d '\n' | sed -e 's/%/%25/g' -e 's/ /%20/g' -e "s/$(printf '\t')/%09/g"
}
dash() { [ -n "${1:-}" ] && printf '%s' "$1" || printf -- '-'; }
discipline_identity() {
  [ -n "${FM_DISCIPLINE_RECEIPT:-}" ] || return 0
  printf '%s@%s@%s' "$FM_DISCIPLINE_LEVEL" "$FM_DISCIPLINE_GENERATION" "$FM_DISCIPLINE_FRAGMENT_SHA256"
}

KIND=$(meta kind); [ -n "$KIND" ] || KIND=ship
MODE=$(meta mode)
YOLO=$(meta yolo)
WT=$(meta worktree)
PROJECT=$(meta project)
GEN=$(meta spawn_gen)
SELF_CMD="FM_HOME=$(printf '%q' "$FM_HOME") $(printf '%q' "$SCRIPT_DIR/fm-stage.sh") $(printf '%q' "$ID")"
STAGE_PR_VALUE=
SUCCESSOR_STATUS=
SI_GEN=
SI_PREDECESSOR_BRANCH=
SI_PREDECESSOR_HEAD=
SI_PREDECESSOR_TREE=
SI_PREDECESSOR_ATTEMPT=
SI_PREDECESSOR_RUN=
SI_PREDECESSOR_DUTY=
SI_PREDECESSOR_ALLOC=
SI_BRANCH=
SI_HEAD=
SI_TREE=
SI_REF=
SI_ATTEMPT=
SI_RUN=
SI_ALLOC=
SI_ACTION=
SI_AUTHORITY=
SI_PR=
SI_ATTESTED=
SI_CHECKED=
SI_QUALIFICATION=
SI_PIPELINE_SUBMITTED=
SI_PIPELINE_CURRENT=
SI_PIPELINE_PUSHED=
SI_LOCAL=
SI_REMOTE=
SI_SYNC=
SI_RELATION=
SI_PUSH_GENERATION=
SI_TARGET_KIND=
SUCCESSOR_STATUS=
SUCCESSOR_SYNC=
SUCCESSOR_ATTESTED_HEAD=
SUCCESSOR_CHECKED_HEAD=
SUCCESSOR_ID=
SUCCESSOR_INPUT_SHA=
STAGE_LANDED_HEAD=
STAGE_LANDED_HEAD_SOURCE=
STAGE_LANDED_HEAD_CONFIRMED=
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

stage_predecessor_head() {
  local value
  value=$(meta stage_predecessor_head)
  if [ -n "$value" ]; then printf '%s' "$value"; else meta stage_head; fi
}

stage_predecessor_branch() {
  local value
  value=$(meta stage_predecessor_branch)
  if [ -n "$value" ]; then printf '%s' "$value"; else meta stage_branch; fi
}

stage_predecessor_attempt() {
  local value
  value=$(meta stage_predecessor_attempt)
  if [ -n "$value" ]; then printf '%s' "$value"; else meta stage_attempt; fi
}

stage_predecessor_run() {
  local value
  value=$(meta stage_predecessor_run)
  if [ -n "$value" ]; then printf '%s' "$value"; else meta stage_run; fi
}

# 0 when the current candidate is equal to or descends from the stage owner's
# current head. A non-ancestor can advance only through candidate-successor.
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

# 0 when the advanced live head is exactly the clean descendant this terminal
# bound run carried and its own PR attests, 1 for a readable disagreement, and 2
# when that identity cannot be evaluated. Descent alone never qualifies: it
# proves the worker built on the predecessor, not that the pipeline ever saw it.
identified_terminal_descendant() { # <bound-run-toon> <branch> <predecessor-head> <head>
  local output=$1 branch=$2 predecessor=$3 head=$4 run_head pr rc
  git -C "$WT" merge-base --is-ancestor "$predecessor" "$head" 2>/dev/null || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  [[ "$run_head" =~ ^[0-9a-f]{40}$ ]] || return 2
  [ "$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null)" = "$head" ] || return 1
  pr=$(fm_nm_strip_quotes "$(fm_nm_field "$output" pr)")
  [ -n "$pr" ] || return 2
  fm_pr_url_parse "$pr" >/dev/null 2>&1 || return 2
  rc=0
  successor_pr_attestation "$pr" "$branch" "$head" any || rc=$?
  return "$rc"
}

bound_run_uses_predecessor() {
  [ "$(meta stage_successor_action)" = authenticated-synchronized-successor ] \
    || { [ "$(meta stage_successor_action)" = mint-validation-branch ] && [ "$(meta stage)" = candidate-successor ]; }
}

bound_run_status() {
  local run output duty expected_head expected_branch
  run=$(obs run_id)
  duty=$(meta stage_duty)
  [ -z "$duty" ] || [ "$duty" = validation ] || return 1
  [ -n "$run" ] && [ "$run" = "$(meta stage_run)" ] || return 1
  [ -n "$(meta stage_attempt)" ] && [ "$(meta stage_attempt)" = "$(obs attempt_id)" ] || return 1
  if bound_run_uses_predecessor; then
    [ "$run" = "$(stage_predecessor_run)" ] || return 1
    [ "$(stage_predecessor_attempt)" = "$(obs attempt_id)" ] || return 1
    expected_head=$(stage_predecessor_head)
    expected_branch=$(stage_predecessor_branch)
  else
    expected_head=$(meta stage_head)
    expected_branch=$(meta stage_branch)
  fi
  [ "$expected_head" = "$(obs candidate_head)" ] || return 1
  [ "$expected_branch" = "$(obs candidate_branch)" ] || return 1
  [ "$(obs entrypoint)" = stage ] || return 1
  output=$(NM_HOME="$(obs nm_home)" fm_nm_run_checked "$WT" 10 axi status --run "$run") || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" id)")" = "$run" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" branch)")" = "$expected_branch" ] || return 1
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

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

base64_decode() {
  local payload
  payload=$(cat)
  printf '%s' "$payload" | base64 --decode 2>/dev/null && return 0
  printf '%s' "$payload" | base64 -D 2>/dev/null
}

# gh-axi wraps a non-JSON --jq result in an api_response envelope and truncates
# the raw body past its own limit, so the row carries only the small facts the
# attestation is read from - never the whole PR description, which routinely
# exceeds that limit. A truncated envelope is unevaluable, never a disagreement.
gh_axi_pr_row() { # <canonical GitHub PR URL>
  local output encoded truncated
  command -v gh-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_pr_url_parse "$1" >/dev/null 2>&1 || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  output=$(gh-axi api "/repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER" --jq \
    '[.number, .state, .merged, .head.sha, .head.ref, .html_url,
      ((.body // "") | contains("Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)")),
      ((.body // "") | split("<!-- no-mistakes-pipeline-attestation:v1 ")[1] // "" | split(" -->")[0] | @base64)] | @tsv' 2>/dev/null) || return 1
  truncated=$(printf '%s\n' "$output" | sed -n 's/^  truncated: //p' | head -1)
  [ "$truncated" = false ] || return 1
  encoded=$(printf '%s\n' "$output" | sed -n 's/^  body: //p' | head -1)
  [ -n "$encoded" ] || return 1
  printf '%s' "$encoded" | jq -r . 2>/dev/null
}

# <state-policy> is `open` (the default) when only a live open PR may attest, or
# `any` when a merged or closed PR still names the head it carried.
successor_pr_attestation() { # <url> <branch> <head> [state-policy]; sets SUCCESSOR_ATTESTED_HEAD
  local row number state merged head branch url pipeline block64 block
  row=$(gh_axi_pr_row "$1") || return 2
  IFS=$(printf '\t') read -r number state merged head branch url pipeline block64 <<EOF
$row
EOF
  [ -n "$number" ] && [ -n "$pipeline" ] || return 2
  fm_pr_url_parse "$1" >/dev/null 2>&1 || return 2
  [ "$number" = "$FM_PR_NUMBER" ] && [ "$url" = "$1" ] || return 1
  [ "${4:-open}" = any ] || { [ "$state" = open ] && [ "$merged" = false ]; } || return 1
  [ "$head" = "$3" ] && [ "$branch" = "$2" ] || return 1
  [ "$pipeline" = true ] || return 1
  [ -n "$block64" ] || return 1
  block=$(printf '%s' "$block64" | base64_decode) || return 2
  [ -n "$block" ] || return 1
  SUCCESSOR_ATTESTED_HEAD=$(printf '%s' "$block" | sed -n 's/.*"head_sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
  [ "$SUCCESSOR_ATTESTED_HEAD" = "$3" ]
}

# Returns 0 for an exact match, 1 for a readable contradiction, and 2 when a
# required status identity cannot be evaluated.
successor_status_matches() { # <status-toon> <run> <branch> <head> <pr>
  local output=$1 run=$2 branch=$3 head=$4 pr=$5 actual run_head status outcome
  actual=$(fm_nm_strip_quotes "$(fm_nm_field "$output" id)"); [ -n "$actual" ] || return 2
  [ "$actual" = "$run" ] || return 1
  actual=$(fm_nm_strip_quotes "$(fm_nm_field "$output" branch)"); [ -n "$actual" ] || return 2
  [ "$actual" = "$branch" ] || return 1
  actual=$(fm_nm_strip_quotes "$(fm_nm_field "$output" pr)"); [ -n "$actual" ] || return 2
  [ "$actual" = "$pr" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  [[ "$run_head" =~ ^[0-9a-f]{40}$ ]] || return 2
  [ "$run_head" = "$head" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$output" status)"); [ -n "$status" ] || return 2
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$output" outcome)")
  case "$status:$outcome" in running:|ci:|completed:passed|completed:checks-passed) return 0 ;; esac
  return 1
}

successor_input_identity() { # canonical typed input on stdin
  sha256_text
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

# --- the head that landed ---------------------------------------------------
#
# stage_head is the current candidate owned by the lifecycle. It remains the
# admitted head through ordinary equal-head and descendant progress, and moves
# only through candidate-successor, whose immutable stage_predecessor_* fields
# retain where validation began. The pipeline's own fix commits are how a
# candidate routinely reaches green, so the head that lands may still be a
# descendant of stage_head. Naming only the submitted head at landing left the
# record asserting a head that was never landed; naming only the current head
# after a non-ancestor rewrite would erase the admitted predecessor. The current,
# predecessor, and landed fields preserve all three facts. resolve_landed_head
# runs at `landing` alone, because that is the
# moment the evidence is still live; what it finds is then recorded under the
# capture rule below, and every later read takes the recorded value.
#
# landed_head_value: the landed head in play for this transition, or empty (`-`
# in the receipt) when none is known. `landing` fills it under the capture rule
# below and WRITES the result to stage_landed_head; every later transition and
# `show` fills it by reading that field back, never by resolving again.
landed_head_value() {
  printf '%s' "$STAGE_LANDED_HEAD"
}

# recorded_landed_head: load the landed head the record already captured. This
# is the only way anything after `landing` learns it, so the record is the
# authority for the rest of the task's life rather than whatever the mutable
# sources happen to say later.
recorded_landed_head() {
  STAGE_LANDED_HEAD=$(meta stage_landed_head)
  STAGE_LANDED_HEAD_SOURCE=$(meta stage_landed_head_source)
  STAGE_LANDED_HEAD_CONFIRMED=$(meta stage_landed_head_confirmed)
}

# resolve_landed_head: set STAGE_LANDED_HEAD to the head that is landing, from
# evidence this script can read without a network call, and never from a guess.
# In order:
#   pr-head   the forge's own head for the pull request being merged. Recorded
#             by bin/fm-pr-check.sh, which bin/fm-pr-merge.sh re-runs live
#             immediately before merging, so it is the head the merge consumes.
#   worktree  the task worktree's current head.
# BOTH must be the recorded candidate or a descendant of it, proven the same
# mechanical way: the source a capture came from is provenance for a later
# reader, never a licence to check it less. Local ancestry alone decides that
# here: landing must not depend on the pipeline service being reachable, and a
# head that is not a successor of the candidate is not evidence of what this
# task landed.
#
# RESIDUAL, NOT CLOSED. Descendancy BOUNDS pr_head, it does not TIE it to the
# pull request being landed. pr_head= is not a stage_* field, so issue() carries
# it across every later transition including `committed --retry`, and a pr_head
# left by an abandoned attempt that happens also to be a descendant of the
# current candidate is still adoptable at the FIRST capture. Binding the
# recorded pr_head to the pull request identity already in stage_pr is the real
# fix and is tracked as its own item; it is deliberately not implemented here.
#
# When neither source proves a head, the head that landed stays UNRESOLVED and
# the receipt says so. An unproven landed head is recorded as unknown; it is
# never filled in with the candidate head, because that assertion is the defect.
#
# CAPTURE ONCE. FULL STOP. The landed head and the source that supplied it are
# written by the FIRST landing that records them and are NEVER replaced: no rank
# promotion, no equal-rank replacement, no filling in an unresolved capture.
#
# There is no ordering of sources here any more, and that absence is deliberate.
# Three successive review rounds produced three findings on the replacement path
# - an equal-rank worktree head, an unresolved capture being filled, and a
# rank promotion from worktree to pr-head - and every one of them is the same
# sentence: EVIDENCE READ AFTER THE LANDING IS NOT EVIDENCE OF WHAT LANDED.
# Three instances of one sentence is not three bugs, it is a surface that cannot
# be made safe at this cost, so the surface is gone rather than patched a fourth
# time. Do not re-add a replacement path without first closing the residual
# above; without it, every source this could promote from is a live value some
# other writer may have refreshed after the merge.
#
# THE ACCEPTED COST, chosen deliberately: a landing that captured a wrong head,
# or captured none at all, can never re-record a better one. That is acceptable
# only because of the escape at `activated`, which types the landed head as
# unconfirmed rather than asserting that it landed. The failure mode moves from
# "the record asserts a head that never landed" to "the record says this could
# not be confirmed" - the first is a falsehood a reader acts on, the second is
# an honest unknown a reader can investigate.
#
# THE PROOF MUST BE AS DURABLE AND AS PROTECTED AS THE THING PROVED. Stated once
# here, at the owner of these records, because this branch got it wrong three
# times in the same shape: the landed head was made durable while its provenance
# was dropped at activation, capture-once gated on the head VALUE rather than on
# what the record said, and never-regress protected the head but not the
# disposition that establishes it. A rule that guards a fact and leaves its proof
# re-derivable from live state has not guarded the fact.
landed_head_on_candidate_lineage() {  # <candidate> <head>
  local candidate=$1 head=$2
  [ -n "$candidate" ] && [ -n "$head" ] || return 1
  [ "$head" != "$candidate" ] || return 0
  [ -n "$WT" ] && [ -d "$WT" ] || return 1
  git -C "$WT" merge-base --is-ancestor "$candidate" "$head" 2>/dev/null
}

resolve_landed_head() {
  local pr_head wt_head candidate
  STAGE_LANDED_HEAD=
  STAGE_LANDED_HEAD_SOURCE=unresolved
  candidate=$(meta stage_head)
  pr_head=$(meta pr_head)
  if [ -n "$pr_head" ] && fm_pr_head_valid "$pr_head" \
      && landed_head_on_candidate_lineage "$candidate" "$pr_head"; then
    STAGE_LANDED_HEAD=$pr_head
    STAGE_LANDED_HEAD_SOURCE='pr-head'
    return 0
  fi
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    wt_head=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
    if landed_head_on_candidate_lineage "$candidate" "$wt_head"; then
      STAGE_LANDED_HEAD=$wt_head
      STAGE_LANDED_HEAD_SOURCE=worktree
      return 0
    fi
  fi
  return 0
}

# --- receipt and record -----------------------------------------------------

receipt_line() {  # <stage> <owner> <reason> <branch> <head> <tree>
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6 residuals=
  if [ -n "$FM_WC_ENGINEERING" ]; then
    residuals=$(fm_work_context_engineering_residuals "$DATA/$ID/work-context.json" | jq -sr 'map(.id) | join(",")')
  fi
  printf '%s: task=%s gen=%s branch=%s head=%s landed_head=%s landed_confirmed=%s tree=%s intent=%s decisions=%s mode=%s yolo=%s alloc=%s nm_home=%s profile=%s attempt=%s run=%s step=%s outcome=%s pr=%s owner=%s reason=%s engineering=%s discipline=%s discipline_proof=%s residuals=%s\n' \
    "$stage" "$ID" "$(enc "$GEN")" "$(enc "$branch")" "$(enc "$(short "$head")")" "$(enc "$(short "$(landed_head_value)")")" "$(enc "$STAGE_LANDED_HEAD_CONFIRMED")" "$(enc "$(short "$tree")")" \
    "$(intent_identity)" "$(enc "$(closed_decision_keys)")" "$(enc "$MODE")" "$(enc "$YOLO")" "$(enc "$(alloc_identity)")" \
    "$(enc "$(obs nm_home)")" "$(enc "$(profile_identity)")" "$(enc "$(obs attempt_id)")" "$(enc "$(obs run_id)")" \
    "$(enc "$(obs run_status)")" "$(enc "$(obs outcome_class)")" "$(enc "$STAGE_PR_VALUE")" "$owner" "$(enc "$reason")" "$(enc "${FM_WC_ENGINEERING_DIGEST:-}")" \
    "$(enc "$(discipline_identity)")" \
    "$(enc "${FM_DISCIPLINE_PROOF_OUTCOME:-}")" "$(enc "$residuals")"
}

# Once a landing has captured a head, the capture, its provenance, its
# confirmation and the rendering that names it are facts of the record rather
# than of the transition that wrote them, so every later record writer carries
# them. Absent a recorded source there is no capture to carry, and stage_reason
# belongs to whichever transition is speaking.
captured_stage_lines() {
  [ -n "$(meta stage_landed_head_source)" ] || return 0
  grep -E '^stage_(landed_head(_source|_confirmed)?|reason)=' "$META" 2>/dev/null || true
}

# Append the receipt, then publish the record. A crash between the two leaves a
# receipt without its record, and the next run appends it again: a bounded
# duplicate, never a lost transition.
issue() {  # <stage> <owner> <reason> <branch> <head> <tree> [extra key=value...]
  local stage=$1 owner=$2 reason=$3 branch=$4 head=$5 tree=$6 line tmp lock kv lineage carried
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
  lineage=$(grep -E '^stage_(predecessor|successor)_' "$META" 2>/dev/null || true)
  carried=$(captured_stage_lines)
  for kv in "$@"; do
    [ -n "$carried" ] || break
    carried=$(printf '%s\n' "$carried" | grep -v -e "^${kv%%=*}=" || true)
  done
  grep -v -e '^stage=' -e '^stage_' "$META" > "$tmp" || true
  {
    printf 'stage=%s\n' "$stage"
    printf 'stage_epoch=%s\n' "$(now_epoch)"
    printf 'stage_branch=%s\n' "$branch"
    printf 'stage_head=%s\n' "$head"
    printf 'stage_tree=%s\n' "$tree"
    printf 'stage_gen=%s\n' "$GEN"
    printf 'stage_context=%s\n' "$FM_WC_ENGINEERING_DIGEST"
    printf 'stage_discipline=%s\n' "$(discipline_identity)"
    printf 'stage_alloc=%s\n' "$(alloc_identity)"
    [ "$MODE" != no-mistakes ] || printf 'stage_duty=validation\n'
    [ -z "$lineage" ] || printf '%s\n' "$lineage"
    [ -z "$carried" ] || printf '%s\n' "$carried"
    if [ "$stage" = candidate-committed ]; then
      printf 'stage_evidence=\n'
    else
      printf 'stage_evidence=%s\n' "${FM_WC_ENGINEERING_EVIDENCE_DIGEST:-$(meta stage_evidence)}"
    fi
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
    candidate-successor)
      printf 'next: worker continues the recorded successor transition; a minted validation branch runs `%s committed --retry`, while an authenticated pipeline successor continues to CI-ready\n' "$SELF_CMD" ;;
    validation-pending)
      printf 'next: worker stops and waits (%s); firstmate clears the hold or repairs the environment, then the worker re-runs `%s committed`\n' "$(dash "$(meta stage_reason)")" "$SELF_CMD" ;;
    validation-admitted)
      if [ -n "$FM_WC_ENGINEERING" ]; then
        if [ -n "$FM_DISCIPLINE_RECEIPT" ]; then
          fm_discipline_render "$DATA" "$ID" ship implementation || refuse validation-admitted ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
          printf '\n\n'
        fi
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

crew_state() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_EXPECT_RUN="$(obs run_id)" \
    "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true
}

# Reuse the work-context owner at existing stage boundaries. The canonical
# engineering hash survives every transition; deleting/changing an admitted
# declaration cannot downgrade its obligations. Only a supported new attempt
# may accept a changed context, after custody returns to the worker.
# 0 when the live engineering declaration still matches the admitted pin, 1 when
# the declaration changed, and 2 when it cannot be evaluated at all. Sets the
# FM_WC_* globals the halves below read.
engineering_pin_current() {
  local pin
  fm_work_context_engineering "$DATA" "$ID" all all || return 2
  pin=$(meta stage_context)
  [ -z "$pin" ] || [ "$pin" = "$FM_WC_ENGINEERING_DIGEST" ]
}

# The half that judges the admitted CONTRACT: the declaration must be readable,
# still the one that was admitted, and carry the same immutable discipline.
# It reads nothing that a transition advances, so it is the gate that runs
# before any transition takes effect.
engineering_context_pin() { # <transition>
  local transition=$1 pin rc=0
  engineering_pin_current || rc=$?
  case "$rc" in
    0) ;;
    2) refuse "$transition" ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL" ;;
    *) [ "$transition" = committed ] && [ "$RETRY" -eq 1 ] \
         || refuse "$transition" ENGINEERING_CONTEXT 'stale engineering context; retain the admitted contract or settle custody and admit a new attempt' ;;
  esac
  pin=$(meta stage_context)
  if [ -n "$pin" ]; then
    [ "$(meta stage_discipline)" = "$(discipline_identity)" ] || \
      refuse "$transition" DISCIPLINE_IDENTITY 'the selected discipline is immutable across resume and retry'
  fi
}

# The half that judges the live CANDIDATE against the admitted discipline. It
# reads stage_head/stage_tree and the successor lineage, so it runs after a
# transition has advanced them, never before.
engineering_context_discipline() { # <transition>
  local transition=$1 pin recorded_head recorded_tree actual_tree recorded_branch actual_branch observed_head expected_observer
  local observer_candidate output successor=0
  # A selected discipline rides the existing stage identity rather than a
  # second receipt store. Once admitted, independently re-read every available
  # facet before work resumes: the selected context, original branch/head/tree,
  # and observer candidate must still describe one candidate.
  pin=$(meta stage_context)
  if [ -n "$pin" ] && [ -n "$FM_DISCIPLINE_RECEIPT" ]; then
    recorded_head=$(meta stage_head)
    recorded_tree=$(meta stage_tree)
    recorded_branch=$(meta stage_branch)
    if [ -z "$recorded_head" ] || [ -z "$recorded_tree" ] || [ -z "$recorded_branch" ]; then
      refuse "$transition" DISCIPLINE_IDENTITY 'admitted discipline requires branch/head/tree in the stage receipt'
    fi
    observer_candidate=$(obs candidate_head)
    if bound_run_uses_predecessor; then expected_observer=$(stage_predecessor_head); else expected_observer=$recorded_head; fi
    [ -z "$observer_candidate" ] || [ "$observer_candidate" = "$expected_observer" ] || \
      refuse "$transition" DISCIPLINE_IDENTITY 'observer candidate does not match the admitted discipline predecessor'
    actual_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$actual_branch" = "$recorded_branch" ] || \
      refuse "$transition" DISCIPLINE_IDENTITY "recorded branch $recorded_branch does not match current branch $actual_branch"
    actual_tree=$(git -C "$WT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
    observed_head=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
    if [ "$observed_head" != "$recorded_head" ] || [ "$actual_tree" != "$recorded_tree" ]; then
      if [ -n "$(meta stage_run)" ] && [ "$(meta stage_run)" = "$(obs run_id)" ]; then
        output=$(bound_run_status 2>/dev/null || true)
        if [ -n "$output" ] && completed_successor_current "$output" "$observed_head"; then
          successor=1
        fi
      fi
      [ "$successor" -eq 1 ] || \
        refuse "$transition" DISCIPLINE_IDENTITY 'live task worktree must remain at the admitted candidate or a verified custody-returned successor'
    fi
  fi
}

engineering_context() { # <transition>
  engineering_context_pin "$1"
  engineering_context_discipline "$1"
}

engineering_result() {
  local run output actual run_head
  [ -n "$FM_WC_ENGINEERING" ] || return 0
  run=$(obs run_id)
  [ -n "$run" ] || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: no bound run'
  output=$(bound_run_status) \
    || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: current run read failed'
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$output" id)")" = "$run" ] \
    || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: current run mismatch'
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  if fm_nm_run_is_pipeline_owned_active "$output"; then
    [[ "$run_head" =~ ^[0-9a-f]{40}$ ]] \
      || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: current pipeline head must be an exact commit identity'
    actual=$run_head
  else
    actual=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) \
      || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: current pipeline head unavailable'
  fi
  { git -C "$WT" merge-base --is-ancestor "$(meta stage_head)" "$actual" 2>/dev/null \
    || fm_nm_run_is_pipeline_owned_active "$output" \
    || completed_successor_current "$output" "$actual"; } \
    || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-identity: pipeline head is not a candidate successor'
  fm_work_context_engineering_evidence "$DATA" "$ID" "$run" "$actual" \
    || refuse ci-ready ENGINEERING_EVIDENCE "$FM_WORK_CONTEXT_DETAIL"
  if [ -e "$DATA/$ID/engineering-evidence.json" ] || [ -L "$DATA/$ID/engineering-evidence.json" ]; then
    [ -n "${FM_WC_ENGINEERING_EVIDENCE_DIGEST:-}" ] \
      || refuse ci-ready ENGINEERING_EVIDENCE 'engineering-evidence-unreadable: index capture unavailable during admission'
  fi
}

# --- successor transition ---------------------------------------------------

successor_receipt_line() {
  printf 'candidate-successor: task=%s gen=%s predecessor_branch=%s predecessor_head=%s predecessor_tree=%s predecessor_attempt=%s predecessor_run=%s predecessor_duty=%s predecessor_alloc=%s branch=%s head=%s tree=%s ref=%s attempt=%s run=%s alloc=%s submitted=%s current=%s pushed=%s local=%s remote=%s sync=%s relation=%s generation=%s target=%s successor=%s authority=%s action=%s pr=%s attested_head=%s checked_head=%s qualification=%s input=%s owner=worker' \
    "$ID" "$(enc "$(meta stage_successor_gen)")" "$(enc "$(meta stage_predecessor_branch)")" "$(enc "$(short "$(meta stage_predecessor_head)")")" \
    "$(enc "$(short "$(meta stage_predecessor_tree)")")" "$(enc "$(meta stage_predecessor_attempt)")" "$(enc "$(meta stage_predecessor_run)")" \
    "$(enc "$(meta stage_predecessor_duty)")" "$(enc "$(meta stage_predecessor_alloc)")" "$(enc "$(meta stage_successor_branch)")" \
    "$(enc "$(short "$(meta stage_successor_head)")")" "$(enc "$(short "$(meta stage_successor_tree)")")" "$(enc "$(meta stage_successor_ref)")" \
    "$(enc "$(meta stage_successor_attempt)")" "$(enc "$(meta stage_successor_run)")" "$(enc "$(meta stage_successor_alloc)")" \
    "$(enc "$(short "$(meta stage_successor_pipeline_submitted_head)")")" "$(enc "$(short "$(meta stage_successor_pipeline_current_head)")")" \
    "$(enc "$(short "$(meta stage_successor_pipeline_pushed_head)")")" "$(enc "$(short "$(meta stage_successor_local_head)")")" \
    "$(enc "$(short "$(meta stage_successor_remote_head)")")" "$(enc "$(meta stage_successor_sync_state)")" "$(enc "$(meta stage_successor_relation)")" \
    "$(enc "$(meta stage_successor_push_generation)")" "$(enc "$(meta stage_successor_target_kind)")" \
    "$(enc "$(meta stage_successor_id)")" "$(enc "$(meta stage_successor_authority)")" "$(enc "$(meta stage_successor_action)")" \
    "$(enc "$(meta stage_successor_pr)")" "$(enc "$(short "$(meta stage_successor_attested_head)")")" \
    "$(enc "$(short "$(meta stage_successor_checked_head)")")" "$(enc "$(meta stage_successor_qualification)")" \
    "$(enc "$(meta stage_successor_input_sha)")"
}

successor_identity() {
  printf '%s\n' "$ID" "$SI_GEN" "$SI_PREDECESSOR_BRANCH" "$SI_PREDECESSOR_HEAD" "$SI_PREDECESSOR_TREE" \
    "$SI_PREDECESSOR_ATTEMPT" "$SI_PREDECESSOR_RUN" "$SI_PREDECESSOR_DUTY" "$SI_PREDECESSOR_ALLOC" \
    "$SI_BRANCH" "$SI_HEAD" "$SI_TREE" "$SI_REF" "$SI_ATTEMPT" "$SI_RUN" "$SI_ALLOC" \
    "$SI_ACTION" "$SI_AUTHORITY" "$SI_PR" "$SI_ATTESTED" "$SI_CHECKED" "$SI_QUALIFICATION" \
    "$SI_PIPELINE_SUBMITTED" "$SI_PIPELINE_CURRENT" "$SI_PIPELINE_PUSHED" "$SI_LOCAL" "$SI_REMOTE" \
    "$SI_SYNC" "$SI_RELATION" "$SI_PUSH_GENERATION" "$SI_TARGET_KIND" | successor_input_identity
}

successor_record_valid() {
  local expected
  SI_GEN=$(meta stage_successor_gen)
  SI_PREDECESSOR_BRANCH=$(meta stage_predecessor_branch)
  SI_PREDECESSOR_HEAD=$(meta stage_predecessor_head)
  SI_PREDECESSOR_TREE=$(meta stage_predecessor_tree)
  SI_PREDECESSOR_ATTEMPT=$(meta stage_predecessor_attempt)
  SI_PREDECESSOR_RUN=$(meta stage_predecessor_run)
  SI_PREDECESSOR_DUTY=$(meta stage_predecessor_duty)
  SI_PREDECESSOR_ALLOC=$(meta stage_predecessor_alloc)
  SI_BRANCH=$(meta stage_successor_branch)
  SI_HEAD=$(meta stage_successor_head)
  SI_TREE=$(meta stage_successor_tree)
  SI_REF=$(meta stage_successor_ref)
  SI_ATTEMPT=$(meta stage_successor_attempt)
  SI_RUN=$(meta stage_successor_run)
  SI_ALLOC=$(meta stage_successor_alloc)
  SI_ACTION=$(meta stage_successor_action)
  SI_AUTHORITY=$(meta stage_successor_authority)
  SI_PR=$(meta stage_successor_pr)
  SI_ATTESTED=$(meta stage_successor_attested_head)
  SI_CHECKED=$(meta stage_successor_checked_head)
  SI_QUALIFICATION=$(meta stage_successor_qualification)
  SI_PIPELINE_SUBMITTED=$(meta stage_successor_pipeline_submitted_head)
  SI_PIPELINE_CURRENT=$(meta stage_successor_pipeline_current_head)
  SI_PIPELINE_PUSHED=$(meta stage_successor_pipeline_pushed_head)
  SI_LOCAL=$(meta stage_successor_local_head)
  SI_REMOTE=$(meta stage_successor_remote_head)
  SI_SYNC=$(meta stage_successor_sync_state)
  SI_RELATION=$(meta stage_successor_relation)
  SI_PUSH_GENERATION=$(meta stage_successor_push_generation)
  SI_TARGET_KIND=$(meta stage_successor_target_kind)
  [[ "$SI_PREDECESSOR_HEAD" =~ ^[0-9a-f]{40}$ && "$SI_PREDECESSOR_TREE" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$SI_HEAD" =~ ^[0-9a-f]{40}$ && "$SI_TREE" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "$SI_PREDECESSOR_BRANCH" ] && [ -n "$SI_PREDECESSOR_ATTEMPT" ] && [ -n "$SI_PREDECESSOR_RUN" ] || return 1
  [ "$SI_PREDECESSOR_DUTY" = validation ] && [ -n "$SI_PREDECESSOR_ALLOC" ] || return 1
  [ -n "$SI_BRANCH" ] && [ "$SI_REF" = "refs/heads/$SI_BRANCH" ] || return 1
  [ "$SI_ATTEMPT" = "$SI_PREDECESSOR_ATTEMPT" ] && [ "$SI_RUN" = "$SI_PREDECESSOR_RUN" ] || return 1
  [ "$SI_ALLOC" = "$SI_PREDECESSOR_ALLOC" ] || return 1
  [ "$SI_AUTHORITY" = fm-stage/no-mistakes-bound-run ] || return 1
  case "$SI_ACTION" in
    authenticated-synchronized-successor)
      fm_pr_url_parse "$SI_PR" >/dev/null 2>&1 || return 1
      [ "$SI_PIPELINE_SUBMITTED" = "$SI_PREDECESSOR_HEAD" ] || return 1
      [ "$SI_PIPELINE_CURRENT" = "$SI_HEAD" ] && [ "$SI_PIPELINE_PUSHED" = "$SI_HEAD" ] || return 1
      [ "$SI_LOCAL" = "$SI_HEAD" ] && [ "$SI_REMOTE" = "$SI_HEAD" ] || return 1
      [ "$SI_ATTESTED" = "$SI_HEAD" ] && [ "$SI_CHECKED" = "$SI_HEAD" ] || return 1
      [ "$SI_SYNC" = synchronized ] && [ "$SI_RELATION" = equal ] || return 1
      [[ "$SI_PUSH_GENERATION" =~ ^[1-9][0-9]*$ ]] || return 1
      case "$SI_TARGET_KIND" in upstream|fork) ;; *) return 1 ;; esac
      [ "$SI_QUALIFICATION" = checks-passed ] || return 1
      ;;
    mint-validation-branch)
      [ -z "$SI_PIPELINE_SUBMITTED$SI_PIPELINE_CURRENT$SI_PIPELINE_PUSHED$SI_LOCAL$SI_REMOTE" ] || return 1
      [ -z "$SI_SYNC$SI_RELATION$SI_PUSH_GENERATION$SI_TARGET_KIND$SI_ATTESTED$SI_CHECKED" ] || return 1
      [ "$SI_QUALIFICATION" = successor-required ] || return 1
      ;;
    *) return 1 ;;
  esac
  expected=$(successor_identity)
  [ "$(meta stage_successor_input_sha)" = "$expected" ] || return 1
  [ "$(meta stage_successor_id)" = "successor-${expected:0:24}" ] || return 1
  [ "$(meta stage_branch)" = "$SI_BRANCH" ] && [ "$(meta stage_head)" = "$SI_HEAD" ] && [ "$(meta stage_tree)" = "$SI_TREE" ] || return 1
}

successor_replay_locked() {
  local line
  successor_record_valid || return 1
  read_candidate
  [ "$BRANCH" = "$SI_BRANCH" ] && [ "$HEAD" = "$SI_HEAD" ] && [ "$TREE" = "$SI_TREE" ] || return 1
  ! worktree_dirty || return 1
  line=$(successor_receipt_line)
  grep -Fxq "$line" "$STATUS" 2>/dev/null || printf '%s\n' "$line" >> "$STATUS"
  printf 'STAGE_UNCHANGED: %s\n' "$line"
}

publish_successor_locked() { # <action> <branch> <head> <tree> <ref> <pr> <attested> <checked> <qualification>
  local action=$1 branch=$2 head=$3 tree=$4 ref=$5 pr=$6 attested=$7 checked=$8 qualification=$9
  local predecessor_branch predecessor_head predecessor_tree predecessor_attempt predecessor_run predecessor_duty predecessor_alloc tmp line captured
  local pipeline_submitted pipeline_current pipeline_pushed local_head remote_head sync_state relation push_generation target_kind authority
  predecessor_branch=$(stage_predecessor_branch)
  predecessor_head=$(stage_predecessor_head)
  predecessor_tree=$(meta stage_predecessor_tree); [ -n "$predecessor_tree" ] || predecessor_tree=$(meta stage_tree)
  predecessor_attempt=$(stage_predecessor_attempt)
  predecessor_run=$(stage_predecessor_run)
  predecessor_duty=$(meta stage_predecessor_duty); [ -n "$predecessor_duty" ] || predecessor_duty=$(meta stage_duty); [ -n "$predecessor_duty" ] || predecessor_duty=validation
  predecessor_alloc=$(meta stage_predecessor_alloc); [ -n "$predecessor_alloc" ] || predecessor_alloc=$(meta stage_alloc); [ -n "$predecessor_alloc" ] || predecessor_alloc=$(alloc_identity)
  pipeline_submitted=; pipeline_current=; pipeline_pushed=; local_head=; remote_head=; sync_state=; relation=; push_generation=; target_kind=
  authority=fm-stage/no-mistakes-bound-run
  if [ "$action" = authenticated-synchronized-successor ]; then
    pipeline_submitted=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" pipeline submitted_head) || return 2
    pipeline_current=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" pipeline current_head) || return 2
    pipeline_pushed=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" pipeline pushed_head) || return 2
    local_head=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" local head) || return 2
    remote_head=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" remote observed_head) || return 2
    sync_state=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" '' state) || return 2
    relation=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" '' relation) || return 2
    push_generation=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" pipeline push_generation raw) || return 2
    target_kind=$(fm_nm_sync_scalar "$SUCCESSOR_SYNC" target kind) || return 2
  fi
  SI_GEN=$GEN
  SI_PREDECESSOR_BRANCH=$predecessor_branch; SI_PREDECESSOR_HEAD=$predecessor_head; SI_PREDECESSOR_TREE=$predecessor_tree
  SI_PREDECESSOR_ATTEMPT=$predecessor_attempt; SI_PREDECESSOR_RUN=$predecessor_run; SI_PREDECESSOR_DUTY=$predecessor_duty; SI_PREDECESSOR_ALLOC=$predecessor_alloc
  SI_BRANCH=$branch; SI_HEAD=$head; SI_TREE=$tree; SI_REF=$ref; SI_ATTEMPT=$(meta stage_attempt); SI_RUN=$(meta stage_run); SI_ALLOC=$predecessor_alloc
  SI_ACTION=$action; SI_AUTHORITY=$authority; SI_PR=$pr; SI_ATTESTED=$attested; SI_CHECKED=$checked; SI_QUALIFICATION=$qualification
  SI_PIPELINE_SUBMITTED=$pipeline_submitted; SI_PIPELINE_CURRENT=$pipeline_current; SI_PIPELINE_PUSHED=$pipeline_pushed
  SI_LOCAL=$local_head; SI_REMOTE=$remote_head; SI_SYNC=$sync_state; SI_RELATION=$relation; SI_PUSH_GENERATION=$push_generation; SI_TARGET_KIND=$target_kind
  SUCCESSOR_INPUT_SHA=$(successor_identity)
  SUCCESSOR_ID="successor-${SUCCESSOR_INPUT_SHA:0:24}"
  if [ -n "$(meta stage_successor_id)" ]; then
    [ "$(meta stage_successor_id)" = "$SUCCESSOR_ID" ] || return 3
    successor_replay_locked || return 3
    return 0
  fi
  if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
    return 2
  fi
  captured=$(captured_stage_lines)
  tmp="$STATE/.$ID.meta.successor.${BASHPID:-$$}"
  grep -v -e '^stage=' -e '^stage_' "$META" > "$tmp" || true
  {
    printf 'stage=candidate-successor\n'
    printf 'stage_epoch=%s\n' "$(now_epoch)"
    printf 'stage_branch=%s\n' "$branch"
    printf 'stage_head=%s\n' "$head"
    printf 'stage_tree=%s\n' "$tree"
    printf 'stage_gen=%s\n' "$GEN"
    printf 'stage_context=%s\n' "$(meta stage_context)"
    printf 'stage_discipline=%s\n' "$(meta stage_discipline)"
    printf 'stage_alloc=%s\n' "$predecessor_alloc"
    printf 'stage_duty=validation\n'
    printf 'stage_evidence=%s\n' "$(meta stage_evidence)"
    printf 'stage_attempt=%s\n' "$(meta stage_attempt)"
    printf 'stage_run=%s\n' "$(meta stage_run)"
    printf 'stage_pr=%s\n' "$pr"
    [ -z "$captured" ] || printf '%s\n' "$captured"
    printf 'stage_predecessor_branch=%s\n' "$predecessor_branch"
    printf 'stage_predecessor_head=%s\n' "$predecessor_head"
    printf 'stage_predecessor_tree=%s\n' "$predecessor_tree"
    printf 'stage_predecessor_attempt=%s\n' "$predecessor_attempt"
    printf 'stage_predecessor_run=%s\n' "$predecessor_run"
    printf 'stage_predecessor_duty=%s\n' "$predecessor_duty"
    printf 'stage_predecessor_alloc=%s\n' "$predecessor_alloc"
    printf 'stage_successor_id=%s\n' "$SUCCESSOR_ID"
    printf 'stage_successor_gen=%s\n' "$GEN"
    printf 'stage_successor_branch=%s\n' "$branch"
    printf 'stage_successor_head=%s\n' "$head"
    printf 'stage_successor_tree=%s\n' "$tree"
    printf 'stage_successor_ref=%s\n' "$ref"
    printf 'stage_successor_attempt=%s\n' "$(meta stage_attempt)"
    printf 'stage_successor_run=%s\n' "$(meta stage_run)"
    printf 'stage_successor_alloc=%s\n' "$predecessor_alloc"
    printf 'stage_successor_pipeline_submitted_head=%s\n' "$pipeline_submitted"
    printf 'stage_successor_pipeline_current_head=%s\n' "$pipeline_current"
    printf 'stage_successor_pipeline_pushed_head=%s\n' "$pipeline_pushed"
    printf 'stage_successor_local_head=%s\n' "$local_head"
    printf 'stage_successor_remote_head=%s\n' "$remote_head"
    printf 'stage_successor_sync_state=%s\n' "$sync_state"
    printf 'stage_successor_relation=%s\n' "$relation"
    printf 'stage_successor_push_generation=%s\n' "$push_generation"
    printf 'stage_successor_target_kind=%s\n' "$target_kind"
    printf 'stage_successor_authority=%s\n' "$authority"
    printf 'stage_successor_action=%s\n' "$action"
    printf 'stage_successor_pr=%s\n' "$pr"
    printf 'stage_successor_attested_head=%s\n' "$attested"
    printf 'stage_successor_checked_head=%s\n' "$checked"
    printf 'stage_successor_qualification=%s\n' "$qualification"
    printf 'stage_successor_input_sha=%s\n' "$SUCCESSOR_INPUT_SHA"
  } >> "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
    rm -f -- "$tmp"
    return 2
  fi
  if [ "${FM_STAGE_TEST_INTERRUPT_AFTER_SUCCESSOR_PUBLISH:-0}" = 1 ]; then
    return 86
  fi
  line=$(successor_receipt_line)
  printf '%s\n' "$line" >> "$STATUS"
  printf 'STAGE: %s\n' "$line"
}

authenticated_successor_transition() { # <pr-url>; caller has read candidate
  local pr=$1 lock verdict proof_rc publish_rc run submitted duty expected_head expected_tree expected_branch final_sync sync_rc status_rc ctx_rc
  lock=$(fm_meta_lock_path "$META") || exit 2
  fm_lock_acquire_wait "$lock"
  read_candidate
  if [ -n "$(meta stage_successor_id)" ]; then
    if [ "$(meta stage_successor_action)" != authenticated-synchronized-successor ] \
        || [ "$(meta stage_successor_pr)" != "$pr" ] \
        || ! successor_replay_locked; then
      fm_lock_release "$lock"
      refuse ci-ready SUCCESSOR_COLLISION 'the recorded successor is distinct, incomplete, or no longer matches the exact local candidate'
    fi
    fm_lock_release "$lock"
    return 0
  fi
  expected_head=$HEAD; expected_tree=$TREE; expected_branch=$BRANCH
  submitted=$(stage_predecessor_head)
  run=$(stage_predecessor_run)
  duty=$(meta stage_predecessor_duty); [ -n "$duty" ] || duty=$(meta stage_duty); [ -n "$duty" ] || duty=validation
  if [ -z "$run" ] || [ -z "$submitted" ] || [ -z "$expected_head" ] || [ -z "$expected_tree" ] || [ -z "$expected_branch" ] \
      || [ -z "$(meta stage_attempt)" ] || [ -z "$(obs attempt_id)" ] || [ -z "$(obs run_id)" ]; then
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CNO 'the predecessor, successor, attempt, or run identity could not be evaluated'
  fi
  if [ "$duty" != validation ] || [ "$(meta stage_attempt)" != "$(obs attempt_id)" ] || [ "$run" != "$(obs run_id)" ] \
      || [ "$submitted" != "$(obs candidate_head)" ] || [ "$(meta stage_branch)" != "$(obs candidate_branch)" ] \
      || [ "$(obs entrypoint)" != stage ] \
      || { [ -n "$(meta stage_alloc)" ] && [ "$(meta stage_alloc)" != "$(alloc_identity)" ]; }; then
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CONTRADICTION 'predecessor head, branch, attempt, run, duty, allocation, or entrypoint no longer matches the bound validation'
  fi
  SUCCESSOR_STATUS=$(NM_HOME="$(obs nm_home)" fm_nm_run_checked "$WT" 10 axi status --run "$run") || {
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CNO 'the exact bound run identity could not be read'
  }
  SUCCESSOR_SYNC=$(NM_HOME="$(obs nm_home)" fm_nm_run_checked "$WT" 10 axi sync --check) || {
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CNO 'synchronization identity could not be evaluated'
  }
  sync_rc=0
  fm_nm_verified_synchronized_successor "$run" "$submitted" "$expected_head" "$(meta stage_branch)" "$SUCCESSOR_SYNC" || sync_rc=$?
  case "$sync_rc" in
    0) ;;
    2) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CNO 'local, remote, pipeline, submitted, current, pushed, branch, or cleanliness identity could not be evaluated' ;;
    *) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CONTRADICTION 'local, remote, pipeline, submitted, current, pushed, branch, or cleanliness identity disagrees' ;;
  esac
  status_rc=0
  successor_status_matches "$SUCCESSOR_STATUS" "$run" "$(meta stage_branch)" "$expected_head" "$pr" || status_rc=$?
  case "$status_rc" in
    0) ;;
    2) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CNO 'the exact bound run branch, PR, head, or qualification state could not be evaluated' ;;
    *) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CONTRADICTION 'the bound run does not name this exact branch, PR, successor head, and qualification state' ;;
  esac
  verdict=$(crew_state)
  case "$verdict" in
    "state: done"*"source: run-step"*) ;;
    "state: unknown"*|'') fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CNO "the exact bound run qualification could not be evaluated: ${verdict:-no verdict}" ;;
    *) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CONTRADICTION "the exact bound run is not canonically checks-green: $verdict" ;;
  esac
  proof_rc=0
  successor_pr_attestation "$pr" "$(meta stage_branch)" "$expected_head" || proof_rc=$?
  case "$proof_rc" in
    0) ;;
    2) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CNO 'the live PR identity or attestation could not be evaluated' ;;
    *) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CONTRADICTION 'the live PR identity, branch, state, head, or no-mistakes attestation disagrees' ;;
  esac
  # Final effect-boundary read-back. Network and Git evidence were acquired
  # above while the task record lock was held; repeat the mutable branch/remote
  # projection immediately before publication so a moved ref cannot consume an
  # older proof.
  read_candidate
  if [ "$HEAD" != "$expected_head" ] || [ "$TREE" != "$expected_tree" ] || [ "$BRANCH" != "$expected_branch" ] || worktree_dirty; then
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CONTRADICTION 'the local branch, head, tree, or cleanliness changed during successor verification'
  fi
  final_sync=$(NM_HOME="$(obs nm_home)" fm_nm_run_checked "$WT" 10 axi sync --check) || {
    fm_lock_release "$lock"
    refuse ci-ready SUCCESSOR_CNO 'final synchronization read-back could not be evaluated'
  }
  sync_rc=0
  fm_nm_verified_synchronized_successor "$run" "$submitted" "$expected_head" "$(meta stage_branch)" "$final_sync" || sync_rc=$?
  case "$sync_rc" in
    0) ;;
    2) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CNO 'final local, remote, and pipeline read-back could not be evaluated' ;;
    *) fm_lock_release "$lock"; refuse ci-ready SUCCESSOR_CONTRADICTION 'final local, remote, and pipeline read-back moved before publication' ;;
  esac
  ctx_rc=0
  engineering_pin_current || ctx_rc=$?
  if [ "$ctx_rc" -ne 0 ]; then
    fm_lock_release "$lock"
    [ "$ctx_rc" -ne 2 ] || refuse ci-ready ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
    refuse ci-ready ENGINEERING_CONTEXT 'stale engineering context; retain the admitted contract or settle custody and admit a new attempt'
  fi
  SUCCESSOR_SYNC=$final_sync
  SUCCESSOR_CHECKED_HEAD=$expected_head
  publish_rc=0
  publish_successor_locked authenticated-synchronized-successor "$(meta stage_branch)" "$expected_head" "$expected_tree" "refs/heads/$(meta stage_branch)" "$pr" "$SUCCESSOR_ATTESTED_HEAD" "$SUCCESSOR_CHECKED_HEAD" checks-passed || publish_rc=$?
  fm_lock_release "$lock"
  case "$publish_rc" in
    0) return 0 ;;
    3) refuse ci-ready SUCCESSOR_COLLISION 'a distinct successor is already recorded for this predecessor' ;;
    86) exit 86 ;;
    *) echo "error: successor task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2; exit 2 ;;
  esac
}

terminal_successor_required() { # <bound-status>
  ! fm_nm_run_is_active "$1"
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
    validation-admitted|validation-running|candidate-successor|ci-ready|landing|activated)
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
      if [ -n "$(fm_nm_strip_quotes "$(fm_nm_field "$output" pr)")" ]; then
        if [ "$(meta stage_successor_action)" != mint-validation-branch ] \
            || [ "$current" != candidate-successor ] \
            || [ "$(meta stage_attempt)" != "$(meta stage_successor_attempt)" ] \
            || [ "$(meta stage_run)" != "$(meta stage_successor_run)" ]; then
          refuse committed SUCCESSOR_REQUIRED "the terminal published validation branch is non-reusable; run \`$SELF_CMD successor\`, then re-run committed --retry"
        fi
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

do_successor() {
  local current output lock journal new_branch old_branch old_head base_head existing publish_rc adopt_rc
  require_ship successor
  [ "$MODE" = no-mistakes ] || refuse successor NOT_ADMITTED "mode=$MODE has no validation successor"
  require_worktree successor
  read_candidate
  ! worktree_dirty || refuse successor UNCOMMITTED 'the worktree must be clean before minting a validation successor'
  current=$(meta stage)
  case "$current" in validation-running|ci-ready|landing|activated|candidate-successor) ;; *) refuse successor NOT_ADMITTED "stage=${current:-none} has no admitted validation predecessor" ;; esac
  if [ -n "$(meta stage_successor_id)" ]; then
    if [ "$(meta stage_successor_action)" != mint-validation-branch ] || [ "$current" != candidate-successor ]; then
      refuse successor SUCCESSOR_COLLISION 'one successor is already immutable; a second distinct successor is not allowed'
    fi
    lock=$(fm_meta_lock_path "$META") || exit 2
    fm_lock_acquire_wait "$lock"
    if ! successor_replay_locked; then
      fm_lock_release "$lock"
      refuse successor SUCCESSOR_COLLISION 'the recorded successor is incomplete or no longer matches the exact local candidate'
    fi
    journal="$STATE/.$ID.stage-successor-branch"
    if [ -e "$journal" ] || [ -L "$journal" ]; then
      if [ ! -f "$journal" ] || [ -L "$journal" ] \
          || [ "$(fm_meta_get "$journal" predecessor_branch)" != "$(meta stage_predecessor_branch)" ] \
          || [ "$(fm_meta_get "$journal" predecessor_head)" != "$(meta stage_predecessor_head)" ] \
          || [ "$(fm_meta_get "$journal" successor_branch)" != "$(meta stage_successor_branch)" ] \
          || [ "$(fm_meta_get "$journal" successor_head)" != "$(meta stage_successor_head)" ]; then
        fm_lock_release "$lock"
        refuse successor SUCCESSOR_COLLISION 'the completed successor has an incompatible recovery journal'
      fi
      rm -f -- "$journal"
    fi
    fm_lock_release "$lock"
    # shellcheck disable=SC2016 # backticks are literal command quoting
    printf 'next: worker runs `%s committed --retry`; final admission remains immediately before the next pipeline run\n' "$SELF_CMD"
    return 0
  fi
  output=$(bound_run_status) || refuse successor SUCCESSOR_CNO 'the exact predecessor run could not be read'
  terminal_successor_required "$output" || refuse successor RUN_ACTIVE 'the predecessor run is still active; continue it instead of minting another branch'
  old_branch=$(meta stage_branch); old_head=$(meta stage_head)
  new_branch="${old_branch}-successor"
  journal="$STATE/.$ID.stage-successor-branch"
  # The pipeline's own fix commits routinely advance the predecessor branch past
  # the admitted head, so the mint may base on that advance - but only on the
  # one head this terminal run carried and its PR attests, and never in place of
  # the immutable admitted predecessor.
  base_head=$old_head
  if [ "$BRANCH" = "$old_branch" ] && [ "$HEAD" != "$old_head" ]; then
    adopt_rc=0
    identified_terminal_descendant "$output" "$old_branch" "$old_head" "$HEAD" || adopt_rc=$?
    case "$adopt_rc" in
      0) ;;
      2) refuse successor SUCCESSOR_CNO 'the bound run or live PR identity for the advanced head could not be evaluated' ;;
      *) refuse successor SUCCESSOR_CONTRADICTION 'the live head is not the descendant this bound run carried and its PR attests' ;;
    esac
    base_head=$HEAD
  fi
  if [ "$BRANCH" != "$old_branch" ] || [ "$HEAD" != "$base_head" ]; then
    [ "$BRANCH" = "$new_branch" ] && [ -f "$journal" ] && [ ! -L "$journal" ] \
      && [ -n "$HEAD" ] && [ "$HEAD" = "$(fm_meta_get "$journal" successor_head)" ] \
      || refuse successor SUCCESSOR_CONTRADICTION 'the live branch or head moved from the recorded predecessor'
    base_head=$HEAD
  fi
  lock=$(fm_meta_lock_path "$META") || exit 2
  fm_lock_acquire_wait "$lock"
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    [ -f "$journal" ] && [ ! -L "$journal" ] \
      && [ "$(fm_meta_get "$journal" predecessor_branch)" = "$old_branch" ] \
      && [ "$(fm_meta_get "$journal" predecessor_head)" = "$old_head" ] \
      && [ "$(fm_meta_get "$journal" successor_branch)" = "$new_branch" ] \
      && [ "$(fm_meta_get "$journal" successor_head)" = "$base_head" ] || {
        fm_lock_release "$lock"
        refuse successor SUCCESSOR_COLLISION 'an incompatible interrupted successor transaction already exists'
      }
  else
    existing=$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$new_branch^{commit}" 2>/dev/null || true)
    if [ -n "$existing" ]; then
      fm_lock_release "$lock"
      refuse successor SUCCESSOR_COLLISION "successor branch $new_branch already exists without this transition's recovery journal"
    fi
    {
      umask 077
      printf 'record=fm-stage-successor-prepare/v1\npredecessor_branch=%s\npredecessor_head=%s\nsuccessor_branch=%s\nsuccessor_head=%s\n' \
        "$old_branch" "$old_head" "$new_branch" "$base_head" > "$journal.${BASHPID:-$$}"
      mv "$journal.${BASHPID:-$$}" "$journal"
    }
  fi
  existing=$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$new_branch^{commit}" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    if [ "$existing" != "$base_head" ]; then
      fm_lock_release "$lock"
      refuse successor SUCCESSOR_COLLISION "successor branch $new_branch already names a distinct head"
    fi
    git -C "$WT" switch -q "$new_branch" 2>/dev/null || {
      fm_lock_release "$lock"
      refuse successor SUCCESSOR_COLLISION "successor branch $new_branch exists but cannot be checked out"
    }
  else
    git -C "$WT" switch -q -c "$new_branch" "$base_head" 2>/dev/null || {
      fm_lock_release "$lock"
      refuse successor SUCCESSOR_COLLISION "successor branch $new_branch could not be created"
    }
  fi
  if [ "${FM_STAGE_TEST_INTERRUPT_AFTER_SUCCESSOR_BRANCH:-0}" = 1 ]; then
    fm_lock_release "$lock"
    exit 86
  fi
  read_candidate
  publish_rc=0
  publish_successor_locked mint-validation-branch "$BRANCH" "$HEAD" "$TREE" "refs/heads/$BRANCH" "$(meta stage_pr)" '' '' successor-required || publish_rc=$?
  [ "$publish_rc" -ne 0 ] || rm -f -- "$journal"
  fm_lock_release "$lock"
  case "$publish_rc" in
    0) ;;
    3) refuse successor SUCCESSOR_COLLISION 'a distinct successor is already recorded for this predecessor' ;;
    86) exit 86 ;;
    *) echo "error: successor task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2; exit 2 ;;
  esac
  # shellcheck disable=SC2016 # backticks are literal command quoting
  printf 'next: worker runs `%s committed --retry`; final admission remains immediately before the next pipeline run\n' "$SELF_CMD"
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
    validation-running|candidate-successor|ci-ready) ;;
    *) refuse ci-ready NOT_ADMITTED "stage=${current:-none}; validation must be admitted and running first" ;;
  esac
  engineering_context_pin ci-ready
  if [ "$(meta stage_successor_action)" = authenticated-synchronized-successor ]; then
    authenticated_successor_transition "$PR_ARG"
    current=$(meta stage)
  elif ! candidate_current "$(meta stage_head)" "$HEAD" ci-ready; then
    authenticated_successor_transition "$PR_ARG"
    current=$(meta stage)
  fi
  engineering_context_discipline ci-ready
  verdict=$(crew_state)
  case "$verdict" in
    "state: done"*"source: run-step"*) ;;
    *) refuse ci-ready NOT_CI_READY "canonical state is not checks green from the run step: ${verdict:-no verdict}" ;;
  esac
  observe refresh "$ID"
  engineering_result
  STAGE_PR_VALUE=$PR_ARG
  if [ "$current" = ci-ready ] && [ "$(meta stage_pr)" = "$PR_ARG" ] \
      && [ "$(meta stage_evidence)" = "${FM_WC_ENGINEERING_EVIDENCE_DIGEST:-$(meta stage_evidence)}" ]; then
    unchanged ci-ready
  else
    issue ci-ready merge-authority "" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(obs attempt_id)" "stage_run=$(obs run_id)" "stage_pr=$PR_ARG"
  fi
  next_for ci-ready
}

do_landing() {
  local current captured captured_reason captured_source reason
  require_ship landing
  engineering_context landing
  current=$(meta stage)
  [ -n "$current" ] || refuse landing NOT_ADMITTED "no candidate is recorded"
  [ "$current" != activated ] || { unchanged activated; next_for activated; return 0; }
  [ -z "$PR_ARG" ] || fm_pr_url_parse "$PR_ARG" >/dev/null 2>&1 || refuse landing BAD_PR "not a canonical PR URL: $PR_ARG"
  STAGE_PR_VALUE=${PR_ARG:-$(meta stage_pr)}
  resolve_landed_head
  captured=$(meta stage_landed_head)
  captured_source=$(meta stage_landed_head_source)
  captured_reason=$(meta stage_reason)
  reason="landed-head:$STAGE_LANDED_HEAD_SOURCE"
  # EMPTINESS IS NOT ABSENCE. A recorded `unresolved` is a positive fact - the
  # tool looked at landing time and could not prove a head - so the capture is
  # decided on the recorded SOURCE, never on whether the head string is empty.
  # Reading that empty head as "nothing was recorded" would turn a decision that
  # WAS made into one that was never made, the same collapse as treating an
  # unreadable record as a clean one. Once a source is recorded the capture
  # stands, whatever this delivery just resolved.
  if [ -n "$captured_source" ]; then
    STAGE_LANDED_HEAD=$captured
    STAGE_LANDED_HEAD_SOURCE=$captured_source
    reason=$captured_reason
  fi
  if [ "$current" = landing ] && [ "$(meta stage_pr)" = "$STAGE_PR_VALUE" ] \
      && [ "$(meta stage_landed_head)" = "$STAGE_LANDED_HEAD" ] \
      && [ "$captured_reason" = "$reason" ]; then
    unchanged landing
  else
    issue landing merge-authority "$reason" \
      "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(meta stage_attempt)" "stage_run=$(meta stage_run)" "stage_pr=$STAGE_PR_VALUE" \
      "stage_landed_head=$STAGE_LANDED_HEAD" \
      "stage_landed_head_source=$STAGE_LANDED_HEAD_SOURCE" \
      "stage_reason=$reason"
  fi
  next_for landing
}

# landed_integration_proof: print the INTEGRATION tip that contains <head> - the
# proof that it landed - or return 1. bin/fm-tangle-lib.sh's fm_default_branch
# owns which branch integrates; both the local branch and its remote-tracking
# ref are that branch seen from a different distance, so either one containing
# the head means the head is on the integration line.
#
# "THE REF EXISTS" IS NOT "THE REF ANSWERS" (see ONE ANSWER PER QUESTION above).
# Stopping at the first ref that merely exists is how a stale value wins over a
# correct one: a local-only landing advances refs/heads/<default> and pushes
# nothing, so refs/remotes/origin/<default> stays behind forever, and preferring
# it because it is present would refuse every local-only activation. So each
# ref that resolves is asked the question, and neither ref's absence, nor its
# failure to answer, is evidence against the other. The local branch goes first
# because fleet sync keeps it current for pushed work too, which makes it the
# ref that is right in both modes rather than one.
#
# It deliberately does NOT read the clone's checked-out HEAD. An operator who
# parked the clone on the PR branch, or on a release branch that contains the
# head for an unrelated reason, would otherwise establish a confirmation the
# tool never actually proved. Nothing here fetches; every read is local.
#
# RESIDUAL, NOT CLOSED. The clone's default branch is a PROXY for the pull
# request's actual base, which this record does not carry. An unusual clone
# whose default branch legitimately contains the head for some other reason can
# still confirm wrongly. The proxy passing is not the same as the question being
# answered, and this is not claimed as closed.
landed_integration_proof() {  # <head>
  local head=$1 branch ref tip
  [ -n "$head" ] || return 1
  [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || return 1
  branch=$(fm_default_branch "$PROJECT") || return 1
  for ref in "refs/heads/$branch" "refs/remotes/origin/$branch"; do
    tip=$(git -C "$PROJECT" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || continue
    if git -C "$PROJECT" merge-base --is-ancestor "$head" "$tip" 2>/dev/null; then
      printf '%s' "$tip"
      return 0
    fi
  done
  return 1
}

# landed_head_reachable: whether <head> is on the project clone's integration
# line. An unreachable head, an unavailable clone, and an integration branch
# that cannot be determined are three ways of not proving it, and none of them
# proves the opposite (see ONE ANSWER PER QUESTION above).
landed_head_reachable() {  # <head>
  landed_integration_proof "$1" >/dev/null
}

# landed_head_confirmation: set STAGE_LANDED_HEAD_CONFIRMED to what activation
# can prove about the captured landed head. Its caller runs this BEFORE taking
# readback_evidence's output, because that output is read through a command
# substitution and a subshell cannot hand a decision back.
#
# The disposition only ever moves upward: unconfirmed may become confirmed, and
# a recorded `confirmed` is never taken back. That is ONE ANSWER PER QUESTION
# applied ACROSS TIME - a later delivery failing to re-prove a fact is not
# evidence against it - and without it ordinary housekeeping in the clone would
# silently demote an audit-grade fact.
#
# THE ESCAPE FROM A STRICTNESS RULE IS TO MAKE THE FACT HARDER TO ESTABLISH
# WRONGLY, NOT EASIER TO RETRACT. Freezing a loose predicate locks in whatever it
# happened to accept; loosening the retraction to compensate would just restore
# the silent demotion. So the establishment is what is tight here:
# landed_head_reachable asks the integration line, and an integration branch
# that cannot be determined leaves the head unconfirmed.
landed_head_confirmation() {
  local landed
  [ "$STAGE_LANDED_HEAD_CONFIRMED" != confirmed ] || return 0
  landed=$(landed_head_value)
  if [ -z "$landed" ]; then
    STAGE_LANDED_HEAD_CONFIRMED=none
  elif landed_head_reachable "$landed"; then
    STAGE_LANDED_HEAD_CONFIRMED=confirmed
  else
    STAGE_LANDED_HEAD_CONFIRMED=unconfirmed
  fi
}

# readback_evidence: print what activation could actually PROVE, independently of
# the disposition landed_head_confirmation recorded. It re-tests reachability
# here rather than reading that disposition, because the disposition is sticky
# by design and a head proven once may be unreachable now; falling back to the
# candidate head is what keeps a re-delivery from refusing NO_READBACK on a
# record whose earlier proof still stands.
#
# Two facts, recorded apart, neither inferable from the other: the evidence
# obtained, and whether the captured landed head was confirmed by it. Capture
# once means a landed head captured from the worktree can be wrong - the
# worker's local commit was never the one pushed - and nothing in this tool can
# then correct it. Refusing forever would leave a hand edit of a live fleet
# record as the only escape, which is not a worker's to make. So activation
# PROCEEDS on the candidate head it can still prove and says plainly, in a field
# a consumer can match on, that the captured landed head was not confirmed. It
# never rewrites the landed head or its provenance to make the record agree with
# itself.
readback_evidence() {  # prints the evidence, or 1
  local marker="$STATE/$ID.pr-poll-merge-notified" version provider host path number extra head main
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    if { IFS= read -r version && IFS= read -r provider && IFS= read -r host && IFS= read -r path && IFS= read -r number && ! IFS= read -r extra; } < "$marker" \
        && [ "$version" = fm-pr-poll-merge-notified-v1 ] && [ -n "$provider" ] && [ -n "$host" ] && [ -n "$path" ] && [ -n "$number" ]; then
      printf 'merged:%s:%s:%s:%s' "$provider" "$host" "$path" "$number"
      return 0
    fi
  fi
  # Read back the head that LANDED when one is recorded and provable: proving
  # the submitted candidate reachable proves only that validation started from
  # something that landed, not that the successor the pipeline shipped did.
  local which=landed
  head=$(landed_head_value)
  if [ -z "$head" ] || ! landed_head_reachable "$head"; then
    head=$(meta stage_head)
    which=candidate
  fi
  if main=$(landed_integration_proof "$head"); then
    printf 'ancestor-of:%s:%s-head:%s' "$(short "$main")" "$which" "$(short "$head")"
    return 0
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
  recorded_landed_head
  landed_head_confirmation
  evidence=$(readback_evidence) || refuse activated NO_READBACK "neither a merge-notification marker with PR identity nor the landed head, nor the candidate head it falls back to, reachable from the project clone's integration branch"
  STAGE_PR_VALUE=$(meta stage_pr)
  if [ "$current" = activated ] && [ "$(meta stage_reason)" = "$evidence" ] \
      && [ "$(meta stage_landed_head_confirmed)" = "$STAGE_LANDED_HEAD_CONFIRMED" ]; then
    unchanged activated
  else
    # issue rewrites every stage_* field, so the landed head is restated here to
    # carry the landing's captured fact forward rather than losing it.
    issue activated firstmate "$evidence" "$(meta stage_branch)" "$(meta stage_head)" "$(meta stage_tree)" \
      "stage_attempt=$(meta stage_attempt)" "stage_run=$(meta stage_run)" "stage_pr=$STAGE_PR_VALUE" \
      "stage_landed_head=$STAGE_LANDED_HEAD" \
      "stage_landed_head_source=$STAGE_LANDED_HEAD_SOURCE" \
      "stage_landed_head_confirmed=$STAGE_LANDED_HEAD_CONFIRMED" "stage_reason=$evidence"
  fi
  reconcile_currentness activated
  next_for activated
}

do_show() {
  engineering_context show
  if [ -n "$FM_DISCIPLINE_RECEIPT" ]; then
    fm_discipline_render "$DATA" "$ID" ship implementation || refuse show ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
    printf '\n\n'
  fi
  fm_work_context_engineering_render "$DATA" "$ID" all all || refuse show ENGINEERING_CONTEXT "$FM_WORK_CONTEXT_DETAIL"
  local current
  current=$(meta stage)
  recorded_landed_head
  printf 'STAGE_RECORDED: %s task=%s gen=%s branch=%s head=%s predecessor_head=%s successor=%s landed_head=%s landed_confirmed=%s attempt=%s run=%s pr=%s reason=%s\n' \
    "${current:-none}" "$ID" "$(dash "$(meta stage_gen)")" "$(dash "$(meta stage_branch)")" \
    "$(dash "$(short "$(meta stage_head)")")" "$(dash "$(short "$(meta stage_predecessor_head)")")" "$(dash "$(meta stage_successor_id)")" \
    "$(dash "$(short "$(landed_head_value)")")" "$(dash "$STAGE_LANDED_HEAD_CONFIRMED")" \
    "$(dash "$(meta stage_attempt)")" "$(dash "$(meta stage_run)")" \
    "$(dash "$(meta stage_pr)")" "$(dash "$(meta stage_reason)")"
  next_for "$current"
}

case "$TRANSITION" in
  committed) do_committed ;;
  successor) do_successor ;;
  running) do_running running ;;
  ci-ready) do_ci_ready ;;
  landing) do_landing ;;
  activated) do_activated ;;
  show) do_show ;;
  *) die_usage "unknown transition '$TRANSITION'" ;;
esac
