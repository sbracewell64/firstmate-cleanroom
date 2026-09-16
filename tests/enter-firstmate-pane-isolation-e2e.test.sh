#!/usr/bin/env bash
# Opt-in real-Herdr proof for the console/doctor worker-pane refusal.
# Every pane is created in a guarded named lab session; no ambient pane is used.
set -eu

[ "${FM_LAUNCHER_LIVE_LAB:-}" = 1 ] || { echo 'skip: set FM_LAUNCHER_LIVE_LAB=1 for the guarded Herdr proof'; exit 0; }
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr is unavailable'; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LIVE_HOME=${FM_LAUNCHER_LIVE_HOME:-/home/shane/.firstmate-cleanroom}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fix5-launcher-test-pane-isolation)
TMP_ROOT=$(mktemp -d)
home=$TMP_ROOT/home
tools_root=$TMP_ROOT/tools
mkdir -p "$home/config" "$home/state" "$tools_root/bin"
ln -s "$(command -v herdr)" "$tools_root/bin/herdr"
cat > "$tools_root/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'daemon status') echo 'daemon running' ;;
  '--version') echo 'test-only no-mistakes' ;;
  *) echo 'test-only no-mistakes: unexpected invocation' >&2; exit 1 ;;
esac
SH
cat > "$tools_root/tool-policy.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"tools":[{"tool":"no-mistakes","state":"QUALIFIED"}]}'
SH
chmod +x "$tools_root/bin/no-mistakes" "$tools_root/tool-policy.sh"
export NM_HOME="$home/no-mistakes"
export PATH="$tools_root/bin:$PATH"
cleanup() {
  local rc=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
fail() { echo "not ok - $*" >&2; exit 1; }

printf '%s\n' "$ROOT" > "$home/config/code-root"
printf '%s\n' "$tools_root" > "$home/config/tools-root"
printf '%s\n' herdr > "$home/config/backend"
printf '%s\n' "$HERDR_LAB_SESSION" > "$home/config/herdr-session"

worker_json=$(lab workspace create --cwd "$TMP_ROOT" --label fix5-worker --no-focus)
worker_pane=$(printf '%s' "$worker_json" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$worker_pane" ] || fail 'lab did not allocate a worker pane'
console_json=$(lab workspace create --cwd "$TMP_ROOT" --label fix5-console --no-focus)
console_pane=$(printf '%s' "$console_json" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$console_pane" ] && [ "$console_pane" != "$worker_pane" ] || fail 'lab did not allocate a distinct console pane'

# The live home is read only. An unevaluable record cannot prove either pane safe.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
for pane in "$worker_pane" "$console_pane"; do
  fm_backend_herdr_pane_ownership "$LIVE_HOME/state" "$HERDR_LAB_SESSION" "$pane" \
    || fail 'a lab pane is present in, or cannot be excluded from, live task records'
done

printf 'backend=herdr\nendpoint_task_id=labworker\nwindow=%s:%s\nworktree=%s\nproject=%s\nherdr_session=%s\nherdr_workspace_id=lab-workspace\nherdr_tab_id=lab-tab\nherdr_pane_id=%s\n' \
  "$HERDR_LAB_SESSION" "$worker_pane" "$TMP_ROOT" "$TMP_ROOT" "$HERDR_LAB_SESSION" "$worker_pane" > "$home/state/labworker.meta"
fm_backend_herdr_pane_ownership "$home/state" "$HERDR_LAB_SESSION" "$console_pane" \
  || fail 'dedicated console pane is not provably free of task records'

# A heartbeat distinguishes a surviving worker process from a pane object that
# still exists after its process was terminated.
heartbeat=$TMP_ROOT/worker-heartbeat
lab pane run "$worker_pane" "sh -c 'while true; do date +%s >> $heartbeat; sleep 1; done'" >/dev/null \
  || fail 'could not start the lab worker heartbeat'
for _ in 1 2 3 4 5; do
  [ -s "$heartbeat" ] && break
  sleep 1
done
[ -s "$heartbeat" ] || fail 'lab worker heartbeat never started'
before_beats=$(wc -l < "$heartbeat")

socket=$(lab session list --json | jq -r --arg name "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $name) | .socket_path')
[ -n "$socket" ] || fail 'lab socket could not be read'
before_worker=$(lab pane get "$worker_pane")
before_console=$(lab pane get "$console_pane")
before_focus=$(lab workspace list | jq -c '[.result.workspaces[]? | select(.focused == true) | .workspace_id]')
before_record=$(sha256sum "$home/state/labworker.meta" | cut -d' ' -f1)
for mode in --console --doctor --console --doctor; do
  rc=0
  env FM_HOME="$home" HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_PANE_ID="$worker_pane" \
    HERDR_SOCKET_PATH="$socket" "$ROOT/bin/enter-firstmate.sh" "$mode" \
    > "$TMP_ROOT/output" 2> "$TMP_ROOT/error" || rc=$?
  [ "$rc" -ne 0 ] || fail "$mode accepted a recorded worker pane"
  grep -F 'worker-owned' "$TMP_ROOT/error" >/dev/null || fail "$mode did not name worker ownership"
done
[ "$(sha256sum "$home/state/labworker.meta" | cut -d' ' -f1)" = "$before_record" ] || fail 'worker record changed'
[ ! -e "$home/state/captain-console.json" ] || fail 'refusal wrote the console record'
[ "$(lab pane get "$worker_pane")" = "$before_worker" ] || fail 'worker pane changed or disappeared'
[ "$(lab pane get "$console_pane")" = "$before_console" ] || fail 'dedicated console pane changed or disappeared'
[ "$(lab workspace list | jq -c '[.result.workspaces[]? | select(.focused == true) | .workspace_id]')" = "$before_focus" ] || fail 'focus changed'
sleep 2
[ "$(wc -l < "$heartbeat")" -gt "$before_beats" ] || fail 'recorded worker process stopped after refusal'

# Positive console launch uses the separate lab pane only. The test harness is
# /bin/true and the no-mistakes client is a local stub, so no model or daemon
# can start during this ownership proof.
console_ws=$(printf '%s' "$console_json" | jq -r '.result.workspace.workspace_id')
touch "$home/state/.afk"
jq -n --arg s "$HERDR_LAB_SESSION" --arg sock "$socket" --arg ws "$console_ws" --arg pane "$console_pane" \
  '{session:$s,socket:$sock,workspace_id:$ws,pane_id:$pane,launch_stage:"launching"}' \
  > "$home/state/captain-console.json"
env FM_HOME="$home" FM_HARNESS=/bin/true HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_PANE_ID="$console_pane" HERDR_SOCKET_PATH="$socket" \
  "$ROOT/bin/enter-firstmate.sh" --console > "$TMP_ROOT/console-output" 2> "$TMP_ROOT/console-error" \
  || fail "dedicated lab console pane could not launch: $(cat "$TMP_ROOT/console-error")"
jq -e '.pane_id != "" and .launch_stage == "exited" and .exit_rc == 0' \
  "$home/state/captain-console.json" >/dev/null || fail 'positive console did not complete in its recorded pane'
[ "$(lab pane get "$worker_pane")" = "$before_worker" ] || fail 'positive console changed the worker pane'
echo 'ok - guarded lab worker survives repeated refusals; positive console uses a distinct, unowned lab pane'
