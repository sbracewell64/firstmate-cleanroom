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
The hints are the per-script mean of the `fm-test-timing-portable-serial-*` artifacts from the three green `main` CI runs [34036430465](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34036430465), [34064555580](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34064555580), and [34073321294](https://github.com/sbracewell64/firstmate-cleanroom/actions/runs/34073321294) of 2026-09-06 and 2026-09-07, where the lane ran 144 scripts in about 3.8 million ms of serial work per run.
Averaging three runs damps the per-run spread (the same script varied by up to 2x between runs, for example `tests/fm-control-relaunch.test.sh` at 46 s to 94 s) that a single-run refresh bakes into the partition.
The previous hints, from the 2026-09-03 run plus locally measured guesses for scripts added since, had drifted enough that the shard they balanced to 1078 s each actually ran 833 s to 1177 s of script time, with `portable-serial-2of4` the critical path on all three runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints affect balance and the shard budget guard below, never coverage: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard or a budget refusal rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured or grown scripts let one shard carry far more than another shard's real work and reach the job cap while another runner sits idle.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 36 | 917206 ms (~917.2 s) |
| `portable-serial-2of4` | 36 | 917197 ms (~917.2 s) |
| `portable-serial-3of4` | 36 | 917195 ms (~917.2 s) |
| `portable-serial-4of4` | 36 | 917194 ms (~917.2 s) |
| imbalance | | 12 ms |

The single longest script, `tests/fm-watch-triage.test.sh` at 247132 ms, is the floor for any shard count.

### Measured lane times and the 2026-09-07 rebalance

The per-lane script time (`summary.duration_ms` of each lane artifact) on the three runs above, before the rebalance, was:

| Lane | 34036430465 | 34064555580 | 34073321294 |
|---|---:|---:|---:|
| `portable-parallel-1` | 164.9 s | 213.2 s | 215.0 s |
| `portable-parallel-2` | 158.1 s | 170.5 s | 166.3 s |
| `portable-serial-1of4` | 883.4 s | 733.0 s | 855.1 s |
| `portable-serial-2of4` | 1147.4 s | 1054.7 s | 1176.7 s |
| `portable-serial-3of4` | 935.2 s | 699.5 s | 833.6 s |
| `portable-serial-4of4` | 818.8 s | 939.3 s | 948.5 s |
| `real-herdr-gated` | 532.6 s | 496.7 s | 537.9 s |

`portable-serial-2of4` was the critical path each time; on run 34073321294 its job wall was 19m46s against 14m03s to 15m59s for the other three shards.
Its two largest suites were `tests/fm-watch-triage.test.sh` (249 s) and `tests/fm-session-start.test.sh` (159 s), and after them `tests/fm-control-relaunch.test.sh` (94 s), `tests/fm-procevent.test.sh` (68 s), `tests/fm-sessionstart-nudge.test.sh` (65 s), and `tests/fm-pi-watch-extension.test.sh` (65 s).
Profiling `tests/fm-watch-triage.test.sh` per case showed its cost spread over about 90 cases that each wait for at least one real watcher poll at the suite's tight one-second cadence, with the largest single case (five invalid pane-churn deadline variants at a three-second poll) at 13 s; the suite contained one fixed pause, now replaced by waiting for the observable poll cycle it stood in for.
`tests/fm-session-start.test.sh` runs the real digest per case; its two fixed waits (a one-second network-wake poll granularity and a one-second settle before a hung-subprocess sweep) were replaced by tenth-second polls under the same deadlines.
Neither suite's poll cadence was changed: those are the watcher and digest contracts under test, not guessed sleeps.
Local before and after runs of both suites on one machine measured `tests/fm-watch-triage.test.sh` at 301 s before and 291 s after, and the first 34 cases of `tests/fm-session-start.test.sh` at 114 s in both, so those wait replacements are a correctness improvement inside run-to-run noise, and the rebalance below is what carries the expected critical-path reduction.

The rebalance refreshed the hints only; no lane was added and no concurrency was raised.
Replaying the same measured per-script durations from run 34073321294 through the refreshed partition predicts 986.9 s, 942.1 s, 948.3 s, and 928.7 s for shards 1 to 4, a critical shard of 986.9 s against the measured 1176.7 s (about 16 % less script time on the critical path), and by three-run means 917.2 s against 1087.8 s (about 16 %).
That is the expected effect of the measured redistribution, not a measured result: record the first post-rebalance runs' per-lane times here at the next hint refresh, and expect the same +27 % run-to-run spread noted under Timeouts.

Refresh the hints by downloading the per-shard timing artifacts from the latest few green `main` CI runs whose shard artifacts together cover every serial script (three, as above, damps the per-run spread; one run works but bakes its spread into the partition), replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with each script's mean `duration_ms` over the runs that carried it, and updating the table above from `--serial-shard-loads`:

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
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | job `timeout-minutes: 30` | Each balanced shard is about 15 minutes of hinted script time (the shard table above owns the exact figure), and the same scripts varied by about +27 % between two runs, so the former 20-minute cap sat inside normal spread and cancelled healthy shards; 30 minutes gives about 2x hang-tripwire margin for job setup and runner-speed spread, and the coverage guard's shard budget of 66 % of the cap keeps hinted work at or below 19.8 minutes, which at +27 % still finishes with several minutes to spare. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers, except the portable serial cap, which `bin/fm-test-run.sh` states and the workflow must match.
