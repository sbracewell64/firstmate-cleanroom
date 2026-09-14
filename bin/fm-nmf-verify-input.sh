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
# read, so a stale event is never silently reinterpreted against newer PR state.
# It decides WHICH subject the verifier judges and WHEN it is handed over; the
# pinned verifier remains the sole judge of the verdict itself, including the
# signature, the attestation, the head bind, and any configured exemption.
#
#   classify   maps the event action to 'historical' or 'current'. Single owner
#              of that mapping, so the workflow never re-spells the action list.
#   await      current mode only, the whole live-subject step. Single owner of
#              the publication wait: it reads the live PR (absorbing a transient
#              read failure - retried a bounded number of times per read, then
#              re-read on the next poll - always within the same window),
#              classifies each read through 'resolve', waits while a publication
#              is demonstrably in flight, and emits exactly one resolved subject
#              for the verifier. A window that closes having never obtained a
#              sound live read fails closed with no subject at all; one that
#              closes on a publication that never landed hands the most recent
#              sound read to the verifier, which owns that verdict. The workflow
#              never re-spells the window, the poll cadence, the retry budget,
#              or the deadline behavior.
#   resolve    the pure classifier behind 'await': given the event's expected
#              subject (PR number and head SHA) and one live read (number, head,
#              body), it binds PR identity, refuses a superseded subject (a live
#              head that advanced past the event's subject head - that newer head
#              has its own run), and decides whether that read is ready for the
#              verifier:
#                BOUND    (exit 0): the live body carries a v1 pipeline
#                         attestation whose head_sha equals the live head. It
#                         emits the live body plus the subject head.
#                PENDING  (exit 3): the live body carries the no-mistakes
#                         signature but its attestation does not bind the live
#                         head yet (attestation absent, or bound to a prior
#                         head). The signature is positive evidence that a
#                         no-mistakes publication owns this body and a rebind is
#                         in flight, so this state means "wait", never "pass":
#                         it emits no subject at all.
#                HANDOFF  (exit 0): the attestation does not bind the live head
#                         and waiting cannot change that - either the body
#                         carries no no-mistakes signature (nothing is
#                         publishing, so there is nothing to wait for), or
#                         NMF_PUBLICATION_FINAL is set because the caller's
#                         window closed. It emits the live subject with a
#                         stderr annotation and lets the pinned verifier produce
#                         the authoritative refusal (or the configured
#                         exemption) against the live head.
#              A historical event never reaches this path, so an old event can
#              never be re-judged against a newer body or head. It fails closed
#              (exit 1) on identity mismatch, a superseded subject, or an empty
#              live body. An empty body is falsy to the pinned verifier and would
#              fall back to the frozen event payload, so that refusal keeps a
#              stale event from being reinterpreted against newer PR state.
#   readback   current mode only, AFTER the verifier. Re-reads the live subject
#              (number and head) and refuses to let the result stand if the
#              subject advanced during verification, so an old-head run can never
#              publish a green result for a newer, already-advanced PR head.
#
# All four fail closed: a missing required input, an unreadable or definitively
# refused live PR, or an unrecognized event action is an error, never a silent
# pass. On a BOUND or HANDOFF result 'resolve' and 'await' print GITHUB_OUTPUT
# key=value lines on stdout (the multi-line body uses a random heredoc
# delimiter, GitHub's documented mitigation for attacker-controlled multi-line
# values); a hard refusal exits non-zero with a ::error:: line on stderr;
# PENDING exits 3 with a ::notice:: line and no stdout output, which is a retry
# signal to 'await', never a pass.
#
# Publication wait, and why it is bounded the way it is. 'git push no-mistakes'
# advances the PR head and then re-publishes the body attestation for the new
# head as a later step, so a synchronize event routinely fires and reads the
# body before the rebind lands. Measured against this repository's own gate runs
# and PR body edit history, that gap was 18s and 21s on the two races that
# passed, 117s, 118s and 117s on three consecutive recent races, and 358s twice
# earlier - so the previous 90s window was below every failing observation and
# above neither. NMF_PUBLICATION_WINDOW_SECONDS defaults to 600, which covers
# the largest observed gap with roughly 1.7x headroom while staying far inside
# the job's own timeout, so the deadline - not the platform - produces the
# outcome. Past that the pipeline is no longer racing the gate, it has stalled,
# and a red check the pipeline's own CI-fix loop can act on is the honest
# result. The wait costs nothing on the two paths that matter most: a bound body
# returns on the first read, and a body with no no-mistakes signature hands off
# on the first read instead of waiting out a window it can never satisfy.
#
# NMF_PUBLICATION_WINDOW_SECONDS overrides that derived default, so the workflow
# step that wires this helper must not pin a lower value.
# The base workflow's "Resolve live PR subject" step currently pins '90' in its
# env, which is below every failing observation recorded above.
# Leaving that line in place when the step is wired to 'await' would silently
# override the derived bound back to 90s, making this fix inert while all of its
# machinery still runs, so the step that adopts 'await' must drop it.
#
# KNOWN, UNEXERCISED GAP: gating the wait on the signature covers a
# re-publication race but not a FIRST-publication race - a PR a person opened by
# hand, whose body is still unsigned when 'git push no-mistakes' advances the
# head. There is no bound for that case because there is nothing to size one
# from: across all 89 recorded gate runs and 49 PRs in this repository, no
# synchronize event has ever seen an unsigned body. Every recorded PR was created
# by the pipeline already carrying its signature and attestation, and all four
# failures this wait exists for carried a signed body attested to the PRIOR head
# for the whole window. Fail-closed still holds there: such a PR fails without a
# wait rather than passing, and the symptom, if it ever occurs, is one re-run -
# the same cost as today, not a loss of safety.
#
# Usage:
#   NMF_EVENT_ACTION=<action> fm-nmf-verify-input.sh classify
#   GITHUB_REPOSITORY=<owner/name> NMF_EVENT_NUMBER=<n> NMF_EVENT_HEAD_SHA=<sha> \
#     [NMF_PUBLICATION_WINDOW_SECONDS=<s>] [NMF_PUBLICATION_POLL_SECONDS=<s>] \
#     [NMF_LIVE_READ_ATTEMPTS=<n>] [NMF_LIVE_READ_BACKOFF_SECONDS=<s>] \
#     fm-nmf-verify-input.sh await
#   NMF_EVENT_NUMBER=<n> NMF_EVENT_HEAD_SHA=<sha> \
#     NMF_LIVE_NUMBER=<n> NMF_LIVE_HEAD_SHA=<sha> NMF_LIVE_BODY=<body> \
#     [NMF_PUBLICATION_FINAL=1] fm-nmf-verify-input.sh resolve
#   NMF_SUBJECT_NUMBER=<n> NMF_SUBJECT_HEAD=<sha> \
#     NMF_LIVE_NUMBER=<n> NMF_LIVE_HEAD_SHA=<sha> \
#     fm-nmf-verify-input.sh readback
#   fm-nmf-verify-input.sh --help
set -eu

# Defaults for the bounded publication wait; the header owns their derivation.
NMF_PUBLICATION_WINDOW_SECONDS_DEFAULT=600
NMF_PUBLICATION_POLL_SECONDS_DEFAULT=10
# Live-read retry budget: at most 3 attempts with 2s then 4s of backoff, so a
# transient forge failure costs at most 6s of the window it is spent inside.
NMF_LIVE_READ_ATTEMPTS_DEFAULT=3
NMF_LIVE_READ_BACKOFF_SECONDS_DEFAULT=2

usage() {
  sed -n '2,128{s/^# \{0,1\}//;p;}' "$0"
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
# stderr and exit 3 - 'await's retry-within-the-window signal, never a pass.
# Emits nothing on stdout, so a body not yet bound to the live head can never be
# consumed as a resolved live subject.
pending() {
  printf '::notice::%s\n' "$*" >&2
  exit 3
}

# The pipeline signature line and attestation delimiters, byte-for-byte the
# pinned verifier's (verify.py) SIGNATURE_MARKER, ATTESTATION_PREFIX and
# ATTESTATION_CLOSING. Kept identical so this helper's "is a no-mistakes
# publication in flight for this body" and "is the body bound to the live head
# yet" predicates agree with the verifier's authoritative reads. The verifier
# remains the sole judge of the verdict; these predicates only decide WHEN the
# body is handed to it.
SIGNATURE_MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
ATTESTATION_CLOSING=' -->'

# True when the body carries the no-mistakes signature line. That line is what a
# pipeline writes into every body it owns, so its presence is the evidence that a
# rebind for a newer head is in flight and worth waiting for; its absence means
# no publication is coming and the verifier should judge the body immediately.
body_has_signature() {
  case "$1" in
    *"$SIGNATURE_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the head_sha of the FIRST v1 pipeline attestation block in the body, or
# nothing when no block is present, the block is unterminated, or it carries no
# head_sha. Mirrors verify.py, which uses the first block and reads its head_sha
# field. Pure string work with no JSON dependency; a malformed or head_sha-less
# block yields nothing, which the caller treats as not-yet-bound rather than a
# pass, so the fail-closed direction is preserved.
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

# A positive integer, or a typed refusal. A malformed bound must never silently
# become zero (judge immediately) or unbounded (never judge).
require_positive_int() {
  local name=$1 value=$2
  case "$value" in
    ''|*[!0-9]*) die 2 "fm-nmf-verify-input.sh $SUBCOMMAND: $name must be a positive integer, got '$value'." ;;
  esac
  [ "$value" -gt 0 ] || die 2 "fm-nmf-verify-input.sh $SUBCOMMAND: $name must be a positive integer, got '$value'."
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

emit_subject() {
  local live_number=$1 live_head=$2 live_body=$3 delimiter
  delimiter=$(random_delimiter)
  printf 'head_sha=%s\n' "$live_head"
  printf 'subject_head=%s\n' "$live_head"
  printf 'subject_number=%s\n' "$live_number"
  printf 'body<<%s\n' "$delimiter"
  printf '%s\n' "$live_body"
  printf '%s\n' "$delimiter"
}

resolve() {
  local event_number=${NMF_EVENT_NUMBER:-}
  local event_head=${NMF_EVENT_HEAD_SHA:-}
  local live_number=${NMF_LIVE_NUMBER:-}
  local live_head=${NMF_LIVE_HEAD_SHA:-}
  local live_body=${NMF_LIVE_BODY:-}
  local final=${NMF_PUBLICATION_FINAL:-}
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

  local attested_head
  attested_head=$(attested_head_of_body "$live_body")
  if [ "$attested_head" != "$live_head" ]; then
    # The attestation does not bind the live head. Wait only while a publication
    # is demonstrably in flight, which the signature line is the evidence for.
    if [ -z "$final" ] && body_has_signature "$live_body"; then
      if [ -z "$attested_head" ]; then
        pending "fm-nmf-verify-input.sh resolve: live body carries no pipeline attestation bound to the live head $live_head yet; awaiting publication within the bounded window."
      fi
      pending "fm-nmf-verify-input.sh resolve: live body attestation is bound to $attested_head, not the live head $live_head; awaiting re-publication for the current head within the bounded window."
    fi
    # Waiting cannot help, so hand the live subject over now and let the pinned
    # verifier state the authoritative outcome against the live head.
    if body_has_signature "$live_body"; then
      printf '::warning::fm-nmf-verify-input.sh resolve: the publication window closed with the live body attested to %s, not the live head %s; handing the live subject to the verifier, which judges the head bind.\n' \
        "${attested_head:-no head}" "$live_head" >&2
    else
      printf '::notice::fm-nmf-verify-input.sh resolve: the live body carries no no-mistakes signature, so no publication is in flight for head %s; handing the live subject to the verifier now instead of waiting.\n' \
        "$live_head" >&2
    fi
  fi

  emit_subject "$live_number" "$live_head" "$live_body"
}

# Classify a failed live read from the two structural signals the read produces:
# the exit status, and the HTTP status the forge printed. Only a failure that
# could answer differently on the next attempt may be retried: a transport
# failure, which reaches us as a generic exit with no HTTP status at all, and a
# 5xx or 429, which are the forge declining to answer right now.
#
# Everything else is definitive and must propagate immediately rather than be
# retried, because no number of attempts can change it and no retry may ever
# turn a genuinely missing attestation into a pass. gh's own exit status names
# two of those that carry no HTTP status and so cannot be told apart from a
# transport failure by message text: 4 is "authentication required" (an absent
# or invalid GH_TOKEN), and 127 is the shell's "command not found" for a gh that
# is not on PATH. Both are misconfiguration, not weather.
live_read_is_transient() {
  local exit_status=$1 status
  case "$exit_status" in
    4|127) return 1 ;;
  esac
  status=$(printf '%s' "$2" | sed -n 's/.*(HTTP \([0-9][0-9][0-9]\)).*/\1/p' | head -1)
  case "$status" in
    '') return 0 ;;
    5??|429) return 0 ;;
    *) return 1 ;;
  esac
}

# One live PR read into the NMF_LIVE_* inputs 'resolve' classifies, with a small
# bounded retry for a transient failure. Exit 0 means NMF_LIVE_* now describe a
# sound read; exit 3 means the budget was spent on a TRANSIENT failure and this
# poll produced no sound read, which the caller treats exactly like PENDING - it
# re-reads on the next poll while the window is open. A DEFINITIVE failure is
# never retried and never downgraded to pending: it is fatal on the spot.
#
# Fail-closed is preserved at the WINDOW boundary, not at the first transient
# blip. The retry exists because the wait multiplies this read: one
# all-or-nothing read per poll means a single 502 anywhere in the window reds a
# PR whose attestation does publish - the same defect this whole change removes -
# and dying the moment a 6s budget is spent leaves the rest of the window unused
# for the same outcome. The budget is deliberately small and is spent INSIDE the
# publication window (the caller measures elapsed time from one fixed start), so
# the worst case an operator sees is the window, not the window plus the retries;
# a window that closes with no sound read at all still fails closed, in the
# caller, with no subject handed over.
LAST_LIVE_READ_FAILURE=
read_live_subject() {
  local repo=$1 number=$2 attempts=$3 backoff=$4
  local attempt=1 pr rc errfile reason
  errfile=$(mktemp) || die 1 "fm-nmf-verify-input.sh await: could not create a temporary file for the live PR read."
  while : ; do
    rc=0
    pr=$(gh api "repos/${repo}/pulls/${number}" 2>"$errfile") || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$errfile"
      LAST_LIVE_READ_FAILURE=
      # Deliberately not exported: 'resolve' runs in this shell, while an
      # exported body would be copied into every later child's environment.
      NMF_LIVE_NUMBER=$(printf '%s' "$pr" | jq -r '.number // ""')
      NMF_LIVE_HEAD_SHA=$(printf '%s' "$pr" | jq -r '.head.sha // ""')
      NMF_LIVE_BODY=$(printf '%s' "$pr" | jq -r '.body // ""')
      return 0
    fi
    reason=$(tr '\n' ' ' < "$errfile")
    if ! live_read_is_transient "$rc" "$reason"; then
      rm -f "$errfile"
      die 1 "fm-nmf-verify-input.sh await: could not read the live PR repos/${repo}/pulls/${number}; the read failed definitively (exit ${rc}), so there is no sound live subject and no retry can establish one: ${reason}"
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      rm -f "$errfile"
      LAST_LIVE_READ_FAILURE=$reason
      printf '::notice::fm-nmf-verify-input.sh await: the live PR read failed transiently on all %s attempt(s) of this poll (%s); re-reading on the next poll while the publication window is open.\n' \
        "$attempts" "$reason" >&2
      return 3
    fi
    printf '::notice::fm-nmf-verify-input.sh await: live PR read attempt %s of %s failed transiently (%s); retrying in %ss.\n' \
      "$attempt" "$attempts" "$reason" "$backoff" >&2
    sleep "$backoff"
    attempt=$(( attempt + 1 ))
    backoff=$(( backoff * 2 ))
  done
}

await() {
  local repo=${GITHUB_REPOSITORY:-}
  local event_number=${NMF_EVENT_NUMBER:-}
  local event_head=${NMF_EVENT_HEAD_SHA:-}
  local window=${NMF_PUBLICATION_WINDOW_SECONDS:-$NMF_PUBLICATION_WINDOW_SECONDS_DEFAULT}
  local poll=${NMF_PUBLICATION_POLL_SECONDS:-$NMF_PUBLICATION_POLL_SECONDS_DEFAULT}
  local attempts=${NMF_LIVE_READ_ATTEMPTS:-$NMF_LIVE_READ_ATTEMPTS_DEFAULT}
  local backoff=${NMF_LIVE_READ_BACKOFF_SECONDS:-$NMF_LIVE_READ_BACKOFF_SECONDS_DEFAULT}
  require GITHUB_REPOSITORY "$repo"
  require NMF_EVENT_NUMBER "$event_number"
  require NMF_EVENT_HEAD_SHA "$event_head"
  require_positive_int NMF_PUBLICATION_WINDOW_SECONDS "$window"
  require_positive_int NMF_PUBLICATION_POLL_SECONDS "$poll"
  require_positive_int NMF_LIVE_READ_ATTEMPTS "$attempts"
  require_positive_int NMF_LIVE_READ_BACKOFF_SECONDS "$backoff"

  local started elapsed polls=0 rc read_rc out sound_read=
  # This command's own deadline is the only thing that ends the wait, so an
  # inherited finality flag can never shorten the window out from under it.
  NMF_PUBLICATION_FINAL=
  started=$(date +%s)
  while : ; do
    polls=$(( polls + 1 ))
    read_rc=0
    read_live_subject "$repo" "$event_number" "$attempts" "$backoff" || read_rc=$?
    if [ "$read_rc" -eq 0 ]; then
      sound_read=1
      rc=0
      out=$(resolve) || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        return 0
      fi
      # Exit 3 is PENDING (a publication is in flight); any other non-zero is a
      # hard fail-closed refusal that must propagate immediately.
      [ "$rc" -eq 3 ] || exit "$rc"
    fi
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -ge "$window" ]; then
      # Which of the two deadline diagnoses this is turns on whether a sound
      # live read was EVER obtained, not on how the last poll happened to end.
      # A wait whose reads were sound and whose publication simply never landed
      # is a stalled publication, and the verifier owns that verdict; only a
      # wait that never established any live subject is a read outage. The
      # NMF_LIVE_* inputs still hold the most recent sound read, so 'resolve'
      # re-applies the identity and superseded-subject guards to it before it
      # can be handed over.
      if [ -z "$sound_read" ]; then
        die 1 "fm-nmf-verify-input.sh await: the ${window}s publication window closed with no sound live read of repos/${repo}/pulls/${event_number} ever obtained, across ${elapsed}s and ${polls} poll(s); every read failed transiently, the last with: ${LAST_LIVE_READ_FAILURE}. There is no live subject to hand to the verifier, so this fails closed."
      fi
      printf '::warning::fm-nmf-verify-input.sh await: the no-mistakes attestation for PR #%s head %s was still unpublished after %ss and %s poll(s); the %ss publication window is closed, so the verifier now judges the live body as it stands.\n' \
        "$event_number" "$event_head" "$elapsed" "$polls" "$window" >&2
      NMF_PUBLICATION_FINAL=1
      rc=0
      out=$(resolve) || rc=$?
      [ "$rc" -eq 0 ] || exit "$rc"
      printf '%s\n' "$out"
      return 0
    fi
    sleep "$poll"
  done
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
  await) await ;;
  resolve) resolve ;;
  readback) readback ;;
  --help|-h|help) usage ;;
  '') die 2 "fm-nmf-verify-input.sh: a subcommand is required (classify|await|resolve|readback)." ;;
  *) die 2 "fm-nmf-verify-input.sh: unknown subcommand '$SUBCOMMAND'." ;;
esac
