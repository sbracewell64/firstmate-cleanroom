#!/usr/bin/env bash
# The remote handoff fixture must fail fast, never hang.
#
# Observed 2026-09-06 on CI run 34000833102, job "Behavior portable serial 2":
# tests/fm-remote-backlog-handoff.test.sh printed "not ok - first serialized
# handoff never reached receipt" at 01:07:21, its exit trap then waited forever
# on a background handoff parked in the fake-ssh serialize gate that nothing
# released, and the runner cancelled the whole shard at the 30-minute job cap
# with no verdict for any later script. This pins the repaired contract from
# the outside: force that exact assertion through the fixture's receipt-gate
# override, then prove the failing fixture exits on its own well inside a hang
# guard, its cleanup completes within seconds of the assertion, and no fixture
# process or temp root outlives it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
SUBJECT="$ROOT/tests/fm-remote-backlog-handoff.test.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-handoff-failfast)
# The subject's every temp path lives under this directory, so leak checks can
# name exactly what the failed fixture was responsible for and nothing else.
INNER="$TMP_ROOT/inner"
mkdir -p "$INNER"
OUT="$TMP_ROOT/subject.out"
# The outer bound only has to sit far below the CI shard cap; the cleanup bound
# below is the claim under test.
HANG_GUARD_SECONDS=300
CLEANUP_BOUND_SECONDS=20

set +e
FM_REMOTE_HANDOFF_RECEIPT_GATE_SECONDS=0 TMPDIR="$INNER" FM_TEST_SKIP_ORPHAN_REAP=1 \
  fm_run_timed "$HANG_GUARD_SECONDS" bash "$SUBJECT" > "$OUT" 2>&1
rc=$?
set -e
ended_at=$(date +%s)

[ "$rc" -ne 124 ] || fail "the failing fixture hung past the ${HANG_GUARD_SECONDS}s guard instead of terminating"
[ "$rc" -ne 0 ] || fail "the forced receipt deadline did not fail the fixture"$'\n'"--- fixture output ---"$'\n'"$(cat "$OUT")"
# The forced failure must land exactly where CI failed: after the earlier
# stages passed and with the first serialized handoff already in flight.
assert_grep 'ok - dropped transfer recovery overwrites scratch and delivers exactly once' "$OUT" \
  "the fixture did not reach the serialized handoff stage before failing"$'\n'"--- fixture output ---"$'\n'"$(cat "$OUT")"
assert_grep 'not ok - first serialized handoff never reached receipt' "$OUT" \
  "the forced receipt deadline did not fail the serialized handoff assertion"$'\n'"--- fixture output ---"$'\n'"$(cat "$OUT")"
pass "a forced receipt deadline fails the serialized handoff assertion instead of passing"

# The assertion line is the fixture's last write to its output, so the file's
# mtime is when the failure fired and everything after it is cleanup.
failed_at=$(stat -c %Y "$OUT" 2>/dev/null || stat -f %m "$OUT" 2>/dev/null) \
  || fail "cannot read the fixture output's modification time"
cleanup_seconds=$((ended_at - failed_at))
[ "$cleanup_seconds" -le "$CLEANUP_BOUND_SECONDS" ] \
  || fail "cleanup after the failed assertion took ${cleanup_seconds}s, above the ${CLEANUP_BOUND_SECONDS}s bound"
pass "a failed assertion terminates the fixture within ${CLEANUP_BOUND_SECONDS}s (took ${cleanup_seconds}s)"

leaked=$(pgrep -f -- "$INNER" 2>/dev/null || true)
if [ -n "$leaked" ]; then
  ps -o pid,ppid,args -p "$(printf '%s' "$leaked" | tr '\n' ',')" >&2 || true
  fail "fixture processes outlived the failed fixture: $(printf '%s' "$leaked" | tr '\n' ' ')"
fi
pass "no background handoff, fake ssh, or remote worker outlives the failed fixture"

remaining=$(find "$INNER" -mindepth 1 -maxdepth 1 -name 'fm-remote-handoff.*' 2>/dev/null || true)
[ -z "$remaining" ] || fail "the failed fixture left its temp root behind: $remaining"
pass "the failed fixture removes its temp root"

echo "ALL TESTS PASSED"
