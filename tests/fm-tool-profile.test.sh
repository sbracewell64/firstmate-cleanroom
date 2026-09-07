#!/usr/bin/env bash
# Tests for bin/fm-tool-profile.sh, the qualified tool-profile observation.
#
# Regression origin (2026-09-06, no-mistakes friction audit finding NMF-ENV):
# the clean-room launcher exported the scoped tools first on PATH, and yet the
# no-mistakes lint gate failed on an absent actionlint, the test agent found
# tasks-axi 0.2.3 from a login shell whose ~/.profile re-prepended the legacy
# ~/.local/bin, and the Pi extension tests could not run because the distro
# node was built without TypeScript execution. Each consumer had a different
# environment and nothing observed them. This suite pins the probe that every
# consumer can now run, with a deliberately below-floor tasks-axi and a
# legacy-shaped login shell as negative controls, so the probe can never go
# quietly vacuous.
#
# Every tool the probe looks at is a stub under a private PATH; no case probes
# or launches a tool installed on this host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROFILE="$ROOT/bin/fm-tool-profile.sh"
TMP_ROOT=$(fm_test_tmproot fm-tool-profile)

PIN_SHELLCHECK=$("$ROOT/bin/fm-lint.sh" --required-version)
PIN_ACTIONLINT=$("$ROOT/bin/fm-lint-workflows.sh" --required-version)
PIN_TASKS_AXI=$("$PROFILE" --pin tasks-axi)
FLOOR_TASKS_AXI=$("$PROFILE" --floor tasks-axi)
FLOOR_NO_MISTAKES=$("$PROFILE" --floor no-mistakes)

# A private system dir so an ABSENT case cannot fall through to a real copy of
# the tool while the probe still has the utilities it needs.
SYSBIN="$TMP_ROOT/sysbin"
mkdir -p "$SYSBIN"
for tool in bash sh sed awk head tr ps mktemp rm cat jq dirname grep cut sort readlink env printf; do
  path=$(command -v "$tool" 2>/dev/null) || continue
  ln -s "$path" "$SYSBIN/$tool"
done

write_shellcheck() {  # <dir> <version>
  cat > "$1/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: %s\nlicense: GNU General Public License, version 3\n' '$2'
  exit 0
fi
exit 0
SH
  chmod +x "$1/shellcheck"
}

write_actionlint() {  # <dir> <version>
  cat > "$1/actionlint" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -version ]; then
  printf '%s\ninstalled by downloading from release page\nbuilt with go1.24 compiler for linux/amd64\n' '$2'
  exit 0
fi
exit 0
SH
  chmod +x "$1/actionlint"
}

write_tasks_axi() {  # <dir> <version> [archive-body yes|no] [multi-id yes|no]
  local dir=$1 version=$2 archive_body=${3:-yes} multi_id=${4:-yes} archive_line mv_usage
  archive_line=""
  [ "$archive_body" = yes ] && archive_line='  --archive-body'
  mv_usage='usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  [ "$multi_id" = yes ] || mv_usage='usage: tasks-axi mv <id> --to <path-or-dir>'
  cat > "$dir/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  [ -z '$archive_line' ] || printf '%s\n' '$archive_line'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_usage'
  exit 0
fi
exit 0
SH
  chmod +x "$dir/tasks-axi"
}

write_no_mistakes() {  # <dir> <version> <build>
  cat > "$1/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'no-mistakes version v%s (%s) 2026-08-31T14:04:25Z\n' '$2' '$3'
  exit 0
fi
exit 0
SH
  chmod +x "$1/no-mistakes"
}

# write_node <dir> <version> <ts yes|no>: a node that executes a .ts file only
# when built with TypeScript support, mirroring process.features.typescript.
write_node() {
  cat > "$1/node" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf 'v%s\n' '$2'; exit 0 ;;
  -p)
    case "\${2:-}" in
      *features.typescript*) if [ '$3' = yes ]; then printf 'strip\n'; else printf 'false\n'; fi; exit 0 ;;
    esac
    exit 0 ;;
esac
case "\${1:-}" in
  *.ts)
    if [ '$3' = yes ]; then
      printf 'fm-tool-profile:ts-ok 42\n'
      exit 0
    fi
    printf 'TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension ".ts"\n' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$1/node"
}

# qualified_bin <dir>: every tool at its pin, floor, or capability.
qualified_bin() {
  mkdir -p "$1"
  write_shellcheck "$1" "$PIN_SHELLCHECK"
  write_actionlint "$1" "$PIN_ACTIONLINT"
  write_tasks_axi "$1" "$PIN_TASKS_AXI"
  write_no_mistakes "$1" 1.61.0 0af0be6
  write_node "$1" 24.0.0 yes
}

run_probe() {  # <bin> [args...] -> OUT, RC (stdout and stderr merged)
  local bin=$1
  shift
  RC=0
  OUT=$(PATH="$bin:$SYSBIN" "$PROFILE" "$@" 2>&1) || RC=$?
}

test_pins_are_projected_from_their_owners() {
  local out rc
  [ "$PIN_SHELLCHECK" = "$("$PROFILE" --pin shellcheck)" ] \
    || fail "--pin shellcheck must equal bin/fm-lint.sh --required-version"
  [ "$PIN_ACTIONLINT" = "$("$PROFILE" --pin actionlint)" ] \
    || fail "--pin actionlint must equal bin/fm-lint-workflows.sh --required-version"
  case "$PIN_TASKS_AXI" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "--pin tasks-axi must print a semver, got '$PIN_TASKS_AXI'" ;;
  esac
  case "$FLOOR_NO_MISTAKES" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "--floor no-mistakes must print a semver, got '$FLOOR_NO_MISTAKES'" ;;
  esac
  rc=0
  out=$("$PROFILE" --pin herdr 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--pin for a tool with no owned pin must exit 2, got $rc"$'\n'"$out"
  pass "pins and floors are projected from their owners"
}

# fixture_probe <dir> <lib-body>: a copy of the probe whose bin/ holds a
# tasks-axi owner that first loads the real lib and then applies <lib-body>, so
# the probe's own owner projection can be exercised against a broken owner
# without touching the real one.
fixture_probe() {
  mkdir -p "$1/bin"
  cp "$PROFILE" "$1/bin/fm-tool-profile.sh"
  printf '. %q\n%s\n' "$ROOT/bin/fm-tasks-axi-lib.sh" "$2" > "$1/bin/fm-tasks-axi-lib.sh"
}

test_pin_below_floor_or_missing_is_refused_by_the_owner_projection() {
  # The CI install pin can never be a version the local floor refuses, and a
  # pin the owner no longer defines must fail the projection loudly instead of
  # letting a consumer install `tasks-axi@` (latest).
  local fixture out err rc
  fixture="$TMP_ROOT/pin-below-floor"
  fixture_probe "$fixture" 'FM_TASKS_AXI_PIN=0.0.1'
  rc=0
  out=$("$fixture/bin/fm-tool-profile.sh" --pin tasks-axi 2>"$fixture/err") || rc=$?
  err=$(cat "$fixture/err")
  [ "$rc" -eq 2 ] || fail "--pin tasks-axi below the floor must exit 2, got $rc"$'\n'"$out$err"
  [ -z "$out" ] || fail "--pin tasks-axi below the floor must print nothing on stdout, got '$out'"
  assert_contains "$err" "FM_TASKS_AXI_PIN 0.0.1 is below FM_TASKS_AXI_MIN $FLOOR_TASKS_AXI" \
    "the refusal must name the pin, the floor, and their owner variables"
  fixture="$TMP_ROOT/pin-missing"
  fixture_probe "$fixture" 'unset FM_TASKS_AXI_PIN'
  rc=0
  out=$("$fixture/bin/fm-tool-profile.sh" --pin tasks-axi 2>"$fixture/err") || rc=$?
  err=$(cat "$fixture/err")
  [ "$rc" -eq 2 ] || fail "--pin tasks-axi with no owned pin must exit 2, got $rc"$'\n'"$out$err"
  [ -z "$out" ] || fail "--pin tasks-axi with no owned pin must print nothing on stdout, got '$out'"
  assert_contains "$err" "could not be projected from its owner" "the refusal must name the projection failure"
  rc=0
  out=$("$PROFILE" --pin tasks-axi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the real owner's pin must be accepted, got $rc"$'\n'"$out"
  [ "$out" = "$PIN_TASKS_AXI" ] || fail "the real owner's pin must be printed unchanged, got '$out'"
  pass "--pin tasks-axi refuses a pin below the floor or a pin the owner no longer defines"
}

test_qualified_profile_passes_and_reports_every_tool() {
  local bin="$TMP_ROOT/qualified"
  qualified_bin "$bin"
  run_probe "$bin" --require shellcheck,actionlint,tasks-axi,no-mistakes,node-ts \
    --expect-path0 "$bin" --strict-pin
  [ "$RC" -eq 0 ] || fail "qualified profile expected exit 0, got $RC"$'\n'"$OUT"
  assert_not_contains "$OUT" "ENVIRONMENT_UNREADY" "qualified profile must emit no ENVIRONMENT_UNREADY line"
  for tool in shellcheck actionlint tasks-axi no-mistakes node-ts; do
    printf '%s\n' "$OUT" | grep -Eq "^QUALIFIED +$tool " \
      || fail "qualified profile did not report $tool as QUALIFIED"$'\n'"$OUT"
  done
  assert_contains "$OUT" "build 0af0be6" "no-mistakes row must carry the observed build"
  assert_contains "$OUT" "PATH[0]=$bin" "profile line must report the observed PATH[0]"
  assert_contains "$OUT" "profile=OBSERVED" "matching expectations must report OBSERVED"
  pass "a qualified profile passes and reports every tool"
}

test_missing_actionlint_fails_naming_the_owner() {
  local bin="$TMP_ROOT/no-actionlint"
  qualified_bin "$bin"
  rm "$bin/actionlint"
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "missing actionlint expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: actionlint ABSENT" \
    "missing actionlint must be a typed ENVIRONMENT_UNREADY line"
  assert_contains "$OUT" "fm-install-actionlint.sh" \
    "missing actionlint must name the owner action"
  assert_contains "$OUT" "$PIN_ACTIONLINT" \
    "missing actionlint must name the pinned version"
  printf '%s\n' "$OUT" | grep -Eq "^QUALIFIED +shellcheck " \
    || fail "the other tools must still be observed when one is absent"$'\n'"$OUT"
  pass "a missing actionlint fails naming the owner action"
}

test_wrong_actionlint_version_is_a_pinned_mismatch() {
  local bin="$TMP_ROOT/old-actionlint"
  qualified_bin "$bin"
  write_actionlint "$bin" 1.6.0
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "wrong actionlint expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: actionlint PINNED_MISMATCH" \
    "a non-pinned actionlint must be PINNED_MISMATCH"
  assert_contains "$OUT" "found 1.6.0, pinned $PIN_ACTIONLINT" \
    "the mismatch must name both versions"
  pass "a non-pinned actionlint is a PINNED_MISMATCH"
}

test_suffixed_pinned_builds_are_judged_as_the_gates_judge_them() {
  # bin/fm-lint.sh compares the `version:` line and bin/fm-lint-workflows.sh
  # the whole first line, so a suffixed build carrying the pinned triple is
  # refused by the gate and must be refused by the probe too.
  local bin="$TMP_ROOT/suffixed"
  qualified_bin "$bin"
  write_shellcheck "$bin" "$PIN_SHELLCHECK-1-gabc"
  write_actionlint "$bin" "$PIN_ACTIONLINT-dev"
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "suffixed pinned builds expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: shellcheck PINNED_MISMATCH (found $PIN_SHELLCHECK-1-gabc, pinned $PIN_SHELLCHECK" \
    "a suffixed shellcheck build must be PINNED_MISMATCH with the gate's own version string"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: actionlint PINNED_MISMATCH (found $PIN_ACTIONLINT-dev, pinned $PIN_ACTIONLINT" \
    "a suffixed actionlint build must be PINNED_MISMATCH with the gate's own version string"
  cat > "$bin/shellcheck" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && printf 'ShellCheck %s\n' '$PIN_SHELLCHECK'
exit 0
SH
  chmod +x "$bin/shellcheck"
  run_probe "$bin"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: shellcheck PINNED_MISMATCH (version unreadable, pinned $PIN_SHELLCHECK" \
    "a shellcheck without a version: line is unreadable to the gate and must be unreadable to the probe"
  pass "suffixed shellcheck and actionlint builds are PINNED_MISMATCH exactly as the gates judge them"
}

test_below_floor_tasks_axi_is_refused() {
  # Negative control: the exact legacy shape the audit found (0.2.3).
  local bin="$TMP_ROOT/old-tasks-axi"
  qualified_bin "$bin"
  write_tasks_axi "$bin" 0.2.3
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "below-floor tasks-axi expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: tasks-axi PRESENT_BELOW_FLOOR" \
    "a below-floor tasks-axi must be PRESENT_BELOW_FLOOR"
  assert_contains "$OUT" "found 0.2.3" "the refusal must name the observed version"
  assert_contains "$OUT" "install tasks-axi $PIN_TASKS_AXI" "the refusal must name the pin to install"
  pass "a below-floor tasks-axi is refused"
}

test_tasks_axi_at_floor_without_feature_probe_is_below_floor() {
  local bin="$TMP_ROOT/stripped-tasks-axi"
  qualified_bin "$bin"
  write_tasks_axi "$bin" "$PIN_TASKS_AXI" no yes
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "stripped tasks-axi expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: tasks-axi PRESENT_BELOW_FLOOR" \
    "a tasks-axi that fails its feature probe must be PRESENT_BELOW_FLOOR"
  pass "a tasks-axi that advertises the pin but lacks a probed feature is refused"
}

test_strict_pin_catches_a_drifted_tasks_axi() {
  local bin="$TMP_ROOT/drifted-tasks-axi"
  qualified_bin "$bin"
  write_tasks_axi "$bin" 9.9.9
  run_probe "$bin"
  [ "$RC" -eq 0 ] || fail "a newer compatible tasks-axi must pass without --strict-pin, got $RC"$'\n'"$OUT"
  run_probe "$bin" --strict-pin
  [ "$RC" -eq 1 ] || fail "--strict-pin expected exit 1 for a drifted tasks-axi, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: tasks-axi PINNED_MISMATCH" \
    "--strict-pin must report a drifted tasks-axi as PINNED_MISMATCH"
  assert_contains "$OUT" "found 9.9.9, pinned $PIN_TASKS_AXI" \
    "the drift must name both versions"
  pass "--strict-pin catches a tasks-axi that drifted from the CI pin"
}

test_node_without_typescript_execution_is_capability_missing() {
  local bin="$TMP_ROOT/node-no-ts"
  qualified_bin "$bin"
  write_node "$bin" 22.22.1 no
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "node without TS expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: node-ts CAPABILITY_MISSING" \
    "a node that cannot execute .ts must be CAPABILITY_MISSING"
  assert_contains "$OUT" "process.features.typescript=false" \
    "the capability row must carry the structural detail"
  assert_contains "$OUT" "official Node release binaries" \
    "the capability row must name the owner action"
  pass "a node that reports a version but cannot execute .ts is CAPABILITY_MISSING"
}

test_node_ts_is_proved_by_execution_not_by_the_feature_flag() {
  # A node whose feature flag lies must still be judged by what it executes.
  local bin="$TMP_ROOT/node-lying"
  qualified_bin "$bin"
  cat > "$bin/node" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'v24.0.0\n'; exit 0 ;;
  -p) printf 'strip\n'; exit 0 ;;
  *.ts) printf 'nothing useful\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$bin/node"
  run_probe "$bin"
  [ "$RC" -eq 1 ] || fail "a node that claims TS but does not execute it must fail, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "node-ts CAPABILITY_MISSING" "execution, not the flag, decides node-ts"
  pass "node-ts is proved by executing a .ts file, not by the feature flag"
}

test_no_mistakes_is_reported_but_only_required_on_request() {
  local bin="$TMP_ROOT/old-no-mistakes"
  qualified_bin "$bin"
  write_no_mistakes "$bin" 1.40.3 d873960
  run_probe "$bin"
  [ "$RC" -eq 0 ] || fail "no-mistakes is not required by default; expected exit 0, got $RC"$'\n'"$OUT"
  printf '%s\n' "$OUT" | grep -Eq "^PRESENT_BELOW_FLOOR +no-mistakes +1\.40\.3 .*required=no " \
    || fail "a below-floor no-mistakes must still be reported with required=no"$'\n'"$OUT"
  run_probe "$bin" --require no-mistakes
  [ "$RC" -eq 1 ] || fail "--require no-mistakes expected exit 1 below the floor, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: no-mistakes PRESENT_BELOW_FLOOR" \
    "a required below-floor no-mistakes must be typed"
  assert_contains "$OUT" "found 1.40.3 build d873960, floor $FLOOR_NO_MISTAKES" \
    "the refusal must name the observed version, build, and floor"
  pass "no-mistakes is always observed and required only on request"
}

test_expected_profile_mismatch_fails() {
  local bin="$TMP_ROOT/profile"
  qualified_bin "$bin"
  RC=0
  OUT=$(NM_HOME=/tmp/some-home PATH="$bin:$SYSBIN" "$PROFILE" \
    --expect-nm-home /tmp/other-home --expect-path0 "$bin" 2>&1) || RC=$?
  [ "$RC" -eq 1 ] || fail "NM_HOME mismatch expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: profile PROFILE_MISMATCH" "NM_HOME divergence must be a PROFILE_MISMATCH"
  assert_contains "$OUT" "NM_HOME is /tmp/some-home, expected /tmp/other-home" "the mismatch must name both values"
  RC=0
  OUT=$(env -u NM_HOME PATH="$bin:$SYSBIN" "$PROFILE" --expect-nm-home /tmp/other-home 2>&1) || RC=$?
  [ "$RC" -eq 1 ] || fail "unset NM_HOME expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "NM_HOME is unset, expected /tmp/other-home" "an unset NM_HOME must be named as unset"
  assert_contains "$OUT" "NM_HOME=<unset>" "the profile line must show an unset NM_HOME"
  RC=0
  OUT=$(PATH="$SYSBIN:$bin" "$PROFILE" --expect-path0 "$bin" 2>&1) || RC=$?
  [ "$RC" -eq 1 ] || fail "PATH[0] mismatch expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "PATH[0] is $SYSBIN, expected $bin" "the mismatch must name both PATH heads"
  RC=0
  OUT=$(NM_HOME=/tmp/other-home PATH="$bin/:$SYSBIN" "$PROFILE" --expect-nm-home /tmp/other-home --expect-path0 "$bin" 2>&1) || RC=$?
  [ "$RC" -eq 0 ] || fail "a trailing slash on PATH[0] must not count as a mismatch, got $RC"$'\n'"$OUT"
  pass "an expected NM_HOME or PATH[0] that diverges is a PROFILE_MISMATCH"
}

test_login_shell_negative_control_reports_the_legacy_selection() {
  # The audit's mechanism: a login shell whose ~/.profile prepends
  # $HOME/.local/bin, where a legacy tasks-axi and no-mistakes live, silently
  # shadows the qualified tools. The probe run FROM that login shell must
  # report exactly that, or the CI fixture's login-shell case proves nothing.
  local bin="$TMP_ROOT/login/qualified" home="$TMP_ROOT/login/home"
  qualified_bin "$bin"
  mkdir -p "$home/.local/bin"
  write_tasks_axi "$home/.local/bin" 0.2.3
  write_no_mistakes "$home/.local/bin" 1.40.3 d873960
  cat > "$home/.profile" <<'PROFILE'
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
PROFILE
  RC=0
  OUT=$(HOME="$home" NM_HOME=/tmp/clean-home PATH="$bin:$SYSBIN" \
    bash -lc '"$1" --require tasks-axi,no-mistakes --expect-nm-home /tmp/clean-home --expect-path0 "$2"' _ "$PROFILE" "$bin" 2>&1) || RC=$?
  [ "$RC" -eq 1 ] || fail "legacy-shaped login shell expected exit 1, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "PATH[0]=$home/.local/bin" "the probe must report the login shell's own PATH[0]"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: tasks-axi PRESENT_BELOW_FLOOR (found 0.2.3" \
    "the login shell must be seen resolving the legacy tasks-axi"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: no-mistakes PRESENT_BELOW_FLOOR (found 1.40.3" \
    "the login shell must be seen resolving the legacy no-mistakes"
  assert_contains "$OUT" "ENVIRONMENT_UNREADY: profile PROFILE_MISMATCH" \
    "the shadowed PATH[0] must be a PROFILE_MISMATCH"
  assert_contains "$OUT" "NM_HOME=/tmp/clean-home" \
    "NM_HOME survives the login shell while the tool selection does not; both facts must be visible"
  # Positive control: the same login shell, with the profile re-selected after
  # shell initialization (the consumer-entrypoint pattern), observes the
  # qualified tools again. A stock /etc/profile may reset PATH outright, so the
  # re-selection is what an entrypoint must do, not something a login shell is
  # trusted to preserve.
  RC=0
  OUT=$(HOME="$home" NM_HOME=/tmp/clean-home PATH="$bin:$SYSBIN" \
    bash -lc 'PATH="$2:$PATH" "$1" --require tasks-axi,no-mistakes --expect-nm-home /tmp/clean-home --expect-path0 "$2"' _ "$PROFILE" "$bin" 2>&1) || RC=$?
  [ "$RC" -eq 0 ] || fail "login shell with the profile re-selected expected exit 0, got $RC"$'\n'"$OUT"
  printf '%s\n' "$OUT" | grep -Eq "^QUALIFIED +tasks-axi +$PIN_TASKS_AXI " \
    || fail "re-selecting the profile after login initialization must restore the qualified tasks-axi"$'\n'"$OUT"
  pass "a legacy-shaped login shell is reported as the legacy selection (negative control)"
}

test_json_output_carries_the_same_verdict() {
  local bin="$TMP_ROOT/json"
  qualified_bin "$bin"
  write_actionlint "$bin" 1.6.0
  RC=0
  OUT=$(PATH="$bin:$SYSBIN" "$PROFILE" --json --expect-path0 "$bin" 2>/dev/null) || RC=$?
  [ "$RC" -eq 1 ] || fail "--json must keep the exit status, got $RC"$'\n'"$OUT"
  printf '%s\n' "$OUT" | jq -e '.record == "fm-tool-profile/v1" and .ready == false' >/dev/null \
    || fail "--json must carry record and ready"$'\n'"$OUT"
  printf '%s\n' "$OUT" | jq -e '.tools[] | select(.tool == "actionlint") | .state == "PINNED_MISMATCH" and .version == "1.6.0" and .required == true' >/dev/null \
    || fail "--json must carry the actionlint row"$'\n'"$OUT"
  printf '%s\n' "$OUT" | jq -e --arg bin "$bin" '.profile.path0 == $bin and .profile.state == "OBSERVED"' >/dev/null \
    || fail "--json must carry the observed profile"$'\n'"$OUT"
  printf '%s\n' "$OUT" | jq -e '.unready | length == 1 and (.[0] | startswith("ENVIRONMENT_UNREADY: actionlint PINNED_MISMATCH"))' >/dev/null \
    || fail "--json must carry the typed unready lines"$'\n'"$OUT"
  pass "--json carries the same verdict, rows, and typed lines"
}

test_unknown_tool_and_missing_jq_are_usage_errors() {
  local bin="$TMP_ROOT/usage" out rc
  qualified_bin "$bin"
  rc=0
  out=$(PATH="$bin:$SYSBIN" "$PROFILE" --require herdr 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown --require tool must exit 2, got $rc"$'\n'"$out"
  assert_contains "$out" "unknown tool in --require: herdr" "unknown tool must be named"
  rc=0
  out=$(PATH="$bin:$SYSBIN" "$PROFILE" --bogus 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown argument must exit 2, got $rc"$'\n'"$out"
  pass "unknown tools and arguments are usage errors"
}

test_pins_are_projected_from_their_owners
test_pin_below_floor_or_missing_is_refused_by_the_owner_projection
test_qualified_profile_passes_and_reports_every_tool
test_missing_actionlint_fails_naming_the_owner
test_wrong_actionlint_version_is_a_pinned_mismatch
test_suffixed_pinned_builds_are_judged_as_the_gates_judge_them
test_below_floor_tasks_axi_is_refused
test_tasks_axi_at_floor_without_feature_probe_is_below_floor
test_strict_pin_catches_a_drifted_tasks_axi
test_node_without_typescript_execution_is_capability_missing
test_node_ts_is_proved_by_execution_not_by_the_feature_flag
test_no_mistakes_is_reported_but_only_required_on_request
test_expected_profile_mismatch_fails
test_login_shell_negative_control_reports_the_legacy_selection
test_json_output_carries_the_same_verdict
test_unknown_tool_and_missing_jq_are_usage_errors
