# Query Path Benchmark — Design

## Why a separate framework

The existing `benchmarks/bench_schema.zig` + `zig build compare-bench` (M0.4 / M0.6) handle generic result-document JSON and A/B diffing. They do NOT know about query lifecycle. This plan adds a query-specific scenario spec + runner on top of the generic schema so every bench emits the same `ResultRow` shape while capturing parse / plan / execute phase timings separately.

## Scenario catalog (10 canonical queries)

Same shapes across parser / planner / executor layers so results stack:

1. `ping` — `RETURN 1 AS x` (baseline, no data access)
2. `point_read_inline` — `MATCH (p:LT_Person {lt_id: $id}) RETURN p.name, p.age` (GAP-0808 fast path)
3. `point_read_where` — `MATCH (p:LT_Person) WHERE p.lt_id = $id RETURN p.name` (label-scan path)
4. `one_hop` — `MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b) RETURN b.name, b.age`
5. `two_hop_distinct` — `MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name, c.lt_id LIMIT 20`
6. `fan_out_cross_type` — `MATCH (p:LT_Person {lt_id: $id})-[:LT_KNOWS]->(f)-[:LT_WORKS_AT]->(c:LT_Company) RETURN DISTINCT c.name LIMIT 10`
7. `agg_count_label` — `MATCH (p:LT_Person) RETURN count(p) AS n` (pure aggregation)
8. `agg_avg_property` — `MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age) AS mean_age`
9. `order_by_limit` — `MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50`
10. `union_two_labels` — `MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id`

## Dataset sizes

Three fixed sizes for executor benches: `small=500 nodes`, `medium=2000 nodes + 8000 edges`, `large=10000 nodes + 30000 edges`. Each scenario runs against each size. Seeded deterministically by `query_datasets.zig` (same shapes as the loadtest's point_read / two_hop / fan_out so results compare directly).

## Measurements (per scenario × dataset)

Extended `QueryResultRow` (lives in `common_query.zig`; serializes via `bench_schema.ResultDocument`):

- `scenario_name`, `variant`, `dataset_size` (string: small/medium/large)
- `iterations`, `warmup_iterations` (typically 7 + 1 warmup, same as bench-timeseries)
- `wall_time_ns_median`, `wall_time_ns_stddev`
- `throughput_ops_per_sec`, `throughput_stddev_ops_per_sec`
- `parse_ns_per_op_p50`, `plan_ns_per_op_p50`, `execute_ns_per_op_p50` (phase timings — planner and executor benches only)
- `materialize_ns_per_op_p50` (executor-match bench only)
- `row_count_p50` (correctness sanity — should be stable across variants)
- `plan_cache_hits`, `plan_cache_misses` (planner bench only)
- `alloc_count_per_op`, `alloc_bytes_per_op` (via DebugAllocator stats in Debug mode only)
- `peak_rss_delta_bytes` (delta between warmup-end and run-end, mirrors thread-pool pattern)

## Noise gate

Reuse `zig build compare-bench`'s `max(15%, 3σ)` rule. Higher-is-better prefixes: `throughput_`, `plan_cache_hit_rate`. Lower-is-better prefixes: `latency_`, `wall_time_`, `*_ns_per_op`, `alloc_`, `peak_rss_`.

## Variant axis

Initially a single variant `default`. Reserved for future A/B sweeps (e.g. fast-path on/off, arena scratch size, RLS on/off).
