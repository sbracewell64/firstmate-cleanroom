# shellcheck shell=bash
# fm-programme-presentation-lib.sh - the quiet-presentation contract for the
# typed programme continuation: present a material change ONCE, stay quiet on
# unchanged state, and acknowledge only the identity that was actually
# presented. Sourced by bin/fm-wake-drain.sh (presenter and acknowledger),
# bin/fm-session-start.sh, bin/fm-fleet-snapshot.sh, and
# bin/fm-supervise-daemon.sh (readers).
#
# WHY THIS EXISTS. Callers that re-present the programme's typed result on
# every poll produced the repeated idle loop the handoff-liveness
# investigation traced: unchanged state re-woke a model and re-emitted a recap.
# The resolver (bin/fm-continuation-resolve.sh) now publishes a clock-free
# `material_identity` over {commission/action/generation, classification,
# authority, reason, accountable owner, evidence and hold identities}; this
# library is the ONE owner of how that identity is compared with what was
# already presented, so every caller keys quiet handling on material state and
# never on a clock, a poll counter, or its own memory.
#
# DURABLE RECORDS under $STATE (bin/fm-wake-lib.sh's STATE), main actor only:
#   .programme-presented          the last identity whose presentation was
#                                 acknowledged: one JSON object
#                                 {schema:"fm-programme-presented/v1",
#                                  material_identity, summary, presented_at}
#   .programme-presented.pending  the identity the drain presented in a turn
#                                 whose acknowledgement comes later through
#                                 `fm-wake-drain.sh --ack-through`; same shape
# Neither record is authority, state, or a store of the result: they hold an
# identity and a one-line summary only, and deleting either merely re-presents
# the current state once.
#
# CONTRACT (fm_programme_present <state> <mode>):
#   1. Run the resolver's `render`; exit 3 (no programme) prints no presentation
#      on stdout and returns 3, while captured diagnostics remain visible on
#      stderr; a resolver failure is itself material state, keyed by a
#      digest of its exit code and the diagnostic it wrote, so a broken pin
#      surfaces once and then stays quiet until it changes. When NO diagnostic
#      was captured - whether because it could not be staged or because the
#      resolver wrote none, which are the same thing here - that digest would be
#      identical for every failure of that exit code, so this REFUSES TO DEDUPE
#      and presents each occurrence instead. When the distinguishing input is
#      unavailable the answer is to refuse to identify, never to fall back to a
#      value everything shares: presenting the same failure twice is harmless,
#      suppressing a genuinely different one is not. Do not narrow that guard to
#      the unstageable case alone; it would re-create the collapse.
#   2. Compare the identity with the acknowledged record AND the pending
#      record: equal to either is unchanged -> print nothing, return 0. When
#      it equals the pending record and the mode is `commit` (a no-ack turn
#      has observed the same state again), the pending record is promoted to
#      the acknowledged record exactly as fm_programme_ack_pending would, so
#      readers converge on "unchanged" instead of labelling the state
#      pending-ack forever; the identity promoted is still only the one that
#      was presented, never a current identity that differs from it.
#   3. Otherwise print the PROGRAMME CONTINUATION section once and record the
#      identity: mode `pending` writes .programme-presented.pending for a
#      later acknowledgement; mode `commit` (a turn that prints no
#      WAKE_ACK_REQUIRED) acknowledges immediately.
#   4. fm_programme_ack_pending <state> promotes the pending record to the
#      acknowledged record WITHOUT re-resolving: the identity acknowledged is
#      exactly the one presented, so state that changed between presentation
#      and acknowledgement is not swallowed and surfaces at the next drain.
# The branch supervision actor never presents or acknowledges programme
# state; docs/programme-continuation.md owns the caller census.

FM_PROGRAMME_PRESENTATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_PROGRAMME_PRESENTATION_DIR/fm-timeout-lib.sh"
fi

fm_programme_presented_path() {  # <state>
  printf '%s/.programme-presented' "$1"
}

fm_programme_pending_path() {  # <state>
  printf '%s/.programme-presented.pending' "$1"
}

_fm_programme_record_identity() {  # <file>
  [ -f "$1" ] || return 0
  jq -r 'if (.material_identity | type) == "string" then .material_identity else "" end' "$1" 2>/dev/null || true
}

fm_programme_presented_identity() {  # <state>
  _fm_programme_record_identity "$(fm_programme_presented_path "$1")"
}

fm_programme_pending_identity() {  # <state>
  _fm_programme_record_identity "$(fm_programme_pending_path "$1")"
}

# The full material identity carried by a `render` text (its last line), or
# nothing when the text carries none.
fm_programme_identity_from_render() {  # <render-text>
  printf '%s\n' "$1" | sed -n 's/^Material identity \([0-9a-f]\{64\}\) .*/\1/p' | head -1
}

_fm_programme_sha256() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

_fm_programme_write_record() {  # <file> <identity> <summary>
  local tmp
  tmp=$(mktemp "$1.tmp.XXXXXX") || return 1
  if ! jq -n --arg id "$2" --arg summary "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema:"fm-programme-presented/v1", material_identity:$id, summary:$summary, presented_at:$at}' > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Presentation state for a given identity, as one token a reader can print:
#   unchanged      acknowledged as presented
#   pending-ack    presented, acknowledgement outstanding
#   changed        not presented yet (or changed since)
fm_programme_presentation_state() {  # <state> <identity>
  local presented pending
  presented=$(fm_programme_presented_identity "$1")
  pending=$(fm_programme_pending_identity "$1")
  if [ -n "$2" ] && [ "$2" = "$presented" ]; then printf 'unchanged'
  elif [ -n "$2" ] && [ "$2" = "$pending" ]; then printf 'pending-ack'
  else printf 'changed'; fi
}

_fm_programme_prefix_diagnostic() {
  while IFS= read -r line || [ -n "$line" ]; do
    printf 'resolver diagnostic: %s\n' "$line"
  done
}

fm_programme_render_non_actionable() {
  while IFS= read -r line || [ -n "$line" ]; do
    printf 'resolver data: %s\n' "$line"
  done
}

fm_programme_resolver_capture() {  # <resolver> <operation> <temp-prefix> [args...]
  local resolver=$1 operation=$2 prefix=$3 errfile out rc=0
  shift 3
  FM_PROGRAMME_RESOLVER_OUT=''
  FM_PROGRAMME_RESOLVER_DIAG=''
  FM_PROGRAMME_RESOLVER_RC=125
  errfile=$(mktemp "${TMPDIR:-/tmp}/$prefix.XXXXXX" 2>/dev/null) \
    || errfile=$(mktemp "/tmp/$prefix.XXXXXX" 2>/dev/null) \
    || { FM_PROGRAMME_RESOLVER_DIAG='resolver diagnostics: staging allocation failed'; return 125; }
  if [ "${FM_PROGRAMME_RESOLVER_BOUNDED:-0}" = 1 ]; then
    out=$(fm_run_timed 1 "$resolver" "$operation" "$@" 2>"$errfile") || rc=$?
  else
    out=$("$resolver" "$operation" "$@" 2>"$errfile") || rc=$?
  fi
  FM_PROGRAMME_RESOLVER_OUT=$out
  if ! FM_PROGRAMME_RESOLVER_DIAG=$(cat "$errfile"); then
    FM_PROGRAMME_RESOLVER_DIAG='resolver diagnostics: capture file could not be read'
    if ! rm -f -- "$errfile"; then
      FM_PROGRAMME_RESOLVER_DIAG='resolver diagnostics: capture file could not be read or removed'
    fi
    FM_PROGRAMME_RESOLVER_RC=125
    return 125
  fi
  if ! rm -f -- "$errfile"; then
    FM_PROGRAMME_RESOLVER_DIAG='resolver diagnostics: capture file cleanup failed'
    FM_PROGRAMME_RESOLVER_RC=125
    return 125
  fi
  FM_PROGRAMME_RESOLVER_RC=$rc
  return 0
}

fm_programme_relay_diagnostic() {  # <diagnostic>
  [ -z "$1" ] || _fm_programme_prefix_diagnostic <<< "$1"
}

_fm_programme_present_locked() {
  local state=$1 mode=$2 identity=$3 summary=$4 out=$5 dedupe=$6 verdict
  if [ "$dedupe" -eq 1 ]; then
    verdict=$(fm_programme_presentation_state "$state" "$identity")
    case "$verdict" in
      unchanged) return 0 ;;
      pending-ack)
        [ "$mode" = commit ] || return 0
        _fm_programme_ack_pending_locked "$state"
        return $?
        ;;
    esac
  fi
  printf 'PROGRAMME CONTINUATION (material state changed since last presented; typed owner bin/fm-continuation-resolve.sh):\n'
  printf '%s\n' "$out" | fm_programme_render_non_actionable
  if [ "$mode" = pending ]; then
    printf 'PROGRAMME CONTINUATION: presented identity %s; it is acknowledged by the WAKE_ACK_REQUIRED command below, and state that changes before then surfaces again.\n' "${identity:0:12}"
    _fm_programme_write_record "$(fm_programme_pending_path "$state")" "$identity" "$summary" || return 1
  else
    printf 'PROGRAMME CONTINUATION: presented identity %s (acknowledged with this presentation; nothing is pending).\n' "${identity:0:12}"
    _fm_programme_write_record "$(fm_programme_presented_path "$state")" "$identity" "$summary" || return 1
    rm -f -- "$(fm_programme_pending_path "$state")"
  fi
}

# Present the programme continuation once per material change. See CONTRACT.
fm_programme_present() {  # <state> <mode: pending|commit>
  local state=$1 mode=$2 resolver out rc=0 identity summary diag='' diag_note='' reason='' diagnostic_reason='' dedupe=1 captured=1 lock present_rc revalidate_capture revalidate_rc revalidate_diag revalidate_out revalidate_identity revalidate_tmpdir saved_tmpdir had_tmpdir=0
  resolver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-continuation-resolve.sh"
  case "$mode" in pending|commit) ;; *) return 2 ;; esac
  if fm_programme_resolver_capture "$resolver" render fm-programme-present; then
    out=$FM_PROGRAMME_RESOLVER_OUT
    diag=$FM_PROGRAMME_RESOLVER_DIAG
    rc=$FM_PROGRAMME_RESOLVER_RC
  else
    out=''
    rc=$FM_PROGRAMME_RESOLVER_RC
    diag=${FM_PROGRAMME_RESOLVER_DIAG:-'resolver diagnostics: staging was unavailable'}
    captured=0
  fi
  [ -n "$diag" ] || captured=0
  fm_programme_relay_diagnostic "$diag" >&2
  case "$rc" in
    0)
      identity=$(fm_programme_identity_from_render "$out")
      [ -n "$identity" ] || { identity=$(_fm_programme_sha256 "render-without-identity:$out"); }
      summary=$(printf '%s\n' "$out" | sed -n '1,2p' | paste -sd ' ' -)
      ;;
    3) return 3 ;;
    *)
      reason=${diag:-$diag_note}
      identity=$(_fm_programme_sha256 "resolver-failed:$rc:$reason")
      summary="resolver failed (exit $rc)"
      if [ -n "$reason" ]; then
        diagnostic_reason=$(_fm_programme_prefix_diagnostic <<< "$reason")
      fi
      out="resolver failed (exit $rc); continuation authority is unproven, not captain-gated:
$diagnostic_reason"
      # With no captured diagnostic the identity cannot tell one failure of this
      # exit code from another, so this REFUSES TO DEDUPE rather than falling back
      # to a value every such failure shares: presenting the same failure twice is
      # harmless, suppressing a genuinely new one is not.
      [ "$captured" -eq 1 ] || dedupe=0
      ;;
  esac
  lock="$state/.status-presentation-lock"
  fm_lock_acquire_wait "$lock" || return 1
  present_rc=0
  if [ "$rc" -eq 0 ]; then
    revalidate_tmpdir=${TMPDIR:-/tmp}
    [ -d "$revalidate_tmpdir" ] && [ -w "$revalidate_tmpdir" ] || revalidate_tmpdir=/tmp
    if [ "${TMPDIR+x}" = x ]; then had_tmpdir=1; saved_tmpdir=$TMPDIR; fi
    TMPDIR=$revalidate_tmpdir
    FM_PROGRAMME_RESOLVER_BOUNDED=1
    fm_programme_resolver_capture "$resolver" render fm-programme-present
    revalidate_capture=$?
    unset FM_PROGRAMME_RESOLVER_BOUNDED
    if [ "$had_tmpdir" -eq 1 ]; then TMPDIR=$saved_tmpdir; else unset TMPDIR; fi
    revalidate_rc=$FM_PROGRAMME_RESOLVER_RC
    revalidate_diag=$FM_PROGRAMME_RESOLVER_DIAG
    fm_programme_relay_diagnostic "$revalidate_diag" >&2
    if [ "$revalidate_capture" -ne 0 ] || [ "$revalidate_rc" -ne 0 ]; then
      present_rc=1
    else
      revalidate_out=$FM_PROGRAMME_RESOLVER_OUT
      revalidate_identity=$(fm_programme_identity_from_render "$revalidate_out")
      [ -n "$revalidate_identity" ] || revalidate_identity=$(_fm_programme_sha256 "render-without-identity:$revalidate_out")
      identity=$revalidate_identity
      out=$revalidate_out
      summary=$(printf '%s\n' "$out" | sed -n '1,2p' | paste -sd ' ' -)
    fi
  fi
  if [ "$present_rc" -eq 0 ]; then
    _fm_programme_present_locked "$state" "$mode" "$identity" "$summary" "$out" "$dedupe"
    present_rc=$?
  fi
  fm_lock_release "$lock" || [ "$present_rc" -ne 0 ] || present_rc=1
  return "$present_rc"
}

# Acknowledge exactly the identity the drain presented; never re-resolve here.
_fm_programme_ack_pending_locked() {  # <state>
  local pending
  pending=$(fm_programme_pending_path "$1")
  [ -f "$pending" ] || return 0
  [ -n "$(_fm_programme_record_identity "$pending")" ] || { rm -f -- "$pending"; return 0; }
  mv -f -- "$pending" "$(fm_programme_presented_path "$1")"
}

fm_programme_ack_pending() {  # <state>
  local state=$1 lock="$1/.status-presentation-lock" rc
  fm_lock_acquire_wait "$lock" || return 1
  _fm_programme_ack_pending_locked "$state"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}
