#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-commit-identity.sh.
#
# The guarantee under test: pinning a repo's no-mistakes gate mirror makes a
# commit created in a worktree off that mirror - with no GIT_AUTHOR_*/
# GIT_COMMITTER_* set, exactly as the daemon's gate agent runs - carry the
# captain identity in the real git OBJECT (author AND committer), instead of
# falling through to the operator global identity. Every case drives the script
# through its executable interface and reads the identity back off actual
# commits, never off the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-nm-commit-identity.sh"
PIN_NAME='sbracewell64'
PIN_EMAIL='301307654+sbracewell64@users.noreply.github.com'
GLOBAL_NAME='Test'
GLOBAL_EMAIL='test@example.com'

TMP_ROOT=$(fm_test_tmproot fm-nm-commit-identity)

# A fake operator global git config carrying the contaminating identity, plus a
# neutralized system config, so a commit with no user.* set anywhere else
# resolves to GLOBAL_* - the exact fall-through the fix must displace.
GLOBAL_CFG="$TMP_ROOT/global.gitconfig"
git config --file "$GLOBAL_CFG" user.name "$GLOBAL_NAME"
git config --file "$GLOBAL_CFG" user.email "$GLOBAL_EMAIL"
export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
export GIT_CONFIG_NOSYSTEM=1

# git_env: run git with the fake global in effect and NO per-process identity
# env, so identity resolution mirrors the daemon's gate agent exactly.
git_env() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_GLOBAL="$GLOBAL_CFG" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# make_mirror <nm-home> <repo-id> <origin-url>: build a bare gate mirror faithful
# to no-mistakes' own - extensions.worktreeConfig on, no core.bare in the shared
# config, no user.* - seeded with one commit on main and the given origin URL.
make_mirror() {
  local nm=$1 id=$2 url=$3 mirror seed
  mirror="$nm/repos/$id.git"
  mkdir -p "$nm/repos"
  git init -q --bare "$mirror"
  git -C "$mirror" config extensions.worktreeConfig true
  git -C "$mirror" config --unset core.bare 2>/dev/null || true
  git -C "$mirror" config remote.origin.url "$url"
  seed="$TMP_ROOT/seed-$id"
  git init -q "$seed"
  git -C "$seed" -c user.name=Seed -c user.email=seed@example.invalid commit -q --allow-empty -m init
  git -C "$seed" push -q "$mirror" HEAD:refs/heads/main
  git -C "$mirror" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$mirror"
}

# commit_identity <mirror> <label>: add a detached worktree off <mirror>, make a
# commit there with no identity env, and echo "author=<a> committer=<c>" from the
# real object.
commit_identity() {
  local mirror=$1 label=$2 wt
  wt="$TMP_ROOT/wt-$label"
  git_env -C "$mirror" worktree add -q --detach "$wt" main
  ( cd "$wt" && git_env commit -q --allow-empty -m "$label" )
  git_env -C "$wt" log -1 --format='author=%an <%ae> committer=%cn <%ce>'
}

# a checkout whose origin points at the mirror, so the helper can bind them.
make_checkout() {
  local dir=$1 url=$2
  fm_git_init_commit "$dir"
  git -C "$dir" remote add origin "$url"
}

test_pin_displaces_global_in_real_object() {
  local nm co out ident
  nm="$TMP_ROOT/nm-pin"
  make_mirror "$nm" aaaa1111 "https://example.com/org/repo.git" >/dev/null
  co="$TMP_ROOT/checkout-pin"
  make_checkout "$co" "https://example.com/org/repo.git"

  # Baseline: without the pin, a mirror worktree commit is contaminated.
  ident=$(commit_identity "$nm/repos/aaaa1111.git" baseline)
  case "$ident" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL> committer=$GLOBAL_NAME <$GLOBAL_EMAIL>") ;;
    *) fail "baseline did not reproduce the contamination: $ident" ;;
  esac

  out=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "pin exited nonzero"
  assert_contains "$out" "pinned $nm/repos/aaaa1111.git" "pin reports the mirror it pinned"

  # Proof: a FRESH worktree off the pinned mirror commits under the captain
  # identity in the real object - author AND committer.
  ident=$(commit_identity "$nm/repos/aaaa1111.git" pinned)
  [ "$ident" = "author=$PIN_NAME <$PIN_EMAIL> committer=$PIN_NAME <$PIN_EMAIL>" ] \
    || fail "pinned mirror commit identity wrong: $ident"

  pass "pin displaces the operator global in author and committer of a real commit object"
}

test_sibling_isolation_and_global_untouched() {
  local nm co_a out global_before global_after ident_b
  nm="$TMP_ROOT/nm-iso"
  make_mirror "$nm" aaaa2222 "https://example.com/org/alpha.git" >/dev/null
  make_mirror "$nm" bbbb3333 "https://example.com/org/beta.git" >/dev/null
  co_a="$TMP_ROOT/checkout-alpha"
  make_checkout "$co_a" "https://example.com/org/alpha.git"

  global_before=$(cat "$GLOBAL_CFG")
  out=$(NM_HOME="$nm" "$BIN" pin "$co_a") || fail "pin exited nonzero"
  assert_contains "$out" "pinned $nm/repos/aaaa2222.git" "pinned only alpha's mirror"
  assert_not_contains "$out" bbbb3333 "beta's mirror is not pinned"

  # The sibling repo's mirror is untouched: its worktree commit still falls
  # through to the operator global.
  ident_b=$(commit_identity "$nm/repos/bbbb3333.git" sibling)
  case "$ident_b" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL> committer=$GLOBAL_NAME <$GLOBAL_EMAIL>") ;;
    *) fail "pinning alpha leaked into beta's mirror: $ident_b" ;;
  esac

  global_after=$(cat "$GLOBAL_CFG")
  [ "$global_before" = "$global_after" ] || fail "operator global git config was modified by pin"

  pass "pin isolates to the matched mirror and never touches the operator global"
}

test_pin_is_idempotent() {
  local nm co out1 out2 ident
  nm="$TMP_ROOT/nm-idem"
  make_mirror "$nm" cccc4444 "https://example.com/org/gamma.git" >/dev/null
  co="$TMP_ROOT/checkout-gamma"
  make_checkout "$co" "https://example.com/org/gamma.git"

  out1=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "first pin exited nonzero"
  assert_contains "$out1" "pinned $nm/repos/cccc4444.git" "first pin writes"
  out2=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "second pin exited nonzero"
  assert_contains "$out2" "already-pinned $nm/repos/cccc4444.git" "second pin is a no-op report"

  ident=$(commit_identity "$nm/repos/cccc4444.git" idem)
  [ "$ident" = "author=$PIN_NAME <$PIN_EMAIL> committer=$PIN_NAME <$PIN_EMAIL>" ] \
    || fail "identity drifted after idempotent re-pin: $ident"

  pass "pin is idempotent: the second run reports already-pinned and identity holds"
}

test_url_spelling_variants_match() {
  local nm co out
  nm="$TMP_ROOT/nm-url"
  # Mirror records the .git-suffixed https URL; checkout's origin omits the
  # suffix and adds a trailing slash. Normalization must still bind them.
  make_mirror "$nm" dddd5555 "https://example.com/org/delta.git" >/dev/null
  co="$TMP_ROOT/checkout-delta"
  make_checkout "$co" "https://example.com/org/delta/"

  out=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "pin exited nonzero"
  assert_contains "$out" "pinned $nm/repos/dddd5555.git" "normalized URL variants bind to the mirror"
  pass "trailing-slash and .git URL spellings normalize to the same mirror"
}

test_noop_success_paths() {
  local nm co out
  # No repos directory in this home at all: no-op success.
  nm="$TMP_ROOT/nm-empty"
  mkdir -p "$nm"
  co="$TMP_ROOT/checkout-none"
  make_checkout "$co" "https://example.com/org/none.git"
  out=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "no-mirror pin should exit 0"
  assert_not_contains "$out" pinned "nothing is pinned when no mirror exists"

  # A mirror exists but for a different repo: the checkout binds to nothing.
  make_mirror "$nm" eeee6666 "https://example.com/org/other.git" >/dev/null
  out=$(NM_HOME="$nm" "$BIN" pin "$co") || fail "unmatched pin should exit 0"
  assert_not_contains "$out" pinned "an unmatched checkout pins nothing"

  # A checkout with no origin: no-op success.
  local noorigin="$TMP_ROOT/checkout-noorigin"
  fm_git_init_commit "$noorigin"
  out=$(NM_HOME="$nm" "$BIN" pin "$noorigin") || fail "origin-less pin should exit 0"
  assert_not_contains "$out" pinned "an origin-less checkout pins nothing"

  pass "absent mirror, unmatched origin, and origin-less checkout are all no-op successes"
}

test_bad_usage_rejected() {
  local rc
  # Unknown action, valid arity: usage error.
  rc=0; "$BIN" bogus /tmp >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "unknown action should be a usage error (got $rc)"
  # Too few args: usage error.
  rc=0; "$BIN" pin >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "missing project-dir should be a usage error (got $rc)"
  # Too many args: usage error.
  rc=0; "$BIN" pin a b >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "extra args should be a usage error (got $rc)"
  pass "bad usage is rejected with the usage exit code"
}

test_pin_displaces_global_in_real_object
test_sibling_isolation_and_global_untouched
test_pin_is_idempotent
test_url_spelling_variants_match
test_noop_success_paths
test_bad_usage_rejected

pass "fm-nm-commit-identity: all cases"
