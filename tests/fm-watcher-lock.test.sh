#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

# An arm only reports its typed failure after wait_for_healthy_successor has
# spent the whole confirmation budget, so cases that wait for that failure must
# outlast the largest production default (30s on MSYS, 10s elsewhere - see
# ARM_CONFIRM_DEFAULT in bin/fm-watch-arm.sh). This is a ceiling spent only when
# an arm genuinely fails to exit; a passing case returns as soon as it does.
ARM_FAIL_EXIT_POLLS=400

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

drain_and_ack() {  # <state>
  local state=$1 out sequence generation home
  home=${state%/state}
  out="$state/.test-drain.out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" \
    > "$out" 2> "$state/.test-drain.err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$out")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$out")
  rm -f "$out" "$state/.test-drain.err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  reap "$pid1"
  reap "$pid2"
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  reap "$pid"
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard banner missing neutral automatic-recovery guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard did not order neutral automatic recovery after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) live watcher plus fresh beacon, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") || fail "could not identify fresh guard watcher"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when live and fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" \
    && fail "restart did not surface recovery after replacing a reused-pid lock"
  wait "$pid" 2>/dev/null || true
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "restart replaced reused-pid lock without surfacing recovery: $(cat "$out")"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart preserves recovery without signaling a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer_ready peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  node -e 'const fs = require("node:fs"); process.on("SIGTERM", () => {}); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" &
  peer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$peer_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$peer_ready" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "TERM-resistant peer did not become ready"
  fi
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # The arm's confirmation budget bounds a REAL child startup (fork, exec, lock
  # acquisition, beacon publication), so this case holds the arm to production's
  # own budget rather than a shrunken fixture one: a one-second budget turned
  # ordinary CPU contention into an honest "FAILED - no live watcher with a fresh
  # beacon" and broke this case's premise under full-suite load (issue #2844).
  # It stays at the production default rather than something roomier because the
  # same budget bounds the successor wait this case deliberately spends below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  i=0
  while [ "$i" -lt "$ARM_FAIL_EXIT_POLLS" ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  reap "$wpid"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  reap "$wpid"
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      if [ "$row" = dead-pid ]; then
        is_live_non_zombie "$armpid" || break
      else
        grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      fi
      sleep 0.1; i=$((i + 1))
    done
    if [ "$row" = dead-pid ]; then
      is_live_non_zombie "$armpid" \
        && fail "arm did not surface recovery after reclaiming a dead-pid lock"
      wait "$armpid" 2>/dev/null || true
      grep -F 'check: rearm-resurface' "$armout" >/dev/null \
        || fail "arm reclaimed dead-pid lock without surfacing recovery: $(cat "$armout")"
      continue
    fi
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    reap "$armpid"
    reap "$lock_pid"
  done
  pass "arm starts cleanly and resurfaces recovery after a dead-pid lock"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  # This case asserts wake propagation, not the confirmation deadline, and its
  # child must also run the registered check before exiting: measured at 1.9-2.3s
  # idle but 9.1-13.1s at 3x CPU oversubscription, against an 11s production
  # budget. An explicit budget takes the deadline out of the assertion and costs
  # nothing on a passing run, because the arm returns as soon as the child
  # settles (issue #2844).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=60 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Same budget contract as the self-eviction case: the owned child's real
  # startup and stand-down happen inside the arm's confirmation window, so the
  # window stays production-sized (issue #2844).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same budget the arm spends made this
  # regression fixture race the confirmation deadline under full-suite load,
  # rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS" \
    || fail "attached arm did not exit after peer died"
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120 \
    || fail "arm did not exit after losing its fresh watcher"
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  local prior_recovery_generation recovery_generation
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"
  drain_and_ack "$state" || fail "first ledger wake handling acknowledgement failed"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  prior_recovery_generation=$(recovery_marker_generation "$state/.watcher-down")
  reap "$successor_arm" HUP
  # The forced interruption is a watcher-down interval. Consume the prior
  # delivered wake before beginning independent ledger cycles, just as the
  # recovery handling turn does, so this fixture does not intentionally carry a
  # durable wake into the next arm.
  i=0
  while [ "$i" -lt 200 ]; do
    recovery_generation=$(recovery_marker_generation "$state/.watcher-down")
    [ -n "$recovery_generation" ] && [ "$recovery_generation" != "$prior_recovery_generation" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$recovery_generation" != "$prior_recovery_generation" ] \
    || fail "forced arm interruption did not publish a new recovery generation"
  drain_and_ack "$state" || fail "recovery drain after forced arm interruption failed"

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    prior_recovery_generation=$(recovery_marker_generation "$state/.watcher-down")
    reap "$successor_arm" HUP
    i=0
    while [ "$i" -lt 200 ]; do
      recovery_generation=$(recovery_marker_generation "$state/.watcher-down")
      [ -n "$recovery_generation" ] && [ "$recovery_generation" != "$prior_recovery_generation" ] && break
      sleep 0.1
      i=$((i + 1))
    done
    [ "$recovery_generation" != "$prior_recovery_generation" ] \
      || fail "bounded ledger cycle $iteration did not publish a new recovery generation"
    drain_and_ack "$state" \
      || fail "recovery drain after bounded ledger cycle $iteration failed"
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*restart_stop=.*child_stop=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80 \
    || fail "terminated stopped-watcher cycle did not exit"
  status=0
  wait "$armpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_a_zombie_is_dead_and_does_not_block_successor() {
  # A forked child that exited while its parent has not reaped it is a zombie.
  # Linux exposes that state through /proc, and the lock owner must treat it as
  # dead: it cannot authorize signalling or keep a stale lock from succession.
  local dir state lockdir zpid go i successor_pid proc_state stat_line
  dir=$(make_case zombie-predicates)
  state="$dir/state"
  lockdir="$state/.zombie.lock"
  go="$dir/reap.go"
  command -v python3 >/dev/null 2>&1 || { pass "zombie predicate pair skipped: python3 is unavailable"; return; }
  [ -r /proc/$$/cmdline ] \
    || { pass "zombie predicate pair skipped: this host exposes no /proc cmdline"; return; }

  python3 - "$dir/zombie.pid" "$go" <<'PYZ' &
import os, sys, time
pid = os.fork()
if pid == 0:
    os._exit(0)
with open(sys.argv[1], "w") as fh:
    fh.write(str(pid))
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
os.waitpid(pid, 0)
PYZ
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/zombie.pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  zpid=$(cat "$dir/zombie.pid" 2>/dev/null || true)
  case "$zpid" in
    ''|*[!0-9]*) : > "$go"; wait; fail "the zombie fixture never published a pid" ;;
  esac
  # Synchronize on the kernel-observable state, not merely on the fixture's
  # PID publication. A fast or supervised runner can otherwise let the
  # predicate checks race the child's transition to (or away from) Z.
  i=0
  proc_state=
  while [ "$i" -lt 100 ]; do
    stat_line=$(cat "/proc/$zpid/stat" 2>/dev/null || true)
    proc_state=
    if [ -n "$stat_line" ]; then
      read -r proc_state _ <<< "${stat_line##*)}"
    fi
    [ "$proc_state" = Z ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$proc_state" = Z ] \
    || { : > "$go"; wait; fail "the zombie fixture did not reach the observable Z state"; }

  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$zpid"; then
    : > "$go"; wait
    fail "a zombie was treated as live and could block stale-owner succession"
  fi
  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2" >/dev/null 2>&1' _ "$LIB" "$zpid"; then
    : > "$go"; wait
    fail "a zombie yielded an identity that could authorize signalling"
  fi

  mkdir "$lockdir"
  printf '%s\n' "$zpid" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$LIB" "$lockdir" \
    || { : > "$go"; wait; fail "stale-owner reconciliation did not establish a successor claim for a zombie"; }
  successor_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$successor_pid" != "$zpid" ] \
    || { : > "$go"; wait; fail "successor claim retained the zombie pid"; }

  : > "$go"
  wait
  pass "a zombie is dead for ownership and permits a successor claim without signalling"
}

test_unevaluable_proc_state_is_live_safe() {
  local dir proc_root pid status=0
  dir=$(make_case unevaluable-proc-state)
  proc_root="$dir/proc"
  pid=$$
  mkdir -p "$proc_root/$pid"
  for stat_line in '' '   ' 'not a proc stat' 'x (watcher) Q 1 2 3'; do
    printf '%s\n' "$stat_line" > "$proc_root/$pid/stat"
    status=0
    FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$pid" || status=$?
    [ "$status" -eq 0 ] || fail "unevaluable proc state was treated as dead: '$stat_line'"
  done
  printf '%s\n' 'x (watcher) R 1 2 3' > "$proc_root/$pid/stat"
  FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$pid" \
    || fail "a valid non-zombie proc state was treated as dead"
  printf '%s\n' 'x (watcher) Z 1 2 3' > "$proc_root/$pid/stat"
  FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$pid" \
    && fail "a positively observed zombie was treated as live"
  pass "unevaluable proc state remains live-safe while exact zombies are dead"
}

test_live_unverifiable_identity_does_not_confirm_stop() {
  local status=0
  bash -c '. "$1"; fm_pid_alive() { return 0; }; fm_pid_identity() { return 1; }; fm_stop_process_confirmed 123 recorded 1' _ "$LIB" || status=$?
  [ "$status" -eq 4 ] || fail "a live target with unverifiable identity returned $status instead of an unverifiable result"
  if bash -c '. "$1"; fm_stop_was_delivered 4' _ "$LIB"; then
    fail "an unverifiable stop result was treated as a delivered stop"
  fi
  pass "live unverifiable identity blocks confirmed collection"
}

test_live_missing_identity_does_not_signal() {
  local status=0 signal_file
  signal_file=$(mktemp "${TMPDIR:-/tmp}/fm-watcher-missing-identity.XXXXXX") || fail "could not create signal fixture"
  SIGNAL_FILE="$signal_file" bash -c '
    . "$1"
    fm_pid_alive() { return 0; }
    fm_pid_identity() { printf "%s\n" current; }
    kill() { printf "%s\n" signal >> "$SIGNAL_FILE"; return 0; }
    sleep() { :; }
    fm_stop_process_confirmed 123 "" 1
  ' _ "$LIB" || status=$?
  [ "$status" -eq 4 ] || fail "a live target with missing identity returned $status instead of refusal"
  [ ! -s "$signal_file" ] || fail "a live target with missing identity was signalled"
  rm -f "$signal_file"
  pass "live missing identity blocks signaling"
}

test_zero_redelivery_polls_use_default_cadence() {
  local status=0
  FM_STOP_REDELIVER_POLLS=0 bash -c '
    . "$1"
    stop_checks=0
    fm_pid_alive() { stop_checks=$((stop_checks + 1)); [ "$stop_checks" -lt 2 ]; }
    fm_pid_identity() { printf "%s\n" recorded; }
    kill() { return 0; }
    sleep() { :; }
    fm_stop_process_confirmed 123 recorded 1
  ' _ "$LIB" || status=$?
  [ "$status" -eq 0 ] || fail "zero redelivery cadence failed stop confirmation with status $status"
  pass "zero redelivery cadence falls back before modulo arithmetic"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc fakebin locale_log baseline via_lc_all via_lc_time
  local real_first real_second observed
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  fakebin="$TMP_ROOT/locale-ps"
  locale_log="$TMP_ROOT/locale-ps.observed"
  mkdir -p "$fakebin"
  : > "$locale_log"
  # The stub renders lstart through date under whatever locale it inherits, so its
  # output really does change when the caller's locale leaks through. Dropping the
  # LC_ALL=C pin in fm_pid_identity therefore breaks the equality assertions below
  # on any host with a second locale installed, and the recorded LC_ALL below keeps
  # the pin asserted even where ko_KR.UTF-8 is missing and date falls back to C.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$FAKE_PS_LOCALE_LOG"
stamp=$(date -d @1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp=$(date -r 1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp='Mon Jul 28 20:00:00 2026'
printf '%s sleep 300\n' "$stamp"
SH
  chmod +x "$fakebin/ps"
  baseline=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  # Keep the real ps fallback exercised wherever it supports the portable -o fields.
  real_first=
  real_second=
  if LC_ALL=C ps -p "$live" -o lstart= -o command= >/dev/null 2>&1; then
    real_first=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    real_second=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  while read -r observed; do
    [ "$observed" = C ] || fail "fm_pid_identity invoked ps without pinning LC_ALL=C (saw '$observed')"
  done < "$locale_log"
  if [ -n "$real_first" ]; then
    [ "$real_second" = "$real_first" ] \
      || fail "real ps fallback varied with exported LC_TIME (got '$real_second', want '$real_first')"
    pass "fm_pid_identity real ps fallback is locale-invariant"
  else
    pass "real ps fallback locale check skipped where ps -o lstart= is unsupported"
  fi
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse() {
  local dir state proc_root pid identity_key before after_time_jump after_pid_reuse
  dir=$(make_case proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  pid=4242
  identity_key=proc-starttime
  [ "$(uname)" != Linux ] || identity_key=linux-starttime
  mkdir -p "$proc_root"
  printf 'btime 1784094040\n' > "$proc_root/stat"
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read initial fake Linux process identity"
  printf 'btime 1784094016\n' > "$proc_root/stat"
  after_time_jump=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "/proc process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = "$identity_key=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700" ] \
    || fail "/proc process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "/proc process identity ignores simulated btime changes"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read reused fake /proc pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "/proc process identity missed changed starttime for reused pid"
  pass "/proc process identity detects pid reuse"
}

test_stale_watch_reclaim_publishes_before_clear() {
  local dir state lockdir rc token
  dir=$(make_case stale-watch-publish-before-clear)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir"
  printf '99999999\n' > "$lockdir/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_remove_path() {
      if [ "$1" = "$STATE/.watch.lock" ]; then
        kill -KILL "${BASHPID:-$$}"
      fi
      return 1
    }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted stale watcher reclaim unexpectedly completed"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] \
    || fail "stale watcher lock cleared before recovery publication boundary"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$LIB" "$state/.watcher-down") \
    || fail "stale watcher reclaim interruption left no durable recovery evidence"
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale watcher reclaim published invalid recovery evidence: $token" ;;
  esac

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" \
    || fail "successor could not reclaim watcher lock after interrupted clear"
  pass "stale watcher reclaim publishes durable recovery evidence before clear"
}

test_msys_pid_identity_uses_proc() {
  local live identity
  case "$(uname)" in
    MSYS*|MINGW*|CYGWIN*) ;;
    *)
      pass "MSYS /proc process identity regression skipped on non-Windows host"
      return
      ;;
  esac
  sleep 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$identity" in
    proc-starttime=*" cmdline-hex="*) ;;
    *) fail "MSYS process identity did not use compatible /proc fields ('$identity')" ;;
  esac
  pass "MSYS process identity uses compatible /proc fields"
}

test_reap_bounds_a_signal_swallowing_watcher() {
  # Regression for the hang this suite is fixing: a watcher that swallows its
  # stop signal (reproduced deterministically here by IGNORING HUP/INT/TERM
  # outright, the observable end state of the CI bash-5.2 trap-during-command-
  # substitution swallow) must be collected within a bounded deadline, not
  # waited on forever. Before reap, a bare `kill; wait` teardown against such a
  # process blocked until the 30-minute portable-serial job cap with no
  # FM_TEST_END - so this asserts reap KILLs and collects it well inside that
  # window. A KILL is uncatchable, so this holds on every bash version regardless
  # of whether the underlying trap bug can be provoked on this host.
  local dir ready ignorer start elapsed i
  dir=$(make_case reap-swallow)
  ready="$dir/ignorer.ready"
  # A stand-in that ignores every stop signal, then blocks far longer than reap's
  # bounded grace. The short inner sleeps leave no long-lived orphan once the
  # shell itself is KILLed. It marks itself ready only AFTER installing the
  # ignore traps: a fresh `bash -c` inherits the harness's trapped-TERM as the
  # default disposition across exec, so signaling before the trap is installed
  # would kill it in that startup window and mask the KILL path this asserts.
  bash -c 'trap "" HUP INT TERM; : > "$1"; while :; do sleep 0.5; done' _ "$ready" &
  ignorer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "signal-swallowing stand-in did not install its ignore traps"
  # Prove it is genuinely signal-resistant first, so a cooperative exit cannot
  # let this pass without exercising the bounded KILL path.
  kill -TERM "$ignorer" 2>/dev/null || true
  kill -HUP "$ignorer" 2>/dev/null || true
  sleep 0.3
  is_live_non_zombie "$ignorer" \
    || fail "signal-swallowing stand-in exited on TERM/HUP; cannot exercise the bounded reap"
  # Force a short grace so the KILL path is exercised in ~1s rather than the
  # 10s production teardown grace: the assertion is that reap is BOUNDED and
  # collects, not the exact wall-clock ceiling, so this keeps the regression
  # cheap without weakening it. The deadline check gives generous headroom over
  # the forced 1s grace so CI scheduling jitter cannot make it flake.
  start=$(date +%s)
  FM_REAP_GRACE_POLLS=10 reap "$ignorer"
  elapsed=$(( $(date +%s) - start ))
  is_live_non_zombie "$ignorer" && fail "reap did not collect a signal-swallowing watcher"
  [ "$elapsed" -le 20 ] \
    || fail "reap did not bound a signal-swallowing watcher (took ${elapsed}s)"
  pass "reap collects a signal-swallowing watcher within a bounded deadline"
}

test_reap_redelivers_a_dropped_stop_so_the_close_path_still_runs() {
  # The failure this pins is the one the bounded KILL above only CONTAINS: a
  # watcher whose stop signal was dropped is collected, but by an uncatchable
  # KILL, so its close path - singleton lock release, downtime publication,
  # delivery ledger - never runs, and the next drain then has no stopped cycle to
  # present or acknowledge. That is how a green branch arrived red on CI's
  # bash 5.2, where a trapped signal landing while the shell expands a command
  # substitution is consumed without its handler ever running.
  #
  # The stand-in reproduces that observable deterministically on every bash, with
  # no wall-clock window to race: it counts deliveries whose close path does NOT
  # run, and arms the real close path only after the SECOND such delivery. The
  # first is spent by the negative control below, so the first delivery any stop
  # protocol makes is provably dropped. One that delivers once then escalates to
  # KILL leaves no close record; one that re-delivers until the target is
  # observed gone does.
  local dir ready closed drops armed dropper start elapsed i
  dir=$(make_case reap-redelivery)
  ready="$dir/dropper.ready"
  closed="$dir/dropper.closed"
  drops="$dir/dropper.drops"
  armed="$dir/dropper.armed"
  # Marked ready only after the dropping disposition is installed, so a stop sent
  # in the startup window cannot kill it through the inherited default and mask
  # the re-delivery this asserts.
  bash -c '
    count=0
    trap "count=\$((count + 1)); printf %s \"\$count\" > \"\$3\"" TERM
    : > "$1"
    while [ "$count" -lt 2 ]; do sleep 0.05; done
    trap "printf closed > \"\$2\"; exit 0" TERM
    : > "$4"
    while :; do sleep 0.2; done
  ' _ "$ready" "$closed" "$drops" "$armed" &
  dropper=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "stop-dropping stand-in did not install its dropping disposition"

  # Negative control: the first stop really is dropped, so a passing case cannot
  # come from a stand-in that stops on the first delivery anyway.
  kill -TERM "$dropper" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && [ "$(cat "$drops" 2>/dev/null || true)" != 1 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$drops" 2>/dev/null || true)" = 1 ] || fail "stop-dropping stand-in never observed its first stop"
  is_live_non_zombie "$dropper" || fail "stop-dropping stand-in exited on its dropped stop"
  [ ! -e "$closed" ] || fail "stop-dropping stand-in ran a close path for a dropped stop"
  [ ! -e "$armed" ] || fail "stop-dropping stand-in armed its close path before its drop window closed"

  # A grace comfortably past both the drop window and the re-delivery interval,
  # so the assertion is about re-delivery rather than about outlasting anything.
  start=$(date +%s)
  FM_REAP_GRACE_POLLS=80 reap "$dropper"
  elapsed=$(( $(date +%s) - start ))
  is_live_non_zombie "$dropper" && fail "reap did not collect a stop-dropping watcher"
  [ -e "$closed" ] \
    || fail "reap collected the watcher without its close path running: the dropped stop was never re-delivered"
  [ "$elapsed" -le 8 ] \
    || fail "reap did not re-deliver promptly after the drop window (took ${elapsed}s)"
  pass "a dropped stop is re-delivered until the watcher is gone, so its close path still runs"
}

test_watcher_close_path_is_not_abandoned_by_a_later_stop() {
  # A dying watcher receiving more than one stop is ordinary: a supervisor
  # signals the process group AND the pid, and a confirmed stop re-delivers to a
  # target that has shown no sign of stopping. Its close path is what makes the
  # stop READABLE - it releases the singleton lock and publishes the downtime
  # episode the next drain presents and retires - so a later stop must not
  # re-enter the exit handler and abandon it half done. That leaves a watcher
  # that is gone with no record that it ever stopped, and the next drain then has
  # nothing to present: the exact shape of the CI failure this branch repairs.
  local dir state fakebin out pid i
  dir=$(make_case close-path-second-stop)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || { reap "$pid"; fail "watcher never reached its poll loop"; }

  # Keep stopping it until it is gone. The interval is deliberately far shorter
  # than the library's own 2-second re-delivery pacing: the window this case must
  # hit is the one before watcher_cleanup installs its ignore, and only an
  # interval shorter than the close path lands a stop inside it, which is what
  # makes this deterministic rather than a race the run might miss. The burst is
  # safe once that ignore is in force because the close path IGNORES stops rather
  # than queueing them, so they build no pending-trap bookkeeping to corrupt.
  i=0
  while [ "$i" -lt 250 ] && is_live_non_zombie "$pid"; do
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.02
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" && { reap "$pid"; fail "watcher never stopped under repeated stops"; }
  wait "$pid" 2>/dev/null || true

  [ -e "$state/.watcher-down" ] \
    || fail "the watcher's close path was abandoned by a later stop: no downtime episode was published"
  drain_and_ack "$state" \
    || fail "a watcher stopped under repeated stops left no acknowledgeable stopped cycle"
  pass "a later stop cannot abandon the watcher close path that publishes its stop"
}

test_close_path_wait_for_the_marker_lock_stays_killable() {
  # arch-escape-hatch-ordering regression. The close path ignores stop signals so
  # a later stop cannot tear its downtime publication, but the WAIT for the
  # downtime marker lock has no deadline of its own, and a live holder that never
  # releases would leave the exiting watcher spinning with every stop discarded -
  # an UNKILLABLE watcher, which is worse in this fleet than a torn close because
  # the broad kill that would be the only way out is forbidden here. So that wait
  # runs with the ordinary stop disposition still in force, and this proves both
  # halves: the watcher is still collectable by an ordinary stop while it waits,
  # and what it leaves behind is the ordinary killed-watcher state the next
  # watcher recovers rather than a half-written marker.
  local dir state fakebin out watcher holder successor watcher_status i
  dir=$(make_case close-path-marker-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  watcher=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || { reap "$watcher"; fail "watcher never reached its poll loop"; }
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
    || { reap "$watcher"; fail "watcher did not record itself as the singleton holder"; }

  # A peer that takes the downtime marker lock through the real primitive and
  # never gives it back, so the exiting watcher's acquire cannot return.
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while :; do sleep 0.2; done
  ' _ "$LIB" "$state/.watcher-down.lock" "$dir/holder.ready" >/dev/null 2>&1 &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$dir/holder.ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$dir/holder.ready" ] \
    || { kill -KILL "$holder" 2>/dev/null || true; reap "$watcher"; fail "the marker-lock holder never took the lock"; }

  # Ordinary stops only, re-delivered the way a supervisor and a confirmed stop
  # both do. No KILL: an uncatchable signal would collect the watcher whether or
  # not the wait is interruptible, and would prove nothing.
  i=0
  while [ "$i" -lt 100 ] && is_live_non_zombie "$watcher"; do
    kill -TERM "$watcher" 2>/dev/null || true
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$watcher" \
    && { kill -KILL "$holder" 2>/dev/null || true; reap "$watcher"; fail "a watcher waiting for the downtime marker lock discarded every stop: only an uncatchable KILL could collect it"; }
  watcher_status=0
  wait "$watcher" 2>/dev/null || watcher_status=$?
  [ "$watcher_status" -eq 1 ] \
    || { kill -KILL "$holder" 2>/dev/null || true; fail "the marker-lock signal path did not exit directly after releasing its lock (status $watcher_status)"; }

  # Nothing was half-done: the marker was never written, and the singleton lock
  # still names the collected watcher, exactly as for a watcher killed outright.
  [ ! -e "$state/.watcher-down" ] \
    || { kill -KILL "$holder" 2>/dev/null || true; fail "a stop taken during the marker-lock wait left a downtime marker behind"; }
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
    || { kill -KILL "$holder" 2>/dev/null || true; fail "a stop taken during the marker-lock wait tore the singleton lock"; }

  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # And that state is recoverable rather than lost: the next watcher steals the
  # stale singleton lock, publishes the downtime its predecessor never reached,
  # and the drain can present and acknowledge that stopped cycle.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-two.out" 2>/dev/null &
  successor=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$state/.watcher-down" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.watcher-down" ] \
    || { reap "$successor"; fail "the next watcher did not publish the downtime the collected watcher never reached"; }
  drain_and_ack "$state" \
    || { reap "$successor"; fail "the state left by a stop during the marker-lock wait is not an acknowledgeable stopped cycle"; }
  reap "$successor"
  pass "a close path waiting for the marker lock is still collectable by a stop, and what it leaves is recoverable"
}

test_close_path_publishes_under_marker_lock_contention() {
  # The sequence the case above cannot reach: the downtime marker lock is FREE
  # when the close begins, and a peer only starts contending for it once the stop
  # has landed. A close that asked "is the lock free?" and then separately took it
  # would pass its probe, lose the lock to that peer in between, and then block on
  # the real acquire with every stop ignored. Holding the probe-acquired lock
  # across the transition removes the window rather than narrowing it, so this
  # pins the property either interleaving must satisfy: the watcher is collected
  # by ordinary stops alone, and its downtime is still recoverable afterwards.
  local dir state fakebin out watcher peer successor i
  dir=$(make_case marker-lock-contention)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  watcher=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || { reap "$watcher"; fail "watcher never reached its poll loop"; }
  # The watcher takes this lock briefly during its own startup, so the premise is
  # that it has been GIVEN BACK, not that it was never held. Wait for that rather
  # than sampling the instant the beacon appears.
  i=0
  while [ "$i" -lt 100 ] && [ -e "$state/.watcher-down.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.watcher-down.lock" ] \
    && { reap "$watcher"; fail "the marker lock must be free before this close begins"; }

  # The stop first, then a peer that starts competing for the marker lock and
  # keeps it once it wins. Whichever of them takes it first, the watcher must not
  # end up spinning on it with its stops discarded.
  kill -TERM "$watcher" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while :; do sleep 0.2; done
  ' _ "$LIB" "$state/.watcher-down.lock" "$dir/peer.held" >/dev/null 2>&1 &
  peer=$!

  # Ordinary stops only. A KILL would collect the watcher whether or not the
  # publishing wait is interruptible, and would prove nothing.
  i=0
  while [ "$i" -lt 100 ] && is_live_non_zombie "$watcher"; do
    kill -TERM "$watcher" 2>/dev/null || true
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$watcher" \
    && { kill -KILL "$peer" 2>/dev/null || true; reap "$watcher"; fail "a close path that lost the marker lock to a peer discarded every stop: only an uncatchable KILL could collect it"; }
  wait "$watcher" 2>/dev/null || true

  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true

  # Recoverable either way: the watcher published its downtime before the peer
  # could take the lock, or it was collected without publishing and the next
  # watcher's stale-lock steal publishes it. Both must reach an acknowledgeable
  # stopped cycle.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-two.out" 2>/dev/null &
  successor=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$state/.watcher-down" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.watcher-down" ] \
    || { reap "$successor"; fail "no downtime episode survived a close that contended for the marker lock"; }
  drain_and_ack "$state" \
    || { reap "$successor"; fail "a close that contended for the marker lock left no acknowledgeable stopped cycle"; }
  reap "$successor"
  pass "a close path racing a peer for the marker lock is still collectable by a stop and still leaves a recoverable downtime"
}

# A stand-in watcher that RECORDS every stop signal it receives, so a case can
# assert on what the arm actually sent its owned child rather than on prose about
# it. It is launched by the real arm, through a fixture bin/ whose fm-watch.sh is
# this stand-in, and it claims this home's singleton lock the way a real watcher
# does so the arm's healthy-watcher confirmation accepts it.
make_recording_watcher_bin() {  # <dir>
  local dir=$1 armbin
  armbin="$dir/armbin"
  mkdir -p "$armbin"
  ln -sf "$ROOT/bin/fm-watch-arm.sh" "$armbin/fm-watch-arm.sh"
  ln -sf "$ROOT/bin/fm-wake-lib.sh" "$armbin/fm-wake-lib.sh"
  ln -sf "$ROOT/bin/fm-timeout-lib.sh" "$armbin/fm-timeout-lib.sh"
  cat > "$armbin/fm-watch.sh" <<'STUB'
#!/usr/bin/env bash
set -u
SIG_LOG=${FM_STUB_SIGLOG:?}
STUB_MODE=${FM_STUB_MODE:?}
STUB_GO=${FM_STUB_GO:-}
STUB_LIB=${FM_STUB_LIB:?}
STUB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
: > "$SIG_LOG"
stub_stops=0
on_stop() {
  printf '%s\n' "$1" >> "$SIG_LOG"
  stub_stops=$((stub_stops + 1))
  if [ "$STUB_MODE" = exit-on-stop ]; then
    exit 0
  fi
  if [ "$STUB_MODE" = drop-first-stop ] && [ "$stub_stops" -ge 2 ]; then
    exit 1
  fi
}
trap 'on_stop TERM' TERM
trap 'on_stop HUP' HUP
trap 'on_stop INT' INT
[ "$STUB_MODE" != exit-now ] || exit 0
# shellcheck disable=SC1090,SC1091
. "$STUB_LIB"
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$STUB_SELF" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
touch "$STATE/.last-watcher-beat"
stub_i=0
while [ "$stub_i" -lt 300 ]; do
  if [ -n "$STUB_GO" ] && [ -e "$STUB_GO" ]; then
    break
  fi
  sleep 0.1
  stub_i=$((stub_i + 1))
done
[ "$STUB_MODE" != wake ] || printf 'signal: stub-wake\n'
exit 0
STUB
  chmod +x "$armbin/fm-watch.sh"
  printf '%s\n' "$armbin"
}

test_normal_cycle_end_sends_the_owned_child_no_stop() {
  # The arm's normal-completion waits are deliberately NOT routed through the
  # confirmed stop: their unbounded wait IS the supervision cycle, and the child
  # ends it by itself. That exclusion is only safe while those paths send the
  # child nothing, so this asserts it from the child's side - a stand-in watcher
  # that records every stop it receives must record none across a cycle that ends
  # with its own wake.
  local dir state armbin siglog go out arm status
  dir=$(make_case normal-cycle-no-stop)
  state="$dir/state"
  siglog="$dir/child-signals.log"
  go="$dir/child.go"
  armbin=$(make_recording_watcher_bin "$dir")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_STUB_SIGLOG="$siglog" FM_STUB_MODE=wake \
    FM_STUB_GO="$go" FM_STUB_LIB="$LIB" "$armbin/fm-watch-arm.sh" > "$dir/arm.out" 2>/dev/null &
  arm=$!
  i=0
  while [ "$i" -lt 150 ] && ! grep -qF 'watcher: started pid=' "$dir/arm.out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/arm.out" \
    || { reap "$arm"; fail "the recording stand-in watcher was never confirmed by the arm"; }

  : > "$go"
  status=0
  wait_for_exit "$arm" 200 >/dev/null 2>&1 || status=$?
  out=$(cat "$dir/arm.out" 2>/dev/null || true)
  case "$out" in
    *"signal: stub-wake"*) ;;
    *) fail "the arm did not surface the wake its child ended on: $out" ;;
  esac
  [ ! -s "$siglog" ] \
    || fail "a normal cycle end signalled the owned child: $(tr '\n' ' ' < "$siglog")"
  pass "a cycle that ends on the child's own wake sends that child no stop signal"
}

test_an_unconfirmed_child_stop_is_never_the_arms_last_word() {
  local dir state armbin siglog arm child delivered i
  dir=$(make_case arm-stop-is-confirmed)
  state="$dir/state"
  siglog="$dir/child-signals.log"
  armbin=$(make_recording_watcher_bin "$dir")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_STUB_SIGLOG="$siglog" FM_STUB_MODE=drop-first-stop \
    FM_STUB_LIB="$LIB" "$armbin/fm-watch-arm.sh" > "$dir/arm.out" 2>/dev/null &
  arm=$!
  i=0
  while [ "$i" -lt 150 ] && ! grep -qF 'watcher: started pid=' "$dir/arm.out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/arm.out" \
    || { reap "$arm"; fail "the stop-dropping stand-in watcher was never confirmed by the arm"; }
  child=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  case "$child" in
    ''|*[!0-9]*) reap "$arm"; fail "the stand-in watcher recorded no lock pid" ;;
  esac

  reap "$arm" HUP
  is_live_non_zombie "$child" \
    || fail "the arm unexpectedly treated an unconfirmed child stop as proven death"
  delivered=$(grep -c . "$siglog" 2>/dev/null || echo 0)
  [ "$delivered" -eq 1 ] \
    || fail "the arm stopped its child with $delivered TERM deliveries instead of one"
  kill -KILL "$child" 2>/dev/null || true
  pass "an arm stops its owned child with one bounded TERM"
}

test_forced_owned_child_stop_is_reaped_and_recorded() {
  local dir state armbin siglog arm child status i
  dir=$(make_case forced-owned-child-stop)
  state="$dir/state"
  siglog="$dir/child-signals.log"
  armbin=$(make_recording_watcher_bin "$dir")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_STUB_SIGLOG="$siglog" FM_STUB_MODE=ignore-stop \
    FM_STUB_LIB="$LIB" \
    "$armbin/fm-watch-arm.sh" > "$dir/arm.out" 2>/dev/null &
  arm=$!
  i=0
  while [ "$i" -lt 150 ] && ! grep -qF 'watcher: started pid=' "$dir/arm.out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/arm.out" \
    || { reap "$arm"; fail "the ignore-stop stand-in watcher was never confirmed by the arm"; }
  child=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$arm" 2>/dev/null || true
  status=0
  wait "$arm" 2>/dev/null || status=$?
  is_live_non_zombie "$child" \
    || fail "the arm did not retain a TERM-ignoring owned watcher after its bounded stop"
  [ "$(grep -c . "$siglog" 2>/dev/null || echo 0)" -eq 1 ] \
    || fail "the arm delivered more than one TERM to a TERM-ignoring child"
  grep -q 'child_stop=unconfirmed' "$state/.watch-cycle-exits.log" \
    || fail "the arm did not record its unconfirmed child disposition"
  kill -KILL "$child" 2>/dev/null || true
  [ "$status" -eq 129 ] || fail "the arm did not preserve its HUP outcome after force-collecting the child"
  pass "a TERM-ignoring owned child is retained after one bounded TERM"
}

test_restart_records_whether_its_stop_was_confirmed() {
  local dir state fakebin arm_out restart_out restart_err second_out second_err
  local arm_pid holder_pid stopped_pid lock_pid status i
  dir=$(make_case restart-stop-disposition)
  state="$dir/state"
  fakebin="$dir/fakebin"
  arm_out="$dir/arm.out"
  restart_out="$dir/restart.out"
  restart_err="$dir/restart.err"
  second_out="$dir/unconfirmed.out"
  second_err="$dir/unconfirmed.err"

  restart_case_arm() {
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" "$@"
  }
  resume_stopped_holder() {
    [ -n "${stopped_pid:-}" ] || return 0
    kill -CONT "$stopped_pid" 2>/dev/null || true
  }

  restart_case_arm > "$arm_out" 2>/dev/null &
  arm_pid=$!
  i=0
  while [ "$i" -lt 80 ] && ! grep -qF 'watcher: started pid=' "$arm_out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  holder_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$holder_pid" "$arm_out" \
    || { reap "$arm_pid"; fail "restart fixture watcher did not start"; }

  # A recorded holder that DOES act on its stop: the confirmed disposition.
  restart_case_arm --restart > "$restart_out" 2> "$restart_err" || true
  is_live_non_zombie "$holder_pid" \
    && { reap "$arm_pid"; fail "--restart returned while the watcher it stopped was still alive"; }
  grep -q 'restart_stop=confirmed' "$state/.watch-cycle-exits.log" \
    || { reap "$arm_pid"; fail "a --restart that confirmed its stop did not record the confirmed disposition"; }

  # An arm that restarted nothing must not claim a stop disposition at all.
  wait_for_exit "$arm_pid" 200 >/dev/null 2>&1
  grep -q 'restart_stop=none' "$state/.watch-cycle-exits.log" \
    || fail "an arm that performed no --restart stop did not record the absent disposition"
  drain_and_ack "$state" || fail "recovery drain after the confirmed restart failed"

  restart_case_arm > "$second_out" 2>/dev/null &
  arm_pid=$!
  i=0
  while [ "$i" -lt 80 ] && ! grep -qF 'watcher: started pid=' "$second_out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  stopped_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$stopped_pid" "$second_out" \
    || { reap "$arm_pid"; fail "stop-proof fixture watcher did not start"; }

  # Now a recorded holder that CANNOT act on any stop, however often it is
  # delivered: SIGSTOP leaves it live and identity-matched, so --restart signals
  # it for real and its bounded confirmation genuinely cannot succeed.
  kill -STOP "$stopped_pid" 2>/dev/null \
    || { reap "$arm_pid"; fail "could not SIGSTOP the recorded watcher"; }
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  restart_case_arm --restart > "$second_out.restart" 2> "$second_err" || status=$?

  # Every assertion below that depends on the holder still existing runs while it
  # is still SIGSTOPped, so none of them can race the close path the pending stops
  # release. is_live_non_zombie already reads a stopped process as live.
  is_live_non_zombie "$stopped_pid" \
    || { resume_stopped_holder; reap "$arm_pid"; fail "the stop-proof holder was collected, so this case proves nothing about an unconfirmed stop"; }
  [ "$status" -ne 0 ] \
    || { resume_stopped_holder; reap "$arm_pid"; fail "--restart reported success while the watcher it never confirmed stopped still held the lock"; }
  ! grep -qF 'watcher: started pid=' "$second_out.restart" \
    || { resume_stopped_holder; reap "$arm_pid"; fail "--restart launched a successor after an unconfirmed stop"; }
  grep -qF 'could not confirm the recorded watcher stopped' "$second_err" \
    || { resume_stopped_holder; reap "$arm_pid"; fail "--restart did not report its uncertain stop result"; }
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$stopped_pid" ] \
    || { resume_stopped_holder; reap "$arm_pid"; fail "a second watcher took the singleton lock beside the one that was never confirmed stopped"; }

  resume_stopped_holder
  reap "$arm_pid"
  unset -f restart_case_arm resume_stopped_holder
  pass "--restart refuses uncertain stop and preserves the live recorded watcher"
}

test_restart_stop_bound_is_one_second_and_single_signal() {
  local dir state armbin siglog successor_log arm restart_arm holder successor delivered i
  dir=$(make_case restart-stop-bound-floor)
  state="$dir/state"
  siglog="$dir/holder-signals.log"
  successor_log="$dir/successor-signals.log"
  armbin=$(make_recording_watcher_bin "$dir")

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_STUB_SIGLOG="$siglog" FM_STUB_MODE=exit-on-stop \
    FM_STUB_LIB="$LIB" "$armbin/fm-watch-arm.sh" > "$dir/arm.out" 2>/dev/null &
  arm=$!
  i=0
  while [ "$i" -lt 150 ] && ! grep -qF 'watcher: started pid=' "$dir/arm.out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$dir/arm.out" \
    || { reap "$arm"; fail "the recording stand-in watcher was never confirmed by the arm"; }
  holder=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  case "$holder" in
    ''|*[!0-9]*) reap "$arm"; fail "the stand-in watcher recorded no lock pid" ;;
  esac

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_STUB_SIGLOG="$successor_log" FM_STUB_MODE=wake \
    FM_STUB_LIB="$LIB" \
    "$armbin/fm-watch-arm.sh" --restart > "$dir/restart.out" 2>/dev/null &
  restart_arm=$!
  # The relaunch is what proves the stop attempt finished, so the delivery count
  # below is read from a completed confirmation window rather than mid-flight.
  i=0
  while [ "$i" -lt 250 ] && ! grep -qF 'watcher: started pid=' "$dir/restart.out" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  successor=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF 'watcher: started pid=' "$dir/restart.out" \
    || { kill -KILL "$holder" 2>/dev/null || true; reap "$restart_arm"; reap "$arm"
         fail "--restart never relaunched, so its stop window cannot be read"; }

  delivered=$(grep -c . "$siglog" 2>/dev/null || echo 0)
  kill -KILL "$holder" 2>/dev/null || true
  case "$successor" in
    ''|*[!0-9]*) ;;
    *) [ "$successor" = "$holder" ] || kill -KILL "$successor" 2>/dev/null || true ;;
  esac
  reap "$restart_arm"
  reap "$arm"
  [ "$delivered" -eq 1 ] \
    || fail "--restart delivered its stop $delivered time(s) instead of one"
  pass "--restart uses a one-second confirmation bound and one TERM"
}

test_reap_bounds_a_signal_swallowing_watcher
test_reap_redelivers_a_dropped_stop_so_the_close_path_still_runs
test_watcher_close_path_is_not_abandoned_by_a_later_stop
test_close_path_wait_for_the_marker_lock_stays_killable
test_close_path_publishes_under_marker_lock_contention
test_normal_cycle_end_sends_the_owned_child_no_stop
test_an_unconfirmed_child_stop_is_never_the_arms_last_word
test_forced_owned_child_stop_is_reaped_and_recorded
test_restart_records_whether_its_stop_was_confirmed
test_restart_stop_bound_is_one_second_and_single_signal
test_singleton_start
test_a_zombie_is_dead_and_does_not_block_successor
test_unevaluable_proc_state_is_live_safe
test_live_unverifiable_identity_does_not_confirm_stop
test_live_missing_identity_does_not_signal
test_zero_redelivery_polls_use_default_cadence
test_pid_identity_is_locale_invariant
test_proc_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
