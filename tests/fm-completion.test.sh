#!/usr/bin/env bash
# Real stage/resume/drain callers in private state. The no-mistakes CLI is the
# sole substituted authority boundary; it serves read-only canonical records.
# Each subshell deliberately restores the parent fixture's environment on exit.
# shellcheck disable=SC2030,SC2031
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
export FM_TEST_QUALIFICATION_FIXTURE="$ROOT/tests/fixtures/nm-qualification.py"
export FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/canonical"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  --version) echo 'no-mistakes version v1.61.0 (0af0be6) 2026-08-31T14:04:25Z' ;;
  'axi qualification'*) exec python3 "$FM_TEST_QUALIFICATION_FIXTURE" "${@:3}" ;;
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

test_retirement_revalidates_report_and_effect() (
  local mutation out rc saved contract identity before
  prepare_delivery
  printf 'window=isolated:fm-source\nendpoint_task_id=source\n' >> "$FM_STATE_OVERRIDE/source.meta"
  mkdir -p "$TMP_ROOT/retirement-bin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/retirement-bin/tmux"
  chmod +x "$TMP_ROOT/retirement-bin/tmux"
  export PATH="$TMP_ROOT/retirement-bin:$PATH"
  stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'retirement admission'
  identity=$(meta completion_handoff | jq -r .identity)
  stage handoff-release --identity "$identity" >/dev/null || fail 'retirement dispatch'
  cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/retirement.meta"
  for mutation in changed deleted symlink generation attempt run candidate source_head action.owner action.generation; do
    cp "$TMP_ROOT/retirement.meta" "$FM_STATE_OVERRIDE/source.meta"
    rm -f "$FM_DATA_OVERRIDE/source/report.md" "$FM_DATA_OVERRIDE/source/completion-receipt.json"
    printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
    case "$mutation" in
      changed) printf 'changed\n' >> "$FM_DATA_OVERRIDE/source/report.md" ;;
      deleted) rm "$FM_DATA_OVERRIDE/source/report.md" ;;
      symlink)
        mv "$FM_DATA_OVERRIDE/source/report.md" "$TMP_ROOT/report-target"
        ln -s "$TMP_ROOT/report-target" "$FM_DATA_OVERRIDE/source/report.md"
        ;;
      *)
        contract=$(meta completion_handoff | jq -cS --arg field "$mutation" '
          .contract | setpath($field | split(".");
            if $field == "candidate" or $field == "source_head" then "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else "foreign" end)')
        identity=$(printf '%s' "$contract" | shasum -a 256 | cut -d' ' -f1)
        saved=$(meta completion_handoff | jq -c --argjson contract "$contract" --arg identity "$identity" '.contract=$contract | .identity=$identity')
        sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/retirement.next"
        printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/retirement.next"
        mv "$TMP_ROOT/retirement.next" "$FM_STATE_OVERRIDE/source.meta"
        ;;
    esac
    before=$(cat "$FM_STATE_OVERRIDE/source.meta")
    rc=0; out=$("$ROOT/bin/fm-teardown.sh" source 2>&1) || rc=$?
    expect_code 1 "$rc" "$mutation report/effect must prevent retirement"
    assert_contains "$out" 'completion handoff remains unresolved' "$mutation must reach completion retirement refusal"
    [ "$before" = "$(cat "$FM_STATE_OVERRIDE/source.meta")" ] || fail 'retirement changed unresolved metadata'
    assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'retirement archived unresolved receipt'
  done
  cp "$TMP_ROOT/retirement.meta" "$FM_STATE_OVERRIDE/source.meta"
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  test_positive_receipt_retirement_archive
  pass 'actual teardown retains changed/deleted/unreadable reports and mismatched exact effects'
)

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

test_stage_advancement_preserves_effect() {
  local transition out before saved
  for transition in landing activated; do
    out=$(stage "$transition") || fail "$transition with completed handoff: $out"
    before=$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")
    saved=$(meta completion_handoff | jq -c '.receipt=null | .status="pending"')
    sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/advanced.meta"
    printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/advanced.meta"
    mv "$TMP_ROOT/advanced.meta" "$FM_STATE_OVERRIDE/source.meta"
    out=$(stage resume-handoff) || fail "$transition receipt recovery: $out"
    [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'advanced receipt not repaired'
    [ "$before" = "$(shasum -a 256 "$FM_STATE_OVERRIDE/source.status")" ] || fail 'advanced stage replayed effect'
  done
  pass 'landing and activated preserve and reconstruct the same CI-ready effect'
}

prepare_delivery() {
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  : > "$FM_STATE_OVERRIDE/source.status"
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  canonical completed checks-passed
  fm_write_meta "$FM_STATE_OVERRIDE/guarded.meta" 'kind=ship' 'spawn_gen=g1' 'harness=echo'
  jq '.action={id:"guarded",kind:"task-inbox",owner:"guarded",generation:"g1",instruction:"Continue this exact report."}' \
    "$TMP_ROOT/handoff.json" > "$TMP_ROOT/guarded.json"
}

assert_no_delivery() {
  [ "$(meta completion_handoff | jq -r '.receipt // "absent"')" = absent ] || fail 'refusal recorded successful delivery'
  assert_absent "$FM_STATE_OVERRIDE/guarded.inbox/001.msg" 'refusal enqueued an instruction'
}

test_remote_and_destination_lease() {
  local out rc identity
  prepare_delivery
  printf 'remote_host=remote.example\n' >> "$FM_STATE_OVERRIDE/guarded.meta"
  rc=0; out=$(stage handoff --handoff-json "$TMP_ROOT/guarded.json") || rc=$?
  expect_code 1 "$rc" 'remote admission'
  assert_contains "$out" UNSUPPORTED_REMOTE_TARGET 'precise remote admission disposition'
  [ -z "$(meta completion_handoff)" ] || fail 'remote destination admitted'
  prepare_delivery
  stage handoff --handoff-json "$TMP_ROOT/guarded.json" >/dev/null || fail 'local admission'
  identity=$(meta completion_handoff | jq -r .identity)
  printf 'remote_host=remote.example\n' >> "$FM_STATE_OVERRIDE/guarded.meta"
  rc=0; out=$(stage handoff-release --identity "$identity") || rc=$?
  expect_code 1 "$rc" 'remote delivery'
  assert_contains "$out" UNSUPPORTED_REMOTE_TARGET 'precise remote delivery disposition'
  assert_no_delivery
  fm_write_meta "$FM_STATE_OVERRIDE/guarded.meta" 'kind=ship' 'spawn_gen=g1' 'harness=echo'
  printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$FM_STATE_OVERRIDE/.lease-guarded"
  rc=0; out=$(FM_SUPERVISION_ACTOR=main stage resume-handoff 2>&1) || rc=$?
  expect_code 6 "$rc" 'other-actor destination lease'
  assert_contains "$out" 'leased to the branch' 'destination lease refusal'
  assert_no_delivery
  out=$(FM_SUPERVISION_ACTOR=branch stage resume-handoff 2>&1) || fail "same-actor destination delivery: $out"
  assert_present "$FM_STATE_OVERRIDE/guarded.inbox/001.msg" 'same-actor delivery absent'
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'same-actor receipt absent'
  rm "$FM_STATE_OVERRIDE/.lease-guarded" "$FM_STATE_OVERRIDE/.lock"
  rm -r "$FM_STATE_OVERRIDE/guarded.inbox"
  pass 'remote admission and delivery refuse; destination lease rejects other actor and permits its owner'
}

test_destination_changes_while_delivery_waits() {
  local mutation out rc identity worker holder i
  for mutation in report-changed report-deleted sequence-changed sequence-deleted replacement retirement remote source-replacement unchanged; do
    prepare_delivery
    stage handoff --handoff-json "$TMP_ROOT/guarded.json" >/dev/null || fail 'race admission'
    identity=$(meta completion_handoff | jq -r .identity)
    canonical running
    stage handoff-release --identity "$identity" >/dev/null || fail 'race release'
    canonical completed checks-passed
    export FM_TEST_DEST_LOCK="$FM_STATE_OVERRIDE/.meta-guarded.lock"
    case "$mutation" in
      sequence-*)
        mkdir -p "$FM_STATE_OVERRIDE/guarded.inbox/handled"
        export FM_TEST_DEST_LOCK="$FM_STATE_OVERRIDE/guarded.inbox/.seq.lock"
        ;;
    esac
    export FM_TEST_DEST_WAIT="$TMP_ROOT/destination-wait"
    export FM_TEST_DEST_UNLOCK="$TMP_ROOT/destination-unlock"
    rm -f "$FM_TEST_DEST_WAIT" "$FM_TEST_DEST_UNLOCK" "$TMP_ROOT/holder-ready"
    bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_acquire_wait "$FM_TEST_DEST_LOCK"
      : > "$2/holder-ready"
      while [ ! -f "$FM_TEST_DEST_UNLOCK" ]; do sleep 0.02; done
      fm_lock_release "$FM_TEST_DEST_LOCK"
    ' _ "$ROOT" "$TMP_ROOT" &
    holder=$!
    for ((i=0; i<500; i++)); do
      [ ! -f "$TMP_ROOT/holder-ready" ] || break
      sleep 0.02
    done
    [ -f "$TMP_ROOT/holder-ready" ] || fail 'metadata lock holder did not start'
    cat > "$FAKEBIN/cat" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "$FM_TEST_DEST_LOCK/pid" ]; then
  : > "$FM_TEST_DEST_WAIT"
fi
exec /bin/cat "$@"
SH
    chmod +x "$FAKEBIN/cat"
    stage resume-handoff > "$TMP_ROOT/race.out" 2>&1 &
    worker=$!
    for ((i=0; i<500; i++)); do
      [ ! -f "$FM_TEST_DEST_WAIT" ] || break
      kill -0 "$worker" 2>/dev/null || break
      sleep 0.02
    done
    [ -f "$FM_TEST_DEST_WAIT" ] || fail 'delivery failed to consult the held destination lock (filesystem read boundary observer)'
    case "$mutation" in
      report-changed|sequence-changed) printf 'changed\n' >> "$FM_DATA_OVERRIDE/source/report.md" ;;
      report-deleted|sequence-deleted) rm "$FM_DATA_OVERRIDE/source/report.md" ;;
      replacement) fm_write_meta "$FM_STATE_OVERRIDE/guarded.meta" 'kind=ship' 'spawn_gen=g2' 'harness=echo' ;;
      retirement) rm "$FM_STATE_OVERRIDE/guarded.meta" ;;
      remote) printf 'remote_host=remote.example\n' >> "$FM_STATE_OVERRIDE/guarded.meta" ;;
      source-replacement)
        bash -c '
          . "$1/bin/fm-wake-lib.sh"
          lock=$(fm_meta_lock_path "$STATE/source.meta")
          fm_lock_acquire_wait "$lock"
          sed "s/^spawn_gen=.*/spawn_gen=relaunched/" "$STATE/source.meta" > "$STATE/source.next"
          mv "$STATE/source.next" "$STATE/source.meta"
          fm_lock_release "$lock"
        ' _ "$ROOT" || fail 'source relaunch mutation'
        ;;
    esac
    : > "$FM_TEST_DEST_UNLOCK"
    wait "$holder" || fail 'metadata holder failed'
    rc=0; wait "$worker" || rc=$?
    rm "$FAKEBIN/cat"
    out=$(cat "$TMP_ROOT/race.out")
    if [ "$mutation" = unchanged ]; then
      expect_code 0 "$rc" 'unchanged source after contention'
      assert_present "$FM_STATE_OVERRIDE/guarded.inbox/001.msg" 'unchanged source did not dispatch'
      [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'unchanged source receipt absent'
      rm -r "$FM_STATE_OVERRIDE/guarded.inbox"
      continue
    fi
    expect_code 1 "$rc" "$mutation during delivery"
    case "$mutation" in
      report-changed) assert_contains "$out" REPORT_CHANGED 'report changed during custody wait' ;;
      sequence-changed|sequence-deleted) assert_contains "$out" DELIVERY_UNCONFIRMED 'report changed during inbox sequence wait' ;;
      report-deleted) assert_contains "$out" REPORT_UNREADABLE 'report deleted during custody wait' ;;
      replacement) assert_contains "$out" TARGET_GENERATION 'replacement refusal' ;;
      retirement) assert_contains "$out" TARGET_UNREADABLE 'retirement refusal' ;;
      remote) assert_contains "$out" UNSUPPORTED_REMOTE_TARGET 'remote race refusal' ;;
      source-replacement) assert_contains "$out" SOURCE_CHANGED 'source relaunch refusal' ;;
    esac
    assert_no_delivery
  done
  pass 'source relaunch and destination changes refuse stale delivery; unchanged custody permits delivery'
}

test_self_target_delivery() {
  local identity out
  prepare_delivery
  jq '.action.owner="source" | .action.generation="s1.1.1"' "$TMP_ROOT/guarded.json" > "$TMP_ROOT/self.json"
  stage handoff --handoff-json "$TMP_ROOT/self.json" >/dev/null || fail 'self admission'
  identity=$(meta completion_handoff | jq -r .identity)
  out=$(stage handoff-release --identity "$identity") || fail "self delivery: $out"
  assert_present "$FM_STATE_OVERRIDE/source.inbox/001.msg" 'self inbox missing'
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'self receipt missing'
  stage resume-handoff >/dev/null || fail 'self replay'
  assert_absent "$FM_STATE_OVERRIDE/source.inbox/002.msg" 'self delivery duplicated'
  pass 'self-target delivery and receipt persist without recursive metadata locking'
}

test_unqualified_and_foreign_stage_effects_refuse() {
  local out rc saved field effect
  prepare_delivery
  stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'unqualified stage admission'
  rc=0; out=$(stage landing) || rc=$?
  expect_code 1 "$rc" 'direct landing must leave CI-ready effect unresolved'
  [ "$(meta stage)" = validation-running ] || fail 'direct landing mutated unqualified stage'
  assert_contains "$out" QUALIFICATION_REVOKED 'direct landing must refuse before any lifecycle effect'
  [ "$(meta completion_handoff | jq -r '.receipt // "absent"')" = absent ] || fail 'direct landing synthesized a receipt'
  prepare_delivery
  stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'qualified stage admission'
  stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" >/dev/null || fail 'actual qualification'
  stage landing >/dev/null || fail 'qualified landing'
  saved=$(meta completion_handoff | jq -c '.receipt=null | .status="pending"')
  effect=$(meta stage_ci_ready_effect)
  cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/qualified.meta"
  for field in task generation attempt run candidate source_head pr missing; do
    sed -e '/^completion_handoff=/d' -e '/^stage_ci_ready_effect=/d' "$TMP_ROOT/qualified.meta" > "$FM_STATE_OVERRIDE/source.meta"
    printf 'completion_handoff=%s\n' "$saved" >> "$FM_STATE_OVERRIDE/source.meta"
    if [ "$field" != missing ]; then
      printf 'stage_ci_ready_effect=%s\n' "$(printf '%s' "$effect" | jq -c --arg field "$field" '.[$field]="foreign"')" >> "$FM_STATE_OVERRIDE/source.meta"
    fi
    rc=0; out=$(stage resume-handoff) || rc=$?
    expect_code 1 "$rc" "unproven historical effect: $field"
    assert_contains "$out" CI_READY_EFFECT_UNPROVEN "effect identity mismatch: $field"
    [ "$(meta completion_handoff | jq -r '.receipt // "absent"')" = absent ] || fail 'foreign effect repaired receipt'
  done
  cp "$TMP_ROOT/qualified.meta" "$FM_STATE_OVERRIDE/source.meta"
  pass 'direct landing and missing or foreign qualification evidence never reconstruct CI-ready success'
}

test_checkpoint_observation_lock_bounds() (
  local boundary holder checkpoint rc i identity
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  for boundary in entry exit; do
    export FM_STATE_OVERRIDE="$TMP_ROOT/checkpoint-$boundary-state"
    mkdir -p "$FM_STATE_OVERRIDE"
    prepare_delivery
    canonical running
    stage handoff --handoff-json "$TMP_ROOT/guarded.json" >/dev/null || fail 'checkpoint admission'
    identity=$(meta completion_handoff | jq -r .identity)
    stage handoff-release --identity "$identity" >/dev/null || fail 'checkpoint pending release'
    rm -f "$TMP_ROOT/observation-held" "$TMP_ROOT/observation-release"
    bash -c '
      . "$1/bin/fm-wake-lib.sh"
      if [ "$3" = exit ]; then
        while [ ! -f "$STATE/.watch.lock/watcher-path" ]; do sleep 0.02; done
      fi
      lock="$STATE/.nm-observe-source.lock"
      fm_lock_acquire_wait "$lock"
      : > "$2/observation-held"
      while [ ! -f "$2/observation-release" ]; do sleep 0.02; done
      fm_lock_release "$lock"
    ' _ "$ROOT" "$TMP_ROOT" "$boundary" &
    holder=$!
    if [ "$boundary" = entry ]; then
      for ((i=0; i<500; i++)); do
        [ ! -f "$TMP_ROOT/observation-held" ] || break
        sleep 0.02
      done
      [ -f "$TMP_ROOT/observation-held" ] || fail 'observation holder absent'
    fi
    FM_POLL=1 FM_CHECK_INTERVAL=999999 fm_run_timed 60 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 \
      > "$TMP_ROOT/checkpoint-$boundary.out" 2> "$TMP_ROOT/checkpoint-$boundary.err" &
    checkpoint=$!
    rc=0; wait "$checkpoint" || rc=$?
    : > "$TMP_ROOT/observation-release"
    if [ ! -f "$TMP_ROOT/observation-held" ]; then kill "$holder" 2>/dev/null || true; fi
    wait "$holder" || fail 'observation holder failed'
    expect_code 124 "$rc" "$boundary checkpoint bound"
    assert_contains "$(cat "$TMP_ROOT/checkpoint-$boundary.err")" "boundary=$boundary status=124" 'held observation must time out with explicit unresolved disposition'
    assert_contains "$(cat "$TMP_ROOT/checkpoint-$boundary.out")" 'checkpoint: no actionable wake within 5s' 'outer watchdog, rather than finite checkpoint, expired'
    [ "$(meta completion_handoff | jq -r .status)" = pending ] || fail 'timed-out reconciliation closed unresolved action'
    assert_absent "$FM_STATE_OVERRIDE/guarded.inbox/001.msg" 'timed-out reconciliation dispatched action'
  done
  pass 'finite checkpoint bounds entry and exit reconciliation against a live observation lock'
)

# R27: a host whose shasum produces no digest must not collapse every handoff
# identity to the empty string, which would let changed contract bytes pass the
# CONFLICTING_HANDOFF check as ""=="".
test_handoff_identity_survives_a_broken_digest_tool() (
  local out rc=0 identity
  export FM_STATE_OVERRIDE="$TMP_ROOT/digest-state"
  mkdir -p "$FM_STATE_OVERRIDE" "$TMP_ROOT/digest-bin"
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  canonical running
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/digest-bin/shasum"
  chmod +x "$TMP_ROOT/digest-bin/shasum"
  export PATH="$TMP_ROOT/digest-bin:$PATH"

  out=$(stage handoff --handoff-json "$TMP_ROOT/handoff.json") || fail "broken shasum admission: $out"
  identity=$(meta completion_handoff | jq -r .identity)
  [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || fail "admitted identity is not a digest: '$identity'"
  jq '.action.id="ci2"' "$TMP_ROOT/handoff.json" > "$TMP_ROOT/digest-other.json"
  rc=0; out=$(stage handoff --handoff-json "$TMP_ROOT/digest-other.json") || rc=$?
  expect_code 1 "$rc" 'changed contract bytes must refuse'
  assert_contains "$out" CONFLICTING_HANDOFF 'changed contract bytes must not pass as an equal identity'
  [ "$(meta completion_handoff | jq -r .identity)" = "$identity" ] || fail 'refused handoff replaced the admitted contract'
  [ "$(meta completion_handoff | jq -r .contract.action.id)" = ci ] || fail 'refused handoff became authoritative'

  export FM_STATE_OVERRIDE="$TMP_ROOT/digest-none-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/digest-bin/sha256sum"
  chmod +x "$TMP_ROOT/digest-bin/sha256sum"
  rc=0; out=$(stage handoff --handoff-json "$TMP_ROOT/handoff.json") || rc=$?
  expect_code 1 "$rc" 'no usable digest tool must refuse'
  assert_contains "$out" DIGEST_UNAVAILABLE 'unavailable digest must be a typed refusal'
  [ -z "$(meta completion_handoff)" ] || fail 'unavailable digest stored an identity-less handoff'
  pass 'handoff identity falls back to a real digest and refuses when no tool produces one'
)

# R29: landing carries the destination CI-ready qualified. A different --pr is a
# destination mismatch, not a revoked qualification.
test_landing_destination_mismatch_refuses_early() (
  local out rc=0 before
  export FM_STATE_OVERRIDE="$TMP_ROOT/destination-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
  canonical completed checks-passed
  stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'destination fixture admission'
  stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" >/dev/null || fail 'destination fixture release'
  [ "$(meta stage)" = ci-ready ] || fail 'destination fixture did not reach ci-ready'
  before=$(shasum -a 256 "$FM_STATE_OVERRIDE/source.meta" "$FM_STATE_OVERRIDE/source.status")

  rc=0; out=$(stage landing --pr https://github.com/o/r/pull/9 2>&1) || rc=$?
  expect_code 1 "$rc" 'a different landing destination must refuse'
  assert_contains "$out" DESTINATION_MISMATCH 'refusal must name the destination mismatch'
  case "$out" in *QUALIFICATION_REVOKED*) fail 'destination mismatch mislabelled as a revocation' ;; esac
  [ "$before" = "$(shasum -a 256 "$FM_STATE_OVERRIDE/source.meta" "$FM_STATE_OVERRIDE/source.status")" ] \
    || fail 'refused landing mutated the record'

  out=$(stage landing --pr https://github.com/o/r/pull/7) || fail "qualified destination must land: $out"
  [ "$(meta stage)" = landing ] || fail 'qualified destination did not record landing'
  pass 'landing refuses an unqualified destination as a mismatch and accepts the qualified one'
)

test_opposite_direction_delivery_does_not_deadlock() {
  local other_wt out rc pid first second
  prepare_delivery
  rm -rf "$FM_STATE_OVERRIDE/source.inbox"
  other_wt="$TMP_ROOT/other-worktree"
  git clone -q "$WT" "$other_wt" || fail 'opposite fixture clone'
  git -C "$other_wt" checkout -qb fm/other || fail 'opposite fixture branch'
  mkdir -p "$FM_DATA_OVERRIDE/other"
  cp "$FM_DATA_OVERRIDE/source/brief.md" "$FM_DATA_OVERRIDE/other/brief.md"
  cp "$FM_DATA_OVERRIDE/source/report.md" "$FM_DATA_OVERRIDE/other/report.md"
  fm_write_meta "$FM_STATE_OVERRIDE/other.meta" "worktree=$other_wt" "project=$other_wt" \
    'harness=echo' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=other1'
  canonical running
  sed -e 's/01SOURCE/01OTHER/g' -e 's,fm/source,fm/other,g' "$FM_COMPLETION_TEST_CANONICAL" > "$TMP_ROOT/other-canonical"
  FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" "$ROOT/bin/fm-stage.sh" other committed >/dev/null || fail 'opposite admission'
  FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" "$ROOT/bin/fm-stage.sh" other running --run 01OTHER >/dev/null || fail 'opposite run binding'
  jq '.action.owner="other" | .action.generation="other1"' "$TMP_ROOT/guarded.json" > "$TMP_ROOT/to-other.json"
  jq --arg attempt "$(sed -n 's/^stage_attempt=//p' "$FM_STATE_OVERRIDE/other.meta")" \
    --arg report "$FM_DATA_OVERRIDE/other/report.md" \
    '.task="other" | .generation="other1" | .attempt=$attempt | .run="01OTHER" | .report.path=$report |
     .action.owner="source" | .action.generation="s1.1.1"' "$TMP_ROOT/guarded.json" > "$TMP_ROOT/to-source.json"
  stage handoff --handoff-json "$TMP_ROOT/to-other.json" >/dev/null || fail 'source opposite handoff'
  FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" "$ROOT/bin/fm-stage.sh" other handoff --handoff-json "$TMP_ROOT/to-source.json" >/dev/null || fail 'other opposite handoff'
  stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" >/dev/null || fail 'source opposite release'
  FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" "$ROOT/bin/fm-stage.sh" other handoff-release \
    --identity "$(sed -n 's/^completion_handoff=//p' "$FM_STATE_OVERRIDE/other.meta" | jq -r .identity)" >/dev/null || fail 'other opposite release'
  canonical completed checks-passed
  sed -e 's/01SOURCE/01OTHER/g' -e 's,fm/source,fm/other,g' "$FM_COMPLETION_TEST_CANONICAL" > "$TMP_ROOT/other-canonical"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  fm_run_timed 20 "$ROOT/bin/fm-stage.sh" source resume-handoff > "$TMP_ROOT/opposite-source.out" 2>&1 &
  first=$!
  FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" fm_run_timed 20 "$ROOT/bin/fm-stage.sh" other resume-handoff > "$TMP_ROOT/opposite-other.out" 2>&1 &
  second=$!
  for pid in "$first" "$second"; do
    rc=0; wait "$pid" || rc=$?
    case "$rc" in 0|1) ;; *) fail "opposite delivery hung or failed unexpectedly: $rc" ;; esac
  done
  out=$(stage resume-handoff) || fail "opposite source retry: $out"
  out=$(FM_COMPLETION_TEST_CANONICAL="$TMP_ROOT/other-canonical" "$ROOT/bin/fm-stage.sh" other resume-handoff) || fail "opposite other retry: $out"
  assert_present "$FM_STATE_OVERRIDE/source.inbox/001.msg" 'opposite source delivery missing'
  assert_present "$FM_STATE_OVERRIDE/other.inbox/001.msg" 'opposite other delivery missing'
  assert_absent "$FM_STATE_OVERRIDE/source.inbox/002.msg" 'opposite source duplicate'
  assert_absent "$FM_STATE_OVERRIDE/other.inbox/002.msg" 'opposite other duplicate'
  pass 'opposite-direction deliveries terminate without deadlock and converge to one effect each'
}

test_ci_ready_child_revalidates_admitted_identity() {
  local mutation identity out rc
  export FM_TEST_STAGE_ROOT="$ROOT"
  export FM_TEST_STAGE_SNAPSHOT="$TMP_ROOT/stage-effect-boundary"
  mkdir -p "$FM_TEST_STAGE_SNAPSHOT"
  for mutation in report-changed report-deleted spawn_gen stage_run stage_attempt stage_head unchanged; do
    prepare_delivery
    canonical running
    stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'stage race admission'
    identity=$(meta completion_handoff | jq -r .identity)
    stage handoff-release --identity "$identity" >/dev/null || fail 'stage race pending release'
    canonical completed checks-passed
    export FM_TEST_STAGE_MUTATION="$mutation"
    cat > "$FAKEBIN/bash" <<'SH'
#!/bin/bash
if [ "${1##*/}" = fm-stage.sh ] && [ "${2:-}" = source ] && [ "${3:-}" = ci-ready ]; then
  /bin/bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$STATE/source.meta")
    fm_lock_acquire_wait "$lock"
    if [ "$FM_TEST_STAGE_MUTATION" = report-changed ]; then
      printf "changed\n" >> "$FM_DATA_OVERRIDE/source/report.md"
    elif [ "$FM_TEST_STAGE_MUTATION" = report-deleted ]; then
      rm "$FM_DATA_OVERRIDE/source/report.md"
    elif [ "$FM_TEST_STAGE_MUTATION" != unchanged ]; then
      sed "s/^$FM_TEST_STAGE_MUTATION=.*/$FM_TEST_STAGE_MUTATION=changed/" "$STATE/source.meta" > "$STATE/source.next"
      mv "$STATE/source.next" "$STATE/source.meta"
    fi
    cp "$STATE/source.meta" "$FM_TEST_STAGE_SNAPSHOT/meta"
    cp "$STATE/source.nm-observe" "$FM_TEST_STAGE_SNAPSHOT/observe"
    cp "$STATE/source.status" "$FM_TEST_STAGE_SNAPSHOT/status"
    fm_lock_release "$lock"
  ' _ "$FM_TEST_STAGE_ROOT" || exit 1
fi
exec /bin/bash "$@"
SH
    chmod +x "$FAKEBIN/bash"
    rc=0; out=$(stage resume-handoff 2>&1) || rc=$?
    rm "$FAKEBIN/bash"
    if [ "$mutation" = unchanged ]; then
      expect_code 0 "$rc" 'unchanged CI-ready identity'
      [ "$(meta stage)" = ci-ready ] || fail 'valid child did not qualify'
      [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'valid child receipt missing'
    else
      expect_code 1 "$rc" "stale CI-ready $mutation"
      case "$mutation" in
        report-changed) assert_contains "$out" REPORT_CHANGED 'child must refuse changed report' ;;
        report-deleted) assert_contains "$out" REPORT_UNREADABLE 'child must refuse deleted report' ;;
        *) assert_contains "$out" STALE_BINDING 'child must refuse the admitted identity before qualification' ;;
      esac
      cmp -s "$FM_TEST_STAGE_SNAPSHOT/meta" "$FM_STATE_OVERRIDE/source.meta" || fail 'stale child mutated lifecycle or handoff receipt'
      cmp -s "$FM_TEST_STAGE_SNAPSHOT/observe" "$FM_STATE_OVERRIDE/source.nm-observe" || fail 'stale child mutated observer'
      cmp -s "$FM_TEST_STAGE_SNAPSHOT/status" "$FM_STATE_OVERRIDE/source.status" || fail 'stale child emitted stage receipt'
    fi
  done
  prepare_delivery
  stage ci-ready --pr https://github.com/o/r/pull/7 >/dev/null || fail 'normal direct CI-ready caller'
  [ "$(meta stage)" = ci-ready ] || fail 'direct qualification disappeared'
  pass 'actual CI-ready child rejects changed generation/run/attempt/candidate before effects; unchanged and direct callers qualify'
}

test_away_housekeeping_bounds_observation_wait() (
  local holder rc i
  export FM_STATE_OVERRIDE="$TMP_ROOT/away-custody-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  prepare_delivery
  canonical running
  stage handoff --handoff-json "$TMP_ROOT/guarded.json" >/dev/null || fail 'away handoff admission'
  : > "$FM_STATE_OVERRIDE/.afk"
  printf 'needs-decision [key=after-timeout]: retain this decision\n' > "$FM_STATE_OVERRIDE/notice.status"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$STATE/.nm-observe-source.lock"
    fm_lock_acquire_wait "$lock"
    : > "$2/away-holder-ready"
    while [ ! -f "$2/away-holder-release" ]; do sleep 0.02; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$TMP_ROOT" &
  holder=$!
  for ((i=0; i<500; i++)); do
    [ ! -f "$TMP_ROOT/away-holder-ready" ] || break
    sleep 0.02
  done
  [ -f "$TMP_ROOT/away-holder-ready" ] || fail 'away observation holder missing'
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  rc=0
  # shellcheck disable=SC2016 # Expansion belongs to the isolated child shell.
  FM_HEARTBEAT_SCAN_SECS=0 FM_ESCALATE_BATCH_SECS=999999 FM_MAX_DEFER_SECS=0 fm_run_timed 20 bash -c '
    . "$1/bin/fm-supervise-daemon.sh"
    housekeeping "$FM_STATE_OVERRIDE"
    : > "$2/away-housekeeping-returned"
  ' _ "$ROOT" "$TMP_ROOT" > "$TMP_ROOT/away-housekeeping.out" 2>&1 || rc=$?
  : > "$TMP_ROOT/away-holder-release"
  wait "$holder" || fail 'away observation holder failed'
  expect_code 0 "$rc" 'away housekeeping must return before outer watchdog'
  assert_present "$TMP_ROOT/away-housekeeping-returned" 'housekeeping did not regain control'
  assert_contains "$(cat "$FM_STATE_OVERRIDE/.subsuper-escalations")" 'away reconciliation unresolved status=124' 'timeout did not retain unresolved evidence'
  assert_contains "$(cat "$FM_STATE_OVERRIDE/.subsuper-escalations")" 'after-timeout' 'held observer prevented subsequent escalation housekeeping'
  [ "$(meta completion_handoff | jq -r .status)" = pending ] || fail 'away timeout completed pending work'
  pass 'away housekeeping times out a live observation lock and continues its durable escalation scan'
)

test_qualified_successor_identity() {
  local successor unrelated identity saved out rc mutation
  successor=$(git -C "$WT" commit-tree "${HEAD}^{tree}" -p "$HEAD" -m 'qualified pipeline fix') || fail 'successor fixture'
  unrelated=$(git -C "$WT" commit-tree "${HEAD}^{tree}" -m 'unrelated history') || fail 'unrelated fixture'
  prepare_delivery
  jq --arg head "$successor" '.source_head=$head' "$TMP_ROOT/handoff.json" > "$TMP_ROOT/successor.json"
  stage handoff --handoff-json "$TMP_ROOT/successor.json" >/dev/null || fail 'successor handoff admission'
  identity=$(meta completion_handoff | jq -r .identity)
  canonical completed checks-passed
  sed "s/$HEAD/$successor/g" "$FM_COMPLETION_TEST_CANONICAL" > "$TMP_ROOT/final-canonical"
  cp "$TMP_ROOT/final-canonical" "$FM_COMPLETION_TEST_CANONICAL"
  out=$(stage handoff-release --identity "$identity") || fail "qualified successor handoff: $out"
  [ "$(meta stage_head)" = "$HEAD" ] || fail 'submitted candidate changed'
  [ "$(meta stage_ci_ready_effect | jq -r .source_head)" = "$successor" ] || fail 'qualification recorded caller head instead of run head'
  saved=$(meta completion_handoff | jq -c '.receipt=null | .status="pending"')
  sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/successor-meta"
  printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/successor-meta"
  mv "$TMP_ROOT/successor-meta" "$FM_STATE_OVERRIDE/source.meta"
  out=$(stage resume-handoff) || fail "successor receipt reconstruction: $out"
  [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'successor receipt not reconstructed'
  prepare_delivery
  cp "$TMP_ROOT/final-canonical" "$FM_COMPLETION_TEST_CANONICAL"
  stage ci-ready --pr https://github.com/o/r/pull/7 >/dev/null || fail 'direct successor qualification'
  [ "$(meta stage_ci_ready_effect | jq -r .source_head)" = "$successor" ] || fail 'direct caller recorded submitted head'
  for mutation in unrelated foreign-run missing-run unreadable unqualified stale-head; do
    prepare_delivery
    stage handoff --handoff-json "$TMP_ROOT/successor.json" >/dev/null || fail 'negative successor admission'
    sed -e 's/status: completed/status: running/' -e '/^outcome:/d' "$TMP_ROOT/final-canonical" > "$FM_COMPLETION_TEST_CANONICAL"
    stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" >/dev/null || fail 'negative successor release'
    cp "$TMP_ROOT/final-canonical" "$FM_COMPLETION_TEST_CANONICAL"
    case "$mutation" in
      unrelated) sed "s/$successor/$unrelated/g" "$TMP_ROOT/final-canonical" > "$FM_COMPLETION_TEST_CANONICAL" ;;
      foreign-run) sed 's/01SOURCE/01FOREIGN/g' "$TMP_ROOT/final-canonical" > "$FM_COMPLETION_TEST_CANONICAL" ;;
      missing-run) sed '/  id:/d' "$TMP_ROOT/final-canonical" > "$FM_COMPLETION_TEST_CANONICAL" ;;
      unreadable) rm "$FM_COMPLETION_TEST_CANONICAL" ;;
      unqualified) sed -e 's/status: completed/status: reviewing/' -e '/^outcome:/d' "$TMP_ROOT/final-canonical" > "$FM_COMPLETION_TEST_CANONICAL" ;;
      stale-head) canonical completed checks-passed ;;
    esac
    cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/successor-before.meta"
    cp "$FM_STATE_OVERRIDE/source.nm-observe" "$TMP_ROOT/successor-before.observe"
    cp "$FM_STATE_OVERRIDE/source.status" "$TMP_ROOT/successor-before.status"
    rc=0; out=$(stage ci-ready --identity "$(meta completion_handoff | jq -r .identity)" --pr https://github.com/o/r/pull/7 2>&1) || rc=$?
    expect_code 1 "$rc" "invalid successor $mutation"
    cmp -s "$TMP_ROOT/successor-before.meta" "$FM_STATE_OVERRIDE/source.meta" || fail 'invalid successor mutated stage/receipt'
    cmp -s "$TMP_ROOT/successor-before.observe" "$FM_STATE_OVERRIDE/source.nm-observe" || fail 'invalid successor mutated observer'
    cmp -s "$TMP_ROOT/successor-before.status" "$FM_STATE_OVERRIDE/source.status" || fail 'invalid successor emitted receipt'
  done
  [ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ] || fail 'qualification moved caller checkout'
  canonical completed checks-passed
  pass 'submitted A and qualified B stay distinct for handoff, direct qualification and receipt recovery; invalid successors refuse'
}

test_drain_observation_wait_releases_presentation() (
  local holder rc i attempt
  export FM_STATE_OVERRIDE="$TMP_ROOT/drain-custody-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  prepare_delivery
  canonical running
  stage handoff --handoff-json "$TMP_ROOT/guarded.json" >/dev/null || fail 'drain handoff admission'
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$STATE/.nm-observe-source.lock"
    fm_lock_acquire_wait "$lock"
    : > "$2/drain-holder-ready"
    while [ ! -f "$2/drain-holder-release" ]; do sleep 0.02; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$TMP_ROOT" &
  holder=$!
  for ((i=0; i<500; i++)); do
    [ ! -f "$TMP_ROOT/drain-holder-ready" ] || break
    sleep 0.02
  done
  [ -f "$TMP_ROOT/drain-holder-ready" ] || fail 'drain observation holder missing'
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  for attempt in 1 2; do
    rc=0
    fm_run_timed 20 "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/bounded-drain-$attempt.out" 2>&1 || rc=$?
    expect_code 0 "$rc" 'drain must return before outer watchdog'
    assert_contains "$(cat "$TMP_ROOT/bounded-drain-$attempt.out")" 'reconciliation remains unresolved status=124' 'drain lost timeout disposition'
    assert_absent "$FM_STATE_OVERRIDE/.status-presentation-lock/pid" 'drain retained presentation lock after timeout'
  done
  : > "$TMP_ROOT/drain-holder-release"
  wait "$holder" || fail 'drain observation holder failed'
  "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/recovered-drain.out" 2>&1 || fail 'drain after observation release'
  [ "$(meta completion_handoff | jq -r .status)" = pending ] || fail 'drain timeout completed work'
  pass 'contended reconciliation releases presentation custody and later drains remain usable'
)

# R12/R13: the producer, not terminal status, owns exact qualification.
test_monitoring_qualification_and_revocation() (
  export FM_STATE_OVERRIDE="$TMP_ROOT/monitoring-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  cp "$TMP_ROOT/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
  cp "$TMP_ROOT/initial.observe" "$FM_STATE_OVERRIDE/source.nm-observe"
  canonical ci
  export FM_FAKE_CI_LOGS='all CI checks passed - still monitoring'
  stage handoff --handoff-json "$TMP_ROOT/handoff.json" > "$TMP_ROOT/monitoring-admit" || fail 'monitoring admit'
  stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" > "$TMP_ROOT/monitoring-release" || fail "green monitoring must dispatch: $(cat "$TMP_ROOT/monitoring-release")"
  [ "$(meta stage_ci_ready_effect | jq -r .qualification.head)" = "$HEAD" ] || fail 'qualified tuple absent'
  cp "$FM_STATE_OVERRIDE/source.status" "$TMP_ROOT/monitoring-status"
  saved=$(meta completion_handoff | jq -c '.status="pending" | .receipt=null')
  sed -i '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta"
  printf 'completion_handoff=%s\n' "$saved" >> "$FM_STATE_OVERRIDE/source.meta"
  stage resume-handoff > "$TMP_ROOT/monitoring-recovery" || fail 'monitoring effect recovery'
  stage resume-handoff > "$TMP_ROOT/monitoring-repeat" || fail 'monitoring repeat'
  cmp "$TMP_ROOT/monitoring-status" "$FM_STATE_OVERRIDE/source.status" || fail 'monitoring receipt recovery repeated effect'
  cp "$FM_STATE_OVERRIDE/source.meta" "$TMP_ROOT/monitoring-before"
  export FM_FAKE_CI_LOGS='pending checks'
  for verb in show ci-ready landing activated resume-handoff; do
    if stage "$verb" --pr https://github.com/o/r/pull/7 > "$TMP_ROOT/monitoring-$verb" 2>&1; then
      fail "invalidated qualification accepted $verb"
    fi
  done
  cmp "$TMP_ROOT/monitoring-before" "$FM_STATE_OVERRIDE/source.meta" || fail 'invalidation erased historical evidence'
  pass 'monitoring uses exact revocable qualification; recovery and repeat dedupe; invalidated current uses refuse'
)

test_report_changes_during_teardown_status() (
  local mutation out rc original_wt=$WT proj holder_pid
  export FM_STATE_OVERRIDE="$TMP_ROOT/teardown-state"
  mkdir -p "$FM_STATE_OVERRIDE" "$TMP_ROOT/teardown-bin"
  for tool in tmux lsof; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/teardown-bin/$tool"
  done
  for tool in gh gh-axi; do
    printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/teardown-bin/$tool"
  done
  # Declared backend double: `treehouse return --force <worktree>` deletes the
  # worktree when asked, as the orca backend removal does before the archive.
  cat > "$TMP_ROOT/teardown-bin/treehouse" <<'SH'
#!/bin/sh
[ "${FM_TEST_TEARDOWN_REMOVE_WT:-0}" = 1 ] && [ "$1" = return ] && [ -d "$3" ] && rm -rf "$3"
exit 0
SH
  chmod +x "$TMP_ROOT/teardown-bin/"*
  export PATH="$TMP_ROOT/teardown-bin:$PATH"
  # changed/deleted: handoff report mutated during the conclude status read.
  # revoked: directly qualified task (no handoff) whose exact qualification is
  # revoked during that same read. late: handoff report mutated during the
  # final observation refresh. removed*: the backend deleted the worktree
  # before the archive boundary (removed positive; removed-late and
  # removed-revoked mutate during the final refresh, then removed-late reruns
  # with restored bytes). held: the observation lock is held across the
  # archive and the report changes while finalize waits. unchanged/direct:
  # positive controls.
  for mutation in ${1:-changed deleted unchanged revoked direct late removed removed-late removed-revoked held}; do
    WT="$TMP_ROOT/teardown-wt-$mutation"
    proj="$TMP_ROOT/teardown-proj-$mutation"
    git clone -q --no-hardlinks "$original_wt" "$WT" || fail 'private teardown clone'
    git clone -q --no-hardlinks "$original_wt" "$proj" || fail 'private project clone'
    git -C "$WT" remote remove origin
    git -C "$WT" branch main "$HEAD"
    prepare_delivery
    sed -e "s|^worktree=.*|worktree=$WT|" -e "s|^project=.*|project=$proj|" "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/teardown.meta"
    mv "$TMP_ROOT/teardown.meta" "$FM_STATE_OVERRIDE/source.meta"
    printf 'window=isolated:fm-source\nendpoint_task_id=source\n' >> "$FM_STATE_OVERRIDE/source.meta"
    case "$mutation" in
      revoked|direct)
        stage ci-ready --pr https://github.com/o/r/pull/7 >/dev/null || fail 'direct qualification'
        [ -z "$(meta completion_handoff)" ] || fail 'direct case must carry no handoff'
        ;;
      *)
        stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'teardown handoff'
        stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" >/dev/null || fail 'teardown dispatch'
        ;;
    esac
    [ -n "$(meta stage_ci_ready_effect)" ] || fail 'exact stage effect absent before teardown'
    printf 'private poll artifact\n' > "$FM_STATE_OVERRIDE/source.pr-poll"
    export FM_TEST_TEARDOWN_MUTATION=$mutation FM_TEST_TEARDOWN_REACHED="$TMP_ROOT/teardown-status-reached" \
      FM_TEST_TEARDOWN_REFRESHED="$TMP_ROOT/teardown-refresh-reached" FM_TEST_TEARDOWN_REVOKED="$TMP_ROOT/teardown-revoked" \
      FM_TEST_TEARDOWN_REMOVE_WT=0 FM_TEARDOWN_NM_TIMEOUT=10
    case "$mutation" in removed*) export FM_TEST_TEARDOWN_REMOVE_WT=1 ;; esac
    rm -f "$FM_TEST_TEARDOWN_REACHED" "$FM_TEST_TEARDOWN_REFRESHED" "$FM_TEST_TEARDOWN_REVOKED" \
      "$FM_DATA_OVERRIDE/source/completion-receipt.json" "$FM_DATA_OVERRIDE/source/nm-observation-receipt.md"
    cp "$FAKEBIN/no-mistakes" "$TMP_ROOT/teardown-no-mistakes"
    cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'axi qualification'*)
    [ ! -e "$FM_TEST_TEARDOWN_REVOKED" ] || exit 1
    exec python3 "$FM_TEST_QUALIFICATION_FIXTURE" "${@:3}" ;;
  'axi status')
    : > "$FM_TEST_TEARDOWN_REACHED"
    case "$FM_TEST_TEARDOWN_MUTATION" in
      changed) printf 'changed during conclude\n' >> "$FM_DATA_OVERRIDE/source/report.md" ;;
      deleted) rm -f "$FM_DATA_OVERRIDE/source/report.md" ;;
      revoked) : > "$FM_TEST_TEARDOWN_REVOKED" ;;
    esac
    cat "$FM_COMPLETION_TEST_CANONICAL"
    ;;
  'axi status --run '*)
    : > "$FM_TEST_TEARDOWN_REFRESHED"
    case "$FM_TEST_TEARDOWN_MUTATION" in
      late|removed-late) printf 'changed during final refresh\n' >> "$FM_DATA_OVERRIDE/source/report.md" ;;
      removed-revoked) : > "$FM_TEST_TEARDOWN_REVOKED" ;;
    esac
    cat "$FM_COMPLETION_TEST_CANONICAL"
    ;;
  'axi status'*) cat "$FM_COMPLETION_TEST_CANONICAL" ;;
  --version) echo 'no-mistakes version v1.61.0 (0af0be6) 2026-08-31T14:04:25Z' ;;
  *) exit 90 ;;
esac
SH
    holder_pid=
    if [ "$mutation" = held ]; then
      export FM_TEARDOWN_NM_TIMEOUT=2
      # Declared contention double: another observation writer holds the
      # per-task observation lock through the archive, changes the report
      # while finalize waits on that lock, then releases it.
      bash -c '
        . "$1/bin/fm-wake-lib.sh"
        fm_lock_try_acquire "$2/.nm-observe-source.lock" || exit 91
        i=0
        while [ ! -f "$3/source/completion-receipt.json" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
        [ -f "$3/source/completion-receipt.json" ] || { fm_lock_release "$2/.nm-observe-source.lock"; exit 92; }
        printf "changed while finalize waited\n" >> "$3/source/report.md"
        fm_lock_release "$2/.nm-observe-source.lock"
      ' _ "$ROOT" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" &
      holder_pid=$!
      sleep 0.5
    fi
    rc=0; out=$("$ROOT/bin/fm-teardown.sh" source 2>&1) || rc=$?
    if [ -n "$holder_pid" ]; then wait "$holder_pid" || fail "observation lock holder failed ($?): $out"; fi
    mv "$TMP_ROOT/teardown-no-mistakes" "$FAKEBIN/no-mistakes"
    assert_present "$FM_TEST_TEARDOWN_REACHED" "teardown did not reach conclude status: $out"
    case "$mutation" in
      unchanged|direct|removed)
        expect_code 0 "$rc" "$mutation actual teardown: $out"
        assert_present "$FM_TEST_TEARDOWN_REFRESHED" 'final observation refresh must read canonical state'
        assert_absent "$FM_STATE_OVERRIDE/source.meta" "$mutation teardown retained metadata"
        assert_absent "$FM_STATE_OVERRIDE/source.nm-observe" "$mutation teardown retained observation obligation"
        assert_absent "$FM_STATE_OVERRIDE/source.pr-poll" "$mutation teardown retained poll artifact"
        assert_grep 'finalized at' "$FM_DATA_OVERRIDE/source/nm-observation-receipt.md" 'observation receipt not finalized'
        if [ "$mutation" != direct ]; then
          assert_present "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'final retirement archive missing'
        fi
        [ "$mutation" != removed ] || assert_absent "$WT" 'backend double must have removed the worktree'
        ;;
      *)
        expect_code 1 "$rc" "$mutation during teardown"
        case "$mutation" in
          revoked|removed-revoked) assert_contains "$out" 'exact qualification is invalidated' 'direct qualification refusal' ;;
          *) assert_contains "$out" 'completion handoff remains unresolved' 'final retirement must refuse' ;;
        esac
        assert_not_contains "$out" 'teardown source complete' 'stopped retirement must not report success'
        assert_present "$FM_STATE_OVERRIDE/source.meta" 'teardown erased unresolved metadata'
        assert_present "$FM_STATE_OVERRIDE/source.nm-observe" 'teardown erased observation obligation'
        assert_present "$FM_STATE_OVERRIDE/source.pr-poll" 'teardown erased poll artifact on refusal'
        [ -n "$(meta stage_ci_ready_effect)" ] || fail 'refusal erased historical stage effect'
        case "$mutation" in
          held)
            assert_contains "$out" 'retained unresolved' 'held refusal must expose partial cleanup'
            assert_contains "$out" 'lock or canonical read still pending' 'bounded observation wait must warn, never stay silent'
            assert_present "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'authorization archive taken before the late change must remain as evidence'
            [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'teardown erased historical handoff'
            ;;
          late|removed-late|removed-revoked)
            if grep -qx 'stage=finalized' "$FM_STATE_OVERRIDE/source.nm-observe"; then fail 'refusal finalized an unresolved obligation'; fi
            assert_present "$FM_TEST_TEARDOWN_REFRESHED" "$mutation must reach the final refresh"
            assert_contains "$out" 'retained unresolved' "$mutation refusal must expose partial cleanup"
            assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'refusal archived invalidated handoff'
            [ "$mutation" = removed-revoked ] || [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'teardown erased historical handoff'
            case "$mutation" in removed*) assert_absent "$WT" 'backend double must have removed the worktree' ;; esac
            if [ "$mutation" = removed-late ]; then
              printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
              rc=0; out=$("$ROOT/bin/fm-teardown.sh" source 2>&1) || rc=$?
              expect_code 0 "$rc" "rerun without worktree after restored bytes: $out"
              assert_absent "$FM_STATE_OVERRIDE/source.meta" 'rerun retained metadata'
              assert_present "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'rerun retirement archive missing'
            fi
            ;;
          revoked)
            if grep -qx 'stage=finalized' "$FM_STATE_OVERRIDE/source.nm-observe"; then fail 'refusal finalized an unresolved obligation'; fi
            assert_absent "$FM_TEST_TEARDOWN_REFRESHED" 'revoked qualification must refuse before the final refresh'
            assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'refusal archived invalidated handoff'
            ;;
          *)
            if grep -qx 'stage=finalized' "$FM_STATE_OVERRIDE/source.nm-observe"; then fail 'refusal finalized an unresolved obligation'; fi
            assert_absent "$FM_TEST_TEARDOWN_REFRESHED" 'status-read refusal must stop before the final refresh'
            assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'refusal archived invalidated handoff'
            [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'teardown erased historical handoff'
            ;;
        esac
        ;;
    esac
    pass "actual teardown status boundary: $mutation"
  done
  printf 'complete private report\n' > "$FM_DATA_OVERRIDE/source/report.md"
)

test_report_changes_during_qualification() (
  local boundary mutation identity saved before out rc
  export FM_STATE_OVERRIDE="$TMP_ROOT/qualification-state"
  mkdir -p "$FM_STATE_OVERRIDE"
  mkdir -p "$TMP_ROOT/qualification-bin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/qualification-bin/tmux"
  chmod +x "$TMP_ROOT/qualification-bin/tmux"
  export PATH="$TMP_ROOT/qualification-bin:$PATH"
  for boundary in ${1:-stage existing recovery retirement}; do
    for mutation in ${2:-changed deleted unchanged}; do
      prepare_delivery
      printf 'window=isolated:fm-source\nendpoint_task_id=source\n' >> "$FM_STATE_OVERRIDE/source.meta"
      stage handoff --handoff-json "$TMP_ROOT/handoff.json" >/dev/null || fail 'qualification race admission'
      identity=$(meta completion_handoff | jq -r .identity)
      if [ "$boundary" != stage ]; then
        stage handoff-release --identity "$identity" >/dev/null || fail 'qualification race initial effect'
        if [ "$boundary" = recovery ]; then
          saved=$(meta completion_handoff | jq -c '.status="pending" | .receipt=null')
          sed '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta" > "$TMP_ROOT/recovery.meta"
          printf 'completion_handoff=%s\n' "$saved" >> "$TMP_ROOT/recovery.meta"
          mv "$TMP_ROOT/recovery.meta" "$FM_STATE_OVERRIDE/source.meta"
        fi
      else
        canonical running
        stage handoff-release --identity "$identity" >/dev/null || fail 'qualification race release'
        canonical completed checks-passed
      fi
      before=$(cat "$FM_STATE_OVERRIDE/source.meta")
      cp "$FM_STATE_OVERRIDE/source.status" "$TMP_ROOT/qualification-status"
      export FM_TEST_CUSTODY_ROOT="$ROOT" FM_TEST_CUSTODY_RESULT="$TMP_ROOT/custody-result"
      rm -f "$FM_TEST_CUSTODY_RESULT"
      export FM_TEST_REPORT_MUTATION="$mutation" FM_TEST_REPORT_PATH="$FM_DATA_OVERRIDE/source/report.md"
      export FM_TEST_REPORT_COUNTER="$TMP_ROOT/qualification-counter" FM_TEST_REPORT_TRIGGER=2
      case "$boundary" in stage|existing) export FM_TEST_REPORT_TRIGGER=1 ;; esac
      printf '0' > "$FM_TEST_REPORT_COUNTER"
      cp "$FAKEBIN/no-mistakes" "$TMP_ROOT/qualification-original"
      cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'axi qualification'*)
    result=$(python3 "$FM_TEST_QUALIFICATION_FIXTURE" "${@:3}") || exit 1
    if [[ " $* " == *' --attempt '* ]]; then
      count=$(cat "$FM_TEST_REPORT_COUNTER")
      count=$((count + 1))
      printf '%s' "$count" > "$FM_TEST_REPORT_COUNTER"
      if [ "$count" = "$FM_TEST_REPORT_TRIGGER" ]; then
        case "$FM_TEST_REPORT_MUTATION" in
          changed) printf 'changed during qualification\n' >> "$FM_TEST_REPORT_PATH" ;;
          deleted) rm "$FM_TEST_REPORT_PATH" ;;
          spawn_gen|stage_run|stage_attempt|stage_head|replacement)
            bash -c '
              . "$FM_TEST_CUSTODY_ROOT/bin/fm-wake-lib.sh"
              lock=$(fm_meta_lock_path "$STATE/source.meta")
              if fm_lock_try_acquire "$lock"; then
                field=$FM_TEST_REPORT_MUTATION
                [ "$field" != replacement ] || field=spawn_gen
                sed "s/^$field=.*/$field=replaced/" "$STATE/source.meta" > "$STATE/source.next"
                mv "$STATE/source.next" "$STATE/source.meta"
                printf published > "$FM_TEST_CUSTODY_RESULT"
                fm_lock_release "$lock"
              else
                printf blocked > "$FM_TEST_CUSTODY_RESULT"
              fi
            ' || exit 1
            ;;
        esac
      fi
    fi
    printf '%s\n' "$result"
    ;;
  'axi status'*) cat "$FM_COMPLETION_TEST_CANONICAL" ;;
  --version) echo 'no-mistakes version v1.61.0 (0af0be6) 2026-08-31T14:04:25Z' ;;
  *) exit 90 ;;
esac
SH
      rc=0
      if [ "$boundary" = retirement ]; then
        rm -f "$FM_DATA_OVERRIDE/source/completion-receipt.json"
        out=$("$ROOT/bin/fm-teardown.sh" source 2>&1) || rc=$?
      else
        out=$(stage resume-handoff 2>&1) || rc=$?
      fi
      mv "$TMP_ROOT/qualification-original" "$FAKEBIN/no-mistakes"
      [ "$(cat "$FM_TEST_REPORT_COUNTER")" -ge "$FM_TEST_REPORT_TRIGGER" ] || fail "$boundary did not reach selected qualification boundary: $out"
      case "$mutation" in
        spawn_gen|stage_run|stage_attempt|stage_head|replacement)
          expect_code 0 "$rc" 'qualification retains source custody'
          [ "$(cat "$FM_TEST_CUSTODY_RESULT")" = blocked ] || fail 'metadata owner published a replacement during current-success qualification'
          [ "$before" = "$(cat "$FM_STATE_OVERRIDE/source.meta")" ] || fail 'custody changed matching receipt'
          bash -c '
            . "$FM_TEST_CUSTODY_ROOT/bin/fm-wake-lib.sh"
            lock=$(fm_meta_lock_path "$STATE/source.meta")
            fm_lock_try_acquire "$lock" || exit 1
            field=$FM_TEST_REPORT_MUTATION
            [ "$field" != replacement ] || field=spawn_gen
            sed "s/^$field=.*/$field=replaced/" "$STATE/source.meta" > "$STATE/source.next"
            mv "$STATE/source.next" "$STATE/source.meta"
            fm_lock_release "$lock"
          ' || fail 'metadata owner could not publish after confirmation released custody'
          rc=0; out=$(stage resume-handoff 2>&1) || rc=$?
          expect_code 1 "$rc" 'replacement after custody release must refuse stale handoff'
          pass "metadata custody serializes $mutation and refuses subsequent stale confirmation"
          continue
          ;;
      esac
      if [ "$mutation" != unchanged ]; then
        expect_code 1 "$rc" "$boundary $mutation during qualification"
        [ "$before" = "$(cat "$FM_STATE_OVERRIDE/source.meta")" ] || fail "$boundary published metadata after report $mutation"
        cmp -s "$TMP_ROOT/qualification-status" "$FM_STATE_OVERRIDE/source.status" || fail "$boundary emitted stage effect after report $mutation"
        if [ "$boundary" = existing ]; then
          assert_contains "$out" COMPLETION_CNO 'matching receipt must not suppress report refusal'
          [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'refusal erased historical dispatched receipt'
        fi
        if [ "$boundary" = retirement ]; then
          assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'qualification race archived receipt'
          assert_contains "$out" 'completion handoff remains unresolved' 'retirement must refuse at completion owner'
        fi
      elif [ "$boundary" = retirement ]; then
        assert_absent "$FM_DATA_OVERRIDE/source/completion-receipt.json" 'unlanded preflight archived a receipt'
        expect_code 1 "$rc" 'unlanded work must still refuse teardown'
      else
        expect_code 0 "$rc" "$boundary unchanged qualification"
        [ "$(meta completion_handoff | jq -r .status)" = dispatched ] || fail 'unchanged receipt missing'
        case "$boundary" in
          existing|recovery)
            cmp -s "$TMP_ROOT/qualification-status" "$FM_STATE_OVERRIDE/source.status" || fail 'reconciliation repeated stage effect'
            saved=$(meta completion_handoff)
            stage resume-handoff >/dev/null || fail 'unchanged receipt first replay'
            stage resume-handoff >/dev/null || fail 'unchanged receipt second replay'
            [ "$saved" = "$(meta completion_handoff)" ] || fail 'replay rewrote matching receipt'
            cmp -s "$TMP_ROOT/qualification-status" "$FM_STATE_OVERRIDE/source.status" || fail 'replay repeated stage effect'
            ;;
        esac
      fi
      pass "$boundary refuses $mutation report during qualification or preserves unchanged success"
    done
  done
)

if [ "${1:-}" = retirement-status ]; then
  test_report_changes_during_teardown_status "${2:-changed deleted unchanged revoked direct late removed removed-late removed-revoked held}" || exit 1
  exit 0
fi
if [ "${1:-}" = custody-order ]; then
  test_self_target_delivery
  test_opposite_direction_delivery_does_not_deadlock
  test_ci_ready_child_revalidates_admitted_identity
  exit 0
fi

if [ "${1:-}" = qualification-report ]; then
  test_report_changes_during_qualification "${2:-stage existing recovery retirement}" "${3:-changed deleted unchanged}" || exit 1
  exit 0
fi

if [ "${1:-}" = report-integrity ]; then
  case "${2:-all}" in
    retirement) test_retirement_revalidates_report_and_effect || exit 1 ;;
    delivery) test_destination_changes_while_delivery_waits ;;
    child) test_ci_ready_child_revalidates_admitted_identity ;;
    all)
      test_retirement_revalidates_report_and_effect || exit 1
      test_destination_changes_while_delivery_waits
      test_ci_ready_child_revalidates_admitted_identity
      ;;
    *) fail 'unknown report integrity case' ;;
  esac
  exit 0
fi

test_monitoring_qualification_and_revocation || exit 1
test_report_changes_during_qualification || exit 1
test_report_changes_during_teardown_status || exit 1

test_show_refreshes_stale_completed_run
test_resume_completed_report_without_wake
test_authoritative_effect_repairs_missing_receipt
test_positive_receipt_retirement_archive
test_retirement_revalidates_report_and_effect || exit 1
test_stage_advancement_preserves_effect
test_canonical_read_failure_keeps_receipt
test_duplicate_and_changed_bytes
test_handled_inbox_keeps_open_action_and_deduplicates
test_stop_checkpoint_delayed_report_caller_chain
test_unknown_conflicting_and_stale_authority_refuses
test_session_start_reconciles_durable_handoff
test_concurrent_resume_dispatches_once
test_remote_and_destination_lease
test_destination_changes_while_delivery_waits
test_self_target_delivery
test_unqualified_and_foreign_stage_effects_refuse
test_checkpoint_observation_lock_bounds
test_opposite_direction_delivery_does_not_deadlock
test_ci_ready_child_revalidates_admitted_identity
test_away_housekeeping_bounds_observation_wait
test_qualified_successor_identity
test_drain_observation_wait_releases_presentation
test_handoff_identity_survives_a_broken_digest_tool || exit 1
test_landing_destination_mismatch_refuses_early || exit 1
