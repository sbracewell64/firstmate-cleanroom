# Clean-room no-mistakes pipeline prerequisite - 2026-09-03

This file exists only to give the clean-room's isolated no-mistakes pipeline a real, disposable change to validate.
It is the deliverable of the `ruling_2_no_mistakes_prerequisite` prerequisite run (control issue #7, decision PROCEED) and is never meant to be merged.

## What was exercised

- The full no-mistakes pipeline - review, tests, lint, docs, push through the gate, PR, and CI - driven only through its gates, with no hand fixes and without `--yes`.
- The run stopped at CI green (or a terminal failure); the PR was not merged.

## Client and root

- Client: the clean-room no-mistakes binary, v1.61.0.
- Data root, database, and daemon: the isolated clean-room root, selected by an explicit `NM_HOME` override on every client call.
- The shared legacy root was not used.

## Base

- Repository: `sbracewell64/firstmate-cleanroom`, a byte-exact and history-exact seed of upstream `kunchenguid/firstmate` at commit `41d0ab3910ece4e90db0194f756437b3abe8ab8f`.
- Branch: `fm/nm-isolated-pipeline-prereq`, based on that commit; PR target `main`.

## Change

- This file only. No tracked code, tests, workflows, or `AGENTS.md` were touched.
