# query-bench baseline refresh — 2026-05-11 (group-commit default)

`baseline/bench-query-all.json` was refreshed from a clean CI run on
commit `d7a17a6e` (pipeline #2516770059, "Company Cluster Runner(s)").

## Why

The previous baseline was captured ~2026-04-21 (commit `ce4e9742`,
roll-up commit `e5c04c26`) — **before** commit `24db46c5` (2026-04-23)
made the group-commit coordinator the default (`group_commit.isEnabled()`
returns true unless `GEODE_GROUP_COMMIT=0`), and before the Phase-2
`ShardedCoordinator` work.

`bench-query-path` runs with group commit on (it does not set
`GEODE_GROUP_COMMIT=0`). The `executor-mutation` micro-benches issue one
mutation at a time (or a single 100-node batch) in a tight loop with no
concurrency — the worst case for a batched-commit coordinator: every op
waits a flush window instead of committing inline. So `compare-bench`
flagged 18 "regressions" against the old inline-commit baseline:

| scenario | old (inline) | new (group-commit) | ratio |
|---|---:|---:|---:|
| `create_single` throughput | ~1306 ops/s | ~21 ops/s | ~62x slower |
| `create_batch_100` throughput | (n/a) | ~0.20 batch/s | -- |
| `set_property` throughput | -- | ~121 ops/s | -- |
| `delete_single` throughput | -- | ~121 ops/s | -- |
| `merge_single` throughput | -- | ~24 ops/s | -- |
| `create_edge` throughput | -- | ~15 ops/s | ~108x slower |

Reads/match got **faster** over the same window (parse-cache + RLS
row-buffer reuse), e.g. `executor-match latency_execute` -67% -- so the
slowdown is specific to the commit path, not a CPU-throttled runner.

This is the intended architecture (group commit raises throughput under
concurrent writers; the single-threaded micro-bench just doesn't model
that), so the fix is a re-baseline, not a code change. The match/parser/
planner rows in the refreshed baseline remain real regression detectors.

## Surfaced because of the CI timeout fix

`bench-query-path` had been hitting its 1h `job_execution_timeout` on the
slow shared runners for weeks (it never reached `compare-bench`). Pipeline
#2516770059 bumped the job to 2h and pinned it to the fast pool, so it ran
to completion for the first time and exposed the stale baseline.

## Future work

If a single-run baseline proves too noisy for the I/O-bound mutation rows
(gates collapse to the 15% floor when `value_stddev=0`), either capture a
multi-run median baseline or have `bench_executor_mutation.zig` batch its
ops so the numbers reflect the coordinator's batched throughput rather
than its per-op latency.
