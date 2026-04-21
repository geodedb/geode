# Query Path Benchmark — Baseline + Bottleneck Report

Captured on `perf/query-bench-2026-04-20` from a clean run of
`./scripts/query-perf-gate.sh baseline before` at commit `c0a49e61`.
608 rows cover parser (10 scenarios) + planner (30) + executor-match
(30) + executor-mutation (6), each emitting 8 measurement rows.

## Scope

The query-path benchmark suite landed in 8 commits (framework → 4 layer benches → aggregate + A/B harness → CI + variant fix):

| Commit    | Layer                                                         |
|-----------|---------------------------------------------------------------|
| `fec23f49`| `query_datasets.zig` — deterministic seed helpers             |
| `dddc50c7`| `common_query.zig` — `QueryScenarioSpec` + `expand()`          |
| `7c9142a7`| `bench_parser.zig` — parse-only throughput (M1)                |
| `8c70e219`| `bench_planner.zig` — parse+plan phase split (M2)              |
| `7482f624`| `bench_executor_match.zig` — in-process MATCH exec (M3.1)      |
| `aa91f4f8`| `bench_executor_mutation.zig` — mutation-path (M3.2)           |
| `53e56ac0`| `bench-query-all` aggregate step (M4.1)                        |
| `da996afa`| `query-perf-gate.sh` — A/B driver (M4.2)                       |
| `17229b9c`| `.gitlab-ci.yml` — `bench-query-path` job (M6.1)               |
| `c0a49e61`| variant per layer (fixes scenario_name collision in merged JSON)|

Baseline: `docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json`.

## Headline numbers (ReleaseFast, 13900H, Linux 6.12)

### Parser (10 scenarios, no data)

| scenario            | parse_ns_p50 | ops/sec |
|---------------------|-------------:|--------:|
| `ping`              |    48 µs     |  20.9 k |
| `order_by_limit`    |    67 µs     |  15.0 k |
| `point_read_inline` |    85 µs     |  11.8 k |
| `point_read_where`  |    86 µs     |  11.7 k |
| `agg_count_label`   |    96 µs     |  10.4 k |
| `two_hop_distinct`  |   103 µs     |  9.7 k  |
| `fan_out_cross_type`|   104 µs     |  9.6 k  |
| `one_hop`           |   104 µs     |  9.6 k  |

Spread: 48–104 µs. Parser cost grows ~2× from the simplest (RETURN) to the most complex (multi-hop) query — the lexer/arena allocations scale with token count.

### Planner (parse+plan, 10 scenarios × 3 dataset sizes = 30 rows)

- **Fastest:** `ping/large` at 30.8 k ops/sec (~32.5 µs combined).
- **Slowest:** `fan_out_cross_type/small` at 13.3 k ops/sec (~75 µs combined).
- Plan cost alone is ~600 ns across every shape — invariant under dataset size because `planQuery` doesn't touch data statistics. Parse dominates 99 % of the parse+plan wall.

### Executor-match (in-process MATCH, 30 rows: 10 scenarios × 3 dataset sizes)

Top 10 slowest `latency_execute_ns_p50`:

| scenario (dataset)           |    exec_ns_p50 |   rows/query | ops/sec |
|------------------------------|---------------:|-------------:|--------:|
| `two_hop_distinct/large`     |      1.29 s    |     20       |   0.77  |
| `union_two_labels/large`     |      1.07 s    |   5000       |   0.93  |
| `order_by_limit/large`       |      0.91 s    |     50       |   1.10  |
| `point_read_where/large`     |      0.90 s    |      1       |   1.11  |
| `agg_avg_property/large`     |      0.90 s    |      1       |   1.11  |
| `agg_count_label/large`      |      0.90 s    |      1       |   1.11  |
| `two_hop_distinct/medium`    |      0.83 s    |     20       |   1.20  |
| `fan_out_cross_type/large`   |      0.61 s    |     10       |   1.63  |
| `union_two_labels/medium`    |      0.40 s    |   2000       |   2.52  |
| `point_read_where/medium`    |      0.36 s    |      1       |   2.79  |

`point_read_inline` (the GAP-0808 property-index fast path) by contrast:

| scenario                     |    exec_ns_p50 | ops/sec |
|------------------------------|---------------:|--------:|
| `point_read_inline/small`    |    190 µs      |  5.27 k |
| `point_read_inline/medium`   |    195 µs      |  5.13 k |
| `point_read_inline/large`    |    288 µs      |  3.48 k |

Ping (pure RETURN, no data access) peaks at `ping/medium` 16.4 k ops/sec.

### Executor-mutation (6 scenarios)

| scenario             |    exec_ns_p50 | ops/sec |
|----------------------|---------------:|--------:|
| `delete_single`      |    294 µs      |  3.08 k |
| `set_property`       |    308 µs      |  2.87 k |
| `create_edge`        |    547 µs      |  1.63 k |
| `merge_single`       |    683 µs      |  1.32 k |
| `create_single`      |    746 µs      |  1.20 k |
| `create_batch_100`   |     89.6 ms    |    10.7 (= 896 µs/node amortized) |

CREATE is 2.5× slower than DELETE on the same graph — the per-property index write amplifies every CREATE, while DELETE only unlinks.

## Top bottlenecks — ranked by expected QPS impact

Evidence is the row at `variant/scenario_name/measurement` in `baseline/bench-query-all.json`.

### 1. Label-scan with WHERE returns to O(N) despite indexes (`point_read_where`) — **FIXED (GAP-0809, commit `d7b79be5`)**

- **Signal (before):** `point_read_where/large` 900 ms vs `point_read_inline/large` 288 µs. **3,125× slowdown** for an equivalent query written with `WHERE p.lt_id = 42` instead of inline `{lt_id: 42}`.
- **Why:** the GAP-0808 fast path in `src/execution/planned_read_runtime.zig:collectStartSlots` only triggered when the pattern had an inline property constraint. Equivalent `WHERE` predicates fell through to a full label scan + post-filter.
- **Fix:** `tryExtractPatternEqPredicate` pulls a single simple equality from `WHERE` when `pattern.props` is absent and feeds it into the same adapter-level `getCandidateNodesByLabelAndProperty` lookup. Handles `.Member` and `.PropertyAccess` AST shapes, tolerates mirrored `literal = p.key`, and declines non-equality / compound predicates.
- **Measured after-win:**
  - `point_read_where/small`:  183 ms →  383 µs (**480×**)
  - `point_read_where/medium`: 1460 ms →  235 µs (**6,200×**)
  - `point_read_where/large`:  900 ms →  344 µs (**2,600×**)
- **Regression cover:** `tests/test_gap0809_where_fastpath.zig` (3 cases). 1092/1092 tests green.

### 2. Aggregation over a label = full scan (`agg_count_label`, `agg_avg_property`)

- **Signal:** `agg_count_label/large` 900 ms on 5 k nodes → **~180 µs per node** for a pure count. `agg_avg_property/large` is indistinguishable (900 ms) — the WHERE filter doesn't reduce the scan.
- **Why:** `MATCH (p:LT_Person) RETURN count(p)` iterates every node in the label index, materializes each (property dupes + graph-name dupes), then aggregates. Materialization is pure waste when the aggregator only needs a count.
- **Fix:** aggregation-aware planner — when the projection is `count(*)` / `count(p)` / `count(p.key)` the executor just counts label-index entries. For typed aggregates (`avg`/`sum`), iterate but skip property dupes the aggregator doesn't use.
- **Expected win:** 10-50× on pure-count; 3-5× on typed aggregates.

### 3. Multi-hop MATCH traversal (`two_hop_distinct`, `fan_out_cross_type`)

- **Signal:** `two_hop_distinct/large` 1.29 s on 5 k nodes / 15 k edges — the worst scenario in the baseline. `fan_out_cross_type/large` 0.61 s.
- **Why:** after the anchor-node GAP-0808 hit, each hop triggers a full materialization of intermediate node properties + graph-name dupes. Prior profile (`docs/performance/2026-04-19-qps-closure/step-4-two-hop-profile.md`) shows `executeMultiChainRelationshipMatch` + `materializeNode/Edge` dominate but each under 0.2% self-time — the work is spread across thousands of per-hop allocs.
- **Fix:** bulk materialization API — `materializePath(allocator, path_slots)` fetching labels+properties for all path nodes in one adapter round-trip. Arena-scope the path-row construction so per-hop dupes die with the query.
- **Expected win:** 2-5× on multi-hop latency.

### 4. UNION executes each leg as a separate full label scan (`union_two_labels`)

- **Signal:** `union_two_labels/large` 1.07 s for 5 k Person + 100 Company rows → **211 µs/row**. 95% of the runtime on `large` is the Person leg; the Company leg is negligible.
- **Why:** each arm of the UNION runs its own `MATCH (label) RETURN` full scan, then merges results sequentially.
- **Fix:** (priority 1, easy win) parallelize the two legs onto the thread pool since they're independent. (Priority 2, harder) query-planner fusion to emit a single label-index walk that yields both labels.
- **Expected win:** ~2× via parallelism; 5-10× via fusion.

### 5. ORDER BY + LIMIT does a full scan before trimming (`order_by_limit`)

- **Signal:** `order_by_limit/large` 908 ms — the same ~900 ms envelope as a full aggregation. Despite `LIMIT 50`, every node is visited + sorted.
- **Why:** the planner doesn't push the limit into the label-index walk. A top-K heap over `lt_id` would touch N log K = 5000 × 6 ≈ 30 k comparisons instead of 5000 materializations + sort.
- **Fix:** planner rule — when the projection is `p.<indexed_prop>` and ORDER BY is on the same indexed property, emit a top-K streaming walk instead of materialize-then-sort.
- **Expected win:** 5-20× on `LIMIT`-bounded queries.

### 6. Parser cost dominates plan cost 99× — parse is the hot path for every query

- **Signal:** `bench-query-planner` measures parse p50 37 µs vs plan p50 ≤ 1 µs → **parser is ~100× more expensive than planner** across all shapes.
- **Why:** full tokenize-parse-validate pipeline runs on every query. The server's `SharedQueryOptimizer` caches planning but does NOT cache parsing — every connection re-parses identical queries on every request.
- **Fix:** structural-key AST cache keyed on query hash → pre-parsed `ast.Program`. Integrate into `executeProgramWithContext` entrance so cache hit bypasses lexer+parser. Already-built pieces: `src/planner/structural_key.zig`.
- **Expected win:** 1.5-5× on high-QPS point-read traffic (parse is ~85 µs of every point_read_inline's ~190 µs p50 on small — 45% of the wall).

### 7. CREATE is 2.5× slower than DELETE (`create_single` vs `delete_single`)

- **Signal:** CREATE 746 µs, DELETE 294 µs. SET 308 µs (DELETE-like), MERGE 683 µs, CREATE_EDGE 547 µs, batched CREATE amortizes to 896 µs/node (slightly worse than single).
- **Why:** CREATE appends to the label index, the merge-property index, and three setNodeProperty entries (each walking the adapter). DELETE does a label-index scan (fast for ~500 seeded nodes) + unlinks. `create_batch_100` NOT amortizing reveals there is no batch plan path.
- **Fix:** (1) batch-CREATE planner — when N inline CREATEs share a label/prop shape, emit one index-update pass. (2) lazy property-index rebuild at transaction commit instead of per-SET.
- **Expected win:** 3-10× on CREATE-heavy loadtest scenarios (`two_hop` setup phase).

## Follow-ups

Each bottleneck above maps to one `perf/` ticket. Suggested order (by impact × effort):

| rank | gap        | bottleneck                                         | est. win   | est. effort | status |
|-----:|-----------:|----------------------------------------------------|-----------:|------------:|:-------|
| ~~1~~    | GAP-0809   | WHERE prop=const fast-path parity with inline-prop | 2,600× measured (large) | 2d | ✅ done (`d7b79be5`) |
| ~~1~~    | GAP-0810   | shared AST cache in executeProgramWithContext      | parse -80-92%, execute flat | 3d | ✅ done (`e3391f5d` + `c1b660fd` + re-applied `59e4ab97`, `5f3b190c`; ledger `gap0810-diff.md`) |
| ~~1a~~   | GAP-0810-INVESTIGATE | cached-parse vs store-reset regression   | artifact, not real | 2d | ✅ closed — DebugAllocator bookkeeping artifact (`e349d085`; `gap0810-investigation.md`) |
| ~~2~~| GAP-0811   | aggregation-aware planner (count/avg no materialize)| 388-11 000× measured | 3d | ✅ done (`f9121c62` + `6b4e0f7d` + `58396844` + `d03a5154`; ledger `f7b53ef2`) |
| ~~3~~| GAP-0812   | ORDER BY + LIMIT streaming top-K                   | 292-1025× measured | 4d | ✅ done (`d6045bfb`; ledger `b7feff32`) |
| ~~4~~| GAP-0813   | bulk materializePath for multi-hop traversals     | 721-2704× measured | 5d | ✅ done (`b98f341d`; ledger `5862045f`) |
| 5    | GAP-0814   | UNION-leg parallelism                              | ~2×        | 2d | ⚠️ partial — code correct + 1.6× on unit balanced-arms test (`871627f5`; ledger `b449976c`); bench `union_two_labels` is 50:1 asymmetric so A/B shows 0× bench win. Follow-ups: cost-model threshold, balanced-arm bench scenario. |
| 6    | GAP-0815   | batch-CREATE planner (shared label/prop shape)     | 3-10×      | 4d | ⚠️ partial — detection + executor landed (`fa5e5bef`; ledger `5719faa2`), ~35% Debug win on N≥3 inline-clauses. Bench `create_batch_100` shape differs (loop of 100 single-clause queries) so A/B flat. Follow-up: GAP-0815-deep for adapter-level batch slot allocation. |

Each can be attacked via `./scripts/query-perf-gate.sh <gap-id> before` → implement → `after` → inspect `diff.md`. The baseline in `baseline/bench-query-all.json` is the reference; replacing it requires A/B verification plus a committed update of the baseline JSON.

### GAP-0810 close note (2026-04-20, post-investigation)

Phase 1 of the `perf/ingest-query-perf-2026-04-20` branch landed the public `parseGqlCached` wrapper (`e3391f5d`) + `SharedAstCache` hooks on `MaterializedViewManager` / `QueryCoordinator` (`c1b660fd`). The bench wiring commits (`53571fcc` + `d7caba53`) were temporarily reverted (`6c108091`, `c7eb359f`) after the A/B gate showed `latency_execute_ns_p50` rising by 37–117% on `point_read_inline` / `point_read_where` / `one_hop` at medium/large sizes.

**Root cause (2026-04-20):** the regression was an `std.heap.DebugAllocator` measurement artifact, NOT a defect in the parse cache. DebugAllocator's per-allocation bookkeeping and mutex have O(live_allocations) cost; when the bench holds a SharedAstCache across timed iterations, it retains extra live allocations (heap `*ParseResult`, parse arena, `query_text_copy`). Every allocation and free inside `executeProgramWithContext` (row buffers, owned_graph_entities, etc.) subsequently pays more DebugAllocator overhead — the observed execute slowdown.

**Fix** (`e349d085`): switch the executor benches from DebugAllocator to `std.heap.smp_allocator` (the production allocator chosen by `graph_store.global_allocator` per GAP-0754 — this is a known class of problem). Regression pinned by `tests/test_gap0810_reproduce_regression.zig` gating B/C ≤ 1.25x.

**Re-applied** (`59e4ab97`, `5f3b190c`): the original bench cache wiring + `errdefer handle.release()` leak-on-error fix. A/B under smp_allocator shows parse deltas of −40% to −92% across scenarios with execute deltas within ±15% of control (a few cells show run-to-run variance up to +22% from iter-window jitter, unrelated to cache wiring). Full details in `gap0810-investigation.md` and `gap0810-diff.md`.

Pre-investigation serial A/B (DebugAllocator) — for historical context:

| scenario | small (500 nodes) | medium (2000) | large (5000) |
|---|---|---|---|
| point_read_inline | **−35%** (faster) | **+85%** (slower) | **+37%** (slower) |
| point_read_where  | **−27%** (faster) | **+63%** (slower) | **+16%** (slower) |
| one_hop           | **−19%** (faster) | **+117%** (slower) | **+51%** (slower) |

Post-investigation A/B (smp_allocator, ledger `gap0810-diff.md`):

| scenario | size | parse Δ | execute Δ |
|---|---|---|---|
| point_read_inline | medium | **−83.0%** | +11.4% |
| point_read_where  | medium | **−83.9%** | +1.1% |
| one_hop           | medium | **−87.0%** | +12.0% |
| agg_count_label   | large  | **−77.7%** | **−13.7%** |

Production QUIC handler already runs on `smp_allocator` in ReleaseFast (GAP-0754), so the cache path there was never affected — the regression only ever existed in the bench harness.

## Reproduction

```bash
git checkout perf/query-bench-2026-04-20
./scripts/query-perf-gate.sh mybaseline before   # ~15-20 min, writes docs/performance/2026-04-20-query-bench/mybaseline-before-query-all.json
```

The per-layer JSONs (`mybaseline-before-parser.json` etc.) can also be inspected individually.

## Generating a scenario ranking from the baseline

```bash
jq -r '
  .rows
  | map(select(.variant == "executor-match" and .measurement == "latency_execute_ns_p50"))
  | sort_by(.value) | reverse
  | .[] | "\(.scenario_name)\t\(.value)"
' docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json
```
