#!/usr/bin/env bash
# Regression tests for fm-spawn's worker commit-identity pin (bin/fm-spawn.sh,
# the "export GIT_AUTHOR_* / GIT_COMMITTER_*" line sent into the worker pane
# beside GOTMPDIR).
#
# A worker worktree inherits whatever identity the operator's global git config
# carries, so its commits are authored under that identity; GitHub resolves it to
# a foreign account and a squash-merge propagates it into landed history. The fix
# pins the captain-decided identity per-process at the launch seam. These tests
# drive the real spawn path with a fake terminal that captures what fm-spawn sends
# into the pane, then prove the EFFECTIVE commit object - author AND committer, via
# `git var` and `git log`, not a trailer or grep - resolves to the pinned identity
# and never the ambient global, for every worker delivery kind.
#
# Hermetic: the ambient git global is redirected to a disposable file, so the test
# both proves the pin overrides an arbitrary global regardless of the host machine
# and never reads or writes the operator's own global config.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-commit-identity)

# The captain-decided identity fm-spawn is expected to pin. Kept here as literal
# expected values (never sourced from the implementation) so the assertion is an
# independent contract, not a mirror of the source.
PINNED_NAME='sbracewell64'
PINNED_EMAIL='301307654+sbracewell64@users.noreply.github.com'

# Disposable ambient global git identity for the whole test. Redirecting
# GIT_CONFIG_GLOBAL keeps every git invocation - the spawn subprocess and the
# verification commits alike - off the operator's real global, and stands in for
# the contaminating identity a fresh worktree would otherwise inherit.
export GIT_CONFIG_SYSTEM=/dev/null
DISPOSABLE_GLOBAL="$TMP_ROOT/disposable-global-gitconfig"
CONTAMINATING_NAME='Disposable Global'
CONTAMINATING_EMAIL='disposable-global@example.invalid'
mkdir -p "$TMP_ROOT"
printf '[user]\n\tname = %s\n\temail = %s\n' "$CONTAMINATING_NAME" "$CONTAMINATING_EMAIL" > "$DISPOSABLE_GLOBAL"
export GIT_CONFIG_GLOBAL="$DISPOSABLE_GLOBAL"

# Fake tmux: answers the pane-path query with the settled worktree and logs the
# text payload of every send-keys form - the launch literal (`-l <text>`) and a
# text line (`<text> Enter`) - one per line, in order, so the identity export the
# spawn seam sends can be read back.
make_capturing_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse codex
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_capturing_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

# The exact export line fm-spawn sent, e.g.
#   export GIT_AUTHOR_NAME='...' GIT_AUTHOR_EMAIL='...' GIT_COMMITTER_NAME='...' ...
identity_export_line() {
  grep -m1 '^export GIT_AUTHOR_NAME=' "$1" || true
}

# Prove the EFFECTIVE identity the exported env produces is the pinned identity
# and not the ambient global: apply the exact exported line in a hermetic repo,
# read git var (which accounts for env overrides), make a commit, and inspect the
# commit object's author and committer.
assert_effective_identity_pinned() {  # <export-line> <label>
  local exportline=$1 label=$2 repo an ae cn ce author_ident committer_ident
  repo="$TMP_ROOT/verify-$label"
  git init -q "$repo"
  (
    cd "$repo" || exit 1
    eval "$exportline"
    git var GIT_AUTHOR_IDENT > "$repo/.author-ident"
    git var GIT_COMMITTER_IDENT > "$repo/.committer-ident"
    git commit -q --allow-empty -m probe
  ) || fail "$label: could not build the effective-identity probe commit"

  author_ident=$(cat "$repo/.author-ident")
  committer_ident=$(cat "$repo/.committer-ident")
  assert_contains "$author_ident" "$PINNED_NAME <$PINNED_EMAIL>" \
    "$label: git var GIT_AUTHOR_IDENT did not resolve to the pinned identity"
  assert_contains "$committer_ident" "$PINNED_NAME <$PINNED_EMAIL>" \
    "$label: git var GIT_COMMITTER_IDENT did not resolve to the pinned identity"

  an=$(git -C "$repo" log -1 --format='%an')
  ae=$(git -C "$repo" log -1 --format='%ae')
  cn=$(git -C "$repo" log -1 --format='%cn')
  ce=$(git -C "$repo" log -1 --format='%ce')
  [ "$an" = "$PINNED_NAME" ] || fail "$label: commit author name is '$an', not the pinned identity"
  [ "$ae" = "$PINNED_EMAIL" ] || fail "$label: commit author email is '$ae', not the pinned identity"
  [ "$cn" = "$PINNED_NAME" ] || fail "$label: commit committer name is '$cn', not the pinned identity"
  [ "$ce" = "$PINNED_EMAIL" ] || fail "$label: commit committer email is '$ce', not the pinned identity"
  # The pin must OVERRIDE the ambient global, not merely coincide with it.
  [ "$ae" != "$CONTAMINATING_EMAIL" ] || fail "$label: commit inherited the ambient global identity instead of the pinned one"
  [ "$ce" != "$CONTAMINATING_EMAIL" ] || fail "$label: committer inherited the ambient global identity instead of the pinned one"
}

# Sanity guard for the red state: with no pin, a fresh worktree inheriting the
# disposable global would author commits under it, proving the fixture actually
# reproduces the contamination the fix removes.
test_fixture_reproduces_contamination_without_the_pin() {
  local repo ae
  repo="$TMP_ROOT/baseline-contamination"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m probe
  ae=$(git -C "$repo" log -1 --format='%ae')
  [ "$ae" = "$CONTAMINATING_EMAIL" ] \
    || fail "fixture did not reproduce the inherited-global contamination (author email '$ae')"
  pass "a worktree with no pin authors commits under the ambient global - the contamination the fix removes"
}

test_worker_delivery_kinds_pin_the_commit_identity() {
  local rec id out status line contract
  for contract in no-mistakes direct-PR scout; do
    id="commit-identity-${contract}-r1"
    rec=$(make_case "$contract" "$id")
    read_case "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode "$contract" --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should succeed"
    assert_contains "$out" "spawned $id" "$contract spawn did not report success"
    line=$(identity_export_line "$LAUNCH_LOG")
    [ -n "$line" ] \
      || fail "$contract spawn did not pin the worker commit identity (no GIT_AUTHOR_* export reached the worker)"
    assert_effective_identity_pinned "$line" "$contract"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s export: %s\n' "$contract" "$line"
      printf '# observed %s author-ident: %s\n' "$contract" "$(cat "$TMP_ROOT/verify-$contract/.author-ident")"
    fi
  done
  pass "ship, direct-PR, and scout workers each launch with the pinned commit identity in the effective author and committer"
}

test_fixture_reproduces_contamination_without_the_pin
test_worker_delivery_kinds_pin_the_commit_identity

echo "# all fm-spawn-commit-identity tests passed"
