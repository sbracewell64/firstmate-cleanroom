#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, bounded concurrency, budgets, timing
# markers, JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-documentation-audiences.test.sh \
    fm-test-isolation-proof.test.sh \
    fm-test-run.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-harness-adapter-instructions-live-e2e.test.sh \
    fm-harness-adapter-references.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-procevent-quota.test.sh \
    fm-quota-choose.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-control-herdr-smoke.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-control-lib.sh"
  : >"$repo/bin/fm-timeout-lib.sh"
  : >"$repo/bin/fm-procevent-quota.sh"
  : >"$repo/bin/fm-quota-axi-lib.sh"
  : >"$repo/bin/fm-quota-choose.sh"
  : >"$repo/bin/unmapped-source.sh"
  # A shared helper with no curated family of its own, named by exactly ONE
  # script of the expensive real-Herdr family and consumed by one curated
  # watcher script. This is the shape that made a one-line helper change select
  # every real-Herdr E2E.
  : >"$repo/bin/shared-probe-lib.sh"
  printf '# shared-probe-lib.sh\n' >>"$repo/tests/fm-backend-herdr-smoke.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: the reference must reach
  # the file verbatim so the changed-file scan can find it, not expand here.
  printf '. "$ROOT/bin/shared-probe-lib.sh"\n' >"$repo/bin/fm-watch-probe.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p \
    "$repo/.agents/skills/example" \
    "$repo/.agents/skills/harness-adapters/references/common" \
    "$repo/.claude" "$repo/.pi/extensions" "$repo/docs" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/docs/fm-test-isolation-proof.md"
  : >"$repo/CONTRIBUTING.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_runner_surfaces_select_their_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-owner-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A change to the runner selects the WHOLE pure-contract-unit family, not
  # just its own contract test. The runner executes every script in that
  # family, so its own test passing proves its logic is right, not that the
  # suite it drives still runs. Narrowing this to the contract owners would
  # also make any wall-clock claim about the changed suite trivially true by
  # not running the work.
  printf '\n' >>"$repo/bin/fm-test-run.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-test-run.test.sh*) ;;
    *) fail "runner change did not select its own contract test: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-ask-user-authority.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  git -C "$repo" add bin/fm-test-run.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm runner-change

  # The same holds for the surfaces that document that contract.
  printf '\n' >>"$repo/docs/fm-test-isolation-proof.md"
  printf '\n' >>"$repo/CONTRIBUTING.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-documentation-audiences.test.sh*) ;;
    *) fail "documentation surface change did not select audience coverage: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "documentation surface change did not select its curated family: $listed" ;;
  esac

  rm -rf "$tmp"
  pass "runner and its documentation surfaces select their curated family, not just their contract owners"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter reference selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter reference selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-reference-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/SKILL.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter router selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter router selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters/SKILL.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-router-change

  printf '\n' >>"$repo/bin/fm-procevent-quota.sh"
  printf '\n' >>"$repo/bin/fm-quota-choose.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "quota process-event source selects its focused test"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "quota chooser source selects its focused test"
  git -C "$repo" add bin/fm-procevent-quota.sh bin/fm-quota-choose.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-source-change

  printf '\n' >>"$repo/bin/fm-quota-axi-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "shared quota validator selects process-event coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "shared quota validator selects chooser coverage"
  git -C "$repo" add bin/fm-quota-axi-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-validator-change

  printf '\n' >>"$repo/bin/fm-control-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "control library keeps backend coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "control library keeps session coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "control library selects chooser coverage"
  git -C "$repo" add bin/fm-control-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm control-lib-change

  printf '\n' >>"$repo/bin/fm-timeout-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "timeout library selects quota polling coverage"
  git -C "$repo" add bin/fm-timeout-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm timeout-lib-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

# A direct test reference is per-script evidence. Widening it to the referencing
# test's whole family is what turned a one-line change to a shared helper into
# every real-Herdr E2E, including scripts with no dependency on it at all.
# Consumer bin/ scripts must still resolve through the curated map, so recorded
# family-level coupling is not lost along the way.
test_changed_bin_reference_selects_per_script_not_per_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/shared-probe-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)

  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" \
    "the one gated script that names the helper must still be selected"
  case "$listed" in
    *tests/fm-control-herdr-smoke.test.sh*)
      fail "a single gated script's reference dragged in its whole family: $listed"
      ;;
  esac
  # The curated consumer keeps its family-level coupling.
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a curated consumer of the helper must still select its whole family"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a curated consumer of the helper must still select its whole family"

  rm -rf "$tmp"
  pass "a bin reference selects the referencing scripts, and consumers still select their curated families"
}

# Exercise begin/end markers from real fixture processes to prove the automatic
# changed-suite default and its explicit serial override.
test_changed_uses_bounded_automatic_concurrency() {
  local tmp repo script serial_shape parallel_shape timeout_repo timeout_script expected_jobs rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-consent.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - concurrency consent fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/parallel.json") \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default changed fixture run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "plain --changed did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --jobs 1 --json "$tmp/serial.json") \
    >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial changed fixture run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force serial execution: $serial_shape"
  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PY' \
    || fail "changed timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PY

  timeout_repo="$tmp/timeout-repo"
  timeout_script=tests/fm-calm-pi-extension.test.sh
  mkdir -p "$timeout_repo/bin" "$timeout_repo/tests"
  cp "$RUNNER" "$timeout_repo/bin/fm-test-run.sh"
  cat >"$timeout_repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  [ "$1" -eq 900 ] || return 99
  return 124
}
SH
  cat >"$timeout_repo/$timeout_script" <<'SH'
#!/usr/bin/env bash
touch should-not-run
echo "not ok - automatic timeout helper was bypassed"
SH
  chmod +x "$timeout_repo/bin/fm-test-run.sh" "$timeout_repo/$timeout_script"
  git -C "$timeout_repo" init -q
  git -C "$timeout_repo" add .
  git -C "$timeout_repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$timeout_repo/$timeout_script"
  set +e
  (cd "$timeout_repo" && bin/fm-test-run.sh --changed --base HEAD) \
    >"$tmp/timeout.out" 2>"$tmp/timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "single-script automatic timeout must fail the run, got $rc"
  grep -Eq '^FM_TEST_END .+ tests/fm-calm-pi-extension\.test\.sh exit=124 ' "$tmp/timeout.out" \
    || fail "single unproven changed script did not receive the automatic timeout: $(cat "$tmp/timeout.out")"
  [ ! -e "$timeout_repo/should-not-run" ] || fail "automatic timeout helper did not own the single changed script"

  rm -rf "$tmp"
  pass "changed defaults to bounded automatic scheduling with serial override"
}

test_empty_selection_emits_summary() {
  local tmp repo out json rc fake_bin real_git
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  printf '%s\n' "$out" | grep -Eq \
    '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' \
    || fail "empty selection summary is missing or malformed: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["summary"]["skipped_gate"] == 0
assert doc["summary"]["duration_ms"] >= 0
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  fake_bin="$tmp/fake-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SLOW_GIT_MARKER" ]; then
  : >"$SLOW_GIT_MARKER"
  sleep 1
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  set +e
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --max-wall-ms 100) \
    >"$tmp/slow-selection.out" 2>"$tmp/slow-selection.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an empty run past its budget must fail normally, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its summary"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=100 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its budget result"
  [ -e "$tmp/slow-git" ] || fail "the slow selection fixture did not run"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --max-wall-ms nope) \
    >"$tmp/bad-budget.out" 2>"$tmp/bad-budget.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed budget on an empty selection must be refused, got $rc"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --per-script-timeout-secs nope) \
    >"$tmp/bad-timeout.out" 2>"$tmp/bad-timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed timeout on an empty selection must be refused, got $rc"
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-afk-inject-e2e.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on a family with no recorded proof must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

# The complement of the refusal above: a family carrying a recorded concurrent
# proof is admitted and actually scheduled, so the admission rule is two-sided
# rather than a blanket refusal that happens to pass its negative cases.
test_jobs_admits_a_concurrent_safe_family() {
  local tmp rc external
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-admit.XXXXXX")
  # --list exits before the admission guard, so this has to be a real run for
  # the assertion to mean anything. Two cheap watcher-wake-lock scripts exercise
  # admission and the concurrent scheduler for real.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-supervision-events.test.sh tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--jobs on a proven family must be admitted, got $rc: $(cat "$tmp/err") $(cat "$tmp/out")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "the admitted concurrent run did not report both scripts green: $(cat "$tmp/out")"

  set +e
  "$RUNNER" --jobs 5 tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/over-cap.out" 2>"$tmp/over-cap.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a family run above its proven four-worker cap must be refused, got $rc"

  external="$tmp/fm-session-lock-ancestry.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - colliding external fixture"\n' >"$external"
  chmod +x "$external"
  set +e
  "$RUNNER" --jobs 2 "$external" >"$tmp/external.out" 2>"$tmp/external.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an external script colliding with a proven family member must be refused, got $rc"
  rm -rf "$tmp"
  pass "--jobs admits and schedules a family with a recorded concurrent proof"
}

# Workers are handed scripts in order, so the slowest script must start first or
# it runs alone at the tail and throws away most of the concurrency.
test_concurrent_runs_are_ordered_longest_first() {
  local tmp listed first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-order.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --family watcher-wake-lock --list >"$tmp/serial" 2>&1
  set -e
  # The scheduler reorders the real run, so assert on the begin-marker order of
  # a real concurrent run over scripts whose hints differ by a wide margin.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-session-lock-ancestry.test.sh tests/fm-task-inbox.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  set -e
  first=$(grep -m1 '^FM_TEST_BEGIN' "$tmp/out" | awk '{print $3}')
  [ "$first" = tests/fm-task-inbox.test.sh ] \
    || fail "concurrent run did not start the longest script first, started: $first"
  rm -rf "$tmp"
  pass "a concurrent run starts the longest-hint script first"
}

# --max-wall-ms is checked after the run, so it cannot end a run that never
# finishes. A hung script has to become a bounded failure, because an unbounded
# suite is exactly what silently outruns its caller's invocation budget.
test_per_script_timeout_bounds_a_hang() {
  local tmp repo runner hang rc began ended grandchild_pid grandchild waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hang.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  grandchild_pid="$tmp/grandchild.pid"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture is about to hang"
sh -c 'trap "" TERM; echo $$ >"$1"; sleep 600' _ "$GRANDCHILD_PID" &
sleep 600
SH
  chmod +x "$runner" "$repo/$hang"

  began=$(date +%s)
  set +e
  GRANDCHILD_PID="$grandchild_pid" \
    "$runner" --per-script-timeout-secs 3 "$hang" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  ended=$(date +%s)

  [ "$rc" -ne 0 ] || fail "a terminated script must fail the run: $(cat "$tmp/out")"
  [ "$((ended - began))" -lt 120 ] \
    || fail "the per-script bound did not stop a 600s hang (took $((ended - began))s)"
  grep -Fq 'exceeded the per-script bound' "$tmp/out" \
    || fail "the terminated script was not named: $(cat "$tmp/out")"
  grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "a terminated script must be recorded as exit 124: $(cat "$tmp/out")"
  # The run still completes and accounts for the script, rather than dying.
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out" \
    || fail "the bounded run did not report a complete summary: $(cat "$tmp/out")"
  [ -s "$grandchild_pid" ] || fail "the hanging fixture did not record its grandchild"
  grandchild=$(cat "$grandchild_pid")
  waited=0
  while kill -0 "$grandchild" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$grandchild" 2>/dev/null; then
    kill -KILL "$grandchild" 2>/dev/null || true
    fail "the timed-out script left grandchild $grandchild running"
  fi

  # 0 keeps the historical unbounded behavior, so no existing caller changes.
  set +e
  "$runner" --per-script-timeout-secs nope "$hang" >"$tmp/o2" 2>"$tmp/e2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--per-script-timeout-secs with a non-number must be refused, got $rc"

  rm -rf "$tmp"
  pass "--per-script-timeout-secs turns a hung script into a bounded failure"
}

# The duration regression this guard exists for: a suite whose scripts are all
# green but whose wall clock outgrew its caller's invocation budget. The caller
# gets killed mid-run and retries invisibly, so an over-budget run has to be a
# failure, not a note in the log.
test_max_wall_ms_is_a_result_not_advice() {
  local tmp repo runner fast rc summary_duration budget_duration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fast=tests/fm-budget-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cat >"$repo/$fast" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - budget fixture"
SH
  chmod +x "$runner" "$repo/$fast"

  # Comfortably inside budget: the run passes and states the budget it met.
  set +e
  "$runner" --max-wall-ms 60000 "$fast" >"$tmp/under" 2>"$tmp/under.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a run inside its budget must pass, got $rc: $(cat "$tmp/under.err")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=60000 duration_ms=[0-9]+$' "$tmp/under" \
    || fail "an inside-budget run did not report the budget: $(cat "$tmp/under")"

  # Same green script, budget it cannot meet: the run must FAIL.
  set +e
  "$runner" --max-wall-ms 500 "$fast" >"$tmp/over" 2>"$tmp/over.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an over-budget run must fail through the result path, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SUMMARY_FAMILY .+$' "$tmp/over" \
    || fail "an over-budget run omitted its family summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SLOWEST rank=1 .+$' "$tmp/over" \
    || fail "an over-budget run omitted its slowest result: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=500 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its budget result: $(cat "$tmp/over")"
  summary_duration=$(awk '/^FM_TEST_SUMMARY / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  budget_duration=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  [ "$budget_duration" = "$summary_duration" ] \
    || fail "budget verdict used a different duration than the summary: $(cat "$tmp/over")"

  # A malformed budget is refused rather than silently ignored.
  set +e
  "$runner" --max-wall-ms 0 "$fast" >"$tmp/bad" 2>"$tmp/bad.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms 0 must be refused (exit 2), got $rc"
  set +e
  "$runner" --max-wall-ms nope "$fast" >"$tmp/bad2" 2>"$tmp/bad2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms with a non-number must be refused (exit 2), got $rc"

  rm -rf "$tmp"
  pass "--max-wall-ms fails an over-budget run and refuses a malformed budget"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

# Workflow parsing is owned by the same capability the tool profile probes.
# Parse once before the expensive suite; unavailable tooling fails immediately.
WORKFLOW_JSON=$("$ROOT/bin/fm-workflow-yaml.sh" "$ROOT/.github/workflows/ci.yml") \
  || fail "workflow YAML capability or input unavailable"

workflow_job_timeout_minutes() {  # <job-id>
  python3 -c 'import json,sys; print(json.load(sys.stdin)["jobs"][sys.argv[1]]["timeout-minutes"])' "$1" <<<"$WORKFLOW_JSON"
}

test_portable_serial_shard_hints_stay_inside_the_job_cap_budget() {
  # The coverage guard budgets every serial shard's summed duration hints at a
  # stated fraction of the job cap, so a grown test is caught here rather than
  # by a runner cancelled at the cap.
  local tmp out loads count budget max lane n load rc bad leftover
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-budget.XXXXXX")
  out=$("$RUNNER" --check-coverage) || { rm -rf "$tmp"; fail "coverage guard failed: $out"; }
  budget=$(printf '%s\n' "$out" | sed -n 's/.* serial_shard_budget_ms=\([0-9]*\).*/\1/p')
  max=$(printf '%s\n' "$out" | sed -n 's/.* serial_shard_max_hint_ms=\([0-9]*\).*/\1/p')
  [ -n "$budget" ] && [ -n "$max" ] \
    || { rm -rf "$tmp"; fail "coverage guard did not report the shard budget and max hint: $out"; }
  [ "$max" -le "$budget" ] \
    || { rm -rf "$tmp"; fail "coverage guard passed with a shard hint total $max over its budget $budget"; }

  # --serial-shard-loads is the table the refresh procedure records; its max
  # is the number the guard compared, and every shard lane appears once.
  loads=$("$RUNNER" --serial-shard-loads)
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$(printf '%s\n' "$loads" | wc -l | tr -d ' ')" -eq "$count" ] \
    || { rm -rf "$tmp"; fail "--serial-shard-loads must list every serial shard once: $loads"; }
  while IFS=$'\t' read -r lane n load; do
    [ "$("$RUNNER" --list --lane "$lane" | wc -l | tr -d ' ')" -eq "$n" ] \
      || { rm -rf "$tmp"; fail "$lane script count $n disagrees with --list"; }
    [ "$load" -le "$max" ] \
      || { rm -rf "$tmp"; fail "$lane load $load exceeds the reported max $max"; }
  done <<EOF
$loads
EOF
  printf '%s\n' "$loads" | grep -q "	$max\$" \
    || { rm -rf "$tmp"; fail "no shard carries the reported max hint $max: $loads"; }

  # A cap the current hints cannot fit under fails the guard and names the
  # shard, proving the budget is enforced rather than only reported.
  set +e
  FM_PORTABLE_SERIAL_JOB_CAP_MINUTES=1 "$RUNNER" --check-coverage >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "a 1-minute what-if cap must fail the guard (exit 1), got $rc"; }
  grep -Fq 'shard hint total exceeds' "$tmp/err" \
    || { rm -rf "$tmp"; fail "budget refusal must say the hint total exceeds the cap: $(cat "$tmp/err")"; }
  grep -Eq 'portable-serial-1of[0-9]+=[0-9]+ms' "$tmp/err" \
    || { rm -rf "$tmp"; fail "budget refusal must name the offending shard: $(cat "$tmp/err")"; }
  grep -q 'FM_TEST_COVERAGE ok' "$tmp/out" && { rm -rf "$tmp"; fail "budget refusal must not print the ok marker"; }

  # A refused what-if cap must leave no scratch directory behind, so each
  # refusal runs under a private TMPDIR that must still be empty afterwards.
  mkdir "$tmp/scratch"
  for bad in soon 08 0 '' 361; do
    set +e
    TMPDIR="$tmp/scratch" FM_PORTABLE_SERIAL_JOB_CAP_MINUTES=$bad "$RUNNER" --check-coverage >"$tmp/out2" 2>"$tmp/err2"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "what-if cap '$bad' must refuse (exit 2), got $rc"; }
    grep -Fq 'FM_PORTABLE_SERIAL_JOB_CAP_MINUTES must be' "$tmp/err2" \
      || { rm -rf "$tmp"; fail "what-if cap '$bad' refusal must name the variable: $(cat "$tmp/err2")"; }
    leftover=$(ls -A "$tmp/scratch")
    [ -z "$leftover" ] \
      || { rm -rf "$tmp"; fail "what-if cap '$bad' refusal must leave no temp directory: $leftover"; }
  done
  rm -rf "$tmp"
  pass "portable serial shard hints are budgeted against the job cap and the guard fails on drift"
}

test_portable_serial_ci_job_cap_matches_the_runner_budget() {
  # ci.yml's tests-portable-serial timeout is the cap the runner budgets shard
  # hints against; parse the workflow as YAML so the two cannot drift apart.
  local cap ci_cap
  ci_cap=$(workflow_job_timeout_minutes tests-portable-serial) \
    || fail "could not parse the tests-portable-serial job timeout from ci.yml"
  cap=$("$RUNNER" --check-coverage | sed -n 's/.* serial_cap_min=\([0-9]*\).*/\1/p')
  [ -n "$cap" ] || fail "coverage guard did not report serial_cap_min"
  [ "$cap" = "$ci_cap" ] \
    || fail "bin/fm-test-run.sh budgets serial shards against a $cap-minute cap but ci.yml caps the job at $ci_cap minutes"
  pass "portable serial CI job cap ($ci_cap min) matches the runner's shard budget cap"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  local json job_timeout step_timeout
  json=$(python3 -c 'import json,sys
job=json.load(sys.stdin)["jobs"]["tests-herdr"]
step=next(s for s in job["steps"] if isinstance(s,dict) and s.get("name")=="Run real-Herdr family (serial, required)")
print(json.dumps({"job_timeout":job["timeout-minutes"],"step_timeout":step["timeout-minutes"]}))' <<<"$WORKFLOW_JSON") \
    || fail "could not read tests-herdr timeouts from parsed workflow"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

# Write one lane timing artifact the way bin/fm-test-run.sh --json emits it.
# aggregate_lane_fixture <path> <lane> <total> <failed> <skipped_gate> <duration_ms>
aggregate_lane_fixture() {
  local path=$1 lane=$2 total=$3 failed=$4 skipped=$5 duration=$6 i scripts=""
  mkdir -p "$(dirname "$path")"
  i=0
  while [ "$i" -lt "$total" ]; do
    [ -z "$scripts" ] || scripts="$scripts,"
    if [ "$i" -lt "$skipped" ]; then
      scripts="$scripts{\"path\": \"tests/$lane-$i.test.sh\", \"family\": \"afk\", \"duration_ms\": 5, \"exit\": 0, \"gate_skip\": true}"
    elif [ "$i" -lt $((skipped + failed)) ]; then
      scripts="$scripts{\"path\": \"tests/$lane-$i.test.sh\", \"family\": \"afk\", \"duration_ms\": 700, \"exit\": 1, \"gate_skip\": false}"
    else
      scripts="$scripts{\"path\": \"tests/$lane-$i.test.sh\", \"family\": \"afk\", \"duration_ms\": 400, \"exit\": 0, \"gate_skip\": false}"
    fi
    i=$((i + 1))
  done
  cat >"$path" <<JSON
{
  "run_id": "run-$lane",
  "lane": "$lane",
  "selection": "lane=$lane",
  "started_at": "2026-09-06T00:00:00Z",
  "finished_at": "2026-09-06T00:01:00Z",
  "summary": {"total": $total, "failed": $failed, "skipped_gate": $skipped, "duration_ms": $duration},
  "scripts": [$scripts]
}
JSON
}

test_aggregate_json() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  aggregate_lane_fixture "$tmp/b.json" portable-serial-1of1 2 1 0 2000
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json") \
    || { rm -rf "$tmp"; fail "aggregate of two identified lanes must succeed: $out"; }
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 " "aggregate summary line"
  assert_contains "$out" " total=3 " "aggregate total"
  assert_contains "$out" " failed=1 " "aggregate failed"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert [l["lane"] for l in doc["lanes"]]==["portable-parallel-1","portable-serial-1of1"], doc["lanes"]
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

# The Herdr CI lane uploads its timing JSON under a nested directory inside its
# artifact, so an aggregate that only reads root-level members silently drops
# that lane while the workflow still declares the aggregate depends on it. A
# directory input must resolve every fm-test-timing-*.json beneath it.
test_aggregate_resolves_nested_lane_members() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggnest.XXXXXX")
  aggregate_lane_fixture "$tmp/in/fm-test-timing-portable-parallel-1.json" portable-parallel-1 1 0 0 1000
  aggregate_lane_fixture "$tmp/in/fm-test/fm-test-timing-real-herdr-gated.json" real-herdr-gated 3 0 0 3000
  mkdir -p "$tmp/in/fm-herdr"
  printf 'not a timing artifact\n' >"$tmp/in/fm-herdr/default-server.log"
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" \
    --expect-lane portable-parallel-1 --expect-lane real-herdr-gated "$tmp/in") \
    || { rm -rf "$tmp"; fail "aggregate over a directory holding a nested lane member must succeed: $out"; }
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 " "both lanes aggregated"
  assert_contains "$out" " complete=true" "manifest satisfied"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert [l["lane"] for l in doc["lanes"]]==["portable-parallel-1","real-herdr-gated"], doc["lanes"]
assert doc["summary"]["complete"] is True, doc["summary"]
assert doc["summary"]["missing_lanes"]==[], doc["summary"]
assert doc["summary"]["critical_path_duration_ms"]==3000, doc["summary"]
' "$tmp/out.json" || { rm -rf "$tmp"; fail "nested lane member was not included in the aggregate"; }
  rm -rf "$tmp"
  pass "aggregate-json resolves a nested lane member from a directory input"
}

test_aggregate_refuses_duplicate_lane_ids() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggdup.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  aggregate_lane_fixture "$tmp/b.json" portable-parallel-1 2 0 0 2000
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "two artifacts claiming the same lane must be refused, not summed: $out"; }
  assert_contains "$out" "duplicate lane" "duplicate lane refusal names the defect"
  assert_contains "$out" "portable-parallel-1" "duplicate lane refusal names the lane"
  [ ! -e "$tmp/out.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rm -rf "$tmp"
  pass "aggregate-json refuses duplicate lane ids instead of summing them"
}

test_aggregate_requires_lane_identity() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agglane.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  python3 -c '
import json,sys
p=sys.argv[1]; doc=json.load(open(p)); del doc["lane"]; json.dump(doc, open(p,"w"))
' "$tmp/a.json"
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "an artifact with no lane identity must be refused: $out"; }
  assert_contains "$out" "lane identity" "unidentified artifact refusal names the defect"
  rm -rf "$tmp"
  pass "aggregate-json refuses an input that carries no lane identity"
}

test_aggregate_refuses_missing_input() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggmiss.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/nope.json" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a good lane plus a nonexistent input must refuse the whole aggregate with exit 2 (got $rc): $out"; }
  assert_contains "$out" "aggregate input not found" "missing input refusal names the defect"
  assert_contains "$out" "$tmp/nope.json" "missing input refusal names the path"
  [ ! -e "$tmp/out.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out2.json" "$tmp/nope-only.json" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a sole nonexistent input must refuse the aggregate with exit 2 (got $rc): $out"; }
  assert_contains "$out" "aggregate input not found" "sole missing input refusal names the defect"
  [ ! -e "$tmp/out2.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rm -rf "$tmp"
  pass "aggregate-json refuses a nonexistent input from the main process without writing output"
}

test_aggregate_refuses_empty_resolution_without_manifest() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggempty.XXXXXX")
  mkdir -p "$tmp/in/nested"
  printf '{}\n' >"$tmp/in/nested/not-a-timing-file.json"
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/in" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a directory holding no fm-test-timing-*.json and no manifest must be refused with exit 2 (got $rc): $out"; }
  assert_contains "$out" "fm-test-run: no fm-test-timing-*.json found under $tmp/in" "empty resolution refusal is typed and names the input"
  [ ! -e "$tmp/out.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out2.json" --expect-lane portable-parallel-1 --expect-lane real-herdr-gated "$tmp/in" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "the same empty directory under a manifest must be refused with exit 2 (got $rc): $out"; }
  assert_contains "$out" "fm-test-run: no fm-test-timing-*.json found under $tmp/in; every expected lane is missing: portable-parallel-1, real-herdr-gated" "empty resolution under a manifest names every expected lane"
  [ ! -e "$tmp/out2.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  aggregate_lane_fixture "$tmp/lane.json" portable-parallel-1 1 0 0 1000
  "$RUNNER" --aggregate-json "$tmp/prior/fm-test-timing-aggregate.json" "$tmp/lane.json" >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "building the prior aggregate fixture must succeed"; }
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out3.json" "$tmp/prior" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a directory holding only a prior aggregate must be refused with exit 2 (got $rc): $out"; }
  assert_contains "$out" "fm-test-run: no lane timing artifact resolved from $tmp/prior/fm-test-timing-aggregate.json" "prior-aggregate-only refusal is typed and names the input"
  [ ! -e "$tmp/out3.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out4.json" --expect-lane portable-parallel-1 --expect-lane real-herdr-gated "$tmp/prior" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a prior-aggregate-only directory under a manifest must be refused with exit 2 (got $rc): $out"; }
  assert_contains "$out" "every expected lane is missing: portable-parallel-1, real-herdr-gated" "prior-aggregate-only refusal under a manifest names every expected lane"
  [ ! -e "$tmp/out4.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rm -rf "$tmp"
  pass "aggregate-json refuses a resolution that yields no lane, with or without a manifest"
}

test_aggregate_refuses_invalid_lane_json() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggbadjson.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  aggregate_lane_fixture "$tmp/b.json" portable-parallel-2 1 0 0 1000
  head -c 120 "$tmp/b.json" >"$tmp/truncated.json"
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/truncated.json" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "a truncated lane file must be refused with exit 2 (got $rc): $out"; }
  assert_contains "$out" "fm-test-run: aggregate input $tmp/truncated.json is not valid JSON" "invalid JSON refusal is typed and names the file"
  printf '%s\n' "$out" | grep -q "Traceback" && { rm -rf "$tmp"; fail "invalid JSON must be refused without a traceback: $out"; }
  [ ! -e "$tmp/out.json" ] || { rm -rf "$tmp"; fail "a refused aggregate must not write an output artifact"; }
  rm -rf "$tmp"
  pass "aggregate-json refuses a truncated lane file with a typed message and no traceback"
}

test_aggregate_marks_missing_expected_lanes_incomplete() {
  local tmp out rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggmiss.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-parallel-1 1 0 0 1000
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" \
    --expect-lane portable-parallel-1 --expect-lane portable-serial-1of2 \
    --expect-lane portable-serial-2of2 --expect-lane real-herdr-gated "$tmp/a.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "an aggregate missing expected lanes must not exit 0: $out"; }
  assert_contains "$out" "INCOMPLETE" "incomplete aggregate says so"
  assert_contains "$out" " complete=false" "summary line reports incomplete"
  assert_contains "$out" "missing_lanes=portable-serial-1of2,portable-serial-2of2,real-herdr-gated" "missing lanes are listed"
  [ -f "$tmp/out.json" ] || { rm -rf "$tmp"; fail "an incomplete aggregate must still be written, marked incomplete"; }
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["complete"] is False, doc["summary"]
assert doc["summary"]["missing_lanes"]==["portable-serial-1of2","portable-serial-2of2","real-herdr-gated"], doc["summary"]
assert doc["summary"]["expected_lanes"]==["portable-parallel-1","portable-serial-1of2","portable-serial-2of2","real-herdr-gated"], doc["summary"]
assert doc["summary"]["lanes"]==1
' "$tmp/out.json" || { rm -rf "$tmp"; fail "incomplete aggregate JSON is not marked"; }
  # An undeclared manifest can never claim completeness.
  out=$("$RUNNER" --aggregate-json "$tmp/out2.json" "$tmp/a.json") \
    || { rm -rf "$tmp"; fail "aggregate with no manifest must still succeed: $out"; }
  assert_contains "$out" " complete=undeclared" "no manifest means completeness is undeclared"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["complete"] is None, doc["summary"]
assert doc["summary"]["expected_lanes"] is None, doc["summary"]
' "$tmp/out2.json" || { rm -rf "$tmp"; fail "undeclared manifest must not be recorded as complete"; }
  rm -rf "$tmp"
  pass "aggregate-json lists missing expected lanes and marks the aggregate INCOMPLETE"
}

test_aggregate_counts_gate_skips_apart_from_executed() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggskip.XXXXXX")
  aggregate_lane_fixture "$tmp/a.json" portable-serial-1of2 5 1 2 4000
  aggregate_lane_fixture "$tmp/b.json" portable-serial-2of2 3 0 1 3000
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json") \
    || { rm -rf "$tmp"; fail "aggregate must succeed: $out"; }
  assert_contains "$out" " total=8 " "total counts every script"
  assert_contains "$out" " executed=5 " "executed excludes gate skips"
  assert_contains "$out" " skipped_gate=3 " "gate skips are reported on their own"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
s=doc["summary"]
assert s["total"]==8 and s["executed"]==5 and s["skipped_gate"]==3 and s["failed"]==1, s
by={l["lane"]: l for l in doc["lanes"]}
assert by["portable-serial-1of2"]["summary"]["executed"]==3, by
assert by["portable-serial-2of2"]["summary"]["executed"]==2, by
assert sum(1 for r in doc["scripts"] if r["gate_skip"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "gate skips were not kept distinct from executed tests"; }
  rm -rf "$tmp"
  pass "aggregate-json keeps gate skips distinct from executed tests"
}

test_aggregate_is_deterministic_for_unchanged_input() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggdet.XXXXXX")
  aggregate_lane_fixture "$tmp/in/fm-test-timing-b.json" portable-serial-2of2 2 0 0 2000
  aggregate_lane_fixture "$tmp/in/nested/fm-test-timing-a.json" portable-serial-1of2 2 0 1 1000
  out=$("$RUNNER" --aggregate-json "$tmp/one.json" "$tmp/in/fm-test-timing-b.json" "$tmp/in/nested/fm-test-timing-a.json") \
    || { rm -rf "$tmp"; fail "first aggregate must succeed: $out"; }
  out=$("$RUNNER" --aggregate-json "$tmp/two.json" "$tmp/in/nested/fm-test-timing-a.json" "$tmp/in/fm-test-timing-b.json") \
    || { rm -rf "$tmp"; fail "second aggregate must succeed: $out"; }
  # A re-run downloads the previous attempt's aggregate beside the lanes; it
  # is a report, never a lane, and must not change the bytes either.
  cp "$tmp/one.json" "$tmp/in/fm-test-timing-aggregate.json"
  out=$("$RUNNER" --aggregate-json "$tmp/three.json" "$tmp/in") \
    || { rm -rf "$tmp"; fail "directory aggregate must succeed: $out"; }
  cmp -s "$tmp/one.json" "$tmp/two.json" \
    || { rm -rf "$tmp"; fail "input order changed the aggregate bytes"; }
  cmp -s "$tmp/one.json" "$tmp/three.json" \
    || { rm -rf "$tmp"; fail "resolving the same inputs from a directory changed the aggregate bytes"; }
  rm -rf "$tmp"
  pass "unchanged input yields a byte-identical aggregate regardless of input order, resolution, or a prior aggregate beside it"
}

# The producer stamps the lane identity the aggregate validates: the --lane
# name, or the family name for a family run such as the Herdr CI lane.
test_timing_json_records_lane_identity() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-laneid.XXXXXX")
  # Select the Herdr family, then exclude it, so the run is empty but keeps the
  # family's identity without needing a real Herdr.
  out=$("$RUNNER" --family real-herdr-gated --exclude-family real-herdr-gated --json "$tmp/family.json" 2>"$tmp/err") \
    || { rm -rf "$tmp"; fail "empty family run must pass: $out $(cat "$tmp/err")"; }
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["lane"]=="real-herdr-gated", doc
assert doc["summary"]["total"]==0
' "$tmp/family.json" || { rm -rf "$tmp"; fail "family run did not record its lane identity"; }
  out=$("$RUNNER" --json "$tmp/scripts.json" "$ROOT/tests/fm-test-fixtures.test.sh" 2>"$tmp/err") \
    || { rm -rf "$tmp"; fail "script run must pass: $out $(cat "$tmp/err")"; }
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["lane"] is None, doc
' "$tmp/scripts.json" || { rm -rf "$tmp"; fail "an ad-hoc script run must not claim a lane identity"; }
  rm -rf "$tmp"
  pass "timing JSON records the lane identity of lane and family runs only"
}

# The CI lane manifest has one owner: the same script that owns lane names and
# the serial shard count. The workflow expects exactly these lanes in the
# aggregate, so a lane added here without a job, or a shard count that moved,
# shows up as INCOMPLETE instead of a quietly smaller report.
test_list_ci_lanes_matches_the_lane_inventory() {
  local ci lanes n
  ci=$("$RUNNER" --list-ci-lanes) || fail "--list-ci-lanes failed"
  lanes=$("$RUNNER" --list-lanes | grep -v '^portable-serial$')
  [ "$ci" = "$lanes" ] || fail "--list-ci-lanes must equal every lane except the unsharded portable-serial umbrella:
$ci
--
$lanes"
  n=$(printf '%s\n' "$ci" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$n" -ge 1 ] || fail "--list-ci-lanes must list every portable serial shard"
  printf '%s\n' "$ci" | grep -qx 'real-herdr-gated' || fail "--list-ci-lanes must include the Herdr lane"
  pass "--list-ci-lanes is the lane inventory minus the unsharded serial umbrella"
}

# Every CI job that uploads a per-lane timing artifact must feed the aggregate
# job, so the manifest above and the workflow's dependency list cannot drift.
test_timing_aggregate_job_needs_every_lane_producer() {
  local out
  out=$(python3 -c 'import json,sys
jobs=json.load(sys.stdin)["jobs"]
needs=jobs["tests-timing-aggregate"].get("needs") or []
if isinstance(needs,str): needs=[needs]
producers=sorted(jid for jid,job in jobs.items() if jid!="tests-timing-aggregate" and any(
 isinstance(s,dict) and str(s.get("uses","")).startswith("actions/upload-artifact")
 and str((s.get("with") or {}).get("name","")).startswith("fm-test-timing-") for s in job.get("steps",[])))
print("producers="+",".join(producers))
print("missing="+",".join(sorted(set(producers)-set(needs))))
print("extra="+",".join(sorted(set(needs)-set(producers))))' <<<"$WORKFLOW_JSON") \
    || fail "could not read timing aggregate wiring from parsed workflow"
  assert_contains "$out" "producers=tests-herdr,tests-portable-parallel-1,tests-portable-parallel-2,tests-portable-serial" "lane producers"
  printf '%s\n' "$out" | grep -qx 'missing=' || fail "a lane timing producer does not feed the aggregate: $out"
  printf '%s\n' "$out" | grep -qx 'extra=' || fail "the aggregate needs a job that uploads no lane timing: $out"
  pass "the timing aggregate job depends on exactly the jobs that upload lane timing"
}

test_serial_runner_isolates_instance_environment() {
  local tmp fixture bound out rc
  tmp=$(fm_test_tmproot fm-test-run-instance-env)
  fixture="$tmp/instance.test.sh"
  mkdir -p "$tmp/captain" "$tmp/fixture-home"
  printf 'untouched\n' > "$tmp/captain/sentinel"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
set -u
for key in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND; do
  if printenv "$key" >/dev/null 2>&1; then
    printf 'not ok - inherited instance binding reached test: %s\n' "$key"
    exit 1
  fi
done
[ "$FM_RUNNER_KEEP" = kept ] || exit 8
# A test's own explicit instance remains usable after the runner boundary.
FM_HOME="$FM_RUNNER_FIXTURE_HOME" bash -c 'printf "fixture-only\n" > "$FM_HOME/receipt"' || exit 9
printf 'ok - instance bindings isolated; explicit fixture and unrelated input preserved\n'
SH
  for bound in 0 10; do
    rc=0
    out=$(FM_HOME="$tmp/captain" FM_STATE_OVERRIDE="$tmp/captain/state" \
      FM_DATA_OVERRIDE="$tmp/captain/data" FM_ROOT_OVERRIDE="$tmp/captain" \
      FM_PROJECTS_OVERRIDE="$tmp/captain/projects" FM_CONFIG_OVERRIDE="$tmp/captain/config" \
      FM_BACKEND=herdr FM_RUNNER_KEEP=kept FM_RUNNER_FIXTURE_HOME="$tmp/fixture-home" \
      "$RUNNER" --per-script-timeout-secs "$bound" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "serial runner leaked an instance binding (bound=$bound): $out"
    assert_contains "$out" 'FM_TEST_SUMMARY total=1 failed=0' 'isolated runner summary'
    [ "$(cat "$tmp/fixture-home/receipt")" = fixture-only ] || fail "fixture override did not work"
    [ "$(cat "$tmp/captain/sentinel")" = untouched ] || fail "parent sentinel changed"
    [ ! -e "$tmp/captain/receipt" ] || fail "test wrote through the inherited home"
  done
  pass "serial and timed scripts isolate instance bindings while retaining explicit fixture inputs"
}

test_serial_runner_isolates_instance_environment

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_runner_surfaces_select_their_family
test_changed_dependency_selection_and_unmapped_failure
test_changed_bin_reference_selects_per_script_not_per_family
test_changed_uses_bounded_automatic_concurrency
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_admits_a_concurrent_safe_family
test_concurrent_runs_are_ordered_longest_first
test_per_script_timeout_bounds_a_hang
test_max_wall_ms_is_a_result_not_advice
test_jobs_parallel_scheduler_and_failure_propagation
test_portable_serial_shard_hints_stay_inside_the_job_cap_budget
test_portable_serial_ci_job_cap_matches_the_runner_budget
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
test_aggregate_resolves_nested_lane_members
test_aggregate_refuses_duplicate_lane_ids
test_aggregate_requires_lane_identity
test_aggregate_refuses_missing_input
test_aggregate_refuses_empty_resolution_without_manifest
test_aggregate_refuses_invalid_lane_json
test_aggregate_marks_missing_expected_lanes_incomplete
test_aggregate_counts_gate_skips_apart_from_executed
test_aggregate_is_deterministic_for_unchanged_input
test_timing_json_records_lane_identity
test_list_ci_lanes_matches_the_lane_inventory
test_timing_aggregate_job_needs_every_lane_producer
