#!/usr/bin/env bash
# Behavior tests for the pure cold-start supervision decisions in the versioned
# launcher source bin/enter-firstmate.sh. Loads it with FM_ENTRY_LIB=1, which
# defines only the pure functions and runs no identity check, so this file
# touches no home, no Herdr session, and no watcher.
#
# Usage: bash tests/enter-firstmate-arm.test.sh
#        FM_ENTRY_LAUNCHER=/path/to/enter-firstmate.sh bash tests/enter-firstmate-arm.test.sh
#        FM_CODE_ROOT_PROBE=<checkout> adds the encode round-trip through the real
#        bin/fm-operational-input.sh (skipped when the checkout is absent).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER=${FM_ENTRY_LAUNCHER:-$HERE/../bin/enter-firstmate.sh}
CODE_ROOT=${FM_CODE_ROOT_PROBE:-$HERE/..}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
[ -f "$LAUNCHER" ] || fail "launcher not found: $LAUNCHER"
# shellcheck disable=SC1090 # the launcher path is resolved at run time
FM_ENTRY_LIB=1 . "$LAUNCHER" || fail "FM_ENTRY_LIB=1 load failed"
command -v cold_arm_decide >/dev/null || fail "cold_arm_decide not defined by the library load"
[ -z "${MODE:-}" ] || [ "$MODE" = console-launch ] || fail "library load must not change mode (MODE=$MODE)"
[ -z "${FM_HERDR_ANCESTRY:-}" ] || fail "library load must stop before the identity checks"
pass "FM_ENTRY_LIB=1 defines the pure functions and runs nothing else"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-entry-arm-test.XXXXXX") || fail mktemp
trap 'rm -rf "$TMP"' EXIT

# --- cold_arm_decide truth table --------------------------------------------
#            needed afk writable foreign claim_open -> verb
expect() {
  local got
  got=$(cold_arm_decide "$1" "$2" "$3" "$4" "$5")
  [ "$got" = "$6" ] || fail "cold_arm_decide $1 $2 $3 $4 $5 -> '$got' (want '$6')"
}
expect false 0 1 0 0 skip-not-needed
expect false 1 0 1 1 skip-not-needed   # nothing to supervise wins over every other fact
expect true  1 1 0 0 skip-afk          # the away daemon owns the watcher
expect true  0 0 0 0 refuse-state-unwritable
expect true  1 0 0 0 skip-afk          # afk is checked before writability
expect true  0 1 1 0 defer-live-session
expect true  0 0 1 1 refuse-state-unwritable  # unwritable state outranks a foreign lock
expect true  0 1 0 0 arm
expect true  0 1 0 1 defer-open-claim
expect true  0 1 1 1 defer-live-session  # a live session outranks the open claim
expect ''    '' '' '' '' skip-not-needed   # missing inputs never arm
[ "$(cold_arm_decide true 0 1 0 0 | wc -l | tr -d ' ')" = 1 ] || fail "decide prints exactly one line"
pass "cold_arm_decide truth table (11 rows)"

# --- cold_arm_arm_line classification ----------------------------------------
f=$TMP/handoff
: > "$f"; [ "$(cold_arm_arm_line "$f")" = none ] || fail "empty handoff -> none"
printf 'decision: arm gen=3 owner_pid=42\n' > "$f"; [ "$(cold_arm_arm_line "$f")" = none ] || fail "decision only -> none"
printf 'watcher: started pid=100 (beacon fresh)\n' >> "$f"; [ "$(cold_arm_arm_line "$f")" = started ] || fail "started"
printf 'watcher: attached pid=100 (beacon 2s)\n' >> "$f"; [ "$(cold_arm_arm_line "$f")" = attached ] || fail "last line wins: attached"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n' >> "$f"; [ "$(cold_arm_arm_line "$f")" = failed ] || fail "failed"
printf 'watcher: healthy pid=1\n' > "$f"; [ "$(cold_arm_arm_line "$f")" = none ] || fail "an unrecognised watcher line is none"
[ "$(cold_arm_arm_line "$TMP/does-not-exist")" = none ] || fail "missing file -> none"
pass "cold_arm_arm_line classifies the last arm line"

# --- cold_arm_reasons ---------------------------------------------------------
cat > "$f" <<'H'
decision: arm gen=3 owner_pid=42
watcher: started pid=100 (beacon fresh)
noise line
check: process-event result captured: procevent:venue:1
signal: /x/state/task.status
stale: fm-task (idle)
heartbeat
heartbeat: fleet
H
r=$(cold_arm_reasons "$f")
[ "$(printf '%s\n' "$r" | wc -l | tr -d ' ')" = 5 ] || fail "reasons count (got: $r)"
case "$r" in *noise*|*decision*|*'watcher:'*) fail "reasons must contain only actionable lines" ;; esac
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'check: extra %s\n' "$i" >> "$f"; done
[ "$(cold_arm_reasons "$f" | wc -l | tr -d ' ')" = 8 ] || fail "reasons are bounded to 8"
[ -z "$(cold_arm_reasons "$TMP/does-not-exist")" ] || fail "missing file -> no reasons"
pass "cold_arm_reasons keeps only the actionable class, bounded"

# --- cold_arm_wake_body ---------------------------------------------------------
body=$(cold_arm_wake_body $'check: a\nsignal: b')
case "$body" in *$'\n'*) fail "body must be a single line" ;; esac
case "$body" in *'check: a | signal: b'*) ;; *) fail "reasons joined with ' | ' (got: $body)" ;; esac
case "$body" in 'firstmate watcher wake - one supervision event needs a handling turn now.'*) ;; *) fail "body opens like the Stop hook banner" ;; esac
case "$body" in *'Run bin/fm-wake-drain.sh first'*'WAKE_ACK_REQUIRED --ack-through'*'do NOT run bin/fm-watch-arm.sh'*) ;; *) fail "body carries the drain, ack, and no-manual-arm instructions" ;; esac
pass "cold_arm_wake_body is one line with the handling contract"

# --- round trip through the real operational-input owner (when present) -------
if [ -x "$CODE_ROOT/bin/fm-operational-input.sh" ]; then
  encoded=$(printf '%s' "$body" | "$CODE_ROOT/bin/fm-operational-input.sh" encode watcher) || fail "encode watcher failed"
  kind=$(printf '%s' "$encoded" | "$CODE_ROOT/bin/fm-operational-input.sh" kind) || fail "kind parse failed"
  [ "$kind" = watcher ] || fail "encoded kind is '$kind', want watcher"
  [ "$kind" != away-supervisor ] || fail "must never be the away-supervisor kind"
  back=$(printf '%s' "$encoded" | "$CODE_ROOT/bin/fm-operational-input.sh" body) || fail "body parse failed"
  [ "$back" = "$body" ] || fail "body round trip differs"
  case "$encoded" in $'\xE2\x81\xA3'"FIRSTMATE_OP: v1 watcher: "*) ;; *) fail "wire form must start with U+2063 FIRSTMATE_OP: v1 watcher:" ;; esac
  pass "watcher-kind envelope round-trips through bin/fm-operational-input.sh ($CODE_ROOT)"
else
  pass "skip: encode round trip (no code root at $CODE_ROOT)"
fi
echo "all cold-start arm decision tests passed"
