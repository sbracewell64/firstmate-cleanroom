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
#   1. Run the resolver's `render`; exit 3 (no programme) prints nothing and
#      returns 3; a resolver failure is itself material state, keyed by a
#      digest of its exit code and message, so a broken pin surfaces once and
#      then stays quiet until it changes.
#   2. Compare the identity with the acknowledged record AND the pending
#      record: equal to either is unchanged -> print nothing, return 0.
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

# Present the programme continuation once per material change. See CONTRACT.
fm_programme_present() {  # <state> <mode: pending|commit>
  local state=$1 mode=$2 resolver out rc=0 identity summary verdict
  resolver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-continuation-resolve.sh"
  case "$mode" in pending|commit) ;; *) return 2 ;; esac
  out=$("$resolver" render 2>&1) || rc=$?
  case "$rc" in
    0)
      identity=$(fm_programme_identity_from_render "$out")
      [ -n "$identity" ] || { identity=$(_fm_programme_sha256 "render-without-identity:$out"); }
      summary=$(printf '%s\n' "$out" | sed -n '1,2p' | paste -sd ' ' -)
      ;;
    3) return 3 ;;
    *)
      identity=$(_fm_programme_sha256 "resolver-failed:$rc:$out")
      summary="resolver failed (exit $rc)"
      out="resolver failed (exit $rc); continuation authority is unproven, not captain-gated:
$out"
      ;;
  esac
  verdict=$(fm_programme_presentation_state "$state" "$identity")
  [ "$verdict" = changed ] || return 0
  printf 'PROGRAMME CONTINUATION (material state changed since last presented; typed owner bin/fm-continuation-resolve.sh):\n'
  printf '%s\n' "$out"
  if [ "$mode" = pending ]; then
    printf 'PROGRAMME CONTINUATION: presented identity %s; it is acknowledged by the WAKE_ACK_REQUIRED command below, and state that changes before then surfaces again.\n' "${identity:0:12}"
    _fm_programme_write_record "$(fm_programme_pending_path "$state")" "$identity" "$summary" || return 1
  else
    printf 'PROGRAMME CONTINUATION: presented identity %s (acknowledged with this presentation; nothing is pending).\n' "${identity:0:12}"
    _fm_programme_write_record "$(fm_programme_presented_path "$state")" "$identity" "$summary" || return 1
    rm -f -- "$(fm_programme_pending_path "$state")"
  fi
}

# Acknowledge exactly the identity the drain presented; never re-resolve here.
fm_programme_ack_pending() {  # <state>
  local pending
  pending=$(fm_programme_pending_path "$1")
  [ -f "$pending" ] || return 0
  [ -n "$(_fm_programme_record_identity "$pending")" ] || { rm -f -- "$pending"; return 0; }
  mv -f -- "$pending" "$(fm_programme_presented_path "$1")"
}
