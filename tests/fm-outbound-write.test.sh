#!/usr/bin/env bash
# Behavior tests for the outbound-write discipline (bin/fm-outbound-write-lib.sh)
# and its enforcement at the tracked writers that send firstmate-authored bytes
# out of a home: the Relay reply, follow-up, and dismiss clients and the remote
# secondmate steer. Every transport is a fixture (a fakebin curl, a fake ssh);
# nothing here reaches a network.
#
# The cases that were RED before the library existed:
#   - fm-x-dismiss handed its JSON body to curl as an argument instead of a file;
#   - fm-send called a remote steer delivered on the transport's exit status
#     alone, with no canonical read-back of the recorded bytes;
#   - fm-x-followup kept the link after a relay 4xx rejection, so the next pass
#     posted the same rejected reply again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-outbound-write-lib.sh
. "$ROOT/bin/fm-outbound-write-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PERL_DIR=$(command -v perl 2>/dev/null) && PERL_DIR=$(dirname "$PERL_DIR") || PERL_DIR=
[ -n "$PERL_DIR" ] && BASE_PATH="$PERL_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-outbound-write-tests)
SEND="$ROOT/bin/fm-send.sh"

sha256_of() {  # <file>
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# A fakebin curl standing in for the relay. It logs every argv element on its
# own "arg=" line plus the body it received, so a test can prove the body
# arrived through a file and not through the command line.
make_fake_curl() {  # <home>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" data="" url=""
for a in "$@"; do printf 'arg=%s\n' "$a" >> "$FAKE_CURL_LOG"; done
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) cat -- "${2#@}" > "$FAKE_CURL_LOG.body"; data=$(cat -- "$FAKE_CURL_LOG.body") ;;
        *) data=$2 ;;
      esac
      shift 2 ;;
    -H|-m|-w|-X) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
{ echo "url=$url"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
case "$url" in
  */connector/answer)   [ -n "$ofile" ] && printf '%s' "${FAKE_ANSWER_BODY:-}" > "$ofile"; printf '%s' "${FAKE_ANSWER_CODE:-200}" ;;
  */connector/followup) printf '%s' "${FAKE_FOLLOWUP_CODE:-200}" ;;
  */connector/dismiss)  printf '%s' "${FAKE_DISMISS_CODE:-200}" ;;
  *) printf '204' ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

posts_to() {  # <log> <endpoint>
  grep -c "^url=.*/connector/$2\$" "$1" 2>/dev/null || true
}

# --- library contract --------------------------------------------------------

test_prepare_refuses_missing_fields_and_retains_exact_bytes() {
  local state payload id rec bytes
  state="$TMP_ROOT/lib-prepare/state"; mkdir -p "$state"
  payload="$TMP_ROOT/lib-prepare/payload"; printf 'hello\nworld' > "$payload"
  fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public \
    >/dev/null 2>&1 && fail "prepare must refuse a missing correlation"
  fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=loud correlation=c \
    >/dev/null 2>&1 && fail "prepare must refuse an unknown disclosure scope"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c) \
    || fail "prepare must succeed with every required field"
  rec=$(fm_outbound_record_path "$state" "$id")
  cmp -s "$payload" "$(fm_outbound_payload_path "$state" "$id")" || fail "the ledger must retain the exact payload bytes"
  bytes=$(fm_outbound_get "$state" "$id" bytes)
  [ "$bytes" = 11 ] || fail "the ledger must record the payload length, got $bytes"
  [ "$(fm_outbound_get "$state" "$id" sha256)" = "$(sha256_of "$payload")" ] || fail "the ledger must record the payload sha256"
  [ "$(fm_outbound_get "$state" "$id" outcome)" = prepared ] || fail "a prepared write starts as prepared"
  [ "$(stat -c %a "$rec" 2>/dev/null || stat -f %Lp "$rec")" = 600 ] || fail "records must be mode 0600"
  [ "$(stat -c %a "$state/outbound-writes" 2>/dev/null || stat -f %Lp "$state/outbound-writes")" = 700 ] || fail "the ledger directory must be mode 0700"
  pass "prepare refuses missing structured fields and retains exact bytes, length, and sha256 privately"
}

test_send_refuses_message_bytes_in_argv() {
  local state payload id out rc
  state="$TMP_ROOT/lib-send/state"; mkdir -p "$state"
  payload="$TMP_ROOT/lib-send/payload"; printf '{"request_id":"r"}' > "$payload"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c)
  rc=0
  fm_outbound_send "$state" "$id" file true --data '{"request_id":"r"}' 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "file conveyance must refuse argv that carries the message bytes (got $rc)"
  [ -z "$(fm_outbound_get "$state" "$id" sent_epoch)" ] || fail "a refused send must not be recorded as sent"
  out=$(fm_outbound_send "$state" "$id" file sh -c "cat \"\$FM_OUTBOUND_PAYLOAD_FILE\"") || fail "file conveyance must run the transport"
  [ "$out" = '{"request_id":"r"}' ] || fail "the transport must read the body from the ledger file, got: $out"
  out=$(fm_outbound_send "$state" "$id" stdin cat) || fail "stdin conveyance must pipe the payload"
  [ "$out" = '{"request_id":"r"}' ] || fail "stdin conveyance must deliver the exact bytes, got: $out"
  rc=0
  fm_outbound_send "$state" "$id" argv:2 true other '{"request_id":"r"}' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a declared opaque argv element that IS the payload must be accepted (got $rc)"
  rc=0
  fm_outbound_send "$state" "$id" argv:1 true other '{"request_id":"r"}' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a declared argv element that is not the payload must be refused (got $rc)"
  [ "$(fm_outbound_get "$state" "$id" send_rc)" = 0 ] || fail "send must record the transport status"
  pass "send conveys the body by file, stdin, or one declared opaque argv element and refuses silent argv interpolation"
}

test_readback_and_classify_verdicts() {
  local state payload id cls
  state="$TMP_ROOT/lib-rb/state"; mkdir -p "$state"
  payload="$TMP_ROOT/lib-rb/payload"; printf 'body' > "$payload"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=fleet correlation=c1)
  fm_outbound_readback "$state" "$id" exact printf 'body' || fail "an exact read-back of equal bytes must verify"
  cls=$(fm_outbound_classify "$state" "$id" exit 0)
  [ "$cls" = accepted ] && [ "$(fm_outbound_get "$state" "$id" outcome)" = delivered ] \
    || fail "accepted plus verified read-back is delivered, got $cls/$(fm_outbound_get "$state" "$id" outcome)"

  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=fleet correlation=c2)
  fm_outbound_readback "$state" "$id" exact printf 'other' && fail "a differing read-back must not verify"
  [ "$(fm_outbound_get "$state" "$id" readback)" = mismatch ] || fail "a differing read-back is recorded as mismatch"
  cls=$(fm_outbound_classify "$state" "$id" exit 0)
  [ "$(fm_outbound_get "$state" "$id" outcome)" = undelivered ] \
    || fail "an accepted transport with a read-back mismatch is undelivered, never delivered"

  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=fleet correlation=c3)
  fm_outbound_readback "$state" "$id" sha256 printf 'sha256=%s\nbytes=4\n' "$(sha256_of "$payload")" \
    || fail "a sha256 read-back carrying the retained digest must verify"
  fm_outbound_readback "$state" "$id" sha256 printf 'nothing\n'
  [ "$?" -eq 2 ] || fail "a sha256 read-back without digest evidence is unavailable"
  fm_outbound_readback "$state" "$id" sha256 printf 'sha256=%s\nbytes=9\n' "$(sha256_of "$payload")"
  [ "$?" -eq 1 ] || fail "a sha256 read-back with a differing length is a mismatch"

  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=fleet correlation=c3b)
  fm_outbound_readback "$state" "$id" custom sh -c 'exit 1'
  [ "$?" -eq 1 ] || fail "a custom fetch that exits 1 is a mismatch"
  [ "$(fm_outbound_get "$state" "$id" readback)" = mismatch ] || fail "the custom mismatch is recorded"
  fm_outbound_readback "$state" "$id" custom sh -c 'exit 7'
  [ "$?" -eq 2 ] || fail "a custom fetch that exits otherwise is unavailable"
  fm_outbound_readback "$state" "$id" custom sh -c 'exit 0' || fail "a custom fetch that exits 0 verifies"

  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c4)
  fm_outbound_readback "$state" "$id" unavailable "no canonical fetch"
  [ "$(fm_outbound_get "$state" "$id" readback)" = unavailable ] || fail "a declared unavailable read-back is recorded"
  [ "$(fm_outbound_classify "$state" "$id" http 200)" = accepted ] || fail "HTTP 2xx classifies accepted"
  [ "$(fm_outbound_get "$state" "$id" outcome)" = accepted ] || fail "accepted without a read-back stays accepted, not delivered"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c5)
  [ "$(fm_outbound_classify "$state" "$id" http 500)" = transient ] || fail "HTTP 5xx classifies transient"
  [ "$(fm_outbound_get "$state" "$id" outcome)" = retryable ] || fail "a transient failure is retryable"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c6)
  [ "$(fm_outbound_classify "$state" "$id" http 401)" = rejected-auth ] || fail "HTTP 401 classifies rejected-auth"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c7)
  [ "$(fm_outbound_classify "$state" "$id" http 409)" = conflict ] || fail "HTTP 409 classifies conflict"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=c8)
  [ "$(fm_outbound_classify "$state" "$id" http '')" = transport-lost ] || fail "no HTTP status classifies transport-lost"
  [ "$(fm_outbound_get "$state" "$id" outcome)" = unknown ] || fail "a lost transport is unknown, never delivered"
  id=$(fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=fleet correlation=c9)
  [ "$(fm_outbound_classify "$state" "$id" exit 255)" = transport-lost ] || fail "exit 255 classifies transport-lost"
  pass "readback records verified, mismatch, and unavailable verdicts and classify derives outcomes from returned evidence only"
}

test_rejection_blocks_automatic_retry_until_acknowledged() {
  local state payload first second rc
  state="$TMP_ROOT/lib-reject/state"; mkdir -p "$state"
  payload="$TMP_ROOT/lib-reject/payload"; printf 'body' > "$payload"
  first=$(fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-1)
  [ "$(fm_outbound_classify "$state" "$first" http 422)" = rejected ] || fail "HTTP 422 classifies rejected"
  [ "$(fm_outbound_get "$state" "$first" outcome)" = undelivered ] || fail "a rejection is recorded undelivered"
  rc=0
  fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-1 >/dev/null 2>"$TMP_ROOT/lib-reject/err" || rc=$?
  [ "$rc" -eq 3 ] || fail "a second write to a rejected destination and correlation must be refused with exit 3 (got $rc)"
  assert_grep "undelivered=$first" "$TMP_ROOT/lib-reject/err" "the refusal must name the undelivered record"
  [ "$(find "$state/outbound-writes" -name '*.record' | wc -l | tr -d ' ')" = 1 ] || fail "a refused retry must leave exactly one undelivered record"
  second=$(fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-2) \
    || fail "a different correlation to the same destination is a new write"
  [ -n "$second" ] || fail "the new write must get an id"
  second=$(FM_OUTBOUND_WRITE_ACK="$first" fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-1) \
    || fail "an explicit acknowledgement of the undelivered record must allow a deliberate re-send"
  [ -n "$second" ] || fail "the acknowledged re-send must get an id"
  first=$(fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-3)
  fm_outbound_classify "$state" "$first" http 503 >/dev/null
  fm_outbound_prepare "$state" "$payload" writer=t destination=relay account=a authority=au disclosure=public correlation=req-3 >/dev/null \
    || fail "a transient failure must never block a retry"
  pass "a provider rejection leaves one undelivered record that blocks automatic retry until explicitly acknowledged"
}

test_prune_is_bounded_and_rm_guard_refuses_unsafe_paths() {
  local state payload old fresh dir
  state="$TMP_ROOT/lib-prune/state"; mkdir -p "$state"
  payload="$TMP_ROOT/lib-prune/payload"; printf 'body' > "$payload"
  old=$(FM_OUTBOUND_WRITE_NOW=1000 fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=old)
  dir=$(fm_outbound_dir "$state")
  printf 'keep\n' > "$dir/unrelated.txt"
  fresh=$(FM_OUTBOUND_WRITE_NOW=$((1000 + 604800 + 1)) fm_outbound_prepare "$state" "$payload" writer=t destination=d account=a authority=au disclosure=public correlation=new)
  assert_absent "$dir/$old.record" "a record past the seven-day horizon is pruned on the next prepare"
  assert_absent "$dir/$old.payload" "the pruned record's payload goes with it"
  assert_present "$dir/$fresh.record" "a fresh record survives the prune"
  assert_present "$dir/unrelated.txt" "prune removes only ledger artifacts it derived from a record id"
  fm_outbound_remove_artifacts "" "$fresh" && fail "the rm guard must refuse an empty directory"
  fm_outbound_remove_artifacts "$dir" "" && fail "the rm guard must refuse an empty id"
  fm_outbound_remove_artifacts "$TMP_ROOT/lib-prune" "$fresh" && fail "the rm guard must refuse a directory that is not an outbound-writes ledger"
  fm_outbound_remove_artifacts "$dir" "../escape" && fail "the rm guard must refuse an id with a path separator"
  assert_present "$dir/$fresh.record" "a refused rm must remove nothing"
  pass "the ledger is pruned on the seven-day horizon and its rm guard refuses empty or unexpected paths"
}

test_prune_leaves_an_in_progress_record_untouched() {
  local state dir
  state="$TMP_ROOT/lib-prune-inflight/state"
  dir=$(fm_outbound_dir_prepare "$state") || fail "the ledger directory must be creatable"
  printf 'schema=1\nid=1000-abc\noutcome=prepared\n' > "$dir/1000-abc.record"
  printf 'body' > "$dir/1000-abc.payload"
  printf 'schema=1\nid=1000-def\nprepared_epoch=soon\noutcome=prepared\n' > "$dir/1000-def.record"
  printf 'body' > "$dir/1000-def.payload"
  FM_OUTBOUND_WRITE_NOW=$((1000 + 604800 * 10)) fm_outbound_prune "$state" || fail "prune must succeed with in-progress records present"
  assert_present "$dir/1000-abc.record" "a record with no prepared_epoch is in progress and never pruned"
  assert_present "$dir/1000-abc.payload" "the in-progress record's payload stays with it"
  assert_present "$dir/1000-def.record" "a record with an unparseable prepared_epoch is never pruned"
  assert_present "$dir/1000-def.payload" "the unparseable record's payload stays with it"
  pass "prune treats a record without a parseable prepared_epoch as in progress and leaves it alone"
}

# --- fm-x-dismiss: body by file, never by argument ------------------------------

test_dismiss_conveys_body_by_file_and_retains_it() {
  local home fakebin log out rc rec
  home="$TMP_ROOT/dismiss-file"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"; : > "$log"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-dismiss.sh" req-d 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "dismiss success exit"
  [ "$out" = req-d ] || fail "dismiss must still echo only the request_id (got: $out)"
  assert_grep 'data={"request_id":"req-d"}' "$log" "the relay must still receive exactly {request_id}"
  assert_no_grep 'arg={"request_id"' "$log" "the dismiss body must not travel as a curl argument"
  assert_grep 'arg=--data-binary' "$log" "the dismiss body must travel as a file"
  rec=$(find "$home/state/outbound-writes" -name '*.record' | head -1)
  [ -n "$rec" ] || fail "a live dismiss must leave a ledger record"
  [ "$(grep '^writer=' "$rec" | cut -d= -f2)" = fm-x-dismiss ] || fail "the record names its writer"
  [ "$(grep '^sha256=' "$rec" | cut -d= -f2)" = "$(sha256_of "$log.body")" ] \
    || fail "the record's sha256 must be the digest of the exact POSTed bytes"
  [ "$(grep '^outcome=' "$rec" | cut -d= -f2)" = accepted ] || fail "a 2xx dismiss without a canonical fetch is accepted, not delivered"
  [ "$(grep '^readback=' "$rec" | cut -d= -f2)" = unavailable ] || fail "the relay's missing read-back is recorded as unavailable"
  assert_no_grep 'tok-d' "$rec" "the record must never carry the pairing token"
  pass "fm-x-dismiss conveys its body by file, retains the exact bytes and digest, and never stores the token"
}

# --- fm-x-reply: a relay rejection is undelivered and not retried ----------------

test_reply_rejection_is_undelivered_and_not_reposted() {
  local home fakebin log out rc rec
  home="$TMP_ROOT/reply-422"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"; : > "$log"
  printf 'FMX_PAIRING_TOKEN=tok-r\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    FAKE_ANSWER_CODE=422 FAKE_ANSWER_BODY='{"error":"content_rejected"}' \
    "$ROOT/bin/fm-x-reply.sh" req-r "a reply the relay refuses" 2>"$home/err"); rc=$?
  expect_code 10 "$rc" "a relay 4xx rejection exits 10"
  [ -z "$out" ] || fail "a rejected reply must not echo the request_id (got: $out)"
  assert_grep 'undelivered' "$home/err" "the rejection must be reported as undelivered"
  rec=$(find "$home/state/outbound-writes" -name '*.record' | head -1)
  [ -n "$rec" ] || fail "the rejected reply must leave a ledger record"
  [ "$(grep '^outcome=' "$rec" | cut -d= -f2)" = undelivered ] || fail "the record must be undelivered"
  [ "$(grep '^class=' "$rec" | cut -d= -f2)" = rejected ] || fail "the record must classify the rejection"
  [ "$(sha256_of "$log.body")" = "$(grep '^sha256=' "$rec" | cut -d= -f2)" ] \
    || fail "the retained digest must be the digest of the bytes the relay received"
  [ "$(LC_ALL=C wc -c < "$log.body" | tr -d ' ')" = "$(grep '^bytes=' "$rec" | cut -d= -f2)" ] \
    || fail "the retained length must be the length of the bytes the relay received"
  [ "$(posts_to "$log" answer)" = 1 ] || fail "one post must have reached the relay"
  # The same request is not posted again, even with different text.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-reply.sh" req-r "a reworded retry" 2>"$home/err2"); rc=$?
  expect_code 10 "$rc" "a re-post to a rejected request is refused"
  assert_grep 'not retried automatically' "$home/err2" "the refusal must say the post is not retried"
  [ "$(posts_to "$log" answer)" = 1 ] || fail "the refused re-post must not reach the relay"
  [ "$(find "$home/state/outbound-writes" -name '*.record' | wc -l | tr -d ' ')" = 1 ] || fail "exactly one undelivered record remains"
  # A transient failure keeps the existing retryable behavior.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    FAKE_ANSWER_CODE=503 "$ROOT/bin/fm-x-reply.sh" req-t "transient" 2>"$home/err3"); rc=$?
  expect_code 1 "$rc" "a relay 5xx stays the generic retryable failure"
  assert_grep 'HTTP 503' "$home/err3" "a 5xx still reports the failing status"
  pass "fm-x-reply records a relay rejection as one undelivered record and refuses to re-post that request"
}

test_reply_receipt_carries_ledger_identity() {
  local home fakebin log rc receipt rec
  home="$TMP_ROOT/reply-receipt"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"; : > "$log"
  printf 'FMX_PAIRING_TOKEN=tok-r\n' > "$home/.env"
  receipt="$home/receipt.json"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-reply.sh" req-ok --receipt-file "$receipt" "fine" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a live post succeeds"
  rec=$(jq -r '.ledger' "$receipt")
  [ -n "$rec" ] && [ "$rec" != null ] || fail "the receipt must name the ledger record"
  [ "$(jq -r '.payload_sha256' "$receipt")" = "$(grep '^sha256=' "$home/state/outbound-writes/$rec.record" | cut -d= -f2)" ] \
    || fail "the receipt's payload digest must match the ledger"
  pass "a live reply's receipt carries the ledger id and the exact payload digest"
}

# --- fm-x-followup: no retry after rejection ------------------------------------

test_followup_rejection_clears_link_and_never_reposts() {
  local home fakebin log out rc meta
  home="$TMP_ROOT/fu-422"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"; : > "$log"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  meta="$home/state/task-f.meta"
  fm_write_meta "$meta" "window=w" "x_request=req-f" "x_request_ts=1700000000" "x_followups=0" \
    "x_platform=x" "x_reply_max_chars=280"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=422 \
    "$ROOT/bin/fm-x-followup.sh" task-f - <<<"rejected follow-up" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected follow-up must not exit 0"
  assert_grep 'not retried' "$home/err" "the rejection must say it is not retried"
  assert_no_grep 'x_request=' "$meta" "a rejected follow-up must clear the link so no later pass retries it"
  [ "$(posts_to "$log" followup)" = 1 ] || fail "exactly one post must have reached the relay"
  # The next milestone pass finds nothing due and posts nothing.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_NOW_OVERRIDE=1700003700 \
    "$ROOT/bin/fm-x-followup.sh" --check task-f 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "no follow-up may be due after a rejection (rc=$rc out=$out)"
  [ "$(posts_to "$log" followup)" = 1 ] || fail "a later pass must not repost the rejected follow-up"
  pass "fm-x-followup clears the link after a relay rejection and a later pass never reposts it"
}

# --- fm-send remote steer: delivered only on a verified read-back ----------------

make_send_stubs() {  # <dir> -> echoes fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  fm_fake_exit0 "$fb" tmux sleep
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
while [ "$#" -gt 0 ]; do case "$1" in --) shift; break ;; *) shift ;; esac; done
digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }
argv_b64=${6:-}
message=$(perl -MMIME::Base64=decode_base64 -e '$d=decode_base64($ARGV[0]); @a=split(/\0/, $d, -1); print $a[3] if $a[0] eq "fm-remote-secondmate-control.sh" && $a[1] eq "send"' "$argv_b64")
case "${FM_FAKE_EVIDENCE:-none}" in
  none) ;;
  right)
    printf 'record=fixture\nsha256=%s\nbytes=%s\n' "$(printf '%s' "$message" | digest)" \
      "$(printf '%s' "$message" | LC_ALL=C wc -c | tr -d ' ')" ;;
  wrong)
    printf 'record=fixture\nsha256=%s\nbytes=%s\n' "$(printf '%s' "$message tampered" | digest)" \
      "$(printf '%s' "$message" | LC_ALL=C wc -c | tr -d ' ')" ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

make_send_home() {  # <name> -> echoes parent home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/rsm.meta" "window=fm-remote:p1" "endpoint_task_id=rsm" "harness=claude" \
    "kind=secondmate" "mode=secondmate" "yolo=off" "remote_host=remote-mac" "remote_root=/remote/root" \
    "remote_backend=herdr" "remote_herdr_session=fm-remote" "remote_target=fm-remote:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: $home/rhome; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

pending_record() {  # <home>
  find "$1/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1
}

run_send() {  # <fakebin> <home> <evidence-mode> <args...>
  local fb=$1 home=$2 mode=$3
  shift 3
  env PATH="$fb:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$home/ssh.log" FM_FAKE_EVIDENCE="$mode" \
    "$SEND" "$@"
}

test_send_remote_without_readback_evidence_is_unconfirmed() {
  local dir fb home rc pend rec
  dir="$TMP_ROOT/send-noevidence"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); home=$(make_send_home send-noevidence-home)
  rc=0
  run_send "$fb" "$home" none rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a remote leg that returns no read-back evidence must not be called delivered"
  assert_grep 'no read-back digest' "$dir/err" "the unconfirmed steer must name the missing read-back"
  assert_grep 'FM_PENDING_REPLY_EXISTING_CORR=' "$dir/err" "the unconfirmed steer must print the correlation-reusing resend"
  pend=$(pending_record "$home")
  [ -n "$pend" ] || fail "the expectation must be preserved for the record that may have landed"
  [ "$(grep '^phase=' "$pend" | tail -1 | cut -d= -f2-)" = delivery_unknown ] \
    || fail "delivery must be recorded unknown, not delivered: $(cat "$pend")"
  [ -z "$(grep '^delivered_epoch=' "$pend" | cut -d= -f2-)" ] || fail "delivery must not be stamped without a read-back"
  rec=$(find "$home/state/outbound-writes" -name '*.record' | head -1)
  [ -n "$rec" ] || fail "the steer must leave a ledger record"
  [ "$(grep '^readback=' "$rec" | cut -d= -f2)" = unavailable ] || fail "the missing evidence is recorded as unavailable"
  [ "$(grep '^conveyance=' "$rec" | cut -d= -f2)" = argv:7 ] || fail "the steer must declare its opaque argv conveyance"
  [ "$(grep '^outcome=' "$rec" | cut -d= -f2)" != delivered ] || fail "the record must not claim delivered"
  pass "fm-send never calls a remote steer delivered without read-back evidence"
}

test_send_remote_readback_mismatch_is_undelivered() {
  local dir fb home rc rec
  dir="$TMP_ROOT/send-mismatch"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); home=$(make_send_home send-mismatch-home)
  rc=0
  run_send "$fb" "$home" wrong rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a read-back digest mismatch must not be called delivered"
  assert_grep 'UNDELIVERED' "$dir/err" "a mismatch must be reported undelivered"
  assert_grep 'different digest' "$dir/err" "the report must name the digest mismatch"
  [ -z "$(pending_record "$home")" ] || fail "a known-undelivered marked steer discards its fresh expectation"
  rec=$(find "$home/state/outbound-writes" -name '*.record' | head -1)
  [ -n "$rec" ] || fail "the steer must leave a ledger record"
  [ "$(grep '^readback=' "$rec" | cut -d= -f2)" = mismatch ] || fail "the mismatch verdict is recorded"
  [ "$(grep '^outcome=' "$rec" | cut -d= -f2)" = undelivered ] || fail "the outcome is undelivered with the retained digest"
  [ "$(grep -c . "$home/ssh.log")" = 1 ] || fail "a mismatch must not be retried through the transport"
  pass "fm-send reports a read-back mismatch as undelivered with the retained digest and does not retry"
}

test_send_remote_verified_readback_is_delivered() {
  local dir fb home rc pend rec
  dir="$TMP_ROOT/send-verified"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); home=$(make_send_home send-verified-home)
  rc=0
  run_send "$fb" "$home" right rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  expect_code 0 "$rc" "a verified read-back delivers: $(cat "$dir/err")"
  pend=$(pending_record "$home")
  [ -n "$pend" ] && [ -n "$(grep '^delivered_epoch=' "$pend" | cut -d= -f2-)" ] || fail "a verified steer marks its expectation delivered"
  rec=$(find "$home/state/outbound-writes" -name '*.record' | head -1)
  [ "$(grep '^readback=' "$rec" | cut -d= -f2)" = verified ] && [ "$(grep '^outcome=' "$rec" | cut -d= -f2)" = delivered ] \
    || fail "a verified steer's record is delivered: $(cat "$rec")"
  pass "fm-send calls a remote steer delivered only once the remote read-back digest matches the retained bytes"
}

test_prepare_refuses_missing_fields_and_retains_exact_bytes
test_send_refuses_message_bytes_in_argv
test_readback_and_classify_verdicts
test_rejection_blocks_automatic_retry_until_acknowledged
test_prune_is_bounded_and_rm_guard_refuses_unsafe_paths
test_prune_leaves_an_in_progress_record_untouched
test_dismiss_conveys_body_by_file_and_retains_it
test_reply_rejection_is_undelivered_and_not_reposted
test_reply_receipt_carries_ledger_identity
test_followup_rejection_clears_link_and_never_reposts
test_send_remote_without_readback_evidence_is_unconfirmed
test_send_remote_readback_mismatch_is_undelivered
test_send_remote_verified_readback_is_delivered
echo "all fm-outbound-write tests passed"
