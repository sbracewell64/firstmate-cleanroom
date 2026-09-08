#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-commit-identity.sh.
#
# The guarantee under test, proven off real git OBJECTS and real git identity
# resolution (never source bytes): pinning a repo's no-mistakes gate mirror makes
# a commit created in a worktree off that mirror - with no GIT_AUTHOR_*/
# GIT_COMMITTER_* set, exactly as the daemon's gate agent runs - carry the
# captain identity, and the helper FAILS CLOSED with typed outcomes when it
# cannot confirm that: MISSING (no mirror), AMBIGUOUS (conflicting exact
# bindings), WRITE_FAILED (lost write), UNVERIFIED (config.worktree override or
# effective-identity mismatch). Each case is one of the four reviewer
# counterexamples or a required property (author preservation, idempotency).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-nm-commit-identity.sh"
PIN_NAME='sbracewell64'
PIN_EMAIL='301307654+sbracewell64@users.noreply.github.com'
GLOBAL_NAME='Test'
GLOBAL_EMAIL='test@example.com'

TMP_ROOT=$(fm_test_tmproot fm-nm-commit-identity)

# Fake operator global carrying the contaminating identity; system config off.
GLOBAL_CFG="$TMP_ROOT/global.gitconfig"
git config --file "$GLOBAL_CFG" user.name "$GLOBAL_NAME"
git config --file "$GLOBAL_CFG" user.email "$GLOBAL_EMAIL"
export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
export GIT_CONFIG_NOSYSTEM=1
# Never let the harness's own identity env leak into resolution.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# Default: no daemon gate line (resolver falls back to the deterministic mirror).
export FM_NM_GATE_CMD='true'

git_env() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_GLOBAL="$GLOBAL_CFG" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# make_mirror <dir> <origin-url>: a bare gate mirror faithful to no-mistakes' own
# (worktreeConfig on, no core.bare, no user.*), seeded with one commit on main.
make_mirror() {
  local mirror=$1 url=$2 seed
  mkdir -p "$(dirname "$mirror")"
  git init -q --bare "$mirror"
  git -C "$mirror" config extensions.worktreeConfig true
  git -C "$mirror" config --unset core.bare 2>/dev/null || true
  git -C "$mirror" config remote.origin.url "$url"
  seed="$TMP_ROOT/seed-$(basename "$mirror").$RANDOM"
  git init -q "$seed"
  git -C "$seed" -c user.name=Seed -c user.email=seed@example.invalid commit -q --allow-empty -m init
  git -C "$seed" push -q "$mirror" HEAD:refs/heads/main
  git -C "$mirror" symbolic-ref HEAD refs/heads/main
}

# real_commit_identity <mirror> <label>: add a detached worktree off <mirror>,
# commit there with no identity env, echo "author=<a> committer=<c>" per OBJECT.
real_commit_identity() {
  local mirror=$1 label=$2 wt
  wt="$TMP_ROOT/wt-$label.$RANDOM"
  git_env -C "$mirror" worktree add -q --detach "$wt" main
  ( cd "$wt" && git_env commit -q --allow-empty -m "$label" )
  git_env -C "$wt" log -1 --format='author=%an <%ae> committer=%cn <%ce>'
}

# a git checkout whose origin points at <url>.
make_checkout() {
  local dir=$1 url=$2
  fm_git_init_commit "$dir"
  git -C "$dir" remote add origin "$url"
}

# the mirror path the helper derives for a repo checkout under an NM_HOME.
derived_mirror() {
  local nm=$1 repo=$2 top id
  top=$(cd "$repo" && git rev-parse --show-toplevel)
  top=$(cd "$top" && pwd -P)
  id=$(printf '%s' "$top" | sha256sum | cut -c1-12)
  printf '%s/repos/%s.git' "$nm" "$id"
}

run() { "$BIN" "$@"; }   # returns exit code; caller captures stdout separately

# ---------------------------------------------------------------------------

test_pin_displaces_global_in_real_object() {
  local mirror out ident
  mirror="$TMP_ROOT/nm-pos/repos/pos.git"
  make_mirror "$mirror" "https://example.com/org/pos.git"

  ident=$(real_commit_identity "$mirror" baseline)
  case "$ident" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL> committer=$GLOBAL_NAME <$GLOBAL_EMAIL>") ;;
    *) fail "baseline did not reproduce the contamination: $ident" ;;
  esac

  out=$(run pin --mirror "$mirror") || fail "pin exited nonzero: $out"
  assert_contains "$out" "OK $mirror" "pin reports OK for the pinned mirror"
  assert_contains "$out" "verified=" "pin reports the verified contexts"

  ident=$(real_commit_identity "$mirror" pinned)
  [ "$ident" = "author=$PIN_NAME <$PIN_EMAIL> committer=$PIN_NAME <$PIN_EMAIL>" ] \
    || fail "pinned mirror commit identity wrong: $ident"
  pass "pin displaces the operator global in author and committer of a real commit object"
}

test_ce1_missing_is_typed_not_silent_success() {
  local nm co out rc
  # Reviewer CE1: pinning before the mirror exists must NOT return success.
  nm="$TMP_ROOT/nm-ce1"; mkdir -p "$nm"
  co="$TMP_ROOT/co-ce1"
  make_checkout "$co" "https://example.com/org/ce1.git"   # gate mirror never created
  out=$(run pin --repo "$co" --nm-home "$nm"); rc=$?
  [ "$rc" -eq 3 ] || fail "missing mirror must exit 3 (MISSING), got $rc: $out"
  assert_contains "$out" "MISSING" "absent mirror yields a typed MISSING outcome"
  assert_not_contains "$out" "OK " "MISSING must never read as success"

  # An explicit --mirror that does not exist is also MISSING.
  out=$(run pin --mirror "$nm/repos/nope.git"); rc=$?
  [ "$rc" -eq 3 ] || fail "nonexistent --mirror must exit 3, got $rc: $out"
  pass "CE1: no mirror to pin returns a typed MISSING (exit 3), never silent success"
}

test_ce2_write_failure_is_typed_and_not_pinned() {
  local mirror out rc ident
  # Reviewer CE2: a locked config must surface WRITE_FAILED, never a warning+0.
  mirror="$TMP_ROOT/nm-ce2/repos/ce2.git"
  make_mirror "$mirror" "https://example.com/org/ce2.git"
  : > "$mirror/config.lock"   # git config refuses to write while the lock exists
  out=$(run pin --mirror "$mirror"); rc=$?
  rm -f "$mirror/config.lock"
  [ "$rc" -eq 5 ] || fail "a blocked config write must exit 5 (WRITE_FAILED), got $rc: $out"
  assert_contains "$out" "WRITE_FAILED" "locked write yields a typed WRITE_FAILED outcome"
  assert_not_contains "$out" "OK " "WRITE_FAILED must never read as success"

  # And the identity really did NOT get pinned - a real commit is still Test.
  ident=$(real_commit_identity "$mirror" afterlock)
  case "$ident" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL>"*) ;;
    *) fail "write reportedly failed yet identity changed: $ident" ;;
  esac
  pass "CE2: a blocked config write returns WRITE_FAILED (exit 5) and does not falsely pin"
}

test_ce3_worktree_override_fails_closed() {
  local mirror out rc wt ident
  # Reviewer CE3: config.worktree user.* OVERRIDES the shared pin; the helper
  # must detect it and fail closed rather than claim success.
  mirror="$TMP_ROOT/nm-ce3/repos/ce3.git"
  make_mirror "$mirror" "https://example.com/org/ce3.git"
  out=$(run pin --mirror "$mirror") || fail "initial pin failed: $out"
  assert_contains "$out" "OK " "shared pin succeeds before any override"

  # A live worktree with a config.worktree identity override.
  wt="$TMP_ROOT/wt-ce3"
  git_env -C "$mirror" worktree add -q --detach "$wt" main
  git_env -C "$wt" config --worktree user.name Hijack
  git_env -C "$wt" config --worktree user.email hijack@example.com

  # The hazard is real: a commit in that worktree carries the override.
  ident=$( ( cd "$wt" && git_env commit -q --allow-empty -m ov && git_env log -1 --format='%an <%ae>' ) )
  [ "$ident" = "Hijack <hijack@example.com>" ] || fail "override hazard not reproduced: $ident"

  out=$(run verify --mirror "$mirror"); rc=$?
  [ "$rc" -eq 6 ] || fail "a config.worktree override must exit 6 (UNVERIFIED), got $rc: $out"
  assert_contains "$out" "UNVERIFIED" "worktree override yields a typed UNVERIFIED outcome"
  assert_not_contains "$out" "OK " "UNVERIFIED must never read as success"
  pass "CE3: a config.worktree override is detected and fails closed (UNVERIFIED, exit 6)"
}

test_ce4_exact_binding_no_fuzzy_multi_mutation() {
  local nm co m1 m2 out rc ident2
  # Reviewer CE4: same origin must NOT cause two mirrors to be mutated; binding
  # is exact (declared --mirror, or the repo-path-derived mirror), never origin.
  nm="$TMP_ROOT/nm-ce4"
  co="$TMP_ROOT/co-ce4"
  make_checkout "$co" "https://example.com/org/shared-origin.git"
  m1=$(derived_mirror "$nm" "$co")
  make_mirror "$m1" "https://example.com/org/shared-origin.git"
  m2="$nm/repos/sibling.git"                       # same origin, different mirror
  make_mirror "$m2" "https://example.com/org/shared-origin.git"

  out=$(run pin --repo "$co" --nm-home "$nm") || fail "pin --repo failed: $out"
  assert_contains "$out" "OK $m1" "repo binds to its exact derived mirror"

  # The sibling with the SAME origin is untouched: its real commit stays Test.
  ident2=$(real_commit_identity "$m2" sibling)
  case "$ident2" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL>"*) ;;
    *) fail "pinning one mirror leaked into a same-origin sibling: $ident2" ;;
  esac

  # AMBIGUOUS: when the daemon's declared gate and the derived mirror both exist
  # and disagree, refuse rather than guess.
  export FM_NM_GATE_CMD="printf 'gate:  %s\n' $m2"
  out=$(run pin --repo "$co" --nm-home "$nm"); rc=$?
  export FM_NM_GATE_CMD='true'
  [ "$rc" -eq 4 ] || fail "conflicting exact bindings must exit 4 (AMBIGUOUS), got $rc: $out"
  assert_contains "$out" "AMBIGUOUS" "conflicting bindings yield a typed AMBIGUOUS outcome"
  pass "CE4: binding is exact per repo; a same-origin sibling is untouched and conflicts are AMBIGUOUS"
}

test_authoritative_gate_resolution() {
  local nm co mauth out
  # When the daemon declares a gate, it is authoritative over the derived path.
  nm="$TMP_ROOT/nm-auth"
  co="$TMP_ROOT/co-auth"
  make_checkout "$co" "https://example.com/org/auth.git"
  mauth="$nm/repos/authoritative.git"             # NOT the derived path
  make_mirror "$mauth" "https://example.com/org/auth.git"
  export FM_NM_GATE_CMD="printf 'gate:  %s\n' $mauth"
  out=$(run pin --repo "$co" --nm-home "$nm") || fail "authoritative pin failed: $out"
  export FM_NM_GATE_CMD='true'
  assert_contains "$out" "OK $mauth" "the daemon's declared gate is used when the derived mirror is absent"
  pass "resolution uses the daemon's authoritative gate path when present"
}

test_rebase_preserves_authors() {
  local mirror wt
  # Required property: pinning must not rewrite authorship. A rebase preserves
  # the ORIGINAL author of every replayed commit (only the committer becomes the
  # pin) and leaves unrelated upstream commits entirely untouched.
  mirror="$TMP_ROOT/nm-reb/repos/reb.git"
  make_mirror "$mirror" "https://example.com/org/reb.git"
  run pin --mirror "$mirror" >/dev/null || fail "pin failed"
  wt="$TMP_ROOT/wt-reb"
  git_env -C "$mirror" worktree add -q "$wt" -b feature main
  # An upstream commit authored by someone else, then a base advance.
  ( cd "$wt"
    git_env commit -q --allow-empty --author "Upstream Dev <up@example.com>" -m upstream-work
    upstream_sha=$(git_env rev-parse HEAD)
    git_env checkout -q -b newbase main
    git_env commit -q --allow-empty --author "Base Owner <base@example.com>" -m base-advance
    base_author=$(git_env log -1 --format='%an <%ae>')
    git_env checkout -q feature
    git_env rebase -q newbase
    replayed_author=$(git_env log -1 --format='%an <%ae>')
    replayed_committer=$(git_env log -1 --format='%cn <%ce>')
    [ "$replayed_author" = "Upstream Dev <up@example.com>" ] \
      || { echo "rebase rewrote a replayed commit's author: $replayed_author" >&2; exit 1; }
    [ "$replayed_committer" = "$PIN_NAME <$PIN_EMAIL>" ] \
      || { echo "replayed committer not the pin: $replayed_committer" >&2; exit 1; }
    # The unrelated base commit keeps its own author untouched.
    [ "$base_author" = "Base Owner <base@example.com>" ] \
      || { echo "unrelated base author changed: $base_author" >&2; exit 1; }
    : "$upstream_sha"
  ) || fail "author preservation check failed"
  pass "pin preserves original authors on rebase; only the replayed committer becomes the pin"
}

test_idempotent() {
  local mirror out1 out2 ident
  mirror="$TMP_ROOT/nm-idem/repos/idem.git"
  make_mirror "$mirror" "https://example.com/org/idem.git"
  out1=$(run pin --mirror "$mirror") || fail "first pin failed: $out1"
  out2=$(run pin --mirror "$mirror") || fail "second pin failed: $out2"
  assert_contains "$out1" "OK " "first pin OK"
  assert_contains "$out2" "OK " "second pin OK"
  ident=$(real_commit_identity "$mirror" idem)
  [ "$ident" = "author=$PIN_NAME <$PIN_EMAIL> committer=$PIN_NAME <$PIN_EMAIL>" ] \
    || fail "identity drifted after idempotent re-pin: $ident"
  pass "pin is idempotent: repeated pins stay OK and the identity holds"
}

test_operator_global_untouched() {
  local mirror before after
  mirror="$TMP_ROOT/nm-glob/repos/glob.git"
  make_mirror "$mirror" "https://example.com/org/glob.git"
  before=$(cat "$GLOBAL_CFG")
  run pin --mirror "$mirror" >/dev/null || fail "pin failed"
  after=$(cat "$GLOBAL_CFG")
  [ "$before" = "$after" ] || fail "operator global git config was modified by pin"
  pass "pin never modifies the operator global git config"
}

test_ce5_unreadable_worktree_identity_fails_closed() {
  local mirror out rc wt
  # Reviewer CE5: a live worktree whose git var read fails (empty user.name ->
  # git var exits 128) must be UNVERIFIED, never silently dropped as OK.
  mirror="$TMP_ROOT/nm-ce5/repos/ce5.git"
  make_mirror "$mirror" "https://example.com/org/ce5.git"
  run pin --mirror "$mirror" >/dev/null || fail "initial pin failed"
  wt="$TMP_ROOT/wt-ce5"
  git_env -C "$mirror" worktree add -q --detach "$wt" main
  git_env -C "$wt" config --worktree user.name ""   # empty -> git var fails 128
  # Confirm the hazard: git var really cannot resolve an identity here.
  ( cd "$wt" && git_env var GIT_AUTHOR_IDENT >/dev/null 2>&1 ) \
    && fail "expected git var to fail on an empty user.name"
  out=$(run verify --mirror "$mirror"); rc=$?
  [ "$rc" -eq 6 ] || fail "an unreadable worktree identity must exit 6 (UNVERIFIED), got $rc: $out"
  assert_contains "$out" "UNVERIFIED" "unreadable identity yields UNVERIFIED"
  assert_not_contains "$out" "OK " "a failed read must never certify as OK"
  pass "CE5: an unreadable live-worktree identity fails closed (UNVERIFIED, exit 6)"
}

test_ce6_failed_vendor_never_pins_outside_nm_home() {
  local nm co outside out rc
  # Reviewer CE6: a vendor status that exits nonzero while printing a gate path
  # OUTSIDE the declared NM_HOME must NOT be trusted, and no foreign mirror is
  # ever pinned.
  nm="$TMP_ROOT/nm-ce6"; mkdir -p "$nm/repos"
  outside="$TMP_ROOT/outside-ce6/other.git"
  make_mirror "$outside" "https://example.com/org/ce6.git"
  co="$TMP_ROOT/co-ce6"
  make_checkout "$co" "https://example.com/org/ce6.git"
  export FM_NM_GATE_CMD="printf 'gate:  $outside\n'; exit 7"
  out=$(run pin --repo "$co" --nm-home "$nm"); rc=$?
  export FM_NM_GATE_CMD='true'
  [ "$rc" -ne 0 ] || fail "a failed vendor status pointing outside NM_HOME must not succeed: $out"
  # The foreign mirror was never pinned - a real commit there is still Test.
  case "$(real_commit_identity "$outside" ce6)" in
    "author=$GLOBAL_NAME <$GLOBAL_EMAIL>"*) ;;
    *) fail "the outside mirror was mutated despite the failed binding" ;;
  esac
  # Even a SUCCESSFUL vendor status pointing outside the declared repos dir is
  # rejected as AMBIGUOUS rather than pinning a foreign mirror.
  export FM_NM_GATE_CMD="printf 'gate:  $outside\n'"
  out=$(run pin --repo "$co" --nm-home "$nm"); rc=$?
  export FM_NM_GATE_CMD='true'
  [ "$rc" -eq 4 ] || fail "a gate outside the declared repos dir must exit 4 (AMBIGUOUS), got $rc: $out"
  assert_contains "$out" "AMBIGUOUS" "an out-of-home gate is AMBIGUOUS"
  pass "CE6: a failed or out-of-home vendor gate never pins a mirror outside the declared NM_HOME"
}

test_bad_usage() {
  local rc
  rc=0; run bogus --repo /tmp >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown action should exit 2, got $rc"
  rc=0; run pin >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "missing --repo/--mirror should exit 2, got $rc"
  rc=0; run verify --repo >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "dangling --repo value should exit 2, got $rc"
  pass "bad usage is rejected with the usage exit code"
}

test_pin_displaces_global_in_real_object
test_ce1_missing_is_typed_not_silent_success
test_ce2_write_failure_is_typed_and_not_pinned
test_ce3_worktree_override_fails_closed
test_ce4_exact_binding_no_fuzzy_multi_mutation
test_authoritative_gate_resolution
test_ce5_unreadable_worktree_identity_fails_closed
test_ce6_failed_vendor_never_pins_outside_nm_home
test_rebase_preserves_authors
test_idempotent
test_operator_global_untouched
test_bad_usage

pass "fm-nm-commit-identity: all cases"
