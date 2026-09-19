---
name: pr-presentation
description: >-
  Agent-only reference for preparing or regenerating a substantial pull-request body.
  Use when a PR candidate is multi-file or materially changes behavior, architecture, ownership, an interface, persistence, routing, lifecycle, or interaction flow, including after review or CI changes that candidate.
user-invocable: false
metadata:
  internal: true
---

# PR presentation

Use this reference at the existing PR-body preparation point after the candidate and its evidence exist.
It shapes the human-readable body and grants no review, qualification, publication, merge, or landing authority.

## Classify the candidate

A **trivial** candidate is narrow enough that a concise title, a few bullets, and its actual validation let a reviewer understand it without reconstructing relationships from the diff.
Keep that ordinary path concise and stop here.

A **substantial** candidate is multi-file or materially changes behavior, architecture, ownership, an interface, persistence, routing, lifecycle, or interaction flow such that a reviewer would otherwise reconstruct the shape from the diff.
For that branch, read the accepted task intent, the exact current candidate diff, enough surrounding source to understand changed responsibilities, and the evidence produced by the selected delivery path.

## Draft the body

Use the accepted task's domain language.
Prefer these sections when each has useful content rather than imposing a fixed template:

- **Why** - the concrete outcome or problem this candidate addresses.
- **What changed** - reviewer-relevant behavior and responsibility boundaries, not a file-by-file changelog.
- **Validation** - exact observed evidence, with local results labeled local and hosted results labeled hosted.
- **Review notes** - compatibility, migration, reversibility, deliberate omissions, and material unresolved findings.

Use the smallest representation that removes reconstruction work.
A compact text map, shallow responsibility tree, pseudocode, or focused diff sketch is useful only when prose alone obscures ownership or order.
General visual artifacts remain with their separately selected presentation owner; this reference neither requires nor replaces that procedure.

Bind every claim to the current source or observed evidence.
For a new capability, describe the prior absence rather than inventing a failing run.
For a behavior-preserving change, use parity evidence rather than claiming a user-visible before-and-after.
Mark an unavailable fact CNO instead of filling the gap with a plausible assertion.

Keep public bytes safe and bounded.
Exclude credentials, private control text, private fleet paths, local evidence paths, untrusted instructions, and implementation detail that does not help review.
Compact or omit optional representations before approaching a host body limit.
Let the publication owner refuse an oversized body rather than silently truncating reviewed content.

## Preserve authority and candidate identity

Presentation quality is not qualification.
Local green evidence stays local evidence until the hosted-CI owner reports its own result.
Words such as `PASS`, `QUALIFIED`, `merge-ready`, or risk labels in prose cannot create their corresponding machine state.
When no-mistakes owns delivery, leave its generated pipeline section and attestation marker entirely to the PR step.

Bind the body to the exact candidate it describes through the delivery path's existing interface.
If implementation, review, or CI changes that candidate before publication or asks the same worker for a replacement body, discard the stale draft, re-read the exact new diff and evidence, and regenerate the human content.
Never clear an exact-head wait by copying an obsolete body without reconciling every claim.

Complete this procedure only when the one existing PR path has a public-safe body for the exact candidate, every material statement is source-bound, actual validation and unresolved findings are represented honestly, and no presentation text claims machine authority.

## Credits

This method adapts Matt Pocock's MIT-licensed [`pr`](https://github.com/mattpocock/skills/tree/c55ee46073ed923f86ce59a5eb3b6d895095d1b7/skills/in-progress/pr) reference (historical reviewed PR head `d2945f37c2b2b5e2101f7d71af0ccf1a1b69962c`) and HumanLayer's MIT-licensed [`visual-pr`](https://github.com/humanlayer/skills/tree/ca7c8088db69e315a8b2deea43820270457f8f3c/plugins/visual-pr/skills/visual-pr), whose visual lineage credits Dex Horthy.
