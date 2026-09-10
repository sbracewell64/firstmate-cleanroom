#!/usr/bin/env bash
# Execute the real spawn command in a shell whose PATH differs from the caller.
# The fake backend and clients isolate process routing, without a model call.
set -u
# shellcheck source=tests/lib.sh
. "/home/shane/.firstmate-cleanroom/no-mistakes/worktrees/56044c3a23d6/01M25GW8NWG020TTNBBH3P7MPB/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-codex)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_case() {
  local kind=$1 w home target fakebin selected old id out rc
  w="$TMP_ROOT/$kind"; home="$w/home"; target="$w/target"
  id="codex-path-$kind-$$"
  fakebin=$(fm_fakebin "$w")
  selected="$w/selected client"; old="$w/old-client"
  [ "$kind" != raw ] || selected="$w/selected-client"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$selected" "$old"
  printf 'brief bytes\n' > "$home/data/$id/brief.md"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$target/bin" "$target/data"
    printf '# Firstmate\n' > "$target/AGENTS.md"
    printf '%s\n' "$id" > "$target/.fm-secondmate-home"
    printf 'charter bytes\n' > "$target/data/charter.md"
  else
    fm_git_worktree "$target" "$w/worktree" test-worker
  fi
  cat > "$selected/codex" <<'CLIENT'
#!/usr/bin/env bash
printf 'selected\n' > "$FM_CODEX_TEST_RECEIPT"
printf '%s\n' "$@" >> "$FM_CODEX_TEST_RECEIPT"
CLIENT
  cat > "$old/codex" <<'CLIENT'
#!/usr/bin/env bash
printf 'stale client\n' > "$FM_CODEX_TEST_RECEIPT"
exit 1
CLIENT
  cat > "$fakebin/tmux" <<'BACKEND'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CODEX_TEST_BACKEND_LOG"
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_CODEX_TEST_WORKTREE"; exit 0 ;;
esac
case "$1" in
  display-message) printf 'firstmate\n' ;;
  send-keys)
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then
        case "$arg" in
          *--dangerously-bypass-approvals-and-sandbox*)
            PATH="$FM_CODEX_TEST_PANE_PATH" bash -c "$arg"
            exit $? ;;
        esac
      fi
      previous=$arg
    done ;;
esac
exit 0
BACKEND
  chmod +x "$selected/codex" "$old/codex" "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  [ "$kind" != missing ] || rm "$selected/codex"
  local harness=codex
  if [ "$kind" = raw ]; then
    # A raw caller owns its command, including executable and profile posture.
    harness="$selected/codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\""
  fi
  local args=("$id" "$target" --harness "$harness" --model test-model --effort high)
  if [ "$kind" = secondmate ]; then args+=(--secondmate); else args+=(--scout); fi
  rc=0
  out=$(PATH="$selected:$fakebin:$BASE_PATH" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    FM_CODEX_TEST_WORKTREE="$w/worktree" FM_CODEX_TEST_PANE_PATH="$old:$BASE_PATH" \
    FM_CODEX_TEST_BACKEND_LOG="$w/backend.log" FM_CODEX_TEST_RECEIPT="$w/receipt" "$ROOT/bin/fm-spawn.sh" "${args[@]}" 2>&1) || rc=$?
  if [ "$kind" = missing ]; then
    expect_code 1 "$rc" "missing client refuses before endpoint creation"
    assert_contains "$out" "codex executable not found on caller PATH" "missing client refusal lost its cause"
    assert_absent "$home/state/$id.meta" "missing client created a task record"
    assert_absent "$w/receipt" "missing client ran a pane fallback"
    [ ! -f "$w/backend.log" ] || assert_no_grep 'new-window' "$w/backend.log" "missing client created an endpoint"
    printf "%s\n" "$out"
    pass "missing caller client refuses without a pane fallback"
    return
  fi
  [ "$(head -1 "$w/receipt" 2>/dev/null)" = selected ] \
    || fail "$kind: stale pane PATH replaced caller-selected client (spawn=$rc): $out"
  printf "\n%s client invocation receipt:\n" "$kind"
  cat "$w/receipt"
  expect_code 0 "$rc" "$kind selected client launch"
  assert_grep 'test-model' "$w/receipt" "$kind lost model selection"
  assert_grep 'model_reasoning_effort="high"' "$w/receipt" "$kind lost effort selection"
  assert_grep 'FIRSTMATE_OP: v1 launch-brief:' "$w/receipt" "$kind lost brief routing"
  rm -rf "/tmp/fm-$id"
  pass "$kind executes the caller-selected Codex despite a stale pane PATH"
}
run_case scout
run_case secondmate
run_case missing
run_case raw
