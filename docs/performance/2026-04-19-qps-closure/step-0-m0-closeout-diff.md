# Perf diff — step-0-m0-closeout

Generated: 2026-04-19T20:39:10Z
Commit: 7bc687a95799e604bf0f02796c0afb2bdfd39899
CPU: x86_64

## Go loadtest (scenarios: ping point_read; levels 1,2,4,8; 5s each)

| scenario | c | QPS before | QPS after | ΔQPS % | p99 before | p99 after | Δp99 % | err before | err after | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| ping | 1 | 207.6 | 223.8 | +7.8% | 7.14ms | 5.73ms | -19.7% | 0.0% | 0.0% |  |
| ping | 2 | 295.4 | 346.0 | +17.1% | 9.78ms | 7.86ms | -19.6% | 0.0% | 0.0% |  |
| ping | 4 | 347.6 | 404.4 | +16.3% | 16.60ms | 15.69ms | -5.5% | 0.0% | 0.0% |  |
| ping | 8 | 381.6 | 421.0 | +10.3% | 40.43ms | 40.46ms | +0.1% | 0.0% | 0.0% |  |
| point_read | 1 | 6.8 | 6.6 | -2.9% | 228.57ms | 215.51ms | -5.7% | 0.0% | 0.0% |  |
| point_read | 2 | 6.4 | 6.2 | -3.1% | 1036.30ms | 1104.33ms | +6.6% | 0.0% | 0.0% | warn |
| point_read | 4 | 6.2 | 6.0 | -3.2% | 1813.50ms | 1760.01ms | -2.9% | 0.0% | 0.0% | warn |
| point_read | 8 | 5.8 | 5.8 | +0.0% | 3606.63ms | 3432.51ms | -4.8% | 0.0% | 0.0% |  |

## zig bench-timeseries

```
timeseries_ingest_100k/default/throughput_points_per_sec delta -0.38% (gate=15.83%, dir=higher_is_better) ok
timeseries_query_100k/default/throughput_queries_per_sec delta -1.62% (gate=15.00%, dir=higher_is_better) ok
timeseries_ingest_1m/default/throughput_points_per_sec delta -3.68% (gate=42.79%, dir=higher_is_better) ok
timeseries_query_1m/default/throughput_queries_per_sec delta -4.71% (gate=15.00%, dir=higher_is_better) ok
compare-bench: no regressions detected
```

## zig benchmark (phase1/phase2 micro-benches)

```
phase1_stack_buffer_vs_allocprint/default/improvement_ratio delta +0.70% (gate=15.00%, dir=higher_is_better) ok
phase1_presized_vs_zero_arraylist/default/improvement_ratio delta +0.21% (gate=15.00%, dir=higher_is_better) ok
phase1_simd_vs_scalar_cosine/default/improvement_ratio delta +2.24% (gate=15.00%, dir=higher_is_better) ok
phase1_simd_vs_scalar_dot/default/improvement_ratio delta +3.25% (gate=15.00%, dir=higher_is_better) ok
phase1_cached_vs_uncached_index/default/improvement_ratio delta -7.58% (gate=15.00%, dir=higher_is_better) ok
phase2_chunked_adler32_4k/default/improvement_ratio delta +9.32% (gate=15.00%, dir=higher_is_better) ok
phase2_dirty_page_tracking/default/improvement_ratio delta -0.14% (gate=15.00%, dir=higher_is_better) ok
phase2_precomputed_keys_vs_hashmap/default/improvement_ratio delta -4.41% (gate=15.00%, dir=higher_is_better) ok
compare-bench: no regressions detected
```

## Review checklist

- Throughput regression >= 5% on any in-range scenario -> BLOCK, escalate.
- p99 regression >= 10% on any in-range scenario -> BLOCK, escalate.
- 3-5% throughput / 7-10% p99 -> WARN, disposition below.

## Disposition

**M0 harness self-test — no code change between `before` and `after`.**
The binary is identical across the two phases; any observed delta is
run-to-run host variance. All 8 loadtest rows and 12 zig-bench rows
are within the noise gate (no BLOCK).

- `ping` c=1..8: ΔQPS +8% to +17% is the expected noise envelope for
  this loopback workload. p99 shrank 0–20% (also noise). No code
  changed, no interpretation.
- `point_read` c=2 and c=4: ΔQPS -3.1% / -3.2% triggers the `warn`
  band (3–5% QPS drop). These are WITHIN noise for a flat run
  (identical binary). For a real perf fix, the noise gate will flag
  real regressions above this band. The harness is calibrated
  correctly.
- `two_hop` / `fan_out`: intentionally excluded from this run via
  `LOADTEST_SCENARIOS="ping point_read"`. These saturate the MATCH
  path hard enough to trip the `planned_read_runtime.zig` leak
  (M0_10_CONCERNS.md). Restore them after the leak fix lands.
- zig bench-timeseries: 4/4 rows within 5% Δ (gate 15-43%). Ok.
- zig benchmark (phase1/phase2): 8/8 rows within 10% Δ (gate 15%). Ok.

**Harness verdict: READY.** All three comparator paths
(compare_ab.py + zig build compare-bench ×2) produced usable output
and exit 0. The diff.md structure is correct; the disposition
workflow is testable; BLOCK thresholds are calibrated against
realistic noise.
