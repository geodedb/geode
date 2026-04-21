# Query perf diff — gap0815 (batch-CREATE fast path)

Generated: 2026-04-20T23:25:00Z
Branch: perf/ingest-query-perf-2026-04-20
Benches: executor-mutation (serial)
Commits: fa5e5bef (homogeneous-batch detection + executor)

## Headline — mutation scenarios (µs p50)

| scenario | BEFORE | AFTER | delta |
|---|---:|---:|---:|
| create_single    | 731 µs | 740 µs | +1% (noise) |
| create_batch_100 | 88569 µs | 88558 µs | 0% (flat) |
| set_property     | 303 µs | 297 µs | -2% (noise) |
| delete_single    | 292 µs | 288 µs | -1% (noise) |
| merge_single     | 685 µs | 672 µs | -2% (noise) |
| create_edge      | 531 µs | 535 µs | +0.8% (noise) |

**No regressions detected by compare-bench across all 48 rows.**

## Why create_batch_100 didn't move

The bench scenario runs 100 separate `CREATE (:LT_Person {...})` queries in a Zig for-loop — each query has exactly 1 CREATE clause. The new fast path requires N ≥ 3 inline comma-separated clauses WITHIN A SINGLE QUERY (i.e., `CREATE (:L {...}), (:L {...}), (:L {...})`). The bench's shape matches a real-world pattern (bulk-ingest via one statement at a time, typically driven by a client loop) but NOT the shape the GAP-0815 fast path optimizes (a single batch-CREATE statement).

The fast path IS correct and delivers a measurable win at unit-test scale:

- Forced serial 100-clause CREATE: ~750 ms (Debug)
- Homogeneous fast path, 100 clauses: ~470 ms (Debug) — **~35% improvement**

(ReleaseFast improvement is smaller because the serial path's per-clause overhead is mostly mutex acquisition, which is cheaper on release.)

## Mechanism

`detectHomogeneousCreateBatch` gates on:

- all inline CREATE clauses share the same label set (multi-label allowed if all clauses have identical ordered label list)
- all clauses share the same prop-key set (in the same order)
- no clause has hops, no named vars, no MATCH-bound refs, no WITH/SET/REMOVE/RETURN entanglement
- N ≥ 3 (below that, serial path's overhead is noise)

On hit: batch the property-set calls under a single mutex per key using `setNodePropertiesBatch` (plus per-node undo log + auto-index creation + FLE encryption — all preserved). `create_single` remains untouched because `chains.len < 3` fails the gate immediately.

## Disposition

**Accept.** No regressions. The optimization applies to a real workload shape (bulk-ingest via single statement); the existing bench scenario doesn't exercise it but the unit tests do. A deeper adapter-level `createNodesBatch` (one mutex acquisition for N slot allocations) would deliver the 3-10× the plan targeted — deferred as out-of-scope follow-up.

## Follow-ups

- **GAP-0815-deep (new)**: add `StorageAdapter.createNodesBatch(labels[], graph, n)` that allocates N slots + appends label-index entries + initializes per-node state under ONE mutex acquisition. Today, `createNodeWithGraph` takes the graph-adapter mutex per call — the dominant cost at high N. This is the path to 3-10× on the homogeneous-batch shape.

- **Bench scenario refresh (optional)**: `bench_executor_mutation.zig` could add a `create_inline_100` scenario that does `CREATE (:L {...}), (:L {...}), ... × 100` in one statement, alongside the existing `create_batch_100` that loops 100 single queries. This would make the A/B reflect the actual scope of GAP-0815's optimization.

## Verdict

GAP-0815: **partial — implementation correct and test-covered, bench scenario doesn't exercise it.** Mark as PARTIAL in FINAL.md.
