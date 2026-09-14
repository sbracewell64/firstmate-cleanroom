# shellcheck shell=bash
# fm-outbound-write-lib.sh - the one enforcement owner of the outbound-write
# discipline for every tracked writer that sends firstmate-authored bytes out of
# this home: the Relay reply, follow-up, and dismiss clients, the promised public
# reply, the remote backlog handoff, and the remote secondmate steer.
#
# The discipline it enforces, in the order a writer must run it:
#   1. prepare  - validate the structured destination/account/authority/
#                 disclosure/correlation fields, copy the EXACT outgoing payload
#                 bytes into a private ledger record with their length and
#                 sha256, and refuse to prepare a second write to a destination
#                 and correlation whose earlier attempt was rejected and recorded
#                 undelivered (a safety rejection never auto-retries).
#   2. send     - run the caller's transport with the body conveyed as a file,
#                 as stdin, or as one declared opaque argv element, and refuse a
#                 transport whose argv silently carries the message bytes.
#   3. readback - run the caller's canonical destination fetch and record the
#                 verdict (verified, mismatch, unavailable, failed) against the
#                 retained digest, modulo the mode the destination documents.
#   4. classify - derive the outcome ONLY from returned provider evidence: an
#                 HTTP status and body, or a transport exit status. A rejection
#                 becomes exactly one undelivered record; a read-back mismatch
#                 is undelivered, never delivered.
#
# Ledger layout, under <state>/outbound-writes (mode 0700, created lazily):
#   <id>.record    key=value fields listed in fm_outbound_prepare, mode 0600
#   <id>.payload   the exact bytes handed to the transport, mode 0600
#   <id>.response  provider response body captured by classify, mode 0600
#   <id>.readback  canonical read-back evidence captured by readback, mode 0600
# Records older than FM_OUTBOUND_WRITE_MAX_AGE_SECS (default and ceiling
# 604800, seven days, the same horizon as state/x-context) are pruned on every
# prepare, so the ledger stays bounded without a separate sweep.
#
# Exit statuses: 0 success, 1 ledger or record write failure, 2 usage or a
# missing required field, 3 refused because an undelivered rejection record
# already covers this destination and correlation (its id is printed on
# stderr; a deliberate operator re-send passes FM_OUTBOUND_WRITE_ACK=<id>).
# readback returns 0 verified, 1 mismatch, 2 unavailable, 3 failed.
# send returns the transport's own exit status, or 2 when it refuses the argv.
#
# Sourced, never executed. No side effects on source. set -u / set -e safe.

FM_OUTBOUND_WRITE_SCHEMA=fm-outbound-write.v1

fm_outbound_dir() {  # <state-dir>
  printf '%s/outbound-writes' "$1"
}

fm_outbound_sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

fm_outbound_now() {
  if [ -n "${FM_OUTBOUND_WRITE_NOW:-}" ]; then
    printf '%s' "$FM_OUTBOUND_WRITE_NOW"
  else
    date +%s
  fi
}

fm_outbound_max_age() {
  local max_age=${FM_OUTBOUND_WRITE_MAX_AGE_SECS:-604800}
  case "$max_age" in ''|*[!0-9]*) max_age=604800 ;; esac
  [ "${#max_age}" -le 18 ] || max_age=604800
  [ "$max_age" -le 604800 ] || max_age=604800
  printf '%s' "$max_age"
}

fm_outbound_id_valid() {  # <id>
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_outbound_record_path() {  # <state-dir> <id>
  printf '%s/%s.record' "$(fm_outbound_dir "$1")" "$2"
}

fm_outbound_payload_path() {  # <state-dir> <id>
  printf '%s/%s.payload' "$(fm_outbound_dir "$1")" "$2"
}

# Remove one write's ledger files, and nothing else: the directory must be a
# real outbound-writes directory and the id must have the ledger id shape, or
# nothing is removed. This is the only rm of ledger artifacts in the library.
fm_outbound_remove_artifacts() {  # <ledger-dir> <id>
  local dir=$1 id=$2
  [ -n "$dir" ] && [ -n "$id" ] || return 1
  case "$dir" in */outbound-writes) ;; *) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_outbound_id_valid "$id" || return 1
  rm -f -- "$dir/$id.record" "$dir/$id.payload" "$dir/$id.response" "$dir/$id.readback"
}

fm_outbound_dir_prepare() {  # <state-dir>
  local dir
  dir=$(fm_outbound_dir "$1")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
  fi
  chmod 700 "$dir" 2>/dev/null || return 1
  printf '%s' "$dir"
}

# Read one field. Empty output and exit 0 when the record or key is absent.
fm_outbound_get() {  # <state-dir> <id> <key>
  local rec line
  rec=$(fm_outbound_record_path "$1" "$2")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 0
  line=$(grep -E "^$3=" "$rec" 2>/dev/null | tail -n1) || return 0
  printf '%s' "${line#*=}"
}

# Replace one field (append when absent), preserving every other line. The
# record is rewritten in place from a staged copy rather than renamed over: it
# is private evidence, not authority, and a writer's own atomic state rename
# that follows a send must stay the first rename after the transport call.
fm_outbound_set() {  # <state-dir> <id> <key> <value>
  local rec tmp
  rec=$(fm_outbound_record_path "$1" "$2")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  case "$4" in *$'\n'*) return 1 ;; esac
  tmp=$(umask 077; mktemp "$rec.XXXXXX") || return 1
  case "$tmp" in "$rec".??????) ;; *) return 1 ;; esac
  if ! { grep -vE "^$3=" "$rec" || true; } > "$tmp" || ! printf '%s=%s\n' "$3" "$4" >> "$tmp" \
    || ! cat -- "$tmp" > "$rec"; then
    rm -f -- "$tmp"; return 1
  fi
  rm -f -- "$tmp"
}

# Drop records, payloads, and evidence files older than the retention horizon.
fm_outbound_prune() {  # <state-dir>
  local dir rec id prepared now max_age base
  dir=$(fm_outbound_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=$(fm_outbound_now)
  max_age=$(fm_outbound_max_age)
  for rec in "$dir"/*.record; do
    [ -f "$rec" ] || continue
    base=${rec##*/}
    id=${base%.record}
    prepared=$(grep -E '^prepared_epoch=' "$rec" 2>/dev/null | tail -n1)
    prepared=${prepared#*=}
    case "$prepared" in ''|*[!0-9]*) prepared=0 ;; esac
    if [ "$((now - prepared))" -gt "$max_age" ]; then
      fm_outbound_remove_artifacts "$dir" "$id" || return 1
    fi
  done
  return 0
}

# Print the id of an undelivered rejection record for <destination> and
# <correlation>, or nothing. Only a provider rejection blocks a later write;
# a transient, transport, or read-back failure never does.
fm_outbound_undelivered_for() {  # <state-dir> <destination> <correlation>
  local dir rec dest corr outcome class base
  dir=$(fm_outbound_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for rec in "$dir"/*.record; do
    [ -f "$rec" ] || continue
    dest=$(grep -E '^destination=' "$rec" | tail -n1); dest=${dest#*=}
    [ "$dest" = "$2" ] || continue
    corr=$(grep -E '^correlation=' "$rec" | tail -n1); corr=${corr#*=}
    [ "$corr" = "$3" ] || continue
    outcome=$(grep -E '^outcome=' "$rec" | tail -n1); outcome=${outcome#*=}
    [ "$outcome" = undelivered ] || continue
    class=$(grep -E '^class=' "$rec" | tail -n1); class=${class#*=}
    case "$class" in rejected|rejected-auth) ;; *) continue ;; esac
    base=${rec##*/}
    printf '%s' "${base%.record}"
    return 0
  done
  return 0
}

# fm_outbound_prepare <state-dir> <payload-file> key=value...
# Required keys: writer destination account authority disclosure correlation.
# disclosure is public, fleet, or private. Prints the new record id.
fm_outbound_prepare() {  # <state-dir> <payload-file> key=value...
  local state=$1 payload_src=$2 dir rec tmp slot id key val bytes sha now blocker
  local writer='' destination='' account='' authority='' disclosure='' correlation=''
  shift 2 || return 2
  [ -n "$state" ] || return 2
  [ -f "$payload_src" ] && [ ! -L "$payload_src" ] || { echo "fm-outbound-write: payload file is missing or unsafe: $payload_src" >&2; return 2; }
  for key in "$@"; do
    case "$key" in
      writer=*) writer=${key#*=} ;;
      destination=*) destination=${key#*=} ;;
      account=*) account=${key#*=} ;;
      authority=*) authority=${key#*=} ;;
      disclosure=*) disclosure=${key#*=} ;;
      correlation=*) correlation=${key#*=} ;;
      *) echo "fm-outbound-write: unknown prepare field: ${key%%=*}" >&2; return 2 ;;
    esac
  done
  for key in writer destination account authority disclosure correlation; do
    eval "val=\${$key}"
    [ -n "$val" ] || { echo "fm-outbound-write: refusing to prepare: missing required field $key" >&2; return 2; }
    case "$val" in *$'\n'*|*$'\r'*) echo "fm-outbound-write: refusing to prepare: field $key must be single-line" >&2; return 2 ;; esac
  done
  case "$disclosure" in
    public|fleet|private) ;;
    *) echo "fm-outbound-write: refusing to prepare: disclosure must be public, fleet, or private (got '$disclosure')" >&2; return 2 ;;
  esac
  dir=$(fm_outbound_dir_prepare "$state") || { echo "fm-outbound-write: cannot prepare the ledger directory under $state" >&2; return 1; }
  fm_outbound_prune "$state"
  blocker=$(fm_outbound_undelivered_for "$state" "$destination" "$correlation")
  if [ -n "$blocker" ] && [ "${FM_OUTBOUND_WRITE_ACK:-}" != "$blocker" ]; then
    echo "fm-outbound-write: refusing to prepare: an earlier write to $destination for $correlation was rejected and is recorded undelivered ($blocker); it is not retried automatically" >&2
    printf 'undelivered=%s\n' "$blocker" >&2
    return 3
  fi
  now=$(fm_outbound_now)
  slot=$(umask 077; mktemp "$dir/$now-XXXXXX") || return 1
  id=${slot##*/}
  fm_outbound_id_valid "$id" || return 1
  rec="$dir/$id.record"
  tmp="$dir/$id.payload"
  [ ! -e "$rec" ] && [ ! -e "$tmp" ] || return 1
  mv -- "$slot" "$rec" || return 1
  if ! (umask 077; cat -- "$payload_src" > "$tmp") || ! chmod 600 "$tmp" 2>/dev/null; then
    fm_outbound_remove_artifacts "$dir" "$id"; return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
  sha=$(fm_outbound_sha256_file "$tmp")
  case "$sha" in *[!0-9a-f]*|'') fm_outbound_remove_artifacts "$dir" "$id"; echo "fm-outbound-write: sha256 (shasum or sha256sum) is required" >&2; return 1 ;; esac
  [ "${#sha}" -eq 64 ] || { fm_outbound_remove_artifacts "$dir" "$id"; return 1; }
  if ! cat > "$rec" <<EOF
schema=$FM_OUTBOUND_WRITE_SCHEMA
id=$id
writer=$writer
destination=$destination
account=$account
authority=$authority
disclosure=$disclosure
correlation=$correlation
bytes=$bytes
sha256=$sha
prepared_epoch=$now
conveyance=
sent_epoch=
send_rc=
readback=pending
readback_note=
readback_sha256=
evidence=
class=
outcome=prepared
classified_epoch=
EOF
  then
    fm_outbound_remove_artifacts "$dir" "$id"; return 1
  fi
  chmod 600 "$rec" 2>/dev/null || { fm_outbound_remove_artifacts "$dir" "$id"; return 1; }
  printf '%s\n' "$id"
}

fm_outbound_arg_is_payload() {  # <payload-path> <arg>
  printf '%s' "$2" | cmp -s -- - "$1"
}

# fm_outbound_send <state-dir> <id> <conveyance> <cmd> [args...]
# conveyance: file        the command reads the payload path (exported as
#                         FM_OUTBOUND_PAYLOAD_FILE and usable in args)
#             stdin       the payload is piped to the command's stdin
#             argv:<n>    argv element <n> of <cmd args...> (1-based, counting
#                         <cmd> as 0) IS the payload and the transport is
#                         declared to carry argv opaquely
# file and stdin refuse when any argv element carries the payload bytes; argv:<n>
# refuses when the named element is not exactly the payload.
fm_outbound_send() {  # <state-dir> <id> <conveyance> <cmd> [args...]
  local state=$1 id=$2 conveyance=$3 payload rc=0 i n arg
  shift 3 || return 2
  fm_outbound_id_valid "$id" || return 2
  payload=$(fm_outbound_payload_path "$state" "$id")
  [ -f "$payload" ] && [ ! -L "$payload" ] || { echo "fm-outbound-write: no prepared payload for $id" >&2; return 2; }
  [ "$#" -ge 1 ] || return 2
  case "$conveyance" in
    file|stdin)
      i=0
      for arg in "$@"; do
        if [ "$i" -gt 0 ] && fm_outbound_arg_is_payload "$payload" "$arg"; then
          echo "fm-outbound-write: refusing to send $id: the transport argv carries the message bytes (argv[$i]); convey the body as a file or stdin" >&2
          return 2
        fi
        i=$((i + 1))
      done
      ;;
    argv:*)
      n=${conveyance#argv:}
      case "$n" in ''|*[!0-9]*|0) return 2 ;; esac
      [ "$n" -lt "$#" ] || { echo "fm-outbound-write: refusing to send $id: declared argv element $n is absent" >&2; return 2; }
      i=0
      for arg in "$@"; do
        if [ "$i" -eq "$n" ]; then
          fm_outbound_arg_is_payload "$payload" "$arg" || {
            echo "fm-outbound-write: refusing to send $id: declared argv element $n is not the prepared payload" >&2
            return 2
          }
        fi
        i=$((i + 1))
      done
      ;;
    *) echo "fm-outbound-write: unknown conveyance '$conveyance'" >&2; return 2 ;;
  esac
  fm_outbound_set "$state" "$id" conveyance "$conveyance" || return 1
  fm_outbound_set "$state" "$id" sent_epoch "$(fm_outbound_now)" || return 1
  fm_outbound_set "$state" "$id" outcome sent || return 1
  if [ "$conveyance" = stdin ]; then
    "$@" < "$payload" || rc=$?
  else
    FM_OUTBOUND_PAYLOAD_FILE=$payload "$@" || rc=$?
  fi
  # The bytes have left the machine: a ledger write failure here is reported,
  # never turned into a transport failure, because a caller that believed the
  # send failed would post the same payload again.
  fm_outbound_set "$state" "$id" send_rc "$rc" \
    || echo "fm-outbound-write: warning: $id was handed to the transport but its transport status could not be recorded" >&2
  return "$rc"
}

# fm_outbound_readback <state-dir> <id> <mode> [cmd...]
# mode: exact         the command's stdout must equal the payload bytes
#       sha256        the command's stdout carries sha256=<hex> and optionally
#                     bytes=<n> lines that must match the retained digest
#       custom        the command exits 0 verified, 1 mismatch, other unavailable
#       unavailable   no canonical fetch exists; [cmd...] is the one-line reason
fm_outbound_readback() {  # <state-dir> <id> <mode> [cmd...]
  local state=$1 id=$2 mode=$3 payload evidence rc=0 verdict=failed note='' got_sha got_bytes want_sha want_bytes
  shift 3 || return 3
  fm_outbound_id_valid "$id" || return 3
  payload=$(fm_outbound_payload_path "$state" "$id")
  [ -f "$payload" ] && [ ! -L "$payload" ] || return 3
  evidence="$(fm_outbound_dir "$state")/$id.readback"
  case "$mode" in
    unavailable)
      note=$*
      fm_outbound_set "$state" "$id" readback unavailable || return 3
      fm_outbound_set "$state" "$id" readback_note "$note" || return 3
      return 2
      ;;
    exact|sha256|custom) [ "$#" -ge 1 ] || return 3 ;;
    *) return 3 ;;
  esac
  (umask 077; "$@" > "$evidence") || rc=$?
  chmod 600 "$evidence" 2>/dev/null || true
  want_sha=$(fm_outbound_get "$state" "$id" sha256)
  want_bytes=$(fm_outbound_get "$state" "$id" bytes)
  case "$mode" in
    exact)
      if [ "$rc" -ne 0 ]; then verdict=unavailable; note="fetch exited $rc"
      elif cmp -s -- "$evidence" "$payload"; then verdict=verified; note="bytes equal"
      else verdict=mismatch; note="destination bytes differ from the retained payload"; fi
      ;;
    sha256)
      got_sha=$(grep -E '^sha256=' "$evidence" 2>/dev/null | tail -n1); got_sha=${got_sha#*=}
      got_bytes=$(grep -E '^bytes=' "$evidence" 2>/dev/null | tail -n1); got_bytes=${got_bytes#*=}
      if [ "$rc" -ne 0 ]; then verdict=unavailable; note="fetch exited $rc"
      elif [ -z "$got_sha" ]; then verdict=unavailable; note="destination returned no digest evidence"
      elif [ "$got_sha" != "$want_sha" ]; then verdict=mismatch; note="destination digest $got_sha differs from retained $want_sha"
      elif [ -n "$got_bytes" ] && [ "$got_bytes" != "$want_bytes" ]; then verdict=mismatch; note="destination length $got_bytes differs from retained $want_bytes"
      else verdict=verified; note="digest equal"; fi
      ;;
    custom)
      case "$rc" in
        0) verdict=verified; note="caller fetch verified" ;;
        1) verdict=mismatch; note="caller fetch reported a mismatch" ;;
        *) verdict=unavailable; note="caller fetch exited $rc" ;;
      esac
      ;;
  esac
  fm_outbound_set "$state" "$id" readback "$verdict" || return 3
  fm_outbound_set "$state" "$id" readback_note "$note" || return 3
  [ -z "${got_sha:-}" ] || fm_outbound_set "$state" "$id" readback_sha256 "$got_sha" || return 3
  case "$verdict" in verified) return 0 ;; mismatch) return 1 ;; unavailable) return 2 ;; *) return 3 ;; esac
}

# fm_outbound_classify <state-dir> <id> http <code> [body-file]
# fm_outbound_classify <state-dir> <id> exit <rc>
# Prints the class: accepted, rejected, rejected-auth, conflict, transient,
# transport-lost, or failed. Records class, evidence, outcome, and the response
# body when given. Never retries and never infers anything the evidence did not
# return: a generic 4xx is rejected on its status alone.
fm_outbound_classify() {  # <state-dir> <id> <kind> <value> [body-file]
  local state=$1 id=$2 kind=$3 value=$4 body=${5:-} class outcome evidence readback resp
  fm_outbound_id_valid "$id" || return 1
  case "$kind" in
    http)
      case "$value" in
        2[0-9][0-9]) class=accepted ;;
        401|403) class=rejected-auth ;;
        409) class=conflict ;;
        408|425|429|5[0-9][0-9]) class=transient ;;
        4[0-9][0-9]) class=rejected ;;
        ''|*[!0-9]*) class=transport-lost ;;
        *) class=rejected ;;
      esac
      evidence="http ${value:-none}"
      ;;
    exit)
      case "$value" in
        0) class=accepted ;;
        255|124) class=transport-lost ;;
        ''|*[!0-9]*) class=transport-lost ;;
        *) class=failed ;;
      esac
      evidence="exit ${value:-none}"
      ;;
    *) return 1 ;;
  esac
  if [ -n "$body" ] && [ -f "$body" ] && [ -s "$body" ]; then
    resp="$(fm_outbound_dir "$state")/$id.response"
    if (umask 077; head -c 4096 -- "$body" > "$resp") 2>/dev/null; then
      chmod 600 "$resp" 2>/dev/null || true
      evidence="$evidence body=$(fm_outbound_sha256_file "$resp")"
    fi
  fi
  readback=$(fm_outbound_get "$state" "$id" readback)
  case "$class" in
    accepted)
      case "$readback" in
        verified) outcome=delivered ;;
        mismatch) outcome=undelivered ;;
        *) outcome=accepted ;;
      esac
      ;;
    rejected|rejected-auth) outcome=undelivered ;;
    conflict) outcome=conflict ;;
    transient|failed) outcome=retryable ;;
    transport-lost) outcome=unknown ;;
  esac
  # Classification follows the transport, so a record write failure is a
  # warning: the class printed here is still the provider's evidence.
  if ! fm_outbound_set "$state" "$id" class "$class" \
    || ! fm_outbound_set "$state" "$id" evidence "$evidence" \
    || ! fm_outbound_set "$state" "$id" outcome "$outcome" \
    || ! fm_outbound_set "$state" "$id" classified_epoch "$(fm_outbound_now)"; then
    echo "fm-outbound-write: warning: could not record the $class outcome for $id" >&2
  fi
  printf '%s\n' "$class"
}
