#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/laboratory/qualification-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/qualification-fixture.sh"
stage committed > "$LAB/committed.out"
stage running --run "$RUN" > "$LAB/running.out"
cp "$FM_STATE_OVERRIDE/source.meta" "$LAB/initial.meta"
FM_COMPLETION_RECONCILING=1 stage ci-ready --pr "$PR" > "$LAB/direct.out"
[ "$(meta stage_ci_ready_effect | jq -r .source_head)" = "$B" ]
cp "$LAB/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
: > "$FM_STATE_OVERRIDE/source.status"
printf 'private synthetic report\n' > "$FM_DATA_OVERRIDE/source/report.md"
jq -n --arg task source --arg candidate "$A" --arg head "$B" --arg attempt "$(meta stage_attempt)" --arg run "$RUN" --arg pr "$PR" \
 --arg path "$FM_DATA_OVERRIDE/source/report.md" --arg sha "$(sha256sum "$FM_DATA_OVERRIDE/source/report.md" | cut -d' ' -f1)" \
 '{schema:"fm-completion-handoff/v1",task:$task,generation:"admission-generation",attempt:$attempt,run:$run,candidate:$candidate,source_head:$head,report:{path:$path,sha256:$sha},action:{id:"ci",kind:"ci-ready",owner:$task,generation:"admission-generation",pr:$pr}}' > "$LAB/handoff.json"
stage handoff --handoff-json "$LAB/handoff.json" > "$LAB/admit.out"
stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" > "$LAB/release.out"
[ "$(meta stage_ci_ready_effect | jq -r .source_head)" = "$B" ]
[ "$(meta stage_head)" = "$A" ]
[ "$(meta stage_ci_ready_effect | jq -r .qualification.attempt)" != "$(meta stage_attempt)" ]
[ "$(meta completion_handoff | jq -r .status)" = dispatched ]
cp "$FM_STATE_OVERRIDE/source.status" "$LAB/issued.status"
saved=$(meta completion_handoff | jq -c '.status="pending" | .receipt=null')
sed -i '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta"
printf 'completion_handoff=%s\n' "$saved" >> "$FM_STATE_OVERRIDE/source.meta"
stage resume-handoff > "$LAB/recover.out"
stage resume-handoff > "$LAB/repeat.out"
cmp "$FM_STATE_OVERRIDE/source.status" "$LAB/issued.status"
stage ci-ready --pr "$PR" > "$LAB/unchanged.out"
FM_COMPLETION_RECONCILING=1 stage show > "$LAB/show.out"
"$ROOT/bin/fm-pr-check.sh" source "$PR" > "$LAB/register.out"
refuses "$ROOT/bin/fm-pr-merge.sh" source "$PR"
grep -q QUALIFIED_MERGE_HEAD_GUARD_UNAVAILABLE "$LAB/refusal.out"
cp "$FM_STATE_OVERRIDE/source.meta" "$LAB/ci-ready.meta"
bash -c 'set -e; . "$1/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$2"; fm_pr_poll_artifacts_valid "$3" source "$1/bin/fm-pr-poll.sh"' _ "$ROOT" "$FM_STATE_OVERRIDE/source.meta" "$FM_STATE_OVERRIDE"
for field in attempt generation evidence_sha256 repo branch head; do
 effect=$(meta stage_ci_ready_effect | jq -c --arg field "$field" '.qualification[$field]="stale"')
 sed '/^stage_ci_ready_effect=/d' "$LAB/ci-ready.meta" > "$FM_STATE_OVERRIDE/source.meta"
 printf 'stage_ci_ready_effect=%s\n' "$effect" >> "$FM_STATE_OVERRIDE/source.meta"
 refuses bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$2"' _ "$ROOT" "$FM_STATE_OVERRIDE/source.meta"
 cp "$LAB/ci-ready.meta" "$FM_STATE_OVERRIDE/source.meta"
done
stage landing > "$LAB/landing.out"
cp "$FM_STATE_OVERRIDE/source.meta" "$LAB/landing.meta"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\ntest/repo\n42\n' > "$FM_STATE_OVERRIDE/source.pr-poll-merge-notified"
stage activated > "$LAB/activated.out"
cp "$FM_STATE_OVERRIDE/source.meta" "$LAB/activated.meta"
printf 'PASS exact artifact: active monitoring dispatch, exact B, receipt recovery, repeat, landing and activation\n'
cp "$LAB/initial.meta" "$FM_STATE_OVERRIDE/source.meta"
rm "$FM_STATE_OVERRIDE/source.pr-poll-merge-notified"
: > "$FM_STATE_OVERRIDE/source.status"
refuses env FM_PAIR_RACE=1 FM_COMPLETION_RECONCILING=1 "$ROOT/bin/fm-stage.sh" source ci-ready --pr "$PR"
[ "$(meta stage)" = validation-running ]
[ -z "$(meta stage_ci_ready_effect)" ]
[ ! -s "$FM_STATE_OVERRIDE/source.status" ]
printf 'PASS exact artifact: B observed then producer C; no CI-ready effect or receipt\n'
for advanced in ci-ready landing activated; do
 cp "$LAB/$advanced.meta" "$FM_STATE_OVERRIDE/source.meta"
 cp "$FM_STATE_OVERRIDE/source.meta" "$LAB/before.meta"
 refuses env FM_COMPLETION_RECONCILING=1 "$ROOT/bin/fm-stage.sh" source show
 refuses env FM_COMPLETION_RECONCILING=1 "$ROOT/bin/fm-stage.sh" source "$advanced" --pr "$PR"
 refuses stage resume-handoff
 refuses "$ROOT/bin/fm-pr-check.sh" source "$PR"
 refuses "$ROOT/bin/fm-pr-merge.sh" source "$PR"
 refuses bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$2"' _ "$ROOT" "$FM_STATE_OVERRIDE/source.meta"
 refuses bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_poll_artifacts_valid "$2" source "$1/bin/fm-pr-poll.sh"' _ "$ROOT" "$FM_STATE_OVERRIDE"
 refuses bash -c 'SCRIPT_DIR=$1/bin; . "$SCRIPT_DIR/fm-completion-lib.sh"; fm_completion_retire "$2" "$3" source' _ "$ROOT" "$(meta completion_handoff)" "$FM_DATA_OVERRIDE"
 cmp "$LAB/before.meta" "$FM_STATE_OVERRIDE/source.meta"
done
printf 'PASS exact artifact: invalidated no-op/show/advanced/recovery/registration/parser/retirement refuse and preserve records\n'
