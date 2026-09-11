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
# CI-ready alone may consume the separate verified completed-successor
# projection below; it never changes active attribution or teardown rules.
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

# Read one scalar from the documented two-level sync object. Reject duplicate
# roots, sections, or requested fields instead of combining ambiguous proof
# fragments. A consumed section must be an empty-valued object header.
# This is a wire reader, not a second qualification algorithm.
fm_nm_sync_scalar() { # <sync-toon> <section-or-empty> <key> [raw]
  local raw
  raw=$(printf '%s\n' "$1" | awk -v section="$2" -v key="$3" '
    /^branch_sync:$/ { roots++; inside=1; group=""; next }
    /^[^ ]/ { inside=0 }
    inside && /^  [a-z_]+:/ {
      line=substr($0,3); name=line; sub(/:.*/,"",name)
      value=line; sub(/^[^:]*:[ ]*/,"",value)
      group=name; groups[name]++
      if (name == section && value != "") invalid_section=1
      if (section == "" && name == key) { count++; found=value }
      next
    }
    inside && /^    [a-z_]+:/ && group == section {
      line=substr($0,5); name=line; sub(/:.*/,"",name)
      value=line; sub(/^[^:]*:[ ]*/,"",value)
      if (name == key) { count++; found=value }
    }
    END {
      if (invalid_section || roots != 1 || count != 1 || found == "" || (section != "" && groups[section] != 1)) exit 1
      print found
    }') || return 1
  if [ "${4:-}" = raw ]; then printf '%s' "$raw"; else fm_nm_strip_quotes "$raw"; fi
}

# Completed non-ancestor admission is separate from active run attribution.
# The tooling service owns qualification; CI-ready checks its fresh successor
# projection against the bound attempt and actual clean caller/preservation.
# Ordinary equality, a local anchor, or completed status alone grants nothing.
# No teardown or ordinary run-attribution caller uses this predicate.
fm_nm_verified_terminal_successor() { # <worktree> <run> <submitted> <head> <branch> <sync-toon>
  local wt=$1 run=$2 submitted=$3 head=$4 branch=$5 output=$6 generation fingerprint anchor actual dirty
  [[ "$submitted" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$run" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$submitted" != "$head" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" '' state)" = synchronized ] || return 1
  [ "$(fm_nm_sync_scalar "$output" '' relation)" = equal ] || return 1
  [ "$(fm_nm_sync_scalar "$output" '' safety)" = already_synchronized ] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor verified raw)" = true ] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor run_id)" = "$run" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor submitted_head)" = "$submitted" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor qualified_head)" = "$head" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline run)" = "$run" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline status)" = completed ] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline submitted_head)" = "$submitted" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline current_head)" = "$head" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline pushed_head)" = "$head" ] || return 1
  generation=$(fm_nm_sync_scalar "$output" successor push_generation raw) || return 1
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$(fm_nm_sync_scalar "$output" pipeline push_generation raw)" = "$generation" ] || return 1
  actual=$(fm_nm_sync_scalar "$output" successor target_kind) || return 1
  case "$actual" in upstream|fork) ;; *) return 1 ;; esac
  [ "$(fm_nm_sync_scalar "$output" target kind)" = "$actual" ] || return 1
  fingerprint=$(fm_nm_sync_scalar "$output" successor target_fingerprint) || return 1
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor target_ref)" = "refs/heads/$branch" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" target ref)" = "refs/heads/$branch" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" remote freshness)" = live ] || return 1
  [ "$(fm_nm_sync_scalar "$output" remote observed_head)" = "$head" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" local branch)" = "$branch" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" local head)" = "$head" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" local clean raw)" = true ] || return 1
  anchor="refs/no-mistakes/sync-anchor/$run"
  [ "$(fm_nm_sync_scalar "$output" successor preserved_ref)" = "$anchor" ] || return 1
  [ "$(fm_nm_sync_scalar "$output" successor preserved_head)" = "$submitted" ] || return 1
  git -C "$wt" symbolic-ref --quiet "$anchor" >/dev/null 2>&1 && return 1
  [ "$(git -C "$wt" cat-file -t "$anchor" 2>/dev/null)" = commit ] || return 1
  [ "$(git -C "$wt" rev-parse --verify "$anchor" 2>/dev/null)" = "$submitted" ] || return 1
  [ "$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ] || return 1
  [ "$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" = "$head" ] || return 1
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  [ -z "$dirty" ]
}
