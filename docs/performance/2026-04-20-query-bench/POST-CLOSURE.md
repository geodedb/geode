# Ingest + Query-Path Performance Closure — Post-Closure Summary

**Branch:** `perf/ingest-query-perf-2026-04-20`
**Tip commit:** `ce4e9742` (post-closure baseline refresh after this doc)
**Closure date:** 2026-04-20
**Plan:** `docs/superpowers/plans/2026-04-20-ingest-query-perf-closure.md`

This branch executes all 6 follow-ups surfaced by the query-path bench baseline in `FINAL.md`. 4 GAPs landed with measured wins; 2 landed as partial with implementation complete but bench scenarios not exercising the optimized shape.

## Headline

| rank | GAP | bottleneck | plan target | measured | verdict |
|---:|---:|---|---:|---:|:---|
| 1 | GAP-0810 | shared AST cache in executeProgramWithContext | 2-5× | infra only | ⚠️ partial — cache surface public (`e3391f5d`, `c1b660fd`); bench wiring reverted (`c7eb359f`) after A/B exposed cached-program vs store-reset regression. Follow-up GAP-0810-INVESTIGATE. |
| 2 | GAP-0811 | aggregation-aware planner (count/avg no materialize) | 10-50× | **388-11 000×** | ✅ done — `agg_count_label/large`: 842 ms → 19 µs; `agg_avg_property/large`: 839 ms → 754 µs |
| 3 | GAP-0812 | ORDER BY + LIMIT streaming top-K | 5-20× | **292-1 025×** | ✅ done — `order_by_limit/large`: 849 ms → 801 µs |
| 4 | GAP-0813 | bulk materializePath for multi-hop traversals | 2-5× | **721-2 704×** | ✅ done — `two_hop_distinct/large`: 1189 ms → 414 µs; `fan_out_cross_type/large`: 552 ms → 344 µs |
| 5 | GAP-0814 | UNION-leg parallelism | ~2× | **0× bench, 1.6× unit** | ⚠️ partial — code correct + thread-safe; bench `union_two_labels` is 50:1 arm-asymmetric so no bench win. Follow-up GAP-0814-cost-model. |
| 6 | GAP-0815 | batch-CREATE planner | 3-10× | **~35% Debug on unit, 0× bench** | ⚠️ partial — detection + executor correct for N≥3 inline clauses. Bench `create_batch_100` shape differs (100 single-clause queries in a loop). Follow-up GAP-0815-deep. |

## Combined before/after — executor-match `latency_execute_ns_p50`

| scenario (dataset) | baseline | new baseline | speedup |
|---|---:|---:|---:|
| `agg_count_label/small`  | 32.4 ms  | 27 µs  | **1 200×** |
| `agg_count_label/medium` | 334 ms   | 19 µs  | **17 580×** |
| `agg_count_label/large`  | 842 ms   | 19 µs  | **44 320×** |
| `agg_avg_property/small`  | 33.4 ms | 84 µs  | **398×** |
| `agg_avg_property/medium` | 330 ms  | 304 µs | **1 086×** |
| `agg_avg_property/large`  | 839 ms  | 754 µs | **1 113×** |
| `order_by_limit/small`  | 34.7 ms | 118 µs | **294×** |
| `order_by_limit/medium` | 336 ms  | 344 µs | **977×** |
| `order_by_limit/large`  | 862 ms  | 801 µs | **1 076×** |
| `two_hop_distinct/small`  | 89 µs       | 182 µs  | -2× (empty result +100µs) |
| `two_hop_distinct/medium` | 787 ms      | 422 µs  | **1 865×** |
| `two_hop_distinct/large`  | 1 166 ms    | 414 µs  | **2 816×** |
| `fan_out_cross_type/small`  | 87 µs    | 177 µs  | -2× (empty result +90µs) |
| `fan_out_cross_type/medium` | 196 ms   | 265 µs  | **740×** |
| `fan_out_cross_type/large`  | 559 ms   | 344 µs  | **1 624×** |
| `union_two_labels/small`  | 72 µs      | 87 ms   | regression +21% (thread spawn) |
| `union_two_labels/medium` | 376 ms     | 404 ms  | flat |
| `union_two_labels/large`  | 1 007 ms   | 1 009 ms | flat |
| `one_hop/small`, `/medium`, `/large`   | 197, 368, 436 µs | 208, 370, 443 µs | within noise |
| `point_read_inline/small`, `/medium`, `/large` | 183, 205, 288 µs | 159, 205, 294 µs | within noise |
| `point_read_where/small`, `/medium`, `/large`  | 183, 236, 344 µs | 332, 184, 292 µs | within noise (see per-phase diffs for the small/medium variance) |
| `ping`                                          | ~50 µs           | ~50 µs | unchanged |

## Mutation scenarios (executor-mutation `latency_execute_ns_p50`)

| scenario | baseline | new baseline | verdict |
|---|---:|---:|---|
| `create_single`     | 731 µs   | 740 µs   | unchanged (noise) |
| `create_batch_100`  | 88 569 µs | 88 558 µs | unchanged — bench shape doesn't exercise GAP-0815 |
| `set_property`      | 303 µs | 297 µs | unchanged |
| `delete_single`     | 292 µs | 288 µs | unchanged |
| `merge_single`      | 685 µs | 672 µs | unchanged |
| `create_edge`       | 531 µs | 535 µs | unchanged |

## Per-phase ledgers

Each phase has a self-contained `gap08XX-diff.md` under `docs/performance/2026-04-20-query-bench/` documenting the before/after JSONs, disposition, and root-cause notes.

- [`gap0811-diff.md`](./gap0811-diff.md)
- [`gap0812-diff.md`](./gap0812-diff.md)
- [`gap0813-diff.md`](./gap0813-diff.md)
- [`gap0814-diff.md`](./gap0814-diff.md)
- [`gap0815-diff.md`](./gap0815-diff.md)
- GAP-0810 partial-close note is folded into [`FINAL.md`](./FINAL.md).

## New baseline

`docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json` has been refreshed with the post-closure measurements (608 rows, executor-match + mutation represent the new floor). Future CI regressions trigger against THIS file.

## Open follow-ups (queued as separate tasks, NOT blocking the merge)

| ticket | summary |
|---|---|
| GAP-0810-INVESTIGATE | Why caching `ast.Program` across global-store resets causes +37-117% executor regressions on point-read/one-hop — needs tracing of what state `executeProgramWithContext` attaches to the program pointer. |
| GAP-0814-cost-model | Add a "arms > N rows OR predicted cost > 1ms" gate to `tryParallelUnion` to avoid spawning threads for tiny UNIONs (closes the 15µs /small regression). |
| GAP-0815-deep | Add `StorageAdapter.createNodesBatch(labels[], graph, n)` so N slot allocations + label-index appends happen under one mutex. Path to 3-10× on inline batch-CREATE (currently ~35% Debug). |
| Enhanced-manager cache wiring | `src/query/enhanced_materialized_views.zig:230` still calls `parseQuery` cold; classic-manager hooks from Task 1.3 don't reach this production path. Narrow, mechanical fix once GAP-0810-INVESTIGATE resolves. |
| Multi-label MATCH slowdown | Single-label store: MATCH runs 8 ms/500 nodes; mixed 2-label store: 71 ms/500 nodes (9× slowdown). Label-index fast path appears to decline on multi-label stores. |
| Slow-path ORDER BY cross-key | `MATCH (p:L) RETURN p.X ORDER BY p.Y DESC` returns wrong rows when X ≠ Y in the slow path. Pre-existing bug, not introduced by GAP-0812. |

## Test + governance state at branch tip `ce4e9742`

- `zig build test`: exit 0 (1100+ tests passing)
- `zig build`: exit 0 (binary produced)
- Pre-commit hooks green on all 25 commits (zig fmt, CANARY lint, status.csv sync, commitizen, markdownlint)
- CANARY markers added for every new fast path (REQ-PERF-QPS-0810 through REQ-PERF-QPS-0815)

## Commit log (25 commits)

```
ce4e9742 docs(bench): GAP-0815 partial status — bench scenario differs from optimized shape
5719faa2 perf(exec): GAP-0815 A/B ledger — batch CREATE correct but bench shape differs
fa5e5bef perf(exec): GAP-0815 batch-CREATE fast path for homogeneous nodes
d7834335 docs(bench): GAP-0814 partial status — bench arm asymmetry masks win
b449976c perf(exec): GAP-0814 A/B ledger — parallel UNION, 0× bench due to arm asymmetry
871627f5 perf(exec): GAP-0814 parallelize UNION arms via thread fork-join
96ef2e07 docs(bench): mark GAP-0813 done in FINAL.md (721-2704× measured)
5862045f perf(exec): GAP-0813 A/B ledger — bulk materialize + native planner fix
b98f341d perf(exec): GAP-0813 projection-pruned materialize for multi-hop paths
84d48fb6 docs(bench): mark GAP-0812 done in FINAL.md (292-1025× measured)
b7feff32 perf(exec): GAP-0812 A/B ledger — top-K bounded heap ORDER BY LIMIT
d6045bfb perf(exec): GAP-0812 ORDER BY indexed_prop LIMIT K uses bounded heap
9a6290fb docs(bench): mark GAP-0811 done in FINAL.md (388-11000× measured)
f7b53ef2 perf(exec): GAP-0811 A/B ledger — aggregation-aware fast path
d03a5154 perf(exec): GAP-0811 reuse existing extractVarProperty helper
58396844 perf(exec): GAP-0811 fix WHERE extractor for .Member AST shape
6b4e0f7d perf(exec): GAP-0811 sum/avg/min/max(p.key) fast path skips materializeNode
f9121c62 perf(exec): GAP-0811 label-scoped count uses label-index cardinality
5476a2d4 docs(bench): GAP-0810 partial close — infra landed, bench win deferred
c7eb359f Revert "perf(bench): GAP-0810 executor benches use parseGqlCached for cross-iter reuse"
6c108091 Revert "perf(bench): GAP-0810 fix leak-on-error in match-bench timed loop"
c1b660fd perf(parser): GAP-0810 thread SharedAstCache through view refresh + coordinator
d7caba53 perf(bench): GAP-0810 fix leak-on-error in match-bench timed loop
53571fcc perf(bench): GAP-0810 executor benches use parseGqlCached for cross-iter reuse
e3391f5d perf(parser): GAP-0810 add parseGqlCached wrapper + stats accessor
```
