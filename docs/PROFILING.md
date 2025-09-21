# Profiling Reference

`PROFILE <query>` produces a PROFILE JSON frame after the SCHEMA frame.

## Top-Level Fields

- `profile_version`: Schema version (increment on incompatible change).
- `ops[]`: Ordered list of stage objects.
- `peak_contributors[]`: Top 3 allocation deltas (bytes_alloc) with op names.
- `total_time_ns`: Wall-clock pipeline time.
- `spills`: `{sort_spills, distinct_spills, union_spills}` plus optional `spill_reason` (`forced|threshold`).
- `memory`: `{net_bytes, peak_bytes, total_alloc_bytes}` from tracking allocator.
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
| `GEODE_SPILL_THRESHOLD_BYTES` | Triggers spill counters when `peak_bytes >= threshold` |
| `GEODE_FORCE_SORT_SPILL`      | Force sort spill counter                               |
| `GEODE_FORCE_DISTINCT_SPILL`  | Force distinct spill counter                           |
| `GEODE_FORCE_UNION_SPILL`     | Force union spill counter                              |

## CLI Flags

| Flag                | Effect                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `--no-estimates`    | Suppress estimate\_\* fields and aggregate planner_estimates object                                                     |
| `--profile-compact` | Omit zero-value optional metrics (estimate*bytes, estimate_vs_actual, percent_peak, percent_net, freed_bytes, error*\*) |

## Versioning Policy

## Interpretation Notes

## Variance Envelopes

### Standardized JSON Schema (schema_version=1)

Variance envelopes emitted by `run_variance_benches` (and future consolidated runners) follow a normalized JSON Lines schema:

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

Synthetic Raft Commit Variance: Replaces prior skipped placeholder with a deterministic LCG-driven quorum delay simulation producing both v1 and v2 envelopes. Thresholds are intentionally looser (cv_max=0.35, ratio_max=3.0) pending real replication path integration.

### Cross-Reference: Planner & Path Determinism Variance Envelopes

The following variance envelopes explicitly guard planner/path determinism and are cited in `REQUIREMENTS.md` and gap analysis narratives (UA005/UA006 tie-break, planner phase stability):

| Benchmark                                                              | Purpose                                                                | Metrics Guarded | Default Thresholds  |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------- | ------------------- |
| PathQuantifierBoundedVarianceEnvelope                                  | Bounded multi-branch path expansion deterministic timing stability     | cv, p95/mean    | cv≤0.23, ratio≤2.60 |
| PathExpansionHeuristicVarianceEnvelope                                 | Heuristic pruning stability (branch ordering, deterministic tie-break) | cv, p95/mean    | cv≤0.25, ratio≤2.70 |
| PlannerRewritePreValidationTimingVarianceEnvelope                      | Rewrite sub-phase timing stability                                     | cv, p95/mean    | cv≤0.22, ratio≤2.55 |
| PlannerGroupValidationTimingVarianceEnvelope                           | Group validation sub-phase timing stability                            | cv, p95/mean    | cv≤0.22, ratio≤2.55 |
| PlannerPipelineVarianceEnvelope / PlannerPipelinePhaseVarianceEnvelope | Integrated pipeline (rewrite→cardinality→cost) stability               | cv, p95/mean    | cv≤0.22, ratio≤2.55 |
| PlannerAdaptiveReplanTriggerVarianceEnvelope                           | Adaptive replan trigger decision latency stability                     | cv, p95/mean    | cv≤0.22, ratio≤2.55 |

All emit dual schema versions during migration; schema v2 adds `sample_count`, range stats (`min_ns`,`max_ns`), and `thresholds_evaluated` objects for each metric. Consecutive threshold breaches (≥3 runs) mandate investigation (instrumentation drift, branching factor increase, scheduling jitter). Future enhancement: nested `phases` object with per-phase sub-metrics when cost model enumeration replaces any residual synthetic hooks.

## Future Roadmap

- Stage-level free attribution & net_after_op deltas.
- Join / Expand stage profiling.
- I/O wait vs CPU split.
- Vectorized execution micro-metrics (batch size, cache hits).
