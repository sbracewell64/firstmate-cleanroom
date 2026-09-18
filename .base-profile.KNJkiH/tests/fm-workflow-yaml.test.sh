#!/usr/bin/env bash
# Behavior of the shared workflow-YAML capability, through its public command.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
PARSER="$ROOT/bin/fm-workflow-yaml.sh"
TMP_ROOT=$(fm_test_tmproot fm-workflow-yaml)
cat > "$TMP_ROOT/workflow.yml" <<'YAML'
base: &base
  timeout-minutes: 20
jobs:
  tests-herdr:
    timeout-minutes: 75
    steps:
      - name: misleading artifact
        with:
          timeout-minutes: 999
      - <<: *base
        name: Run real-Herdr family (serial, required)
        run: |
          echo example
YAML
out=$("$PARSER" "$TMP_ROOT/workflow.yml") || fail "valid workflow did not parse"
python3 -c 'import json,sys; d=json.load(sys.stdin); j=d["jobs"]["tests-herdr"]; assert j["timeout-minutes"]==75; assert j["steps"][1]["timeout-minutes"]==20; assert j["steps"][0]["with"]["timeout-minutes"]==999' <<<"$out" || fail "nested YAML or anchor semantics changed"
pass "workflow YAML preserves job/step boundaries, nested misleading keys and anchors"
for content in 'jobs: [' '- list-root'; do
  printf '%s\n' "$content" > "$TMP_ROOT/invalid.yml"
  rc=0; out=$("$PARSER" "$TMP_ROOT/invalid.yml" 2>"$TMP_ROOT/error") || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid workflow succeeded"
  [ -z "$out" ] || fail "invalid workflow emitted success-shaped JSON"
done
pass "malformed YAML and a non-mapping root fail without a JSON result"
mkdir "$TMP_ROOT/no-parser"
rc=0; out=$(PATH="$TMP_ROOT/no-parser" "$BASH" "$PARSER" --probe 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "missing capability must exit 1"
assert_contains "$out" 'ENVIRONMENT_UNREADY: workflow-yaml CAPABILITY_MISSING' 'missing capability is typed'
pass "missing parser capability fails explicitly before workflow checks"
probe=$("$PARSER" --probe) || fail "installed parser capability not observed"
case "$probe" in python3$'\t'*|ruby$'\t'*) ;; *) fail "probe omitted selected backend" ;; esac
pass "probe reports the actual selected backend, version and path"
