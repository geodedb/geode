# Profiling Reference

`PROFILE <query>` produces a PROFILE JSON frame after the SCHEMA frame.

## Top-Level Fields

- `profile_version`: Schema version (increment on incompatible change).
- `ops[]`: Ordered list of stage objects.
- `peak_contributors[]`: Top 3 allocation deltas (bytes_alloc) with op names.
- `total_time_ns`: Wall-clock pipeline time.
- `spills`: `{sort_spills, distinct_spills, union_spills}`, plus `spill_reason` only when a counter is above 0. The executor never spills to disk, so every counter is 0 and `spill_reason` is absent (SONNY-6562).
- `memory`: `{net_bytes, peak_bytes, total_alloc_bytes}` — zeros on both paths: allocations are not measured (GAP-0874 decision, see docs/EXPLAIN_PROFILE.md Current Limitations). Until SONNY-6596 the fallback (v1) path reported a fixed synthetic model.
- `planner_estimates` (optional if estimates enabled):
  - `sum_estimate_bytes`
  - `sum_actual_bytes`
  - `count_estimated_ops`
  - `min_error_abs_pct`, `max_error_abs_pct`, `mean_error_abs_pct`, `median_error_abs_pct`, `stddev_error_abs_pct`

## Per-Op Fields (ops[])

| Field              | Meaning                                                                            |
| ------------------ | ---------------------------------------------------------------------------------- |
| op                 | Stage name (Project, Distinct, Sort, Offset, Limit, AggregateBuild, AggregateEmit) |
| op_index           | Zero-based sequential index (stable ordering)                                      |
| input_rows / rows  | Row counts pre/post stage                                                          |
| time_ns            | Stage wall time                                                                    |
| cumulative_time_ns | Running sum of time_ns across emitted stages                                       |
| bytes_out          | Approx logical row bytes (JSON heuristic)                                          |
| bytes_alloc        | Allocation delta attributed to stage                                               |
| estimate_bytes     | Heuristic planner estimate (0 when disabled)                                       |
| estimate_vs_actual | (bytes_alloc \* 100)/estimate_bytes (0 if estimate or actual zero)                 |
| percent_peak       | Share of peak_bytes (0-100)                                                        |
| percent_net        | Share of net_bytes at emission (0-100)                                             |
| freed_bytes        | Bytes net freed relative to previous stage (prototype; mostly 0 now)               |
| net_after_op       | Net allocated bytes after stage                                                    |
| error_bytes        | Absolute difference between estimate and actual (0 if no estimate)                 |
| error_abs_pct      | Absolute percentage error vs estimate                                              |

## Environment Variables

| Variable                      | Effect                                                 |
| ----------------------------- | ------------------------------------------------------ |
| `GEODE_NULLS_LAST`            | Nulls last ordering policy                             |
| `GEODE_SPILL_THRESHOLD_BYTES` | Read at startup; changes no output. The executor never spills, so PROFILE reports no spill (it reported one when its synthetic peak passed the threshold until SONNY-6562) |
| `GEODE_QUERY_MEM_LIMIT_BYTES` | The same setting under another name (it wins when both are set); changes no output |
| `GEODE_FORCE_SORT_SPILL`, `GEODE_FORCE_DISTINCT_SPILL`, `GEODE_FORCE_UNION_SPILL` | Not read by the server (SONNY-6435) |

## CLI Flags

| Flag                | Effect                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `--no-estimates`    | Suppress estimate\_\* fields and aggregate planner_estimates object                                                     |
| `--profile-compact` | Omit zero-value optional metrics (estimate*bytes, estimate_vs_actual, percent_peak, percent_net, freed_bytes, error*\*) |

## Versioning Policy

## Interpretation Notes

## Variance Envelopes

### Standardized JSON Schema (schema_version=1)

Variance envelopes emitted by the variance benchmarks follow a normalized JSON Lines schema:

```json
{
  "schema_version": 1,
  "kind": "VarianceEnvelope",
  "benchmark": "<name>",
  "mean_ns": <uint>,
  "cv_scaled_ppm": <uint>,                 // coefficient of variation * 1e4 (e.g. 15849 => 1.5849)
  "p95_ns": <uint>,
  "p95_over_mean_scaled_ppm": <uint>,      // (p95/mean) * 1e4
  "cv_max_scaled_ppm": <uint>,             // configured threshold * 1e4
  "p95_over_mean_max_scaled_ppm": <uint>,  // configured threshold * 1e4
  "pass": true|false                       // omitted if skipped
}
```

Skipped envelopes (feature stubs, unsafe state) include instead:

```json
{
  "schema_version": 1,
  "kind": "VarianceEnvelope",
  "benchmark": "raft_commit_advancement_variance",
  "skipped": true,
  "reason": "standalone_runner_stub"
}
```

Rationale:

1. Pure integers avoid locale / float formatting drift.
2. `schema_version` enables forward evolution (e.g. adding `iterations`, `warmup` fields) while preserving backward compatibility.
3. Scaling by 1e4 keeps precision sufficient for CV/p95 over mean guardrails without floating point parsing.
4. Consistent `kind` value allows heterogeneous files to be grep-filtered (other lines may retain legacy benchmark formats until migrated).

Migration Plan:

Existing legacy lines (no `schema_version`) are replaced opportunistically when touched; tooling treats absence as legacy format and will NOT enforce thresholds.

### Extended JSON Schema (schema_version=2)

`schema_version=2` is an additive superset emitted alongside v1 during a transition window. It introduces more explicit sampling metadata, range statistics, and a normalized threshold evaluation array to ease future guardrail expansion (e.g. tail latency ratios, median jitter).

```json
{
  "schema_version": 2,
  "kind": "VarianceEnvelope",
  "benchmark": "<name>",
  "mean_ns": <uint>,
  "min_ns": <uint>,
  "max_ns": <uint>,
  "sample_count": <uint>,              // number of post-warmup samples
  "warmup_count": <uint>,              // warmup iterations excluded from stats
  "cv_scaled_ppm": <uint>,
  "p95_ns": <uint>,
  "p95_over_mean_scaled_ppm": <uint>,
  "cv_max_scaled_ppm": <uint>,
  "p95_over_mean_max_scaled_ppm": <uint>,
  "jitter_class": "low|medium|high",  // heuristic buckets: cv <0.10 low, <0.20 medium, else high
  "thresholds_evaluated": [            // normalized evaluation objects
    {"metric":"cv_scaled_ppm","actual":<uint>,"max":<uint>,"pass":true|false},
    {"metric":"p95_over_mean_scaled_ppm","actual":<uint>,"max":<uint>,"pass":true|false}
  ],
  "pass": true|false
}
```

Key Points:

1. Dual Emission: Both v1 and v2 lines are emitted for each benchmark to preserve existing tooling while enabling richer downstream analytics.
2. Deterministic Order: Field ordering is stable to minimize diff noise and allow simple line-based comparisons in CI.
3. Backward Compatibility: v1 content remains byte-for-byte identical (aside from possible improved stabilization due to adaptive sampling). Consumers can safely ignore v2 until migrated.
4. Jitter Classification: Provides coarse qualitative signal helpful in dashboards without computing thresholds client-side.
5. thresholds_evaluated: Generic array enables adding new guardrails (e.g. p99, median/mean ratio) without introducing new top-level duplicated fields beyond the raw metrics.
6. Deprecation Path: Once all consumers accept v2 (tracked via a future CANARY aspect), v1 emission will be flagged for removal with a minimum 2 release grace period.

Adaptive Sampling (Path Multi-Branch): When `VARIANCE_ADAPTIVE=on` and initial CV/ratio fail thresholds, additional batches are appended (bounded) to reduce variance before final emission; metadata (sample_count) reflects final post-warmup sample size.

### Shared Configuration & Trimming Policy (New)

All newly refactored variance benches (starting with Redo Optimization Delta & PathCache Degree Bucket Utilization) consume a common helper `benchmarks/variance_config.zig` which centralizes:

| Env Var Prefix     | Description                                     | Example Default |
| ------------------ | ----------------------------------------------- | --------------- |
| `<PREFIX>_SAMPLES` | Outer sample groups (post-warmup)               | 64 / 128        |
| `<PREFIX>_INNER`   | Inner repetitions averaged per outer sample     | 8               |
| `<PREFIX>_TRIM`    | Number of extreme samples trimmed from each end | 1               |
| `GEODE_BENCH_JSON` | Emit structured JSON (one line) with metrics    | off             |

Trimming occurs AFTER sorting ascending; if `len <= 2*TRIM` no trimming is applied. We retain both trimmed and raw means (where relevant) to avoid obscuring systemic regressions while lowering tail jitter influence.

Example emitted JSON (when `GEODE_BENCH_JSON=1`, current schema_version=2):

```json
{
  "schema_version": 2,
  "benchmark": "redo_optimization_delta_variance",
  "samples": 64,
  "inner": 8,
  "trim_edges": 1,
  "trimmed_len": 62,
  "speedup_mean_trimmed": 1.024,
  "speedup_mean_raw": 1.025,
  "median_trimmed": 1.022,
  "mad_trimmed": 0.004,
  "cv": 0.0909,
  "cv_threshold": 0.18,
  "p95": 1.236,
  "p95_ratio": 1.21,
  "p95_ratio_threshold": 1.35,
  "min_speedup_threshold": 1.0,
  "pass": true
}
```

Rationale:

1. Centralizes environment parsing & avoids copy/paste parsing logic.
2. Explicit trim metadata (`trim_edges`,`trimmed_len`) documents data reduction.
3. JSON emission allows downstream dashboards & longitudinal variance tracking without scraping free‑form text.
4. Minimal default trimming (1 edge) balances stability with transparency.

Future enhancements under consideration (some partially implemented in helper stats API):

- Median / MAD-based robust dispersion alternative.
- Percentile bucket diagnostics (e.g. p50, p75, p90, p95, p99) when CV thresholds marginally fail.
- Adaptive trim if kurtosis exceeds configured bound.
- Thresholds array (normalized) emission once downstream tooling updated.

### Diagnostic JSON Schema (schema_version=3) — In-Flight Migration

`schema_version=3` (currently emitted for the redo optimization delta variance envelope) extends v2 with explicit baseline vs optimized timing statistics for speedup style benches and begins formalizing the generic `thresholds_evaluated` array (currently emitted as an empty array placeholder until all benches adopt unified evaluation objects). This aids root-causing regressions where overall speedup hovers near 1.0 by exposing which side (baseline or optimized path) shifted.

Additions over v2 (for speedup benchmarks):

```json
{
  "schema_version": 3,
  "benchmark": "redo_optimization_delta_variance",
  "samples": 64,
  "inner": 8,
  "trim_edges": 2,
  "trimmed_len": 60,
  "speedup_mean_trimmed": 1.012,
  "speedup_mean_raw": 1.01,
  "baseline_mean_trimmed": 5234567.0,
  "optimized_mean_trimmed": 5172360.0,
  "baseline_median_trimmed": 5231000.0,
  "optimized_median_trimmed": 5171000.0,
  "baseline_cv": 0.081,
  "optimized_cv": 0.077,
  "median_trimmed": 1.011,
  "mad_trimmed": 0.004,
  "cv": 0.079,
  "cv_threshold": 0.18,
  "p95": 1.14,
  "p95_ratio": 1.13,
  "p95_ratio_threshold": 1.35,
  "min_speedup_threshold": 1.0,
  "pass": true,
  "thresholds_evaluated": []
}
```

Planned next step: populate `thresholds_evaluated` with objects mirroring v2 conceptual design (`metric, actual, max, pass`) once all variance benches share a consolidated evaluation struct. After two full release cycles with populated arrays, legacy schema_version=1 emission will be retired, followed by v2 after consumer migration (tracked via dedicated CANARY aspect).

### Legacy Mode Deprecation

`GEODE_BENCH_LEGACY=1` temporarily relaxes certain thresholds (notably minimum speedup mean for redo) to keep CI passing while stabilization work proceeds. This flag is marked deprecated and will be removed once the redo optimization delta envelope achieves three consecutive green runs under strict thresholds. Use only for emergency CI unblocking; do not rely on it in new automation.

Synthetic Raft Commit Variance: Replaces prior skipped placeholder with a deterministic LCG-driven quorum delay simulation producing both v1 and v2 envelopes. Thresholds are intentionally looser (cv_max=0.35, ratio_max=3.0) pending real replication path integration.

### Cross-Reference: Planner & Path Determinism Variance Envelopes

The following variance envelopes explicitly guard planner/path determinism and are cited in `REQUIREMENTS.md` and gap analysis narratives (UA005/UA006 tie-break, planner phase stability):

| Benchmark                                                              | Purpose                                                                | Metrics Guarded | Default Thresholds  |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------- | ------------------- |
| PathQuantifierBoundedVarianceEnvelope                                  | Bounded multi-branch path expansion deterministic timing stability     | cv, p95/mean    | cv≤0.23, ratio≤2.60 |
| PathExpansionHeuristicVarianceEnvelope                                 | Heuristic pruning stability (branch ordering, deterministic tie-break) | cv, p95/mean    | cv≤0.25, ratio≤2.70 |

The rewrite / group-validation timing, planner-pipeline and adaptive-replan
envelopes that used to be listed here measured the synthetic
`src/planner/pipeline.zig` runner and `adaptive_replan.zig`; the envelopes
were removed in SONNY-6511, the runner (reached only by tests) in SONNY-6555.

All emit dual schema versions during migration; schema v2 adds `sample_count`, range stats (`min_ns`,`max_ns`), and `thresholds_evaluated` objects for each metric. Consecutive threshold breaches (≥3 runs) mandate investigation (instrumentation drift, branching factor increase, scheduling jitter). Future enhancement: nested `phases` object with per-phase sub-metrics when cost model enumeration replaces any residual synthetic hooks.

## Future Roadmap

- Stage-level free attribution & net_after_op deltas.
- Join / Expand stage profiling.
- I/O wait vs CPU split.
- Vectorized execution micro-metrics (batch size, cache hits).
