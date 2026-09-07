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
#   resolve    current mode only. Given the event's expected subject (PR number
#              and head SHA) and ONE live provider read (number, head, body), it
#              binds PR identity, refuses a superseded subject (a live head that
#              advanced past the event's subject head - that newer head has its
#              own run), and emits the live body plus the subject head for the
#              verifier. A historical event never reaches this path, so an old
#              event can never be re-judged against a newer body or head.
#              It also fails closed when the live body is empty or unavailable:
#              it emits no body output rather than an empty one.
#              An empty body is falsy to the pinned verifier and would fall back
#              to the frozen event payload, so this refusal keeps a stale event
#              from being reinterpreted against newer PR state.
#   readback   current mode only, AFTER the verifier. Re-reads the live subject
#              (number and head) and refuses to let the result stand if the
#              subject advanced during verification, so an old-head run can never
#              publish a green result for a newer, already-advanced PR head.
#
# All three fail closed: a missing required input or an unrecognized event action
# is an error, never a silent pass. On success 'resolve' prints GITHUB_OUTPUT
# key=value lines on stdout (the multi-line body uses a random heredoc delimiter,
# GitHub's documented mitigation for attacker-controlled multi-line values);
# every diagnostic is a ::error:: line on stderr.
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
  sed -n '2,51{s/^# \{0,1\}//;p;}' "$0"
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
