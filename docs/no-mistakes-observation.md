# No-mistakes launch observation

`bin/fm-nm-observe.sh` is the single owner of the no-mistakes observation obligation: the durable record that says a managed launch was admitted, which real run it became, what the canonical inventory says about that run, and what was never observed.
`bin/fm-nm-assess.sh` is the single owner of the continual per-run two-level assessment that sits on top of that obligation: at each material transition it records the immediate boundary and the one owner level above it, deduplicates findings into families, routes each finding to its existing owner, classifies provider-capacity as a typed external condition, reconciles a late merge against provider/canonical state, and mechanically enforces coverage.
Each script's header owns its exact verbs, flags, record fields, finding classes, cadence, and budgets; nothing here restates them.
This document records the invariant, the entrypoint census with its honest coverage claims, the reconciliation seams, the assessment invariant, and the boundary the owners deliberately do not cross.

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
| Worker-driven `/no-mistakes` (`no-mistakes axi run --intent`) from the ship brief | the worker, through `bin/fm-stage.sh` | COVERED at admission (stage command), reconciled after | The worker's `committed` stage command admits the attempt with `launch` (entrypoint `stage`) before it is told to start the pipeline, and its `running` stage command binds the run with `bind` as soon as the run exists, so the obligation and the stage receipt carry the same attempt and run identity. Nothing in this repository can intercept the worker's own shell, so a worker that starts or reruns a pipeline without those commands is still caught by reconcile as `UNBOUND_RUN` or `SUPERSEDED_RUN`, never prevented; the census says so rather than claiming it. |
| Relaunch of an existing task (`bin/fm-control.sh relaunch`, `bin/fm-spawn.sh --relaunch`) | `bin/fm-control.sh`, `bin/fm-spawn.sh` | COVERED (identity kept) | The relaunch republishes the task record and never touches the obligation, so a parked run resumed by the replacement keeps its bound run id; a genuinely new run after relaunch is `SUPERSEDED_RUN` until linked with `launch --retry` and `bind`. |
| Retry or repair run on the same branch (`no-mistakes rerun`, a second `axi run`) | the worker | PENDING, reconciled after | Reported as `SUPERSEDED_RUN` with the exact heal; `launch --retry` opens the successor attempt linked to its predecessor. |
| Current-state attribution | `bin/fm-crew-state.sh` via `bin/fm-nm-run-lib.sh` | COVERED (shared rules, no change) | The obligation binds runs under the same branch, head, and pipeline-owned rules the state helper uses, so the two never disagree about which run is the task's. |
| PR ready and merge poll | `bin/fm-pr-check.sh`, `bin/fm-pr-poll.sh` | PENDING, reconciled after | `refresh` and `finalize` bind `pr=` and `pr_head=` from the task record; the PR owners are not changed. |
| Merge outcome publication | `bin/fm-pr-merge.sh`, `bin/fm-merge-outcome-lib.sh` | PENDING, reconciled after | `refresh` records `publication=merged:<provider>:<host>:<path>:<number>` from the PR identity carried by the merge-notification marker `bin/fm-pr-lib.sh` owns; a marker without that identity binds nothing, and the merge owners are not changed. |
| Teardown | `bin/fm-teardown.sh` | COVERED (finalization) | Teardown finalizes the durable receipt (which also produces the terminal assessment) before retiring the runtime obligation and assessment records with the task's other state; both the observation and assessment receipts survive in `data/<id>/`. |
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

## Assessment

Every applicable run receives a durable per-run assessment at each material transition (stall or failure, CI-ready, terminal outcome, and a later terminal or head revision), carrying two levels: the immediate boundary (the exact run, candidate, gate and head state, the actual defect or blocked condition, what executed versus what never started, the carried residual finding identity, and the next exact owner and gate) and the one owner level above it (the caller, lifecycle, owner or shared contract that allowed it, the sibling consumers checked, or "no anomaly within measured coverage").
The assessment consumes the obligation's identity envelope and canonical facts; it never parses narration and never infers success from a zero exit.
Findings are deduplicated into families keyed by owner plus violated invariant plus failure family plus contract or profile applicability, and a later occurrence attaches to its family without losing earlier occurrence history.
Occurrence identity includes the candidate head, so the same task, run, and transition at a distinct head revision is a new occurrence that preserves the earlier head's line rather than overwriting it, and occurrence history is immutable across head revisions.
An ordinary refresh preserves the carried residual finding, the provider-capacity block, and every recorded finding family; only a typed owner action (a supersede that names the family, the carried residual, or a returned provider-capacity block) closes any of them, so a refresh never silently clears carried state.
CI-ready is claimed only with source-applicable evidence that CI actually completed (a checks-passed canonical verdict); it is never inferred from an absent, empty, or merely normalized state, and without that evidence the transition is reported ci-ready-unverified with a routed check-normalization finding.
Coverage counts as performed only when a canonical read actually ran or findings were ingested or carried; recording that an assessment exists is not an investigation, so the bare existence-recording hook path is disposed coverage-unperformed rather than a manufactured clean verdict.
A malformed disposition or a malformed freshness epoch (--now) is refused typed and non-zero before it can reach a record, coverage, or a wrong age, never exiting 0 with an arithmetic error.
Each finding is routed to its existing owner: a provider-capacity finding to `nmf-provider-capacity-typed-condition` (the pinned-tool root fix is upstream, and the observer only observes, classifies, and routes it, never repairs pinned no-mistakes internals), a check-normalization finding to `nmf-observer-check-normalization`, and any other bounded defect to the owner it names or a bounded owner task to be filed.
Provider-capacity is a typed external resource-blocked condition, distinct from a candidate repair: real invocation attempts are preserved as invoked-but-no-completed-repair, usage and cost stay UNKNOWN rather than fabricated to zero, the affected gate is paused while independent eligible work continues, and its budget is separate from candidate repair-attempt budgets.
A late merge is reconciled against the merge-notification marker (provider and canonical state) rather than a run record whose cached pr can still read OPEN after the merge landed.
Coverage is mechanically enforced: every admitted launch has an observation or an explicit pending or error state, every assessment has one of the five defined dispositions, and every remediation family has an owner and a next gate.
The existing observation owner produces the assessment at its own `bind` and `refresh` transitions (`assess_hook`); this is the closure wiring only and does not activate in the running primary until that primary adopts this code root, which is a separate decision.

## Records

The obligation lives at `state/<id>.nm-observe` and its receipt at `data/<id>/nm-observation-receipt.md`; `state/.nm-observe-watermark` is the reconciliation's presentation cursor.
The assessment lives at `state/<id>.nm-assessment` and its receipt at `data/<id>/nm-assessment-receipt.md`; finding families live under `data/nm-finding-families/`, one durable file per family with append-only occurrence lines.
[`configuration.md`](configuration.md) routes the home layout, and each script header owns its field inventory and the receipt's sections.

## Boundary

The observer reads and records; it never starts, answers, aborts, syncs, or reruns a pipeline, never approves a gate, never edits a pipeline-owned checkout, never writes under `NM_HOME`, and cannot manufacture an outcome: a recorded class is always replaced by the canonical read on the next refresh.
A daemon identity change is reported and never silently rebound.
The lifecycle stage transitions belong to `bin/fm-stage.sh`, which calls the obligation owner's `launch`, `bind`, and `refresh` and never writes the obligation itself.
The assessment owner keeps the same boundary: it reads the obligation and never writes it, sends only the read-only `axi status` reads, never repairs pinned no-mistakes internals, and its disposition is one of five defined values that is never a gate verdict, so it cannot manufacture a PASS or a merge.

## Verification

`tests/fm-nm-observe.test.sh` pins the obligation lifecycle and every finding class over isolated fixtures, including the negative proof that only read-only status reads were ever sent.
`tests/fm-nm-assess.test.sh` pins the two-level assessment over isolated fixtures: both levels and the identity envelope, provider-capacity as a typed, paused, budget-separate condition with unknown cost, finding-family dedup that attaches occurrences without loss, late-merge reconciliation of a cached-open pr against the canonical merge marker, coverage enforcement of the three invariants, and the negative proof that no mutating verb is sent and no PASS is manufactured.
It also pins the qualification-hardening invariants, each as a regression that fails if the fix is removed plus a positive control: a refresh preserves carried and provider findings (closed only by a typed supersede), a carried residual survives refresh and terminal completion by identity, ci-ready requires a checks-passed verdict, a malformed disposition and a malformed --now epoch are refused typed and non-zero, occurrence history is immutable across head revisions, and the bare hook path is disposed coverage-unperformed rather than a manufactured clean verdict.
