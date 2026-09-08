# no-mistakes gate publication-timing race fix — end-to-end evidence

Branch `fm/nmf-push-attestation-head-sync` (target `c5f4444`, base `7b264cd`).

## 1. Regression reproduced, then fixed (resolve helper + pinned verifier)

Scenario: live PR head advanced to `2222…` but the body's v1 pipeline attestation
is still bound to the PRIOR head `1111…` — the window between `git push no-mistakes`
advancing the head and re-publishing the body attestation.

### Base commit (7b264cd) — spurious current-head FAIL
`fm-nmf-verify-input.sh resolve` exits 0 and emits the PRIOR-head body to the verifier:
```
head_sha=2222222222222222222222222222222222222222
body<<NMF_BODY_…
… attestation:v1 {"head_sha":"1111111111111111111111111111111111111111", …}
```
The pinned verifier then FAILS on that same live head:
```
verifier exit=1
::error::Pipeline attestation head_sha does not match the current PR head.
attestation.head_sha: 1111111111111111111111111111111111111111
PR head:              2222222222222222222222222222222222222222
```

### Target commit (c5f4444) — held PENDING, no red result
Same race input:
```
resolve exit=3   (PENDING — retry within window; NOT handed to verifier)
::notice::… live body attestation is bound to 1111…, not the live head 2222…;
           awaiting re-publication for the current head within the bounded window.
```
Once publication lands (body now binds live head `2222…`):
```
resolve exit=0 (BOUND, emits body)
verifier exit=0
Found no-mistakes signature in PR #3006 body.
Found structurally compliant pipeline step attestation.
```
The race resolves GREEN on the same head with no re-attest / restart / manual step.

## 2. Workflow resolve loop — exit-3 retry contract (extracted from
`.github/workflows/no-mistakes-required.yml` and executed with a stubbed helper)

```
Case 1: PENDING x2 then BOUND -> retries, success writes GITHUB_OUTPUT (3 invocations, exit 0)
Case 2: always PENDING        -> fails closed at deadline (exit 1, ::error:: publication window)
Case 3: hard refusal exit 1   -> propagates immediately, no retry (1 invocation, exit 1)
```
Confirms: exit 3 = retry within window, exit 0 = bind & publish, any other non-zero
propagates immediately, deadline fails closed. No red result is bypassed.

## 3. Targeted suite
`bash tests/fm-no-mistakes-required.test.sh` — 19/19 ok, including the fetched pinned
verifier fixtures, PENDING-when-bound-to-other-head, PENDING-when-no-attestation-yet,
PENDING ::notice:: names both heads, and race-resolves-green-once-bound.
