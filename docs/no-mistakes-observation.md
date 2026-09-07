# No-mistakes launch observation

`bin/fm-nm-observe.sh` is the single owner of the no-mistakes observation obligation: the durable record that says a managed launch was admitted, which real run it became, what the canonical inventory says about that run, and what was never observed.
Its header owns the exact verbs, flags, record fields, finding classes, cadence, and budgets; nothing here restates them.
This document records the invariant, the entrypoint census with its honest coverage claims, the reconciliation seams, and the boundary the owner deliberately does not cross.

## Invariant

Every managed no-mistakes launch in a home has an observation obligation or an explicit typed gap, and every fact the obligation carries about a run is bound by identity from a canonical record.
A managed launch is a task whose record says `kind=ship` and `mode=no-mistakes`.
The obligation is bound before the launch is admitted, the actual run id is bound only after the daemon created the run, a preflight refusal keeps a launch-attempt identity and never a fabricated run id, a resumed run keeps its identity, and a retry links to its predecessor attempt and run.
The canonical inventory is the daemon's own structured answer (`no-mistakes axi status` and `axi status --run <id>`); narration, activity logs, and the daemon's SQLite are never read.
IPC run, step, and CI-readiness events are refresh hints only, and no owner in this repository subscribes to them today, so every recorded fact comes from a canonical read at a reconciliation moment.
Unchanged state stays quiet: a reconciliation prints a line only for a new or changed finding, and a home that holds neither an obligation nor a managed task record prints nothing and queries nothing.
A home whose only managed tasks carry no obligation reports each of them as `UNENROLLED` without querying the inventory, so an enrolment that failed for the first task in a home is still reported.
A transient inventory outage is reported once as `INVENTORY_UNAVAILABLE` and carries the previous pass's run memory forward, so recovery never re-reports the baseline or an already-reported row.

## Entrypoint census

Each path that starts, resumes, or concludes a no-mistakes run for a task in this repository, with what actually covers it.
COVERED means the obligation is created or advanced by the path's own owner before the run can exist; PENDING means the path is covered only by the reconciliation pass afterwards, so a bypass shows up as a typed gap rather than being prevented; COVERAGE GAP means nothing in this home can observe it beyond the orphan report.

| Entrypoint | Owner | Coverage | How |
|---|---|---|---|
| Fresh ship spawn with `mode=no-mistakes` | `bin/fm-spawn.sh` | COVERED (enrolment) | The spawn enrols the obligation after its final commit and before its deferred-signal exit, with `entrypoint=spawn`, so a spawn interrupted after delivery still enrols the record it preserved; an enrolment failure warns with the exact `enrol` heal and the next reconcile reports the task as `UNENROLLED`, even when it is the only managed task in the home. |
| Scout promotion to a no-mistakes ship | `bin/fm-promote.sh` | COVERED (enrolment) | Promotion enrols after the record flip, with `entrypoint=promote`; an enrolment failure warns with the exact heal and the next reconcile reports `UNENROLLED`. |
| Worker-driven `/no-mistakes` (`no-mistakes axi run --intent`) from the ship brief | the worker, instructed by firstmate | PENDING at admission, reconciled after | Firstmate admits the attempt with `bin/fm-nm-observe.sh launch <id>` before it instructs the worker (AGENTS.md section 7), then binds the run with `bind` once the worker has started it. Nothing in this repository can intercept the worker's own shell, so a worker that starts or reruns a pipeline without that step is caught by reconcile as `UNBOUND_RUN` or `SUPERSEDED_RUN`, never prevented. A wrapper alone would not cover this path either; the census says so rather than claiming it. |
| Relaunch of an existing task (`bin/fm-control.sh relaunch`, `bin/fm-spawn.sh --relaunch`) | `bin/fm-control.sh`, `bin/fm-spawn.sh` | COVERED (identity kept) | The relaunch republishes the task record and never touches the obligation, so a parked run resumed by the replacement keeps its bound run id; a genuinely new run after relaunch is `SUPERSEDED_RUN` until linked with `launch --retry` and `bind`. |
| Retry or repair run on the same branch (`no-mistakes rerun`, a second `axi run`) | the worker | PENDING, reconciled after | Reported as `SUPERSEDED_RUN` with the exact heal; `launch --retry` opens the successor attempt linked to its predecessor. |
| Current-state attribution | `bin/fm-crew-state.sh` via `bin/fm-nm-run-lib.sh` | COVERED (shared rules, no change) | The obligation binds runs under the same branch, head, and pipeline-owned rules the state helper uses, so the two never disagree about which run is the task's. |
| PR ready and merge poll | `bin/fm-pr-check.sh`, `bin/fm-pr-poll.sh` | PENDING, reconciled after | `refresh` and `finalize` bind `pr=` and `pr_head=` from the task record; the PR owners are not changed. |
| Merge outcome publication | `bin/fm-pr-merge.sh`, `bin/fm-merge-outcome-lib.sh` | PENDING, reconciled after | `refresh` records `publication=merged:<provider>:<host>:<path>:<number>` from the PR identity carried by the merge-notification marker `bin/fm-pr-lib.sh` owns; a marker without that identity binds nothing, and the merge owners are not changed. |
| Teardown | `bin/fm-teardown.sh` | COVERED (finalization) | Teardown finalizes the durable receipt before retiring the runtime obligation with the task's other state; the receipt survives in `data/<id>/`. |
| Runs from another home on the shared daemon | none in this home | COVERAGE GAP | The daemon serves every home, so another home's runs appear in this home's inventory; they are reported once as `ORPHAN_RUN` and never adopted. |
| A run on the branch of a task record that is not a managed no-mistakes task (a direct-PR ship, a scout, or a hand-run `no-mistakes` from that worktree) | the task's own worker | COVERAGE GAP | Reported once as `UNMANAGED_RUN` naming the owning task id, kind, and mode: an uncovered entrypoint, never adopted, because only `kind=ship mode=no-mistakes` tasks carry an obligation. |
| Manual `no-mistakes` invocations in a project clone, and the daemon's own nested gate-agent runs | none | COVERAGE GAP | Same `ORPHAN_RUN` report; nothing else can observe them here. |
| Runs that predate adoption | none | COVERAGE GAP (baseline) | The first reconciliation in a home that actually reads the inventory records the existing rows as uncovered history (`BASELINE`), not as observed work. |

## Reconciliation seams

- `bin/fm-session-start.sh` runs `reconcile --startup` on the locked path immediately after the inactive-outcome scan and prints any findings under a labeled line; a read-only session runs nothing.
- Both seams scan every task record, so `UNENROLLED` is raised for a managed task with no obligation even before the home holds its first obligation, while a home with neither stays silent and never queries.
- `bin/fm-watch.sh` runs the non-consuming `reconcile --peek` on every poll beside the inactive-outcome scan; the owner's cadence and budget keep quiet cycles free, the peek never advances the presentation cursor (in a home with no cursor it only creates an empty one to start the cadence clock, leaving the first pass to `--startup` or `--now`), and a printed finding raises `check: nm-observe`, which AGENTS.md section 8 routes to `reconcile --now`, the pass that prints the identical lines, commits the cursor, and names the heals.
- Rows the daemon's repository-wide table serves to several worktrees of one repository are reported once per run id.
- The captured eval corpus (`eval.capture_provenance`, `eval.auto_capture`) is review evidence and is never counted as launch coverage; every receipt says so.

## Records

The obligation lives at `state/<id>.nm-observe` and the receipt at `data/<id>/nm-observation-receipt.md`; `state/.nm-observe-watermark` is the reconciliation's presentation cursor.
[`configuration.md`](configuration.md) routes the home layout, and the script header owns the field inventory and the receipt's sections.

## Boundary

The observer reads and records; it never starts, answers, aborts, syncs, or reruns a pipeline, never approves a gate, never edits a pipeline-owned checkout, never writes under `NM_HOME`, and cannot manufacture an outcome: a recorded class is always replaced by the canonical read on the next refresh.
A daemon identity change is reported and never silently rebound.
The per-run two-level assessment and the lifecycle stage transitions are later increments of the same programme and are not part of this owner.

## Verification

`tests/fm-nm-observe.test.sh` pins the lifecycle and every finding class over isolated fixtures, including the negative proof that only read-only status reads were ever sent.
