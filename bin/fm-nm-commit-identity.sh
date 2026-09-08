#!/usr/bin/env bash
# Pin the captain commit identity onto a repository's no-mistakes gate mirror so
# the pipeline's OWN commits carry it - fail-closed, with typed outcomes.
#
# THE PROBLEM this owns. A firstmate worker's own commits are pinned to the
# captain identity through a separate seam (a per-process environment the
# worker's shell carries). But the no-mistakes pipeline makes its OWN commits -
# the document, review-fix, and rebase commits - in a gate worktree the shared
# daemon creates off a per-repo bare mirror under <NM_HOME>/repos/<id>.git. The
# gate agent that authors those commits is a separate process the daemon spawns;
# it inherits neither the worker's shell env nor any GIT_AUTHOR_* the run
# invocation sets, because the long-lived shared daemon's environment was fixed
# when it started and cannot be changed without a restart that would kill every
# other lane's in-flight run. With no user.* pinned in the mirror, git resolves
# the identity from the operator global (commonly Test <test@example.com>), which
# a squash-merge then propagates into landed history. no-mistakes exposes no
# native author/identity/env hook, so the only seam that reaches the daemon's own
# commits without touching the daemon, the operator global, or landed history is
# git config the daemon reads at commit time: the mirror.
#
# GIT IDENTITY PRECEDENCE, exactly (highest wins):
#   1. GIT_AUTHOR_*/GIT_COMMITTER_* environment
#   2. the worktree's config.worktree (when extensions.worktreeConfig is on)
#   3. the repository (shared) config - what this script pins
#   4. the operator global (~/.gitconfig)
#   5. system config
# Pinning the shared config (3) displaces (4)/(5) for every worktree the daemon
# creates off the mirror, so it is set once, is durable across worktree
# recreation and daemon restarts, and needs no per-run action - the smallest
# durable owner. But (1) and (2) still outrank it, so a shared-config write ALONE
# is not proof the effective identity is correct: this script therefore VERIFIES
# the effective identity with `git var GIT_AUTHOR_IDENT`/`GIT_COMMITTER_IDENT`
# (which resolves the full precedence, env included) in every gate context it can
# reach, and FAILS CLOSED (UNVERIFIED) on a config.worktree override or any
# read-back mismatch rather than reporting a pin it cannot confirm. The read-back
# runs with GIT_AUTHOR_*/GIT_COMMITTER_* unset because the daemon's gate agent
# sets none (the observed contamination fell through to config, not to env); a
# daemon that set GIT_AUTHOR_* would outrank any git-config seam and is out of
# this seam's scope.
#
# EXACT BINDING (never a fuzzy origin match). The mirror is bound to THIS exact
# repository, two ways that must agree: the daemon's own declared gate path from
# `no-mistakes status` (authoritative), and the deterministic
# <NM_HOME>/repos/<sha256(canonical repo path)[:12]>.git the daemon derives. Two
# checkouts sharing one origin URL have different paths and therefore different
# mirrors, so origin equality never identifies the owner and is not used.
#
# SCOPE - this is a MITIGATION, not universal enforcement. The daemon owns the
# gate-worktree lifecycle firstmate cannot interleave with, so a caller (fm-spawn
# before a no-mistakes ship worker starts) pinning the mirror covers repeat runs
# of an already-gated repo; it does NOT guarantee a repo's very first run (whose
# mirror the daemon creates mid-run) nor race-free enforcement against a
# concurrently-created worktree override. Those are reported as typed outcomes,
# never papered over as success.
#
# Usage: fm-nm-commit-identity.sh <pin|verify|show> --repo <dir> [--nm-home <dir>] [--mirror <dir>]
#   pin     - bind the mirror, pin its shared config, then verify effective identity.
#   verify  - bind and verify only; never writes.
#   show    - diagnostic; print the bound mirror and its effective identity.
#   --repo   the repository checkout whose gate mirror to bind (required unless --mirror).
#   --mirror an explicit, already-known mirror path; the exact declared binding, skips resolution.
#   --nm-home declare NM_HOME explicitly; else $NM_HOME, else ~/.no-mistakes.
#
# Typed outcomes (stdout line + exit code):
#   OK <mirror> verified=<contexts>   0   bound, pinned, effective identity confirmed
#   MISSING <detail>                  3   no gate mirror exists for this repo (not gated, or first run not yet materialized)
#   AMBIGUOUS <detail>                4   resolution produced conflicting exact bindings; refused rather than guess
#   WRITE_FAILED <detail>             5   the shared-config write failed or did not land
#   UNVERIFIED <detail>               6   effective identity could not be confirmed as the pinned one (worktree override or read-back mismatch)
#   usage error                       2
set -u

FM_NM_COMMIT_NAME='sbracewell64'
FM_NM_COMMIT_EMAIL='301307654+sbracewell64@users.noreply.github.com'

# Command whose stdout carries the daemon's authoritative "gate: <path>" line,
# run inside the repo. Overridable so the resolver is testable without a daemon.
FM_NM_GATE_CMD="${FM_NM_GATE_CMD:-no-mistakes status}"

EX_OK=0 EX_USAGE=2 EX_MISSING=3 EX_AMBIGUOUS=4 EX_WRITE=5 EX_UNVERIFIED=6

usage() {
  echo "usage: fm-nm-commit-identity.sh <pin|verify|show> --repo <dir> [--nm-home <dir>] [--mirror <dir>]" >&2
  exit "$EX_USAGE"
}

emit() {  # <OUTCOME> <detail> <exit-code>
  printf '%s %s\n' "$1" "$2"
  exit "$3"
}

ACTION=""
REPO=""
NM_HOME_ARG=""
MIRROR_ARG=""
[ "$#" -ge 1 ] || usage
ACTION=$1
shift
case "$ACTION" in
  pin | verify | show) ;;
  *) usage ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 || usage ;;
    --nm-home) NM_HOME_ARG=${2:-}; shift 2 || usage ;;
    --mirror) MIRROR_ARG=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done

# canonical <path> -> physical absolute path, or empty if it does not resolve.
canonical() {
  local p=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$p" 2>/dev/null && return 0
  fi
  ( cd "$p" 2>/dev/null && pwd -P ) 2>/dev/null
}

# sha256 hex of the argument bytes (no trailing newline), first 12 chars - the
# daemon's repo-id derivation.
repo_id() {
  local s=$1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | cut -c1-12
  else
    printf '%s' "$s" | shasum -a 256 | cut -c1-12
  fi
}

# ident_field <name|email> <git-var-ident-line>: parse "Name <email> ts tz".
ident_name() { local l=$1; l=${l%% <*}; printf '%s' "$l"; }
ident_email() { local l=$1; l=${l#*<}; l=${l%%>*}; printf '%s' "$l"; }

# read_effective_ident <dir>: echo "<name>\t<email>" resolved by git in <dir>
# with author/committer env stripped, or empty on failure. Fails the whole
# read if author and committer identities disagree.
read_effective_ident() {
  local dir=$1 a c
  a=$(cd "$dir" 2>/dev/null && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git var GIT_AUTHOR_IDENT 2>/dev/null) || return 1
  c=$(cd "$dir" 2>/dev/null && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git var GIT_COMMITTER_IDENT 2>/dev/null) || return 1
  [ "$(ident_name "$a")" = "$(ident_name "$c")" ] && [ "$(ident_email "$a")" = "$(ident_email "$c")" ] || return 1
  printf '%s\t%s' "$(ident_name "$a")" "$(ident_email "$a")"
}

# --- resolve the exact mirror ----------------------------------------------

MIRROR=""
if [ -n "$MIRROR_ARG" ]; then
  MIRROR=$(canonical "$MIRROR_ARG")
  [ -n "$MIRROR" ] && [ -d "$MIRROR" ] || emit MISSING "declared --mirror does not exist: $MIRROR_ARG" "$EX_MISSING"
else
  [ -n "$REPO" ] || usage
  REPO_ABS=$(canonical "$REPO")
  [ -n "$REPO_ABS" ] && [ -d "$REPO_ABS" ] || usage
  # The repository's canonical toplevel is what the daemon keys on.
  REPO_TOP=$(cd "$REPO_ABS" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  REPO_TOP=$(canonical "${REPO_TOP:-$REPO_ABS}")
  [ -n "$REPO_TOP" ] || REPO_TOP=$REPO_ABS
  NM_HOME_RESOLVED="${NM_HOME_ARG:-${NM_HOME:-$HOME/.no-mistakes}}"
  H="$NM_HOME_RESOLVED/repos/$(repo_id "$REPO_TOP").git"

  # Authoritative gate from the daemon (best-effort, bounded).
  G=""
  if have_to=$(command -v timeout || command -v gtimeout); then
    G=$(cd "$REPO_TOP" 2>/dev/null && "$have_to" 15 sh -c "$FM_NM_GATE_CMD" 2>/dev/null \
      | sed -n 's/^[[:space:]]*gate:[[:space:]]*//p' | head -n1)
  else
    G=$(cd "$REPO_TOP" 2>/dev/null && sh -c "$FM_NM_GATE_CMD" 2>/dev/null \
      | sed -n 's/^[[:space:]]*gate:[[:space:]]*//p' | head -n1)
  fi
  G_ABS=""
  [ -n "$G" ] && [ -d "$G" ] && G_ABS=$(canonical "$G")

  H_ABS=""
  [ -d "$H" ] && H_ABS=$(canonical "$H")

  if [ -n "$G_ABS" ] && [ -n "$H_ABS" ] && [ "$G_ABS" != "$H_ABS" ]; then
    emit AMBIGUOUS "daemon gate ($G_ABS) and derived mirror ($H_ABS) disagree; refusing to guess" "$EX_AMBIGUOUS"
  elif [ -n "$G_ABS" ]; then
    MIRROR=$G_ABS
  elif [ -n "$H_ABS" ]; then
    MIRROR=$H_ABS
  else
    emit MISSING "no gate mirror for $REPO_TOP under $NM_HOME_RESOLVED/repos (repo not gated here, or its first run has not created the mirror yet)" "$EX_MISSING"
  fi
fi

# The bound path must be a real git repository (the gate mirror).
git -C "$MIRROR" rev-parse --git-dir >/dev/null 2>&1 \
  || emit MISSING "bound mirror is not a git repository: $MIRROR" "$EX_MISSING"

# --- pin the shared config (pin action only) -------------------------------

if [ "$ACTION" = pin ]; then
  cur_name=$(git -C "$MIRROR" config --local --get user.name 2>/dev/null || true)
  cur_email=$(git -C "$MIRROR" config --local --get user.email 2>/dev/null || true)
  if [ "$cur_name" != "$FM_NM_COMMIT_NAME" ] || [ "$cur_email" != "$FM_NM_COMMIT_EMAIL" ]; then
    if ! git -C "$MIRROR" config user.name "$FM_NM_COMMIT_NAME" 2>/dev/null \
      || ! git -C "$MIRROR" config user.email "$FM_NM_COMMIT_EMAIL" 2>/dev/null; then
      emit WRITE_FAILED "config write refused for $MIRROR (locked or read-only)" "$EX_WRITE"
    fi
  fi
  # Confirm the write actually landed in the mirror's own config, not just that
  # the command returned 0 (a lost write leaves the identity contaminated).
  got_name=$(git -C "$MIRROR" config --local --get user.name 2>/dev/null || true)
  got_email=$(git -C "$MIRROR" config --local --get user.email 2>/dev/null || true)
  [ "$got_name" = "$FM_NM_COMMIT_NAME" ] && [ "$got_email" = "$FM_NM_COMMIT_EMAIL" ] \
    || emit WRITE_FAILED "pin did not land in $MIRROR/config (got '$got_name <$got_email>')" "$EX_WRITE"
fi

# --- verify effective identity in every reachable gate context -------------

# config.worktree can outrank the shared config, so scan every registered
# worktree for an override and for the actually-resolved identity.
verified_ctx="shared"
override_detail=""
mismatch_detail=""
wt=""
wt_bare=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt=${line#worktree }; wt_bare=0 ;;
    "bare") wt_bare=1 ;;
    "")
      # end of one worktree record; skip the bare mirror's own record and any
      # entry that is the mirror itself - only LINKED gate worktrees matter.
      wt_canon=$(canonical "${wt:-/nonexistent}")
      if [ -n "${wt:-}" ] && [ "$wt_bare" -eq 0 ] && [ "$wt_canon" != "$MIRROR" ] \
        && [ -d "$wt" ] && git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        wt_name=$(git -C "$wt" config --worktree --get user.name 2>/dev/null || true)
        wt_email=$(git -C "$wt" config --worktree --get user.email 2>/dev/null || true)
        if { [ -n "$wt_name" ] && [ "$wt_name" != "$FM_NM_COMMIT_NAME" ]; } \
          || { [ -n "$wt_email" ] && [ "$wt_email" != "$FM_NM_COMMIT_EMAIL" ]; }; then
          override_detail="config.worktree in $wt overrides the pin ($wt_name <$wt_email>)"
        fi
        eff=$(read_effective_ident "$wt" || true)
        if [ -n "$eff" ]; then
          en=${eff%%$'\t'*}; ee=${eff#*$'\t'}
          if [ "$en" != "$FM_NM_COMMIT_NAME" ] || [ "$ee" != "$FM_NM_COMMIT_EMAIL" ]; then
            mismatch_detail="effective identity in $wt is $en <$ee>, not the pin"
          else
            verified_ctx="$verified_ctx+wt:$wt"
          fi
        fi
      fi
      wt=""
      ;;
  esac
done < <(git -C "$MIRROR" worktree list --porcelain 2>/dev/null; printf '\n')

[ -z "$override_detail" ] || emit UNVERIFIED "$override_detail" "$EX_UNVERIFIED"
[ -z "$mismatch_detail" ] || emit UNVERIFIED "$mismatch_detail" "$EX_UNVERIFIED"

# The base identity a freshly-created worktree inherits: the mirror's own
# shared-config resolution must itself be the pin.
base_eff=$(read_effective_ident "$MIRROR" || true)
if [ -n "$base_eff" ]; then
  bn=${base_eff%%$'\t'*}; be=${base_eff#*$'\t'}
  [ "$bn" = "$FM_NM_COMMIT_NAME" ] && [ "$be" = "$FM_NM_COMMIT_EMAIL" ] \
    || emit UNVERIFIED "mirror shared-config identity is $bn <$be>, not the pin" "$EX_UNVERIFIED"
else
  emit UNVERIFIED "could not read effective identity for $MIRROR" "$EX_UNVERIFIED"
fi

if [ "$ACTION" = show ]; then
  emit OK "$MIRROR effective=$FM_NM_COMMIT_NAME <$FM_NM_COMMIT_EMAIL>" "$EX_OK"
fi
emit OK "$MIRROR verified=$verified_ctx" "$EX_OK"
