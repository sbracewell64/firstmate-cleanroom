# Programme continuation authority

`bin/fm-continuation-resolve.sh` is the single deterministic owner of what runs next in a pinned programme and under whose authority.
`bin/fm-continuation-lib.sh` owns the vocabulary and every classification table it applies.
This document records the invariant, the canonical inputs, the typed result, the consumer census, and the boundary the owner deliberately does not cross.
The two script headers own exact flags, schema fields, and the law tables; nothing here restates them.

## Invariant

A continuation or stop decision that depends on authority is derived from current typed authority, hold, and proof state for the exact next action and generation.
Historical prose, generic caution, and model inference may not manufacture a captain gate.
The defect this repairs was captain-facing synthesis telling the captain that an already-authorized programme step waited on their word.

## Canonical inputs

The resolver keeps no store of its own and reads three canonical sources.

- The pinned programme file, located through `config/programme` ([`configuration.md`](configuration.md)), carries the ordered sequence, the standing grant and its references, the reserved axes, and each step's typed action facts.
- Proof dispositions under each step's artifact root are read for their outcome only; the highest-numbered attempt directory is the current one, and when it has no readable disposition the step is not terminal and resolves as CNO rather than falling back to an older attempt.
- Accepted owner evidence is the one closed non-proof completion-evidence kind: a step of kind `accepted_owner_evidence` names an owner-produced machine-readable record authored beside the programme, and the resolver binds it by exact programme, step, project, commission, owner, candidate, policy, byte digest, generation, and bound local sources before reading its observed outcome against the step's accept list.
- That adapter returns an observed status and applicability only and grants nothing: a record whose outcome is not accepted (a landing or a self-report without its qualification) leaves the step as the next action under the ordinary law, a missing record is `REQUIRED_BINDING_MISSING` and CNO, an unreadable record or bound source is CNO, and every mismatch, unsupported kind or outcome, superseded record, or recorded contradiction is a refusal that resolves CNO with its exact `OWNER_EVIDENCE_*` reason; none of these ever becomes CAPTAIN.
- The owner kinds and each kind's observed-outcome vocabulary are closed tables in the library, so a record cannot name a command, predicate, plugin, or workflow, and a self-report can never claim a qualification outcome.
- A programme with any owner-evidence step must carry a `binding` object naming the commission, the controlling grant, the consumer contract, and the supported evidence kinds; the resolver verifies it against its own contract and refuses a mismatch at load, and a legacy proof-only programme without one still resolves while every reader prints `REQUIRED_BINDING_MISSING` rather than an optional N/A.
- Durable holds are read through tasks-axi from the same backlog the captain-hold owner writes; a hold binds to an action only through the typed `Continuation-binding:` line that `bin/fm-captain-hold.sh hold --action` or `bind-action` records ([`captain-hold-lifecycle.md`](captain-hold-lifecycle.md)).
- The same backlog carries the captain's recorded answer to a typed step fact: when the fact's decision task (its `decision_key`, else programme-action-axis) is closed with the captain-hold owner's resolution record, or open, newest-recorded as released, and not under a live captain hold, the fact is retired, listed in `basis_refs` as answered, and never materialized again; a plain closure without a record is not an answer.
- Retirement survives later non-captain holds on the decision task: an external wait or a parked hold placed on it gates through the hold path, never re-fires the fact, and `--materialize` never replaces such a hold.
- One identity: a fact is identified everywhere by its own decision task, so coverage by a gating captain hold, answer lookup, and materialization all key on that task; a foreign captain hold that merely shares the axis gates on its own through the hold path but never stands in for the fact, each distinct fact materializes exactly one canonical hold, and the captain answers it through that same task.
- Identity rule: a required fact's durable identity is the task `--materialize` would hold (its `decision_key` when that is a slug, else programme-action-axis), and it is injective over required facts on reserved axes (captain_axes entries and enhancements with `required_to_proceed` true, since a non-reserved fact never owns a task and keeps its typed refusal), so one required fact owns one identity and one durable binding, two required facts resolving to one identity in one step or across steps are refused at load whether keyed or keyless, and a non-required enhancement never becomes a fact or a task and so cannot overwrite, alias, or retire a required fact's binding by reusing its key.
- An answer retires a fact only for the action it was given for: the answered task's own `Continuation-binding:` line must name this action and this programme (or no programme), so an answer bound to another action or programme, or an unbound record such as a legacy fm-decision-hold one, is listed in `basis_refs` as ignored with its reason and the fact still fires.

Control rulings reach the resolver through those stores rather than through a fourth reader: a ruling that changes the sequence or the grant is a programme-file change, and a ruling that opens or closes a wait is a bound hold.
There is no second authority store, no compiled projection, and no reader of report, review, or chat prose.

## Typed result

The result is one JSON object (schema `fm-continuation-resolution/v1`) whose fields the resolver header owns.
Its load-bearing fields are the next action, its action generation, the classification, the authority state, the single reason code, the exact basis references, and the applicability tuple with its digest.
Applicability binds the result to the action, the programme generation, the action generation, the predecessor disposition identity, the current disposition, the gating holds, and the date, so any change to canonical state changes the digest and a stale result cannot be reused.
The `why` field and the `render` output are presentation derived from the typed fields; no renderer can override them.

The classification law itself, including how a bound hold or a step's own typed facts gate an action, is stated once in the library header and applied by the resolver; a CAPTAIN result from a typed step fact is made durable with `resolve --materialize` through the captain-hold owner.
That completes the lifecycle in code: the fact fires CAPTAIN, `--materialize` creates the hold, the captain answers through `bin/fm-captain-hold.sh answer`, and the recorded answer retires the fact without any programme-file edit.

## Material identity and quiet presentation

Every result carries a clock-free `material_identity`: a digest over the programme and binding identities, the next action and its generation, the classification, authority state, reason code, CNO, accountable owner, predecessor, current, and evidence identities, gating holds, answered facts, and materialize axes, with the date and every path excluded.
`bin/fm-programme-presentation-lib.sh` is the single owner of how a presentation caller keys on it: the wake drain presents the programme continuation once when the identity differs from the acknowledged and pending records under `state/`, stays quiet on unchanged polls and restarts, records a pending identity on a turn that prints an acknowledgement command, and `--ack-through` promotes exactly that pending identity without re-resolving, so state that moves between presentation and acknowledgement surfaces again at the next drain.
The session-start digest, fleet snapshot, fleet view, and away-mode digest read the same records and label a result as already presented, pending acknowledgement, or new, and the away digest omits an already-presented token entirely.
The library header owns the record shapes and the contract.

## Consumer census

Every tracked path that can tell firstmate to proceed, wait, escalate, or ask the captain about a programme step consumes the typed result or an explicitly narrower canonical owner.

| Path | Consumption |
|---|---|
| Transition selection | `AGENTS.md` section 7 names the resolver as the owner; the model dispatches the next programme step from its typed result. |
| Session-start projection | `bin/fm-session-start.sh` embeds `render` in the fleet-state digest when a programme is configured and labels its presentation state. |
| Wake presentation | `bin/fm-wake-drain.sh` presents a material change once through `bin/fm-programme-presentation-lib.sh` and acknowledges exactly the presented identity on `--ack-through`. |
| Status projection | `bin/fm-fleet-snapshot.sh` embeds `resolve` verbatim under `programme_continuation` with a `presentation` member; `bin/fm-bearings-snapshot.sh` and `bin/fm-fleet-view.sh` project that field and never derive a programme state from rows. |
| Away continuation | `bin/fm-supervise-daemon.sh` appends the `summary` token to an escalation digest only while its identity is not already presented. |
| Control and ruling consumption | Effects land in the programme file or as bound holds, which the resolver reads; the control-plane consumer itself lives outside this repository and must record its effects through those owners rather than as prose. |
| Report synthesis | `check-prose` refuses captain-facing text that asserts a captain gate while the typed result is not CAPTAIN. |
| Keyed status decisions | `bin/fm-wake-drain.sh`'s OPEN DECISIONS fold is an explicitly narrower owner over crewmate status keys and does not classify programme authority. |
| Captain-hold lifecycle | `bin/fm-captain-hold.sh` remains the durability and effect owner; classification reaches it already typed through the binding and `--materialize`. |
| Projection substrate | `bin/fm-programme-projection.sh` consumes `resolve` verbatim for every authority field and adds only phase, generation, applicability, and delegation members (see below). |

## Boundary

The owner resolves continuation for the existing pinned sequence only.
It carries no phase, delegation, plan-drift, or concurrency machinery, and adds no speculative fields for a later programme-control kernel.
The typed concepts it does carry, the classification and authority enums, the applicability tuple, the reserved-axis policy, and the bound-hold effect law, are the stable seam a later kernel may consume, wrap, or extend.
The one composition layer that does so today is the projection substrate below, and it leaves this owner exactly as narrow.
The owner-evidence adapter is a completion-evidence reader at the resolver's existing seam, not a widening of that boundary: it adds no authority, phase, or delegation semantics, and the projection substrate consumes its steps unchanged.

## The bounded A-F programme candidate

`programmes/cleanroom-af-package/` carries the one bounded A-F programme this repository materializes as a candidate for the home's `config/programme` pin, with its evidence records authored beside it and its README owning the hand-off contract for admission, deployment, and read-back.
The programme binds the controlling captain grant and the completed architecture ruling by source, represents the Proof-B `CNO_AT_B-S9` transition through that ruling's own record bound to the adverse disposition by exact bytes, and binds the landed slices to their forge and pipeline records; a slice whose qualification record is not yet bound resolves as `REQUIRED_BINDING_MISSING`, never as complete.
The historical requalification programme stays where it is as evidence and is named as superseded for this use only.

## Projection substrate

`bin/fm-programme-projection.sh` is a separately qualified composition layer above the resolver, built for a manager loop that reads one typed projection tuple and nothing else.
It recomputes the tuple from canonical records on every call, holds no durable state, writes nothing, and carries no protected-effect authority: it never merges, spawns, holds, transitions, picks a model or effort, or enforces a bound.
Its authority fields (next action, action generation, classification, authority state, reason code, basis references) are the resolver's, consumed verbatim, and its exit 3 for an unconfigured home mirrors the resolver's.
Its own additions are the next action's phase and phase generation, the worker epoch read from the bound task's durable record, an applicability tuple that becomes structurally non-matching on any moved candidate head or tree, new attempt, new worker epoch, or superseded, lifted, or newly gating hold or grant, and the delegation bounds for the next phase.
Delegation is returned, never enforced: `bin/fm-spawn.sh` stays the enforcer, dispatch profiles and quota keep model and effort, hidden fan-out counts under the ceiling, and the substrate reports a measured ladder rung without ever ramping.
Superseded and lifted markers stay on the canonical hold and grant records the resolver already reads, so the substrate has no second store to consult or maintain.
The script header owns the optional programme-file fields it reads (`phase`, `task_id`, and `delegation`), the concurrency ladder, and the result schema.
The resolver stays narrow: the substrate reads the located programme path and artifact root back from the resolver's result instead of re-deriving location precedence, and nothing promotes the resolver into phase, delegation, or concurrency ownership.
A renderer may turn the reason code, basis references, and applicability into prose but may not override the typed tuple, and no path may re-derive these fields from prose.

## Verification

`tests/fm-continuation-lib.test.sh` pins every table in the library.
`tests/fm-continuation-resolve.test.sh` runs the watched-red fixtures against a real tasks-axi backlog and proves the consumer closure above, including the no-pre-existing-hold captain case, the materialized hold, and the refused prose.
The same suite proves the owner-evidence adapter: real accepted A-E records under the grant yield the pilot, a landing or self-report without its qualification cannot, every mismatch and forged receipt is refused CNO, the Proof-B transition is accepted only through the ruling record bound to the exact adverse bytes and outcome, structure and binding defects are refused at load, applicability and material identity move on evidence, grant, and hold changes and ignore the clock, and the wake drain presents once, stays quiet, and acknowledges only the presented identity across the present-then-change-then-ack race.
`tests/fm-programme-projection.test.sh` proves the substrate's authority fields equal the resolver's under every driven classification, that each structural change makes a prior applicability tuple non-matching, that two calls over unchanged state are identical and write nothing, that every backlog access is a read, that delegation bounds are returned without a spawn, that an owner-evidence programme composes unchanged with the pilot's concurrency-2 bound returned and nothing launched, and that a record it cannot compose (an unreadable or nested candidate worktree, duplicate step ids, or an off-ladder ceiling) is refused rather than nulled or selected around.
