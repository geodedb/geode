# Benchmark Report - Grey Cardinal Compliance

## Overview

This report documents the performance benchmarks created for the Grey Cardinal specification compliance, focusing on Time-Series integration.

## Time-Series Benchmarks (GAP-006)

**Benchmark File:** `src/benchmarks/bench_timeseries.zig`

### Methodology

The benchmark measures two key metrics:

1. **Ingestion Rate:** Rate of inserting `Point` structs into the in-memory `Store`.
2. **Query Rate:** Rate of GQL `evalExpr` calls resolving `timeseries.value()` against the store.

### Configuration

- **Medium Load:** 100,000 points, 100,000 queries.
- **Large Load:** 1,000,000 points, 100,000 queries.

### Expected Results (Target)

- **Ingestion:** > 10M points/sec (in-memory).
- **Query:** > 1M ops/sec (GQL eval overhead included).

*Note: Runtime verification was skipped due to execution environment limitations, but the benchmark code is available for validation in CI/CD environments.*

## Audit Latency Benchmarks (GAP-0168)

**Benchmark File:** `benchmarks/benchmark_audit_latency.zig`

<!-- CANARY: REQ=REQ-BENCHMARK-AUDIT-002; FEATURE="Audit Latency Benchmark"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=monitoring; UPDATED=2026-01-14 -->

### Methodology

The benchmark measures three key aspects of audit logging performance:

1. **Single-Threaded Audit Write Latency:** Time to serialize and buffer an audit entry
2. **Concurrent Audit Writes:** Multi-threaded throughput under contention
3. **WAL fsync Ordering:** Latency of durability guarantees via fsync

### Configuration

- **Single-Threaded Test:** 10,000 iterations with JSON serialization
- **Concurrent Test:** 4 threads × 2,500 iterations each
- **WAL Test:** 100 fsync operations with 4KB page writes

### Performance Targets

| Metric | Target | Threshold |
|--------|--------|-----------|
| Avg Audit Write Latency | < 10 μs | P99 < 100 μs |
| Audit Throughput (single) | > 100K ops/sec | N/A |
| Audit Throughput (concurrent) | > 500K ops/sec | 4 threads |
| WAL fsync Latency | < 1 ms avg | Platform-dependent |
| WAL Write Throughput | > 10 MB/s | 4KB pages |

### Latest Results (Reproducible)

Run benchmarks with:

```bash
zig build benchmark
# Or run specific benchmark:
zig build-exe benchmarks/benchmark_audit_latency.zig && ./benchmark_audit_latency
```

**Single-threaded audit writes:**

- Typical avg latency: 500-2000 ns (0.5-2 μs)
- P50: ~500 ns
- P95: ~1000 ns
- P99: ~5000 ns
- Throughput: 500K-2M ops/sec

**Concurrent audit writes (4 threads):**

- Total throughput: 1M-4M ops/sec
- Avg per-operation latency: 200-1000 ns

**WAL fsync ordering:**

- Avg fsync latency: 50-500 μs (SSD-dependent)
- Write throughput: 20-100 MB/s

## TDE Encryption Overhead Benchmarks

**Measurement:** `zig build test-sonny6435-tde-overhead`
(`tests/test_sonny6435_tde_overhead.zig`; also part of `zig build bench`).
The former `benchmarks/benchmark_tde_overhead.zig` hashed a buffer and called
it encryption, and reported `overhead_pct=0.00 (simulated)`; it was removed
with the unbuilt `benchmark_tde_oltp_overhead.zig` simulation (SONNY-6435).

<!-- CANARY: REQ=REQ-BENCHMARK-TDE-001; FEATURE="TDE Overhead Benchmark"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=security; UPDATED=2026-11-12 -->

The storage engine runs the same insert-and-read workload with page and WAL
encryption off and on, interleaved, ReleaseFast. Measured 2026-11-12 on a
shared, loaded dev host (details and limits in
[docs/TDE_FILE_LEVEL_ENCRYPTION.md](docs/TDE_FILE_LEVEL_ENCRYPTION.md#measured-overhead)):

| WAL sync | Overhead (median) |
|----------|-------------------|
| `each_commit` (default) | +0.7% (four runs: -1.3% to +0.7%) |
| `deferred`, no checkpoint (commit path CPU cost) | +19.5% (three runs: +19.5% to +21.0%) |

| Metric | Target | Evidence |
|--------|--------|----------|
| Page Encryption Throughput | > 30 MB/s | AES-256-GCM (`benchmark_tde_encrypt_pages`) |
| Key Derivation | < 1 ms | Per-session (target, not measured here) |

## RLS/ABAC Authorization Benchmarks

**Benchmark File:** none. `benchmarks/benchmark_rls_abac_variance.zig`, which
no build step built, timed a placeholder policy catalog defined in
`tests/canary_rls_abac.zig`, not geode's RLS/ABAC engine; both were removed
(SONNY-6548). The targets below are not measured.

<!-- CANARY: REQ=REQ-BENCHMARK-ABAC-001; FEATURE="ABAC Benchmark"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-14 -->

### Performance Targets

| Metric | Target |
|--------|--------|
| RBAC Permission Check | < 1 μs |
| ABAC Policy Evaluation | < 10 μs (5 policies) |
| RLS Filter Generation | < 100 μs |

## Benchmark Reproducibility

All benchmarks can be reproduced locally via:

```bash
# Full benchmark suite
zig build benchmark

# Subset for CI
zig build bench

# Individual benchmark
zig build-exe benchmarks/<benchmark_name>.zig
./<benchmark_name>
```

Benchmarks emit JSON results compatible with CI artifact collection.

---

*Last Updated: 2026-01-14*
*CANARY: REQ=REQ-BENCHMARK-EVIDENCE-001; FEATURE="Performance Evidence"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=monitoring; UPDATED=2026-01-14*
