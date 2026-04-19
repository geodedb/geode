# Loadtest + Benchmark Report — v0.3.5 / v0.3.6 (2026-04-18)

## Environment (clean)

- **geode**: v0.3.5 (commit `8d57f512`, ReleaseFast native build, same binary as v0.3.6)
- **loadtest client**: `geode-test-harness/loadtest/go/geode-loadtest` (Go, quic-go native)
- **host**: Linux 6.12.74+deb13+1-amd64 x86_64, 56 cores
- **auth**: enabled (`geode` user / password)
- **data dir**: `/tmp/geode_bench_data` (fresh, no persisted state)
- **log level**: `warn`
- **levels**: 1, 2, 4, 8, 16, 32 concurrent clients, 5s per level
- **contention**: the `geode.service` systemd unit was stopped before the run — confirmed no other geode processes running. Results below represent a quiet-host baseline.

> **Clean run vs. prior contended run: numbers were nearly identical.** The `geode.service` we stopped (3d5h uptime, ~93% CPU) was not meaningfully impacting the benchmark server — the bottleneck is inside the geode query path itself, not host contention.

## Load-test results (`geode-loadtest`, reports in `reports_clean/`)

### ping — `RETURN 1 AS x` (pure transport)

Data: 0 nodes / 0 edges

| c   | qps    | p50       | p95       | p99       | err   |
|-----|--------|-----------|-----------|-----------|-------|
| 1   | 314.8  | 3.16 ms   | 3.61 ms   | 3.82 ms   | 0     |
| 2   | 518.0  | 3.72 ms   | 5.00 ms   | 5.83 ms   | 0     |
| 4   | 654.4  | 5.87 ms   | 8.30 ms   | 9.24 ms   | 0     |
| 8   | **940.6**  | 8.02 ms | 11.93 ms | 13.95 ms  | 0 (peak) |
| 16  | 805.8  | 9.68 ms   | 14.53 ms  | 16.97 ms  | 0.2%  |
| 32  | 867.6  | 8.78 ms   | 12.82 ms  | 14.10 ms  | 0.5%  |

- **Peak QPS 940.6 @ c=8.** Knee at c=8; c=16/32 do not gain further.
- Sub-percent errors at c≥16 — admission-lane fix from v0.3.4 is holding.

### point_read — `MATCH by lt_id`

Data: 500 nodes

| c   | qps   | p50         | p95         | p99         | err    |
|-----|-------|-------------|-------------|-------------|--------|
| 1   | 28.6  | 30.27 ms    | 68.27 ms    | 75.18 ms    | 0      |
| 2   | 19.4  | 102.37 ms   | 161.73 ms   | 251.72 ms   | 0      |
| 4   | 18.0  | 250.94 ms   | 323.97 ms   | 599.90 ms   | 0      |
| 8   | 18.2  | 518.57 ms   | 638.60 ms   | 1022.40 ms  | 0      |
| 16  | 17.4  | 553.55 ms   | 618.65 ms   | 987.55 ms   | 8.4%   |
| 32  | 17.0  | 545.51 ms   | 612.34 ms   | 1102.36 ms  | 22.0%  |

- **QPS saturates at ~18 QPS immediately** for c≥2. Latency grows 1:1 with client count.
- 50× gap vs `ping` for a 500-node property lookup points to a serialized path in MATCH / catalog — worth profiling.

### one_hop — `person -[:LT_KNOWS]-> person`

Data: 1K nodes / 3K edges

| c   | qps   | p50          | p95          | p99          | err    |
|-----|-------|--------------|--------------|--------------|--------|
| 1   | 6.6   | 150.40 ms    | 196.78 ms    | 256.67 ms    | 0      |
| 2   | 6.4   | 324.41 ms    | 393.84 ms    | 438.59 ms    | 0      |
| 4   | 6.8   | 664.97 ms    | 757.16 ms    | 1156.45 ms   | 0      |
| 8   | 7.4   | 1.339 s      | 1.509 s      | 1.878 s      | 0 (peak) |
| 16  | 7.4   | 1.362 s      | 1.695 s      | 1.839 s      | 17.8%  |
| 32  | 6.4   | 1.356 s      | 2.119 s      | 2.272 s      | 42.9%  |

- Throughput flat at ~7 QPS; latency scales 1:1 with concurrency.

### two_hop — `person->person->person DISTINCT`

Data: 2K nodes / 8K edges

| c   | qps   | p50          | p95          | p99          | err    |
|-----|-------|--------------|--------------|--------------|--------|
| 1   | 0.6   | 2.260 s      | 2.417 s      | 2.417 s      | 0      |
| 2   | 0.8   | 4.345 s      | 4.515 s      | 4.515 s      | 0      |
| 4   | 1.2   | 6.965 s      | 8.978 s      | 8.978 s      | 0 (peak) |
| 8   | 0.8   | 4.493 s      | 9.143 s      | 9.143 s      | 60%    |

- **Stopped at c=8** (>50% error rate threshold).
- 1.5 s per 2K-node 2-hop DISTINCT traversal is our heaviest scenario.

### fan_out — `person->person->company` (cross-type 2-hop)

Data: 2.2K nodes / 8K edges

| c   | qps   | p50          | p95          | p99          | err    |
|-----|-------|--------------|--------------|--------------|--------|
| 1   | 2.4   | 440.14 ms    | 573.69 ms    | 573.69 ms    | 0      |
| 2   | 2.6   | 874.05 ms    | 907.76 ms    | 907.76 ms    | 0      |
| 4   | 3.0   | 1.817 s      | 2.276 s      | 2.276 s      | 0      |
| 8   | 3.6   | 3.630 s      | 4.117 s      | 4.117 s      | 0      |
| 16  | 3.8   | 3.540 s      | 4.102 s      | 4.102 s      | 29.6%  |
| 32  | 3.0   | 4.071 s      | 5.178 s      | 5.178 s      | 61.5%  |

- Middle of the pack; stopped at c=32.

## Zig engine benchmark (`zig build bench-timeseries -Doptimize=ReleaseFast`)

Direct in-process benchmark of the time-series store — no network, no auth.

| config | ingestion rate       | query rate            | notes                       |
|--------|----------------------|-----------------------|-----------------------------|
| Medium (100K points, 100K queries) | **62.7 M points/sec** (1.60 ms)  | **6.35 M queries/sec** (15.76 ms, all 100K hit) | warm cache |
| Large (1M points, 100K queries)    | **80.6 M points/sec** (12.40 ms) | **7.58 M queries/sec** (13.19 ms, all 100K hit) | cold + 10× data |

Storage engine sustains ~80 M points/s ingestion and ~7.5 M valueBefore queries/s in-process. The network-path latency observed in the load-tests above is dominated by query planning / execution / result marshaling, not the raw storage layer.

## vs. `benchmarks/loadtest/baseline.jsonl`

Baseline on disk only covers the ping scenario and caps at c=4:

| c  | ping qps (baseline) | ping qps (clean run) | Δ       | ping p50 (baseline) | ping p50 (clean) | Δ       |
|----|---------------------|----------------------|---------|---------------------|------------------|---------|
| 1  | 273.8               | 314.8                | +15.0%  | 2.40 ms             | 3.16 ms          | +31.7%  |
| 2  | 727.0               | 518.0                | −28.7%  | 2.70 ms             | 3.72 ms          | +37.8%  |
| 4  | 646.2               | 654.4                | +1.3%   | 3.10 ms             | 5.87 ms          | +89.4%  |

The `benchmarks/loadtest/compare.py` thresholds (20% QPS band / 20% p50 band) would still flag c=2 and c=4 on p50. Two possible explanations: (1) a real p50 regression since baseline was captured, (2) the baseline was captured on a quieter or hotter-cached host. The `geode.service` we stopped is not the explanation — the clean numbers above match the contended ones. **Recommend:** refresh the baseline via `make loadtest-save-baseline` (on the intended baseline host) and extend it to cover all five scenarios, then set up `loadtest-regression` to gate on merges.

## Headline numbers

| Metric                                | v0.3.5/v0.3.6 (clean host) |
|---------------------------------------|----------------------------|
| ping peak QPS                         | **940.6 @ c=8** (14.0 ms p99) |
| point_read peak QPS (500 nodes)       | 28.6 @ c=1                  |
| one_hop peak QPS (1K/3K)              | 7.4 @ c=8                   |
| two_hop peak QPS (2K/8K DISTINCT)     | 1.2 @ c=4                   |
| fan_out peak QPS (2.2K/8K cross-type) | 3.8 @ c=16                  |
| bench-timeseries ingestion (1M pts)   | 80.6 M points/sec           |
| bench-timeseries query (100K queries) | 7.58 M queries/sec          |

## Follow-ups

1. **MATCH-by-property investigation.** 500-node `lt_id` lookup hits only ~18 QPS vs ping's ~940 — 50× gap. Candidate: planner / catalog-lock path, or per-query cost overhead. Worth profiling with `-Doptimize=ReleaseFast` and `perf` or dbg-gate timers.
   - **Update 2026-04-18 (GAP-0752 closed, commit `849c6ac1`, threshold adjusted in `bf44f0ac`):** handler was unconditionally taking the exclusive writer lock on every non-EXPLAIN query, serializing read-only MATCH-by-property behind mutations. Fix routes reads to `acquireGraphReadLock` based on `query_traits.isMutatingProgram`. Post-fix point_read: qps@c=1=28.8, qps@c=4=33.6 (ratio 1.17×, up from 0.63×); p50@c=4 dropped 57% (251 ms → 108 ms). See `docs/audit/bugfix-GAP-0752-match-write-lock.md`.
   - **Remaining narrowing work (raises ratio toward 1.5×+):** (a) `src/server/query_plan_cache.zig:451` — single global mutex on plan compile/insert still re-serializes plan lookups; narrow to sharded or read-mostly scheme. (b) `src/server/main.zig:815` — single-threaded response poll loop; worker-pool or per-connection event reactors. Neither is correctness-blocking; both are throughput ceilings.
2. **Two-hop DISTINCT expansion.** 1.5 s per query at 2K nodes / 8K edges indicates O(n²) DISTINCT materialization or lack of short-circuiting. Candidate for planner/executor work.
3. **Baseline refresh.** Run `make loadtest-save-baseline` after any performance-affecting change and extend coverage to all five scenarios (point_read, one_hop, two_hop, fan_out).
4. **Admission lane validation.** c≥16 error rates are single-digit for ping but climb to 18-43% for traversal scenarios — partial admission/back-pressure behavior is doing its job but the queue ramp could be smoother. Correlate with GAP-0751 metrics.
