# Bounded A-F programme candidate

This directory is the candidate for the one bounded A-F programme the clean-room home may pin through `config/programme` ([`docs/configuration.md`](../../docs/configuration.md)).
It exists so the typed continuation owner can represent the A-F package authorized by the captain in control#3 comment 5554812621 without fabricating proof-attempt dispositions for slices that landed through pull requests or were admitted as deliverables.
The resolver header (`bin/fm-continuation-resolve.sh`) owns the programme schema, the owner-evidence record schema, and every check; [`docs/programme-continuation.md`](../../docs/programme-continuation.md) owns the invariant and the consumer census.
Nothing here is authority: the programme file and its evidence records are data the resolver reads and binds, and the captain grant, the Browser Sol ruling, the forge, and the no-mistakes pipeline remain the owners of what they record.

## Contents

- `programme.json` is the pinned sequence: the completed architecture re-review as the predecessor obligation, the package slices C, E, A, B, D, and the pilot F, with explicit dependencies, the controlling grant, the commission binding, the consumer contract, and the supported evidence kinds.
- `evidence/architecture-re-review-ruling.json` represents Browser Sol's post-Proof-B final disposition (control#3 comment 5554585623, decision `PROCEED_WITH_CONDITIONS`) through the ruling owner and binds the Proof-B attempt-3 disposition (`CNO_AT_B-S9`, zero observed-bad) by exact bytes and outcome under the artifact root.
- `evidence/slice-c-s3-pr5-landing.json` and `evidence/slice-e-pr6-landing.json` bind the forge pull-request records for PR #5 and PR #6 (head, merge commit, base), their complete check-run sets, and the no-mistakes evidence references the pipeline wrote into each PR body; their outcome is `MERGED_QUALIFIED`.
- `evidence/slice-a-s1-qualification.json` and `evidence/slice-b-s2-qualification.json` bind the governed local-project deliveries of A's two publication-integrity executables and B's reference-catalog checker into the registered local-only `exchange-work` owner at head `1d2a6a7fc361551958cae8eb0048e8e529dde767` and tree `44ef428d51457b4888e086aaffe49137fbd4e1e8`; their outcome is `DELIVERED_QUALIFIED`, and they publish identities, digests, and typed outcomes only, because the immutable pre-effect admission and the task-private mode-0600 delivery and checker receipts stay under the operational home and never enter Git.
- Slices A, B, and D accept the forge and ruling routes plus `DELIVERED_QUALIFIED` from the governed local-project delivery owner.
  A and B are `DELIVERED_QUALIFIED` only where their private V2 admission and delivery/checker receipts remain available and still verify; wherever the resolver cannot read one of them back it reports CNO `OWNER_EVIDENCE_READBACK_UNAVAILABLE` for that slice rather than completion, and readable but stale, replayed, contradictory, wrong-owner, wrong-family, wrong-path, wrong-type, wrong-digest, or moved head/tree evidence is refusal.
  D alone binds no qualification record: its step names the path where the qualification owner's record must land, and until one does the resolver reports `REQUIRED_BINDING_MISSING` for D, never completion.
  A new local delivery first binds the step's `terminal_predicate.local_delivery` family through `bin/fm-local-project-delivery.py bind`, before dispatch or delivery effects, and qualifies only after the programme pins its owner, record digest, generation, policy, and exact destination candidate head/tree/delivery identity and the resolver reproduces the immutable admission, private delivery receipt, distinct maker/checker identities, bound checker receipt, digest-only privacy declaration, and destination read-back.
  A and B pin `exchange-work` as their registered local-only tracked destination, require the three executable objects at Git mode `100755`, and bind exchange generation 7 as current plus the generation-6 tree as byte-exact rollback.
  D declares the complete seven-member S4 family, including the registry-named manager-loop plan, but pins no project; `--project auto` may select exactly one existing complete registered local-only owner, while no such owner remains CNO `OWNER_MISSING` and creates no project, remote, substitute owner, policy, or authority route.
  The fresh census for this task found no such owner, so D holds at CNO; it reopens only if a later census positively finds exactly one lawful complete owner.
  Each step records the FirstMate self-report on the control venue as `reported` data only; a self-report can never satisfy the step because its outcome vocabulary contains no qualification outcome.

Step order is representational: the accepted steps come first so the resolver's `completed` list shows what is already bound, the independent slices depend only on the ruling, and the pilot depends on all of them.
The pilot step is proof-shaped (`artifacts/proofs/af-pilot-f`) with `delegation.max_concurrency` 2 and the pre-frozen pilot contract recorded as data; the programme, the resolver, and the projection never launch it.

## What the candidate resolves to

Run read-only against the clean-room root in the operational home, where A's and B's private receipts are available and still verify, the candidate resolves the ruling, C, E, A, and B as complete, names slice D as the next action with `BROWSER_SOL / CNO [REQUIRED_BINDING_MISSING]`, and names the qualification owner as accountable.
On any host without those private receipts A is the next action and resolves CNO `OWNER_EVIDENCE_READBACK_UNAVAILABLE` instead, which is equally not completion.
The pilot F is not yielded, no captain gate is manufactured, and the remaining gate is the independent qualification of D through its canonical owner, which the grant requires before F; with D at CNO, F stays ineligible and no higher ramp is authorized.
Qualifying source evidence is not serving-runtime activation: these records qualify the delivered source through its owner and assert nothing about what the serving release runs.

## Hand-off: admission, deployment, and read-back

The bounded worker that authored this candidate wrote nothing outside its repository worktree.
The following effects are separate and belong to the named owners under the same parent repair; this README is the precise spec, not an unassigned follow-up.

1. Admission of the pin, owner `config/programme` in the operational home, written by firstmate after this candidate lands on the default branch and the home's clone is refreshed:

   ```
   programme=<clone root>/programmes/cleanroom-af-package/programme.json
   root=/mnt/e/FirstMate-Cleanroom
   ```

   The root must be the clean-room artifact root, because the ruling record binds `artifacts/proofs/proof-b/attempt-3/disposition.json` and `artifacts/control/policy/architecture-review-acceptance-v1.md` under it and the pilot's proof attempts will live under `artifacts/proofs/af-pilot-f`.
2. Deployment, owner the running firstmate installation: the callers that consume the repaired readiness and quiet semantics (`bin/fm-session-start.sh`, `bin/fm-wake-drain.sh`, `bin/fm-fleet-snapshot.sh`, `bin/fm-fleet-view.sh`, `bin/fm-supervise-daemon.sh`) run only from a firstmate whose `bin/` carries this landing.
   Landed is not running: until the running installation fast-forwards to a revision that includes this change, the resolver's `runtime.resolver_sha256` in any live result will not match this candidate's, and the home continues to run whatever it runs today.
3. Read-back, owner firstmate in the operational home: after the pin and the deployment, run `bin/fm-continuation-resolve.sh render` and `bin/fm-programme-projection.sh summary` from the running installation and record the exact typed result, its `material_identity`, and its `runtime` identities as the read-back evidence; the candidate's own read-only run above is not that observation.
4. Qualification records for A, B, and D, owner the qualification and landing owners: when a slice is independently qualified, its owner record is authored at the step's `terminal_predicate.evidence` path as an `fm-accepted-owner-evidence/v1` record.
   The accepted routes are a `pull_request_merge` record with `MERGED_QUALIFIED` and its bound qualification, a `control_ruling` record with `ADOPT_OPTION` on a request that binds inspectable exact bytes, or a `local_project_delivery` record with `DELIVERED_QUALIFIED` and the private receipt contract owned by `bin/fm-continuation-resolve.sh`.
   The local route publishes identities and digests only; its owner-bound admission and candidate/checker receipts remain under the operational home, and an unavailable source, owner, receipt, or destination is CNO rather than qualification.
   The programme step is then pinned to that record's digest, generation, owner, policy, and exact candidate identity.
   Re-pinning is a programme edit that moves the programme digest, the applicability tuple, and the material identity, which is the intended invalidation.
5. Formal consumption of the #31 ruling (comment 5561634429, `sol-ruling-f-programme-binding-20260906-b`), owner the fm-sol-control/v2 consume path: the binding records that ruling as published and pending consumption; this candidate does not assert it consumed, and the resulting receipt and applicability are a separate observation.
6. Launching F remains a later protected effect with immediate applicability revalidation and is outside this candidate entirely.

## Maintaining this directory

Keep the historical requalification programme under the clean-room root unchanged; the binding names it as superseded for this use only.
Never edit an evidence record in place to change what it says: a corrected or superseding record is a new record with a new digest, the old one keeps its `superseded_by`, and the programme pin moves with it.
