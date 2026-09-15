#!/usr/bin/env bash
# Actual configured Stop + maintained away daemon/watcher in a private home.
# The executable journey substitutes only tmux. Later predicate units explicitly
# double native session membership. Neither qualifies a native model/receiver.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-continuation)
fm_git_identity fmtest fmtest@example.invalid
# The daemon publishes a physical root and the custody predicate reads a
# physical cwd from /proc or lsof, so the fixture home must be physical too -
# a symlinked TMPDIR component (macOS /var) would otherwise make every
# predicate unit below fail for a reason that has nothing to do with custody.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$home/config" "$home/docs" "$TMP_ROOT/fakebin"
cp -R "$ROOT/bin" "$ROOT/.codex" "$home/"
cp -R "$ROOT/docs/supervision-protocols" "$home/docs/"
: > "$home/AGENTS.md"
git -C "$home" init -qb main
git -C "$home" add AGENTS.md
git -C "$home" commit -qm fixture
cat > "$TMP_ROOT/fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message) printf '%%9\n' ;;
  capture-pane) printf '›\n' ;;
  has-session|send-keys|load-buffer|paste-buffer|delete-buffer) ;;
  *) exit 1 ;;
esac
TMUX
chmod +x "$TMP_ROOT/fakebin/tmux"
# A shell driver owns a private lock/cwd but is NOT a native harness. The real
# configured hook must reject it even with an actual daemon/watcher present.
cat > "$TMP_ROOT/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -eu
cd "$FM_HOME"
command=$(jq -r '.hooks.Stop[0].hooks[0].command' .codex/hooks.json)
stop() { printf '%s' "$1" | bash -c "$command"; }
# The recovery budget is scoped to this driver's own session, so every case
# below is an independent scenario and starts from a fresh receipt.
reset_budget() { rm -f state/.turnend-codex-blocks; }
stop '{"stop_hook_active":true,"session_id":"empty"}' > empty.out 2>&1
[ ! -s empty.out ]
printf 'kind=ship\nharness=echo\n' > state/demo.meta
reset_budget
rc=0; stop '{"stop_hook_active":true,"session_id":"blind"}' > blind.out 2>&1 || rc=$?
[ "$rc" = 2 ]
# No watcher is a watcher fault, not a continuation-owner fault: the durable
# receipt and the operator line must both send the reader to the right owner.
grep -q 'CONTINUATION_REQUIRED: watcher-unhealthy;' blind.out
grep -qx 'reason=watcher-unhealthy' state/.turnend-codex-blocks
# A malformed Stop payload is the harness's fault, and it is answered before
# the watcher or the continuation owner is consulted at all.
reset_budget
rc=0; stop '{"stop_hook_active":"true","session_id":"badpayload"}' > badpayload.out 2>&1 || rc=$?
[ "$rc" = 2 ]
grep -q 'CONTINUATION_REQUIRED: stop-payload-invalid;' badpayload.out
grep -qx 'reason=stop-payload-invalid' state/.turnend-codex-blocks
# Real Cursor discriminator excludes the compatibility copy only.
stop '{"cursor_version":"2026.08.11","stop_hook_active":true}' > cursor.out 2>&1
[ ! -s cursor.out ]
printf 'sm-private\n' > .fm-secondmate-home
reset_budget
rc=0; stop '{"stop_hook_active":true,"session_id":"secondmate"}' > secondmate.out 2>&1 || rc=$?
[ "$rc" = 2 ]
rm .fm-secondmate-home
printf '%s\n' "$BASHPID" > state/.lock
: > state/.afk
"$FM_HOME/bin/fm-supervise-daemon.sh" > daemon.out 2>&1 &
daemon=$!
trap 'kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true' EXIT
until [ -f state/.supervise-daemon.lock/continuation ] && [ -f state/.watch.lock/watcher-path ]; do
  kill -0 "$daemon"
  sleep 0.1
 done
# The daemon is the actual record author, but a shell is not a native primary.
reset_budget
rc=0; stop '{"stop_hook_active":true,"session_id":"shell-owner"}' > shell-owner.out 2>&1 || rc=$?
[ "$rc" = 2 ]
grep -q CONTINUATION_REQUIRED shell-owner.out
# Payload and watcher are both healthy here, so this is the one case that is
# genuinely a continuation-owner fault.
grep -q 'CONTINUATION_REQUIRED: continuation-owner-unverified;' shell-owner.out
grep -qx 'reason=continuation-owner-unverified' state/.turnend-codex-blocks
# A documented supervisor target override makes custody UNEVALUABLE, not failed.
# It names itself, allows on the very first Stop, and never climbs the ladder.
reset_budget
rc=0; FM_SUPERVISOR_TARGET=firstmate:0 stop '{"stop_hook_active":true,"session_id":"override"}' > override.out 2>&1 || rc=$?
[ "$rc" = 0 ]
! grep -q CONTINUATION_REQUIRED override.out
! grep -q continuation-owner-unverified override.out
grep -q 'CONTINUATION_CNO: custody is not evaluable under a supervisor target override' override.out
grep -qx 'reason=continuation-owner-unevaluable-target-override' state/.turnend-codex-blocks
grep -qx 'blocks=3' state/.turnend-codex-blocks
printf 'ok - configured Stop refuses a shell owner despite real private daemon/watcher custody, and reports a target override as unevaluable rather than unverified\n'

# Predicate-level units: double ONLY native session membership so later checks
# are reached. All process identities, cwd and daemon records remain real.
. "$FM_HOME/bin/fm-wake-lib.sh"
. "$FM_HOME/bin/fm-session-lock-lib.sh"
. "$FM_HOME/bin/fm-codex-continuation-lib.sh"
fm_session_lock_owned_by_self() { [ "$1" = "$FM_HOME/state" ]; }
owned() { fm_codex_continuation_owned "$FM_HOME/state" "$FM_HOME" "$FM_HOME"; }
owned || exit 30
if TMUX_PANE=%foreign owned; then exit 31; fi
cp state/.supervise-daemon.lock/pid-identity daemon.identity
printf 'stale-start\n' > state/.supervise-daemon.lock/pid-identity
if owned; then exit 32; fi
cp daemon.identity state/.supervise-daemon.lock/pid-identity
: > state/.subsuper-inject-wedged
if owned; then exit 33; fi
rm state/.subsuper-inject-wedged
if fm_codex_continuation_owned "$FM_HOME/state" "$FM_HOME/foreign-home" "$FM_HOME"; then exit 34; fi
# Identical bytes under another release cannot confer path/root ownership.
mkdir foreign
cp -R bin foreign/
if fm_codex_continuation_owned "$FM_HOME/state" "$FM_HOME" "$FM_HOME/foreign"; then exit 35; fi
cp state/.supervise-daemon.lock/continuation continuation.good
printf 'unknown=field\n' >> state/.supervise-daemon.lock/continuation
if owned; then exit 36; fi
cp continuation.good state/.supervise-daemon.lock/continuation
owned || exit 37
printf 'ok - portable predicate units reach and reject target/start/submit/home/root/record mismatches with native session membership explicitly doubled\n'

# A herdr host that leaves HERDR_SESSION unset is NOT a custody fault: the hook
# must compose its pane through the same single owner the daemon published with,
# which defaults that session. Only the record's declared pane is substituted
# here; no herdr transport behaviour is qualified.
sed 's/^backend=tmux$/backend=herdr/; s/^target=%9$/target=default:%p7/' \
  continuation.good > state/.supervise-daemon.lock/continuation
if ! (unset TMUX_PANE HERDR_SESSION; export HERDR_ENV=1 HERDR_PANE_ID=%p7; owned); then exit 38; fi
if (unset TMUX_PANE; export HERDR_ENV=1 HERDR_PANE_ID=%p7 HERDR_SESSION=other; owned); then exit 39; fi
cp continuation.good state/.supervise-daemon.lock/continuation
owned || exit 40

# Custody belongs to the daemon's pane, not to the primary pid that happened to
# hold state/.lock when the daemon started. A primary that exits and is replaced
# in the same home keeps real custody, so the proof must survive the swap.
sleep 30 &
restarted=$!
printf '%s\n' "$restarted" > state/.lock
owned || exit 41
# The budget identity names the session being budgeted, not whoever happens to
# hold the fleet lock, so swapping state/.lock must not move the key. It must
# also name a live process that really is this session - an ancestor in this
# caller's harness run, or the POSIX session it runs in - so no literal can
# satisfy it.
held_key=$(fm_codex_continuation_session_key)
key_pid=${held_key#harness=}
key_pid=${key_pid%% *}
case "$key_pid" in ''|*[!0-9]*) exit 42 ;; esac
kill -0 "$key_pid" 2>/dev/null || exit 42
fm_harness_ancestry_pids 2>/dev/null | grep -qx "$key_pid" \
  || [ "$key_pid" = "$(ps -o sess= -p $$ 2>/dev/null | tr -d '[:space:]')" ] || exit 42
kill "$restarted" 2>/dev/null || true
wait "$restarted" 2>/dev/null || true
printf '%s\n' "$BASHPID" > state/.lock
owned || exit 43
[ "$(fm_codex_continuation_session_key)" = "$held_key" ] || exit 44

# state/.turnend-codex-blocks is this guard's own durable receipt contract.
# Drive two distinct session keys through the refusal itself: the second
# session's FIRST Stop must earn its own blocks=1 refusal rather than inherit
# the first session's exhausted budget.
budget() {
  local rc=0
  fm_codex_continuation_refuse "$FM_HOME/state" "$1" watcher-unhealthy 2>/dev/null || rc=$?
  printf '%s' "$rc"
}
rm -f state/.turnend-codex-blocks
[ "$(budget 'harness=101 session-a')" = 2 ] || exit 45
grep -qx 'blocks=1' state/.turnend-codex-blocks || exit 46
[ "$(budget 'harness=101 session-a')" = 2 ] || exit 47
grep -qx 'blocks=2' state/.turnend-codex-blocks || exit 48
[ "$(budget 'harness=101 session-a')" = 0 ] || exit 49
grep -qx 'blocks=3' state/.turnend-codex-blocks || exit 50
[ "$(budget 'harness=202 session-b')" = 2 ] || exit 51
grep -qx 'blocks=1' state/.turnend-codex-blocks || exit 52
grep -qx 'session=harness=202 session-b' state/.turnend-codex-blocks || exit 53

# The mirror of a stale record: a daemon that wins its own lock before the
# primary takes state/.lock must still publish, or no record would ever exist
# and every later Stop in every later session would refuse and then CNO-allow.
mkdir -p nolock/.supervise-daemon.lock
printf '%s\n' "$BASHPID" > nolock/.supervise-daemon.lock/pid
[ ! -e nolock/.lock ]
fm_codex_continuation_publish nolock "$FM_HOME" "$FM_HOME" tmux %9 || exit 54
diff continuation.good nolock/.supervise-daemon.lock/continuation || exit 55
printf 'ok - custody survives a primary swap, a defaulted herdr session and a lock-less publish; one session can never spend another session bounded recovery\n'

DRIVER
# Hard bound includes positive custody waiting and reaps private descendants.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
rc=0
fm_run_timed 25 env -i PATH="$TMP_ROOT/fakebin:$PATH" HOME="$home" FM_HOME="$home" \
  FM_BACKEND=tmux FM_HARNESS=codex TMUX_PANE=%9 \
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_SCAN_SECS=999999 \
  bash "$TMP_ROOT/driver.sh" || rc=$?
if [ "$rc" -ne 0 ]; then
  for f in "$home"/*.out; do printf '%s\n' "$f"; cat "$f"; done
  fail "private Codex continuation caller journey exited $rc"
fi
pass 'configured Stop safe idle/secondmate/cursor and shell-owner refusal; later custody predicate units pass without native qualification'
