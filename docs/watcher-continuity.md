# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode; a refused notice commit stays silent for a later retry, and after a successful notice later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It confirms the handling handoff against that successor before scheduling the follow-up, retries once against the current generation and successor, and treats a failed confirmation as a restoration failure: it classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding, so a finished, hung, or identity-mismatched claim cannot suppress it ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).
The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
Direct drain callers receive that instruction on stderr.
Session start receives the drain-owned sequence and generation through a private descriptor before programme diagnostics run, then prints the instruction from that record; command-shaped diagnostic text never grants acknowledgement authority.
An unacknowledged downtime generation is announced at most once: the first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch and mints a fresh generation so buried decisions still resurface once.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below), while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff, using `bin/fm-lease-lib.sh`'s existing `fm_lease_actor` identity (`FM_SUPERVISION_ACTOR`, unset or `main` for every non-Pi harness and Pi's own main session; `branch` only inside the Pi supervision branch's own bash tool calls, injected deterministically by the extension - never agent memory).
Every presented row is claimed to exactly one actor under the durable queue lock.
Main records its presented set in `state/.main-eligible-rows`.
A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`, bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`, and publication is refused if main already claimed any requested row.
A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.
Its `--ack-through <SEQ>` deletes only claimed main rows at or below the cutoff, while a branch acknowledgement deletes only claimed branch rows at or below its cutoff.
Every settled branch prompt releases any residual grant, so an omitted or failed acknowledgement leaves the durable row available to a later main drain; a successful acknowledgement has already removed it.
If a branch offer loses the claim race to main, it falls back to a main follow-up rather than assuming the earlier main delivery is still live.
[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.
A check-kind row is main-owned in every mode, including a heartbeat review, so it is never part of a branch claim and never defers one; main is woken for it on that check's own triggering close.
`fm-wake-drain.sh` never reclassifies a row itself: it filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.
`tests/fm-wake-queue.test.sh`'s mixed-queue actor tests drive both directions against the real scripts: branch acknowledgement cannot swallow a main row, and a concurrent main turn cannot present or acknowledge an active branch grant.
`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
Every record also carries `restart_stop`, the disposition of the `--restart` stop the writing arm performed before it launched, and `child_stop`, the disposition of the owned watcher-child stop on an arm close.
It is `confirmed` when the recorded watcher was observed gone, `unconfirmed` when the stop was not confirmed within its bound, whether the bound elapsed with the watcher alive or the stop could not be delivered to a watcher that is still there, `no-live-watcher` when this home's lock recorded no live identity-matched watcher to stop, and `none` for an arm that was not a `--restart`.
This outcome errs only toward caution: it can record `unconfirmed` for a watcher that was in fact provably gone, because a pid recycled inside the restart window is read as gone by the stop helper but still answers the liveness poll that gates `confirmed`.
It never records `confirmed` for a watcher that was not observed gone.
`child_stop` is `confirmed` when the owned child exits within the bounded stop, `forced-unconfirmed` when that bound expires and the still-matching child is force-collected and reaped, `unconfirmed` when ownership no longer matches and the arm cannot safely force-collect it, and `none` when no owned child close was attempted.
`exit_code` and `signal` are both the literal `unknown` when the arm could not confirm its child's stop within its bound, because an arm that never observed the child exit has no status to wait for, so a consumer must not assume `exit_code` is a number.
`successor` stays the last field of the record because it is the one field rewritten in place, when a persistent adapter's successor arm resolves its predecessor's outcome; any further field is appended before it.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

Stopping a watcher is CONFIRMED by observing the process gone, never assumed from a queued signal, because the target's shell can consume a trapped signal without running its handler and carry on with its close path unrun; [`fm_stop_process_confirmed`](../bin/fm-wake-lib.sh) owns that fact and the re-delivery it requires.
The arm layer's `--restart` stop and the legacy auto-arm reclaim in that same library go through it, and so does the test suites' `reap`.
That close path is also uninterruptible: it ignores stop signals for its own duration, because a later stop would otherwise re-enter the exit handler and abandon it part way through.
The one exception is its wait for the downtime marker lock, which runs with the ordinary stop disposition still in force, because that wait has no deadline of its own and a holder that never releases would otherwise make the watcher unkillable.
The watcher takes that lock and holds it across the marker mutation and the singleton-lock release, so the uninterruptible region contains no unbounded wait: the transition it calls is the already-held variant and performs no acquire of its own, and the waits that do run inside it are bounded ones with deadlines of their own.
That no-wait property is established by inspection of the region rather than by a test that fails without it.
The two marker-lock cases in [`tests/fm-watcher-lock.test.sh`](../tests/fm-watcher-lock.test.sh) pin the outcomes the region must produce - the watcher stays collectable by an ordinary stop, and the downtime episode is still recoverable afterwards - and both also pass against the earlier probe-then-release shape, because the watcher defers its trapped stop until its poll sleep returns and a contending peer therefore wins the free lock essentially always.
The single attempt that takes it is the acquire itself rather than a question about it, so no peer can take the lock between deciding and acting, and only the retry loop a contended close falls into runs with stops still lethal.
The stop disposition in force during the wait releases the marker lock before exiting, so that lock is never left held by this watcher's dead pid.
It covers that one path and nothing further: a stop landing inside the acquire itself can leave a residue it does not own, such as the steal mutex or a lock link whose owner pid was never written, and those are reclaimed by the lock library's ordinary stale-owner steal rather than by this trap.
Nothing is written before that point, so such a stop leaves an unpublished downtime and a singleton lock still recorded to the collected watcher, which the next watcher's stale-lock steal publishes on its behalf.
The arm layer's own close paths ignore stop signals for the same reason and for the same duration, so a re-delivered stop cannot collect an arm between stopping its watcher child and writing that cycle's lifecycle record.
Those close paths stop the watcher child through the same bounded confirmed stop rather than an unbounded wait, so ignoring stop signals can never wedge an arm: the bound elapses, the lifecycle record is still written, and the arm still exits.
An unconfirmed `--restart` stop proceeds rather than refusing, because `--restart` is the recovery path and leaving the fleet with no watcher at all is worse than the duplicate a refusal would avoid; the outcome is named in `restart_stop` instead of being hidden.
The singleton lock is what holds the unconfirmed case to one live watcher: the fresh child stands down against the still-live recorded holder rather than running beside it, and `tests/fm-watcher-lock.test.sh` proves that against a holder that cannot act on any stop.
A watcher collected without running its close path publishes no downtime of its own, so the gap is not converted into a recovery episode until the next watcher steals its stale singleton lock.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watch-recovery-loop.test.sh` covers the once-per-generation announcement bound with the real Pi extension against a refused handling handshake, and a handling successor that must surface a real crew event instead of going blind.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination, a bounded reap that collects a watcher which swallowed its stop signal rather than waiting on it forever, a dropped stop that must be re-delivered until the watcher is gone so its close path still runs, a watcher stopped repeatedly whose close path must still publish an acknowledgeable stop, a `--restart` against a stop-proof recorded holder that must record the unconfirmed disposition and still leave exactly one live watcher, a close path held off by a stuck downtime-marker-lock holder that must still be collectable by ordinary stops and leave state the next watcher recovers, and the same close path against a peer that only begins contending for that lock once the stop has landed.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim; [`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset; [`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

### Release adoption and authenticated stage polling

A running watcher retains the parser loaded from its code root; staging a new release or reconnecting Desktop does not replace that process or update its loaded parser.
The [watcher identity predicate](../bin/fm-wake-lib.sh) requires the recorded watcher path to match the caller's expected path as well as the home and process identity, so a healthy old-root watcher is not proof that supervision from the new root is active.
Treat an old-root Doctor/checkpoint mismatch as read-only diagnosis and reporting, not authority to interrupt the primary, replace its watcher, or alter live task registration.
For Codex, after the old foreground checkpoint returns naturally, the adoption candidate is the next bare foreground checkpoint invoked from the qualified new release directory with the same explicit `FM_HOME` and scoped environment.
The [checkpoint entrypoint](../bin/fm-watch-checkpoint.sh) launches its sibling watcher; follow the [Codex foreground protocol](supervision-protocols/codex.md) without a background wrapper or a primary restart.
This invocation path does not itself establish live adoption; verify the resulting watcher's code path and identity before claiming the new release is supervising.
The separate Doctor configuration-reporting limitation remains owned by [configuration.md](configuration.md#native-primary-console-client).

The [PR identity parser](../bin/fm-pr-lib.sh) admits the lifecycle owner's exact stage fields after authenticated PR registration; [fm-stage.sh](../bin/fm-stage.sh) owns their schema.
The isolated registration-to-activation-to-authenticated-snapshot regression in [fm-pr-check-security.test.sh](../tests/fm-pr-check-security.test.sh) covers this ordering while retaining unknown-field, malformed-record, and duplicate-identity refusals.
That guarantee is independent of harness and backend recognition and does not qualify other metadata writers: [fm-promote.sh](../bin/fm-promote.sh) applies to scout promotion, while [fm-spawn.sh](../bin/fm-spawn.sh) recovery metadata may require separate PR-registration reconciliation.

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
