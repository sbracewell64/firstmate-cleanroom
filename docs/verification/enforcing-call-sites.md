# Enforcing call sites

Audience: maintainer verification.

An invariant is not active merely because it is documented.
An enforce, validate or refuse capability that no production caller reaches is UNPROVEN, not active.
This record is the dated sweep behind that reading, and [`docs/enforcement-points.json`](../enforcement-points.json) is the machine-readable owner of the per-entry rows.
[`bin/fm-enforcement-caller-check.sh`](../../bin/fm-enforcement-caller-check.sh) validates that inventory, and [`tests/fm-enforcement-callers.test.sh`](../../tests/fm-enforcement-callers.test.sh) is the call site CI schedules.

## What the check proves

The check discovers candidate entry points from the tracked tree with rules it owns, so an inventory edit can narrow neither the discovery nor the accepted kinds.
It discovers four shapes in `bin/`: a script whose name carries an enforce-style word, a top-level dispatch subcommand named with an enforce verb, a long option named with an enforce verb, and a library function whose name carries one.
Every discovered candidate must be declared, so a new rule cannot ship without being accounted for.

A declared `enforced` entry must name at least one call site that exists, sits on the production surface, and actually calls the capability.
The production surface is what a running Firstmate or its automated gates execute: `bin/`, the CI workflows, `.no-mistakes.yaml`, and the registered harness hook files.
`tests/`, `docs/`, and agent skills are not on it.
A test that calls the capability is not evidence that the guarded path reaches it, and the check says so mechanically.
The reference must also be executable: comment lines in a shell caller are stripped before the match, so a header that merely names the capability is not read as a call.

## Why a repository gate may name a test

An entry declared `guards: runtime` guards a live Firstmate operation, and only a production-surface caller counts for it.
An entry declared `guards: repository` guards a property of the repository itself, where the guarded path is a change landing and the CI suite walk is the production path.
For those, and only those, a `ci-suite` call site is accepted, and the check proves the chain rather than assuming it: the named script must be a `tests/*.test.sh` that calls the capability, and `bin/fm-test-run.sh` must itself schedule that script into a CI lane.
A test that exists but no lane runs is refused with the same force as no caller at all.
This is not a relaxation of the rule for runtime invariants: a `ci-suite` call site declared on a `guards: runtime` entry is refused outright.

## Honest bounds

The check proves a production call site, not full reachability from an executable entry point.
A library function called only from another unreached function in the same library still counts, so the `note` field records which executable traverses it.
Discovery is name-shaped, so a capability whose name carries none of the enforce words is found only when it is declared by hand; the two known-good references below are declared that way.
`data/` is captain-private and untracked, so a rule that lives only in `data/learnings.md` cannot be gated by a repository check at all.

## Sweep of 2026-09-14

The check accounts for 31 entry points: 26 enforced, 4 operator-invoked, and 1 that is not an enforcement point.
It verifies 57 declared call sites.

The executable-reference rule changed the reading of eight call sites that a plain text match had accepted.
`bin/fm-watch-arm.sh`, `bin/fm-subagent-pretool-check.sh`, `bin/fm-procevent-when.sh`, `bin/fm-check-register.sh`, `bin/fm-watch.sh`, `bin/fm-teardown.sh`, `bin/fm-claude-stop-autoarm.sh`, and `bin/fm-turnend-guard.sh` each name a capability in a header comment without calling it.
Seven of those entry points keep other real callers.
The eighth, `bin/fm-check-unregister.sh`, turned out to have none at all.

### Known-good references, confirmed

Both already-repaired instances of this family still name their production callers, and `tests/fm-enforcement-callers.test.sh` asserts each by name.

| Entry point | Enforcing call site | Repair |
| --- | --- | --- |
| `bin/fm-startup-memory-budget.sh:enforce` | `bin/fm-session-start.sh` | PR 46, merge `0e826aa` |
| `bin/fm-outbound-write-lib.sh:fm_outbound_send` | `bin/fm-send.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-x-reply.sh`, `bin/fm-x-dismiss.sh` | PR 47, merge `0a519ea` |

### Entries that are not automatically called

Four discovered capabilities have no automatic caller, and each is declared `operator-invoked` with the reason and the prose owner that invokes it.
None of them is the family's failure shape, because in each case the invariant itself is enforced elsewhere or the entry point is a human-initiated procedure.

| Entry point | Reading | Why |
| --- | --- | --- |
| `bin/fm-home-seed.sh:validate` | ACTIVE at the write boundary | The same `validate_registry` predicate runs inside the transactional seed path; this subcommand is a standalone re-check. |
| `bin/fm-decision-hold.sh:verify` | ACTIVE through its surviving owner | A one-release compatibility shim over `bin/fm-captain-hold.sh:verify`, which carries the production call site. |
| `bin/fm-render-launcher.sh:--require-complete-config` | ACTIVE as an operator opt-in | A strictness flag on a captain-authorized launcher cutover that no script schedules. |
| `bin/fm-check-unregister.sh` | ACTIVE as the command `AGENTS.md` names | No script calls it: `bin/fm-teardown.sh` removes a spawned task's check artifacts on its own path, so this is the retirement command for a check registered by hand. |

`bin/fm-tool-update-check.sh` is declared as not an enforcement point: it reports a wake line and refuses nothing, and was discovered only because its name carries the word check.

### Observation, not repaired in this slice

`bin/fm-home-seed.sh:validate` is the one entry whose reach could be widened: nothing re-validates `data/secondmates.md` after a hand edit, so a registry corrupted outside the seed path is found at its next consumer rather than at session start.
That would wire a new call into `bin/fm-session-start.sh`, which a concurrent lane owns, so it is recorded here rather than done.

### Documented invariants with no named owner

The prose side was swept over `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, and every file under `docs/`, looking for sections that assert mechanical enforcement (`refuses`, `fails closed`, `enforces`) while naming no owning script or workflow anywhere in the section.
Twenty-seven sections matched that section-local shape, and each names its owner at the document level instead: `docs/subagent-guard.md` over `bin/fm-subagent-pretool-check.sh`, `docs/configuration.md`'s away-mode backend section over `bin/fm-supervise-daemon.sh`, `docs/extension-bindings.md` over the registered Pi extension, and so on.
`AGENTS.md`'s own mechanical claims were checked individually and each resolves to enforcing code: the explicit-home refusal in `bin/fm-send.sh`, the commit-identity refusal reached from `bin/fm-pr-check.sh`, the delivery-contract and backlog-gate refusals in `bin/fm-spawn.sh`, the completion gate `bin/fm-teardown.sh` reaches through `bin/fm-captain-hold.sh:verify`, and the worktree-isolation refusal in `bin/fm-spawn.sh` paired with the assertion `bin/fm-brief.sh` writes into every ship brief.
No tracked prose invariant was left UNPROVEN by this sweep.

The one prose instance of this family that did exist, the outbound-write discipline, lived in the untracked private `data/learnings.md` rather than in tracked prose, which is why no repository check could have caught it.
Its repair moved the rule into `bin/fm-outbound-write-lib.sh`, where this check now holds it.

## Adding an entry point

Add the capability, wire its enforcing call, then declare it in `docs/enforcement-points.json` with its `id`, `kind`, one-sentence `invariant`, `guards`, and `callSites`.
Run `bin/fm-enforcement-caller-check.sh`; an undeclared or unreachable capability is named in the failure.
