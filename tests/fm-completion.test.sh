#!/usr/bin/env bash
# Real stage/resume/drain callers in private state. The no-mistakes CLI is the
# sole substituted authority boundary; it serves read-only canonical records.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-completion)
fm_git_identity fmtest fmtest@example.invalid
export FM_HOME="$TMP_ROOT/home" FM_BACKEND=tmux
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
export NM_HOME="$TMP_ROOT/nm"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE/source" "$NM_HOME" "$FM_HOME/config"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '{"pid":4242,"started_at":"2026-09-06T00:00:00Z"}\n' > "$NM_HOME/daemon.pid"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/canonical"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  --version) echo 'no-mistakes version v1.61.0 (0af0be6) 2026-08-31T14:04:25Z' ;;
  'axi status'*) cat "$FM_COMPLETION_TEST_CANONICAL" ;;
  *) echo 'unexpected non-read authority call' >&2; exit 90 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"
WT="$TMP_ROOT/worktree"
mkdir "$WT"
git -C "$WT" init -q
git -C "$WT" checkout -qb fm/source
printf 'commands:\n  lint: true\n' > "$WT/.no-mistakes.yaml"
git -C "$WT" add .no-mistakes.yaml
git -C "$WT" commit -qm candidate
HEAD=$(git -C "$WT" rev-parse HEAD)
fm_write_meta "$FM_STATE_OVERRIDE/source.meta" "worktree=$WT" "project=$WT" \
  'harness=echo' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=s1.1.1'
printf '# Task\nPrivate continuation fixture\n' > "$FM_DATA_OVERRIDE/source/brief.md"
canonical() {
  printf 'run:\n  id: "01SOURCE"\n  branch: fm/source\n  status: %s\n  head: "%s"\n  pr: "https://github.com/o/r/pull/7"\n' "$1" "$HEAD" > "$FM_COMPLETION_TEST_CANONICAL"
  [ -z "${2:-}" ] || printf 'outcome: %s\n' "$2" >> "$FM_COMPLETION_TEST_CANONICAL"
}
meta() { sed -n "s/^$1=//p" "$FM_STATE_OVERRIDE/source.meta"; }
stage() { "$ROOT/bin/fm-stage.sh" source "$@"; }
canonical running
stage committed > "$TMP_ROOT/committed" || fail "fixture admission: $(cat "$TMP_ROOT/committed")"
stage running --run 01SOURCE > "$TMP_ROOT/running" || fail "fixture run binding: $(cat "$TMP_ROOT/running")"
cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/initial.meta"
cp "$FM_STATE_OVERRIDE/source.nm-observe" "$TMP_ROOT/initial.observe"
printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
jq -n --arg candidate "$HEAD" --arg attempt "$(meta stage_attempt)" \
  --arg report "$FM_DATA_OVERRIDE/source/report.md" \
  --arg digest "$(shasum -a 256 "$FM_DATA_OVERRIDE/source/report.md" | cut -d' ' -f1)" \
  '{schema:"fm-completion-handoff/v1",task:"source",generation:"s1.1.1",attempt:$attempt,run:"01SOURCE",candidate:$candidate,source_head:$candidate,
    report:{path:$report,sha256:$digest},action:{id:"ci",kind:"ci-ready",owner:"source",generation:"s1.1.1",pr:"https://github.com/o/r/pull/7"}}' \
  > "$TMP_ROOT/handoff.json"

test_show_refreshes_stale_completed_run() {
  local out rc=0
  canonical completed checks-passed
  out=$(stage show) || rc=$?
  assert_contains "$(cat "$FM_STATE_OVERRIDE/source.nm-observe")" 'outcome_class=ci-ready' 'actual resume caller must refresh a stale running cache'
  expect_code 1 "$rc" 'completed report without admitted action remains CNO'
  assert_contains "$out" HANDOFF_UNBOUND 'missing action authority must be visible'
  pass 'actual stage show refreshes canonical completion and refuses an unbound report'
}

test_resume_completed_report_without_wake() {
  local out identity
  out=$(stage handoff --handoff-json "$TMP_ROOT/handoff.json") || fail "handoff admission: $out"
  identity=$(meta completion_handoff | jq -r .identity)
  canonical completed checks-passed
  out=$("$ROOT/bin/fm-continuation-resolve.sh" reconcile) || fail "resume: $out"
  assert_contains "$out" 'reason=manager-capacity' 'full capacity must preserve the owner'
  [ "$(meta stage)" = validation-running ] || fail 'capacity pending must not advance stage'
  assert_contains "$(cat "$FM_STATE_OVERRIDE/source.nm-observe")" 'outcome_class=ci-ready' 'stale cache must refresh without a wake'
  out=$(stage handoff-release --identity "$identity") || fail "release: $out"
  assert_contains "$out" 'COMPLETION_DISPATCHED:' 'release must dispatch the eligible stage'
  [ "$(meta stage)" = ci-ready ] || fail 'real stage owner must establish CI-ready'
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'effect receipt absent'
  pass 'resume refreshes completed canonical state without a wake and dispatches once after manager release'
}

test_duplicate_and_changed_bytes() {
  local before out rc
  before=$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")
  out=$("$ROOT/bin/fm-continuation-resolve.sh" reconcile) || fail "duplicate: $out"
  [ "$before" = "$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")" ] || fail 'duplicate resume repeated stage receipt'
  printf 'changed bytes\n' >> "$FM_DATA_OVERRIDE/source/report.md"
  rc=0; out=$(stage resume-handoff) || rc=$?
  expect_code 1 "$rc" 'same identity with changed report bytes refuses'
  assert_contains "$out" REPORT_CHANGED 'changed-byte refusal'
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'adverse evidence erased prior receipt'
  pass 'same report replay deduplicates and changed report bytes refuse without erasing evidence'
}

test_authoritative_effect_repairs_missing_receipt() {
  local before saved out
  before=$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")
  # Construct the crash boundary: the actual stage effect already succeeded,
  # but the following handoff receipt was not committed. No stage is invented.
  saved=$(meta completion_handoff | jq -c '.receipt=null | .status="pending"')
  sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/crash.meta"
  printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/crash.meta"
  mv "$TMP_ROOT/crash.meta" "$FM_STATE_OVERRIDE/source.meta"
  out=$(stage resume-handoff) || fail "effect recovery: $out"
  assert_contains "$out" COMPLETION_DISPATCHED 'missing receipt must be reconstructed'
  [ "$before" = "$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")" ] || fail 'receipt recovery repeated the stage effect'
  pass 'authoritative completed stage repairs a missing handoff receipt without replay'
}

test_positive_receipt_retirement_archive() {
  local out rc=0
  # A direct portable lifecycle-owner call avoids unrelated endpoint teardown.
  # The prior test produced its receipt via the real CI-ready stage effect.
  out=$(bash -c '
    SCRIPT_DIR=$1/bin
    . "$SCRIPT_DIR/fm-completion-lib.sh"
    fm_completion_retire "$2" "$3" source
  ' _ "$ROOT" "$(meta completion_handoff)" "$FM_DATA_OVERRIDE") || rc=$?
  expect_code 0 "$rc" "closed stage receipt archive: $out"
  [ "$(cat "$FM_DATA_OVERRIDE/source/completion-receipt.json")" = "$(meta completion_handoff)" ] || fail 'retirement archive lost contract/receipt bytes'
  pass 'positive stage-effect receipt retirement preserves the exact non-executable durable archive (portable owner-level call)'
}

test_canonical_read_failure_keeps_receipt() {
  local saved out rc=0
  saved=$(meta completion_handoff)
  mv "$FM_COMPLETION_TEST_CANONICAL" "$FM_COMPLETION_TEST_CANONICAL.saved"
  out=$(stage resume-handoff 2>&1) || rc=$?
  mv "$FM_COMPLETION_TEST_CANONICAL.saved" "$FM_COMPLETION_TEST_CANONICAL"
  expect_code 1 "$rc" 'unreadable canonical state must refuse'
  assert_contains "$out" CANONICAL_READ_FAILED 'failed canonical read cannot reuse cached green'
  [ "$saved" = "$(meta completion_handoff)" ] || fail 'canonical read failure rewrote evidence'
  pass 'canonical read failure preserves receipt and refuses cached success'
}

test_handled_inbox_keeps_open_action_and_deduplicates() {
  local out identity before saved rc
  # Independent handoff scenario using the already exercised canonical source
  # binding. The receiver transport is the real durable inbox, not a model.
  sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/inbox.meta"
  mv "$TMP_ROOT/inbox.meta" "$FM_STATE_OVERRIDE/source.meta"
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  fm_write_meta "$FM_STATE_OVERRIDE/receiver.meta" 'kind=ship' 'spawn_gen=s2.1.1' 'harness=echo'
  jq '.action={id:"handoff",kind:"task-inbox",owner:"receiver",generation:"s2.1.1",instruction:"Consume the admitted report and continue the existing action."}' \
    "$TMP_ROOT/handoff.json" > "$TMP_ROOT/inbox.json"
  out=$(stage handoff --handoff-json "$TMP_ROOT/inbox.json") || fail "inbox admission: $out"
  identity=$(meta completion_handoff | jq -r .identity)
  printf 'blocked [key=dependency]: manager-owned dependency\n' >> "$FM_STATE_OVERRIDE/source.status"
  out=$(stage handoff-release --identity "$identity") || fail "held release: $out"
  assert_contains "$out" dependency-held 'dependency hold must preserve pending owner'
  [ "$(meta completion_handoff | jq -r .reason)" = dependency-held ] || fail 'exact dependency disposition was not durable'
  assert_absent "$FM_STATE_OVERRIDE/receiver.inbox/001.msg" 'held action dispatched'
  printf 'resolved [key=dependency]: dependency released\n' >> "$FM_STATE_OVERRIDE/source.status"
  out=$("$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "drain continuation: $out"
  assert_present "$FM_STATE_OVERRIDE/receiver.inbox/001.msg" 'drain must reconcile the admitted handoff'
  before=$(shasum -a 256 "$FM_STATE_OVERRIDE/receiver.inbox/001.msg")
  mv "$FM_STATE_OVERRIDE/receiver.inbox/001.msg" "$FM_STATE_OVERRIDE/receiver.inbox/handled/001.msg"
  saved=$(meta completion_handoff | jq -c '.receipt=null | .status="pending"')
  sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/lost-receipt.meta"
  printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/lost-receipt.meta"
  mv "$TMP_ROOT/lost-receipt.meta" "$FM_STATE_OVERRIDE/source.meta"
  out=$(stage resume-handoff) || fail "handled recovery: $out"
  assert_contains "$out" downstream-action-unconfirmed 'handled inbox is not action completion'
  assert_absent "$FM_STATE_OVERRIDE/receiver.inbox/002.msg" 'handled replay duplicated dispatch'
  [ "${before%% *}" = "$(shasum -a 256 "$FM_STATE_OVERRIDE/receiver.inbox/handled/001.msg" | cut -d' ' -f1)" ] || fail 'handled bytes changed'
  rc=0; out=$("$ROOT/bin/fm-teardown.sh" source 2>&1) || rc=$?
  expect_code 1 "$rc" 'unresolved completion must prevent lifecycle retirement'
  assert_contains "$out" 'completion handoff remains unresolved' 'teardown must preserve the completion owner'
  assert_present "$FM_STATE_OVERRIDE/source.meta" 'teardown erased the unresolved contract'
  fm_write_meta "$FM_STATE_OVERRIDE/receiver.meta" 'kind=ship' 'spawn_gen=s3.1.1' 'harness=echo'
  rc=0; out=$(stage resume-handoff) || rc=$?
  expect_code 1 "$rc" 'different target generation refuses'
  assert_contains "$out" TARGET_GENERATION 'generation refusal'
  pass 'drain dispatches once after dependency release; handled replay repairs receipt and retains open downstream action'
}

test_stop_checkpoint_delayed_report_caller_chain() {
  local out identity cp rc command
  # Restore an independently admitted initial fixture, then vary only report
  # and canonical completion timing. This driver is not a native model loop.
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  : > "$FM_STATE_OVERRIDE/source.status"
  canonical running
  fm_write_meta "$FM_STATE_OVERRIDE/later.meta" 'kind=ship' 'spawn_gen=s4.1.1' 'harness=echo'
  jq '.action={id:"delayed",kind:"task-inbox",owner:"later",generation:"s4.1.1",instruction:"Continue the admitted delayed-report action."}' \
    "$TMP_ROOT/handoff.json" > "$TMP_ROOT/delayed.json"
  stage handoff --handoff-json "$TMP_ROOT/delayed.json" >/dev/null || fail 'delayed handoff registration'
  identity=$(meta completion_handoff | jq -r .identity)
  rm "$FM_DATA_OVERRIDE/source/report.md"
  stage handoff-release --identity "$identity" > "$TMP_ROOT/report-not-yet-readable" || true
  git -C "$FM_HOME" init -q
  cp -R "$ROOT/bin" "$FM_HOME/bin"
  cp -R "$ROOT/.codex" "$FM_HOME/.codex"
  : > "$FM_HOME/AGENTS.md"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$FM_HOME/.codex/hooks.json")
  FM_POLL=1 FM_CHECK_INTERVAL=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 4 > "$TMP_ROOT/finite.out" 2> "$TMP_ROOT/finite.err" &
  cp=$!
  sleep 1
  rc=0
  out=$(cd "$FM_HOME" && printf '%s' '{"stop_hook_active":true,"session_id":"delayed-report"}' |
    HOME="$FM_HOME" bash -c "$command" 2>&1) || rc=$?
  expect_code 2 "$rc" 'attempted final while finite checkpoint owns no callback must refuse'
  canonical completed checks-passed
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  rc=0; wait "$cp" || rc=$?
  expect_code 124 "$rc" 'real finite checkpoint should reach quiet expiry'
  assert_present "$FM_STATE_OVERRIDE/later.inbox/001.msg" 'checkpoint must reconcile delayed report without a new prompt or status event'
  out=$(stage resume-handoff) || fail "delayed replay: $out"
  assert_absent "$FM_STATE_OVERRIDE/later.inbox/002.msg" 'delayed-report replay dispatched twice'
  pass 'configured Stop, real finite checkpoint and delayed canonical report produce one attributable inbox effect (private shell driver only)'
}

test_unknown_conflicting_and_stale_authority_refuses() {
  local out rc field saved identity
  saved=$(meta completion_handoff)
  identity=$(printf '%s' "$saved" | jq -r .identity)
  cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/good.meta"
  for field in generation attempt run candidate; do
    jq --arg field "$field" '.[$field]="stale"' "$TMP_ROOT/delayed.json" > "$TMP_ROOT/stale.json"
    rc=0; out=$(stage handoff --handoff-json "$TMP_ROOT/stale.json") || rc=$?
    expect_code 1 "$rc" "stale/malformed $field admission"
    [ "$saved" = "$(meta completion_handoff)" ] || fail 'stale admission replaced existing contract'
  done
  jq '.action.id="different"' "$TMP_ROOT/delayed.json" > "$TMP_ROOT/conflicting.json"
  rc=0; out=$(stage handoff --handoff-json "$TMP_ROOT/conflicting.json") || rc=$?
  expect_code 1 "$rc" 'conflicting action admission'
  assert_contains "$out" CONFLICTING_HANDOFF 'conflicting identity must refuse'

  sed 's/^spawn_gen=.*/spawn_gen=stale/' "$TMP_ROOT/good.meta" > "$FM_STATE_OVERRIDE/source.meta"
  rc=0; out=$(stage handoff-release --identity "$identity") || rc=$?
  expect_code 1 "$rc" 'release on stale source generation'
  [ "$saved" = "$(meta completion_handoff)" ] || fail 'stale release mutated contract'
  cp "$TMP_ROOT/good.meta" "$FM_STATE_OVERRIDE/source.meta"

  cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/source-authority.real"
  rm "$FM_STATE_OVERRIDE/source.meta"
  ln -s "$TMP_ROOT/source-authority.real" "$FM_STATE_OVERRIDE/source.meta"
  rc=0; out=$("$ROOT/bin/fm-continuation-resolve.sh" reconcile) || rc=$?
  expect_code 1 "$rc" 'indirected source authority must remain visible as CNO'
  assert_contains "$out" TASK_AUTHORITY_UNREADABLE 'resolver silently skipped unreadable authority'
  rm "$FM_STATE_OVERRIDE/source.meta"
  mv "$TMP_ROOT/source-authority.real" "$FM_STATE_OVERRIDE/source.meta"

  canonical completed unknown-outcome
  rc=0; out=$(stage resume-handoff) || rc=$?
  expect_code 1 "$rc" 'unknown outcome refuses cached success'
  assert_contains "$out" CANONICAL_OUTCOME_UNKNOWN 'unknown outcome must remain CNO'
  canonical completed checks-passed
  mv "$FM_DATA_OVERRIDE/source/report.md" "$TMP_ROOT/report.real"
  ln -s "$TMP_ROOT/report.real" "$FM_DATA_OVERRIDE/source/report.md"
  rc=0; out=$(stage resume-handoff) || rc=$?
  expect_code 1 "$rc" 'symlink report refusal'
  assert_contains "$out" REPORT_UNREADABLE 'unreadable report predicate'
  rm "$FM_DATA_OVERRIDE/source/report.md"
  mv "$TMP_ROOT/report.real" "$FM_DATA_OVERRIDE/source/report.md"

  printf 'conflicting edited instruction\n' >> "$FM_STATE_OVERRIDE/later.inbox/001.msg"
  rc=0; out=$(stage resume-handoff) || rc=$?
  expect_code 1 "$rc" 'changed authoritative effect bytes refuse'
  assert_contains "$out" EFFECT_CONFLICT 'changed effect must not cause another dispatch'
  assert_absent "$FM_STATE_OVERRIDE/later.inbox/002.msg" 'conflicting effect replayed'
  [ "$saved" = "$(meta completion_handoff)" ] || fail 'refusals erased receipt evidence'
  pass 'malformed identity, stale generation, unknown outcome, report indirection and conflicting effect all refuse without mutation/replay'
}

test_session_start_reconciles_durable_handoff() {
  local out identity rc=0
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  canonical running
  fm_write_meta "$FM_STATE_OVERRIDE/startup.meta" 'kind=ship' 'spawn_gen=s5.1.1' 'harness=echo'
  jq '.action={id:"startup",kind:"task-inbox",owner:"startup",generation:"s5.1.1",instruction:"Continue this restart-surviving report action."}' \
    "$TMP_ROOT/handoff.json" > "$TMP_ROOT/startup.json"
  stage handoff --handoff-json "$TMP_ROOT/startup.json" >/dev/null || fail 'startup handoff registration'
  identity=$(meta completion_handoff | jq -r .identity)
  stage handoff-release --identity "$identity" >/dev/null || fail 'startup release while producer active'
  canonical completed checks-passed
  # Declared external boundaries: native session introspection and bootstrap's
  # vendor CLIs. The complete maintained session-start/lock/bootstrap/drain,
  # observer/stage/inbox chain runs unchanged, against this private home.
  export FM_COMPLETION_TEST_PRIMARY=$$
  cat > "$FAKEBIN/ps" <<'PS'
#!/usr/bin/env bash
pid= previous=
for argument in "$@"; do
  [ "$previous" != -p ] || pid=$argument
  previous=$argument
done
if [ "$pid" = "$FM_COMPLETION_TEST_PRIMARY" ]; then
  case "$*" in
    *comm=*|*args=*) printf 'codex\n'; exit 0 ;;
  esac
fi
exec /bin/ps "$@"
PS
  chmod +x "$FAKEBIN/ps"
  fm_fake_exit0 "$FAKEBIN" tmux gh gh-axi treehouse tasks-axi
  out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" 'actual startup caller'
  assert_contains "$out" COMPLETION_DISPATCHED 'startup must dispatch the durable eligible handoff'
  assert_present "$FM_STATE_OVERRIDE/startup.inbox/001.msg" 'startup lost the report obligation'
  out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-session-start.sh" 2>&1) || fail "startup replay: $out"
  assert_absent "$FM_STATE_OVERRIDE/startup.inbox/002.msg" 'restart replay duplicated the action'
  rm "$FAKEBIN/ps"
  pass 'actual session-start reconciles a pre-restart durable handoff and deduplicates restart (external native-session/CLI boundaries doubled)'
}

test_concurrent_resume_dispatches_once() {
  local saved out rc pid successes=0 i
  local -a pids=()
  # Construct one released pending handoff using the just-admitted identity;
  # remove its actual effect only to construct a fresh concurrency fixture.
  saved=$(meta completion_handoff | jq -c '.status="pending" | .receipt=null')
  sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/concurrent.meta"
  printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/concurrent.meta"
  mv "$TMP_ROOT/concurrent.meta" "$FM_STATE_OVERRIDE/source.meta"
  rm "$FM_STATE_OVERRIDE/startup.inbox/001.msg"
  for i in 1 2 3 4; do
    stage resume-handoff > "$TMP_ROOT/concurrent.$i" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    rc=0; wait "$pid" || rc=$?
    case "$rc" in 0) successes=$((successes + 1)) ;; 1|6) ;; *) fail "unexpected concurrent resume exit $rc" ;; esac
  done
  [ "$successes" -gt 0 ] || fail 'all concurrent owners refused'
  out=$(stage resume-handoff) || fail "concurrent repair readback: $out"
  [ "$(find "$FM_STATE_OVERRIDE/startup.inbox" -name '*.msg' -type f | wc -l)" -eq 1 ] || fail 'concurrent resume duplicated the inbox effect'
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'concurrent winner omitted receipt'
  pass 'four concurrent actual resume callers serialize to one inbox effect and one recoverable receipt'
}

test_show_refreshes_stale_completed_run
test_resume_completed_report_without_wake
test_authoritative_effect_repairs_missing_receipt
test_positive_receipt_retirement_archive
test_canonical_read_failure_keeps_receipt
test_duplicate_and_changed_bytes
test_handled_inbox_keeps_open_action_and_deduplicates
test_stop_checkpoint_delayed_report_caller_chain
test_unknown_conflicting_and_stale_authority_refuses
test_session_start_reconciles_durable_handoff
test_concurrent_resume_dispatches_once
