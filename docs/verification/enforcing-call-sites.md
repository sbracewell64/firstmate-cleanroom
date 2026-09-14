# Enforcing call sites

Audience: maintainer verification.

An invariant is not active merely because it is documented.
An enforce, validate or refuse capability that no production caller reaches is UNPROVEN, not active.
This record is the dated sweep behind that reading, and [`docs/enforcement-points.json`](../enforcement-points.json) is the machine-readable owner of the per-entry rows.
[`bin/fm-enforcement-caller-check.sh`](../../bin/fm-enforcement-caller-check.sh) validates that inventory, and [`tests/fm-enforcement-callers.test.sh`](../../tests/fm-enforcement-callers.test.sh) is the call site CI schedules.

## What the check proves

The check discovers candidate entry points from the tracked tree with rules it owns, so an inventory edit can narrow neither the discovery nor the accepted kinds.
It discovers four shapes in `bin/`: a script whose name carries an enforce-style word, a dispatch subcommand named with an enforce verb, a long option named with an enforce verb, and a function whose name carries one.
A dispatcher is a `case` on the script's own argument stream, which means `$1` itself or a variable the same file assigned directly from `$1`, wherever that `case` appears; an unrelated internal `case` is deliberately not harvested.
A long option is discovered on every alternative of an alias group, so `--enforce|--enforce-all)` accounts for both.
A function is discovered in any tracked `bin/` script or backend adapter, not only in a `*-lib.sh`.
In a sourced library, which means a `bin/` script another tracked script brings in with `.` or `source`, every enforce-verb function is discovered whatever it is named, because a library's functions are its entry points.
In a script that is only executed, discovery is limited to the `fm_`-prefixed functions; the bound below records why.
Every discovered candidate must be declared, so a new rule cannot ship without being accounted for.

A declared `enforced` entry must name at least one call site that exists, sits on the production surface, and actually calls the capability.
The production surface is what a running Firstmate or its automated gates execute: `bin/`, the CI workflows, `.no-mistakes.yaml`, and the registered harness hook files.
`tests/`, `docs/`, and agent skills are not on it.
A test that calls the capability is not evidence that the guarded path reaches it, and the check says so mechanically.
The reference must also be executable, because a matcher that reads a capability name in text as a caller reports enforcement where none exists - the exact defect this check is for.
Comments are stripped per language before the match: `#` line comments in `.sh`, `.yaml` and `.yml` callers, and `//` line comments and `/* */` blocks in `.mjs`, `.js` and `.ts` callers.
JSON has no comment syntax, so a hook registration is matched as written.
Emitted operator text is stripped too: in a shell caller, heredoc bodies and the argument text of `printf`, `echo` and `cat` are dropped.
Command substitutions inside that text survive, so a genuine call on the other side of a pipe - `printf %s "$payload" | bin/fm-turnend-guard.sh --cursor` - still counts as enforcement.

One binding rule covers all four axes, so no axis is quietly weaker than the others: the capability's name must stand in COMMAND POSITION of an actual command, and for a subcommand or long option the token must follow it in that same command.
The site's text is read as logical lines, with a backslash continuation joined only on an odd number of trailing backslashes because an even count is escaped backslashes that end the command, and each line is split into command segments at its unquoted control operators.
A bare mention, an existence test such as `[ -x "$dir/fm-x.sh" ]`, and a path assigned but never run are therefore not call sites.
Every production surface is read the same way: a shell caller executes its own lines, and every other surface carries its commands inside literals, so a hook `command` field, a YAML `run:` step and a template literal handed to a process spawner are each read as a command string.
The indirections the repository really uses are followed rather than refused: a command substitution, a leading environment assignment, a variable holding the script's path, a command string assigned to a variable, and a command string handed to a nested shell or to `trap`.
The token has to follow the script in one of those segments, so a caller that runs the script with a different subcommand and separately uses the capability's word in a neighbouring command is not evidence.
Two indirections the repository really uses are resolved rather than refused: a variable holding the script's path, as `bin/enter-firstmate.sh` does with `TOOL_PROFILE_OWNER`, and an argument list built with `set --` that the invocation forwards as `"$@"`, as `bin/fm-nm-observe.sh` does for `bin/fm-tool-profile.sh --require`.

A function call site must also have the library in scope: the site is the defining library itself, or a file that sources it directly or through a chain of sourced libraries.
Without that link a bare name proves nothing, because two files can define independent functions of the same name, and the repository already contains such homonyms.

An entry may also record `rejectedCallSites`: a path that names the capability only in comment or emitted text, with the reason.
The check asserts each one is still named by the file and still rejected by the matcher, so weakening the executable-reference rule fails loudly against a real production file rather than silently inflating the verified count.

## Why a repository gate may name a test

An entry declared `guards: runtime` guards a live Firstmate operation, and only a production-surface caller counts for it.
An entry declared `guards: repository` guards a property of the repository itself, where the guarded path is a change landing and the CI suite walk is the production path.
For those, and only those, a `ci-suite` call site is accepted, and the check proves the chain rather than assuming it: the named script must be a `tests/*.test.sh` that calls the capability, and `bin/fm-test-run.sh` must itself schedule that script into a CI lane.
A test that exists but no lane runs is refused with the same force as no caller at all.
This is not a relaxation of the rule for runtime invariants: a `ci-suite` call site declared on a `guards: runtime` entry is refused outright.

## Honest bounds

Command position is decided textually, not by a shell parse, so four residues remain.
A token that follows the script anywhere in the same command counts even when it is not an argument, so `fm-startup-memory-budget.sh report > "$dir/enforce.log"` would still read as the `enforce` call; the shape now rejected is the same script invoked as `report` with a bare `enforce` word in a neighbouring command, which used to pass on proximity alone.
The `set --` accommodation is file-wide: any `set --` line carrying the token, plus any invocation of that script forwarding `"$@"`, are bound without proving they are the same argument list.
The variable-path accommodation is file-wide in the same way: a variable assigned the script's path anywhere in the file makes every later command naming that variable an invocation candidate.
Reading every literal on a non-shell surface as a command string is deliberately generous: a literal that merely begins with the script's path counts even where the surrounding code never executes it.

The check proves that a production call site exists, NOT that the caller consumes the callee's verdict.
A caller that invokes the capability and then discards its exit status still counts as a call site, so an advisory reporter can look identical to a refusal from where this check stands.
`bin/fm-guard.sh` is the worked example: it always exits 0, so no caller can refuse on it, which the sweep below records.
Extending the check to detect a discarded verdict is a candidate follow-up, recorded here as an observation rather than attempted in this slice.

The check proves a production call site, not full reachability from an executable entry point.
A function called only from another unreached function in the same file still counts, so the `note` field records which executable traverses it.
A function defined inside a script that is only executed, never sourced, is discovered only when its name carries the `fm_` prefix.
That is deliberate, and the measurement is the reason: 78 tracked functions in `bin/` carry an enforce verb without that prefix, 4 of them live in sourced libraries and are now discovered, and the other 74 are defined inside scripts that are only executed.
Those 74 are script-internal helpers: nothing outside the defining script can call them, so the script's own surface, which discovery already accounts for by name, subcommand and flag, is the entry point a caller can reach.
Reporting all 74 separately would bury the entry points that matter and train a reader to mute the check, which conceals as effectively as no check at all.
Discovery also reads only `bin/*.sh` and `bin/backends/*.sh`, so a `bin/*.mjs` decider such as `bin/fm-cd-command-policy.mjs`, `bin/fm-arm-command-policy.mjs` or `bin/fm-extension-launch-barrier.mjs` can be counted as a caller but can never be discovered as an entry point of its own.
Discovery is name-shaped, so a capability whose name carries none of the enforce words is found only when it is declared by hand; `bin/fm-outbound-write-lib.sh:fm_outbound_send` is declared that way.
The same name shape is what makes a namespace prefix look like a verb: `bin/fm-guard.sh`'s `fm_guard_*` banner helpers are discovered and then declared as not enforcement points, which keeps the account explicit rather than special-casing the prefix in discovery.
`data/` is captain-private and untracked, so a rule that lives only in `data/learnings.md` cannot be gated by a repository check at all.

## Sweep of 2026-09-14

The check accounts for 50 entry points: 39 enforced, 4 operator-invoked, and 7 that are not enforcement points.
It verifies 75 declared call sites and re-rejects 5 recorded near misses.

The most significant finding is `bin/fm-guard.sh`.
It had been declared `enforced` over the invariant that a fleet mutation runs only from a session holding the verified per-home lock and an untangled checkout, and it cannot hold that.
Its only top-level exits are the `exit 0` statements at lines 167 and 242, and its own header states that it warns and never blocks, so no invocation can act on a failing status and a mutation from a tangled checkout prints the banner and then proceeds.
Most `bin/` callers underline that by invoking it as `|| true`, and the one that does not, `bin/fm-session-start.sh`, captures its output in a command substitution rather than acting on its status.
It is now declared as not an enforcement point, with the invariant restated as what it does guarantee, which is that the condition is announced.
This sweep did NOT establish whether a narrower owner enforces the per-home session lock at some other boundary; that question is recorded as not observed rather than answered in either direction.

The executable-reference rule changed the reading of thirteen references that a plain text match had accepted.
Eight are shell header comments: `bin/fm-watch-arm.sh`, `bin/fm-subagent-pretool-check.sh`, `bin/fm-procevent-when.sh`, `bin/fm-check-register.sh`, `bin/fm-watch.sh`, `bin/fm-teardown.sh`, `bin/fm-claude-stop-autoarm.sh`, and `bin/fm-turnend-guard.sh` each name a capability without calling it.
Seven of those entry points keep other real callers; the eighth, `bin/fm-check-unregister.sh`, turned out to have none at all.

The remaining five had been declared as verified call sites and are now recorded as `rejectedCallSites`, so the sweep's own finds became a permanent self-test on real files.
`bin/fm-stage.sh` and `bin/fm-branch-prompt.sh` name `bin/fm-pr-check.sh` in emitted operator text, and `bin/fm-supervision-instructions.sh` names `bin/fm-turnend-guard-cursor.sh` the same way.
`bin/fm-cd-command-policy.mjs` names `bin/fm-cd-pretool-check.sh` in a `//` comment, and `.no-mistakes.yaml` names `bin/fm-lint-workflows.sh` in a `#` comment.
Each of those entry points keeps a genuine caller, so no entry's reading changed from ACTIVE to UNPROVEN; what changed is that the inventory now says where enforcement actually happens.

### Known-good references, confirmed

Both already-repaired instances of this family still name their production callers, and `tests/fm-enforcement-callers.test.sh` asserts each by name.
That assertion is proven rather than trusted: the same predicate is run against copies of the inventory with each named caller removed, and both copies must be rejected.

| Entry point | Enforcing call site | Repair |
| --- | --- | --- |
| `bin/fm-startup-memory-budget.sh:enforce` | `bin/fm-session-start.sh` | PR 46, merge `0e826aa` |
| `bin/fm-outbound-write-lib.sh:fm_outbound_send` | `bin/fm-send.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-x-reply.sh`, `bin/fm-x-dismiss.sh` | PR 47, merge `0a519ea` |

### Entries that are not automatically called

Four discovered capabilities have no automatic caller, and each is declared `operator-invoked` with the reason and the prose owner that invokes it.
Widening discovery added no new instance of this shape: every newly discovered capability has a production caller, and the ones that are not enforcement points are declared as such.
None of them is the family's failure shape, because in each case the invariant itself is enforced elsewhere or the entry point is a human-initiated procedure.

| Entry point | Reading | Why |
| --- | --- | --- |
| `bin/fm-home-seed.sh:validate` | ACTIVE at the write boundary | The same `validate_registry` predicate runs inside the transactional seed path; this subcommand is a standalone re-check. |
| `bin/fm-decision-hold.sh:verify` | ACTIVE through its surviving owner | A one-release compatibility shim over `bin/fm-captain-hold.sh:verify`, which carries the production call site. |
| `bin/fm-render-launcher.sh:--require-complete-config` | ACTIVE as an operator opt-in | A strictness flag on a captain-authorized launcher cutover that no script schedules. |
| `bin/fm-check-unregister.sh` | ACTIVE as the command `AGENTS.md` names | No script calls it: `bin/fm-teardown.sh` removes a spawned task's check artifacts on its own path, so this is the retirement command for a check registered by hand. |

`bin/fm-tool-update-check.sh` is declared as not an enforcement point: it reports a wake line and refuses nothing, and was discovered only because its name carries the word check.
The four `fm_guard_*` helpers in `bin/fm-guard.sh` are declared the same way: they decide how loudly the watcher-down banner prints and never change whether a fleet mutation is allowed.
`bin/fm-guard.sh` itself is declared the same way for the same reason, as recorded above.
`bin/fm-wake-lib.sh:_fm_wake_require_classify` is declared the same way as well: `require` there means module import, and the function sources `bin/fm-classify-lib.sh` on demand rather than rejecting anything.

### Observation, not repaired in this slice

`bin/fm-home-seed.sh:validate` is the one entry whose reach could be widened: nothing re-validates `data/secondmates.md` after a hand edit, so a registry corrupted outside the seed path is found at its next consumer rather than at session start.
That would wire a new call into `bin/fm-session-start.sh`, which a concurrent lane owns, so it is recorded here rather than done.

### Documented invariants with no named owner

The prose side was swept over `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, and every file under `docs/`, looking for sections that assert mechanical enforcement (`refuses`, `fails closed`, `enforces`) while naming no owning script or workflow anywhere in the section.
Twenty-seven sections matched that section-local shape, and each names its owner at the document level instead: `docs/subagent-guard.md` over `bin/fm-subagent-pretool-check.sh`, `docs/configuration.md`'s away-mode backend section over `bin/fm-supervise-daemon.sh`, `docs/extension-bindings.md` over the registered Pi extension, and so on.
`AGENTS.md`'s own mechanical claims were checked individually and each resolves to enforcing code: the explicit-home refusal in `bin/fm-send.sh`, the commit-identity refusal reached from `bin/fm-pr-check.sh`, the delivery-contract and backlog-gate refusals in `bin/fm-spawn.sh`, the completion gate `bin/fm-teardown.sh` reaches through `bin/fm-captain-hold.sh:verify`, and the worktree-isolation refusal in `bin/fm-spawn.sh` paired with the assertion `bin/fm-brief.sh` writes into every ship brief.
By that criterion, no section asserting mechanical enforcement failed to name an owning script or workflow at document level.

That criterion is narrower than the governing principle, and one tracked prose invariant does not survive the principle.
`AGENTS.md` states that a session which cannot acquire and verify the session lock must remain read-only and must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or perform any other fleet mutation.
`bin/fm-guard.sh` was the shared call site every one of those commands traverses, and this sweep reclassified it away from that invariant because it always exits 0 and every caller discards its status.
This sweep did NOT establish whether a narrower owner enforces the lock at another boundary, so the per-home session lock is recorded as UNPROVEN here rather than claimed to be unenforced.
Reading it as ACTIVE because the rule is well known is exactly the softening the governing principle forbids.

The one prose instance of this family that did exist, the outbound-write discipline, lived in the untracked private `data/learnings.md` rather than in tracked prose, which is why no repository check could have caught it.
Its repair moved the rule into `bin/fm-outbound-write-lib.sh`, where this check now holds it.

## Adding an entry point

Add the capability, wire its enforcing call, then declare it in `docs/enforcement-points.json` with its `id`, `kind`, one-sentence `invariant`, `guards`, and `callSites`.
Run `bin/fm-enforcement-caller-check.sh`; an undeclared or unreachable capability is named in the failure.
