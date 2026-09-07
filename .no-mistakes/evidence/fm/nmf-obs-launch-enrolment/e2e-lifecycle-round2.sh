#!/usr/bin/env bash
# Manual end-to-end walk of bin/fm-nm-observe.sh as firstmate would drive it:
# enrol -> launch (admitted before the worker is told) -> bind the real run ->
# refresh from the canonical record -> reconcile (orphan, unbound, peek vs now,
# vanished, daemon reset, preflight refusal) -> receipt -> finalize.
# Isolated fixtures: throwaway git repos, a fake `no-mistakes` serving TOON and
# logging every argv, a fake NM_HOME daemon.pid. Never touches a real daemon.
set -u
ROOT=${1:?worktree root}
OBSERVE="$ROOT/bin/fm-nm-observe.sh"
TMP=$(mktemp -d /tmp/fm-nm-e2e.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; STATE="$HOME_DIR/state"; DATA="$HOME_DIR/data"
mkdir -p "$STATE" "$DATA" "$TMP/fakebin" "$TMP/nm-home"
NM_LOG="$TMP/no-mistakes.argv"; : > "$NM_LOG"
cat > "$TMP/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
case "${1:-} ${2:-}" in
  "axi status")
    if [ "${3:-}" = --run ]; then
      if [ -n "${FM_FAKE_AXI_STATUS_RUN_NOT_FOUND:-}" ]; then
        printf 'error: "run \\"%s\\" not found"\n' "${4:-}"; exit 1
      fi
      if [ -f "${FM_FAKE_RUNS_DIR:?}/${4:-}.toon" ]; then cat "$FM_FAKE_RUNS_DIR/${4:-}.toon"; else printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"; fi
    else
      printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
    fi ;;
esac
exit 0
SH
chmod +x "$TMP/fakebin/no-mistakes"
printf '#!/usr/bin/env bash\nexit "${FM_FAKE_TMUX_RC:-0}"\n' > "$TMP/fakebin/tmux"; chmod +x "$TMP/fakebin/tmux"
mkdir -p "$TMP/runs"; export PATH="$TMP/fakebin:$PATH" FM_FAKE_NM_LOG="$NM_LOG" FM_FAKE_RUNS_DIR="$TMP/runs"
setrun() { toon_run "$@" > "$TMP/runs/$1.toon"; }
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
export FM_NM_OBSERVE_TIMEOUT=5 FM_NM_OBSERVE_BUDGET_SECS=10 FM_NM_OBSERVE_LAUNCH_GRACE_SECS=0
export GIT_AUTHOR_NAME=fm GIT_AUTHOR_EMAIL=fm@example.invalid GIT_COMMITTER_NAME=fm GIT_COMMITTER_EMAIL=fm@example.invalid
printf '{"pid":4242,"started_at":"2026-09-06T00:00:00Z"}\n' > "$TMP/nm-home/daemon.pid"
profile() { printf '{"record":"fm-tool-profile/v1","profile":{"nm_home":"%s","path0":"/opt/tools/bin","parent":"bash","state":"OBSERVED","detail":""},"tools":[{"state":"%s","tool":"no-mistakes","version":"1.61.0","bound":"floor=1.46.0","path":"/opt/tools/bin/no-mistakes","required":true,"detail":"build 0af0be6"}],"unready":[%s],"ready":%s}\n' "$TMP/nm-home" "$2" "$3" "$1" > "$TMP/profile-$1.json"; }
profile true QUALIFIED ''
profile false ABSENT '"ENVIRONMENT_UNREADY: no-mistakes ABSENT; owner: install it"'
mkwt() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" commit -q --allow-empty -m init; git -C "$1" checkout -q -b "$2"; printf 'commands:\n  lint: bin/fm-lint.sh\n' > "$1/.no-mistakes.yaml"; git -C "$1" add .no-mistakes.yaml; git -C "$1" commit -q -m policy; }
mktask() { printf '%s\n' "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$4" "project=$4" "harness=echo" "kind=$2" "mode=$3" "yolo=off" > "$STATE/$1.meta"; }
toon_status() { local rows=$2 n; n=$(printf '%s\n' "$rows" | grep -c . || true); printf 'current_branch: %s\ncount: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$1" "$n" "$n" "$n"; printf '%s\n' "$rows" | awk -F '\t' 'NF >= 4 { printf "  \"%s\",%s,%s,%s,\"%s\"\n", $1, $2, $3, $4, $5 }'; }
toon_cur() { printf 'current_branch: %s\nrun:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: %s\n' "$2" "$1" "$2" "$3" "$4"; }
toon_run() { printf 'current_branch: %s\nother_branch_run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: %s\n  pr: "%s"\n  steps[1]{step,status,findings,duration_ms}:\n    intent,completed,0,9\n' "$2" "$1" "$2" "$3" "$4" "${6:-}"; [ -z "$5" ] || printf 'outcome: %s\n' "$5"; }
redact() { sed -e "s#$TMP#<tmp>#g" -e "s#$ROOT#<repo>#g"; }
step() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$(printf '%q ' "$@" | sed -e "s#$TMP#<tmp>#g" -e "s#$ROOT#<repo>#g" -e 's#<repo>/bin/fm-nm-observe.sh#bin/fm-nm-observe.sh#')"; "$@" 2>&1 | redact; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
show() { printf '$ cat %s\n' "$(printf '%s' "$1" | redact)"; redact < "$1"; }

WT1="$TMP/wt-t1"; mkwt "$WT1" fm/t1; HEAD1=$(git -C "$WT1" rev-parse HEAD); S1=${HEAD1:0:8}
WT2="$TMP/wt-t2"; mkwt "$WT2" fm/t2; HEAD2=$(git -C "$WT2" rev-parse HEAD); S2=${HEAD2:0:8}
WT3="$TMP/wt-t3"; mkwt "$WT3" fm/t3
mktask t1 ship no-mistakes "$WT1"; mktask t2 ship no-mistakes "$WT2"; mktask t3 ship no-mistakes "$WT3"; mktask s1 scout "" "$WT3"

echo "# fm-nm-observe end-to-end transcript (isolated fixtures, fake no-mistakes)"
step "1. enrol: obligation exists for a managed ship task; a scout is refused"
run "$OBSERVE" enrol t1 --entrypoint spawn
run "$OBSERVE" enrol s1
step "2. launch: attempt admitted BEFORE the worker is instructed; identity recorded, no run id"
run "$OBSERVE" launch t1 --profile-json "$TMP/profile-true.json"
show "$STATE/t1.nm-observe"
step "3. bind with no run yet: MISSING_BINDING, nothing written"
FM_FAKE_AXI_STATUS=$(toon_status fm/t1 "") run "$OBSERVE" bind t1
step "4. worker created the run; bind the ACTUAL run id from axi status"
export FM_FAKE_AXI_STATUS; FM_FAKE_AXI_STATUS=$(toon_cur 01RUNT1 fm/t1 running "$S1"; toon_status fm/t1 "$(printf '01RUNT1\tfm/t1\trunning\t%s\t' "$S1")")
setrun 01RUNT1 fm/t1 running "$S1" ""
run "$OBSERVE" bind t1
run "$OBSERVE" bind t1
grep -E '^(stage|attempt_id|run_id|run_status|outcome_class|daemon_epoch)=' "$STATE/t1.nm-observe" | redact
step "5. launch again while the bound run is active: identity kept (resume)"
run "$OBSERVE" launch t1 --profile-json "$TMP/profile-true.json"
step "6. refresh: outcome comes only from the canonical record"
setrun 01RUNT1 fm/t1 completed "$S1" success
FM_FAKE_AXI_STATUS=$(toon_status fm/t1 "$(printf '01RUNT1\tfm/t1\tcompleted\t%s\t' "$S1")")
run "$OBSERVE" refresh t1
grep -E '^(run_status|run_outcome|outcome_class)=' "$STATE/t1.nm-observe"
step "7. first reconcile: pre-existing foreign row becomes BASELINE (uncovered history)"
FM_FAKE_AXI_STATUS=$(toon_status fm/t1 "$(printf '01RUNT1\tfm/t1\tcompleted\t%s\t\n01OLDRUN\tfm/elsewhere\tcompleted\tfeedface\t' "$S1")")
run "$OBSERVE" reconcile --now
step "8. unchanged healthy inventory: silent"
run "$OBSERVE" reconcile --now
step "9. a new run from another home appears: ORPHAN_RUN once, then quiet"
FM_FAKE_AXI_STATUS=$(toon_status fm/t1 "$(printf '01RUNT1\tfm/t1\tcompleted\t%s\t\n01OLDRUN\tfm/elsewhere\tcompleted\tfeedface\t\n01FOREIGN\tfm/other-home\trunning\tcafebabe\t' "$S1")")
run "$OBSERVE" reconcile --now
run "$OBSERVE" reconcile --now
step "10. crash between run creation and binding: t2 launch-accepted, run exists, never bound -> UNBOUND_RUN"
run "$OBSERVE" launch t2 --profile-json "$TMP/profile-true.json"
FM_FAKE_AXI_STATUS=$(toon_status fm/t1 "$(printf '01RUNT1\tfm/t1\tcompleted\t%s\t\n01OLDRUN\tfm/elsewhere\tcompleted\tfeedface\t\n01FOREIGN\tfm/other-home\trunning\tcafebabe\t\n01RUNT2\tfm/t2\trunning\t%s\t' "$S1" "$S2")")
echo "watcher seam: reconcile --peek --now prints the finding but does NOT consume it"
WM_BEFORE=$(sha256sum "$STATE/.nm-observe-watermark" | cut -c1-16)
run "$OBSERVE" reconcile --peek --now
echo "watermark sha before peek=$WM_BEFORE after peek=$(sha256sum "$STATE/.nm-observe-watermark" | cut -c1-16)"
echo "firstmate on 'check: nm-observe' runs reconcile --now: identical lines, cursor committed"
run "$OBSERVE" reconcile --now
echo "watermark sha after --now=$(sha256sum "$STATE/.nm-observe-watermark" | cut -c1-16)"
run "$OBSERVE" reconcile --now
step "11. heal the UNBOUND_RUN: bind t2, then reconcile is quiet"
setrun 01RUNT2 fm/t2 running "$S2" ""
FM_FAKE_AXI_STATUS=$(toon_cur 01RUNT2 fm/t2 running "$S2"; toon_status fm/t2 "$(printf '01RUNT1\tfm/t1\tcompleted\t%s\t\n01OLDRUN\tfm/elsewhere\tcompleted\tfeedface\t\n01FOREIGN\tfm/other-home\trunning\tcafebabe\t\n01RUNT2\tfm/t2\trunning\t%s\t' "$S1" "$S2")")
run "$OBSERVE" bind t2
run "$OBSERVE" reconcile --now
step "12. crash between launch acceptance and run creation: t3 accepted, worker dead, no run -> LAUNCH_GAP"
run "$OBSERVE" launch t3 --profile-json "$TMP/profile-true.json"
FM_FAKE_TMUX_RC=1 run "$OBSERVE" reconcile --now
step "13. the daemon says the bound run is unknown: RUN_VANISHED (not an outage)"
FM_FAKE_AXI_STATUS_RUN_NOT_FOUND=1 run "$OBSERVE" refresh t2
step "14. query failure: INVENTORY_UNAVAILABLE, recorded class kept"
PATH_SAVE=$PATH; mv "$TMP/fakebin/no-mistakes" "$TMP/fakebin/no-mistakes.off"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FM_FAKE_NM_LOG"; exit 3\n' > "$TMP/fakebin/no-mistakes"; chmod +x "$TMP/fakebin/no-mistakes"
run "$OBSERVE" refresh t2
mv -f "$TMP/fakebin/no-mistakes.off" "$TMP/fakebin/no-mistakes"
setrun 01RUNT2 fm/t2 running "$S2" ""
step "15. daemon restart under bound runs: refresh/reconcile report DAEMON_RESET; a fresh bind is refused unless accepted"
printf '{"pid":5151,"started_at":"2026-09-06T02:00:00Z"}\n' > "$TMP/nm-home/daemon.pid"
run "$OBSERVE" refresh t2
echo "t3's crashed launch is relaunched and its worker now created a run; binding it across the reset is refused"
FM_FAKE_AXI_STATUS=$(toon_cur 01RUNT3 fm/t3 running "$(git -C "$WT3" rev-parse --short=8 HEAD)"; toon_status fm/t3 "$(printf '01RUNT3\tfm/t3\trunning\t%s\t' "$(git -C "$WT3" rev-parse --short=8 HEAD)")")
run "$OBSERVE" bind t3
grep -E '^(run_id|stage)=' "$STATE/t3.nm-observe"
run "$OBSERVE" bind t3 --accept-daemon-reset
grep -E '^(run_id|stage|daemon_epoch|daemon_reset_observed)=' "$STATE/t3.nm-observe"
run "$OBSERVE" reconcile --now
step "16. preflight refusal keeps the attempt identity and never fabricates a run id"
mktask t4 ship no-mistakes "$WT3"
run "$OBSERVE" launch t4 --profile-json "$TMP/profile-false.json"
grep -E '^(stage|attempt_id|run_id|outcome_class|preflight_refusal)=' "$STATE/t4.nm-observe"
step "17. coverage receipt for t1 (data/<id>/nm-observation-receipt.md)"
run "$OBSERVE" receipt t1
show "$DATA/t1/nm-observation-receipt.md"
step "18. finalize (teardown seam): receipt survives after the runtime record is removed"
setrun 01RUNT1 fm/t1 completed "$S1" success
run "$OBSERVE" finalize t1
rm -f "$STATE/t1.nm-observe"
ls "$DATA/t1/" && grep -E '^(- stage|stage)' "$DATA/t1/nm-observation-receipt.md" || head -12 "$DATA/t1/nm-observation-receipt.md" | redact
step "20. retry chain (NMO-17/NMO-20): a retry never re-attributes a run an earlier attempt already bound"
WT5="$TMP/wt-t5"; mkwt "$WT5" fm/t5; S5=$(git -C "$WT5" rev-parse --short=8 HEAD); mktask t5 ship no-mistakes "$WT5"
run "$OBSERVE" launch t5 --profile-json "$TMP/profile-true.json"
setrun 01RUN5A fm/t5 running "$S5" ""
FM_FAKE_AXI_STATUS=$(toon_cur 01RUN5A fm/t5 running "$S5"; toon_status fm/t5 "$(printf '01RUN5A\tfm/t5\trunning\t%s\t' "$S5")")
run "$OBSERVE" bind t5
setrun 01RUN5A fm/t5 failed "$S5" failed
run "$OBSERVE" refresh t5
echo "attempt 1 is terminal (failed); the operator reruns on the UNCHANGED head: launch opens a linked retry"
FM_FAKE_AXI_STATUS=$(toon_cur 01RUN5A fm/t5 failed "$S5"; toon_status fm/t5 "$(printf '01RUN5A\tfm/t5\tfailed\t%s\t' "$S5")")
run "$OBSERVE" launch t5 --profile-json "$TMP/profile-true.json"
grep -E '^(attempt_seq|predecessor_attempt_id|predecessor_run_id|bound_runs|run_id|stage)=' "$STATE/t5.nm-observe"
echo "the table still lists only RUN5A (same branch, same head) newest: reconcile must NOT call it t5's UNBOUND_RUN (fresh cursor, so a first-pass line would print)"
rm -f "$STATE/.nm-observe-watermark"
echo "(UNENROLLED t1 / INVENTORY_UNAVAILABLE t3 / PREFLIGHT_REFUSED t4 / DAEMON_RESET t2 below are carry-overs of steps 12-18 fixtures, not part of this scenario)"
run "$OBSERVE" reconcile --now
echo "bind without --run and with --run naming the predecessor are both refused"
run "$OBSERVE" bind t5
run "$OBSERVE" bind t5 --run 01RUN5A
echo "worker crashed before creating a run; LAUNCH_GAP heal says relaunch then launch --retry: attempt 3 opens over an attempt that bound nothing"
run "$OBSERVE" launch t5 --retry --profile-json "$TMP/profile-true.json"
grep -E '^(attempt_seq|predecessor_run_id|bound_runs|run_id)=' "$STATE/t5.nm-observe"
rm -f "$STATE/.nm-observe-watermark"
run "$OBSERVE" reconcile --now
run "$OBSERVE" bind t5
run "$OBSERVE" bind t5 --run 01RUN5A
echo "a genuinely newer same-branch run RUN5B appears: it IS the retry's unbound run, and bind attributes it"
setrun 01RUN5B fm/t5 running "$S5" ""
FM_FAKE_AXI_STATUS=$(toon_cur 01RUN5B fm/t5 running "$S5"; toon_status fm/t5 "$(printf '01RUN5B\tfm/t5\trunning\t%s\t\n01RUN5A\tfm/t5\tfailed\t%s\t' "$S5" "$S5")")
rm -f "$STATE/.nm-observe-watermark"
run "$OBSERVE" reconcile --now
run "$OBSERVE" bind t5
grep -E '^(attempt_seq|predecessor_run_id|bound_runs|run_id)=' "$STATE/t5.nm-observe"
step "21. JSON null profile identities (NMO-18): recorded as unset / unobserved, never the string null"
printf '{"record":"fm-tool-profile/v1","profile":{"nm_home":null,"path0":null,"parent":"bash","state":"OBSERVED","detail":""},"tools":[{"state":"QUALIFIED","tool":"no-mistakes","version":null,"bound":"floor=1.46.0","path":"/opt/tools/bin/no-mistakes","required":true,"detail":null}],"unready":[],"ready":true}\n' > "$TMP/profile-null.json"
WT7="$TMP/wt-t7"; mkwt "$WT7" fm/t7; mktask t7 ship no-mistakes "$WT7"
run "$OBSERVE" launch t7 --profile-json "$TMP/profile-null.json"
grep -E '^(nm_home|path0|nm_version|nm_build|profile_ready|daemon_epoch)=' "$STATE/t7.nm-observe"
run "$OBSERVE" receipt t7
printf 'occurrences of the literal word null in the receipt: %s\n' "$(grep -cw null "$DATA/t7/nm-observation-receipt.md")"
grep -E 'NM_HOME|version|daemon' "$DATA/t7/nm-observation-receipt.md" | redact
step "22. teardown seam order (NMO-16): finalize while the merge marker still exists binds the late publication"
# shellcheck disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
fm_pr_poll_merge_mark_notified "$STATE" t2 github github.com example/repo 42 && echo "marker written by its owner: $(sed -n 1p "$STATE/t2.pr-poll-merge-notified")"
run "$OBSERVE" finalize t2
grep -E 'publication|finalized' "$DATA/t2/nm-observation-receipt.md"
echo "contrast: a task whose merge was never marked (t7) finalizes with the publication listed under 'not observed'; once bound, a record keeps its publication"
run "$OBSERVE" finalize t7
grep -E 'publication|a merge' "$DATA/t7/nm-observation-receipt.md"
step "23. negative: every verb the observer ever sent to no-mistakes"
sort -u "$NM_LOG"
