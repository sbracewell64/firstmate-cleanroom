#!/usr/bin/env bash
# Behavior tests for bin/fm-commit-identity-verify.sh - the consumption half of
# the durable commit-identity obligation. Every case drives the executable and
# reads real git OBJECTS in a range; none assert source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-commit-identity-verify.sh"
PIN_NAME='sbracewell64'
PIN_EMAIL='301307654+sbracewell64@users.noreply.github.com'

TMP_ROOT=$(fm_test_tmproot fm-commit-identity-verify)
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP_ROOT/global.gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

# commit <repo> <name> <email> <subject>
commit() {
  git -C "$1" -c user.name="$2" -c user.email="$3" commit -q --allow-empty -m "$4"
}

new_repo() {
  local r=$1
  git init -q "$r"
  commit "$r" Base base@example.invalid base-commit
}

test_ok_when_pipeline_commits_pinned_and_others_ignored() {
  local r base out
  r="$TMP_ROOT/ok"; new_repo "$r"; base=$(git -C "$r" rev-parse HEAD)
  # An unrelated upstream author, a worker commit, and a pinned pipeline commit.
  commit "$r" "Upstream Dev" up@example.com "feat: upstream change"
  commit "$r" "$PIN_NAME" "$PIN_EMAIL" "no-mistakes(review): pinned pipeline fix"
  commit "$r" "Some Worker" worker@example.com "fix: a worker commit"
  out=$("$BIN" --repo "$r" --base "$base" --head HEAD --name "$PIN_NAME" --email "$PIN_EMAIL") \
    || fail "clean pipeline commits should verify OK: $out"
  assert_contains "$out" "OK 1 pipeline" "only the one pipeline commit is counted"
  pass "OK: a pinned pipeline commit passes while worker and upstream commits are ignored"
}

test_contaminated_pipeline_commit_fails() {
  local r base out rc
  r="$TMP_ROOT/bad"; new_repo "$r"; base=$(git -C "$r" rev-parse HEAD)
  commit "$r" "$PIN_NAME" "$PIN_EMAIL" "no-mistakes(review): pinned"
  commit "$r" Test test@example.com "no-mistakes(document): contaminated"
  out=$("$BIN" --repo "$r" --base "$base" --head HEAD --name "$PIN_NAME" --email "$PIN_EMAIL"); rc=$?
  [ "$rc" -eq 7 ] || fail "a contaminated pipeline commit must exit 7 (CONTAMINATED), got $rc: $out"
  assert_contains "$out" "CONTAMINATED" "a contaminated pipeline commit is reported"
  assert_contains "$out" "Test <test@example.com>" "the offending identity is named"
  pass "CONTAMINATED: a Test-authored pipeline commit fails closed (exit 7)"
}

test_worker_or_upstream_contamination_is_not_flagged() {
  local r base out
  # A non-pipeline commit that is NOT the pin must NOT be flagged - the check is
  # scoped to pipeline commits, so it never false-positives on legitimate
  # worker, upstream, or forge identities.
  r="$TMP_ROOT/scope"; new_repo "$r"; base=$(git -C "$r" rev-parse HEAD)
  commit "$r" "GitHub" noreply@github.com "feat: a squash-style commit"
  commit "$r" "Someone Else" else@example.com "chore: external"
  out=$("$BIN" --repo "$r" --base "$base" --head HEAD --name "$PIN_NAME" --email "$PIN_EMAIL") \
    || fail "non-pipeline commits must not be flagged: $out"
  assert_contains "$out" "OK 0 pipeline" "no pipeline commit in range means nothing to enforce"
  pass "scoping: non-pipeline commits of any identity are never flagged"
}

test_obligation_file_supplies_identity() {
  local r base obl out
  r="$TMP_ROOT/obl"; new_repo "$r"; base=$(git -C "$r" rev-parse HEAD)
  commit "$r" Test test@example.com "no-mistakes(document): contaminated"
  obl="$TMP_ROOT/obligation"
  printf 'name=%s\nemail=%s\n' "$PIN_NAME" "$PIN_EMAIL" > "$obl"
  out=$("$BIN" --repo "$r" --base "$base" --head HEAD --obligation "$obl"); [ "$?" -eq 7 ] \
    || fail "the obligation file's identity should drive the check: $out"
  assert_contains "$out" "CONTAMINATED" "obligation-driven check catches contamination"
  pass "the durable obligation file supplies the required identity"
}

test_unreadable_range_is_typed() {
  local r out rc
  r="$TMP_ROOT/range"; new_repo "$r"
  out=$("$BIN" --repo "$r" --base deadbeef --head HEAD --name "$PIN_NAME" --email "$PIN_EMAIL"); rc=$?
  [ "$rc" -eq 3 ] || fail "an unresolvable base must exit 3 (RANGE_UNREADABLE), got $rc: $out"
  assert_contains "$out" "RANGE_UNREADABLE" "a bad ref is a typed range failure"
  pass "an unresolvable commit range is a typed RANGE_UNREADABLE"
}

test_bad_usage() {
  local rc
  rc=0; "$BIN" --repo /tmp --base a >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "missing --head should exit 2, got $rc"
  rc=0; "$BIN" --repo /tmp --base a --head b >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "missing identity source should exit 2, got $rc"
  pass "bad usage is rejected with the usage exit code"
}

test_git_log_failure_is_not_empty_success() {
  local r base out rc real_git fakebin
  r="$TMP_ROOT/log-failure"; new_repo "$r"; base=$(git -C "$r" rev-parse HEAD)
  commit "$r" Test test@example.com "no-mistakes(document): contaminated"
  real_git=$(command -v git)
  fakebin="$TMP_ROOT/log-failure-bin"; mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg do
  if [ "$arg" = log ]; then
    printf 'fatal: fixture traversal failed\n' >&2
    exit 7
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" "$BIN" --repo "$r" --base "$base" --head HEAD --name "$PIN_NAME" --email "$PIN_EMAIL"); rc=$?
  [ "$rc" -eq 3 ] || fail "failed traversal must be RANGE_UNREADABLE, got $rc: $out"
  assert_contains "$out" "RANGE_UNREADABLE" "failed traversal is unavailable evidence"
  pass "git log failure cannot become OK zero commits"
}

test_git_log_failure_is_not_empty_success
test_ok_when_pipeline_commits_pinned_and_others_ignored
test_contaminated_pipeline_commit_fails
test_worker_or_upstream_contamination_is_not_flagged
test_obligation_file_supplies_identity
test_unreadable_range_is_typed
test_bad_usage

pass "fm-commit-identity-verify: all cases"
