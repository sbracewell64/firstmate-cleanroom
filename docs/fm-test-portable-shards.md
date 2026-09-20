# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints are the per-script mean of the `fm-test-timing-portable-serial-*` artifacts from the four green CI runs [34813628086](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34813628086), [34823065861](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34823065861), [34826043556](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34826043556), and [34843572468](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34843572468) of 2026-09-14, where the lane ran 160 scripts in about 4.9 million ms of serial work per run.
Averaging several runs damps the per-run spread (the same script varies by up to 2x between runs) that a single-run refresh bakes into the partition.
A hint the refresh did not cover is a local measurement rather than a CI mean, and the next refresh replaces it with the measured mean.
`tests/enter-firstmate-render.test.sh` was repaired in the same change that refreshed the table (see the 2026-09-14 refresh below), so its hint is its local post-repair wall scaled by the CI-to-local ratio the unchanged `tests/enter-firstmate-launch.test.sh` measured on the same machine, and a script added after that refresh carries its measured local wall the same way.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints affect balance and the shard budget guard below, never coverage: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard or a budget refusal rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured or grown scripts let one shard carry far more than another shard's real work and reach the job cap while another runner sits idle.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 41 | 1078513 ms (~1078.5 s) |
| `portable-serial-2of4` | 41 | 1078499 ms (~1078.5 s) |
| `portable-serial-3of4` | 41 | 1078499 ms (~1078.5 s) |
| `portable-serial-4of4` | 42 | 1078512 ms (~1078.5 s) |
| imbalance | | 14 ms |

The single longest script, `tests/fm-watch-triage.test.sh` at 265573 ms, is the floor for any shard count.

### Measured lane times and the 2026-09-14 refresh

The per-lane script time (`summary.duration_ms` of each lane artifact) on the four runs above, before the refresh, was:

| Lane | 34813628086 | 34823065861 | 34826043556 | 34843572468 |
|---|---:|---:|---:|---:|
| `portable-parallel-1` | 226.5 s | 225.4 s | 234.9 s | 204.5 s |
| `portable-parallel-2` | 131.5 s | 115.9 s | 127.4 s | 160.6 s |
| `portable-serial-1of4` | 1035.9 s | 1124.6 s | 1043.2 s | 1060.3 s |
| `portable-serial-2of4` | 1566.5 s | 1750.4 s | 1700.1 s | 1488.9 s |
| `portable-serial-3of4` | 982.4 s | 961.9 s | 852.9 s | 983.4 s |
| `portable-serial-4of4` | 1267.7 s | 1182.3 s | 1320.5 s | 1203.5 s |

`portable-serial-2of4` was the critical path each time, at 25 to 29 minutes of script time against the 30-minute cap, and on [run 34836750198](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34836750198) it was cancelled at the cap with 1800 s of script time recorded.
The previous hints, from the 2026-09-07 refresh, had balanced the four shards to 985 s each, but thirteen scripts added since carried no hint and fell to the 20 s default.
One of them, `tests/enter-firstmate-render.test.sh`, measured 765 to 858 s (a mean of 815 s, 40x its default) and landed in shard 2 beside the next-largest hinted scripts.
Its cost was repetition, not work: every staging that passes the donor guard runs `bin/fm-render-launcher.sh`'s full qualification, which runs the whole `tests/enter-firstmate-{arm,launch,profile}.test.sh` family from the repo the tool lives in, and the suite drove eight such stagings against the real repo, so it re-ran `tests/enter-firstmate-launch.test.sh` (135 s mean, dominated by two 25 s delayed-startup contract cases in `tests/test_console_lifecycle.py`) eight times over.
The repair keeps exactly one real-repo staging, which now also asserts the launcher family ran and every member passed, and drives every other staging through a byte-identical copy of the tool from a scratch repo holding the real launcher and stub launcher tests, the repo-root seam the suite's missing-capability case already used.
No assertion was removed: the suite went from 48 to 50 guarded assertion lines, and the family it stopped repeating still runs as its own scripts of the same lane.

With the refreshed hints the four shards project to the table above, a critical shard of about 17.6 minutes of script time against the 66 % budget's 19.8 minutes, and by the same run-to-run spread noted under Timeouts the slowest shard should finish in the low twenties of minutes of job wall.
That is the expected effect of the redistribution plus the render repair, not a measured result: record the first post-refresh runs' per-lane times here at the next hint refresh.

Refresh the hints by downloading the per-shard timing artifacts from the latest few green CI runs whose shard artifacts together cover every serial script (three or four, as above, damps the per-run spread; one run works but bakes its spread into the partition), replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with each script's mean `duration_ms` over the runs that carried it, and updating the table above from `--serial-shard-loads`:

```sh
for run in <run-id> <run-id> <run-id>; do gh run download "$run" -R <owner>/<repo> --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"; done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*/*.json | awk '{ sum[$1] += $2; n[$1]++ } END { for (p in sum) printf "%s %d\n", p, sum[p] / n[p] }' | LC_ALL=C sort
bin/fm-test-run.sh --serial-shard-loads
bin/fm-test-run.sh --check-coverage
```

`bin/fm-test-run.sh` states the shard job cap and budgets every shard's summed hints at a fixed fraction of it, so `--check-coverage` fails on hint drift before a runner is cancelled at the cap.
The script's header owns the cap, the fraction, and the what-if override for trying a different cap.
`tests/fm-test-run.test.sh` fails when the stated cap disagrees with the `tests-portable-serial` job timeout in `.github/workflows/ci.yml`, so the two change together.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It also fails when any portable serial shard's summed duration hints exceed the budget derived from the shard job cap, and prints the cap, the budget, and the largest shard total on its success line.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
Each lane artifact carries its lane identity (`lane`: the `--lane` name, or the family name for the Herdr family run), and `bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact from those identities.
The aggregate resolves lane files nested anywhere under the downloaded artifact directory, refuses a nonexistent input, an input that is not valid JSON, an input with no lane identity, or two inputs claiming one lane, keeps gate skips (`skipped_gate`) apart from `executed` scripts, and checks the lanes it saw against the expected-lane manifest.
An aggregate run whose inputs yield no lane at all (no timing file, or only a prior aggregate) is refused with exit 2 and nothing written, with or without a manifest, so it never publishes an empty report; under a manifest the refusal names every expected lane as missing.
That manifest is `bin/fm-test-run.sh --list-ci-lanes`, the same owner the lane jobs take their names and shard count from; a lane that produced no artifact is listed under `missing_lanes`, the aggregate is marked `complete: false`, the summary line says `INCOMPLETE`, and the aggregate job fails by lane name instead of publishing a smaller report as if it were the whole fleet.
Before this check the Herdr lane's nested file was silently left out, so the aggregate reported six lanes and 168 scripts for a run that executed seven lanes and 180.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring, and `tests/fm-test-run.test.sh` checks that every job uploading lane timing feeds the aggregate job.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured lane script times are two to four minutes (the lane table above) and the timeout is a hang tripwire. |
| portable serial 1-4 | job `timeout-minutes: 30` | Each balanced shard is under 18 minutes of hinted script time (the shard table above owns the exact figure), and the same scripts varied by about +27 % between two runs, so the former 20-minute cap sat inside normal spread and cancelled healthy shards; 30 minutes gives about 2x hang-tripwire margin for job setup and runner-speed spread, and the coverage guard's shard budget of 66 % of the cap keeps hinted work at or below 19.8 minutes, which at +27 % still finishes with several minutes to spare. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers, except the portable serial cap, which `bin/fm-test-run.sh` states and the workflow must match.
