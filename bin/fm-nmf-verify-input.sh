#!/usr/bin/env bash
# fm-nmf-verify-input.sh - resolve the typed input for the no-mistakes-required
# gate (.github/workflows/no-mistakes-required.yml).
#
# The gate's pinned verifier action judges a PR body's pipeline attestation
# against a PR head SHA, and by default reads BOTH from the frozen workflow
# event payload. That default is correct for events whose evidence is
# historical - 'opened' and 'edited', where a body edit or a fork's first
# approval must be judged exactly as it was at the event. It is wrong for the
# recovery events whose subject is current readiness - 'synchronize' and
# 'reopened' - because the event payload can carry a one-generation-late
# body/head pair (read-replica lag, or a head that advanced after the event),
# which fails a PR whose live body is soundly attested to the live head.
#
# This helper makes the input mode explicit and typed instead of a blanket live
# read, so a stale event is never silently reinterpreted against newer PR state:
#
#   classify   maps the event action to 'historical' or 'current'. Single owner
#              of that mapping, so the workflow never re-spells the action list.
#   resolve    current mode only, classifies ONE live provider read against the
#              event subject. Given the event's expected subject (PR number and
#              head SHA) and one live read (number, head, body), it binds PR
#              identity, refuses a superseded subject (a live head that advanced
#              past the event's subject head - that newer head has its own run),
#              and inspects whether the live body's pipeline attestation is bound
#              to the live head yet:
#                BOUND   (exit 0): the live body carries a v1 pipeline
#                        attestation whose head_sha equals the live head. It
#                        emits the live body plus the subject head for the
#                        verifier, exactly as before.
#                PENDING (exit 3): the live body is present but its attestation
#                        does not bind the live head yet (attestation absent, or
#                        bound to a prior head). This is the publication-timing
#                        window: 'git push no-mistakes' advances the head and
#                        then re-publishes the body attestation for it in two
#                        steps, so a synchronize event can fire and read the body
#                        before the re-publication lands. The caller (workflow)
#                        may re-read and retry within a short bounded SAME-SUBJECT
#                        window; resolve emits no body output in this state, so a
#                        not-yet-bound body can never reach the verifier as bound.
#              A historical event never reaches this path, so an old event can
#              never be re-judged against a newer body or head. It fails closed
#              (exit 1) on identity mismatch, a superseded subject, or an empty
#              live body. An empty body is falsy to the pinned verifier and would
#              fall back to the frozen event payload, so that refusal keeps a
#              stale event from being reinterpreted against newer PR state. A
#              body that never binds the live head only ever reaches PENDING, so
#              the caller's bounded window turns a sustained mismatch into a
#              fail-closed deadline, never a pass.
#   readback   current mode only, AFTER the verifier. Re-reads the live subject
#              (number and head) and refuses to let the result stand if the
#              subject advanced during verification, so an old-head run can never
#              publish a green result for a newer, already-advanced PR head.
#
# All three fail closed: a missing required input or an unrecognized event action
# is an error, never a silent pass. On a BOUND result 'resolve' prints
# GITHUB_OUTPUT key=value lines on stdout (the multi-line body uses a random
# heredoc delimiter, GitHub's documented mitigation for attacker-controlled
# multi-line values); a hard refusal exits non-zero with a ::error:: line on
# stderr; the PENDING publication-window state exits 3 with a ::notice:: line and
# no stdout output, which is a retry signal to the caller, never a pass.
#
# Usage:
#   NMF_EVENT_ACTION=<action> fm-nmf-verify-input.sh classify
#   NMF_EVENT_NUMBER=<n> NMF_EVENT_HEAD_SHA=<sha> \
#     NMF_LIVE_NUMBER=<n> NMF_LIVE_HEAD_SHA=<sha> NMF_LIVE_BODY=<body> \
#     fm-nmf-verify-input.sh resolve
#   NMF_SUBJECT_NUMBER=<n> NMF_SUBJECT_HEAD=<sha> \
#     NMF_LIVE_NUMBER=<n> NMF_LIVE_HEAD_SHA=<sha> \
#     fm-nmf-verify-input.sh readback
#   fm-nmf-verify-input.sh --help
set -eu

usage() {
  sed -n '2,71{s/^# \{0,1\}//;p;}' "$0"
}

# ::error:: annotation on stderr, then the given exit code.
die() {
  local code=$1
  shift
  printf '::error::%s\n' "$*" >&2
  exit "$code"
}

require() {
  local name=$1 value=$2
  [ -n "$value" ] || die 2 "fm-nmf-verify-input.sh $SUBCOMMAND: missing required input $name."
}

# PENDING publication-window state: a ::notice:: (not ::error::) annotation on
# stderr and exit 3 - the caller's retry-within-the-window signal, never a pass.
# Emits nothing on stdout, so a body not yet bound to the live head can never be
# consumed as a resolved live subject.
pending() {
  printf '::notice::%s\n' "$*" >&2
  exit 3
}

# The pipeline attestation delimiters, byte-for-byte the pinned verifier's
# (verify.py) ATTESTATION_PREFIX and ATTESTATION_CLOSING. Kept identical so this
# helper's "is the body bound to the live head yet" predicate agrees with the
# verifier's authoritative head-bind read. The verifier remains the sole judge
# of a BOUND body; this predicate only decides WHEN the body is handed to it.
ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
ATTESTATION_CLOSING=' -->'

# Print the head_sha of the FIRST v1 pipeline attestation block in the body, or
# nothing when no block is present, the block is unterminated, or it carries no
# head_sha. Mirrors verify.py, which uses the first block and reads its head_sha
# field. Pure string work with no JSON dependency; a malformed or head_sha-less
# block yields nothing, which the caller treats as not-yet-bound (PENDING)
# rather than a pass, so the fail-closed direction is preserved.
attested_head_of_body() {
  local body=$1 rest block
  case "$body" in
    *"$ATTESTATION_PREFIX"*) ;;
    *) return 0 ;;
  esac
  rest=${body#*"$ATTESTATION_PREFIX"}
  case "$rest" in
    *"$ATTESTATION_CLOSING"*) block=${rest%%"$ATTESTATION_CLOSING"*} ;;
    *) return 0 ;;
  esac
  printf '%s' "$block" \
    | sed -n 's/.*"head_sha"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]\{7,\}\)".*/\1/p' \
    | head -1
}

# A random GITHUB_OUTPUT heredoc delimiter. 128 bits of entropy makes a
# collision with any line the (attacker-controlled) PR body could contain
# infeasible, so the body can never break out and inject extra outputs.
random_delimiter() {
  local hex
  hex=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -dc 'a-f0-9') || hex=
  [ -n "$hex" ] || die 1 "fm-nmf-verify-input.sh $SUBCOMMAND: could not read a random output delimiter."
  printf 'NMF_BODY_%s\n' "$hex"
}

classify() {
  local action=${NMF_EVENT_ACTION:-}
  require NMF_EVENT_ACTION "$action"
  case "$action" in
    opened|edited)
      printf 'mode=historical\n'
      ;;
    synchronize|reopened)
      printf 'mode=current\n'
      ;;
    *)
      die 2 "fm-nmf-verify-input.sh classify: unrecognized event action '$action'."
      ;;
  esac
}

resolve() {
  local event_number=${NMF_EVENT_NUMBER:-}
  local event_head=${NMF_EVENT_HEAD_SHA:-}
  local live_number=${NMF_LIVE_NUMBER:-}
  local live_head=${NMF_LIVE_HEAD_SHA:-}
  local live_body=${NMF_LIVE_BODY:-}
  require NMF_EVENT_NUMBER "$event_number"
  require NMF_EVENT_HEAD_SHA "$event_head"
  require NMF_LIVE_NUMBER "$live_number"
  require NMF_LIVE_HEAD_SHA "$live_head"
  # Bind PR identity: the live read must describe the same PR the event names.
  if [ "$live_number" != "$event_number" ]; then
    die 1 "fm-nmf-verify-input.sh resolve: live PR identity #$live_number does not match the event subject #$event_number."
  fi

  # Refuse a superseded subject: if the live head has advanced past the head this
  # run's event was fired for, this run is stale. The advanced head fires its own
  # run; letting this one continue would judge a body/head this run is not about.
  if [ "$live_head" != "$event_head" ]; then
    die 1 "fm-nmf-verify-input.sh resolve: subject superseded - event head $event_head, live head $live_head. The advanced head has its own run; this run must not publish a result for it."
  fi

  # Fail closed on an empty live body. An empty PR_BODY is falsy to the pinned
  # verifier, which would fall back to the frozen event payload - exactly the
  # stale reinterpretation this mode forbids. Refuse before emitting any output.
  if [ -z "$live_body" ]; then
    die 1 "fm-nmf-verify-input.sh resolve: current-mode live body is empty or unavailable; no sound live subject established, refusing to fall back to the frozen event payload."
  fi

  # Publication-timing window. 'git push no-mistakes' advances the head and then
  # re-publishes the body attestation for the new head in two steps, so a
  # synchronize event can read the body after the head landed but before the
  # attestation was re-bound to it - the FAIL-then-SUCCESS race on one head that
  # this fix exists for. Only emit a BOUND live subject once the live body's
  # attestation binds the live head; otherwise report PENDING so the caller can
  # re-read within its bounded SAME-SUBJECT window. A body that never binds the
  # live head only ever reaches PENDING, so the caller's deadline turns a
  # sustained mismatch into a fail-closed refusal, never a pass. The verifier
  # stays the sole authority on a BOUND body.
  local attested_head
  attested_head=$(attested_head_of_body "$live_body")
  if [ -z "$attested_head" ]; then
    pending "fm-nmf-verify-input.sh resolve: live body carries no pipeline attestation bound to the live head $live_head yet; awaiting publication within the bounded window."
  fi
  if [ "$attested_head" != "$live_head" ]; then
    pending "fm-nmf-verify-input.sh resolve: live body attestation is bound to $attested_head, not the live head $live_head; awaiting re-publication for the current head within the bounded window."
  fi

  local delimiter
  delimiter=$(random_delimiter)
  printf 'head_sha=%s\n' "$live_head"
  printf 'subject_head=%s\n' "$live_head"
  printf 'subject_number=%s\n' "$live_number"
  printf 'body<<%s\n' "$delimiter"
  printf '%s\n' "$live_body"
  printf '%s\n' "$delimiter"
}

readback() {
  local subject_number=${NMF_SUBJECT_NUMBER:-}
  local subject_head=${NMF_SUBJECT_HEAD:-}
  local live_number=${NMF_LIVE_NUMBER:-}
  local live_head=${NMF_LIVE_HEAD_SHA:-}
  require NMF_SUBJECT_NUMBER "$subject_number"
  require NMF_SUBJECT_HEAD "$subject_head"
  require NMF_LIVE_NUMBER "$live_number"
  require NMF_LIVE_HEAD_SHA "$live_head"

  if [ "$live_number" != "$subject_number" ]; then
    die 1 "fm-nmf-verify-input.sh readback: live PR identity #$live_number no longer matches the verified subject #$subject_number."
  fi
  if [ "$live_head" != "$subject_head" ]; then
    die 1 "fm-nmf-verify-input.sh readback: subject advanced during verification - verified head $subject_head, live head $live_head. Refusing to publish a result for a superseded head."
  fi
  printf 'Live PR subject #%s at %s still matches the verified subject.\n' "$live_number" "$live_head"
}

SUBCOMMAND=${1:-}
case "$SUBCOMMAND" in
  classify) classify ;;
  resolve) resolve ;;
  readback) readback ;;
  --help|-h|help) usage ;;
  '') die 2 "fm-nmf-verify-input.sh: a subcommand is required (classify|resolve|readback)." ;;
  *) die 2 "fm-nmf-verify-input.sh: unknown subcommand '$SUBCOMMAND'." ;;
esac
