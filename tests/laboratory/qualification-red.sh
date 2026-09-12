#!/usr/bin/env bash
set -euo pipefail
export FM_PAIR_LEGACY=1 FM_PAIR_STAGE_ROOT=${FM_QUALIFICATION_BASELINE_ROOT:?}
. "$(dirname "${BASH_SOURCE[0]}")/qualification-fixture.sh"
stage committed > "$LAB/committed.out"
stage running --run "$RUN" > "$LAB/running.out"
no-mistakes axi qualification --run "$RUN" --head "$B" --json > "$LAB/producer-green.json"
printf 'private synthetic report\n' > "$FM_DATA_OVERRIDE/source/report.md"
jq -n --arg candidate "$A" --arg head "$B" --arg attempt "$(meta stage_attempt)" --arg run "$RUN" --arg pr "$PR" \
 --arg path "$FM_DATA_OVERRIDE/source/report.md" --arg sha "$(sha256sum "$FM_DATA_OVERRIDE/source/report.md" | cut -d' ' -f1)" \
 '{schema:"fm-completion-handoff/v1",task:"source",generation:"admission-generation",attempt:$attempt,run:$run,candidate:$candidate,source_head:$head,report:{path:$path,sha256:$sha},action:{id:"ci",kind:"ci-ready",owner:"source",generation:"admission-generation",pr:$pr}}' > "$LAB/handoff.json"
stage handoff --handoff-json "$LAB/handoff.json" > "$LAB/admit.out"
rc=0
stage handoff-release --identity "$(meta completion_handoff | jq -r .identity)" > "$LAB/release.out" || rc=$?
printf 'monitoring handoff exit=%s disposition=%s\n' "$rc" "$(cat "$LAB/release.out")"
sed -i '/^completion_handoff=/d' "$FM_STATE_OVERRIDE/source.meta"
FM_PAIR_RACE=1 FM_COMPLETION_RECONCILING=1 stage ci-ready --pr "$PR" > "$LAB/race.out"
C=$(cat "$LAB/canonical-head")
refuses no-mistakes axi qualification --run "$RUN" --head "$C" --json
if [ "$(meta stage_ci_ready_effect | jq -r .source_head)" = "$C" ]; then
 printf 'WATCHED RED: actual prior stage published unqualified C after green B; producer refuses C\n'
 exit 1
fi
printf 'unexpected baseline result\n' >&2
exit 2
