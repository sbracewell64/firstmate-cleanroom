# no-mistakes per-run assessment: ce

Rendered 2026-09-07T17:00:49Z by bin/fm-nm-assess.sh from state/ce.nm-assessment (fm-nm-assessment/v1).
This assessment observes, classifies, and routes; it grants nothing, approves no gate, and is not a run outcome.

## Identity

- home: /tmp/nm-assess-demo.2nV0Rk/home
- project: /tmp/nm-assess-demo.2nV0Rk/wt
- repository remote: git@example:proj.git
- launch attempt: att-ce (predecessor attempt , predecessor run )
- run:  (branch fm/ce, head )
- runtime profile: no-mistakes 1.61.0 build 0af0be6
- transition: ci-ready-unverified

## Immediate boundary

- gate / canonical state: none / ci-ready-unverified
- defect or blocked condition: ci-ready claimed without source-applicable CI evidence: outcome=none, status=none; ci-ready must be backed by a checks-passed canonical verdict, never inferred from an absent or normalized state
- work executed: unknown (ci-ready claimed without source-applicable CI evidence)
- work never started: ci (no source-applicable evidence CI started or completed)
- carried residual finding: none
- next exact owner / gate: nmf-observer-check-normalization must confirm the source-applicable CI verdict before ci-ready is claimed; no CI gate is treated as consumed on absent or normalized state

## One owner level above

- owner / contract: the caller/lifecycle/shared-contract the routed finding names
- sibling consumers checked: the sibling consumers of that contract (see the finding family)

## Findings and dispositions

- check-normalization-1761489857|nmf-observer-check-normalization|ci-ready-requires-source-applicable-ci-evidence|check-normalization|profile=1.61.0/0af0be6|linked-existing-repair
- carried residual finding: none (carried by identity across refresh unless typed-closed)
- overall disposition: linked-existing-repair

## CI-ready evidence (unverified)

- ci-ready was NOT claimed: no source-applicable checks-passed verdict; ci-ready is never inferred from an absent or normalized state
- ci-ready claimed without source-applicable CI evidence: outcome=none, status=none; ci-ready must be backed by a checks-passed canonical verdict, never inferred from an absent or normalized state

## Coverage and freshness

- coverage performed: yes (recording existence is not investigation)
- last successful canonical read: 3000
- last material event: 3000
- last handled/acknowledged: 1788800449
- current runtime/session generation (daemon): 4242@2026-09-06T00:00:00Z
- captured eval cases are review evidence, never launch coverage, and are not counted here
