#!/usr/bin/env bash
# Dismiss a pending X-mode mention at the relay WITHOUT replying to it.
#
# Usage: fm-x-dismiss.sh <request_id>
#
# When firstmate decides NOT to reply to a mention (a pure acknowledgment, or any
# mention it judges not worth a reply), clearing only the local inbox file is not
# enough: the relay keeps re-offering that request on every poll until it times
# out to a polite "offline" auto-reply. Dismiss tells the relay to drop the
# request outright - it posts nothing and stops re-offering it - so a skipped
# mention causes no re-offer churn and no offline auto-reply.
#
# POSTs {"request_id":"<id>"} (no text - a dismiss has no body) to
# $RELAY/connector/dismiss with the bearer token. On success (2xx) it echoes ONLY
# the request_id and clears the request's durable per-request reply context
# (state/x-context/<id>.json; a dismissed mention never gets a follow-up); on a
# non-2xx (or transport failure) it exits non-zero so the caller knows the
# dismiss did not land and can fall back to leaving the inbox file for a later
# pass. A 4xx other than 401/403/409 is the relay rejecting THIS dismiss: exit
# 10, the payload retained as an undelivered record under state/outbound-writes/,
# and no automatic retry (bin/fm-outbound-write-lib.sh owns that rule).
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), nothing is posted. Instead the
# would-be POST body ({request_id}) is recorded to state/x-outbox/<request_id>.json
# with an "endpoint":"dismiss" marker so the preview is self-describing (the live
# POST body stays {request_id}), a "DRY RUN" summary is printed to stderr, and
# stdout still echoes the request_id with exit 0. Dry-run needs neither a token
# nor the relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-outbound-write-lib.sh
. "$SCRIPT_DIR/fm-outbound-write-lib.sh"

usage() {
  echo "usage: fm-x-dismiss.sh <request_id>" >&2
}

REQ=${1:-}
if [ -z "$REQ" ] || [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

fmx_load_config

# The request_id becomes a filename (inbox/outbox record), so never trust it into
# a path even though the relay issues it.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-dismiss: unsafe request_id: $REQ" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-x-dismiss: jq not found" >&2; exit 1; }

# Build the body with jq so the request_id is correctly JSON-escaped. This is
# exactly what would be POSTed (and, in dry-run, exactly what we record/preview):
# a dismiss carries only {request_id}.
PAYLOAD=$(jq -cn --arg rid "$REQ" '{request_id:$rid}') || {
  echo "fm-x-dismiss: failed to build request payload" >&2; exit 1; }

# Preview / dry-run: surface what we WOULD post and stop, without auth or network.
if [ -n "$FMX_DRY" ]; then
  outbox_dir="$STATE/x-outbox"
  # The recorded body carries an "endpoint":"dismiss" marker so an outbox record
  # is self-describing (the live POST body stays exactly {request_id}).
  OUTREC=$(printf '%s' "$PAYLOAD" | jq -c '. + {endpoint:"dismiss"}') || {
    echo "fm-x-dismiss: failed to build dry-run outbox record" >&2; exit 1; }
  printf '%s\n' "$OUTREC" \
    | fmx_private_artifact_publish_stdin "$outbox_dir" "$REQ.json" 600 || {
    echo "fm-x-dismiss: cannot write dry-run outbox: $outbox_dir/$REQ.json" >&2
    exit 1
  }
  # A dismissed mention will never get a follow-up, so drop its durable
  # per-request reply context too. Best-effort; a no-op when none was recorded.
  fmx_context_registry_clear "$STATE" "$REQ"
  printf 'fm-x-dismiss: DRY RUN - would POST to %s/connector/dismiss (recorded: state/x-outbox/%s.json)\n' \
    "$FMX_RELAY" "$REQ" >&2
  printf '%s\n' "$REQ"
  exit 0
fi

if [ -z "$FMX_TOKEN" ]; then
  echo "fm-x-dismiss: X mode not configured (no FMX_PAIRING_TOKEN)" >&2
  exit 1
fi

# Outbound-write discipline (bin/fm-outbound-write-lib.sh): the body is staged
# to a file and retained with its digest before the POST, the transport reads it
# from that file rather than from an argument, a request the relay already
# rejected is not dismissed again automatically, and the outcome is classified
# only from the returned HTTP status.
PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-x-dismiss.XXXXXX") || {
  echo "fm-x-dismiss: cannot create request payload temp file" >&2; exit 1; }
trap 'rm -f "$PAYLOAD_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE" || { echo "fm-x-dismiss: cannot stage request payload" >&2; exit 1; }
LEDGER=$(fm_outbound_prepare "$STATE" "$PAYLOAD_FILE" writer=fm-x-dismiss \
  "destination=$FMX_RELAY/connector/dismiss" "account=relay-token:$(fmx_token_fingerprint)" \
  "authority=relay-consent:${FMX_ENV_FILE:-$FM_HOME/.env}" disclosure=public \
  "correlation=dismiss:$REQ")
prepare_rc=$?
case "$prepare_rc" in
  0) ;;
  3) echo "fm-x-dismiss: not dismissing $REQ: an earlier dismiss was rejected by the relay and is recorded undelivered; it is not retried automatically" >&2; exit 10 ;;
  *) echo "fm-x-dismiss: could not retain the outgoing payload in state/outbound-writes; nothing was posted" >&2; exit 1 ;;
esac
fm_outbound_readback "$STATE" "$LEDGER" unavailable \
  "the relay exposes no canonical fetch of a dismissed request; acceptance rests on the returned HTTP status" || true
code=$(fm_outbound_send "$STATE" "$LEDGER" file \
  fmx_post_json dismiss "$(fm_outbound_payload_path "$STATE" "$LEDGER")")
post_rc=$?
case "$post_rc" in
  0) : ;;
  127) fm_outbound_classify "$STATE" "$LEDGER" http '' >/dev/null; echo "fm-x-dismiss: curl not found" >&2; exit 1 ;;
  3) fm_outbound_classify "$STATE" "$LEDGER" http '' >/dev/null; echo "fm-x-dismiss: invalid FMX_PAIRING_TOKEN" >&2; exit 1 ;;
  2) echo "fm-x-dismiss: refused to hand the payload to the transport (see stderr above)" >&2; exit 1 ;;
  *) fm_outbound_classify "$STATE" "$LEDGER" http '' >/dev/null; echo "fm-x-dismiss: request to relay failed" >&2; exit 1 ;;
esac

CLASS=$(fm_outbound_classify "$STATE" "$LEDGER" http "$code") || CLASS=
case "$CLASS" in
  accepted)
    # Dropped at the relay: no follow-up will come, so clear the durable
    # per-request reply context too (best-effort, no-op when none was recorded).
    fmx_context_registry_clear "$STATE" "$REQ"
    printf '%s\n' "$REQ"
    ;;
  rejected|rejected-auth)
    echo "fm-x-dismiss: relay rejected the dismiss for $REQ (HTTP $code): undelivered, recorded as state/outbound-writes/$LEDGER.record, and not retried" >&2
    exit 10
    ;;
  *) echo "fm-x-dismiss: relay returned HTTP $code" >&2; exit 1 ;;
esac
