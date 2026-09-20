#!/usr/bin/env bash
# fm-wake-ack-lib.sh - the private wake-drain acknowledgement packet contract.
#
# A packet-aware caller opens fd 3 only for one fm-wake-drain.sh presentation
# and sets FM_WAKE_ACK_PACKET_FD=3.
# The drain writes exactly one packet and closes fd 3 before programme
# presentation or any other presentation subprocess can run:
#
#   fm-wake-ack-v1<TAB>none<TAB>-<TAB>-
#   fm-wake-ack-v1<TAB>required<TAB><sequence><TAB><recovery-generation>
#
# The packet is the only machine authority for a wrapper to reconstruct a
# WAKE_ACK_REQUIRED instruction.
# Stdout remains presentation data and stderr remains diagnostic data.
# Direct drain callers do not opt into the packet and continue to receive the
# drain-owned instruction on stderr.
#
# This file is sourced, never executed.
set -u

FM_WAKE_ACK_PACKET_SCHEMA=fm-wake-ack-v1
FM_WAKE_ACK_PACKET_MODE=
FM_WAKE_ACK_PACKET_SEQUENCE=
FM_WAKE_ACK_PACKET_GENERATION=

fm_wake_ack_packet_requested() {
  [ "${FM_WAKE_ACK_PACKET_FD:-}" = 3 ]
}

fm_wake_ack_packet_emit() {  # <none|required> [<sequence> <generation>]
  local mode=$1 sequence=${2:--} generation=${3:--}
  fm_wake_ack_packet_requested || return 3
  case "$mode" in
    none)
      sequence=-
      generation=-
      ;;
    required)
      case "$sequence" in ''|*[!0-9]*) return 2 ;; esac
      case "$generation" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
  local rc=0
  printf '%s\t%s\t%s\t%s\n' "$FM_WAKE_ACK_PACKET_SCHEMA" "$mode" "$sequence" "$generation" >&3 \
    || rc=$?
  exec 3>&-
  return "$rc"
}

fm_wake_ack_packet_close() {
  fm_wake_ack_packet_requested || return 0
  exec 3>&-
}

fm_wake_ack_packet_parse() {  # <private-packet-file>
  local file=$1 record schema mode sequence generation extra bytes
  FM_WAKE_ACK_PACKET_MODE=
  FM_WAKE_ACK_PACKET_SEQUENCE=
  FM_WAKE_ACK_PACKET_GENERATION=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  record=$(cat "$file" 2>/dev/null) || return 1
  [ -n "$record" ] || return 1
  bytes=$(wc -c < "$file" 2>/dev/null) || return 1
  bytes=${bytes//[[:space:]]/}
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -eq $((${#record} + 1)) ] || return 1
  IFS=$(printf '\t') read -r schema mode sequence generation extra <<EOF
$record
EOF
  [ -z "${extra:-}" ] || return 1
  [ "$record" = "$(printf '%s\t%s\t%s\t%s' "$schema" "$mode" "$sequence" "$generation")" ] || return 1
  [ "$schema" = "$FM_WAKE_ACK_PACKET_SCHEMA" ] || return 1
  case "$mode" in
    none)
      [ "$sequence" = - ] && [ "$generation" = - ] || return 1
      ;;
    required)
      case "$sequence" in ''|*[!0-9]*) return 1 ;; esac
      case "$generation" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  FM_WAKE_ACK_PACKET_MODE=$mode
  FM_WAKE_ACK_PACKET_SEQUENCE=$sequence
  FM_WAKE_ACK_PACKET_GENERATION=$generation
}

fm_wake_ack_render_required() {
  [ "$FM_WAKE_ACK_PACKET_MODE" = required ] || return 1
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' \
    "$FM_WAKE_ACK_PACKET_SEQUENCE" "$FM_WAKE_ACK_PACKET_GENERATION"
}
