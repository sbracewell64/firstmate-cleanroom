#!/usr/bin/env bash
# Structural regression tests for the enforcing-call-site inventory.
#
# The family this guards: bin/ ships an enforce, validate or refuse capability,
# every reference to it lives in tests/, and the guarded production path never
# calls it. The rule then reads as active while enforcing nothing. These tests
# prove the check fires on exactly that shape, including the case where an
# enforcing call is removed from a path that previously carried one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-enforcement-caller-check.sh"
INVENTORY="$ROOT/docs/enforcement-points.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-enforcement-callers.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

# write_fixture <repo>: a minimal tracked tree carrying one enforce subcommand
# and one enforce-style script, each reached from a production caller.
write_fixture() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  git -C "$repo" init -q

  cat > "$repo/bin/fm-widget.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
enforce() { [ -f "${1:-}" ]; }
case "${1:-}" in
  enforce) shift; enforce "$@" ;;
  *) exit 2 ;;
esac
FIX

  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/fm-widget.sh" enforce "$1"
FIX

  cat > "$repo/bin/fm-audit-check.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
exit 0
FIX

  cat > "$repo/tests/fm-widget.test.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
"$(dirname "$0")/../bin/fm-widget.sh" enforce /dev/null
FIX

  cat > "$repo/tests/fm-audit.test.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
"$(dirname "$0")/../bin/fm-audit-check.sh"
FIX

  # Calls the same capability but is deliberately absent from every CI lane.
  cat > "$repo/tests/fm-audit-extra.test.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
"$(dirname "$0")/../bin/fm-audit-check.sh" --extra
FIX

  # A stand-in harness: the check asks the repository's own runner which tests
  # CI schedules, so a fixture must answer that question the same way.
  cat > "$repo/bin/fm-test-run.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --list-ci-lanes) printf '%s\n' portable-serial ;;
  --list) [ "${3:-}" = portable-serial ] && printf '%s\n' tests/fm-audit.test.sh ;;
  *) exit 2 ;;
esac
FIX

  chmod +x "$repo/bin/"*.sh "$repo/tests/"*.sh
  write_fixture_inventory "$repo"
  git -C "$repo" add -A
}

write_fixture_inventory() {
  cat > "$1/docs/enforcement-points.json" <<'JSON'
{
  "version": 1,
  "entryPoints": [
    {
      "id": "bin/fm-widget.sh:enforce",
      "kind": "enforced",
      "invariant": "A widget is accepted only when its recorded file exists.",
      "guards": "runtime",
      "callSites": [{"path": "bin/fm-widget-consumer.sh", "via": "production"}]
    },
    {
      "id": "bin/fm-audit-check.sh",
      "kind": "enforced",
      "invariant": "The tracked widget inventory stays well formed.",
      "guards": "repository",
      "callSites": [{"path": "tests/fm-audit.test.sh", "via": "ci-suite"}]
    }
  ]
}
JSON
}

# set_inventory <repo> <jq-free python mutation>
mutate_fixture_inventory() {
  local repo=$1 mode=$2
  python3 - "$repo/docs/enforcement-points.json" "$mode" <<'PY'
import json
import sys
from pathlib import Path

path, mode = Path(sys.argv[1]), sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
entries = {entry["id"]: entry for entry in data["entryPoints"]}
if mode == "test-caller-as-production":
    entries["bin/fm-widget.sh:enforce"]["callSites"] = [
        {"path": "tests/fm-widget.test.sh", "via": "production"}
    ]
elif mode == "runtime-claims-ci-suite":
    entries["bin/fm-widget.sh:enforce"]["callSites"] = [
        {"path": "tests/fm-widget.test.sh", "via": "ci-suite"}
    ]
elif mode == "unscheduled-ci-suite":
    entries["bin/fm-audit-check.sh"]["callSites"] = [
        {"path": "tests/fm-audit-extra.test.sh", "via": "ci-suite"}
    ]
elif mode == "drop-widget":
    data["entryPoints"] = [e for e in data["entryPoints"] if e["id"] != "bin/fm-widget.sh:enforce"]
else:
    raise SystemExit(f"unknown mode: {mode}")
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  git -C "$repo" add -A
}

test_repository_inventory_passes() {
  local out
  out=$("$CHECK") || fail "repository enforcement-caller check failed"
  assert_contains "$out" "fm-enforcement-caller-check: ok entries=" \
    "check did not report the accounted entry points"
  assert_contains "$out" "call_sites=" "check did not report verified call sites"
  pass "every enforce-style entry point in bin/ names a verified enforcing call site"
}

test_known_good_repairs_still_have_production_callers() {
  python3 - "$INVENTORY" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
entries = {entry["id"]: entry for entry in data["entryPoints"]}
expected = {
    "bin/fm-startup-memory-budget.sh:enforce": "bin/fm-session-start.sh",
    "bin/fm-outbound-write-lib.sh:fm_outbound_send": "bin/fm-send.sh",
}
for entry_id, caller in expected.items():
    entry = entries.get(entry_id)
    if entry is None:
        raise SystemExit(f"{entry_id} is no longer accounted for")
    if entry.get("kind") != "enforced":
        raise SystemExit(f"{entry_id} is no longer declared as enforced")
    sites = {site["path"] for site in entry["callSites"] if site["via"] == "production"}
    if caller not in sites:
        raise SystemExit(f"{entry_id} no longer names {caller} as a production call site")
PY
  pass "the two already-repaired invariants still name their production callers"
}

test_removing_the_enforcing_call_fails() {
  local repo="$TMP_ROOT/regression"
  write_fixture "$repo"
  "$CHECK" --root "$repo" >/dev/null || fail "fixture with a wired enforcing call was rejected"

  # The exact family shape: the capability survives, the production caller stops
  # calling it, and only the test still does.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
printf 'accepted %s\n' "$1"
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"
  pass "omitting the enforcing call fails where the wired call previously passed"
}

test_comment_mention_is_not_a_call() {
  local repo="$TMP_ROOT/comment-only"
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
# Widgets are accepted only after fm-widget.sh enforce says so.
set -eu
printf 'accepted %s\n' "$1"
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"
  pass "a header comment naming the capability is not read as an enforcing call"
}

test_test_only_caller_is_not_evidence() {
  local repo="$TMP_ROOT/test-only"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" test-caller-as-production
  run_expect_failure "is not on the production surface" "$CHECK" --root "$repo"
  mutate_fixture_inventory "$repo" runtime-claims-ci-suite
  run_expect_failure "a runtime invariant needs a production caller" "$CHECK" --root "$repo"
  pass "a test caller is never accepted as evidence for a runtime invariant"
}

test_unscheduled_repository_gate_fails() {
  local repo="$TMP_ROOT/unscheduled"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" unscheduled-ci-suite
  run_expect_failure "is not scheduled into any CI lane" "$CHECK" --root "$repo"
  pass "a repository gate must be a test CI actually schedules, not merely a test that exists"
}

test_undeclared_entry_point_fails() {
  local repo="$TMP_ROOT/undeclared"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-widget
  run_expect_failure "undeclared enforce-style entry point" "$CHECK" --root "$repo"
  pass "a new enforce-style entry point cannot ship without being accounted for"
}

test_repository_inventory_passes
test_known_good_repairs_still_have_production_callers
test_removing_the_enforcing_call_fails
test_comment_mention_is_not_a_call
test_test_only_caller_is_not_evidence
test_unscheduled_repository_gate_fails
test_undeclared_entry_point_fails
