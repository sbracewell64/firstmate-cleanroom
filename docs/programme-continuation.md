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
- Proof dispositions under each step's artifact root are read for their outcome only; the highest-numbered attempt is the current one.
- Durable holds are read through tasks-axi from the same backlog the captain-hold owner writes; a hold binds to an action only through the typed `Continuation-binding:` line that `bin/fm-captain-hold.sh hold --action` or `bind-action` records ([`captain-hold-lifecycle.md`](captain-hold-lifecycle.md)).
- The same backlog carries the captain's recorded answer to a typed step fact: when the fact's decision task (its `decision_key`, else programme-action-axis) is closed with the captain-hold owner's resolution record, or open, unheld, and newest-recorded as released, the fact is retired, listed in `basis_refs` as answered, and never materialized again; a plain closure without a record is not an answer.

Control rulings reach the resolver through those stores rather than through a fourth reader: a ruling that changes the sequence or the grant is a programme-file change, and a ruling that opens or closes a wait is a bound hold.
There is no second authority store, no compiled projection, and no reader of report, review, or chat prose.

## Typed result

The result is one JSON object (schema `fm-continuation-resolution/v1`) whose fields the resolver header owns.
Its load-bearing fields are the next action, its action generation, the classification, the authority state, the single reason code, the exact basis references, and the applicability tuple with its digest.
Applicability binds the result to the action, the programme generation, the action generation, the predecessor disposition identity, the current disposition, the gating holds, and the date, so any change to canonical state changes the digest and a stale result cannot be reused.
The `why` field and the `render` output are presentation derived from the typed fields; no renderer can override them.

The classification law itself, including how a bound hold or a step's own typed facts gate an action, is stated once in the library header and applied by the resolver; a CAPTAIN result from a typed step fact is made durable with `resolve --materialize` through the captain-hold owner.
That completes the lifecycle in code: the fact fires CAPTAIN, `--materialize` creates the hold, the captain answers through `bin/fm-captain-hold.sh answer`, and the recorded answer retires the fact without any programme-file edit.

## Consumer census

Every tracked path that can tell firstmate to proceed, wait, escalate, or ask the captain about a programme step consumes the typed result or an explicitly narrower canonical owner.

| Path | Consumption |
|---|---|
| Transition selection | `AGENTS.md` section 7 names the resolver as the owner; the model dispatches the next programme step from its typed result. |
| Session-start projection | `bin/fm-session-start.sh` embeds `render` in the fleet-state digest when a programme is configured. |
| Status projection | `bin/fm-fleet-snapshot.sh` embeds `resolve` verbatim under `programme_continuation`; `bin/fm-bearings-snapshot.sh` and `bin/fm-fleet-view.sh` project that field and never derive a programme state from rows. |
| Away continuation | `bin/fm-supervise-daemon.sh` appends the `summary` token to every escalation digest. |
| Control and ruling consumption | Effects land in the programme file or as bound holds, which the resolver reads; the control-plane consumer itself lives outside this repository and must record its effects through those owners rather than as prose. |
| Report synthesis | `check-prose` refuses captain-facing text that asserts a captain gate while the typed result is not CAPTAIN. |
| Keyed status decisions | `bin/fm-wake-drain.sh`'s OPEN DECISIONS fold is an explicitly narrower owner over crewmate status keys and does not classify programme authority. |
| Captain-hold lifecycle | `bin/fm-captain-hold.sh` remains the durability and effect owner; classification reaches it already typed through the binding and `--materialize`. |

## Boundary

The owner resolves continuation for the existing pinned sequence only.
It carries no phase, delegation, plan-drift, or concurrency machinery, and adds no speculative fields for a later programme-control kernel.
The typed concepts it does carry, the classification and authority enums, the applicability tuple, the reserved-axis policy, and the bound-hold effect law, are the stable seam a later kernel may consume, wrap, or extend.

## Verification

`tests/fm-continuation-lib.test.sh` pins every table in the library.
`tests/fm-continuation-resolve.test.sh` runs the watched-red fixtures against a real tasks-axi backlog and proves the consumer closure above, including the no-pre-existing-hold captain case, the materialized hold, and the refused prose.
