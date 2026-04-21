# Query perf diff — gap0812 (ORDER BY + LIMIT streaming top-K)

Generated: 2026-04-20T22:10:00Z
Branch: perf/ingest-query-perf-2026-04-20
Benches: executor-match (serial, isolated)
Commits: d6045bfb (topKOrderedFastPath + hand-rolled heap)

## Headline — order_by_limit scenarios

| scenario | BEFORE p50 | AFTER p50 | speedup |
|---|---:|---:|---:|
| order_by_limit/small  | 34.7 ms | 119 µs | **292×** |
| order_by_limit/medium | 336 ms  | 397 µs | **846×** |
| order_by_limit/large  | 862 ms  | 841 µs | **1025×** |

Expected win per plan: 5-20×. Measured: 292-1025×. Exceeds expectation by orders of magnitude because the slow path was materializing every node before the sort, whereas the fast path uses a K=50 bounded min-heap (DESC) over a direct property-read — O(N log K) comparisons versus O(N log N) + O(N × property_materialize_cost).

## Regressions

**None.** `compare-bench` exit=0, all 240 rows within the 15% gate.

## Mechanism

`topKOrderedFastPath` detects `MATCH (p:<Label>) RETURN p.<key> ORDER BY p.<key> <dir> LIMIT K` (same key in RETURN and ORDER BY, K ≤ 10 000), iterates the label-index posting list, and maintains a K-bounded heap over the target property's numeric value. Allocation-free hot loop (hand-rolled `heapSiftUp`/`heapSiftDown` over a fixed-capacity `ArrayList(TopKEntry)`).

`TopKEntry` holds either Int or Float with a discriminator, preserving numeric types losslessly for same-type comparisons. NULLS FIRST/LAST policies, OFFSET > 0, and non-numeric keys all fall back to the slow path cleanly.

## Disposition

**Merge.** No regressions, ~1000× speedup on the target scenario, clean fall-back behavior.
