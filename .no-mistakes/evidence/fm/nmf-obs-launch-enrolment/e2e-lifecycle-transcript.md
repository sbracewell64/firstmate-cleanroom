# fm-nm-observe end-to-end transcript (isolated fixtures, fake no-mistakes)

### 1. enrol: obligation exists for a managed ship task; a scout is refused
$ bin/fm-nm-observe.sh enrol t1 --entrypoint spawn 
NM_OBSERVE: ENROLLED task=t1 entrypoint=spawn
[exit 0]
$ bin/fm-nm-observe.sh enrol s1 
NM_OBSERVE: NOT_MANAGED task=s1 kind=scout mode= reason=only kind=ship mode=no-mistakes tasks carry a no-mistakes observation obligation
[exit 1]

### 2. launch: attempt admitted BEFORE the worker is instructed; identity recorded, no run id
$ bin/fm-nm-observe.sh launch t1 --profile-json <tmp>/profile-true.json 
NM_OBSERVE: LAUNCH_ACCEPTED task=t1 attempt=1788752587-b9223043 branch=fm/t1 head=c34ee45a1208 daemon=4242@2026-09-06T00:00:00Z
[exit 0]
$ cat <tmp>/home/state/t1.nm-observe
record=fm-nm-observation/v1
task=t1
home=<tmp>/home
project=<tmp>/wt-t1
repo_remote=unknown
enrolled_epoch=1788752587
entrypoint=firstmate
attempt_id=1788752587-b9223043
attempt_seq=1
predecessor_attempt_id=
predecessor_run_id=
launch_epoch=1788752587
candidate_branch=fm/t1
candidate_head=c34ee45a12089386d1f09887efa9dcafc2600198
nm_home=<tmp>/nm-home
path0=/opt/tools/bin
nm_version=1.61.0
nm_build=0af0be6
profile_ready=true
policy=sha256:fb8dc08e2b0a9e662203c8b262cc6929c08069d262a624a059d21bc507f14145
daemon_epoch=4242@2026-09-06T00:00:00Z
run_id=
run_head=
run_branch=
run_bound_epoch=
run_status=
run_outcome=
outcome_class=
outcome_epoch=
head_change=
superseding_run=
daemon_reset_observed=
stage=launch-accepted
preflight_refusal=

### 3. bind with no run yet: MISSING_BINDING, nothing written
$ bin/fm-nm-observe.sh bind t1 
NM_OBSERVE: MISSING_BINDING task=t1 branch=fm/t1 reason=no run on branch fm/t1 (nothing recorded)
[exit 1]

### 4. worker created the run; bind the ACTUAL run id from axi status
$ bin/fm-nm-observe.sh bind t1 
NM_OBSERVE: RUN_BOUND task=t1 run=01RUNT1 status=running class=active
[exit 0]
$ bin/fm-nm-observe.sh bind t1 
NM_OBSERVE: REFRESHED task=t1 run=01RUNT1 status=running class=active
[exit 0]
attempt_id=1788752587-b9223043
daemon_epoch=4242@2026-09-06T00:00:00Z
stage=run-bound
run_id=01RUNT1
run_status=running
outcome_class=active

### 5. launch again while the bound run is active: identity kept (resume)
$ bin/fm-nm-observe.sh launch t1 --profile-json <tmp>/profile-true.json 
NM_OBSERVE: RUN_BOUND task=t1 attempt=1788752587-b9223043 run=01RUNT1 class=active (a resumed run keeps its identity; pass --retry only for a genuinely new run)
[exit 1]

### 6. refresh: outcome comes only from the canonical record
$ bin/fm-nm-observe.sh refresh t1 
NM_OBSERVE: REFRESHED task=t1 run=01RUNT1 status=completed class=successful
[exit 0]
run_status=completed
run_outcome=success
outcome_class=successful

### 7. first reconcile: pre-existing foreign row becomes BASELINE (uncovered history)
$ bin/fm-nm-observe.sh reconcile --now 
NM_OBSERVE: UNENROLLED task=t2 (managed no-mistakes task with no observation obligation; heal: bin/fm-nm-observe.sh enrol t2)
NM_OBSERVE: UNENROLLED task=t3 (managed no-mistakes task with no observation obligation; heal: bin/fm-nm-observe.sh enrol t3)
NM_OBSERVE: BASELINE runs=1 (pre-existing inventory rows recorded as uncovered history, not adopted)
[exit 0]

### 8. unchanged healthy inventory: silent
$ bin/fm-nm-observe.sh reconcile --now 
[exit 0]

### 9. a new run from another home appears: ORPHAN_RUN once, then quiet
$ bin/fm-nm-observe.sh reconcile --now 
NM_OBSERVE: ORPHAN_RUN run=01FOREIGN branch=fm/other-home status=running head=cafebabe pr=none (no task record in this home owns this branch: another home, a manual launch, or an uncovered entrypoint; explicit coverage gap, not adopted)
[exit 0]
$ bin/fm-nm-observe.sh reconcile --now 
[exit 0]

### 10. crash between run creation and binding: t2 launch-accepted, run exists, never bound -> UNBOUND_RUN
$ bin/fm-nm-observe.sh launch t2 --profile-json <tmp>/profile-true.json 
NM_OBSERVE: LAUNCH_ACCEPTED task=t2 attempt=1788752591-1d6caad1 branch=fm/t2 head=c34ee45a1208 daemon=4242@2026-09-06T00:00:00Z
[exit 0]
watcher seam: reconcile --peek --now prints the finding but does NOT consume it
$ bin/fm-nm-observe.sh reconcile --peek --now 
NM_OBSERVE: UNBOUND_RUN task=t2 run=01RUNT2 status=running head=c34ee45a (run exists for the accepted branch but the obligation holds no run id; heal: bin/fm-nm-observe.sh bind t2 --run 01RUNT2)
[exit 0]
watermark sha before peek=d254452b8554fbaa after peek=d254452b8554fbaa
firstmate on 'check: nm-observe' runs reconcile --now: identical lines, cursor committed
$ bin/fm-nm-observe.sh reconcile --now 
NM_OBSERVE: UNBOUND_RUN task=t2 run=01RUNT2 status=running head=c34ee45a (run exists for the accepted branch but the obligation holds no run id; heal: bin/fm-nm-observe.sh bind t2 --run 01RUNT2)
[exit 0]
watermark sha after --now=e9ff10aaf386964c
$ bin/fm-nm-observe.sh reconcile --now 
[exit 0]

### 11. heal the UNBOUND_RUN: bind t2, then reconcile is quiet
$ bin/fm-nm-observe.sh bind t2 
NM_OBSERVE: RUN_BOUND task=t2 run=01RUNT2 status=running class=active
[exit 0]
$ bin/fm-nm-observe.sh reconcile --now 
[exit 0]

### 12. crash between launch acceptance and run creation: t3 accepted, worker dead, no run -> LAUNCH_GAP
$ bin/fm-nm-observe.sh launch t3 --profile-json <tmp>/profile-true.json 
NM_OBSERVE: LAUNCH_ACCEPTED task=t3 attempt=1788752594-51d910d2 branch=fm/t3 head=c34ee45a1208 daemon=4242@2026-09-06T00:00:00Z
[exit 0]
$ bin/fm-nm-observe.sh reconcile --now 
NM_OBSERVE: LAUNCH_GAP task=t3 attempt=1788752594-51d910d2 age=1s worker=dead (launch accepted, no run created, worker endpoint gone: crash between acceptance and run creation; heal: relaunch through bin/fm-control.sh, then bin/fm-nm-observe.sh launch t3 --retry)
[exit 0]

### 13. the daemon says the bound run is unknown: RUN_VANISHED (not an outage)
$ bin/fm-nm-observe.sh refresh t2 
NM_OBSERVE: RUN_VANISHED task=t2 run=01RUNT2 (the daemon reports this run as not found; recorded class active kept)
[exit 0]

### 14. query failure: INVENTORY_UNAVAILABLE, recorded class kept
$ bin/fm-nm-observe.sh refresh t2 
NM_OBSERVE: INVENTORY_UNAVAILABLE task=t2 run=01RUNT2 reason=query failed or timed out (recorded class active kept)
[exit 0]

### 15. daemon restart under bound runs: refresh/reconcile report DAEMON_RESET; a fresh bind is refused unless accepted
$ bin/fm-nm-observe.sh refresh t2 
NM_OBSERVE: DAEMON_RESET task=t2 recorded=4242@2026-09-06T00:00:00Z observed=5151@2026-09-06T02:00:00Z (outcome read by run id, not rebound)
NM_OBSERVE: REFRESHED task=t2 run=01RUNT2 status=running class=active
[exit 0]
t3's crashed launch is relaunched and its worker now created a run; binding it across the reset is refused
$ bin/fm-nm-observe.sh bind t3 
NM_OBSERVE: DAEMON_RESET task=t3 recorded=4242@2026-09-06T00:00:00Z observed=5151@2026-09-06T02:00:00Z (not rebound; heal: bin/fm-nm-observe.sh bind t3 --accept-daemon-reset)
[exit 1]
run_id=
stage=launch-accepted
$ bin/fm-nm-observe.sh bind t3 --accept-daemon-reset 
NM_OBSERVE: RUN_BOUND task=t3 run=01RUNT3 status=running class=active
[exit 0]
daemon_reset_observed=5151@2026-09-06T02:00:00Z
daemon_epoch=5151@2026-09-06T02:00:00Z
stage=run-bound
run_id=01RUNT3
$ bin/fm-nm-observe.sh reconcile --now 
NM_OBSERVE: DAEMON_RESET task=t1 recorded=4242@2026-09-06T00:00:00Z observed=5151@2026-09-06T02:00:00Z (daemon identity changed under this obligation; nothing was rebound; heal: bin/fm-nm-observe.sh refresh t1)
NM_OBSERVE: DAEMON_RESET task=t2 recorded=4242@2026-09-06T00:00:00Z observed=5151@2026-09-06T02:00:00Z (daemon identity changed under this obligation; nothing was rebound; heal: bin/fm-nm-observe.sh refresh t2)
[exit 0]

### 16. preflight refusal keeps the attempt identity and never fabricates a run id
$ bin/fm-nm-observe.sh launch t4 --profile-json <tmp>/profile-false.json 
NM_OBSERVE: PREFLIGHT_REFUSED task=t4 attempt=1788752598-d72e32cd profile=ENVIRONMENT_UNREADY: no-mistakes ABSENT; owner: install it (no run id exists; repair the environment, then re-run launch)
[exit 1]
attempt_id=1788752598-d72e32cd
run_id=
stage=launch-refused
outcome_class=preflight-refused
preflight_refusal=ENVIRONMENT_UNREADY: no-mistakes ABSENT; owner: install it

### 17. coverage receipt for t1 (data/<id>/nm-observation-receipt.md)
$ bin/fm-nm-observe.sh receipt t1 
<tmp>/home/data/t1/nm-observation-receipt.md
[exit 0]
$ cat <tmp>/home/data/t1/nm-observation-receipt.md
# no-mistakes observation receipt: t1

Rendered 2026-09-07T03:43:19Z by bin/fm-nm-observe.sh from state/t1.nm-observe (fm-nm-observation/v1).
This receipt states what was observed and what was not; it grants nothing and is not a run outcome.

## Identity

- home: <tmp>/home
- project: <tmp>/wt-t1
- repository remote: unknown
- entrypoint: firstmate
- stage: run-bound
- launch attempt: 1788752587-b9223043 (sequence 1, predecessor attempt , predecessor run )
- candidate: branch fm/t1 head c34ee45a12089386d1f09887efa9dcafc2600198
- runtime profile: NM_HOME=<tmp>/nm-home PATH[0]=/opt/tools/bin no-mistakes 1.61.0 build 0af0be6 ready=true
- policy: sha256:fb8dc08e2b0a9e662203c8b262cc6929c08069d262a624a059d21bc507f14145
- daemon epoch at launch: 4242@2026-09-06T00:00:00Z

## Observed

- run 01RUNT1 bound at 1788752588 (branch fm/t1, head c34ee45a)
- canonical status completed outcome success -> class successful (read at 1788752589)

## Not observed

- a PR record
- a merge or publication
- IPC run, step, and CI-readiness events: no owner in this home subscribes to them; every fact above came from a canonical read

## Gaps

- captured eval cases are review evidence, never launch coverage, and are not counted here

### 18. finalize (teardown seam): receipt survives after the runtime record is removed
$ bin/fm-nm-observe.sh finalize t1 
NM_OBSERVE: DAEMON_RESET task=t1 recorded=4242@2026-09-06T00:00:00Z observed=5151@2026-09-06T02:00:00Z (outcome read by run id, not rebound)
NM_OBSERVE: REFRESHED task=t1 run=01RUNT1 status=completed class=successful
NM_OBSERVE: FINALIZED task=t1 receipt=<tmp>/home/data/t1/nm-observation-receipt.md
[exit 0]
nm-observation-receipt.md
- stage: finalized

### 19. negative: every verb the observer ever sent to no-mistakes
axi status
axi status --run 01RUNT1
axi status --run 01RUNT2
