#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting), fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment), and
# fm-nm-observe.sh (read-only run binding and inventory reconciliation), and
# fm-stage.sh (candidate currentness and engineering evidence admission).
# Teardown uses only strict branch-and-head identity; crew-state and the
# observer and stage owner additionally permit the active pipeline-owned exemption defined
# below. Getting this wrong in either direction is unsafe: a false negative
# hides a genuinely parked run, and a false positive lets teardown act on a
# run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# 0 when captured `axi status --run <id>` output $1 is the daemon's own answer
# that run $2 does not exist (exit 1 with exactly this line on stdout). Any
# other failure is a query that could not complete, not a missing run.
fm_nm_status_is_run_not_found() {  # <status-output> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# fm_nm_run_is_pipeline_owned_active below carries the one exemption: a live
# run whose pipeline currently owns the branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# One conditional consumer for the producer's revocable exact-head tuple.
# A successful read is current only at the producer snapshot. Every later
# authority use revalidates the retained tuple; no local write/forge atomicity.

fm_nm_qualification_read() {
  local dir=$1 run=$2 head=$3 branch=$4 pr=$5 prior=${6:-} result
  local args=(axi qualification --run "$run" --head "$head" --json)
  if [ -n "$prior" ]; then
    fm_nm_qualification_valid "$prior" "$run" "$head" "$branch" "$pr" || return 1
    args+=(--attempt "$(printf '%s' "$prior" | jq -r .attempt)" --generation "$(printf '%s' "$prior" | jq -r .generation)")
  fi
  result=$(fm_nm_run_checked "$dir" 10 "${args[@]}") || return 1
  fm_nm_qualification_valid "$result" "$run" "$head" "$branch" "$pr" || return 1
  result=$(printf '%s' "$result" | jq -cS .) || return 1
  if [ -n "$prior" ]; then
    [ "$result" = "$(printf '%s' "$prior" | jq -cS .)" ] || return 1
  fi
  printf '%s\n' "$result"
}

fm_nm_qualification_valid() {
  printf '%s' "$1" | jq -se --arg run "$2" --arg head "$3" --arg branch "$4" --arg pr "$5" '
    length == 1 and (.[0] |
      .schema == "no-mistakes/ci-qualification/v1" and
      .validity == "current-at-read; revocable; bind exact identity and revalidate before downstream use" and
      .run == $run and .head == $head and (.head | test("^[0-9a-f]{40}$")) and
      (.branch | ltrimstr("refs/heads/")) == ($branch | ltrimstr("refs/heads/")) and
      (.repo | type == "string" and length > 0) and
      (.attempt | type == "string" and length > 0) and
      (.generation | type == "string" and length > 0) and
      (.push_generation | type == "number" and . > 0 and floor == .) and
      (.status == "running" or .status == "completed") and
      (.evidence_sha256 | test("^[0-9a-f]{64}$")) and
      .evidence.provider == "github" and .evidence.pr == $pr and
      ((.evidence.checks | type == "array") or (.evidence.checks == null and .evidence.declared_no_ci == true)) and
      ((.evidence.checks | length > 0) or .evidence.declared_no_ci == true) and
      all((.evidence.checks // [])[]; .bucket == "pass" or .bucket == "skipping"))
  ' >/dev/null 2>&1
}

fm_nm_effect_current() {
  local file=$1 expected_pr=${2:-} expected_task=${3:-$(basename "$1" .meta)} effect qualification run head branch pr dir
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  effect=$(sed -n 's/^stage_ci_ready_effect=//p' "$file")
  run=$(sed -n 's/^stage_run=//p' "$file")
  branch=$(sed -n 's/^stage_branch=//p' "$file")
  pr=$(sed -n 's/^stage_pr=//p' "$file")
  dir=$(sed -n 's/^worktree=//p' "$file")
  [ -z "$expected_pr" ] || [ "$expected_pr" = "$pr" ] || return 1
  printf '%s' "$effect" | jq -se --arg task "$expected_task" \
    --arg generation "$(sed -n 's/^spawn_gen=//p' "$file")" \
    --arg stage_gen "$(sed -n 's/^stage_gen=//p' "$file")" \
    --arg attempt "$(sed -n 's/^stage_attempt=//p' "$file")" \
    --arg candidate "$(sed -n 's/^stage_head=//p' "$file")" --arg run "$run" --arg pr "$pr" '
      length == 1 and (.[0] | .task == $task and .generation == $generation and .generation == $stage_gen and
      .attempt == $attempt and .candidate == $candidate and .run == $run and .pr == $pr and
      (.attempt | length > 0) and (.run | length > 0) and (.candidate | test("^[0-9a-f]{40}$")))
    ' >/dev/null 2>&1 || return 1
  head=$(printf '%s' "$effect" | jq -r .source_head) || return 1
  qualification=$(printf '%s' "$effect" | jq -c .qualification) || return 1
  local obligation nm_home
  obligation="$(dirname "$file")/$expected_task.nm-observe"
  [ -f "$obligation" ] && [ ! -L "$obligation" ] && [ -r "$obligation" ] || return 1
  [ "$(sed -n 's/^run_id=//p' "$obligation")" = "$run" ] || return 1
  [ "$(sed -n 's/^attempt_id=//p' "$obligation")" = "$(printf '%s' "$effect" | jq -r .attempt)" ] || return 1
  nm_home=$(sed -n 's/^nm_home=//p' "$obligation")
  [ -n "$nm_home" ] && [ -d "$nm_home" ] || return 1
  NM_HOME="$nm_home" NO_MISTAKES_HOME="$nm_home" fm_nm_qualification_read "$dir" "$run" "$head" "$branch" "$pr" "$qualification"
}

fm_nm_effect_required() {
  local file=$1
  grep -q '^stage_ci_ready_effect=.' "$file" && return 0
  grep -qx 'mode=no-mistakes' "$file" && grep -q '^stage_run=.' "$file"
}
