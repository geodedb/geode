# Performance Audit — Phase 1 Context

**Root:** /home/benji/src/devnw/codepros/geode/geode
**Platform:** GitLab (origin: <git@gitlab.com>:devnw/codepros/geode/geode.git)
**Languages:** Zig 0.16.0 (primary); Go 1.26.2 (loadtest client, gRPC bridge); Python 3.13 (bench drivers, compare/save scripts)
**Harness path (corrected):** /home/benji/src/devnw/codepros/geode/geode-test-harness (sibling of this repo, NOT `../geode-test-harness` from repo root — which resolves to `/home/benji/src/devnw/codepros/geode-test-harness` and is absent)

## Services & Entrypoints

| Service | Entrypoint | Type | Path |
|---------|-----------|------|------|
| Unified geode binary | `main` → `cli/main.zig` → subcommand dispatch | CLI + server | src/unified_entry.zig:12, src/cli/main.zig:153 |
| QUIC serve | `serve` subcommand wires listener | Long-running server | src/server/main.zig:403-754 |
| QUIC listener | `transport.listen()` | QUIC+TLS I/O loop | src/transport/quic.zig (1243 LOC) |
| QUIC connection handler | `SharedConnState`, `BufferedProtoReader.nextMessage` | Per-connection | src/server/quic_connection_handler.zig:263,606 |
| Stream scheduler | `StreamScheduler` (DRR) | Fairness layer | src/transport/stream_scheduler.zig:45 |
| Worker pool | `BoundedQueue`, `submit`, `submitBlocking` | Query worker threads | src/transport/thread_pool.zig:24,203 |
| MATCH executor | `executeMatchQueryImpl`, `executeMatchCallQuery` | Query execution | src/execution/match_operations.zig:774,519 (7,110 LOC) |
| Storage adapter | `graph_storage_adapter.zig` | MVCC + per-graph rwlock | src/storage/graph_storage_adapter.zig |
| Graph store | `graph_store.zig` | In-memory node/edge store | src/graph_store.zig (6,560 LOC) |
| WAL | `wal.zig` | Durability + fsync | src/wal.zig (773 LOC) |
| TDE | `storage/tde_file_encryption.zig` | Page-level AES-GCM | src/storage/tde_file_encryption.zig |
| Planner | `planner/*.zig` (24 files) | Cost-based optimization | src/planner/cost_model.zig, src/planner/enumerator.zig, src/planner/adaptive.zig |
| HNSW vector index | `VectorIndex.searchVectorF32/I32` | Vector search | src/index/vector_index.zig:92,114; src/index/hnsw_persist.zig |
| R-tree spatial | `rtree_persist.zig` | Spatial queries | src/index/rtree_persist.zig |
| Index optimizer | `server/index_optimizer.zig` | Cost-based index selection | src/server/index_optimizer.zig |

Top-level `src/main.zig` is the default Zig scaffold (32 LOC placeholder) — NOT the production entry. Production uses `unified_entry.zig` as the root (build.zig:437).

## Workload Characteristics

| Parameter | Value | Source | Confidence |
|-----------|-------|--------|------------|
| Listen address | 0.0.0.0:3141 (QUIC+TLS only) | CLAUDE.md; src/server/main.zig:620 | confirmed |
| Load-test concurrency levels | 1,2,4,8,16,32 (configurable via `LOADTEST_LEVELS`) | geode-test-harness/Makefile:470 | confirmed |
| Per-level duration | 5s default | geode-test-harness/Makefile:471 | confirmed |
| Scenarios | ping, point_read, one_hop, two_hop, fan_out | loadtest/go/scenario.go:65-207 | confirmed |
| QPS regression threshold | current < baseline × 0.8 | CLAUDE.md; benchmarks/loadtest/compare.py | confirmed |
| p50 regression threshold | current > baseline × 1.2 | CLAUDE.md; benchmarks/loadtest/compare.py | confirmed |
| Error-rate regression | current > 10% when baseline < 5% | CLAUDE.md | confirmed |
| SLO latency target | UNKNOWN (no declared end-user SLO, only per-benchmark targets) | — | — |
| RPS target | UNKNOWN (baselines exist, no stated target) | — | — |
| Audit write latency target | < 10 μs avg, p99 < 100 μs | BENCHMARK_REPORT.md:54 | confirmed (target) |
| WAL fsync target | < 1 ms avg | BENCHMARK_REPORT.md:56 | confirmed (target) |
| WAL write throughput | > 10 MB/s (4 KB pages) | BENCHMARK_REPORT.md:57 | confirmed (target) |
| TDE page-encryption throughput | > 30 MB/s | BENCHMARK_REPORT.md:94 | confirmed (target) |
| TDE OLTP overhead | < 5% | BENCHMARK_REPORT.md:94 | confirmed (target) |
| RBAC check | < 1 μs | BENCHMARK_REPORT.md:119 | confirmed (target) |
| ABAC (5 policies) | < 10 μs | BENCHMARK_REPORT.md:119 | confirmed (target) |
| RLS filter generation | < 100 μs | BENCHMARK_REPORT.md:119 | confirmed (target) |
| Time-series ingestion | > 10M points/sec (in-memory) | BENCHMARK_REPORT.md:26 | suspected (un-run target) |

## Performance Model (Hypothesized Hot Components)

| Component | Resource | Why | File:Line |
|-----------|----------|-----|-----------|
| `executeMatchQueryImpl` full-scan sites | CPU | 17 full-scan + 7 label-indexed sites; label_index lookup is the recent GAP-0509 fix — regressions possible | src/execution/match_operations.zig:774,830,1521 |
| `passesTenantFilter` / `passesTenantFilterEdge` | CPU | Inlined per-row filter; called 7× in match loop | src/execution/match_operations.zig:88,94,615,905,1541 |
| QUIC `BufferedProtoReader.nextMessage` | CPU+Net | Per-message framing on hot stream path | src/server/quic_connection_handler.zig:282 |
| `StreamScheduler` DRR loop | CPU | Per-stream quantum accounting, touched on every chunk | src/transport/stream_scheduler.zig:102 |
| `wal.zig` fsync path | I/O (blocking) | Durability barrier, <1ms target, SSD-dependent | src/wal.zig |
| `tde_file_encryption.zig` page encrypt | CPU | AES-256-GCM per page, targets 30 MB/s, <5% OLTP | src/storage/tde_file_encryption.zig |
| HNSW `searchVectorF32` | CPU | SIMD distance; <50ns/8D L2 claim in CLAUDE.md | src/index/vector_index.zig:92 |
| `graph_store.zig` node/edge access | CPU+Mem | 6,560 LOC core; tier-1 rwlock | src/graph_store.zig |
| `planner/cost_model.zig`, `enumerator.zig` | CPU | Per-query overhead; cost-based join enumeration | src/planner/cost_model.zig |
| `query_plan_cache.zig`, `query_ast_cache.zig` | CPU+Mem | Cache-hit rate determines planner cost | src/server/query_plan_cache.zig, src/server/query_ast_cache.zig |
| Lock hierarchy (7 tiers) | Contention | GAP-0278 ordering; multi-graph alphabetical | CLAUDE.md "Mutex Lock Ordering" |

## External Dependencies

| Dependency | Type | Connection Pooling | Timeout | Path |
|-----------|------|-------------------|---------|------|
| zquic (vendored QUIC) | Network lib | N/A (listener) | transport timeouts configured in `config.listen_quic` | src/transport/quic.zig |
| gRPC bridge (optional) | Network | via grpc_dep module | — | src/transport/grpc_server.zig, build.zig:256 |
| S3 / Digital Ocean Spaces | Object store (backup) | Per-backup client | — | src/storage/s3_backup.zig |
| Remote KMS (optional) | Network | Cached unwrap | See benchmark_remote_kms_unwrap_concurrency.zig | benchmarks/benchmark_remote_kms_unwrap_concurrency.zig |
| Federation peers | Network | NodeRegistry (distributed) | Gated on GEODE_CLUSTER_TOKEN | src/distributed/ |

Authentication is fail-closed (CLAUDE.md). No outbound HTTP dependencies observed in hot paths for single-tenant mode.

## Baseline Measurements

Current baseline file: `benchmarks/loadtest/baseline.jsonl` (3 records, `ping` scenario only, concurrency 1/2/4). Point-read / one-hop / two-hop / fan_out baselines are NOT yet populated.

| Benchmark | Command | Result | Date |
|-----------|---------|--------|------|
| ping_c1 | (harness loadtest-go) | qps=273.8, p50=2.4 ms, p99=2.9 ms, errors=0, 1369 queries over 5s | baseline |
| ping_c2 | (harness loadtest-go) | qps=727.0, p50=2.7 ms, p99=3.4 ms, errors=0, 3635 queries over 5s | baseline |
| ping_c4 | (harness loadtest-go) | qps=646.2, p50=3.1 ms, p99=4.0 ms, errors=4, 3235 queries over 5s | baseline |
| Zig benchmark suite | `zig build bench`, `make bench` | Not run this phase (read-only) | — |
| TDE / WAL / audit / RLS / MFA / federation / thread-pool / transport | `benchmarks/benchmark_*.zig` (~46 files) | Not run this phase | — |
| Phase 5 micro-optims | `benchmarks/phase5_1..phase5_9_*.zig` | Not run this phase | — |
| Timeseries | `make bench-timeseries` → `src/benchmarks/bench_timeseries.zig` | Not run this phase | — |
| MATCH staged campaign | `make match-ops-bench` | Not run this phase | — |

Note on ping baseline: ping_c4 shows lower qps than ping_c2 (646 vs 727) and 4 errors — likely contention or saturation at 4-worker mark. Worth investigating in Phase 2.

The baseline has `threshold_qps_min` = qps × 0.8 and `threshold_p50_max_ms` ≈ p99 pre-computed; `compare.py` uses these plus the CLAUDE.md thresholds.

## Available Profiling Tools

| Tool | Available | Version / Path |
|------|-----------|----------------|
| zig | yes | 0.16.0 (build + test + benches compiled via build.zig) |
| go | yes | 1.26.2 (harness loadtest client) |
| python3 | yes | 3.13.5 (compare.py, save_baseline.py, loadtest/benchmarks/query_suite.py) |
| perf | yes | /usr/bin/perf (Linux perf — available for CPU profiling) |
| hyperfine | NO | not installed |
| pprof | NO | not installed |
| valgrind / callgrind | UNKNOWN | not probed |
| `zig build bench` / `zig build benchmark` | yes | per build.zig (bench_ts_exe:1141, tde_bench_exe:666, parallel_wrapper_bench:1683, transport_throughput_bench:1691) |
| Variance runners | yes | benchmarks/variance_config.zig + per-benchmark `*_variance.zig` files |

## Loadtest & Benchmark Infrastructure Inventory

- **Go loadtest client:** geode-test-harness/loadtest/go/{main,scenario,setup}.go — 5 scenarios (ping, point_read, one_hop, two_hop, fan_out); emits `reports/loadtest_<scenario>.json`.
- **Python query suite:** loadtest/benchmarks/query_suite.py — broader read/write/traversal/analytical benchmarks (not wired to baseline.jsonl yet).
- **Baseline compare:** `make loadtest-compare` → `benchmarks/loadtest/compare.py` (QPS drop, p50 inflation, error-rate rules).
- **Baseline save:** `make loadtest-save-baseline` or `loadtest-save-all-baselines` → `benchmarks/loadtest/save_baseline.py`; appends one JSONL record per concurrency level.
- **Zig benchmarks (~46):** everything under `benchmarks/*.zig` — TDE (4 variants), WAL, MFA, RLS, federation, pagination, monitoring, signaled queue (MPMC/MPSC/SPMC), transport throughput, thread-pool parallelism, QUIC stream registry, adaptive estimator variance, merge throughput.
- **Phase benchmarks:** `phase1_benchmarks.zig`, `phase2_benchmarks.zig`, `phase3_benchmarks.zig`, `phase5_1..5_9_*.zig` (column allocation, neighbors lazy sort, SIMD cosine, environment arrays, string concat, concurrent catalog, pagerank edges, metrics atomic, struct-by-value).
- **In-src micro-benches:** `src/benchmarks/bench_timeseries.zig`, `src/benchmarks/bench_gpu_*.zig` (BFS, pagerank, setops, shortest_path, TDE), `src/bench/ordering_cmp_bench.zig`, `src/benchmarks/pagination_*.zig` and `adaptive_replan_autotune_variance.zig`.
- **Historical data:** `benchmarks/history/adaptive_clamp.jsonl` (single file — limited longitudinal data).
- **CI gate:** `.gitlab-ci.yml` job `loadtest-regression` — MR + main push, `allow_failure: true` initially (per CLAUDE.md).

## Unknowns & Assumptions

- **No declared product-level SLO.** Only per-subsystem targets in BENCHMARK_REPORT.md. Clarification needed from product: p50/p95/p99 target for end-to-end query, target RPS at concurrency=32 (top of configured ladder), target cold-start / startup budget.
- **Baseline coverage is thin.** Only `ping` at concurrency {1,2,4} has a recorded baseline; point_read / one_hop / two_hop / fan_out appear in `compare.py` wildcard globs but `baseline.jsonl` contains no records for them — `make loadtest-save-all-baselines` has not been run since they were wired up, or the reports directory was empty.
- **ping_c4 regression-like data in baseline itself:** qps drops from 727 → 646 between c2 and c4 with 4 errors. Confirm whether this is saturation (expected) or a contention bug worth fixing before freezing the baseline.
- **Claimed numbers with no cited run:** "13.18× I/O improvement" and "<50 ns 8D L2 distance" are referenced in CLAUDE.md / docs but the exact benchmark command + raw output is not reproduced here; need a Phase 2 re-run to confirm.
- **`../geode-test-harness` path in CLAUDE.md resolves differently depending on cwd.** From repo root `/home/benji/src/devnw/codepros/geode/geode`, `../geode-test-harness` = `/home/benji/src/devnw/codepros/geode/geode-test-harness` (exists). From a deeper `src/` cwd it would resolve elsewhere. The Makefile targets cd into the repo root first so this works, but any ad-hoc instructions that mention `../geode-test-harness` need to land in a shell at repo root.
- **`phase1_benchmarks.zig` naming collision risk:** there is already a `benchmarks/phase1_benchmarks.zig` for an earlier "Phase 1" (likely a dev-cycle phase, not this audit phase). Keep audit artifacts under `docs/audit/` to avoid confusion.
- **Profiler gaps:** `hyperfine` and `pprof` are absent on this host. `perf` is available for CPU profiling; flamegraph tooling status UNKNOWN. If Phase 2 wants statistical wall-clock comparisons across two builds, install `hyperfine` or fall back to `zig`'s variance runners.
- **GPU benches are present** (`src/benchmarks/bench_gpu_*.zig`) — do not blindly run in an environment without CUDA. Gate these.
- **Distributed path gated on `GEODE_CLUSTER_TOKEN`** — measurements below default single-tenant mode do not exercise `src/distributed/` hot paths.
