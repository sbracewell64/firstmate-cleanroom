# no-mistakes per-run assessment: lm

Rendered 2026-09-07T12:28:16Z by bin/fm-nm-assess.sh from state/lm.nm-assessment (fm-nm-assessment/v1).
This assessment observes, classifies, and routes; it grants nothing, approves no gate, and is not a run outcome.

## Identity

- home: /tmp/tmp.UPOnPEPZju/home
- project: /tmp/tmp.UPOnPEPZju/proj
- repository remote: git@example:proj.git
- launch attempt: att-lm (predecessor attempt , predecessor run )
- run: 05RUN (branch fm/lm, head 462865d4fce8318d9fa83b12da438d0a5fae9000)
- runtime profile: no-mistakes 1.61.0 build 0af0be6
- transition: terminal

## Immediate boundary

- gate / canonical state: completed / successful
- defect or blocked condition: none
- work executed: review,test,document,lint,push,pr,ci
- work never started: none
- carried residual finding: none
- next exact owner / gate: the guarded-landing owner (bin/fm-pr-merge.sh) under its existing merge authority; validated is not landed

## One owner level above

- owner / contract: no anomaly within measured coverage
- sibling consumers checked: none
- reason broader repair is unnecessary here: the canonical read exposed no defect and no avoidable work; a clean assessment does not prove the architecture defect-free

## Late-merge reconciliation

- provider/canonical publication: merged:github:github.com:x/y:12
- cached run pr (untrusted, not authoritative): https://github.com/x/y/pull/12
- terminal outcome is taken from the provider/canonical state, never the stale cached run record

## Findings and dispositions

- none within measured coverage; disposition: no-actionable-anomaly
- overall disposition: no-actionable-anomaly

## Coverage and freshness

- last successful canonical read: 1788784096
- last material event: 2000
- last handled/acknowledged: 1788784096
- current runtime/session generation (daemon): 4242@2026-09-06T00:00:00Z
- captured eval cases are review evidence, never launch coverage, and are not counted here
