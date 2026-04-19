# 2026-04-19 QPS Closure Plan — Artifact Ledger

Plan: `docs/superpowers/plans/2026-04-19-qps-regression-closure.md`

Each step captures before/after perf-gate artifacts here. Naming convention mirrors thread-pool's `docs/performance/appsec-fixes-2026-04-15/`:

- `step-N-<slug>-before-loadtest.json` — full 5-scenario Go loadtest run, before the fix
- `step-N-<slug>-before-bench-timeseries.json` — zig bench-timeseries, before
- `step-N-<slug>-before-benchmark.json` — zig benchmark (Phase 1/2) — before
- `step-N-<slug>-after-*.json` — same three, after
- `step-N-<slug>-diff.md` — generated diff + review checklist disposition

Regression gate (same as `scripts/perf-gate.sh`):

- Throughput regression ≥ 5% on any in-range scenario → BLOCK, require user disposition in diff.md.
- p99 regression ≥ 10% on any in-range scenario → BLOCK, same.
- 3–5% throughput / 7–10% p99 → WARN, note in commit body.
- Scenarios outside the hot path of the change (determined by construction, not measurement) may be dispositioned as "noise" in diff.md with evidence.
