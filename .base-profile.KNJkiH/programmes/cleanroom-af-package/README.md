# Bounded A-F programme candidate

This directory is the candidate for the one bounded A-F programme the clean-room home may pin through `config/programme` ([`docs/configuration.md`](../../docs/configuration.md)).
It exists so the typed continuation owner can represent the A-F package authorized by the captain in control#3 comment 5554812621 without fabricating proof-attempt dispositions for slices that landed through pull requests or were admitted as deliverables.
The resolver header (`bin/fm-continuation-resolve.sh`) owns the programme schema, the owner-evidence record schema, and every check; [`docs/programme-continuation.md`](../../docs/programme-continuation.md) owns the invariant and the consumer census.
Nothing here is authority: the programme file and its evidence records are data the resolver reads and binds, and the captain grant, the Browser Sol ruling, the forge, and the no-mistakes pipeline remain the owners of what they record.

## Contents

- `programme.json` is the pinned sequence: the completed architecture re-review as the predecessor obligation, the package slices C, E, A, B, D, and the pilot F, with explicit dependencies, the controlling grant, the commission binding, the consumer contract, and the supported evidence kinds.
- `evidence/architecture-re-review-ruling.json` represents Browser Sol's post-Proof-B final disposition (control#3 comment 5554585623, decision `PROCEED_WITH_CONDITIONS`) through the ruling owner and binds the Proof-B attempt-3 disposition (`CNO_AT_B-S9`, zero observed-bad) by exact bytes and outcome under the artifact root.
- `evidence/slice-c-s3-pr5-landing.json` and `evidence/slice-e-pr6-landing.json` bind the forge pull-request records for PR #5 and PR #6 (head, merge commit, base), their complete check-run sets, and the no-mistakes evidence references the pipeline wrote into each PR body; their outcome is `MERGED_QUALIFIED`.
- Slices A, B, and D bind no qualification record yet: their steps name the path where the qualification owner's record must land, and until it does the resolver reports `REQUIRED_BINDING_MISSING` for the first of them, never completion.
  Each step records the FirstMate self-report on the control venue as `reported` data only; a self-report can never satisfy the step because its outcome vocabulary contains no qualification outcome.

Step order is representational: the accepted steps come first so the resolver's `completed` list shows what is already bound, the independent slices depend only on the ruling, and the pilot depends on all of them.
The pilot step is proof-shaped (`artifacts/proofs/af-pilot-f`) with `delegation.max_concurrency` 2 and the pre-frozen pilot contract recorded as data; the programme, the resolver, and the projection never launch it.

## What the candidate resolves to

Run against the clean-room root read-only, the candidate resolves the ruling, C, and E as complete, names slice A as the next action with `BROWSER_SOL / CNO [REQUIRED_BINDING_MISSING]`, and names the qualification owner as accountable.
The pilot F is not yielded, no captain gate is manufactured, and the remaining gate is the independent qualification of A, B, and D through their canonical owners, which the grant requires before F.

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
4. Qualification records for A, B, and D, owner the qualification and landing owners: when a slice is independently qualified, its owner record is authored at the step's `terminal_predicate.evidence` path as an `fm-accepted-owner-evidence/v1` record (a `pull_request_merge` record with `MERGED_QUALIFIED` and its bound qualification, or a `control_ruling` record with `ADOPT_OPTION` on a request that binds the deliverables' exact bytes), and the programme step is then pinned to that record's `evidence_sha256`, owner reference, and candidate identity.
   Re-pinning is a programme edit that moves the programme digest, the applicability tuple, and the material identity, which is the intended invalidation.
5. Formal consumption of the #31 ruling (comment 5561634429, `sol-ruling-f-programme-binding-20260906-b`), owner the fm-sol-control/v2 consume path: the binding records that ruling as published and pending consumption; this candidate does not assert it consumed, and the resulting receipt and applicability are a separate observation.
6. Launching F remains a later protected effect with immediate applicability revalidation and is outside this candidate entirely.

## Maintaining this directory

Keep the historical requalification programme under the clean-room root unchanged; the binding names it as superseded for this use only.
Never edit an evidence record in place to change what it says: a corrected or superseding record is a new record with a new digest, the old one keeps its `superseded_by`, and the programme pin moves with it.
