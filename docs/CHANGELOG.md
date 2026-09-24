# Changelog

## [Unreleased] - Time-Series Audit and Gap Closure

### Added

- **CANARY Governance Tokens:** 24 CANARY markers added across timeseries source files (GAP-0281)
- **Legacy GAP ID Mapping:** Documented mapping from Grey Cardinal GAP-004/005/006 to GAP-0279+ numbering (GAP-0288)
- **Time-Series Audit Report:** `docs/TIMESERIES_AUDIT_REPORT.md` tracking all timeseries gap status

### Fixed

- **Documentation Accuracy:** Updated MIGRATION_GUIDE.md to reflect partial server wiring status and list in-progress functions (GAP-0291)
- **SUM/FIRST/LAST Aggregations:** Added test coverage for missing aggregation types (GAP-0284)
- **valueAt/timeBucketAvg Edge Cases:** Added boundary and empty-input tests (GAP-0285)
- **Step/Nearest Interpolation:** Added tests for step and nearest interpolation methods (GAP-0286)

---

## [v0.8.23] - Unreleased

### Security

- **QUIC listener certificate auto-generation fails closed in production
  (SONNY-2394):** this covers `QuicTransport.listen`'s own auto-generation
  only. That path serves the listeners whose certificate is not prepared at
  startup: the intra-cluster (cluster and Raft) QUIC listeners and the
  remote-KMS server. Such a listener self-signs a missing certificate only in
  dev posture (Debug build, `GEODE_ENV` not `production`) or when explicitly
  enabled (`GEODE_TLS_AUTOGENERATE_CERT=1`, or the per-listener
  `cert_auto_generate = .always` transport config). In production posture
  (release build or `GEODE_ENV=production`) it refuses to start instead.
  Server startup is unchanged: `geode serve` without `--cert`/`--key` still
  generates a self-signed certificate at startup when none exists (in its data
  or certificate directory, or `/tmp` when that is not writable), in every
  posture.

---

## [v0.8.22] - September 19, 2026

Concurrency memory-safety fix in the graph-storage adjacency read path.

### Fixed

- **Borrowed-slice torn read on concurrent edge append (SONNY-1797):** the
  adjacency-list accessors now take an acquire-ordered (ptr,len) snapshot that
  pairs with the appender release publish, eliminating a torn
  one-past-the-old-buffer out-of-bounds read (UAF-class) reachable by any
  concurrent reader during edge append. The `test_edge_torn_read_stress`
  regression is un-quarantined and back in the sharded `test` suite.

---

## [v0.8.21] - September 19, 2026

grpc-zig fixes propagated through the devnw/zig dependency diamond, plus
Prometheus exposition naming (SONNY).

### Fixed

- **grpc-zig RST_STREAM handled as a stream error (SONNY-1838):** re-pinned
  onto grpc-zig v0.1.12, which handles an inbound RST_STREAM as an HTTP/2
  §5.4.2 stream error — failing only that stream's RPC and continuing to read
  the connection — instead of tearing the whole connection down and dropping
  every other in-flight RPC. GOAWAY and real connection loss still tear down.
- **grpc-zig FIPS dependency resolvable (SONNY-1852):** grpc-zig v0.1.12 pins
  `.fips` to the published git dependency (the spine's v0.1.1 content hash)
  rather than a machine-local `.path`, so `-Dfips=true` and the FIPS CI job
  resolve.
- **Prometheus naming conventions on /metrics (SONNY-1807):** the OTel →
  Prometheus responder now applies Prometheus/OpenMetrics naming — `_total`
  for monotonic counters and base-unit suffixes (`_seconds`, `_bytes`) — so
  scrapers and dashboards work without manual renaming.

### Changed

- **Dependency diamond re-pinned onto grpc-zig v0.1.12:** the `zig-tool
  sync-diamond` cascade re-released the ~18 intermediate devnw/zig libraries
  (otel v0.1.24, quic v0.1.44, geode-client-zig v0.3.12, graph-storage v0.4.6,
  …) so a single grpc-zig version converges across the dependency tree.

---

## [v0.8.20] - September 18, 2026

QUIC stream semantics: sibling-stream binding, idle-stream reclamation, and
statement cancellation on the wire (SONNY).

### Fixed

- **Unbound sibling QUIC streams (SONNY-1835):** a sibling stream opened without
  its own HELLO inherited no tenant/graph identity and silently returned zero
  rows. Such an unbound sibling is now refused with a typed error (GQLSTATE
  08003) instead of running unbound. Clients that send a per-stream HELLO,
  including the Go driver, are unaffected.
- **Statement cancellation on the QUIC wire (SONNY-1841):** there was no way to
  cancel an in-flight statement, so an abandoned mutation ran to completion
  holding the per-graph write lock to its ~120s deadline and blocking the next
  writer on another connection. A per-stream CANCEL message (proto oneof tag
  15, backward-compatible — old clients simply never send it) and a QUIC stream
  reset now abort the statement; the write path polls the cancellation and
  releases the write lock promptly (SQLSTATE 57014).

### Changed

- **Idle-open sibling stream reclamation (SONNY-1837):** idle-open sibling QUIC
  streams can now be reaped on an independent, tighter deadline via
  `GEODE_QUIC_STREAM_IDLE_REAP_MS` (default 0 = opt-in; the existing ~300s
  connection-deadline reclamation and the admission rejection on slot
  exhaustion are unchanged), letting operators reclaim stream-pool slots faster
  under handshake pressure.

---

## [v0.8.19] - September 18, 2026

Engine metrics correctness and QUIC teardown safety, plus CI/test-suite
hardening. Cut to unblock the sonny-upstream integration work (SONNY).

### Fixed

- **Cluster node health metric (SONNY-1803):** `geode.cluster.node.health`
  was a monotonic Counter and could never represent a return to healthy. It is
  now a Gauge (0 = unhealthy, 1 = healthy) observable in both directions.
- **QUIC stream-teardown use-after-free read (SONNY-1794):** teardown proved
  stream liveness by reading `tracking_index` on a wrapper that could already
  be freed. Membership is now decided by a pointer-only scan of the tracked
  list under `streams_mu`, so a freed wrapper is never dereferenced.
- **Accept-reactor inbox churn (SONNY-1796):** the stream accept reactor's
  `drainPending` discarded and reallocated the pending inbox on every
  non-quiet pass; it now reuses the backing capacity across passes.
- **Resident node-cache use-after-move (SONNY-1979):** `getNodePtrForScan`
  returned a live `*Node` into a shard's `AutoHashMap` value storage; a
  concurrent hydration insert that grew that shard rehash-moved the value,
  dangling the pointer (CWE-362, use-after-move). Resident hits are now
  snapshotted into a grace-lifetime detached box under the shared shard lock
  (matching the existing scan-miss path), so the returned pointer is stable
  across a concurrent shard grow.

### Changed

- **Bounded metric cardinality (SONNY-1805):** `db.namespace` on graph
  mutation metrics no longer emits the raw, unbounded (tenant-revealing) graph
  name; it emits a bounded id.
- **Closed metric label sets (SONNY-1806):** the reason/strategy attributes on
  the transport-close, query-plan, audit-drop, and CDC-drop metrics are now
  closed enums instead of open `[]const u8` strings.

### CI / Tests

- **Serialized k8s test shards (SONNY-1798):** the two 8-way test-stage
  matrices now carry a per-shard `resource_group`, capping concurrent pods.
- **Load-independent pre-push assertions (SONNY-1799):** the startup
  lazy-hydrate and gap0813 timing assertions no longer flake under host load;
  the gap0813 latency budget scales under CI.
- **Quarantined intermittent torn-read stress (SONNY-1797):**
  `test-edge-torn-read-stress` removed from the aggregate `test` step (still
  standalone-runnable), tracked in `docs/KNOWN_TEST_ISSUES.md`.
- **Verified SONNY-1795:** the `close_app_error` double-latch was confirmed
  already resolved — it is latched only in the disjoint `close()` and
  `requestShutdown()` paths.
- **Join spawned workers on all paths (SONNY-1982):** the lazy-hydrate
  concurrency tests could let a spawned worker outlive its test body on an
  error path (a `try` between spawn and join), which SIGSEGV'd under Zig's
  `--listen` test runner in the x4-sharded pre-push. Each worker is now joined
  on every exit path (guarded `defer`, release-then-join before captured state
  dies), fixing a pre-existing pre-push flake.

---

## [v0.8.18] - September 16, 2026

CI-only re-cut of v0.8.17. No engine code changes.

### Fixed

- **Cross-build shards (CI):** the v0.8.17 tag pipeline lost both aarch64
  cross-build shards to an out-of-memory kill inside `zig build` on the k8s
  cluster runner, so `build-release` never ran. `test-cross-build` now runs on
  the dedicated docker-executor fleet with `zig build -j2`. The v0.8.17 tag
  remains but never produced an image or packages.

---

## [v0.8.17] - September 16, 2026

CI-only re-cut of v0.8.16. No engine code changes.

### Fixed

- **Cross-build OpenSSL prefix (CI):** Debian removed openssl `3.5.6-1~deb13u2`
  from the trixie pool on 2026-09-16, so `scripts/ci/fetch-openssl-prefix.sh`
  404'd and the v0.8.16 tag pipeline's `aarch64-linux-gnu` cross-build failed
  before `build-release` could run. The Debian pins are refreshed to
  `3.5.7-1~deb13u2` with digests cross-checked against the trixie Packages
  index. The v0.8.16 tag remains but never produced an image or packages.

---

## [v0.8.16] - September 15, 2026

Engine release. Re-pins the whole `devnw/zig` dependency spine onto
grpc-zig v0.1.10 (SONNY-1568 per-connection reader threads) via the
`zig-tool sync-diamond` cascade, and ships the reviewed server/execution
/storage/transport fixes.

### Fixed

- **Tenant scope on engine-direct reads (SONNY-1229):** engine-direct reads now
  apply the caller's tenant scope instead of bypassing it.
- **Node-scan fast path (SONNY-1218):** the fast path is declined when no
  storage adapter is present rather than silently returning unscoped rows.
- **Tenant visibility in graph execution (SONNY-1318):** scoped degree workers
  hardened, FTS fails closed under strict tenancy, union-find edges are read by
  value, and the thread-safety audit was corrected.
- **Tenant scope in path and subquery operators (SONNY-1326):** `shortestPath`,
  `COUNT{}`, `EXISTS{}` and pattern comprehensions apply tenant scope;
  `graph_procedure_tenancy` is advertised as a capability.
- **UNION read-only gate (SONNY-1330):** the gate walks CTE bodies and
  expression subqueries, and parallel UNION arms no longer mutate shared state.
- **Exact-index persistence accounting (SONNY-1574):** a skipped or unattempted
  exact-index persist is never reported as done; it counts only for a FULL
  checkpoint the engine accepted, a timed-out worker wait fails, and the persist
  is spawned outside the build mutex.
- **gRPC flow control (SONNY-1560):** a pushed gRPC result no longer holds the
  session mutex across a page write; a stalled, abandoned or superseded stream
  releases the session cursor deterministically; an unsatisfiable peer
  flow-control window is classified `RESOURCE_EXHAUSTED` instead of being waited
  out; the library's RST ends an exhausted stream and the flow-control seam is
  pinned.
- **QUIC connection lifecycle (SONNY-1219):** every server-initiated connection
  close is named, the five try-escapes out of `handleQuicConnection` are named,
  stream wrappers are no longer double-freed, stream release is idempotent, and
  the accept reactor's OOM teardown runs outside `shard.mu`.

### Changed

- Re-pinned `grpc_zig` to v0.1.10 and cascaded the 18 intermediate libraries
  that sit between it and the engine (see the release report for the full tag
  list).

### Known limitations

- **Server-initiated close codes are named on the SENDING side only.** The
  connection-close codes introduced by SONNY-1219 are set when the server
  closes, but a peer cannot read them: the vendored quic layer discards the
  close code on receive. Until that is fixed the codes are useful for
  server-side logging and tests only, not for client-side behavior. Tracked as
  **T-8**.

---

## [v0.18.1] - January 28, 2026

### Added

- **TDE File-Level Encryption:** Extended TDE to all persistent storage files:
  - Index persistence: R-tree, HNSW, Patricia trie, Domain trie, JSONB inverted, Interval tree
  - Schema catalogs: Main catalog and FLE catalog
  - Distributed state: Raft consensus state, snapshots, and log files
  - All files encrypted with AES-256-GCM when `GEODE_TDE_KEY` is set
  - CANARY markers added: REQ-TDE-FILELEVEL-001

### Documentation

- Added [TDE_FILE_LEVEL_ENCRYPTION.md](TDE_FILE_LEVEL_ENCRYPTION.md)
- Updated SECURITY_PROGRESS.md with file-level encryption status
- Added geodetestlab spec: `tde_filelevel_encryption.yml`

---

## [v0.1.0] - Grey Cardinal Compliance

### Added

- **Backup Encryption:** Implemented AES-256-GCM encryption for backup files (GAP-005). Requires `GEODE_TDE_KEY`.
- **Time-Series Integration:** Added `timeseries.value()` GQL function to access in-memory time-series data (GAP-004).
- **WAL Replay:** Implemented WAL replay logic for incremental backup recovery (GAP-002).
- **Benchmarks:** Added Time-Series benchmarks (`src/benchmarks/bench_timeseries.zig`) (GAP-006).

### Fixed

- **Backup Compression:** Fixed shim implementation to use real ZStandard compression (GAP-001).
- **Graph Centrality:** Cleaned up unused headers; deferred advanced metrics to v0.18 (GAP-003).

### Security

- **TDE:** Transparent Data Encryption for backups.

---
Add OpenCL integration into GPUAccelerator: compile kernels via clCreateProgramWithSource/clBuildProgram/clCreateKernel, and store program/kernel/queue in KernelCompiledOpenCL; prepared Launch/Copy paths will be implemented later.
