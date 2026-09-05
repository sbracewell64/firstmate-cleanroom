# Programme continuation resolver - end-to-end CLI transcript

Isolated FM_HOME with the cleanroom requalification shape: proof-a attempts 1-2 FAILED, attempt 3 PROVED, empty tasks-axi backlog, config/programme pinned.
The temp home path is shown as `<home>`.
Exit codes are those of the first command in each pipeline.

## 1. Authorized continuation on the real cleanroom shape

$ cat config/programme
```
programme=<home>/cleanroom/programme.json
root=<home>/cleanroom
[exit 0]
```

$ fm-continuation-resolve.sh resolve
```
{
  "schema": "fm-continuation-resolution/v1",
  "programme": {
    "id": "cleanroom-requalification",
    "generation": "fm-requal-programme/v1",
    "path": "<home>/cleanroom/programme.json",
    "sha256": "9f41565e83abc90a3041c54eff92776ae3efde157d68e520f72dd3ebffa92096"
  },
  "next_action": "proof-b",
  "next_action_title": "fresh Proof B",
  "action_generation": 1,
  "classification": "SELF_HANDLE",
  "authority_state": "AUTHORIZED",
  "reason_code": "STANDING_GRANT",
  "basis_refs": [
    {
      "kind": "programme_grant",
      "ref": "control#3 requalification programme"
    },
    {
      "kind": "programme_grant",
      "ref": "control#3 comment 5546589797"
    },
    {
      "kind": "predecessor_disposition",
      "id": "proof-a",
      "attempt": 3,
      "outcome": "PROVED",
      "disposition": "<home>/cleanroom/artifacts/proofs/proof-a/attempt-3/disposition.json",
      "sha256": "39ab9b00ae6c32e10eb6d2ad1983d154f78d30b7c2e1543b2f0ed8d07c054405"
    }
  ],
  "applicability": {
    "action": "proof-b",
    "programme_id": "cleanroom-requalification",
    "programme_generation": "fm-requal-programme/v1",
    "programme_sha256": "9f41565e83abc90a3041c54eff92776ae3efde157d68e520f72dd3ebffa92096",
    "action_generation": 1,
    "predecessor": {
      "id": "proof-a",
      "attempt": 3,
      "outcome": "PROVED",
      "disposition": "<home>/cleanroom/artifacts/proofs/proof-a/attempt-3/disposition.json",
      "sha256": "39ab9b00ae6c32e10eb6d2ad1983d154f78d30b7c2e1543b2f0ed8d07c054405"
    },
    "current": null,
    "gating_holds": [],
    "answered_facts": [],
    "today": "2026-09-05"
  },
  "applicability_digest": "0d69db387d59b7c3cc9844c3eee94e5a6e7ebf7334154d8ef882ec8168f7ef26",
  "completed": [
    {
      "id": "proof-a",
      "attempt": 3,
      "outcome": "PROVED",
      "disposition": "<home>/cleanroom/artifacts/proofs/proof-a/attempt-3/disposition.json",
      "sha256": "39ab9b00ae6c32e10eb6d2ad1983d154f78d30b7c2e1543b2f0ed8d07c054405"
    }
  ],
  "holds": {
    "considered": 0,
    "gating": [],
    "ignored": []
  },
  "cno": null,
  "materialize": [],
  "why": "The standing programme grant pre-authorizes proof-b on the terminal-good predecessor (proof-a attempt 3 PROVED); no typed fact gates it, so it proceeds without a fresh captain word."
}
[exit 0]
```

$ fm-continuation-resolve.sh summary
```
programme cleanroom-requalification@fm-requal-programme/v1: next=proof-b SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT applicability=0d69db387d59
[exit 0]
```

$ fm-continuation-resolve.sh render
```
Programme cleanroom-requalification: next action proof-b (fresh Proof B), attempt 1.
Typed result: SELF_HANDLE / AUTHORIZED [STANDING_GRANT].
The standing programme grant pre-authorizes proof-b on the terminal-good predecessor (proof-a attempt 3 PROVED); no typed fact gates it, so it proceeds without a fresh captain word.
Basis:
  - grant control#3 requalification programme
  - grant control#3 comment 5546589797
  - disposition proof-a attempt 3 PROVED (39ab9b00ae6c)
Applicability 0d69db387d59: action proof-b, generation 1, programme fm-requal-programme/v1.
[exit 0]
```

## 2. check-prose refuses a manufactured captain gate over an AUTHORIZED result

$ fm-continuation-resolve.sh check-prose report.md   # report manufactures a gate
```
check-prose: REFUSED - text asserts a captain gate while the typed resolution is SELF_HANDLE/AUTHORIZED for proof-b:
1:Fresh Proof B is prepared but, like the re-review, nothing further runs without your word.
[exit 1]
```

$ printf 'Fresh Proof B proceeds under the standing grant; Proof A is PROVED.' | fm-continuation-resolve.sh check-prose -
```
check-prose: no captain-gate phrasing; consistent with SELF_HANDLE/AUTHORIZED
[exit 0]
```

## 3. Reserved-axis typed fact fires CAPTAIN with zero holds; --materialize creates the canonical hold

$ jq '.steps[1].captain_axes' programme.json
```
[{"axis":"new_paid_spend","decision_key":"proof-b-paid-runner","effect":"use a paid GitHub runner for Proof B"}]
[exit 0]
```

$ tasks-axi list --fields hold_kind   # store before
```
count: 0
tasks: 0 tasks in this backlog
help[2]:
  - "Run `tasks-axi add <id> \"<title>\"` to add a task"
  - Run `tasks-axi list --state done` to see completed work
[exit 0]
```

$ fm-continuation-resolve.sh resolve   # plain resolve is read-only
```
{
  "next_action": "proof-b",
  "classification": "CAPTAIN",
  "authority_state": "REQUIRES_CAPTAIN",
  "reason_code": "STEP_RESERVED_AXIS",
  "holds": {
    "considered": 0,
    "gating": [],
    "ignored": []
  },
  "materialize": [
    {
      "axis": "new_paid_spend",
      "decision_key": "proof-b-paid-runner",
      "effect": "use a paid GitHub runner for Proof B"
    }
  ],
  "materialized": null,
  "why": "proof-b declares a reserved axis (axis new_paid_spend) that only the captain may decide; it waits for the captain's own answer."
}
[exit 0]
```

$ tasks-axi list --fields hold_kind   # still empty after plain resolve
```
count: 0
tasks: 0 tasks in this backlog
help[2]:
  - "Run `tasks-axi add <id> \"<title>\"` to add a task"
  - Run `tasks-axi list --state done` to see completed work
[exit 0]
```

$ fm-continuation-resolve.sh render
```
Programme cleanroom-requalification: next action proof-b (fresh Proof B), attempt 1.
Typed result: CAPTAIN / REQUIRES_CAPTAIN [STEP_RESERVED_AXIS].
proof-b declares a reserved axis (axis new_paid_spend) that only the captain may decide; it waits for the captain's own answer.
Basis:
  - grant control#3 requalification programme
  - grant control#3 comment 5546589797
  - disposition proof-a attempt 3 PROVED (39ab9b00ae6c)
  - step fact axis new_paid_spend (reserved)
Durable captain hold required: run fm-continuation-resolve.sh resolve --materialize.
Applicability 82dabbb27317: action proof-b, generation 1, programme fm-requal-programme/v1.
[exit 0]
```

$ fm-continuation-resolve.sh resolve --materialize
```
{
  "classification": "CAPTAIN",
  "authority_state": "REQUIRES_CAPTAIN",
  "reason_code": "HOLD_RESERVED_AXIS",
  "basis_refs": [
    {
      "kind": "programme_grant",
      "ref": "control#3 requalification programme"
    },
    {
      "kind": "programme_grant",
      "ref": "control#3 comment 5546589797"
    },
    {
      "kind": "predecessor_disposition",
      "id": "proof-a",
      "attempt": 3,
      "outcome": "PROVED",
      "disposition": "<home>/cleanroom/artifacts/proofs/proof-a/attempt-3/disposition.json",
      "sha256": "39ab9b00ae6c32e10eb6d2ad1983d154f78d30b7c2e1543b2f0ed8d07c054405"
    },
    {
      "kind": "hold",
      "task": "proof-b-paid-runner",
      "hold_kind": "captain",
      "axis": "new_paid_spend",
      "wait": "",
      "classification": "CAPTAIN",
      "reason_code": "HOLD_RESERVED_AXIS"
    },
    {
      "kind": "step_fact",
      "axis": "new_paid_spend",
      "decision_key": "proof-b-paid-runner",
      "reserved": true,
      "answered": false
    }
  ],
  "materialized": [
    {
      "task": "proof-b-paid-runner",
      "axis": "new_paid_spend"
    }
  ],
  "applicability_digest": "cf2a8e8fc65bc77f6effa3180b1dde8aa923c24b144514936f9224ab34ef3be3"
}
[exit 0]
```

$ tasks-axi show proof-b-paid-runner
```
task:
  id: proof-b-paid-runner
  title: "Captain decision for proof-b: use a paid GitHub runner for Proof B"
  state: queued
  blocked: no
  blocked_by: none
  held: yes
  hold_reason: reserved axis new_paid_spend on programme step proof-b
  hold_kind: captain
  hold_until: "-"
  kind: task
  repo: firstmate
  priority: "-"
  created: 2026-09-05
  closed: "-"
  deps: none
  links: none
  body: "Continuation-binding: action=proof-b programme=cleanroom-requalification axis=new_paid_spend"
[exit 0]
```

$ fm-continuation-resolve.sh resolve --materialize   # replay converges
```
{
  "reason_code": "HOLD_RESERVED_AXIS",
  "materialized": [],
  "applicability_digest": "cf2a8e8fc65bc77f6effa3180b1dde8aa923c24b144514936f9224ab34ef3be3"
}
[exit 0]
```

## 4. Captain answer through fm-captain-hold.sh retires the fact; nothing re-fires

$ fm-captain-hold.sh answer proof-b-paid-runner --decision-file ok.txt --release
```
released: proof-b-paid-runner
[exit 0]
```

$ fm-continuation-resolve.sh resolve
```
{
  "next_action": "proof-b",
  "classification": "SELF_HANDLE",
  "authority_state": "AUTHORIZED",
  "reason_code": "STANDING_GRANT",
  "basis_refs": [
    {
      "kind": "programme_grant",
      "ref": "control#3 requalification programme"
    },
    {
      "kind": "programme_grant",
      "ref": "control#3 comment 5546589797"
    },
    {
      "kind": "predecessor_disposition",
      "id": "proof-a",
      "attempt": 3,
      "outcome": "PROVED",
      "disposition": "<home>/cleanroom/artifacts/proofs/proof-a/attempt-3/disposition.json",
      "sha256": "39ab9b00ae6c32e10eb6d2ad1983d154f78d30b7c2e1543b2f0ed8d07c054405"
    },
    {
      "kind": "step_fact",
      "axis": "new_paid_spend",
      "decision_key": "proof-b-paid-runner",
      "reserved": true,
      "answered": true,
      "answered_task": "proof-b-paid-runner",
      "answered_mode": "released"
    }
  ],
  "materialize": []
}
[exit 0]
```

$ fm-continuation-resolve.sh resolve --materialize   # answered fact is never re-materialized
```
{
  "reason_code": "STANDING_GRANT",
  "materialize": [],
  "materialized": []
}
[exit 0]
```

## 5. Bound external wait gates; lifted hold is not authority

$ fm-captain-hold.sh bind-action ci-quota --action proof-b --wait external && tasks-axi hold ci-quota --kind external && summary
```
ci-quota
programme cleanroom-requalification@fm-requal-programme/v1: next=proof-b EXTERNAL_DEPENDENCY/WAITING_EXTERNAL reason=HOLD_EXTERNAL_WAIT applicability=e98a44a35bd8
[exit 0]
```

$ fm-continuation-resolve.sh render
```
Programme cleanroom-requalification: next action proof-b (fresh Proof B), attempt 1.
Typed result: EXTERNAL_DEPENDENCY / WAITING_EXTERNAL [HOLD_EXTERNAL_WAIT].
proof-b waits on an external dependency (task ci-quota); no captain word is involved.
Basis:
  - grant control#3 requalification programme
  - grant control#3 comment 5546589797
  - disposition proof-a attempt 3 PROVED (39ab9b00ae6c)
  - hold ci-quota (external, wait external) -> EXTERNAL_DEPENDENCY
  - step fact axis new_paid_spend (reserved), answered by proof-b-paid-runner (released)
Applicability e98a44a35bd8: action proof-b, generation 1, programme fm-requal-programme/v1.
[exit 0]
```

$ tasks-axi unhold ci-quota && summary   # lifted hold gates nothing
```
programme cleanroom-requalification@fm-requal-programme/v1: next=proof-b SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT applicability=53ed916e2127
[exit 0]
```

## 6. Consumers project the same typed result

$ fm-fleet-snapshot.sh --json | jq .programme_continuation
```
{
  "configured": true,
  "schema": "fm-continuation-resolution/v1",
  "next_action": "proof-b",
  "classification": "SELF_HANDLE",
  "authority_state": "AUTHORIZED",
  "reason_code": "STANDING_GRANT",
  "applicability_digest": "53ed916e21270f780388556054470d8c723b51f1d43ae79ddd545d06d369da79"
}
[exit 0]
```

$ fm-fleet-view.sh   # Programme continuation section
```
## Programme continuation
cleanroom-requalification: next action proof-b - SELF_HANDLE / AUTHORIZED [STANDING_GRANT]. Owner: bin/fm-continuation-resolve.sh.

[exit 0]
```

$ fm-bearings-snapshot.sh   # programme row
```
programme[1]{programme,next_action,classification,authority_state,reason_code,applicability}:
  cleanroom-requalification,proof-b,SELF_HANDLE,AUTHORIZED,STANDING_GRANT,53ed916e2127
[exit 0]
```

$ programme_digest_token   # away-mode digest suffix
```
 | programme cleanroom-requalification@fm-requal-programme/v1: next=proof-b SELF_HANDLE/AUTHORIZED reason=STANDING_GRANT applicability=53ed916e2127[exit 0]
```

## 7. Resolver failure is shown, never guessed; unconfigured home exits 3 and consumers stay silent

$ printf 'not json' > programme.json; fm-fleet-view.sh
```
## Programme continuation
Resolver failed (exit 1); continuation authority is unproven, not captain-gated.
[exit 0]
```

$ fm-fleet-snapshot.sh --json | jq -c .programme_continuation
```
{"configured":true,"error":"fm-continuation-resolve: programme file is not a valid programme (programme_id, schema, steps[] required): <home>/cleanroom/programme.json","exit_code":1}
[exit 0]
```

$ rm config/programme; fm-continuation-resolve.sh resolve
```
fm-continuation-resolve: no programme configured (set <home>/config/programme with a programme= line, or pass --programme)
[exit 3]
```

$ fm-fleet-snapshot.sh --json | jq -c .programme_continuation
```
{"configured":false}
[exit 0]
```
