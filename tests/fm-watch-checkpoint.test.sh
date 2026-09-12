#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# Exercise the configured shell caller, with its real dependencies and private
# state. This does not stand in for the native model's Stop event loop.
test_configured_stop_retry_does_not_admit_unfinished_work() {
  local home command out status attempt cp deadline sequence generation
  home=$(make_home stop-retry)
  cp -R "$ROOT/bin" "$home/bin"
  cp -R "$ROOT/.codex" "$home/.codex"
  mkdir -p "$home/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$home/docs/"
  : > "$home/AGENTS.md"
  git init -q "$home"
  printf 'kind=ship\nmode=no-mistakes\n' > "$home/state/demo.meta"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$home/.codex/hooks.json")
  status=0
  out=$(cd "$home" && printf '%s' '{"stop_hook_active":true,"session_id":"private-retry"}' |
    env -i PATH="$PATH" HOME="$home" FM_HOME="$home" FM_BACKEND=tmux FM_HARNESS=codex \
      bash -c "$command" 2>&1) || status=$?
  expect_code 2 "$status" "configured Stop retry with unfinished work and no continuation owner"
  assert_contains "$out" 'CONTINUATION' 'Stop must name the missing continuation obligation'
  pass 'configured Codex Stop retry refuses unfinished work without a continuation owner'

  for attempt in 2 3 4; do
    status=0
    out=$(cd "$home" && printf '%s' '{"stop_hook_active":true,"session_id":"private-retry"}' |
      env -i PATH="$PATH" HOME="$home" FM_HOME="$home" FM_BACKEND=tmux FM_HARNESS=codex \
        bash -c "$command" 2>&1) || status=$?
    if [ "$attempt" -eq 2 ]; then
      expect_code 2 "$status" 'second bounded recovery'
    else
      expect_code 0 "$status" 'exhausted recovery must not loop indefinitely'
      assert_contains "$out" 'CONTINUATION_CNO:' 'exhaustion must never silently certify completion'
      assert_contains "$(cat "$home/state/.turnend-codex-blocks")" 'outcome=CNO' 'durable failure is required'
    fi
  done
  [ "$(grep -c 'codex-continuation-cno' "$home/state/.wake-queue")" -eq 1 ] || fail 'bounded failure must leave one durable escalation'
  assert_present "$home/state/demo.meta" 'Stop exhaustion must preserve unfinished task authority'
  FM_HOME="$home" "$home/bin/fm-wake-drain.sh" > "$home/cno-drain.out" 2> "$home/cno-drain.err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$home/cno-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$home/cno-drain.err")
  FM_HOME="$home" "$home/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null || fail 'failure handling acknowledgement'
  pass 'configured Codex Stop exhaustion is bounded and durably CNO'

  env -i PATH="$PATH" HOME="$home" FM_HOME="$home" FM_BACKEND=tmux FM_HARNESS=codex \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$home/bin/fm-watch-checkpoint.sh" --seconds 5 > "$home/checkpoint.out" 2> "$home/checkpoint.err" &
  cp=$!
  deadline=$(( $(date +%s) + 3 ))
  while [ ! -f "$home/state/.watch.lock/watcher-path" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.05; done
  [ -f "$home/state/.watch.lock/watcher-path" ] || fail 'private finite watcher never acquired its lock'
  status=0
  out=$(cd "$home" && printf '%s' '{"stop_hook_active":false,"session_id":"private-finite"}' |
    env -i PATH="$PATH" HOME="$home" FM_HOME="$home" FM_BACKEND=tmux FM_HARNESS=codex \
      bash -c "$command" 2>&1) || status=$?
  expect_code 2 "$status" 'matching live finite watcher cannot establish post-final custody'
  assert_contains "$out" 'CONTINUATION_REQUIRED:' 'finite checkpoint refusal'
  status=0; wait "$cp" || status=$?
  expect_code 124 "$status" 'private watcher must actually expire'
  pass 'configured Codex Stop rejects a real finite checkpoint as post-final custody'

  : > "$home/state/.afk"
  status=0
  out=$(cd "$home" && printf '%s' '{"stop_hook_active":true,"session_id":"private-away"}' |
    env -i PATH="$PATH" HOME="$home" FM_HOME="$home" FM_BACKEND=tmux FM_HARNESS=codex \
      bash -c "$command" 2>&1) || status=$?
  expect_code 2 "$status" 'away flag cannot establish receiver acceptance'
  pass 'configured Codex Stop refuses away mode without a verified owner'
}

test_configured_stop_retry_does_not_admit_unfinished_work
test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
