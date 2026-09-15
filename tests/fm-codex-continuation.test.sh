#!/usr/bin/env bash
# Actual configured Stop + maintained away daemon/watcher in a private home.
# The executable journey substitutes only tmux. Later predicate units explicitly
# double native session membership. Neither qualifies a native model/receiver.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-continuation)
fm_git_identity fmtest fmtest@example.invalid
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
stop '{"stop_hook_active":true,"session_id":"empty"}' > empty.out 2>&1
[ ! -s empty.out ]
printf 'kind=ship\nharness=echo\n' > state/demo.meta
rc=0; stop '{"stop_hook_active":true,"session_id":"blind"}' > blind.out 2>&1 || rc=$?
[ "$rc" = 2 ]
# No watcher is a watcher fault, not a continuation-owner fault: the durable
# receipt and the operator line must both send the reader to the right owner.
grep -q 'CONTINUATION_REQUIRED: watcher-unhealthy;' blind.out
grep -qx 'reason=watcher-unhealthy' state/.turnend-codex-blocks
# A malformed Stop payload is the harness's fault, and it is answered before
# the watcher or the continuation owner is consulted at all.
rc=0; stop '{"stop_hook_active":"true","session_id":"badpayload"}' > badpayload.out 2>&1 || rc=$?
[ "$rc" = 2 ]
grep -q 'CONTINUATION_REQUIRED: stop-payload-invalid;' badpayload.out
grep -qx 'reason=stop-payload-invalid' state/.turnend-codex-blocks
# Real Cursor discriminator excludes the compatibility copy only.
stop '{"cursor_version":"2026.08.11","stop_hook_active":true}' > cursor.out 2>&1
[ ! -s cursor.out ]
printf 'sm-private\n' > .fm-secondmate-home
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
rc=0; stop '{"stop_hook_active":true,"session_id":"shell-owner"}' > shell-owner.out 2>&1 || rc=$?
[ "$rc" = 2 ]
grep -q CONTINUATION_REQUIRED shell-owner.out
# Payload and watcher are both healthy here, so this is the one case that is
# genuinely a continuation-owner fault.
grep -q 'CONTINUATION_REQUIRED: continuation-owner-unverified;' shell-owner.out
grep -qx 'reason=continuation-owner-unverified' state/.turnend-codex-blocks
printf 'ok - configured Stop refuses a shell owner despite real private daemon/watcher custody\n'

# Predicate-level units: double ONLY native session membership so later checks
# are reached. All process identities, cwd and daemon records remain real.
. "$FM_HOME/bin/fm-wake-lib.sh"
. "$FM_HOME/bin/fm-session-lock-lib.sh"
. "$FM_HOME/bin/fm-codex-continuation-lib.sh"
fm_session_lock_owned_by_self() { [ "$1" = "$FM_HOME/state" ]; }
owned() { fm_codex_continuation_owned "$FM_HOME/state" "$FM_HOME" "$FM_HOME"; }
owned
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
owned
printf 'ok - portable predicate units reach and reject target/start/submit/home/root/record mismatches with native session membership explicitly doubled\n'

DRIVER
# Hard bound includes positive custody waiting and reaps private descendants.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
rc=0
fm_run_timed 25 env -i PATH="$TMP_ROOT/fakebin:$PATH" HOME="$home" FM_HOME="$home" \
  FM_BACKEND=tmux FM_SUPERVISOR_BACKEND=tmux FM_HARNESS=codex TMUX_PANE=%9 \
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_SCAN_SECS=999999 \
  bash "$TMP_ROOT/driver.sh" || rc=$?
if [ "$rc" -ne 0 ]; then
  for f in "$home"/*.out; do printf '%s\n' "$f"; cat "$f"; done
  fail "private Codex continuation caller journey exited $rc"
fi
pass 'configured Stop safe idle/secondmate/cursor and shell-owner refusal; later custody predicate units pass without native qualification'
