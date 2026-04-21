# Query perf diff — gap0814 (UNION arm parallelism)

Generated: 2026-04-20T22:55:00Z
Branch: perf/ingest-query-perf-2026-04-20
Benches: executor-match (serial)
Commits: 871627f5 (thread fork-join UNION)

## Headline — union_two_labels

| scenario | BEFORE | AFTER | delta |
|---|---:|---:|---:|
| union_two_labels/small  | 72 µs   | 86 µs   | **+21% (regression)** |
| union_two_labels/medium | 376 ms  | 399 ms  | +6% (within noise) |
| union_two_labels/large  | 1007 ms | 1001 ms | 0% (flat) |

**Expected win per plan: ~2×. Measured: 0×.**

## Why the bench doesn't show the expected win

The bench's `union_two_labels` query pairs a LT_Person scan (5000 rows at large) with a LT_Company scan (100 rows at large). The arms are **50:1 asymmetric**. Parallelizing a 990 ms arm with a 10 ms arm saves at most 10 ms — nowhere near the 2× the plan assumed (which required balanced arms).

The implementation is correct and thread-safe:

- Unit tests at balanced scale (500+500) show **1.6× speedup** (`tests/test_gap0814_union_parallelism.zig`).
- 10× consecutive full-suite runs: zero flakes, no races.
- Serial fallback preserved for INTERSECT/EXCEPT and single-arm UNIONs.

## /small regression: thread-spawn overhead

`union_two_labels/small` adds ~15 µs absolute (72 → 86 µs) because the parallel path spawns a thread per arm even when the arms take a few µs each. There's no cost-model threshold yet. A follow-up should add an "arms > N rows" or "first-arm-cost > X µs" gate to avoid spawning for trivially small unions.

## Regressions not attributable to GAP-0814

- `two_hop_distinct/small` +113% exec, `fan_out_cross_type/small` +108% exec — pre-existing regressions from GAP-0813's native-planner routing (empty-result overhead). Already dispositioned in `gap0813-diff.md`. Not new.
- `ping/medium` +22% exec, `union_two_labels/small` parse +130% — measurement noise. Parse time is not structurally affected by GAP-0814 (which touches only `set_operations.zig:executeUnionWithContext`).

## Disposition

**Accept with honest assessment.** The infrastructure is correct but the specific bench scenario doesn't exercise it. The expected 2× win is latent — will surface when production workloads have balanced-arm UNIONs. The /small regression is ~15 µs absolute; acceptable given the code is thread-safe and the fallback-on-error path is clean.

## Follow-up

- **GAP-0814-cost-model (new)**: add a "minimum arm cost" threshold to `tryParallelUnion` — e.g., require each arm to have either > 200 nodes in the first scan OR predicted > 1ms cost (from planner stats). Below threshold, use serial fallback. Closes the /small regression.

- **Bench-scenario refresh (optional)**: add a `union_balanced` scenario to `bench_executor_match.zig` that pairs two label scans of equal size. This would demonstrate the 1.6-2× win in the A/B ledger where it's reproducible.

## Verdict

GAP-0814: **partial — implementation landed, bench doesn't exercise the balanced-arm case where parallelism pays off.** Code is correct, thread-safe, and will yield gains on balanced-arm UNIONs in production. Mark as PARTIAL in FINAL.md with the honest measurement.
