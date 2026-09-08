#!/usr/bin/env bash
# Pin the captain commit identity onto a repository's no-mistakes gate mirror so
# the pipeline's OWN commits carry it.
#
# THE PROBLEM this owns. A firstmate worker's own commits are pinned to the
# captain identity through a separate seam - a per-process GIT_AUTHOR_*/
# GIT_COMMITTER_* environment the worker's shell carries. But the no-mistakes
# pipeline makes its OWN commits - the document, review-fix, rebase, and evidence
# commits - in a gate worktree the shared no-mistakes daemon creates under
# <NM_HOME>/worktrees/<repo id>, off a per-repo bare mirror under
# <NM_HOME>/repos/<repo id>.git. The gate agent that authors those commits is a
# separate process the daemon spawns; it inherits NEITHER the worker's shell env
# NOR any GIT_AUTHOR_* the run invocation sets, because the long-lived daemon's
# environment was fixed when it started and cannot be changed without a restart
# that would kill every other lane's in-flight run. With no user.* set anywhere
# in the mirror, git resolves the identity from the operator's global git config
# (commonly Test <test@example.com>), which a squash-merge then propagates into
# landed history. no-mistakes exposes no native author/identity/env hook, so the
# only seam that reaches the daemon's own commits without touching the daemon,
# the operator global, or landed history is git config the daemon reads at commit
# time: the mirror.
#
# WHY the mirror's SHARED config, not a worktree-scoped (--worktree) pin. The
# daemon OWNS the gate worktree lifecycle - it adds the worktree at run start and
# removes it at run end - so a worktree-scoped pin firstmate wrote would be
# ephemeral and would race the daemon's own worktree creation, which firstmate
# has no hook to interleave with. The mirror's shared config is inherited by
# EVERY worktree the daemon creates off that mirror (extensions.worktreeConfig
# being enabled only routes a small allowlist of keys - core.bare and friends -
# to per-worktree config; user.name/user.email stay shared), so pinning it once
# is durable across worktree recreation and daemon restarts and needs no per-run
# action. It touches only this repo's mirror: the operator global, other repos'
# mirrors, and every non-gate checkout are unchanged. That makes it the smallest
# managed owner of the pipeline commit identity.
#
# Usage: fm-nm-commit-identity.sh pin <project-dir>
#        fm-nm-commit-identity.sh show <project-dir>   # diagnostic; prints the mirror identity
#
# Idempotent and best-effort by contract: a project with no gate mirror in this
# home (not gated here, or its first gate run has not created the mirror yet) is
# a no-op success, so callers - fm-spawn.sh pins here before every no-mistakes
# ship worker starts - can invoke it unconditionally. It never creates a mirror,
# never runs a gate, and never touches the daemon.
set -u

# The captain-decided identity every no-mistakes pipeline commit is authored and
# committed under. The noreply address attributes the work to the captain's
# GitHub account without exposing a personal email. This is the git-config facet
# of the same captain identity a worker's OWN commits are pinned to through their
# per-process environment; keep the two values in step.
FM_NM_COMMIT_NAME='sbracewell64'
FM_NM_COMMIT_EMAIL='301307654+sbracewell64@users.noreply.github.com'

usage() {
  echo "usage: fm-nm-commit-identity.sh pin|show <project-dir>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ACTION=$1
PROJECT_DIR=$2
case "$ACTION" in
  pin | show) ;;
  *) usage ;;
esac

# no-mistakes' data home. NM_HOME when the launcher exported it (the firstmate
# home relocates it), else no-mistakes' own default of ~/.no-mistakes.
NM_HOME="${NM_HOME:-$HOME/.no-mistakes}"
REPOS="$NM_HOME/repos"

# Normalize a git remote URL for identity-only matching: strip a trailing slash
# and a trailing .git so https/ssh spellings of the same repo compare equal
# enough to bind a checkout to its mirror. Case is preserved because a forge path
# can be case-sensitive.
normalize_url() {
  local u=${1:-}
  u=${u%/}
  u=${u%.git}
  printf '%s' "$u"
}

# The checkout's origin. A checkout with no origin cannot be bound to a mirror.
ORIGIN=$(git -C "$PROJECT_DIR" config --get remote.origin.url 2>/dev/null || true)
if [ -z "$ORIGIN" ]; then
  [ "$ACTION" = show ] && echo "no-origin" || true
  exit 0
fi
WANT=$(normalize_url "$ORIGIN")

# A gate mirror is created lazily by the first gate run, so an absent repos
# directory simply means nothing is gated in this home yet.
[ -d "$REPOS" ] || { [ "$ACTION" = show ] && echo "no-mirror" || true; exit 0; }

matched=0
for mirror in "$REPOS"/*.git; do
  [ -d "$mirror" ] || continue
  murl=$(git -C "$mirror" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$murl" ] || continue
  [ "$(normalize_url "$murl")" = "$WANT" ] || continue
  matched=1
  if [ "$ACTION" = show ]; then
    printf '%s\t%s <%s>\n' "$mirror" \
      "$(git -C "$mirror" config --get user.name 2>/dev/null || echo '(unset)')" \
      "$(git -C "$mirror" config --get user.email 2>/dev/null || echo '(unset)')"
    continue
  fi
  # Pin the shared config idempotently. --worktree is deliberately never passed:
  # see this file's header for why the shared scope, not a per-worktree one, is
  # the durable owner. The idempotency check reads --local, the mirror's OWN
  # value, not the effective one, so the pin is always materialized in the
  # mirror's config even in the corner case where the operator global already
  # happens to carry the captain identity.
  cur_name=$(git -C "$mirror" config --local --get user.name 2>/dev/null || true)
  cur_email=$(git -C "$mirror" config --local --get user.email 2>/dev/null || true)
  if [ "$cur_name" != "$FM_NM_COMMIT_NAME" ] || [ "$cur_email" != "$FM_NM_COMMIT_EMAIL" ]; then
    git -C "$mirror" config user.name "$FM_NM_COMMIT_NAME" \
      && git -C "$mirror" config user.email "$FM_NM_COMMIT_EMAIL" \
      && echo "pinned $mirror" \
      || echo "warning: could not pin $mirror" >&2
  else
    echo "already-pinned $mirror"
  fi
done

[ "$matched" -eq 1 ] || { [ "$ACTION" = show ] && echo "no-mirror" || true; }
exit 0
