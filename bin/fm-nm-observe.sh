#!/usr/bin/env bash
# fm-nm-observe.sh - single owner of the no-mistakes observation obligation:
# enrol a managed launch, bind the real run, record its canonical outcome, and
# reconcile the daemon's run inventory against every obligation this home holds.
#
# Usage:
#   fm-nm-observe.sh enrol    <task-id> [--entrypoint <name>]
#   fm-nm-observe.sh launch   <task-id> [--entrypoint <name>] [--retry]
#                             [--profile-json <file>] [--expect-nm-home <path>]
#                             [--expect-path0 <dir>]
#   fm-nm-observe.sh bind     <task-id> [--run <run-id>] [--accept-daemon-reset]
#   fm-nm-observe.sh refresh  <task-id> [--accept-daemon-reset]
#   fm-nm-observe.sh receipt  <task-id>
#   fm-nm-observe.sh finalize <task-id>
#   fm-nm-observe.sh reconcile [--startup | --now] [--peek]
#   fm-nm-observe.sh --help
#
# Why. Every managed no-mistakes launch in this home must carry a durable
# observation obligation so that a run which is never created, a run that is
# created but never bound to its task, a run the home never knew about, and a
# daemon whose identity changed under a bound run are each reported as a typed
# gap instead of vanishing. Existing owners keep their authority: the worker
# still drives `no-mistakes axi run`, bin/fm-crew-state.sh still owns current
# state, bin/fm-pr-check.sh and bin/fm-merge-outcome-lib.sh still own PR and
# merge records. This script only observes and records; it never starts,
# answers, aborts, syncs, or reruns a pipeline, never writes under NM_HOME, and
# never reads the daemon's SQLite. The verbs it sends to `no-mistakes` are
# exactly `axi status` and `axi status --run <id>`, both read-only.
#
# Records (this script is the only writer of each):
#   state/<id>.nm-observe            the obligation: key=value, fm-nm-observation/v1
#   data/<id>/nm-observation-receipt.md  the honest per-task coverage receipt,
#                                    rewritten from the obligation on every
#                                    mutation and by finalize; survives teardown
#   state/.nm-observe-watermark      reconcile's presentation cursor (what was
#                                    already reported); safe to delete, which
#                                    re-reports the current state once
#   state/.nm-observe-<id>.lock      per-obligation write lock (never the task's
#                                    meta lock, so teardown can finalize while it
#                                    holds that lock)
#
# Obligation fields (fm-nm-observation/v1):
#   record, task, home, project, repo_remote, entrypoint, stage,
#   enrolled_epoch, attempt_id, attempt_seq, predecessor_attempt_id,
#   predecessor_run_id, launch_epoch, candidate_branch, candidate_head,
#   nm_home, path0, nm_version, nm_build, profile_ready, policy, daemon_epoch,
#   preflight_refusal, run_id, run_head, run_branch, run_bound_epoch, run_status,
#   run_outcome, outcome_class, outcome_epoch, head_change, superseding_run,
#   pr, pr_head, publication, daemon_reset_observed, finalized_epoch.
#   stage is one of enrolled, launch-refused, launch-accepted, run-bound,
#   finalized. outcome_class is one of active, successful, failed, cancelled,
#   preflight-refused, ci-ready, or empty before any canonical read; the
#   later-head-change, repair-run, and late-merge classes are carried as the
#   head_change, superseding_run, and publication fields beside it so a
#   terminal class is never overwritten by a later event on the same run.
#
# Verbs:
#   enrol     Create the obligation for a kind=ship mode=no-mistakes task
#             (identity: home, project, repository remote, task). Idempotent.
#             Any other task is refused as NOT_MANAGED; a missing task record
#             is refused. bin/fm-spawn.sh and bin/fm-promote.sh call this so a
#             managed task carries the obligation from its first record.
#   launch    Admit one launch attempt BEFORE the worker is told to start the
#             pipeline. Enrols when needed, then records a fresh attempt id,
#             the candidate branch and head from the task worktree, the
#             qualified tool profile (bin/fm-tool-profile.sh --json --require
#             no-mistakes, run from THIS shell unless --profile-json supplies a
#             capture taken from the real consumer shell), the daemon epoch
#             read from <nm_home>/daemon.pid, and the repository policy digest
#             (.no-mistakes.yaml). A JSON null in the profile is an unset
#             identity: nm_home and path0 record empty, nm_version and
#             nm_build record `unobserved`. An unready profile is recorded as
#             stage=launch-refused with outcome_class=preflight-refused, keeps
#             the attempt id, never fabricates a run id, prints one typed
#             PREFLIGHT_REFUSED line, and exits 1. A second launch while the
#             current attempt has no run, or while its bound run is still
#             active, keeps that attempt (a resumed run keeps its identity);
#             --retry, or a bound run that is already terminal, opens a new
#             attempt linked to its predecessor attempt and run.
#   bind      After no-mistakes created the run, bind the ACTUAL run id from
#             `axi status` (or `axi status --run <id>` with --run) under
#             bin/fm-nm-run-lib.sh's attribution rules: same branch, and the
#             head matches the worktree or the pipeline owns the branch of an
#             active run. An explicit --run id is held to the same rule, so a
#             same-branch run left by earlier work on a reused branch name is
#             refused, never bound. No matching run is MISSING_BINDING (exit
#             1, nothing written, the reason named on the line). A retry
#             attempt never rebinds its predecessor run: the run id the
#             previous attempt bound is refused as MISSING_BINDING whether it
#             was named with --run or attributed from the inventory. A daemon
#             epoch that differs from the one recorded at
#             launch is DAEMON_RESET: the bind is refused rather than silently
#             rebound unless --accept-daemon-reset records the new epoch. A
#             different run id while one is already bound is refused with the
#             exact `launch --retry` heal. Binding the same run again is a
#             refresh.
#   refresh   Re-read the bound run's canonical record and update run_status,
#             run_outcome, outcome_class, head_change (the worktree moved off
#             the candidate head), superseding_run (a newer run on the same
#             branch), pr/pr_head from the task record, and
#             publication=merged:<provider>:<host>:<path>:<number> from the
#             merge-notification marker owned by bin/fm-pr-lib.sh (its version
#             tag on line 1, then provider, host, path, number); a marker that
#             does not carry that identity records no publication. Never
#             manufactures an outcome: with no bound run it records nothing
#             but the head and PR facts, and a query that fails or times out is
#             INVENTORY_UNAVAILABLE with the recorded class kept. Rewrites the
#             receipt.
#   receipt   Render data/<id>/nm-observation-receipt.md from the obligation.
#   finalize  Best-effort refresh plus receipt, marking stage=finalized; called
#             by bin/fm-teardown.sh before it removes the runtime record. Exit
#             0 even when the daemon is unreachable, so cleanup never blocks on
#             observation; the receipt then states what was not observed.
#   reconcile Read-only comparison of the canonical inventory (`axi status`
#             from each obligation's worktree, or its project checkout when the
#             worktree is gone) against every obligation and every managed task
#             record in this home. Prints one typed line per NEW or CHANGED
#             finding and nothing for unchanged state (the watermark owns that
#             memory). Finding classes:
#               UNENROLLED        managed task record with no obligation
#               MISSING_BINDING   launch accepted, no run for its branch after
#                                 FM_NM_OBSERVE_LAUNCH_GRACE_SECS; the worker's
#                                 endpoint liveness is reported beside it, and
#                                 a dead worker makes it LAUNCH_GAP (crash
#                                 between acceptance and run creation)
#               UNBOUND_RUN       a run exists for the accepted branch and head
#                                 but the obligation holds no run id (crash or
#                                 omission between run creation and binding);
#                                 for a retry attempt only rows strictly newer
#                                 than its predecessor run count
#               SUPERSEDED_RUN    a newer run on the bound branch than the one
#                                 bound (a retry or repair run to link)
#               OUTCOME_CHANGED   the bound run's canonical status or outcome
#                                 differs from what the obligation recorded; a
#                                 runs-table row carries status only, so its
#                                 canonical class prints as `unread`
#               RUN_VANISHED      the daemon answers that the bound run id is
#                                 not found, or a successful canonical read no
#                                 longer names it
#               DAEMON_RESET      <nm_home>/daemon.pid names a different daemon
#                                 than the watermark or an obligation recorded
#               UNMANAGED_RUN     an inventory run whose branch is owned by a
#                                 task record in this home that is not a
#                                 managed no-mistakes task (a direct-PR ship, a
#                                 scout, a hand-run): an uncovered entrypoint,
#                                 explicit coverage gap, never adopted
#               ORPHAN_RUN        an inventory run whose branch no task record
#                                 in this home owns (another home, a manual
#                                 launch, or an entrypoint this census does not
#                                 cover): an explicit coverage gap, never adopted
#               INVENTORY_UNAVAILABLE  the read-only query failed, timed out,
#                                 or exceeded the budget; obligations stay
#                                 pending with their recorded class, and the
#                                 watermark's run marks are carried forward so
#                                 a transient outage never re-reports a
#                                 baseline or already-reported row
#               PREFLIGHT_REFUSED a launch this home refused before any run
#               BASELINE          first reconcile in a home: pre-existing
#                                 inventory rows are recorded as uncovered
#                                 history, not adopted
#             Each line ends with the exact heal command when one exists.
#             A home with neither an obligation record nor a managed task
#             record stays completely silent and never queries: it has not
#             adopted observation, so nothing there can be a divergence. A
#             home whose only managed tasks are unenrolled reports them as
#             UNENROLLED without querying the inventory; the BASELINE is
#             recorded on the first pass that actually read the inventory.
#             Every uncovered inventory row is reported once per run id even
#             when several worktrees of one repository were queried, because
#             the daemon's table is repository-wide.
#             Cadence: at most once per FM_NM_OBSERVE_SECS (default 900) per
#             home unless --startup or --now; aggregate budget
#             FM_NM_OBSERVE_BUDGET_SECS (default 10) across every query, each
#             bounded by FM_NM_OBSERVE_TIMEOUT (default 8).
#             --peek computes and prints exactly what --now would against the
#             current watermark but never rewrites it (no baseline seeding, no
#             mark advanced; only the cursor's timestamp is refreshed so the
#             cadence gate keeps spacing the queries), so the findings are
#             still there for the consuming pass. A home's first pass belongs
#             to --startup or --now: a peek in a home with no cursor only
#             creates an empty one to start the cadence clock, and prints and
#             queries nothing until the cadence elapses. Wired into the locked session
#             start (bin/fm-session-start.sh) with --startup, which commits the
#             cursor because its lines are presented in the digest, and into
#             the watcher's poll loop (bin/fm-watch.sh) beside the
#             inactive-outcome scan as the non-consuming `reconcile --peek`,
#             which raises `check: nm-observe` when a line is printed; the
#             `reconcile --now` firstmate then runs prints the identical lines
#             and commits the cursor.
#
# Exit codes: 0 done; 1 typed refusal (NOT_MANAGED, MISSING_BINDING,
# PREFLIGHT_REFUSED, DAEMON_RESET, RUN_BOUND); 2 usage or an unreadable record.
# reconcile exits 0 whenever it could run, including when it printed findings.
#
# docs/no-mistakes-observation.md owns the entrypoint census and the coverage
# claims; docs/configuration.md routes the home layout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RECORD_SCHEMA=fm-nm-observation/v1
OBSERVE_SECS=${FM_NM_OBSERVE_SECS:-900}
BUDGET_SECS=${FM_NM_OBSERVE_BUDGET_SECS:-10}
CALL_TIMEOUT=${FM_NM_OBSERVE_TIMEOUT:-8}
LAUNCH_GRACE=${FM_NM_OBSERVE_LAUNCH_GRACE_SECS:-900}
WATERMARK="$STATE/.nm-observe-watermark"
WATERMARK_LOCK="$STATE/.nm-observe-watermark.lock"

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "error: $1" >&2
  echo "usage: fm-nm-observe.sh enrol|launch|bind|refresh|receipt|finalize <task-id> [flags] | reconcile [--startup|--now] [--peek] | --help" >&2
  exit 2
}

now_epoch() { date +%s; }

valid_task_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;;
  esac
  return 0
}

# --- record I/O -------------------------------------------------------------

record_path() { printf '%s/%s.nm-observe\n' "$STATE" "$1"; }
receipt_path() { printf '%s/%s/nm-observation-receipt.md\n' "$DATA" "$1"; }
lock_path() { printf '%s/.nm-observe-%s.lock\n' "$STATE" "$1"; }

record_get() {  # <record> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Replace or append key=value pairs in <record> atomically. Pairs arrive as
# key=value arguments; a value may be empty, which records the key as empty.
record_set() {  # <record> <key=value>...
  local record=$1 tmp kv key
  shift
  tmp="$record.tmp.$$"
  if [ -f "$record" ]; then
    cp -- "$record" "$tmp"
  else
    : > "$tmp"
  fi
  for kv in "$@"; do
    key=${kv%%=*}
    grep -v "^$key=" "$tmp" > "$tmp.next" 2>/dev/null || true
    printf '%s\n' "$kv" >> "$tmp.next"
    mv -f -- "$tmp.next" "$tmp"
  done
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$record"
}

record_load_or_die() {  # <task-id> -> sets RECORD, requires readable record
  RECORD=$(record_path "$1")
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || { echo "error: no observation obligation for $1 ($RECORD); run: bin/fm-nm-observe.sh enrol $1" >&2; exit 2; }
  [ "$(record_get "$RECORD" record)" = "$RECORD_SCHEMA" ] || { echo "error: unreadable observation obligation for $1 ($RECORD)" >&2; exit 2; }
}

with_lock() {  # <task-id> <fn> [args...]
  local id=$1 lock
  shift
  lock=$(lock_path "$id")
  local rc=0
  fm_lock_acquire_wait "$lock"
  "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# --- task facts -------------------------------------------------------------

meta_path() { printf '%s/%s.meta\n' "$STATE" "$1"; }

task_managed() {  # <meta> -> 0 when kind=ship and mode=no-mistakes
  [ -f "$1" ] || return 1
  [ "$(fm_meta_get "$1" kind)" = ship ] && [ "$(fm_meta_get "$1" mode)" = no-mistakes ]
}

# The task's own worktree, only while it exists: the sole source of a task's
# branch ownership and candidate identity. The project checkout is never a
# task's branch; it is only a place to run the read-only inventory query.
task_worktree() {  # <meta>
  local wt
  wt=$(fm_meta_get "$1" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] && printf '%s' "$wt" || true
}

task_dir() {  # <meta> -> worktree when it exists, else project, else empty
  local wt proj
  wt=$(fm_meta_get "$1" worktree)
  proj=$(fm_meta_get "$1" project)
  if [ -n "$wt" ] && [ -d "$wt" ]; then printf '%s' "$wt"
  elif [ -n "$proj" ] && [ -d "$proj" ]; then printf '%s' "$proj"
  fi
}

repo_remote() {  # <dir>
  git -C "$1" remote get-url origin 2>/dev/null || printf 'unknown'
}

candidate_branch() {  # <dir>
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

candidate_head() {  # <dir>
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

policy_digest() {  # <dir>
  local f="$1/.no-mistakes.yaml" d
  [ -f "$f" ] || { printf 'absent'; return 0; }
  d=$(fm_pr_sha256 "$f" 2>/dev/null || true)
  [ -n "$d" ] && printf 'sha256:%s' "$d" || printf 'unreadable'
}

# The daemon's identity as the daemon itself publishes it: <nm_home>/daemon.pid
# is a small JSON object {"pid":N,"started_at":"..."} written by the daemon on
# start. It is read, never written, and the identity is pid@started_at.
daemon_epoch() {  # <nm_home>
  local f="$1/daemon.pid" pid started
  [ -n "$1" ] && [ -f "$f" ] || { printf 'unobserved'; return 0; }
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  started=$(sed -n 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
  [ -n "$pid" ] && [ -n "$started" ] || { printf 'unobserved'; return 0; }
  printf '%s@%s' "$pid" "$started"
}

# One scalar from the tool profile JSON without a JSON parser dependency: the
# record is single-line and every value this reads is a plain string, number,
# or boolean under a unique key.
profile_json_scalar() {  # <json> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1
}

profile_tool_field() {  # <json> <tool> <field>
  printf '%s' "$1" | tr '{' '\n' | grep "\"tool\":\"$2\"" | head -1 \
    | sed -n "s/.*\"$3\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1
}

attempt_id() {
  local rand
  rand=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand=$$
  printf '%s-%s' "$(now_epoch)" "$rand"
}

# --- canonical inventory ----------------------------------------------------

nm_available() { command -v no-mistakes >/dev/null 2>&1; }

# TSV rows id<TAB>branch<TAB>status<TAB>head<TAB>pr from the runs[N]{...} table
# in captured `axi status` TOON. Values may be double-quoted.
inventory_rows() {  # <toon>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*runs\[[0-9]+\]\{id,branch,status,head,pr\}:/ { intable = 1; next }
    intable && /^[[:space:]]+"?[A-Z0-9]+"?,/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = split(line, f, ",")
      if (n < 4) next
      for (i = 1; i <= n; i++) { gsub(/^"|"$/, "", f[i]) }
      pr = (n >= 5) ? f[5] : ""
      printf "%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], pr
      next
    }
    intable && !/^[[:space:]]/ { intable = 0 }
  '
}

run_field() {  # <toon> <key>
  fm_nm_strip_quotes "$(fm_nm_field "$1" "$2")"
}

outcome_class_of() {  # <status> <outcome>
  local status=$1 outcome=$2
  case "$outcome" in
    passed) printf 'successful'; return 0 ;;
    checks-passed) printf 'ci-ready'; return 0 ;;
    failed) printf 'failed'; return 0 ;;
    cancelled) printf 'cancelled'; return 0 ;;
  esac
  case "$status" in
    completed) printf 'successful' ;;
    failed) printf 'failed' ;;
    cancelled) printf 'cancelled' ;;
    *) printf 'active' ;;
  esac
}

terminal_class() {  # <class>
  case "$1" in successful|failed|cancelled|preflight-refused) return 0 ;; esac
  return 1
}

# --- receipt ----------------------------------------------------------------

render_receipt() {  # <task-id>
  local id=$1 record dir out tmp stage class run pr head cand merged reset superseded preflight branch attempt
  record=$(record_path "$id")
  [ -f "$record" ] || return 0
  dir="$DATA/$id"
  mkdir -p "$dir"
  out=$(receipt_path "$id")
  tmp="$out.tmp.$$"
  stage=$(record_get "$record" stage)
  class=$(record_get "$record" outcome_class)
  run=$(record_get "$record" run_id)
  pr=$(record_get "$record" pr)
  head=$(record_get "$record" run_head)
  cand=$(record_get "$record" candidate_head)
  branch=$(record_get "$record" candidate_branch)
  attempt=$(record_get "$record" attempt_id)
  merged=$(record_get "$record" publication)
  reset=$(record_get "$record" daemon_reset_observed)
  superseded=$(record_get "$record" superseding_run)
  preflight=$(record_get "$record" preflight_refusal)
  {
    printf '# no-mistakes observation receipt: %s\n\n' "$id"
    printf 'Rendered %s by bin/fm-nm-observe.sh from state/%s.nm-observe (%s).\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$RECORD_SCHEMA"
    printf 'This receipt states what was observed and what was not; it grants nothing and is not a run outcome.\n\n'
    printf '## Identity\n\n'
    printf -- '- home: %s\n' "$(record_get "$record" home)"
    printf -- '- project: %s\n' "$(record_get "$record" project)"
    printf -- '- repository remote: %s\n' "$(record_get "$record" repo_remote)"
    printf -- '- entrypoint: %s\n' "$(record_get "$record" entrypoint)"
    printf -- '- stage: %s\n' "${stage:-unknown}"
    printf -- '- launch attempt: %s (sequence %s, predecessor attempt %s, predecessor run %s)\n' \
      "${attempt:-none}" "$(record_get "$record" attempt_seq)" "$(record_get "$record" predecessor_attempt_id)" "$(record_get "$record" predecessor_run_id)"
    printf -- '- candidate: branch %s head %s\n' "${branch:-unknown}" "${cand:-unknown}"
    printf -- '- runtime profile: NM_HOME=%s PATH[0]=%s no-mistakes %s build %s ready=%s\n' \
      "$(record_get "$record" nm_home)" "$(record_get "$record" path0)" "$(record_get "$record" nm_version)" "$(record_get "$record" nm_build)" "$(record_get "$record" profile_ready)"
    printf -- '- policy: %s\n' "$(record_get "$record" policy)"
    printf -- '- daemon epoch at launch: %s\n\n' "$(record_get "$record" daemon_epoch)"
    printf '## Observed\n\n'
    if [ -n "$run" ]; then
      printf -- '- run %s bound at %s (branch %s, head %s)\n' "$run" "$(record_get "$record" run_bound_epoch)" "$(record_get "$record" run_branch)" "${head:-unknown}"
      printf -- '- canonical status %s outcome %s -> class %s (read at %s)\n' \
        "$(record_get "$record" run_status)" "$(record_get "$record" run_outcome)" "${class:-unread}" "$(record_get "$record" outcome_epoch)"
    else
      printf -- '- no run id bound\n'
    fi
    [ -z "$preflight" ] || printf -- '- preflight refused: %s\n' "$preflight"
    [ -z "$pr" ] || printf -- '- PR %s (head %s)\n' "$pr" "$(record_get "$record" pr_head)"
    [ -z "$merged" ] || printf -- '- publication: %s\n' "$merged"
    [ -z "$(record_get "$record" head_change)" ] || printf -- '- later head change: worktree now at %s\n' "$(record_get "$record" head_change)"
    [ -z "$superseded" ] || printf -- '- repair or retry run observed: %s (not bound to this attempt)\n' "$superseded"
    printf '\n## Not observed\n\n'
    [ -n "$run" ] || printf -- '- the run id: this attempt has no bound run, so nothing about the pipeline itself was observed\n'
    [ -n "$class" ] || printf -- '- a canonical outcome: no status was ever read for this attempt\n'
    { [ -n "$class" ] && terminal_class "$class"; } || printf -- '- a terminal outcome\n'
    [ -n "$pr" ] || printf -- '- a PR record\n'
    [ -n "$merged" ] || printf -- '- a merge or publication\n'
    printf -- '- IPC run, step, and CI-readiness events: no owner in this home subscribes to them; every fact above came from a canonical read\n'
    printf '\n## Gaps\n\n'
    case "$stage" in
      enrolled) printf -- '- launch not yet admitted through bin/fm-nm-observe.sh launch %s\n' "$id" ;;
      launch-refused) printf -- '- launch refused before any run; the attempt identity is retained and no run id exists\n' ;;
      launch-accepted) printf -- '- launch accepted, run not bound: bin/fm-nm-observe.sh bind %s once the run exists\n' "$id" ;;
    esac
    [ -z "$reset" ] || printf -- '- daemon identity changed after launch (observed %s); outcomes were read by run id, not rebound\n' "$reset"
    [ -z "$superseded" ] || printf -- '- superseding run %s is unlinked: bin/fm-nm-observe.sh launch %s --retry, then bind\n' "$superseded" "$id"
    if [ "$stage" = finalized ]; then
      printf -- '- finalized at %s; nothing after this point is observed for this task\n' "$(record_get "$record" finalized_epoch)"
    fi
    printf -- '- captured eval cases are review evidence, never launch coverage, and are not counted here\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$out"
}

# --- verbs ------------------------------------------------------------------

do_enrol() {  # <task-id> <entrypoint>
  local id=$1 entry=$2 meta record dir
  meta=$(meta_path "$id")
  [ -f "$meta" ] || { echo "error: no task record for $id ($meta)" >&2; exit 2; }
  if ! task_managed "$meta"; then
    printf 'NM_OBSERVE: NOT_MANAGED task=%s kind=%s mode=%s reason=only kind=ship mode=no-mistakes tasks carry a no-mistakes observation obligation\n' \
      "$id" "$(fm_meta_get "$meta" kind)" "$(fm_meta_get "$meta" mode)"
    return 1
  fi
  record=$(record_path "$id")
  if [ -f "$record" ]; then
    printf 'NM_OBSERVE: ENROLLED task=%s stage=%s (already enrolled)\n' "$id" "$(record_get "$record" stage)"
    return 0
  fi
  dir=$(task_dir "$meta")
  record_set "$record" \
    "record=$RECORD_SCHEMA" \
    "task=$id" \
    "home=$FM_HOME" \
    "project=$(fm_meta_get "$meta" project)" \
    "repo_remote=$([ -n "$dir" ] && repo_remote "$dir" || printf 'unknown')" \
    "entrypoint=$entry" \
    "stage=enrolled" \
    "enrolled_epoch=$(now_epoch)" \
    "attempt_seq=0"
  render_receipt "$id"
  printf 'NM_OBSERVE: ENROLLED task=%s entrypoint=%s\n' "$id" "$entry"
}

do_launch() {  # <task-id> <entrypoint> <retry 0|1> <profile-json-file> <expect-nm-home> <expect-path0>
  local id=$1 entry=$2 retry=$3 profile_file=$4 expect_home=$5 expect_path0=$6
  local meta record dir wt stage run class attempt seq pred_a pred_r json rc=0 ready nm_home path0 ver build unready branch head epoch
  meta=$(meta_path "$id")
  [ -f "$meta" ] || { echo "error: no task record for $id ($meta)" >&2; exit 2; }
  task_managed "$meta" || { do_enrol "$id" "$entry" || return 1; }
  record=$(record_path "$id")
  [ -f "$record" ] || { do_enrol "$id" "$entry" >/dev/null || return 1; }
  stage=$(record_get "$record" stage)
  run=$(record_get "$record" run_id)
  class=$(record_get "$record" outcome_class)
  attempt=$(record_get "$record" attempt_id)
  seq=$(record_get "$record" attempt_seq)
  pred_a=
  pred_r=
  if [ -n "$attempt" ]; then
    if [ "$retry" -eq 0 ]; then
      case "$stage" in
        launch-accepted)
          printf 'NM_OBSERVE: LAUNCH_ACCEPTED task=%s attempt=%s (existing attempt has no run yet; bind it, or pass --retry to open a new attempt)\n' "$id" "$attempt"
          return 0 ;;
        run-bound)
          if ! terminal_class "${class:-active}"; then
            printf 'NM_OBSERVE: RUN_BOUND task=%s attempt=%s run=%s class=%s (a resumed run keeps its identity; pass --retry only for a genuinely new run)\n' "$id" "$attempt" "$run" "${class:-active}"
            return 1
          fi ;;
      esac
    fi
    pred_a=$attempt
    pred_r=$run
  fi
  dir=$(task_dir "$meta")
  wt=$(task_worktree "$meta")
  branch=$([ -n "$wt" ] && candidate_branch "$wt" || true)
  head=$([ -n "$wt" ] && candidate_head "$wt" || true)
  if [ -n "$profile_file" ]; then
    json=$(cat "$profile_file") || { echo "error: unreadable --profile-json $profile_file" >&2; exit 2; }
  else
    set -- --json --require no-mistakes
    [ -z "$expect_home" ] || set -- "$@" --expect-nm-home "$expect_home"
    [ -z "$expect_path0" ] || set -- "$@" --expect-path0 "$expect_path0"
    json=$("$SCRIPT_DIR/fm-tool-profile.sh" "$@" 2>/dev/null) || rc=$?
    [ "$rc" -le 1 ] || { echo "error: bin/fm-tool-profile.sh could not observe the profile (exit $rc)" >&2; exit 2; }
  fi
  ready=$(profile_json_scalar "$json" ready)
  nm_home=$(profile_json_scalar "$json" nm_home)
  path0=$(profile_json_scalar "$json" path0)
  ver=$(profile_tool_field "$json" no-mistakes version)
  build=$(profile_tool_field "$json" no-mistakes detail)
  build=${build#build }
  [ "$nm_home" != null ] || nm_home=
  [ "$path0" != null ] || path0=
  [ "$ver" != null ] || ver=
  [ "$build" != null ] || build=
  [ "$(profile_tool_field "$json" no-mistakes state)" = QUALIFIED ] || ready=false
  epoch=$(daemon_epoch "$nm_home")
  seq=$(( ${seq:-0} + 1 ))
  attempt=$(attempt_id)
  record_set "$record" \
    "entrypoint=$entry" \
    "attempt_id=$attempt" \
    "attempt_seq=$seq" \
    "predecessor_attempt_id=$pred_a" \
    "predecessor_run_id=$pred_r" \
    "launch_epoch=$(now_epoch)" \
    "candidate_branch=$branch" \
    "candidate_head=$head" \
    "nm_home=$nm_home" \
    "path0=$path0" \
    "nm_version=${ver:-unobserved}" \
    "nm_build=${build:-unobserved}" \
    "profile_ready=${ready:-false}" \
    "policy=$([ -n "$dir" ] && policy_digest "$dir" || printf 'unknown')" \
    "daemon_epoch=$epoch" \
    "run_id=" "run_head=" "run_branch=" "run_bound_epoch=" "run_status=" "run_outcome=" \
    "outcome_class=" "outcome_epoch=" "head_change=" "superseding_run=" "daemon_reset_observed="
  if [ "$ready" != true ]; then
    unready=$(printf '%s' "$json" | tr '{' '\n' | grep -o '"unready":\[[^]]*\]' | head -1 | sed 's/"unready":\[//; s/\]$//; s/"//g')
    [ -n "$unready" ] || unready="no-mistakes not QUALIFIED in the observed profile"
    record_set "$record" "stage=launch-refused" "outcome_class=preflight-refused" "outcome_epoch=$(now_epoch)" "preflight_refusal=$unready"
    render_receipt "$id"
    printf 'NM_OBSERVE: PREFLIGHT_REFUSED task=%s attempt=%s profile=%s (no run id exists; repair the environment, then re-run launch)\n' "$id" "$attempt" "$unready"
    return 1
  fi
  record_set "$record" "stage=launch-accepted" "preflight_refusal="
  render_receipt "$id"
  printf 'NM_OBSERVE: LAUNCH_ACCEPTED task=%s attempt=%s branch=%s head=%s daemon=%s%s\n' \
    "$id" "$attempt" "${branch:-detached}" "${head:0:12}" "$epoch" \
    "$([ -n "$pred_r" ] && printf ' predecessor_run=%s' "$pred_r" || true)"
}

# Leave in ATTR_TOON the canonical record for the run bin/fm-nm-run-lib.sh
# attributes to <dir>'s branch, else return 1 with the typed reason in
# ATTR_REASON (both globals, so the caller never needs a subshell). With
# <run-id>, that exact run when it belongs to <branch>; <check-head> 1 holds
# it to the head rule too (a fresh binding), 0 re-reads an already bound run.
ATTR_REASON=
ATTR_TOON=
attributed_run_toon() {  # <dir> <branch> <run-id-or-empty> <timeout> <check-head 0|1>
  local dir=$1 branch=$2 want=$3 t=$4 check=$5 out rb rh
  ATTR_REASON=
  ATTR_TOON=
  if [ -n "$want" ]; then
    out=$(fm_nm_run_checked "$dir" "$t" axi status --run "$want") \
      || { ATTR_REASON="run $want is not readable from the canonical inventory"; return 1; }
    [ "$(run_field "$out" id)" = "$want" ] \
      || { ATTR_REASON="the canonical record does not name run $want"; return 1; }
    rb=$(run_field "$out" branch)
    [ "$rb" = "$branch" ] \
      || { ATTR_REASON="run $want is on branch ${rb:-none}, not $branch"; return 1; }
    if [ "$check" -eq 1 ]; then
      rh=$(run_field "$out" head)
      fm_nm_head_matches_worktree "$dir" "$rh" || fm_nm_run_is_pipeline_owned_active "$out" \
        || { ATTR_REASON="run $want head ${rh:-none} matches neither the worktree head nor a pipeline-owned active run; a same-branch run is never bound by name alone"; return 1; }
    fi
    ATTR_TOON=$out
    return 0
  fi
  out=$(fm_nm_run_checked "$dir" "$t" axi status) \
    || { ATTR_REASON="the canonical inventory is not readable"; return 1; }
  rb=$(run_field "$out" branch)
  [ -n "$rb" ] && [ "$rb" = "$branch" ] \
    || { ATTR_REASON="no run on branch $branch"; return 1; }
  rh=$(run_field "$out" head)
  fm_nm_head_matches_worktree "$dir" "$rh" || fm_nm_run_is_pipeline_owned_active "$out" \
    || { ATTR_REASON="run head ${rh:-none} matches neither the worktree head nor a pipeline-owned active run"; return 1; }
  ATTR_TOON=$out
}

do_bind() {  # <task-id> <run-id-or-empty> <accept-reset 0|1>
  local id=$1 want=$2 accept=$3 meta record dir wt branch out run status outcome class have pred epoch recorded
  meta=$(meta_path "$id")
  record_load_or_die "$id"
  record=$RECORD
  dir=$(task_dir "$meta")
  [ -n "$dir" ] || { printf 'NM_OBSERVE: MISSING_BINDING task=%s reason=no worktree or project directory to query\n' "$id"; return 1; }
  branch=$(record_get "$record" candidate_branch)
  [ -n "$branch" ] || { wt=$(task_worktree "$meta"); [ -z "$wt" ] || branch=$(candidate_branch "$wt"); }
  [ -n "$branch" ] || { printf 'NM_OBSERVE: MISSING_BINDING task=%s reason=no candidate branch recorded and the task worktree is gone\n' "$id"; return 1; }
  have=$(record_get "$record" run_id)
  pred=$(record_get "$record" predecessor_run_id)
  nm_available || { printf 'NM_OBSERVE: MISSING_BINDING task=%s reason=no-mistakes not on PATH\n' "$id"; return 1; }
  if [ -z "$have" ] && [ -n "$pred" ] && [ "$want" = "$pred" ]; then
    printf 'NM_OBSERVE: MISSING_BINDING task=%s branch=%s run=%s reason=predecessor run %s is not a new run (this attempt binds only a run created after it; nothing recorded)\n' "$id" "$branch" "$want" "$pred"
    return 1
  fi
  if [ -n "$have" ] && [ -n "$want" ] && [ "$want" != "$have" ]; then
    printf 'NM_OBSERVE: RUN_BOUND task=%s run=%s refused=%s (one attempt binds one run; heal: bin/fm-nm-observe.sh launch %s --retry && bin/fm-nm-observe.sh bind %s --run %s)\n' \
      "$id" "$have" "$want" "$id" "$id" "$want"
    return 1
  fi
  if ! attributed_run_toon "$dir" "$branch" "${want:-$have}" "$CALL_TIMEOUT" "$([ -z "$have" ] && printf 1 || printf 0)"; then
    printf 'NM_OBSERVE: MISSING_BINDING task=%s branch=%s%s reason=%s (nothing recorded)\n' \
      "$id" "$branch" "$([ -n "$want" ] && printf ' run=%s' "$want" || true)" "$ATTR_REASON"
    return 1
  fi
  out=$ATTR_TOON
  run=$(run_field "$out" id)
  [ -n "$run" ] || { printf 'NM_OBSERVE: MISSING_BINDING task=%s reason=canonical record carries no run id\n' "$id"; return 1; }
  if [ -z "$have" ] && [ -n "$pred" ] && [ "$run" = "$pred" ]; then
    printf 'NM_OBSERVE: MISSING_BINDING task=%s branch=%s run=%s reason=predecessor run %s is not a new run (this attempt binds only a run created after it; nothing recorded)\n' "$id" "$branch" "$run" "$pred"
    return 1
  fi
  if [ -n "$have" ] && [ "$have" != "$run" ]; then
    printf 'NM_OBSERVE: RUN_BOUND task=%s run=%s refused=%s (one attempt binds one run; heal: bin/fm-nm-observe.sh launch %s --retry && bin/fm-nm-observe.sh bind %s --run %s)\n' \
      "$id" "$have" "$run" "$id" "$id" "$run"
    return 1
  fi
  recorded=$(record_get "$record" daemon_epoch)
  epoch=$(daemon_epoch "$(record_get "$record" nm_home)")
  if [ -z "$have" ] && [ -n "$recorded" ] && [ "$recorded" != unobserved ] && [ "$epoch" != "$recorded" ]; then
    if [ "$accept" -eq 0 ]; then
      printf 'NM_OBSERVE: DAEMON_RESET task=%s recorded=%s observed=%s (not rebound; heal: bin/fm-nm-observe.sh bind %s --accept-daemon-reset)\n' \
        "$id" "$recorded" "$epoch" "$id"
      return 1
    fi
    record_set "$record" "daemon_reset_observed=$epoch" "daemon_epoch=$epoch"
  fi
  status=$(run_field "$out" status)
  outcome=$(run_field "$out" outcome)
  class=$(outcome_class_of "$status" "$outcome")
  if [ -z "$have" ]; then
    record_set "$record" "stage=run-bound" "run_id=$run" "run_head=$(run_field "$out" head)" \
      "run_branch=$(run_field "$out" branch)" "run_bound_epoch=$(now_epoch)"
  fi
  record_set "$record" "run_status=$status" "run_outcome=$outcome" "outcome_class=$class" "outcome_epoch=$(now_epoch)"
  refresh_side_facts "$id" "$meta" "$record" "$dir" "$out"
  render_receipt "$id"
  printf 'NM_OBSERVE: %s task=%s run=%s status=%s class=%s\n' "$([ -z "$have" ] && printf 'RUN_BOUND' || printf 'REFRESHED')" "$id" "$run" "$status" "$class"
}

# The PR identity carried by the merge-notification marker bin/fm-pr-lib.sh
# writes (fm_pr_poll_merge_mark_notified): the version tag on line 1, then
# provider, host, path, and number, nothing after. Any other shape carries no
# identity and binds nothing.
merge_marker_identity() {  # <marker> -> provider:host:path:number
  local version provider host path number extra
  { IFS= read -r version && IFS= read -r provider && IFS= read -r host \
      && IFS= read -r path && IFS= read -r number && ! IFS= read -r extra; } < "$1" || return 1
  [ "$version" = fm-pr-poll-merge-notified-v1 ] && [ -n "$provider" ] && [ -n "$host" ] \
    && [ -n "$path" ] && [ -n "$number" ] || return 1
  printf '%s:%s:%s:%s' "$provider" "$host" "$path" "$number"
}

# PR, publication, head-change, and superseding-run facts read from this home's
# own records and from the inventory table already captured in <toon>.
refresh_side_facts() {  # <task-id> <meta> <record> <dir> <toon>
  local id=$1 meta=$2 record=$3 dir=$4 toon=$5 pr pr_head marker ident cand cur run rows newer wt
  pr=$(fm_meta_get "$meta" pr)
  pr_head=$(fm_meta_get "$meta" pr_head)
  [ -z "$pr" ] || record_set "$record" "pr=$pr" "pr_head=$pr_head"
  marker="$STATE/$id.pr-poll-merge-notified"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    ident=$(merge_marker_identity "$marker") && record_set "$record" "publication=merged:$ident"
  fi
  cand=$(record_get "$record" candidate_head)
  wt=$(task_worktree "$meta")
  cur=$([ -n "$wt" ] && candidate_head "$wt" || true)
  if [ -n "$cand" ] && [ -n "$cur" ] && [ "$cand" != "$cur" ]; then
    record_set "$record" "head_change=$cur"
  fi
  run=$(record_get "$record" run_id)
  [ -n "$run" ] || return 0
  rows=$(inventory_rows "$toon")
  [ -n "$rows" ] || return 0
  newer=$(printf '%s\n' "$rows" | awk -F '\t' -v b="$(record_get "$record" run_branch)" -v r="$run" '
    $1 == r { exit }
    $2 == b { print $1; exit }
  ')
  [ -z "$newer" ] || record_set "$record" "superseding_run=$newer"
}

do_refresh() {  # <task-id> <accept-reset 0|1>
  local id=$1 accept=$2 meta record dir run out status outcome class epoch recorded rc=0
  meta=$(meta_path "$id")
  record_load_or_die "$id"
  record=$RECORD
  dir=$(task_dir "$meta")
  run=$(record_get "$record" run_id)
  if [ -z "$run" ]; then
    refresh_side_facts "$id" "$meta" "$record" "$dir" ""
    render_receipt "$id"
    printf 'NM_OBSERVE: REFRESHED task=%s run= class=%s (no bound run; only head and PR facts were read)\n' "$id" "$(record_get "$record" outcome_class)"
    return 0
  fi
  if [ -z "$dir" ] || ! nm_available; then
    render_receipt "$id"
    printf 'NM_OBSERVE: INVENTORY_UNAVAILABLE task=%s run=%s reason=%s\n' "$id" "$run" "$([ -z "$dir" ] && printf 'no directory to query' || printf 'no-mistakes not on PATH')"
    return 0
  fi
  recorded=$(record_get "$record" daemon_epoch)
  epoch=$(daemon_epoch "$(record_get "$record" nm_home)")
  if [ -n "$recorded" ] && [ "$recorded" != unobserved ] && [ "$epoch" != "$recorded" ] && [ "$(record_get "$record" daemon_reset_observed)" != "$epoch" ]; then
    record_set "$record" "daemon_reset_observed=$epoch"
    [ "$accept" -eq 0 ] || record_set "$record" "daemon_epoch=$epoch"
    printf 'NM_OBSERVE: DAEMON_RESET task=%s recorded=%s observed=%s (outcome read by run id, not rebound)\n' "$id" "$recorded" "$epoch"
  fi
  out=$(fm_nm_run_checked "$dir" "$CALL_TIMEOUT" axi status --run "$run") || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && fm_nm_status_is_run_not_found "$out" "$run"; then
    render_receipt "$id"
    printf 'NM_OBSERVE: RUN_VANISHED task=%s run=%s (the daemon reports this run as not found; recorded class %s kept)\n' "$id" "$run" "$(record_get "$record" outcome_class)"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    render_receipt "$id"
    printf 'NM_OBSERVE: INVENTORY_UNAVAILABLE task=%s run=%s reason=query failed or timed out (recorded class %s kept)\n' "$id" "$run" "$(record_get "$record" outcome_class)"
    return 0
  fi
  if [ "$(run_field "$out" id)" != "$run" ]; then
    render_receipt "$id"
    printf 'NM_OBSERVE: RUN_VANISHED task=%s run=%s (a successful canonical read no longer names this run; recorded class %s kept)\n' "$id" "$run" "$(record_get "$record" outcome_class)"
    return 0
  fi
  status=$(run_field "$out" status)
  outcome=$(run_field "$out" outcome)
  class=$(outcome_class_of "$status" "$outcome")
  record_set "$record" "run_status=$status" "run_outcome=$outcome" "outcome_class=$class" "outcome_epoch=$(now_epoch)"
  refresh_side_facts "$id" "$meta" "$record" "$dir" "$out"
  render_receipt "$id"
  printf 'NM_OBSERVE: REFRESHED task=%s run=%s status=%s class=%s\n' "$id" "$run" "$status" "$class"
}

do_finalize() {  # <task-id>
  local id=$1 record
  record=$(record_path "$id")
  [ -f "$record" ] || return 0
  do_refresh "$id" 0 || true
  record_set "$record" "stage=finalized" "finalized_epoch=$(now_epoch)"
  render_receipt "$id"
  printf 'NM_OBSERVE: FINALIZED task=%s receipt=%s\n' "$id" "$(receipt_path "$id")"
}

# --- reconcile --------------------------------------------------------------

RECON_LINES=
RECON_MARKS=
# Record <line> under <key> in this pass's watermark and print it only when the
# watermark did not already hold the same key and digest; a key already
# recorded in this pass (the same run row read from two worktrees of one
# repository) is not recorded or printed again. "silent" records the
# mark without ever printing (the baseline), so an unchanged row stays quiet on
# every later pass and a changed one is printed once. An age is presentation,
# not a change, so it is left out of the digest.
recon_emit() {  # <key> <line> [silent]
  local key=$1 line=$2 digest
  ! printf '%s' "$RECON_MARKS" | cut -f1 | grep -qxF -- "$key" || return 0
  digest=$(printf '%s' "$line" | sed 's/ age=[0-9]*s//' | cksum | awk '{print $1}')
  RECON_MARKS="${RECON_MARKS}${key}"$'\t'"${digest}"$'\n'
  [ "${3:-}" != silent ] || return 0
  if ! printf '%s' "$WM_OLD" | grep -qxF "${key}"$'\t'"${digest}"; then
    RECON_LINES="${RECON_LINES}${line}"$'\n'
  fi
}

recon_due() {  # <startup 0|1> <now 0|1>
  [ "$1" -eq 1 ] || [ "$2" -eq 1 ] && return 0
  [ -f "$WATERMARK" ] || return 0
  local age
  age=$(( $(now_epoch) - $(stat -c %Y "$WATERMARK" 2>/dev/null || stat -f %m "$WATERMARK" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$OBSERVE_SECS" ]
}

worker_alive() {  # <meta> -> alive|dead|unknown
  local backend target window
  window=$(fm_meta_get "$1" window)
  [ -n "$window" ] || { printf 'unknown'; return 0; }
  backend=$(fm_backend_of_meta "$1")
  target=$(fm_backend_target_of_meta "$1")
  if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$(fm_meta_get "$1" endpoint_task_id)" 2>/dev/null; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

do_reconcile() {  # <startup 0|1> <now 0|1> <peek 0|1>
  local startup=$1 force=$2 peek=$3 deadline meta id record dir wt rows line first=0 rid rbranch rstatus rhead rpr n owner branch key keys
  local any=0 reads_ok=0
  for record in "$STATE"/*.nm-observe; do
    [ -f "$record" ] || continue
    any=1
    break
  done
  if [ "$any" -eq 0 ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      task_managed "$meta" || continue
      any=1
      break
    done
  fi
  [ "$any" -eq 1 ] || return 0
  # A home's first pass belongs to a consuming owner (--startup or --now):
  # the watcher's peek only starts the cadence clock with an empty cursor (no
  # mark, nothing consumed) so it cannot re-report the same finding on every
  # poll and starve the rest of the watcher's cycle.
  if [ "$peek" -eq 1 ] && [ "$force" -eq 0 ] && [ ! -f "$WATERMARK" ]; then
    fm_lock_acquire_wait "$WATERMARK_LOCK"
    if [ ! -f "$WATERMARK" ]; then
      : > "$WATERMARK.tmp.$$"
      chmod 0600 "$WATERMARK.tmp.$$"
      mv -f -- "$WATERMARK.tmp.$$" "$WATERMARK"
    fi
    fm_lock_release "$WATERMARK_LOCK"
    return 0
  fi
  recon_due "$startup" "$force" || return 0
  fm_lock_acquire_wait "$WATERMARK_LOCK"
  WM_OLD=$(cat "$WATERMARK" 2>/dev/null || true)
  # The baseline is the first pass that actually read the inventory; the
  # `inventory` mark records that it happened.
  printf '%s\n' "$WM_OLD" | grep -q '^inventory'$'\t' || first=1
  deadline=$(( $(now_epoch) + BUDGET_SECS ))
  local nm_ok=1
  nm_available || nm_ok=0
  INV_FAILED=0
  # Pass 1: every task record. Each branch remembers its owning task for pass
  # 2 (a managed owner always wins a shared branch); only managed tasks are
  # reconciled. Ownership comes from the task's own worktree alone: a detached
  # HEAD or a gone worktree owns nothing, and the project checkout's branch is
  # never a task's branch.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    dir=$(task_dir "$meta")
    wt=$(task_worktree "$meta")
    branch=$([ -n "$wt" ] && candidate_branch "$wt" || true)
    if task_managed "$meta"; then
      owner="managed $id"
    else
      owner="unmanaged $id kind=$(fm_meta_get "$meta" kind || true) mode=$(fm_meta_get "$meta" mode || true)"
    fi
    if [ -n "$branch" ]; then
      case "${TASK_BRANCHES[$branch]:-}" in managed*) ;; *) TASK_BRANCHES[$branch]=$owner ;; esac
    fi
    task_managed "$meta" || continue
    record=$(record_path "$id")
    if [ ! -f "$record" ]; then
      recon_emit "task:$id" "NM_OBSERVE: UNENROLLED task=$id (managed no-mistakes task with no observation obligation; heal: bin/fm-nm-observe.sh enrol $id)"
      continue
    fi
    branch=$(record_get "$record" candidate_branch)
    [ -z "$branch" ] || TASK_BRANCHES[$branch]="managed $id"
    reconcile_task "$id" "$meta" "$record" "$dir"
  done
  # Pass 2: inventory rows no obligation covers, and the daemon identity.
  for dir in "${!INVENTORY_BY_DIR[@]}"; do
    [ "${INV_OK_BY_DIR[$dir]}" = 1 ] || continue
    reads_ok=1
    rows=${INVENTORY_BY_DIR[$dir]}
    [ -n "$rows" ] || continue
    while IFS=$'\t' read -r rid rbranch rstatus rhead rpr; do
      [ -n "$rid" ] || continue
      owner=
      [ -z "$rbranch" ] || owner=${TASK_BRANCHES[$rbranch]:-}
      case "$owner" in
        managed*) continue ;;
        unmanaged*)
          line="NM_OBSERVE: UNMANAGED_RUN run=$rid branch=$rbranch status=$rstatus head=$rhead pr=${rpr:-none} task=${owner#unmanaged } (this branch belongs to a task record in this home that is not a managed no-mistakes task: an uncovered entrypoint; explicit coverage gap, not adopted)" ;;
        *)
          line="NM_OBSERVE: ORPHAN_RUN run=$rid branch=${rbranch:-none} status=$rstatus head=$rhead pr=${rpr:-none} (no task record in this home owns this branch: another home, a manual launch, or an uncovered entrypoint; explicit coverage gap, not adopted)" ;;
      esac
      if [ "$first" -eq 1 ]; then
        recon_emit "run:$rid" "$line" silent
      else
        recon_emit "run:$rid" "$line"
      fi
    done <<< "$rows"
  done
  if [ "$reads_ok" -eq 1 ]; then
    if [ "$first" -eq 1 ]; then
      n=$(printf '%s' "$RECON_MARKS" | grep -c '^run:' || true)
      RECON_LINES="${RECON_LINES}NM_OBSERVE: BASELINE runs=$n (pre-existing inventory rows recorded as uncovered history, not adopted)"$'\n'
    fi
    recon_emit inventory "inventory read" silent
  fi
  # A pass that could not read every inventory carries the previous run marks
  # forward, so a transient outage never re-reports a baseline or an
  # already-reported row once the inventory is readable again.
  if [ "$INV_FAILED" -eq 1 ] || [ "$reads_ok" -eq 0 ]; then
    keys=$(printf '%s' "$RECON_MARKS" | cut -f1)
    while IFS= read -r line; do
      key=${line%%$'\t'*}
      case "$key" in run:*|inventory) ;; *) continue ;; esac
      printf '%s\n' "$keys" | grep -qxF -- "$key" || RECON_MARKS="${RECON_MARKS}${line}"$'\n'
    done <<< "$WM_OLD"
  fi
  reconcile_daemon_identity
  if [ "$peek" -eq 1 ]; then
    [ ! -f "$WATERMARK" ] || touch -- "$WATERMARK" 2>/dev/null || true
  else
    printf '%s' "$RECON_MARKS" > "$WATERMARK.tmp.$$"
    chmod 0600 "$WATERMARK.tmp.$$"
    mv -f -- "$WATERMARK.tmp.$$" "$WATERMARK"
  fi
  fm_lock_release "$WATERMARK_LOCK"
  [ -z "$RECON_LINES" ] || printf '%s' "$RECON_LINES"
  return 0
}

# Query <dir>'s inventory once per pass into the two tables (never through a
# command substitution, which would lose the assignments in a subshell). 0 when
# the inventory for <dir> is readable.
inventory_for_dir() {  # <dir>
  local dir=$1 remaining t out
  if [ -n "${INV_OK_BY_DIR[$dir]:-}" ]; then
    [ "${INV_OK_BY_DIR[$dir]}" = 1 ]
    return
  fi
  remaining=$(( deadline - $(now_epoch) ))
  if [ "$nm_ok" -ne 1 ] || [ "$remaining" -lt 1 ]; then
    INV_FAILED=1
    INV_OK_BY_DIR[$dir]=0
    INVENTORY_BY_DIR[$dir]=
    return 1
  fi
  t=$CALL_TIMEOUT
  [ "$t" -le "$remaining" ] || t=$remaining
  if out=$(fm_nm_run_checked "$dir" "$t" axi status); then
    INV_OK_BY_DIR[$dir]=1
    INVENTORY_BY_DIR[$dir]=$(inventory_rows "$out")
    return 0
  fi
  INV_FAILED=1
  INV_OK_BY_DIR[$dir]=0
  INVENTORY_BY_DIR[$dir]=
  return 1
}
declare -A INVENTORY_BY_DIR=() INV_OK_BY_DIR=() TASK_BRANCHES=()
INV_FAILED=0

reconcile_task() {  # <id> <meta> <record> <dir>
  local id=$1 meta=$2 record=$3 dir=$4 stage run branch rows row rid rhead rstatus class age alive newer out status now_class remaining rc
  stage=$(record_get "$record" stage)
  run=$(record_get "$record" run_id)
  branch=$(record_get "$record" candidate_branch)
  class=$(record_get "$record" outcome_class)
  case "$stage" in
    enrolled|finalized) return 0 ;;
    launch-refused)
      recon_emit "task:$id" "NM_OBSERVE: PREFLIGHT_REFUSED task=$id attempt=$(record_get "$record" attempt_id) profile=$(record_get "$record" preflight_refusal) (no run exists; repair the environment, then bin/fm-nm-observe.sh launch $id)"
      return 0 ;;
  esac
  if [ -z "$dir" ]; then
    INV_FAILED=1
    recon_emit "task:$id" "NM_OBSERVE: INVENTORY_UNAVAILABLE task=$id reason=no worktree or project directory to query"
    return 0
  fi
  if ! inventory_for_dir "$dir"; then
    recon_emit "task:$id" "NM_OBSERVE: INVENTORY_UNAVAILABLE task=$id reason=$([ "$nm_ok" -eq 1 ] && printf 'query failed or budget exhausted' || printf 'no-mistakes not on PATH') (obligation stays pending)"
    return 0
  fi
  rows=${INVENTORY_BY_DIR[$dir]}
  if [ "$stage" = launch-accepted ]; then
    row=$(printf '%s\n' "$rows" | awk -F '\t' -v b="$branch" -v p="$(record_get "$record" predecessor_run_id)" 'p != "" && $1 == p { exit } $2 == b { print; exit }')
    if [ -n "$row" ]; then
      rid=$(printf '%s' "$row" | cut -f1)
      rhead=$(printf '%s' "$row" | cut -f4)
      rstatus=$(printf '%s' "$row" | cut -f3)
      if fm_nm_head_matches_worktree "$dir" "$rhead" || [ "$rstatus" = running ]; then
        recon_emit "task:$id" "NM_OBSERVE: UNBOUND_RUN task=$id run=$rid status=$rstatus head=$rhead (run exists for the accepted branch but the obligation holds no run id; heal: bin/fm-nm-observe.sh bind $id --run $rid)"
        return 0
      fi
    fi
    age=$(( $(now_epoch) - $(record_get "$record" launch_epoch) ))
    [ "$age" -ge "$LAUNCH_GRACE" ] || return 0
    alive=$(worker_alive "$meta")
    if [ "$alive" = dead ]; then
      recon_emit "task:$id" "NM_OBSERVE: LAUNCH_GAP task=$id attempt=$(record_get "$record" attempt_id) age=${age}s worker=dead (launch accepted, no run created, worker endpoint gone: crash between acceptance and run creation; heal: relaunch through bin/fm-control.sh, then bin/fm-nm-observe.sh launch $id --retry)"
    else
      recon_emit "task:$id" "NM_OBSERVE: MISSING_BINDING task=$id attempt=$(record_get "$record" attempt_id) age=${age}s worker=$alive (launch accepted, no run for branch $branch yet; heal: bin/fm-nm-observe.sh bind $id once the worker has started the pipeline)"
    fi
    return 0
  fi
  # run-bound
  newer=$(printf '%s\n' "$rows" | awk -F '\t' -v b="$(record_get "$record" run_branch)" -v r="$run" '$1 == r { exit } $2 == b { print $1; exit }')
  if [ -n "$newer" ] && [ "$newer" != "$(record_get "$record" superseding_run)" ]; then
    recon_emit "task:$id:superseded" "NM_OBSERVE: SUPERSEDED_RUN task=$id run=$run newer=$newer (a newer run on the bound branch is unlinked; heal: bin/fm-nm-observe.sh launch $id --retry && bin/fm-nm-observe.sh bind $id --run $newer)"
  fi
  row=$(printf '%s\n' "$rows" | awk -F '\t' -v r="$run" '$1 == r { print; exit }')
  if [ -n "$row" ]; then
    # The inventory row carries status only: its class stays unread and is
    # never compared, so a row never invents an outcome.
    status=$(printf '%s' "$row" | cut -f3)
    now_class=
  else
    remaining=$(( deadline - $(now_epoch) ))
    out=
    rc=0
    if [ "$remaining" -lt 1 ]; then
      rc=1
    else
      out=$(fm_nm_run_checked "$dir" "$(( CALL_TIMEOUT < remaining ? CALL_TIMEOUT : remaining ))" axi status --run "$run") || rc=$?
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && fm_nm_status_is_run_not_found "$out" "$run"; then
      recon_emit "task:$id" "NM_OBSERVE: RUN_VANISHED task=$id run=$run (the daemon reports the bound run as not found; recorded class ${class:-unread} kept; heal: bin/fm-nm-observe.sh refresh $id)"
      return 0
    fi
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      INV_FAILED=1
      recon_emit "task:$id" "NM_OBSERVE: INVENTORY_UNAVAILABLE task=$id run=$run reason=$([ "$remaining" -lt 1 ] && printf 'budget exhausted' || printf 'query failed or timed out') (obligation stays pending; recorded class ${class:-unread} kept)"
      return 0
    fi
    if [ "$(run_field "$out" id)" != "$run" ]; then
      recon_emit "task:$id" "NM_OBSERVE: RUN_VANISHED task=$id run=$run (a successful canonical read no longer names the bound run; recorded class ${class:-unread} kept; heal: bin/fm-nm-observe.sh refresh $id)"
      return 0
    fi
    status=$(run_field "$out" status)
    now_class=$(outcome_class_of "$status" "$(run_field "$out" outcome)")
  fi
  if [ "$status" != "$(record_get "$record" run_status)" ] || { [ -n "$now_class" ] && terminal_class "$now_class" && [ "$now_class" != "$class" ]; }; then
    recon_emit "task:$id" "NM_OBSERVE: OUTCOME_CHANGED task=$id run=$run recorded=$(record_get "$record" run_status)/${class:-unread} canonical=$status/${now_class:-unread} (heal: bin/fm-nm-observe.sh refresh $id)"
  fi
}

reconcile_daemon_identity() {
  local nm_home epoch recorded record
  for record in "$STATE"/*.nm-observe; do
    [ -f "$record" ] || continue
    nm_home=$(record_get "$record" nm_home)
    [ -n "$nm_home" ] || continue
    epoch=$(daemon_epoch "$nm_home")
    recorded=$(record_get "$record" daemon_epoch)
    [ "$epoch" != unobserved ] && [ -n "$recorded" ] && [ "$recorded" != unobserved ] || continue
    [ "$epoch" != "$recorded" ] || continue
    [ "$(record_get "$record" stage)" = finalized ] && continue
    recon_emit "daemon:$(basename "$record" .nm-observe)" "NM_OBSERVE: DAEMON_RESET task=$(basename "$record" .nm-observe) recorded=$recorded observed=$epoch (daemon identity changed under this obligation; nothing was rebound; heal: bin/fm-nm-observe.sh refresh $(basename "$record" .nm-observe))"
  done
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -ge 1 ] || die_usage "a verb is required"
VERB=$1
shift
case "$VERB" in
  --help|-h|help) usage; exit 0 ;;
esac

if [ "$VERB" = reconcile ]; then
  STARTUP=0
  NOW=0
  PEEK=0
  for a in "$@"; do
    case "$a" in
      --startup) STARTUP=1 ;;
      --now) NOW=1 ;;
      --peek) PEEK=1 ;;
      *) die_usage "unknown reconcile flag $a" ;;
    esac
  done
  mkdir -p "$STATE"
  do_reconcile "$STARTUP" "$NOW" "$PEEK"
  exit 0
fi

[ "$#" -ge 1 ] || die_usage "$VERB requires a task id"
ID=$1
shift
valid_task_id "$ID" || die_usage "invalid task id"
ENTRY=firstmate
RETRY=0
RUN_WANT=
ACCEPT=0
PROFILE_FILE=
EXPECT_HOME=
EXPECT_PATH0=
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      entrypoint) ENTRY=$a ;;
      run) RUN_WANT=$a ;;
      profile-json) PROFILE_FILE=$a ;;
      expect-nm-home) EXPECT_HOME=$a ;;
      expect-path0) EXPECT_PATH0=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --entrypoint) want=entrypoint ;;
    --run) want=run ;;
    --profile-json) want=profile-json ;;
    --expect-nm-home) want=expect-nm-home ;;
    --expect-path0) want=expect-path0 ;;
    --retry) RETRY=1 ;;
    --accept-daemon-reset) ACCEPT=1 ;;
    *) die_usage "unknown flag $a for $VERB" ;;
  esac
done
[ -z "$want" ] || die_usage "--$want requires a value"
case "$ENTRY" in *[!A-Za-z0-9._-]*|'') die_usage "invalid --entrypoint" ;; esac
mkdir -p "$STATE"

case "$VERB" in
  enrol) with_lock "$ID" do_enrol "$ID" "$ENTRY" ;;
  launch) with_lock "$ID" do_launch "$ID" "$ENTRY" "$RETRY" "$PROFILE_FILE" "$EXPECT_HOME" "$EXPECT_PATH0" ;;
  bind) with_lock "$ID" do_bind "$ID" "$RUN_WANT" "$ACCEPT" ;;
  refresh) with_lock "$ID" do_refresh "$ID" "$ACCEPT" ;;
  receipt) record_load_or_die "$ID"; render_receipt "$ID"; printf '%s\n' "$(receipt_path "$ID")" ;;
  finalize) with_lock "$ID" do_finalize "$ID" ;;
  *) die_usage "unknown verb $VERB" ;;
esac
