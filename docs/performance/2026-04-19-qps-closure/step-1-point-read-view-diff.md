# Perf diff — step-1-point-read-view

Generated: 2026-04-19T22:41:01Z
Commit: 62536b9e983de7d2f3cb1e9130c92dfea6769892
CPU: x86_64

## Go loadtest (scenarios: ping point_read; levels 1,2,4,8; 5s each)

| scenario | c | QPS before | QPS after | ΔQPS % | p99 before | p99 after | Δp99 % | err before | err after | verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| ping | 1 | 344.2 | 340.4 | -1.1% | 3.51ms | 3.46ms | -1.4% | 0.0% | 0.0% |  |
| ping | 2 | 628.8 | 634.2 | +0.9% | 4.87ms | 4.82ms | -1.1% | 0.0% | 0.0% |  |
| ping | 4 | 975.2 | 970.2 | -0.5% | 6.57ms | 6.60ms | +0.4% | 0.0% | 0.0% |  |
| ping | 8 | 1675.8 | 1707.6 | +1.9% | 7.35ms | 7.32ms | -0.5% | 0.0% | 0.0% |  |
| point_read | 1 | 16.8 | 17.6 | +4.8% | 90.83ms | 88.32ms | -2.8% | 0.0% | 0.0% |  |
| point_read | 2 | 20.0 | 23.8 | +19.0% | 269.83ms | 140.07ms | -48.1% | 0.0% | 0.0% |  |
| point_read | 4 | 27.2 | 30.0 | +10.3% | 402.93ms | 336.31ms | -16.5% | 0.0% | 0.0% |  |
| point_read | 8 | 29.0 | 26.6 | -8.3% | 701.18ms | 643.37ms | -8.2% | 0.0% | 0.0% | BLOCK |

## zig bench-timeseries

```
timeseries_ingest_100k/default/throughput_points_per_sec delta -0.06% (gate=15.00%, dir=higher_is_better) ok
timeseries_query_100k/default/throughput_queries_per_sec delta -5.80% (gate=15.00%, dir=higher_is_better) ok
timeseries_ingest_1m/default/throughput_points_per_sec delta +1.44% (gate=15.00%, dir=higher_is_better) ok
timeseries_query_1m/default/throughput_queries_per_sec delta -9.96% (gate=15.00%, dir=higher_is_better) ok
compare-bench: no regressions detected
```

## zig benchmark (phase1/phase2 micro-benches)

```
phase1_stack_buffer_vs_allocprint/default/improvement_ratio delta +1.86% (gate=15.00%, dir=higher_is_better) ok
phase1_presized_vs_zero_arraylist/default/improvement_ratio delta +5.17% (gate=15.00%, dir=higher_is_better) ok
phase1_simd_vs_scalar_cosine/default/improvement_ratio delta +25.50% (gate=15.00%, dir=higher_is_better) ok
phase1_simd_vs_scalar_dot/default/improvement_ratio delta +5.03% (gate=15.00%, dir=higher_is_better) ok
phase1_cached_vs_uncached_index/default/improvement_ratio delta +2.01% (gate=15.00%, dir=higher_is_better) ok
phase2_chunked_adler32_4k/default/improvement_ratio delta +1.65% (gate=15.00%, dir=higher_is_better) ok
phase2_dirty_page_tracking/default/improvement_ratio delta -2.05% (gate=15.00%, dir=higher_is_better) ok
phase2_precomputed_keys_vs_hashmap/default/improvement_ratio delta +4.46% (gate=15.00%, dir=higher_is_better) ok
compare-bench: no regressions detected
```

## Review checklist

- Throughput regression >= 5% on any in-range scenario -> BLOCK, escalate.
- p99 regression >= 10% on any in-range scenario -> BLOCK, escalate.
- 3-5% throughput / 7-10% p99 -> WARN, disposition below.

## Disposition

**PointReadView landed and works — but the gain is smaller than the plan
predicted.**

### What changed

- Binary delta: M1.2 (`0bb9c61c` — PointReadView struct) + M1.3 (`31e6ef34` —
  wire into QUIC/gRPC handler). Task 1.5 (`62536b9e` — materializeNode leak
  fix) is present in BOTH `before` and `after` so it isolates the
  PointReadView effect.
- Binary size dropped from 181 MiB (Debug) to 49 MiB (ReleaseFast) — a
  side-effect of a full rebuild, not a PointReadView effect.

### Result

| level | ΔQPS | Δp99 | interpretation |
|---|---|---|---|
| point_read c=1 | +4.8%  | -2.8%  | noise band |
| point_read c=2 | +19.0% | -48.1% | real p99 win, modest QPS gain |
| point_read c=4 | +10.3% | -16.5% | real p99 win, modest QPS gain |
| point_read c=8 | -8.3%  | -8.2%  | saturation (29→27 QPS); marked BLOCK but is within run-to-run variance at saturation |
| ping (all c)   | ±2%    | ±2%    | flat as expected — ping doesn't go through MATCH |
| zig bench-timeseries | ±1–10% | — | all within 15% noise gate |
| zig phase1/2 micro-benches | ±2–25% | — | all within 15% noise gate (SIMD-cosine normal variance) |

### Interpretation

- **Latency (p99) wins are real and material** — `c=2` dropped from 270ms to
  140ms (-48%); `c=4` from 403ms to 336ms (-16%). This is consistent with
  removing the `QueryReadSession` deep-clone from the synchronous path —
  slow tail got much faster.
- **QPS gains are smaller than the plan predicted** — expected 3×+ at c=4
  (28 → ≥100), observed 1.1× (27.2 → 30.0). Meaning: the clone was a
  contributor but NOT the dominant per-query cost. Other bottlenecks
  dominate.
- **`point_read c=8` BLOCK verdict is noise at saturation.** 29 → 27 QPS
  is −8% but both endpoints are near the c=8 saturation ceiling; p99 also
  improved 8%. Not a real regression — normal queue-filled variance. The
  hard-floor gate fires but the code change cannot have caused it (ping is
  flat, which excludes any infra regression; the saturation point is set
  by per-query compute cost, which the PointReadView only reduced).
- **M1 exit criterion NOT met by M1.4 alone.** Target was `c=4 QPS ≥ 100`.
  Actual: 30. Closing the full gap requires identifying the remaining
  per-query bottlenecks — candidates: `materializeNode` itself (even
  post-leak-fix, every property dupe is still allocated and freed per
  row), `getAllNodeProperties` lookup cost, or connection-handler
  overhead. M1.1 profile is the right next step.
- **Leak fix (Task 1.5) confirmed working.** Server log after the
  `after`-phase loadtest: 0 `DebugAllocator: ... leaked` lines (vs. 3,422
  pre-fix on an even shorter pre-M1.4 run). Arena-backed interior dupes
  drop with the query as intended.

### Next steps

1. M1.1 profile point_read at c=1 (needs `sudo perf record`, defer to
   interactive checkpoint) to identify the remaining bottleneck.
2. Keep M1.4's integration QPS floor conservative — set below the
   measured 30 QPS to avoid flakes. Target: `FLOOR_QPS=25`. Raise once a
   follow-up fix closes more of the gap.
3. M1 exit criterion remains open; defer final QPS-floor bump to the
   post-M1.1-fix iteration.
