# Test evidence: baseline CI hazard remediation (41d0ab3 -> 6981a3a)

Fix 1 (Hazard A, bin/fm-spawn.sh recovery lock wait):
- herdr-presentation-e2e-postfix.log: full tests/fm-backend-herdr-presentation-e2e.test.sh in an isolated fm-lab session on Herdr 0.7.5, all 24 cases pass including the two new long-hold cases; default-session tripwire intact.
- herdr-presentation-e2e-prefix.log: same new test file run against the BASE bin/fm-spawn.sh; the long-hold recovery case fails first with the characterized message "refusing a concurrent resume" after 6 s.

Fix 2 (Hazard B2, shard hints / job cap / coverage guard):
- shard-balance-before-after.txt: base assignment weighed with the new measurements puts shard 3 at 19.4 min against a 20 min cap; target rebalances to 16.2 min per shard under a 30 min cap.
- fm-test-run-cli-transcript.txt: --serial-shard-loads, --check-coverage, what-if cap 20 fails / 25 passes, bad cap values refused with exit 2 and no temp dir left, ci.yml parsed as YAML = 30.
- fm-test-run-shard-cap-before-after.txt: the two new tests fail on the base tree and pass on the target tree; test_aggregate_json run separately.
- fm-test-run-test-postfix.log: full tests/fm-test-run.test.sh; only the pre-existing ruby-only Herdr step-timeout test fails here because ruby is absent on this host.

Fix 3 (Hazard B1, tests/fm-secondmate-reconcile.test.sh):
- secondmate-reconcile-test-postfix.log: full test file passes, including the new blocking-waiter probe.
- reconcile-busy-lock-under-load.txt: pinned to one CPU shared with 12 busy loops, the base 200 ms deadline test fails 3/3 rounds; the bounded-poll test passes 3/3.
- reconcile-busy-lock-mutation.txt: with bin/fm-secondmate-reconcile.sh mutated to genuinely wait on the control lock, the new test reports "a busy control lock blocked the reconcile path".
