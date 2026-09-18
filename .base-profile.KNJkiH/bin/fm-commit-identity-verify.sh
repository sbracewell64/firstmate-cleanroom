#!/usr/bin/env bash
# Verify that the commits a task delivers carry the captain identity - the
# CONSUMPTION half of the durable commit-identity obligation.
#
# WHY THIS EXISTS. Pinning the no-mistakes gate mirror at spawn
# (bin/fm-nm-commit-identity.sh) is a scoped MITIGATION: it covers repeat runs of
# an already-gated repo, but not a repo's first run (mirror created mid-run), a
# recreated worktree, an effective-context override, or a concurrent writer. A
# mitigation that only warns at spawn cannot close those gaps. This verifier
# closes them by checking the ACTUAL RESULT at a delivery boundary: every commit
# a branch adds over its base must carry the pinned identity in BOTH author and
# committer, or the branch is refused. It reads the real git OBJECTS, so however
# a contaminated commit was produced, it is caught before it can land.
#
# It checks only the PIPELINE-created commits the branch ADDS (base..head) - the
# ones whose subject carries the no-mistakes marker (`no-mistakes...`), which are
# exactly the commits this fix targets. Worker commits, unrelated upstream
# authors, external contributions, and the forge's own squash committer are never
# inspected and never rewritten, so the check cannot false-positive on a
# legitimately non-captain commit and is safe to run at a shared boundary. With
# no pipeline commit in the range there is nothing to enforce and it passes.
#
# Usage:
#   fm-commit-identity-verify.sh --repo <dir> --base <ref> --head <ref>
#       [--name <name> --email <email> | --obligation <file>]
#
# The required identity comes from --name/--email, or from an --obligation file
# holding `name=<name>` and `email=<email>` lines (the durable obligation a
# no-mistakes ship spawn records). One source is required.
#
# Outcomes (stdout line + exit code):
#   OK <n> commits verified            0   every added commit carries the pin
#   CONTAMINATED <detail>              7   an added commit's author or committer is not the pin
#   RANGE_UNREADABLE <detail>          3   base..head could not be resolved
#   usage error                        2
set -u

EX_OK=0 EX_USAGE=2 EX_RANGE=3 EX_CONTAM=7

usage() {
  echo "usage: fm-commit-identity-verify.sh --repo <dir> --base <ref> --head <ref> (--name <n> --email <e> | --obligation <file>)" >&2
  exit "$EX_USAGE"
}

REPO="" BASE="" HEAD="" NAME="" EMAIL="" OBLIGATION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 || usage ;;
    --base) BASE=${2:-}; shift 2 || usage ;;
    --head) HEAD=${2:-}; shift 2 || usage ;;
    --name) NAME=${2:-}; shift 2 || usage ;;
    --email) EMAIL=${2:-}; shift 2 || usage ;;
    --obligation) OBLIGATION=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$HEAD" ] || usage

if [ -n "$OBLIGATION" ]; then
  [ -f "$OBLIGATION" ] || { echo "RANGE_UNREADABLE obligation file not found: $OBLIGATION"; exit "$EX_RANGE"; }
  # Read name=/email= without executing the file.
  NAME=$(sed -n 's/^name=//p' "$OBLIGATION" | head -n1)
  EMAIL=$(sed -n 's/^email=//p' "$OBLIGATION" | head -n1)
fi
[ -n "$NAME" ] && [ -n "$EMAIL" ] || usage

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "RANGE_UNREADABLE not a git repository: $REPO"; exit "$EX_RANGE"; }
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") \
  || { echo "RANGE_UNREADABLE base is not a commit: $BASE"; exit "$EX_RANGE"; }
HEAD_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$HEAD^{commit}") \
  || { echo "RANGE_UNREADABLE head is not a commit: $HEAD"; exit "$EX_RANGE"; }

# Capture the complete traversal before interpreting any result; process
# substitution hides git's failure and can turn unavailable evidence into OK 0.
OBJECTS=$(mktemp "${TMPDIR:-/tmp}/fm-commit-identity.XXXXXX") \
  || { echo "RANGE_UNREADABLE cannot capture commit objects"; exit "$EX_RANGE"; }
trap 'rm -f -- "$OBJECTS"' EXIT
trap 'exit "$EX_RANGE"' HUP INT TERM
if ! git -C "$REPO" log --no-merges --format='%s%x00%H%x00%an%x00%ae%x00%cn%x00%ce%x00' "$BASE_SHA..$HEAD_SHA" > "$OBJECTS" 2>/dev/null; then
  echo "RANGE_UNREADABLE commit traversal failed"
  exit "$EX_RANGE"
fi

want="$NAME <$EMAIL>"
count=0
offenders=""
# subject, then %H, author, committer - NUL-delimited per field so names or
# subjects with spaces or newlines cannot desync the scan. Only commits whose
# subject marks them a no-mistakes pipeline commit are inspected.
while IFS= read -r -d '' subject && IFS= read -r -d '' sha \
  && IFS= read -r -d '' an && IFS= read -r -d '' ae \
  && IFS= read -r -d '' cn && IFS= read -r -d '' ce; do
  # git log writes a newline between records; it lands as a leading newline on
  # every subject after the first. Strip it so the marker match is not defeated.
  subject=${subject#$'\n'}
  case "$subject" in
    no-mistakes*) ;;
    *) continue ;;
  esac
  count=$((count + 1))
  if [ "$an <$ae>" != "$want" ] || [ "$cn <$ce>" != "$want" ]; then
    offenders="$offenders ${sha:0:12}(A:$an <$ae> C:$cn <$ce>)"
  fi
done < "$OBJECTS"

if [ -n "$offenders" ]; then
  echo "CONTAMINATED not the pinned identity ($want):$offenders"
  exit "$EX_CONTAM"
fi
echo "OK $count pipeline commits verified against $want"
exit "$EX_OK"
