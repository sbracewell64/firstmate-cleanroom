# eligible_queued producer slice — end-to-end evidence

## Hazard scenario (the reported case)
Home with `active_children=0`, holds present, aggregate `state=externally_held`,
yet an independent queued task has no unresolved blocker and no active hold.

Producer output (`bin/fm-fleet-snapshot.sh --secondmate-home-summary`):

```json
{
  "state": "externally_held",
  "counts": {
    "active_children": 0,
    "decisions_open": 0,
    "holds": 2,
    "queued": 3,
    "eligible_queued": 1,
    "landed": 0,
    "endpoints": 0
  },
  "eligible_queued": [
    { "id": "eligible-task", "title": "Independent eligible work",
      "kind": "ship", "priority": "2", "repo": "alpha", "source": "backlog" }
  ],
  "holds": ["dep-task", "held-task"]
}
```

The aggregate label stays `externally_held` (unchanged, informational), but
`eligible_queued` now exposes the single structurally-selectable task —
`dep-task` (dependency-blocked) and `held-task` (active hold) are correctly
excluded, matching the queued-hold surface complement.

## Red-before-green control
Running the new regression `test_eligible_queued_reflects_per_task_predicates`
against the BASE binary (commit b7ffeea, pre-fix) fails: base output has no
`eligible_queued` key, so `.eligible_queued[]` raises
`jq: error ... Cannot iterate over null` and the test exits 1. It passes on the
fixed binary.

## Schema-gate propagation
The published-schema gate in `bin/fm-home-summary-refresh.sh` now requires
`(.eligible_queued | type) == "array"`:
- accepts the producer document (field present) — PASS
- rejects a document with `eligible_queued` deleted — PASS
