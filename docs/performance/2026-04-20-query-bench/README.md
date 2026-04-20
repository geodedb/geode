# 2026-04-20 Query Path Benchmark Plan — Artifact Ledger

Plan: `docs/superpowers/plans/2026-04-20-query-path-benchmarks.md`

Each milestone drops JSON outputs + diff.md here. Naming:

- `baseline/bench-<layer>.json` — M5 frozen baseline (parser / planner / executor-match / executor-mutation / e2e)
- `step-<N>-<slug>-{before,after}-*.json` — per-step A/B artifacts
- `step-<N>-<slug>-diff.md` — generated diff via `zig build compare-bench`
- `FINAL.md` — M5 close-out + ranked bottleneck list

Regression gate:

- `zig build compare-bench` uses `max(15%, 3σ)` noise gate on each (scenario, variant, measurement).
- Query-path measurements use these prefixes (see `common_query.zig`):
  - `throughput_ops_per_sec` — higher-is-better
  - `latency_p50_ns`, `latency_p95_ns`, `latency_p99_ns` — lower-is-better
  - `plan_ns_per_op`, `parse_ns_per_op`, `execute_ns_per_op` — lower-is-better
  - `plan_cache_hit_rate` — higher-is-better
  - `alloc_bytes_per_op`, `peak_rss_delta_bytes` — lower-is-better
