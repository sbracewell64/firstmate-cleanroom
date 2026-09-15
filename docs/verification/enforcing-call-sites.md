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
In such a file every enforce-verb arm label is collected wherever it appears, without tracking which `case` block it sits in.
That reading is deliberately blind: deciding block membership needs a shell lexer, and two attempts at one each dropped later arms on an ordinary shape, first a nested `case` and then a `case` token inside a quoted message.
Reading wide costs one more declaration to review, and an arm that is only an internal decision branch is declared as not an enforcement point with that reason.
A long option is discovered on every long alternative of an alias group, so `--enforce|--enforce-all)` accounts for both and `-e|--enforce)` is discovered on `--enforce` while the short alternative is ignored.
A function is discovered in any tracked `bin/` script or backend adapter, not only in a `*-lib.sh`.
In a sourced library, which means a `bin/` script another tracked script brings in with `.` or `source`, every enforce-verb function is discovered whatever it is named, because a library's functions are its entry points.
In a script that is only executed, discovery is limited to the `fm_`-prefixed functions; the bound below records why.
Every discovered candidate must be declared, so a new rule cannot ship without being accounted for.

A declared `enforced` entry must name at least one call site that exists, sits on the production surface, and still names the capability in executable text.
That is a NAMED-REFERENCE test, and the distinction matters: the check proves a declared, human-reviewed call site is still there and still mentions the capability, and it does NOT prove the shell executes it.
Deciding invocation from static text needs a shell parse this check does not do; the residues are listed under Honest bounds and the follow-up slice that would close them is recorded below.
What the check does catch is the family it was built for, an enforce-style entry point with no non-test caller at all, and that is unaffected by the distinction.
The production surface is what a running Firstmate or its automated gates execute: `bin/`, the CI workflows, `.no-mistakes.yaml`, and the registered harness hook files.
`tests/`, `docs/`, and agent skills are not on it.
A test that calls the capability is not evidence that the guarded path reaches it, and the check says so mechanically.
The reference must be executable, because a capability named only in a comment or in emitted operator text is prose that no reviewer should read as a caller.
Comments are stripped per language before the match.
Every hash-comment caller, which means `.sh`, `.yaml` and `.yml`, shares one rule: a comment is dropped from the first `#` that starts a word outside quotes, whether it opens the line or trails working code.
A word starts at the beginning of a line and after a space, a tab, `;`, `&`, `|` or `(`, each checked against bash rather than assumed.
A `)` is not on that list, because whether it ends a word depends on what it closes: `echo a$(true)#b` prints `a#b`, so a command substitution's `)` does not, while a subshell's does.
So a note at the end of a working line is prose, while a `${VAR#pattern}` expansion and a quoted `'#1'` are left alone.
A `.mjs`, `.js` or `.ts` caller has its own rule for `//` line comments and `/* */` blocks, and JSON has no comment syntax, so a hook registration is matched as written.

Emitted operator text is stripped too: in a shell caller, heredoc bodies and the argument text of `printf`, `echo` and `cat` are dropped.
An emitting command counts wherever a command can start, so one that follows `then`, `else`, `elif`, `do`, `{` or a case-arm label is recognised as well.
That list is enumerated rather than derived, so an emitting command introduced by some other opener is a residue rather than a rule.
A heredoc is recognised whether its delimiter follows `<<` directly or after whitespace, and an arithmetic shift inside `$(( ))` or `(( ))` is read as a shift rather than as an opener.
A command is assembled across its backslash continuations first, joined only on an odd count of trailing backslashes, so the tail of a multi-line `printf` is dropped with its first line instead of surviving as a call.
Command substitutions inside that text survive, so a genuine call spelled inside an emitted string is still a named reference.
A segment ends at a control operator as well, so only the emitting command's own arguments go: `bin/fm-turnend-guard-cursor.sh` keeps its `printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --cursor` call on the far side of the pipe.

A subcommand token must appear near the script's name rather than merely somewhere in the same file: it has to fall within 200 characters after the basename.
A long option is not held to that window; once the basename appears in the file, a word-bounded option token anywhere in the same file satisfies the reference, and the bound below records what that costs.
Every axis matches its token by the same boundary rule, and a hyphen does not end a token: `fm_lease_guard` is not satisfied by `fm_lease_guard_release`, and `verify` is satisfied by neither `--verify-all` nor `verify-later`.

A function call site must also have the library in scope: the site is the defining library itself, or a file that sources it directly or through a chain of sourced libraries.
Without that link a bare name proves nothing, because two files can define independent functions of the same name, and the repository already contains such homonyms.

An entry may also record `rejectedCallSites`: a path that names the capability only in comment or emitted text, with the reason.
The check asserts each one is still named by the file and still rejected by the matcher, so weakening the executable-reference rule fails loudly against a real production file rather than silently inflating the verified count.

## Why a repository gate may name a test

An entry declared `guards: runtime` guards a live Firstmate operation, and only a production-surface caller counts for it.
An entry declared `guards: repository` guards a property of the repository itself, where the guarded path is a change landing and the CI suite walk is the production path.
For those, and only those, a `ci-suite` call site is accepted, and the check proves the chain rather than assuming it: the named script must be a `tests/*.test.sh` that calls the capability, and `bin/fm-test-run.sh` must itself schedule that script into a CI lane.
That carve-out reaches the script, subcommand and long-option axes; a function-axis entry always needs a production-surface reference whatever it guards.
The narrower rule for functions is deliberate rather than an oversight, because a library function is reached through whatever executable sources it rather than by being named on a command line, and no declared entry has that shape today.
A test that exists but no lane runs is refused with the same force as no caller at all.
This is not a relaxation of the rule for runtime invariants: a `ci-suite` call site declared on a `guards: runtime` entry is refused outright.

## Honest bounds

A named reference is not an invocation, and every residue below is reproducible against the tree as it stands.
A path assigned but never executed still counts: in `bin/fm-tool-update-check.sh`, delete the exec at line 873 and the assignment `REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"` at line 79 alone keeps `bin/fm-check-register.sh` reported as enforced.
An existence test still counts: in `bin/fm-pr-check.sh`, delete the invocation at line 118 and the surviving `[ ! -x "$SCRIPT_DIR/fm-commit-identity-verify.sh" ]` at line 105 alone keeps `bin/fm-commit-identity-verify.sh` reported as enforced.
A subcommand token within 200 characters after the basename counts even across a line break, so a caller that runs `fm-startup-memory-budget.sh report` with a bare `enforce` word in a neighbouring command reads as the `enforce` call.
A long option is looser still, because no window applies to it: a file that runs the script without the flag and passes that same flag to an unrelated command elsewhere satisfies the reference.
Both declared sites for `bin/fm-tool-profile.sh:--require` rest on that co-occurrence rather than on a colocated pairing, and neither names the script and the flag on one line of executable text.
`bin/enter-firstmate.sh` names the script at line 1001 and builds `--require` into a command string at line 1006 through the `TOOL_PROFILE_OWNER` variable, and `bin/fm-nm-observe.sh` assembles `--require` with `set --` at line 593 and runs the script with `"$@"` at line 596.
Both were read and are genuine callers, so the entry's reading is right; what the check contributes there is co-occurrence, not the pairing.
Word boundaries do separate a longer sibling on the function axis, so `fm_lease_guard_release` does not satisfy `fm_lease_guard`; the script axis has no such separator, because the basename is matched as a plain substring of the executable text.
Discovery reads the same stripped executable text the caller matcher reads, not the raw source, so a capability named only in a comment, a heredoc body or emitted prose is not discovered at all.
That is deliberate, because it is what stops a commented-out or merely documented arm from being counted as a capability, but it does mean discovery inherits the stripping bounds listed here rather than being unconditionally wide: a mis-read heredoc opener in a `bin/` script would hide the definitions and arms below it.
YAML comments are found with shell quoting rules, because the hash-comment rule is deliberately shared rather than duplicated, so an unbalanced apostrophe in a plain scalar hides the comment that follows it: `description: don't gate this # bin/fm-lint.sh runs in CI` keeps its trailing comment in the executable text, because the apostrophe in `don't` opens a single-quoted region that never closes.
No tracked YAML hits that shape today, and the five lines across `.no-mistakes.yaml` and the three workflows that keep a `#` after stripping are all legitimately quoted shell or expression text.
Closing it would need a YAML-aware parse, which is out of scope for the same reason invocation binding is: this check stops short of re-implementing a language grammar.

Even where a declared call site really is an invocation, the check does not show that the caller consumes the callee's verdict.
A caller that runs the capability and then discards its exit status still counts as a call site, so an advisory reporter can look identical to a refusal from where this check stands.
`bin/fm-guard.sh` is the worked example: it always exits 0, so no caller can refuse on it, which the sweep below records.
Extending the check to detect a discarded verdict is a candidate follow-up, recorded here as an observation rather than attempted in this slice.

The check does not show full reachability from an executable entry point either.
A function called only from another unreached function in the same file still counts, so the `note` field records which executable traverses it.
That compensation is enforced rather than conventional: when every declared call site of a function entry is its own defining library, a non-empty `note` is required.
A function defined inside a script that is only executed, never sourced, is discovered only when its name carries the `fm_` prefix.
That is deliberate, and the measurement is the reason: 78 tracked functions in `bin/` carry an enforce verb without that prefix, 4 of them live in sourced libraries and are now discovered, and the other 74 are defined inside scripts that are only executed.
Those 74 are script-internal helpers: nothing outside the defining script can call them, so the script's own surface, which discovery already accounts for by name, subcommand and flag, is the entry point a caller can reach.
Reporting all 74 separately would bury the entry points that matter and train a reader to mute the check, which conceals as effectively as no check at all.
Discovery and the production surface are deliberately asymmetric about depth.
Discovery reads every tracked `*.sh` under `bin/` at any depth, because erring wide costs only one more declaration while erring narrow would let an enforce-named script under a new subdirectory ship unaccounted, which is the guarantee this check exists to give.
The production surface is matched one path segment at a time instead, because erring wide there would credit enforcement to a file nothing runs, so a new `bin/` subdirectory is not a production caller until it is declared as a surface in the script.
The surface list also means a `bin/*.mjs` decider such as `bin/fm-cd-command-policy.mjs`, `bin/fm-arm-command-policy.mjs` or `bin/fm-extension-launch-barrier.mjs` can be counted as a caller but can never be discovered as an entry point of its own.
Discovery is name-shaped, so a capability whose name carries none of the enforce words is found only when it is declared by hand; `bin/fm-outbound-write-lib.sh:fm_outbound_send` is declared that way.
The same name shape is what makes a namespace prefix look like a verb: `bin/fm-guard.sh`'s `fm_guard_*` banner helpers are discovered and then declared as not enforcement points, which keeps the account explicit rather than special-casing the prefix in discovery.
`data/` is captain-private and untracked, so a rule that lives only in `data/learnings.md` cannot be gated by a repository check at all.

## Sweep of 2026-09-14

The counts this sweep produced are the check's own output, captured verbatim under Evidence below.

The most significant finding is `bin/fm-guard.sh`.
It had been declared `enforced` over the invariant that a fleet mutation runs only from a session holding the verified per-home lock and an untangled checkout, and it cannot hold that.
Its only top-level exits are the `exit 0` statements at lines 167 and 242, and its own header states that it warns and never blocks, so no invocation can act on a failing status and a mutation from a tangled checkout prints the banner and then proceeds.
Most `bin/` callers underline that by invoking it as `|| true`, and the one that does not, `bin/fm-session-start.sh`, captures its output in a command substitution rather than acting on its status.
It is now declared as not an enforcement point, with the invariant restated as what it does guarantee, which is that the condition is announced.
This sweep did NOT establish whether a narrower owner enforces the per-home session lock at some other boundary; that question is recorded as not observed rather than answered in either direction.

The executable-reference rule reclassified references that a plain text match had accepted.
Most were shell header comments naming a capability the file never calls, which left some entry points resting on a caller elsewhere and, where the sweep found none at all, on a kind that says so.
The rest had been declared as verified call sites and are now recorded as `rejectedCallSites`, so the sweep's own finds became a permanent self-test that fails if the stripping rules are ever weakened.
No entry's reading changed from ACTIVE to UNPROVEN; what changed is that the inventory now says where enforcement actually happens.
Which entries those are, and the reason recorded against each, live in [`docs/enforcement-points.json`](../enforcement-points.json), which owns every per-entry row.

### Why an entry can be accounted for without an automatic caller

A capability with no automatic caller by design is declared `operator-invoked` with its reason and the prose owner that invokes it.
That owner has to name the capability, not merely the script: for a tokened entry the check requires the file to carry the script's basename followed by the token, so a document that lists the script in a command index does not qualify.
An entry of that kind is not the family's failure shape, because in each case the invariant itself is enforced elsewhere or the entry point is a human-initiated procedure.

A discovery false positive is declared `not-enforcement` with its reason.
The criterion is what the capability does rather than what it is called: an entry is not an enforcement point when, read in its own code, it refuses nothing a caller could act on.
A reader classifying a new one asks whether the enforce verb in its name describes the thing it does, and whether any caller could be turned away by it; if either answer is no, it is a false positive and the reason records which.
Neither kind is a softening, because both are explicit declarations a reviewer had to write, and an undeclared capability still fails by default.

### Known-good references, confirmed

Both already-repaired instances of this family still name their production callers, and `tests/fm-enforcement-callers.test.sh` asserts each by name.
That assertion is proven rather than trusted: the same predicate is run against copies of the inventory with each named caller removed, and both copies must be rejected.

### Observation, not repaired in this slice

`bin/fm-home-seed.sh:validate` is the one entry whose reach could be widened: nothing re-validates `data/secondmates.md` after a hand edit, so a registry corrupted outside the seed path is found at its next consumer rather than at session start.
That would wire a new call into `bin/fm-session-start.sh`, which a concurrent lane owns, so it is recorded here rather than done.

Binding a declared call site to a real invocation is the second deferral, and it is a slice of its own rather than a tightening of this one.
Doing it honestly needs a real shell-grammar parse rather than regex heuristics over text, because command position has to be decided for a command substitution, a pipeline, a leading environment assignment, a path held in a variable and a command string handed to a nested shell, and an existence test has to be told apart from an invocation.
It is filed separately because every regex approximation attempted while building this check traded one wrong answer for another: each tightening closed one shape and opened a different one, which is worse than a narrower claim that is true.

### Documented invariants with no named owner

The prose side was swept over `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, and every file under `docs/`, looking for sections that assert mechanical enforcement (`refuses`, `fails closed`, `enforces`) while naming no owning script or workflow anywhere in the section.
Twenty-seven sections matched that section-local shape, and each names its owner at the document level instead: `docs/subagent-guard.md` over `bin/fm-subagent-pretool-check.sh`, `docs/configuration.md`'s away-mode backend section over `bin/fm-supervise-daemon.sh`, `docs/extension-bindings.md` over the registered Pi extension, and so on.
`AGENTS.md`'s own mechanical claims were checked individually and each resolves to enforcing code: the explicit-home refusal in `bin/fm-send.sh`, the commit-identity refusal reached from `bin/fm-pr-check.sh`, the delivery-contract and backlog-gate refusals in `bin/fm-spawn.sh`, the completion gate `bin/fm-teardown.sh` reaches through `bin/fm-captain-hold.sh:verify`, and the worktree-isolation refusal in `bin/fm-spawn.sh` paired with the assertion `bin/fm-brief.sh` writes into every ship brief.
By that criterion, no section asserting mechanical enforcement failed to name an owning script or workflow at document level.

That criterion is narrower than the governing principle, and one tracked prose invariant does not survive the principle.
`AGENTS.md` states that a session which cannot acquire and verify the session lock must remain read-only and must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or perform any other fleet mutation.
`bin/fm-guard.sh` was the shared call site every one of those commands traverses, and this sweep reclassified it away from that invariant because it always exits 0, so no caller can act on a failing status.
This sweep did NOT establish whether a narrower owner enforces the lock at another boundary, so the per-home session lock is recorded as UNPROVEN here rather than claimed to be unenforced.
Reading it as ACTIVE because the rule is well known is exactly the softening the governing principle forbids.

The one prose instance of this family that did exist, the outbound-write discipline, lived in the untracked private `data/learnings.md` rather than in tracked prose, which is why no repository check could have caught it.
Its repair moved the rule into `bin/fm-outbound-write-lib.sh`, where this check now holds it.

## Evidence, run 2026-09-14

Every command below was run from a clean worktree at the branch tip, and the output is pasted verbatim.

```sh
bin/fm-enforcement-caller-check.sh
```

```text
fm-enforcement-caller-check: ok entries=51 enforced=39 operator_invoked=4 not_enforcement=8 call_sites=75 rejected_call_sites=5
```

```sh
bin/fm-lint.sh
```

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

```sh
bin/fm-test-run.sh --check-coverage
```

```text
FM_TEST_COVERAGE ok total=197 parallel=24 serial=161 serial_shards=4 herdr=12 serial_cap_min=30 serial_shard_budget_ms=1188000 serial_shard_max_hint_ms=1058513
```

```sh
bin/fm-doc-audience-check.sh
```

```text
fm-doc-audience-check: ok surfaces=93 local_links=334
```

```sh
bin/fm-test-run.sh tests/fm-enforcement-callers.test.sh tests/fm-documentation-audiences.test.sh
```

```text
FM_TEST_END 2026-09-15T03:13:58Z tests/fm-enforcement-callers.test.sh exit=0 duration_ms=14591 gate_skip=false
FM_TEST_END 2026-09-15T03:13:58Z tests/fm-documentation-audiences.test.sh exit=0 duration_ms=862 gate_skip=false
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=15518
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=15453 failed=0
```

## Adding an entry point

Add the capability, wire its enforcing call, then declare it in `docs/enforcement-points.json` with its `id`, `kind`, one-sentence `invariant`, `guards`, and `callSites`.
Run `bin/fm-enforcement-caller-check.sh`; an undeclared or unreachable capability is named in the failure.
