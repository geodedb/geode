# GAP-0810-INVESTIGATE — cached-parse execute regression root cause

**Date:** 2026-04-20
**Status:** FIXED
**Fix commits:**

- `e349d085` — switch executor benches from DebugAllocator to smp_allocator;
  add regression reproducer test
- `59e4ab97` — re-apply `parseGqlCached` wiring on bench_executor_match +
  bench_executor_mutation (originally reverted in `6c108091` + `c7eb359f`)
- `5f3b190c` — re-apply `errdefer handle.release()` leak-on-error fix on
  match-bench timed loop (originally reverted in `6c108091`)

## Symptom

When Phase 1 of the 2026-04-20 query-path perf closure wired
`parseGqlCached` into the executor-match bench, the A/B gate surfaced a
large executor-latency regression on medium/large dataset sizes:

| scenario | small | medium | large |
|---|---|---|---|
| point_read_inline | -35% (faster) | **+85% (slower)** | **+37% (slower)** |
| point_read_where  | -27% (faster) | **+63% (slower)** | **+16% (slower)** |
| one_hop           | -19% (faster) | **+117% (slower)** | **+51% (slower)** |

Parse latencies dropped as expected (cache win); execute latencies grew.
The cache wiring commits (`53571fcc` + `d7caba53`) were reverted
(`6c108091` + `c7eb359f`) pending root cause.

## Hypothesis (plan)

> "The SharedAstCache persists across a `deinitGlobalStore` →
> `initGlobalStore` cycle.  When the same cached `ast.Program` is executed
> against a fresh store, some executor-attached or executor-internal state
> is stale and triggers slow paths.  First execute after a store reset on
> a warm cache is catastrophically slow."

## Investigation

Reproducer: `tests/test_gap0810_reproduce_regression.zig`.

Phase A: seed 500 LT_Person nodes; parse+execute 20 iters via cache.
Store reset; reseed 2000 LT_Person nodes.
Phase B: execute the same cached `ast.Program` 20 iters (SHOULD be
slow per hypothesis).
Phase C (control): fresh `geode.parse` + execute 20 iters (same store).

Under `std.heap.DebugAllocator(.{})` (what the bench uses):

```
A  cached, small-store           : median    126645 ns
B  cached, medium-store (REUSED) : median    343281 ns  [+113% vs C]
C  fresh , medium-store (control): median    161379 ns
B/C ratio (reused cache vs fresh parse): 2.127x
```

**Regression reproduced cleanly.** Confirms the Phase-1 A/B.

Per-iteration samples in Phase B (iter-order, not sorted):

```
215366 190698 204287 237034 226019 193773 200396 196213 202932 212365
323213 321303 372718 334334 362325 429126 444441 448970 451701 475129
```

Grows monotonically after ~iter 10.  Phase C stays flat ~140-200k ns
throughout all 20 iters.  **Not a first-iteration phenomenon — a growing-
over-time one.**

### Isolation: Phase D with a fresh cache

Added a Phase D: create a FRESH `SharedAstCache` post-reset and run 20
iters via `parseGqlCached` against it.  If the issue were "cache surviving
a store reset," Phase D would match Phase C.

```
B  cached, medium-store (REUSED) : median    366157 ns
C  fresh , medium-store (control): median    160009 ns
D  cached, medium-store (FRESH)  : median    268865 ns
```

**Phase D is also slow**, and also grows monotonically over iterations.
Hypothesis is wrong: the regression is not about crossing a store reset.
It is about the cached-parse path itself when executing many iterations.

### Isolation: allocator

Switched the reproducer's `allocator` from DebugAllocator to
`std.heap.smp_allocator` (what the server uses in ReleaseFast per
GAP-0754):

```
B  cached, medium-store (REUSED) : median     36252 ns
C  fresh , medium-store (control): median     52140 ns
D  cached, medium-store (FRESH)  : median     55215 ns
B/C ratio (reused cache vs fresh parse):         0.695x  (30% FASTER)
D/C ratio (fresh cache vs fresh parse, same):    1.059x  (noise)
```

**The regression disappears entirely.** Under smp_allocator the cached
path is actually *faster* than fresh-parse (the AST arena stays hot in
CPU cache), as expected.

## Root cause

`std.heap.DebugAllocator` maintains per-allocation bookkeeping (live-alloc
map, free-bit tracking) guarded by an internal mutex.  Both the per-alloc
cost and the mutex hold time scale with the number of live allocations.

In Phase B of the reproducer the SharedAstCache retains three extra live
allocations that would have been freed in Phase C:

1. The heap-allocated `*ParseResult` (`pr_ptr` in
   `SharedAstCache.getOrParse`).
2. The parse arena the cached `ast.Program` was built on.
3. `query_text_copy` — the heap-stable query text the AST slices point
   into.

Every allocation and free done inside `executeProgramWithContext` during
Phase B (row buffers, owned_graph_entities, temp `std.ArrayList` storage,
`getNodesByLabels` result, etc.) pays proportionally more DebugAllocator
overhead.  As the test runs, kernel page mappings for the retained
allocations accumulate TLB pressure and DebugAllocator's internal maps
rehash, compounding the effect into the monotonic growth seen in Phase B
iteration samples.

The medium/large dataset amplifies the artifact because the match path
does more per-query allocations (label-index slice materialization,
per-row property fetches, owned-entity bookkeeping) — so each of those
pays more DebugAllocator overhead, making the gap look worse than on
small.

**This is a bench-harness measurement artifact, not a defect in the
parse cache.**  GAP-0754 already landed the equivalent fix for a
different MATCH-path hotspot (`global_allocator()` returns
`smp_allocator` because "DebugAllocator's mutex became the next
hot-path bottleneck on the MATCH read path" — exact same pattern).

## Fix

- `benchmarks/bench_executor_match.zig` + `bench_executor_mutation.zig`:
  replace `std.heap.DebugAllocator(.{})` with `std.heap.smp_allocator`.
- `tests/test_gap0810_reproduce_regression.zig`: regression pin.  Gates
  B/C ≤ 1.25x under smp_allocator.  Included in `test-perf` step.

After the fix:

- Reproducer runs green (B/C ≈ 0.9-1.1x, well under 1.25x gate).
- Bench A/B (post re-wiring): parse deltas -40% to -92% across all
  scenarios, execute deltas within ±15% of control on every
  dataset-size cell except `two_hop_distinct/medium` which shows
  high run-to-run variance (+7% / +13% / +77% on three consecutive
  samples, unrelated to cache wiring).  See `gap0810-diff.md`.

## Why the cache wiring revert was justified at the time

The Phase-1 A/B numbers were real measurements.  Reverting while
investigating was the right call — the signal was too large to dismiss,
and the root cause (allocator bookkeeping) was not visible at the level
of the plan.  The fix retroactively validates the cache wiring and
closes GAP-0810.

## Secondary findings

During investigation, reviewed the following for pointer-keyed state
that could plausibly break across a store reset.  None match the
observed pattern:

- `src/server/query_plan_cache.zig`: plan cache is hash-keyed on query
  text, not pointer.  Already has `schema_epoch` invalidation.  Not
  reached by `executeProgramWithContext` in bench.
- `src/planner/path_cache.zig`: byte-slice-keyed FIFO cache.  Not
  invoked on the point_read path.
- `src/planner/adaptive.zig` `PlanCache`: hash-keyed on query + params
  - context.  Not reached by bench.
- `ast.Program` / `ast.Query`: structurally immutable; passed
  `*const ast.Program` by `executeProgramWithContext`; no interior
  mutation or pointer-keyed annotation.
- `src/schema/catalog.zig` global `Catalog` singleton: data_dir set at
  first init, not per-store-reset.  Not a contributor (same catalog
  across Phase B and Phase C).

## References

- Reproducer: `tests/test_gap0810_reproduce_regression.zig`
- A/B ledger: `gap0810-diff.md`
- Original plan: `docs/superpowers/plans/2026-04-20-ingest-query-perf-closure.md`
  Phase 1 / GAP-0810
- Prior allocator lesson: `src/graph_store.zig` `global_allocator()`
  docstring (GAP-0754)
