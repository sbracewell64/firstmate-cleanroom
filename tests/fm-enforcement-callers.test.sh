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
trap 'rm -rf "$TMP_ROOT"; fm_test_cleanup' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out
  if out=$("$@" 2>&1); then
    fail "expected failure containing '$expected'"
  fi
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

# write_fixture <repo>: a minimal tracked tree carrying one enforce subcommand
# dispatched on "$1", one dispatched through a variable assigned from "$1", and
# one enforce-style script, each reached from a production caller.
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

  # The same capability shape, dispatched on a variable the script assigned
  # from its own argument stream rather than on "$1" directly.
  cat > "$repo/bin/fm-gadget.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
CMD=${1:-}
shift || true
case "$CMD" in
  status)
    case "${1:-}" in
      brief) printf 'brief\n' ;;
      *) printf 'full\n' ;;
    esac
    ;;
  verify-gadget) [ -f "${1:-}" ] ;;
  *) exit 2 ;;
esac
FIX

  cat > "$repo/bin/fm-gadget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/fm-gadget.sh" verify-gadget "$1"
FIX

  # A sourced library whose enforce-verb function carries no fm_ prefix: its
  # functions are the entry points, whatever the repository names them.
  cat > "$repo/bin/fm-widget-shared.sh" <<'FIX'
#!/usr/bin/env bash
validate_widget_binding() {
  [ -n "${1:-}" ]
}
FIX

  cat > "$repo/bin/fm-widget-binding-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/fm-widget-shared.sh"
validate_widget_binding "$1"
FIX

  # An independent homonym: the same enforce-verb name, defined and called by a
  # file that never sources the library, so it is a different function.
  cat > "$repo/bin/fm-widget-homonym.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
validate_widget_binding() {
  [ "${1:-}" = local-only ]
}
validate_widget_binding "$1"
FIX

  # Defines an enforce-verb function and never calls it; neither does the script
  # that sources it. Only the test calls it.
  cat > "$repo/bin/fm-idle-lib.sh" <<'FIX'
#!/usr/bin/env bash
fm_idle_validate() {
  [ -n "${1:-}" ]
}
FIX

  cat > "$repo/bin/fm-idle.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/fm-idle-lib.sh"
printf 'idle\n'
FIX

  cat > "$repo/tests/fm-idle.test.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/../bin/fm-idle-lib.sh"
fm_idle_validate yes
FIX

  # An operator-invoked capability whose prose owner names the subcommand.
  cat > "$repo/bin/fm-manual.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  verify) [ -f "${2:-}" ] ;;
  *) exit 2 ;;
esac
FIX

  mkdir -p "$repo/docs"
  cat > "$repo/docs/manual.md" <<'FIX'
Run `bin/fm-manual.sh verify <file>` by hand when the record looks stale.
FIX

  # An undeclared bin/ subdirectory is not part of the production surface.
  # Long options in alias groups that mix a short option, both orderings.
  cat > "$repo/bin/fm-lever.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--enforce-lever) STRICT=1 ;;
    *) break ;;
  esac
  shift
done
[ "$STRICT" -eq 1 ]
FIX

  cat > "$repo/bin/fm-latch.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-latch|-verify) STRICT=1 ;;
    *) break ;;
  esac
  shift
done
[ "$STRICT" -eq 1 ]
FIX

  # A capability reached only from inside its own library.
  cat > "$repo/bin/fm-inner-lib.sh" <<'FIX'
#!/usr/bin/env bash
fm_inner_validate() {
  [ -n "${1:-}" ]
}
fm_inner_apply() {
  fm_inner_validate "$1" || return 1
}
FIX

  cat > "$repo/bin/fm-inner.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/fm-inner-lib.sh"
fm_inner_apply "$1"
FIX

  # An enforce-verb arm nested inside a function inside a loop.
  cat > "$repo/bin/fm-nested-arm.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      enforce-nested) printf 'nested\n' ;;
      *) break ;;
    esac
    shift
  done
}
main "$@"
FIX

  cat > "$repo/bin/fm-yaml-gate.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
exit 0
FIX

  cat > "$repo/.no-mistakes.yaml" <<'FIX'
steps:
  lint: 'bin/fm-yaml-gate.sh'
FIX

  mkdir -p "$repo/.github/workflows"
  cat > "$repo/.github/workflows/ci.yml" <<'FIX'
jobs:
  gate:
    steps:
      - run: bin/fm-yaml-gate.sh
FIX

  mkdir -p "$repo/bin/extra"
  cat > "$repo/bin/extra/fm-validate-thing.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
exit 0
FIX

  cat > "$repo/bin/extra/fm-widget-runner.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
      "id": "bin/fm-gadget.sh:verify-gadget",
      "kind": "enforced",
      "invariant": "A gadget is accepted only when its recorded file exists.",
      "guards": "runtime",
      "callSites": [{"path": "bin/fm-gadget-consumer.sh", "via": "production"}]
    },
    {
      "id": "bin/fm-widget-shared.sh:validate_widget_binding",
      "kind": "enforced",
      "invariant": "A widget binding is accepted only when it names something.",
      "guards": "runtime",
      "callSites": [{"path": "bin/fm-widget-binding-consumer.sh", "via": "production"}]
    },
    {
      "id": "bin/fm-nested-arm.sh:enforce-nested",
      "kind": "not-enforcement",
      "invariant": "A nested widget pass reports itself.",
      "reason": "A scratch arm that prints and refuses nothing."
    },
    {
      "id": "bin/fm-lever.sh:--enforce-lever",
      "kind": "not-enforcement",
      "invariant": "A lever is engaged only in strict mode.",
      "reason": "A scratch strictness flag with no caller yet."
    },
    {
      "id": "bin/fm-latch.sh:--verify-latch",
      "kind": "not-enforcement",
      "invariant": "A latch is closed only in strict mode.",
      "reason": "A scratch strictness flag with no caller yet."
    },
    {
      "id": "bin/fm-inner-lib.sh:fm_inner_validate",
      "kind": "enforced",
      "invariant": "An inner record is accepted only when it names something.",
      "guards": "runtime",
      "callSites": [{"path": "bin/fm-inner-lib.sh", "via": "production"}],
      "note": "Called by fm_inner_apply in its own library, which bin/fm-inner.sh traverses."
    },
    {
      "id": "bin/fm-yaml-gate.sh",
      "kind": "enforced",
      "invariant": "The widget gate runs in CI and in the local landing gate.",
      "guards": "repository",
      "callSites": [
        {"path": ".no-mistakes.yaml", "via": "production"},
        {"path": ".github/workflows/ci.yml", "via": "production"}
      ]
    },
    {
      "id": "bin/extra/fm-validate-thing.sh",
      "kind": "not-enforcement",
      "invariant": "A thing is inspected before it is shipped.",
      "reason": "A scratch helper kept beside the widget tools; it refuses nothing."
    },
    {
      "id": "bin/fm-idle-lib.sh:fm_idle_validate",
      "kind": "not-enforcement",
      "invariant": "An idle marker carries a name.",
      "reason": "A helper kept for a caller that does not exist yet."
    },
    {
      "id": "bin/fm-manual.sh:verify",
      "kind": "operator-invoked",
      "invariant": "A stale record is re-checked before it is trusted.",
      "reason": "A hand-run re-check with no automatic caller by design.",
      "documentedAt": ["docs/manual.md"]
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

# mutate_fixture_inventory <repo> <mode>: rewrite one declaration in place.
mutate_fixture_inventory() {
  local repo=$1 mode=$2
  shift 2
  python3 - "$repo/docs/enforcement-points.json" "$mode" "$@" <<'PY' || fail "could not mutate the fixture inventory for mode $mode"
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
elif mode == "drop-gadget":
    data["entryPoints"] = [e for e in data["entryPoints"] if e["id"] != "bin/fm-gadget.sh:verify-gadget"]
elif mode == "drop-shared-function":
    data["entryPoints"] = [
        e for e in data["entryPoints"] if e["id"] != "bin/fm-widget-shared.sh:validate_widget_binding"
    ]
elif mode == "drop-nested-arm":
    data["entryPoints"] = [
        e for e in data["entryPoints"] if e["id"] != "bin/fm-nested-arm.sh:enforce-nested"
    ]
elif mode == "drop-lever-flag":
    data["entryPoints"] = [
        e for e in data["entryPoints"] if e["id"] != "bin/fm-lever.sh:--enforce-lever"
    ]
elif mode == "drop-latch-flag":
    data["entryPoints"] = [
        e for e in data["entryPoints"] if e["id"] != "bin/fm-latch.sh:--verify-latch"
    ]
elif mode == "drop-self-call-note":
    entries["bin/fm-inner-lib.sh:fm_inner_validate"].pop("note", None)
elif mode == "drop-nested-script":
    data["entryPoints"] = [
        e for e in data["entryPoints"] if e["id"] != "bin/extra/fm-validate-thing.sh"
    ]
elif mode == "library-defines-but-never-calls":
    entry = entries["bin/fm-idle-lib.sh:fm_idle_validate"]
    entry["kind"] = "enforced"
    entry["guards"] = "runtime"
    entry.pop("reason", None)
    entry["callSites"] = [{"path": "bin/fm-idle-lib.sh", "via": "production"}]
elif mode == "documented-at-names-only-the-script":
    Path(sys.argv[3]).write_text(
        "The `bin/fm-manual.sh` command owns the re-check.\n", encoding="utf-8"
    )
elif mode == "undeclared-bin-subdirectory-as-production":
    entries["bin/fm-widget.sh:enforce"]["callSites"] = [
        {"path": "bin/extra/fm-widget-runner.sh", "via": "production"}
    ]
elif mode == "homonym-as-call-site":
    entries["bin/fm-widget-shared.sh:validate_widget_binding"]["callSites"] = [
        {"path": "bin/fm-widget-homonym.sh", "via": "production"}
    ]
elif mode == "rejected-site-is-a-real-call":
    entries["bin/fm-widget.sh:enforce"]["rejectedCallSites"] = [
        {"path": "bin/fm-widget-consumer.sh", "reason": "claimed to be prose"}
    ]
else:
    raise SystemExit(f"unknown mode: {mode}")
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  git -C "$repo" add -A
}

# known_good_callers <inventory>: the two already-repaired instances of this
# family must still be declared enforced and still name their production caller.
known_good_callers() {
  python3 - "$1" <<'PY'
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
}

# drop_call_site <src> <dst> <entry-id> <caller>: copy the inventory with one
# declared production call site removed.
drop_call_site() {
  python3 - "$@" <<'PY' || fail "could not write the mutated known-good inventory"
import json
import sys
from pathlib import Path

src, dst, entry_id, caller = sys.argv[1:5]
data = json.loads(Path(src).read_text(encoding="utf-8"))
for entry in data["entryPoints"]:
    if entry["id"] == entry_id:
        entry["callSites"] = [s for s in entry["callSites"] if s["path"] != caller]
        break
else:
    raise SystemExit(f"{entry_id} is not in {src}")
Path(dst).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

test_repository_inventory_passes() {
  local out
  out=$("$CHECK") || fail "repository enforcement-caller check failed"
  assert_contains "$out" "fm-enforcement-caller-check: ok entries=" \
    "check did not report the accounted entry points"
  assert_contains "$out" "call_sites=" "check did not report verified call sites"
  assert_contains "$out" "rejected_call_sites=" \
    "check did not report the recorded near-miss call sites it re-rejected"
  pass "every enforce-style entry point in bin/ declares a call site that still names it"
}

test_known_good_repairs_still_have_production_callers() {
  local mutated
  known_good_callers "$INVENTORY" \
    || fail "an already-repaired invariant no longer names its production caller"

  # Prove the assertion has teeth rather than trusting that it ran: drop each
  # known-good caller in a copy and require the same predicate to reject it.
  mutated="$TMP_ROOT/known-good-without-session-start.json"
  drop_call_site "$INVENTORY" "$mutated" \
    bin/fm-startup-memory-budget.sh:enforce bin/fm-session-start.sh
  if known_good_callers "$mutated" >/dev/null 2>&1; then
    fail "dropping bin/fm-session-start.sh did not break the known-good assertion"
  fi

  mutated="$TMP_ROOT/known-good-without-send.json"
  drop_call_site "$INVENTORY" "$mutated" \
    bin/fm-outbound-write-lib.sh:fm_outbound_send bin/fm-send.sh
  if known_good_callers "$mutated" >/dev/null 2>&1; then
    fail "dropping bin/fm-send.sh did not break the known-good assertion"
  fi

  pass "the two already-repaired invariants still name their production callers, provably"
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

test_trailing_comment_is_not_a_call() {
  local repo="$TMP_ROOT/trailing-comment"

  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
mkdir -p "${TMPDIR:-/tmp}/widgets"   # widgets are gated by fm-widget.sh enforce upstream
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-binding-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/fm-widget-shared.sh"
mkdir -p "$DIR/.bound"   # the binding is taken by validate_widget_binding elsewhere
FIX
  git -C "$repo" add -A
  run_expect_failure "no production call site" "$CHECK" --root "$repo"

  # A quoted # is not a comment, and the capability sits on the same line, so a
  # stripper that splits on the first # at all destroys a genuine call.
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1#--}" = enforce ] && "$DIR/fm-widget.sh" enforce "$1"
FIX
  git -C "$repo" add -A
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a \${VAR#pattern} expansion was mistaken for a trailing comment"
  pass "a trailing comment naming a capability is not read as an enforcing call"
}

test_hash_comment_surfaces_share_one_rule() {
  local repo="$TMP_ROOT/hash-comments"

  # The two hash-comment production surfaces, held to the shell caller's rule.
  write_fixture "$repo"
  cat > "$repo/.no-mistakes.yaml" <<'FIX'
steps:
  lint: 'true'   # bin/fm-yaml-gate.sh runs in the gate
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  write_fixture "$repo"
  cat > "$repo/.github/workflows/ci.yml" <<'FIX'
jobs:
  gate:
    steps:
      - run: true   # bin/fm-yaml-gate.sh runs in the gate
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  # A quoted # inside a YAML scalar is data, not a comment, and the capability
  # sits after it, so a stripper that cuts at the first # destroys the reference.
  write_fixture "$repo"
  cat > "$repo/.no-mistakes.yaml" <<'FIX'
steps:
  lint: 'echo "#1" && bin/fm-yaml-gate.sh'
FIX
  git -C "$repo" add -A
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a quoted # in a YAML scalar was mistaken for a comment"
  pass "a trailing # comment is prose on every hash-comment surface, not only in shell"
}

test_mixed_flag_alias_group_is_discovered() {
  local repo="$TMP_ROOT/flag-alias"

  # Only the long alternatives are capabilities, so `-verify` beside
  # `--verify-latch` must not become an entry point of its own.
  write_fixture "$repo"
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a short alternative in an alias group was discovered as a capability"

  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-lever-flag
  run_expect_failure "bin/fm-lever.sh:--enforce-lever" "$CHECK" --root "$repo"

  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-latch-flag
  run_expect_failure "bin/fm-latch.sh:--verify-latch" "$CHECK" --root "$repo"
  pass "a long option stays discovered in an alias group that mixes a short option"
}

test_self_call_site_requires_a_traverser_note() {
  local repo="$TMP_ROOT/self-call-note"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-self-call-note
  run_expect_failure "must carry a note" "$CHECK" --root "$repo"
  pass "a function reached only inside its own library must record what traverses it"
}

test_spaced_heredoc_body_is_stripped() {
  local repo="$TMP_ROOT/spaced-heredoc"

  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
cat << NOTE
Handle with real tools: bin/fm-widget.sh enforce <widget> when a widget is reported.
NOTE
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
cat <<- 'NOTE'
Handle with real tools: bin/fm-widget.sh enforce <widget> when a widget is reported.
NOTE
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"
  pass "a heredoc whose delimiter follows whitespace still has its body stripped"
}

test_nested_bin_script_is_still_discovered() {
  local repo="$TMP_ROOT/nested-discovery"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-nested-script
  run_expect_failure "bin/extra/fm-validate-thing.sh" "$CHECK" --root "$repo"
  pass "an enforce-named script under a new bin/ subdirectory must still be declared"
}

test_emitted_operator_text_is_not_a_call() {
  local repo="$TMP_ROOT/emitted-prose"
  write_fixture "$repo"
  # Both prose shapes the sweep found in real callers: a printf of operator
  # next-step text, and a quoted heredoc that renders a tool list.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
printf 'next: firstmate runs bin/fm-widget.sh enforce before the widget lands\n'
cat <<'NOTE'
Handle with real tools: `bin/fm-widget.sh enforce <widget>` when a widget is reported.
NOTE
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  # The same prose split across a continuation is still the printf's argument.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
printf '%s\n' \
  "next: run bin/fm-widget.sh enforce before the widget lands"
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  # The rule drops emitted argument text, not the whole line: a real call on the
  # other side of a pipe is still enforcement.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$1" | "$DIR/fm-widget.sh" enforce "$1"
FIX
  git -C "$repo" add -A
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a genuine call piped from an emitting command was read as prose"
  pass "a capability named only in emitted operator text is not read as an enforcing call"
}

test_recorded_rejected_site_must_stay_rejected() {
  local repo="$TMP_ROOT/rejected-sites"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" rejected-site-is-a-real-call
  run_expect_failure "now reads as a real call" "$CHECK" --root "$repo"
  pass "a recorded near-miss call site that is really a call is refused, not quietly counted"
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

test_deeply_indented_arm_is_discovered() {
  local repo="$TMP_ROOT/indented-arm"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-nested-arm
  run_expect_failure "bin/fm-nested-arm.sh:enforce-nested" "$CHECK" --root "$repo"
  pass "an arm nested inside a function and a loop is still discovered"
}

test_emitted_prose_after_an_opener_is_not_a_call() {
  local repo="$TMP_ROOT/opener-prose"

  # An emitting command after `then`.
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
if [ -z "${1:-}" ]; then echo "run bin/fm-widget.sh enforce <widget>"; fi
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  # An emitting command after a case-arm label.
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  help) printf 'run bin/fm-widget.sh enforce <widget>\n' ;;
  *) exit 2 ;;
esac
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"

  # An emitting command after a brace group.
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
[ "${rc:-0}" -le 1 ] || { echo "error: bin/fm-widget.sh enforce could not observe" >&2; exit 2; }
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"
  pass "emitted prose after then, a case-arm label or a brace group is not a call"
}

test_dispatch_arms_survive_lexical_case_shapes() {
  local repo="$TMP_ROOT/dispatch-shapes"

  # A `case` token inside a quoted message is not a nested block.
  write_fixture "$repo"
  cat > "$repo/bin/fm-gadget.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
CMD=${1:-}
shift || true
case "$CMD" in
  status) printf 'no matching case for %s\n' "${1:-}" ;;
  verify-gadget) [ -f "${1:-}" ] ;;
  *) exit 2 ;;
esac
FIX
  mutate_fixture_inventory "$repo" drop-gadget
  run_expect_failure "bin/fm-gadget.sh:verify-gadget" "$CHECK" --root "$repo"

  # Nor is an `esac` token inside one.
  write_fixture "$repo"
  cat > "$repo/bin/fm-gadget.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
CMD=${1:-}
shift || true
case "$CMD" in
  status) printf 'unknown esac\n' ;;
  verify-gadget) [ -f "${1:-}" ] ;;
  *) exit 2 ;;
esac
FIX
  mutate_fixture_inventory "$repo" drop-gadget
  run_expect_failure "bin/fm-gadget.sh:verify-gadget" "$CHECK" --root "$repo"
  pass "a case or esac token in a quoted message does not truncate arm discovery"
}

test_undeclared_variable_dispatch_subcommand_fails() {
  local repo="$TMP_ROOT/undeclared-dispatch"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-gadget
  run_expect_failure "bin/fm-gadget.sh:verify-gadget" "$CHECK" --root "$repo"
  pass "a subcommand dispatched through a variable assigned from \$1 is discovered too"
}

test_undeclared_sourced_library_function_fails() {
  local repo="$TMP_ROOT/undeclared-library"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" drop-shared-function
  run_expect_failure "bin/fm-widget-shared.sh:validate_widget_binding" "$CHECK" --root "$repo"
  pass "an enforce-verb function in a sourced library is discovered without an fm_ prefix"
}

test_quoted_shift_does_not_start_a_heredoc() {
  local repo="$TMP_ROOT/phantom-heredoc"
  write_fixture "$repo"
  # Neither `<<EOF` inside a quoted usage string nor the `<<` of an arithmetic
  # shift is a redirection; reading either as one would swallow the real call.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { printf '%s\n' "usage: fm-widget-consumer.sh <widget>, or feed a batch with <<EOF"; }
lane_mask() { local n=$1; printf '%s\n' "$((1<<n))"; }
bare_mask() { local n=$1; if (( 1 << n )); then printf 'wide\n'; fi; }
"$DIR/fm-widget.sh" enforce "$1"
FIX
  git -C "$repo" add -A
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a quoted heredoc word or an arithmetic shift swallowed the enforcing call below it"
  pass "a <<WORD inside quotes or an arithmetic shift does not start a phantom heredoc"
}

test_homonym_without_the_library_is_not_a_caller() {
  local repo="$TMP_ROOT/homonym"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" homonym-as-call-site
  run_expect_failure "never sources bin/fm-widget-shared.sh" "$CHECK" --root "$repo"
  pass "a file that defines its own function of the same name is not the library's caller"
}

test_one_line_definition_keeps_its_body() {
  local repo="$TMP_ROOT/one-line-definition"
  write_fixture "$repo"
  cat > "$repo/bin/fm-widget-binding-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/fm-widget-shared.sh"
guard_it() { validate_widget_binding "$1"; }
guard_it "$1"
FIX
  git -C "$repo" add -A
  "$CHECK" --root "$repo" >/dev/null \
    || fail "a call inside a single-line function definition was discarded with its header"
  pass "a single-line function definition keeps the call in its body"
}

test_heredoc_in_a_quoted_command_substitution_is_stripped() {
  local repo="$TMP_ROOT/quoted-command-substitution"
  write_fixture "$repo"
  # The capability is named only inside a heredoc opened within "$( ... )", so
  # the opener sits in a double-quoted region but in command context.
  cat > "$repo/bin/fm-widget-consumer.sh" <<'FIX'
#!/usr/bin/env bash
set -eu
MSG="$(cat <<'NOTE'
Handle with real tools: bin/fm-widget.sh enforce <widget> when a widget is reported.
NOTE
)"
printf '%s\n' "$MSG"
FIX
  git -C "$repo" add -A
  run_expect_failure "does not call it" "$CHECK" --root "$repo"
  pass "operator prose in a heredoc opened inside a command substitution is not read as a call"
}

test_defining_a_function_is_not_calling_it() {
  local repo="$TMP_ROOT/definition-only"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" library-defines-but-never-calls
  run_expect_failure "no production call site" "$CHECK" --root "$repo"
  pass "a library that only defines its capability is not its own caller"
}

test_documented_at_must_name_the_capability() {
  local repo="$TMP_ROOT/documented-at"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" documented-at-names-only-the-script "$repo/docs/manual.md"
  run_expect_failure "does not name \`fm-manual.sh verify\`" "$CHECK" --root "$repo"
  pass "an operator-invoked entry needs a prose owner that names the capability, not just the script"
}

test_undeclared_bin_subdirectory_is_not_production() {
  local repo="$TMP_ROOT/bin-subdirectory"
  write_fixture "$repo"
  mutate_fixture_inventory "$repo" undeclared-bin-subdirectory-as-production
  run_expect_failure "is not on the production surface" "$CHECK" --root "$repo"
  pass "a script under an undeclared bin/ subdirectory is not silently production"
}

test_repository_inventory_passes
test_known_good_repairs_still_have_production_callers
test_removing_the_enforcing_call_fails
test_comment_mention_is_not_a_call
test_trailing_comment_is_not_a_call
test_hash_comment_surfaces_share_one_rule
test_mixed_flag_alias_group_is_discovered
test_self_call_site_requires_a_traverser_note
test_spaced_heredoc_body_is_stripped
test_nested_bin_script_is_still_discovered
test_emitted_operator_text_is_not_a_call
test_recorded_rejected_site_must_stay_rejected
test_test_only_caller_is_not_evidence
test_unscheduled_repository_gate_fails
test_undeclared_entry_point_fails
test_undeclared_variable_dispatch_subcommand_fails
test_dispatch_arms_survive_lexical_case_shapes
test_deeply_indented_arm_is_discovered
test_emitted_prose_after_an_opener_is_not_a_call
test_undeclared_sourced_library_function_fails
test_quoted_shift_does_not_start_a_heredoc
test_homonym_without_the_library_is_not_a_caller
test_one_line_definition_keeps_its_body
test_heredoc_in_a_quoted_command_substitution_is_stripped
test_defining_a_function_is_not_calling_it
test_documented_at_must_name_the_capability
test_undeclared_bin_subdirectory_is_not_production
