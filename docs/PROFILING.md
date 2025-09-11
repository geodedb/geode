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
  - `min_error_abs_pct`, `max_error_abs_pct`, `mean_error_abs_pct`

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

- Minor additive fields retain profile_version.
- Removing or renaming fields bumps profile_version.
- Tests: `e2e_protocol_profile_schema_guard` enforces baseline presence & ordering markers.

## Interpretation Notes

- High `percent_peak` early stages suggest memory reuse opportunities.
- Large `error_abs_pct` points to estimate heuristic tuning targets.
- `freed_bytes` will become meaningful once per-stage deallocation hooks are wired.
- `mean_error_abs_pct` > 50 indicates planner heuristics need recalibration.

## Future Roadmap

- Stage-level free attribution & net_after_op deltas.
- Join / Expand stage profiling.
- I/O wait vs CPU split.
- Vectorized execution micro-metrics (batch size, cache hits).
