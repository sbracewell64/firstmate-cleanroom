# no-mistakes per-run assessment: pc

Rendered 2026-09-07T12:27:51Z by bin/fm-nm-assess.sh from state/pc.nm-assessment (fm-nm-assessment/v1).
This assessment observes, classifies, and routes; it grants nothing, approves no gate, and is not a run outcome.

## Identity

- home: /tmp/tmp.UPOnPEPZju/home
- project: /tmp/tmp.UPOnPEPZju/proj
- repository remote: git@example:proj.git
- launch attempt: att-pc (predecessor attempt , predecessor run )
- run: 02RUN (branch fm/pc, head 462865d4fce8318d9fa83b12da438d0a5fae9000)
- runtime profile: no-mistakes 1.61.0 build 0af0be6
- transition: stall

## Immediate boundary

- gate / canonical state: running / active
- defect or blocked condition: provider-capacity block at gate ci (out of usage credits): a typed external resource-blocked condition, not a candidate repair and not a candidate failure; 3 invocation attempt(s), no completed repair
- work executed: in progress
- work never started: the CI fixer repair (invoked but no completed repair)
- carried residual finding: none
- next exact owner / gate: the affected gate stays paused and predecessor-linked until capacity returns; the owning worker consumes the gate normally once it does; the pinned-tool fix is owned by nmf-provider-capacity-typed-condition

## One owner level above

- owner / contract: the no-mistakes CI caller and provider adapter (pinned-tool internal): source-applicable gate readiness must survive primary interruption/recovery; failed provider attempts stay durable and predecessor-linked; resource retry/accounting is budgeted separately from candidate repair attempts
- sibling consumers checked: every gate whose fixer invokes the same provider adapter; deduplicated as one family across occurrences
- reason broader repair is unnecessary here: no automatic paid fallback, provider/model substitution, new spend, global restart, or new watcher; FirstMate observes/classifies/routes only

## Provider-capacity (typed external resource-blocked condition)

- condition: out of usage credits
- real invocation attempts (no completed repair): 3
- completed repair: false
- usage/cost: unknown (UNKNOWN is never fabricated to zero)
- gate paused: ci (independent eligible work continues; readiness survives interruption/recovery)
- budget: separate from candidate repair-attempt budgets

## Findings and dispositions

- provider-capacity-2766270645|nmf-provider-capacity-typed-condition|provider-capacity-is-not-a-candidate-repair|provider-capacity|profile=1.61.0/0af0be6|linked-existing-repair
- overall disposition: linked-existing-repair

## Coverage and freshness

- last successful canonical read: 1000
- last material event: 1000
- last handled/acknowledged: 1788784071
- current runtime/session generation (daemon): 4242@2026-09-06T00:00:00Z
- captured eval cases are review evidence, never launch coverage, and are not counted here
