#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched forge pull head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, the diff falls
# back to the local branch and says so on stdout. Without pr=, compare the local
# branch.
#
# Provenance: both sides are pinned to exact commit SHAs before diffing. The
# header names the symbolic base, its SHA, the compare source, its SHA, and the
# merge-base the diff starts from, so `git diff <base-sha>...<compare-sha>`
# reproduces the evidence exactly. Rename and copy detection is on for every
# diff mode so a moved or copied file shows both its old and new path, and a
# `changed paths` summary (from --name-status) lists every path including
# deletions, which are counted rather than filtered.
#
# Could-not-observe results are stdout labels, never silent downgrades:
#   COULD NOT OBSERVE LIVE PR HEAD  - live fetch of the forge pull head failed;
#                                     the diff compares the RECORDED pr_head=.
#   COULD NOT OBSERVE PR HEAD       - live fetch failed and no recorded head is
#                                     reachable; the diff compares the LOCAL
#                                     branch as a fallback.
# A label is routing evidence for firstmate, not a captain escalation.
#
# Malformed inputs refuse (nonzero exit, message names the field) rather than
# degrading to a weaker comparison:
#   - an argument that is not "<task-id> [--stat]" (a flag in the id slot, an
#     unknown flag, or an extra argument), or a task id that is not path-safe
#   - a missing meta file, or a missing worktree= or project= field or directory
#   - worktree=, project=, pr=, or pr_head= appearing more than once
#   - pr= that is present but not a canonical PR/MR URL or positive integer
#   - pr_head= that is present but not a 40- or 64-hex commit SHA
#   - an unresolvable default branch, base, or compare commit
# A well-formed pr_head= whose object is simply absent is an observation
# failure, not a policy violation, and takes the could-not-observe path.
# PR URL and pr_head syntax are owned by bin/fm-pr-lib.sh.
#
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints header, changed-path summary, and stat only; default adds the
#   full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

refuse() {
  echo "error: $*" >&2
  exit 1
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
case "$ID" in
  -*) usage; refuse "unparseable argument '$ID': expected <task-id> in the first position" ;;
esac
fm_pr_task_id_valid "$ID" || refuse "unparseable argument '$ID': task id is not path-safe"
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; refuse "unparseable argument '$2': the only option is --stat" ;;
esac
[ $# -le 2 ] || { usage; refuse "unparseable extra argument '$3': expected <task-id> [--stat]"; }

META="$STATE/$ID.meta"
[ -f "$META" ] || refuse "no meta for task $ID at $META"

# meta_field <key> <presence-var>: the single value of key= in META. Refuses a
# repeated key outright: every producer writes each of these fields once, so a
# second line is a corrupt or contradictory record, never a legitimate update.
meta_field() {
  local key=$1 count
  count=$(grep -c "^$key=" "$META" || true)
  [ "$count" -le 1 ] || refuse "meta for task $ID has $count $key= lines; exactly one is allowed"
  grep "^$key=" "$META" | cut -d= -f2- || true
}

WT=$(meta_field worktree)
PROJ=$(meta_field project)
[ -n "$WT" ] || refuse "meta for task $ID is missing worktree="
[ -n "$PROJ" ] || refuse "meta for task $ID is missing project="
[ -d "$WT" ] || refuse "worktree for task $ID is missing: $WT"
[ -d "$PROJ" ] || refuse "project for task $ID is missing: $PROJ"

PR_PRESENT=false
PR_URL=
if grep -q '^pr=' "$META"; then
  PR_PRESENT=true
  PR_URL=$(meta_field pr)
fi
PR_HEAD_PRESENT=false
PR_HEAD_RECORDED=
if grep -q '^pr_head=' "$META"; then
  PR_HEAD_PRESENT=true
  PR_HEAD_RECORDED=$(meta_field pr_head)
fi

# pr= parses to a provider-specific pull ref plus number, or refuses. A bare
# positive integer keeps the historical GitHub-style refs/pull/<n>/head shape.
PR_NUMBER=
PR_PULL_REF=
if "$PR_PRESENT"; then
  if fm_pr_url_parse "$PR_URL"; then
    PR_NUMBER=$FM_PR_NUMBER
    case "$FM_PR_PROVIDER" in
      gitlab) PR_PULL_REF="refs/merge-requests/$PR_NUMBER/head" ;;
      *) PR_PULL_REF="refs/pull/$PR_NUMBER/head" ;;
    esac
  elif [[ "$PR_URL" =~ ^[1-9][0-9]*$ ]]; then
    PR_NUMBER=$PR_URL
    PR_PULL_REF="refs/pull/$PR_NUMBER/head"
  else
    refuse "meta for task $ID has malformed pr= '$PR_URL': expected a canonical PR/MR URL or a positive PR number"
  fi
fi
if "$PR_HEAD_PRESENT"; then
  fm_pr_head_valid "$PR_HEAD_RECORDED" \
    || refuse "meta for task $ID has malformed pr_head= '$PR_HEAD_RECORDED': expected a 40- or 64-hex commit SHA"
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || refuse "cannot determine default branch for $PROJ; expected origin/HEAD, main, or master"

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || refuse "branch fm/$ID does not exist and worktree $WT is detached"
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || refuse "branch $BRANCH does not exist in $WT"
fi

fetch_pull_head() {
  local ref=$1 n=$2 resolved
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  git -C "$WT" fetch --quiet origin \
    "+$ref:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

# Compare-side resolution. COMPARE_KIND names the source the header reports:
#   live      - freshly fetched forge pull head (the authoritative PR head)
#   recorded  - recorded pr_head= because the live fetch failed
#   local     - local branch, either because no pr= is recorded or because
#               neither PR head could be observed (OBSERVE_LABEL is then set)
COMPARE_REF=$BRANCH
COMPARE_KIND=local
OBSERVE_LABEL=
if "$PR_PRESENT"; then
  if PR_HEAD=$(fetch_pull_head "$PR_PULL_REF" "$PR_NUMBER"); then
    COMPARE_REF=$PR_HEAD
    COMPARE_KIND=live
  elif [ -n "$PR_HEAD_RECORDED" ] \
    && git -C "$WT" cat-file -e "$PR_HEAD_RECORDED^{commit}" 2>/dev/null; then
    # Offline / unreachable remote: recorded pr_head is better than the local
    # branch, but never preferred over a successful pull-head fetch above.
    COMPARE_REF=$PR_HEAD_RECORDED
    COMPARE_KIND=recorded
    OBSERVE_LABEL="COULD NOT OBSERVE LIVE PR HEAD: fetch of $PR_PULL_REF for PR $PR_NUMBER failed; this diff compares the RECORDED pr_head= $PR_HEAD_RECORDED, which may lag the open PR."
  else
    OBSERVE_LABEL="COULD NOT OBSERVE PR HEAD: fetch of $PR_PULL_REF for PR $PR_NUMBER failed and no recorded pr_head= is reachable; this diff compares the LOCAL branch $BRANCH as a fallback and may lag the open PR."
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet \
    || refuse "cannot fetch origin/$DEFAULT into $WT"
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

BASE_SHA=$(git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}") || refuse "base $BASE does not exist in $WT"
COMPARE_SHA=$(git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}") || refuse "compare ref $COMPARE_REF does not resolve in $WT"
MERGE_BASE=$(git -C "$WT" merge-base "$BASE_SHA" "$COMPARE_SHA") || refuse "base $BASE_SHA and compare $COMPARE_SHA share no merge-base in $WT"

case "$COMPARE_KIND" in
  live) COMPARE_DESC="PR $PR_NUMBER head (fetched $PR_PULL_REF)" ;;
  recorded) COMPARE_DESC="PR $PR_NUMBER recorded pr_head=" ;;
  *) COMPARE_DESC="local branch $BRANCH" ;;
esac

# Rename and copy detection on every diff mode so lineage is never hidden as a
# delete+add pair. The pinned SHAs drive every git call below.
DIFF_OPTS=(--find-renames --find-copies)
RANGE="$BASE_SHA...$COMPARE_SHA"

echo "diff base: $BASE $BASE_SHA"
echo "diff compare: $COMPARE_DESC $COMPARE_SHA"
echo "merge-base: $MERGE_BASE"
[ -z "$OBSERVE_LABEL" ] || echo "$OBSERVE_LABEL"

if git -C "$WT" diff --quiet "${DIFF_OPTS[@]}" "$RANGE" --; then
  echo "no changes vs $BASE $BASE_SHA"
  exit 0
fi

# Changed-path summary from --name-status: every path, deletions included.
NAME_STATUS=$(git -C "$WT" diff --name-status "${DIFF_OPTS[@]}" "$RANGE" --)
n_added=0 n_modified=0 n_deleted=0 n_renamed=0 n_copied=0 n_other=0 n_total=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n_total=$((n_total + 1))
  case "$line" in
    A*) n_added=$((n_added + 1)) ;;
    M*) n_modified=$((n_modified + 1)) ;;
    D*) n_deleted=$((n_deleted + 1)) ;;
    R*) n_renamed=$((n_renamed + 1)) ;;
    C*) n_copied=$((n_copied + 1)) ;;
    *) n_other=$((n_other + 1)) ;;
  esac
done <<EOF
$NAME_STATUS
EOF
echo "changed paths: $n_total (added $n_added, modified $n_modified, deleted $n_deleted, renamed $n_renamed, copied $n_copied, other $n_other)"
printf '%s\n' "$NAME_STATUS"
echo

git -C "$WT" diff --stat "${DIFF_OPTS[@]}" "$RANGE" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "${DIFF_OPTS[@]}" "$RANGE" --
fi
