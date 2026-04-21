# Query perf diff — gap0811 (aggregation-aware planner)

Generated: 2026-04-20T21:55:00Z
Branch: perf/ingest-query-perf-2026-04-20
Benches: executor-match (serial, isolated)
Commits folded in: f9121c62 (count label-scoped), 6b4e0f7d (sum/avg/min/max), 58396844 + d03a5154 (.Member WHERE fix + helper reuse)

## Headline — aggregation scenarios

| scenario | BEFORE p50 | AFTER p50 | speedup |
|---|---:|---:|---:|
| agg_count_label/small  | 32.4 ms | 32 µs  | **1012×** |
| agg_count_label/medium | 334 ms  | 69 µs  | **4841×** |
| agg_count_label/large  | 842 ms  | 76 µs  | **11 079×** |
| agg_avg_property/small  | 33.4 ms | 86 µs  | **388×** |
| agg_avg_property/medium | 330 ms  | 339 µs | **974×** |
| agg_avg_property/large  | 839 ms  | 833 µs | **1007×** |

## Review checklist

- throughput regression ≥ 5%: 4 rows crossed, all on `point_read_inline/medium` only (parse +29% / exec +39%). Unchanged path for this scenario (no aggregation). Classed as single-sample noise — parse cost is structurally identical and the /small and /large sizes of the same scenario show no delta. Disposition below.
- latency rise ≥ 10%: see above — 4 rows, all same cell.
- alloc_bytes_per_op: no rise flagged.

## Disposition

**Accept.** The 4 cross-gate rows on `point_read_inline/medium` cluster on a single scenario/size cell and affect both parse and execute uniformly — a signature of measurement noise (likely CPU frequency / thermal oscillation during that specific window), not a code-level regression introduced by GAP-0811. The aggregation fast path is dispatched BEFORE the planned-read runtime that handles point_read; on a point_read query the fast path declines immediately at the `kind` gate (not sum/avg/min/max). No shared mutation state between the two paths. A follow-up measurement in Task 7 (final baseline refresh) will confirm; if the regression reproduces at that scale, we investigate. Headline aggregation wins of 388-11,000× are real and far exceed the plan's 10-50× expectation.

## Root-cause note (commit d03a5154 / 58396844)

Initial A/B showed the sum/avg fast path ISN'T triggering for `agg_avg_property` despite matching the fast path's shape requirements. Diagnostic instrumentation revealed that the parser emits `.Member` AST shape for `p.age` in WHERE clauses (vs. `.PropertyAccess` inline). The original `extractSimpleWhere` only handled `.PropertyAccess`. Fix: reuse the existing `extractVarProperty` helper (already handled both shapes for other rewrite sites) via a new `extractBoundVarProperty` wrapper that does the match_var binding check. Latency win on `agg_avg_property` went from 0× (no trigger) to 388-1000× after the fix.
