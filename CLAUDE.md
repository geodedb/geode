# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🏆 Project Status (June 2026)

**DEVELOPMENT READY (single-tenant).** Geode is a **single-tenant** graph database with strong ISO GQL alignment and active development (canonical status: [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) + [docs/KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)). Multi-tenant hardening landed substantially on the `gap-closure-2026-06-09` branch (strict-tenancy auto-default, tenant-hierarchy enforcement in read paths, FLE request-context, tenant-drop cascade, insecure-allow-all production guard, FLE audit-chain fix, durable `ALTER POLICY`), but multi-tenant deployments, distributed clusters, and the full RLS expression compilation path still carry documented residuals and require operator review before production use — see Known Limitations below.

- **✅ Local test baseline: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)** (canonical; expected ~175/179 named `zig build test-*` steps pass after the GAP-0863 rebaseline — exact counts refresh at each round's final sweep, failures named with file:line evidence). The monolithic `zig build test` is blocked by a protobuf union-submessage limitation; the per-step sweep is the canonical local gate. A fresh geodetestlab integration-suite (`../geode-test-harness`) run is owed (prior ~97% / 1644-1688 kept as a dated historical snapshot).
- **✅ ISO/IEC 39075:2024 conformance suite: 96/96** in the named `tests/gql_iso_conformance.zig` suite (`zig build test-iso-conformance`; **parse-only scope** — it asserts parser accept/reject, not executed results). The executed-query `gql_conformance` harness suite is 20/20 after GAP-0892 (`zig build test-gql-conformance`). This scopes "compliance" to those named suites — not a blanket "100% standards-compliant" claim. See [GQL_COMPLIANCE.md](docs/GQL_COMPLIANCE.md) for the verified-forms list and residual limits (e.g. recursive-CTE working-set model, no `SEARCH`/`CYCLE`).
- **✅ 5,094 CANARY Markers** tracking requirements (85.2% TESTED, 223 IMPL = 4.4%, plus EXEMPT/BENCHED per `docs/status.csv`; run `make status-generate` for current counts). GAP-0514 (CANARY IMPL governance debt) **closed 2026-06-11** — residual IMPL markers are enumerated per-file in the journal and dominated by vendor-blocked (grpc_zig), PTY-only, and fault-injection-only lanes.
- **✅ Enterprise Features** implemented (TDE, audit, vector search, backup/restore CLI, enhanced RLS) — see limitations below for multi-tenant and backup caveats
- **✅ ALL TODO.md PHASES COMPLETE** - All 7 development phases implemented (Phases 2-7)

### Known Limitations

- **Single-tenant recommended for production.** Multi-tenant deployments require operator review of the open gaps in `docs/GAP_ANALYSIS.md` before enabling. The storage-level tenant isolation primitives (`getAllNodesForTenant`, `getNodesByLabels(..., tenant)`, `getEdgesByType(..., tenant, graph)`) are correct and regression-tested, but the full cross-cutting concern has not been end-to-end audited against a multi-tenant benchmark suite.
- **Multi-tenancy query isolation (GAP-0509, Closed 2026-04-11)**: all 17 full-scan sites and 7 label-indexed sites in `match_operations.zig` apply `passesTenantFilter`/`getNodesByLabels(..., tenant)`. `listNodeLabels`/`SHOW TABLES` now takes a `filter_tenant` parameter pulled from `ExecutionContext`. Regression cover in `tests/test_gap0509_tenant_isolation.zig`. Residual: the unsafe `evaluateAggregation`/`evaluateAggregationWithLabels` functions in `aggregation_evaluation.zig` were removed entirely via GAP-0739 (2026-04-16, commit `4be895a9`); only a tombstone comment remains. The surviving aggregation entry points (`evaluateGroupAggregation`, `evaluateNodeExpression`, `computeBindingGroupAggregation`) operate on already-tenant-filtered bindings and never iterate `store.nodes` directly.
- **RLS expression engine (closed 2026-04-11; see `docs/GAP_ANALYSIS_RESOLVED.md`)**: wired at server startup (`setGlobalExprRLSEngine` in `src/server/main.zig:638`) and read from the match loop (`passesRLSExprFilter` in `src/execution/match_operations.zig:125`). Compiled bytecode policies enforce property-based row-level filtering via `checkRowAccessByUsername`. Regression cover in `tests/test_rls_expr_engine_wiring.zig`. Residual: the GQL → bytecode pipeline for policy compilation is still manual — policies must be pinned with a pre-compiled `CompiledExpression` until the parser path lands. Temporal policies (`TemporalConstraint`) evaluate but have no end-to-end tests.
- **Distributed module (GAP-0513, Closed 2026-04-10)**: per `docs/DISTRIBUTED_GAP_ANALYSIS.md`, all distributed gaps closed via commit `68ff42c4`. NodeRegistry covered by `src/distributed/test_query_transport_node_registry.zig` (inline copy — see that file's note about drift risk). Activates only when `GEODE_CLUSTER_TOKEN` is set; `--no-cluster` (default) bypasses this path entirely.
- **Auth defaults**: Authentication is enabled by default (fail-closed) and must be configured with credentials before deployment. A user with no stored role resolves to `none` (no global access; only its per-graph grants), not `readwrite` (breaking, 2026-10; see [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md#users-with-no-stored-role-fail-closed-default)).
- **Multi-tenant hardening (GAP-0842 + 2026-06-09/10 branch)**: never set `--insecure-allow-all` in production — it bypasses tenant isolation, RLS, and FLE authz for every request. This branch hardened the path substantially: strict-tenancy is now the **auto-default** in multi-tenant mode (GAP-0848; `--strict-tenancy` / `GEODE_STRICT_TENANCY=1`, GAP-0840), `--insecure-allow-all` is refused in production posture by a startup guard (GAP-0850), tenant-hierarchy is enforced in the read paths with two real isolation-leak fixes (GAP-0846), FLE carries a per-request role/tenant context (GAP-0852), tenant DROP cascades to owned graphs (GAP-0847), and the FLE audit-chain corruption that broke restart was fixed (GAP-0854). Documented residuals: the LSP tenant is still client-asserted (GAP-0818, Partial), and per-tenant at-rest encryption keys are deferred (see `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`). See [docs/security/MULTI_TENANT_HARDENING.md](docs/security/MULTI_TENANT_HARDENING.md).
- **CANARY coverage (GAP-0514, Closed 2026-06-11)**: repo-wide CANARY IMPL is 223/5,094 (4.4%; TESTED 85.2%) per `docs/status.csv` — under the ≤250/≤5% acceptance target. Phase 6 (P1–P3, 2026-06-10/11) reconciled every hotspot file with run-backed evidence. Honest residuals (223 markers) are governance hygiene, not functional defect, and are dominated by the `grpc_server.zig` lanes (GAP-0893 — long attributed to a vendor `grpc_zig` 0.1.7 listener crash, re-diagnosed 2026-08-25 as two geode-side defects and FIXED; those markers are now promotable against green runs), PTY-only REPL lanes, and fault-injection-only lanes.
- **MCP server (GAP-0516, Closed 2026-06-10)**: resource subscriptions stay intentionally unimplemented — Geode does not produce streaming resource-change notifications, so `subscribeResourceHandler`/`unsubscribeResourceHandler` (`src/mcp/server.zig`) return `error.MethodNotFound` → JSON-RPC `-32601` (spec §4.5, the canonical "method not implemented" signal); clients poll via `resources/read`. Regression `tests/test_gap0516_mcp_capabilities.zig` (`zig build test-gap0516`) drives the real `mcp.Server.processMessage` dispatch and asserts the implemented subset (`tools/list`, `resources/list`, `resources/templates/list`, `prompts/list`, `logging/setLevel`) succeeds while subscribe/unsubscribe return `-32601`. **Caveat pinned by the test:** the pinned `mcp` v0.1.12 library hardcodes `resources.subscribe:true` in its `initialize` response with no override, so the advertised capability string cannot be made truthful without forking the dependency — the runtime-truthful contract is the handler's `-32601`. `completeHandler` forwards to the LSP completion path; `setLogLevelHandler` is a safe no-op. See [docs/MCP_SERVER.md](docs/MCP_SERVER.md). **`tools/call` result leak (fixed 2026-08-29):** `mcp` v0.1.11 hardcoded `.owned = false` for every `tools/call` dispatch result while the free site only frees `owned` results, leaking every dynamically-allocated tool response for the life of a long-running `geode mcp` server; v0.1.12 (upstream commit `956b07d`) marks `tools/call` results `owned = true` and documents the ownership contract on `Handler.callTool`. Regression proof: `tests/test_mcp_read_only.zig` now drives real `tools/call` round trips under the strict `std.testing.allocator` (previously worked around with `std.heap.page_allocator` to dodge the upstream leak).
- **Auth DDL persistence**: Auth DDL writes persist to the HMAC-chained `__geode_security` graph and survive restart (users, roles, password/role/active changes, and per-graph `GRANT … ON GRAPH …`). Hydrated at startup via `PersistentUserResolver`, `hydrateCustomRolesFromGraph`, and `GraphRBACPolicy.loadGraphGrants`. Residuals: no model for a `GRANT <privilege>` without `ON GRAPH` (global privilege is governed by the user's role); custom-role membership beyond the built-in role field is not modeled and assignment is refused with SQLSTATE 0A000 (SONNY-6292), rather than acknowledged without an effective grant; GPS policy DDL (`CREATE`/`ALTER`/`DROP POLICY`, incl. `RENAME TO`) now persists durably with the same write-through pattern (GAP-0858, `zig build test-gap0858`) — the remaining RLS residual is the manual GQL→bytecode expression-compilation path; the BIND-time per-graph grant check is additive/permissive in default single-tenant config. See [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md) for the full persistence spec and known limitations.
- **Cluster-mode fail-closed surfaces (2026-06-10)**: in cluster mode (`GEODE_CLUSTER_TOKEN` set), write surfaces with no Raft replication slice are refused instead of silently applying node-locally (`cluster.gateUnreplicatedWrite()`: follower → `ClusterNotLeader`, leader → `ClusterWriteNotReplicable`). Gated surfaces: `geode.ts.insert`/`insert_many`, auth DDL + mutating `geode.auth.*`, policy DDL, tenant create/drop/set_quota, CREATE/DROP INDEX, CREATE/DROP GRAPH, constraints, mutating TDE/CDC/FLE procedures. Standalone mode is unaffected. `MATCH…CREATE` now replicates within its documented slice (head-only named MATCH chains, each var resolving to exactly one node, CREATE endpoints pure var refs, scalar edge props, ≤32 edges); residual shapes (Cartesian matches, new node minted inside the CREATE pattern) fail closed. e2e: `tests/test_cluster_replicable_mutations.zig` (7/7, incl. "unreplicated write surfaces fail closed"); netns coverage: M8 in `tests/cluster/netns_cluster_membership_churn_test.sh`. Closure log: `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`.
- **Full-text search bulk-MERGE auto-indexing (Closed 2026-08-28, Task 4)**: FTS is backed end-to-end by the external `fts-storage` LSM library (see Full-Text Search below). Node create / `SET` / delete keep a fulltext index current via the live-maintenance hook, and the **bulk-MERGE fast path** (`quic_connection_handler.zig`'s `executeBulkSimpleMerge` and its concurrent batch-mode sibling `executeBatchSimpleMerge`, reached via a `/*+BATCH*/`-prefixed program) now runs the SAME `fts_index_ops.maintainFulltextOnWrite` hook right after the apply completes and every graph lock is released — both call sites execute ON the connection thread (never the group-commit worker threads), satisfying the fts engine's single-writer-thread contract. Bulk-MERGE'd nodes are searchable IMMEDIATELY, no rebuild required. `CALL geode.fts.rebuild('<index>')` (Task 3) remains available as a recovery/backfill path — e.g. re-arming an index after a restore, or backfilling nodes written by an older binary before this fix. Regression: `tests/test_fts_bulk_merge_maintenance.zig` (`zig build test-fts-bulk-merge-maintenance`, adapter + fts_index_ops contract) plus the real end-to-end wire-path proof in `../geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml`. Ingestion invariant: after any bulk-ingestion run, verify FTS visibility with a canary query (`CALL geode.fts.search(...)` for a known term) before marking ingestion ready.
- **Full audit report**: See [docs/FULL_AUDIT_2026_04_06.md](docs/FULL_AUDIT_2026_04_06.md) (with 2026-04-11 closure-notes footer) for the comprehensive audit and per-gap resolution details.

## 📚 Documentation Structure

**Complete documentation is available in the [`./docs/`](docs/) directory:**

### Essential References

- **[Implementation Status](docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md)** - Complete feature status with evidence
- **[Features Overview](docs/FEATURES_OVERVIEW.md)** - Comprehensive feature catalog
- **[Development TODO](docs/TODO.md)** - All 7 phases complete (✅ 100%)
- **[Completion Reports](docs/completion_reports/)** - Detailed phase completion documentation
- **[Quick Reference](docs/QUICK_REFERENCE.md)** - Essential commands and syntax

### Technical Documentation

- **[API Reference](docs/API_REFERENCE.md)** - Complete API documentation
- **[Types & Functions](docs/TYPES_AND_FUNCTIONS.md)** - 50+ specialized data types
- **[GQL Compliance](docs/GQL_COMPLIANCE.md)** - ISO/IEC 39075:2024 conformance
- **[LSP Features](docs/LSP_FEATURES.md)** - Schema-aware completion, hover, and diagnostics with per-user permission filtering (stdio + embedded TCP transports)
- **[Test Runner Fixes](docs/TEST_RUNNER_FIXES_OCTOBER_2025.md)** - Recent test infrastructure improvements (Oct 2025)

### Enterprise & Security

- **[Advanced Security Features](docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md)** - Enhanced RLS implementation
- **[KMS Provider System](docs/KMS_PROVIDER_SYSTEM.md)** - Enterprise key management
- **[User Authentication](docs/USER_AUTH.md)** - RBAC/ABAC with TOTP MFA (SMS/email/U2F are planned, NOT implemented; step-up uses scoped `OperationClass` classification, fail-closed — GAP-0884, `zig build test-gap0884`)
- **[GQL Auth DDL](docs/GQL_AUTH_DDL.md)** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW statements (Geode extension)

### Advanced Features

- **[ML Graph Embeddings](docs/ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk (EXPERIMENTAL — simplified implementations; see GAP-0879 framing in that doc)
- **[Real-time Analytics](docs/REAL_TIME_ANALYTICS.md)** - Streaming analytics with ML integration
- **[Materialized Views](docs/MATERIALIZED_VIEWS.md)** - Enterprise view management
- **[Enhanced Transaction Isolation](docs/ENHANCED_TRANSACTION_ISOLATION.md)** - Advanced MVCC
- **[Distributed Query Coordination](docs/DISTRIBUTED_QUERY_COORDINATION.md)** - Federation-aware optimization

## 🎯 Implementation Status

### ✅ ALL TODO.md PHASES COMPLETED (October 16, 2025)

**Total**: ~13,554+ lines of production code across all phases

**Completed Phases**:

1. **Phase 2: Parser Extensions** - Map literals, deep nesting (8+ levels)
2. **Phase 3: Set Operations** - UNION/INTERSECT/EXCEPT, 22/22 tests passing
3. **Phase 4: Transaction Isolation** - Phantom read prevention, SSI, 6 isolation levels
4. **Phase 5: Distributed Coordination** - 10,451 lines of distributed systems code
5. **Phase 6: Materialized Views** - 3 refresh strategies, query rewriting
6. **Phase 7: Graph Algorithms** - 20-90% performance improvements

**Details**: See [docs/completion_reports/](docs/completion_reports/) for comprehensive phase reports

### ✅ ALL MAJOR FEATURES COMPLETED (October 2025)

1. **Backup/Restore** - Engine-backed `geode backup create` / `geode restore` CLI with full graph-data round-trip (S3 / Digital Ocean Spaces target supported). GQL `BACKUP`/`RESTORE` statements are NOT implemented (CLI only). Payload compression: `.gzip` has a real encoder (stdlib DEFLATE, GAP-0880); zstd/lz4/snappy are NOT wired — protocol upload-ingestion residuals remain tracked in GAP-0880. See Known Limitations.
2. **REPL QUIC Integration** - Real-time interactive shell with comprehensive features
3. **Vector Operations** - HNSW indexing with 6 distance metrics and SIMD acceleration
4. **Performance Optimization** - 13.18x I/O improvement, memory-mapped operations
5. **IndexOptimizer** - Cost-based query planning with statistics integration
6. **ML Graph Embeddings** - EXPERIMENTAL Node2Vec (real p/q-biased walks, seeded, real loss reporting), simplified GraphSAGE aggregation, DeepWalk (see docs/ML_GRAPH_EMBEDDINGS.md, GAP-0879)
7. **Real-time Analytics** - Streaming analytics with pattern detection and anomaly detection
8. **Enhanced Transaction Isolation** - Advanced MVCC with SSI and phantom read prevention
9. **Distributed Query Coordination** - Federation-aware optimization with load balancing
10. **Materialized View Refresh** - Complete refresh strategies with dependency tracking
11. **CLI Subprocess Elimination** - Unified binary architecture eliminating subprocess spawning
12. **Advanced Security Features** - Enhanced RLS with policy evaluation, expression compilation, and optimization
13. **GQL Auth DDL** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW USERS/ROLES/PERMISSIONS/VERSION/CAPABILITIES (Geode extension; see [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md)). Routes to existing geode.auth.* handlers — same authorization, audit, and __geode_security persistence. user_assign_role now mutates the user's built-in role. All auth DDL writes persist to the `__geode_security` graph (HMAC-chained, hydrated at startup) and survive restart.

### 🏗️ Architecture Overview

**Core Components**:

- **Parser/Lexer** (`src/gql/`): passes the 96/96 ISO conformance suite (`tests/gql_iso_conformance.zig`, `zig build test-iso-conformance`; parse-only scope, scoped to that suite — see [docs/GQL_COMPLIANCE.md](docs/GQL_COMPLIANCE.md))
- **Query Planner** (`src/planner/`): Cost-based optimization with statistics
- **Storage Engine** (`src/storage/`): MVCC, WAL, TDE with <1% overhead
- **Index System** (`src/index/`): 6 index types including HNSW and R-tree. Full-text search is backed by the external **`fts-storage`** LSM library (see Full-Text Search below) via `src/storage/fts_storage_adapter.zig`; the `FullTextIndex` facade (`src/index/fulltext.zig`) delegates to it.
- **Security** (`src/security/`): Enterprise authentication, audit, encryption, enhanced RLS
- **Transport** (`src/transport/`): QUIC+TLS (`--listen`, always available) plus gRPC over HTTP/2 (`--listen-grpc`, requires OpenSSL 3.x at build and run time; fails closed with `error.TlsRequired` where it is absent). Per-target availability and the `libssl.so.3` runtime requirement are documented in [docs/GRPC_TRANSPORT.md](docs/GRPC_TRANSPORT.md) and enforced from `release/target_manifest.json`.

### 🔎 Full-Text Search (fts-storage-backed)

Full-text search uses the external **`fts-storage`** LSM library as the **primary backing store**, surfaced as a native Geode GQL extension. The legacy in-memory inverted index + bespoke `fulltext_persist.zig` were removed; durability now comes from the library's WAL + segments + manifest.

- **Layout / adapter**: `src/storage/fts_storage_adapter.zig` is a per-graph registry of `fts_storage.Engine`s, one per index, under `{graph_dir}/fts/<index_name>/`. The `FullTextIndex` facade (`src/index/fulltext.zig`) delegates to the adapter; tokenization lives in `src/index/fts_tokenizer.zig`.
- **GQL surface** (native Geode extension, ISO-GQL-compliant in form):
  - `CREATE INDEX <name> FOR (n:Label) ON (n.prop[, n.prop2]) USING fulltext` — creates a fulltext index and backfills existing matching nodes.
  - `CALL geode.fts.search('<index>', '<query>'[, <max>])` — returns rows of `node` (id) + `score` (BM25), reachable over the QUIC wire. (This is ISO GQL's `CALL` procedure form — not a scalar function, and not Cypher `UNWIND`.)
  - `CALL geode.fts.phrase('<index>', '<phrase>'[, <max>])` and `CALL geode.fts.proximity('<index>', '<terms>', <distance>[, <max>])` — REAL position-based phrase/proximity search against the engine's persisted per-(term, doc) token positions (GAP-0869; the former hard-coded stubs in `src/fts/advanced.zig` were deleted). Byte-accurate highlighting via `FullTextIndex.highlight` (caller supplies post-RLS/FLE authorized content).
  - `DROP INDEX <name>` — drops the fulltext index (server stays alive; the fts-storage 0.1.1 single-writer thread-check fix makes cross-worker-thread DROP safe).
  - `CALL geode.fts.rebuild('<index>')` (Task 3) — drops+recreates+re-backfills a fulltext index from current store contents; YIELDs `index`/`nodes_indexed`. Recovery/backfill path (e.g. re-arming an index after a restore, or backfilling nodes written before the Task 4 live-maintenance fix below). The drop→create→backfill window is closed against concurrent writers (2026-08-29): `fts_storage_adapter.zig` tracks a per-index rebuilding flag + pending node-id set (`beginRebuild`/`noteWriteDuringRebuild`/`endRebuild`); a live write landing mid-window is queued instead of erroring on the momentarily-absent engine or double-appending past the backfill snapshot, and drained (plain re-index, never delete-then-reindex) after backfill completes. A second concurrent rebuild of the same index is refused (`RebuildInProgress`). Regression: `tests/test_fts_rebuild.zig`.
- **Live maintenance**: node create / `SET` / delete, AND the bulk-MERGE fast path (`executeBulkSimpleMerge` / `executeBatchSimpleMerge` in `quic_connection_handler.zig`, Task 4, 2026-08-28) keep the index current — including nodes inserted after the index was created and nodes written via bulk-MERGE. The bulk-MERGE hook runs on the connection thread right after the apply completes and every graph lock is released, satisfying the fts engine's single-writer-thread contract.
- **Durability**: indexes survive a server restart (lazy re-open of on-disk fts indexes on first query).
- **Dependency**: pinned in `build.zig.zon` as `.fts_storage` v0.1.1 (commit `908c1f54`). See [.migration/PUBLISH-CHECKLIST.md](.migration/PUBLISH-CHECKLIST.md) for the publish requirement.
- **Verification**: unit tests (`tests/test_fts_storage_adapter.zig`, `test_fts_tokenizer.zig`, `test_fts_e2e.zig`, `tests/test_fts_bulk_merge_maintenance.zig` for the bulk-MERGE maintenance contract, plus `tests/test_fts_apply_symmetry.zig` for raft-apply/snapshot maintenance), a native VarianceEnvelope benchmark (`benchmarks/benchmark_fts_storage.zig`), a CI-aware latency gate (`tests/test_fts_latency.zig`), and harness specs (`geodetestlab-cli/specs/fts_storage_basic.yml`, `fulltext_search_basic.yml`, `fts_bulk_merge_visibility.yml`). NOTE (2026-06-10): `tests/test_fts_maintenance.zig` and `tests/test_fts_coverage.zig` are DEAD code — they call a nonexistent `initGlobalStoreWithDataDir` and are pulled into `all_tests.zig` only as unreferenced consts (never analyzed by the compiler); do not cite them as live coverage.
- **Ingestion invariant**: after any bulk-ingestion run, verify FTS visibility with a canary query (`CALL geode.fts.search(...)` for a known term) before marking ingestion ready — cheap insurance even now that the bulk-MERGE fast path is live-maintained, and the only recovery signal on an older binary or a restore that predates an index.

See [docs/FULLTEXT_SEARCH.md](docs/FULLTEXT_SEARCH.md) for the full reference.

### ⏱️ Time-Series (timeseries-storage-backed)

Time-series uses the external **`timeseries-storage`** LSM library as its backing store (geode wraps it in `src/timeseries/timeseries.zig`, pinned in `build.zig.zon`). It was already the store layer; what's NEW is the native GQL surface to write + query it over the wire — surfaced exactly the way FTS is (`CALL geode.ts.*`, the analog of `CALL geode.fts.search`). Dispatch lives in `src/execution/ts_dispatch.zig`.

- **GQL surface** (native Geode extension, ISO/IEC 39075 `CALL`-procedure form — NOT Cypher; `YIELD` is optional, a bare `CALL` auto-projects its columns as rows):
  - WRITE (**mutating** — a read-only user cannot ingest): `CALL geode.ts.insert(device_id, metric, ts, value)` → YIELD `inserted` (count); `CALL geode.ts.insert_many(device_id, metric, [[ts, value], ...])` → YIELD `inserted`.
  - READ (**read-only** — queryable by a read-only user): `CALL geode.ts.range(device_id, metric, start_ts, end_ts)` → YIELD `ts, value` (one row per point, inclusive of both bounds); `CALL geode.ts.last(device_id, metric)` → YIELD `ts, value`; `CALL geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)` → YIELD `bucket_ts, avg`; `CALL geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)` → YIELD `bucket_ts, value` (agg ∈ avg/sum/min/max/count/first/last).
  - A series is identified by the `(device_id, metric)` pair (`device_id` an integer, `metric` a string).
- **Value type: integer (`i64`) only in this release.** `ts` and `value` are integers; a float/decimal value (e.g. `100.0`) is **rejected** with a clear error. Document `100`, not `100.0`. A float value lane is a deferred follow-up.
- **Wire protocol**: values ride the generic GQL rows wire protocol — **no client or proto change** (same posture as `CALL geode.fts.search`).
- **Concurrency / durability**: the timeseries Store is mutex-guarded for concurrent ingest from the QUIC worker pool (a new leaf-tier lock, see the lock-ordering table below); points persist (durable engine) and survive restart; `range` is inclusive `[start_ts, end_ts]` in both the in-memory and durable paths.
- **Verification**: unit tests (`tests/ts_ingest_roundtrip.zig` — ingest/read/restart/exactness/multi-series/bounds/concurrency/rejection), a native VarianceEnvelope benchmark + a CI-aware latency gate (added in a parallel commit), and a geode-test-harness spec (`timeseries_basic.yml`, forthcoming).

See [docs/TIMESERIES.md](docs/TIMESERIES.md) for the full reference.

## 🧮 Key Data Types

### **Vector Types** (Fully Implemented)

- **VectorF32**: Single-precision floating-point vectors with SIMD acceleration
- **VectorI32**: Integer vectors for discrete data and categorical embeddings
- **HNSW Index Support**: Production-ready with 6 distance metrics
- **IndexOptimizer Integration**: Automatic cost-based selection with logarithmic scaling
- **Performance**: <50ns for 8D L2 distance, supports up to 65,535 dimensions

### **Advanced Types** (Complete)

- **Network Types**: IPv4/IPv6, CIDR, MAC with <1μs parsing
- **Geographic**: Point, LineString, Polygon with R-tree spatial indexing
- **Cryptographic**: Hash types, digital signatures, encryption key management
- **Temporal**: DateTime with timezone support, intervals, duration arithmetic

## 🧪 Testing & Quality

### Evidence-Based Development

- **CANARY System**: 5,094 governance markers tracking requirements
- **Local test baseline**: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (canonical; expected ~175/179 named `zig build test-*` steps pass); a fresh geodetestlab harness run is owed (prior ~97% / 1644-1688 is a dated historical snapshot)
- **ISO conformance suite**: 96/96 in the named `tests/gql_iso_conformance.zig` suite (`zig build test-iso-conformance`; parse-only scope, not a blanket "100% compliant" claim); executed-query `gql_conformance` 20/20 (`zig build test-gql-conformance`)
- **Performance Benchmarks**: Automated regression testing
- **Status Breakdown**: 85.2% TESTED, 4.4% IMPL (223), plus EXEMPT/BENCHED (run `make status-generate` for current counts; GAP-0514 closed 2026-06-11)

### Test Execution

```bash
# Run all tests
python3 scripts/test/extended_test_runner.py

# Or use make targets
make geodetestlab-comprehensive

# Generate governance status
make status-generate

# Build and verify
make build && make verify-fast
```

### Zig Test Conventions

- **Every regression test is a named step.** Write it as `tests/test_<ticket>_<topic>.zig` and register it in `build.zig` as `zig build test-<name>`, with the RUN step passed to `shardDep` as the neighbouring tests do (`const run_x = b.addRunArtifact(x_tests); shardDep(test_step, &run_x.step, 1, test_shard_loads, test_shard_index);`). That is what puts it in the sharded aggregate `zig build test`, which the pre-push hook and the CI shard jobs run. `shardDep` rejects a compile step at configure time, because a compile step is built but never run (SONNY-2394). The one exception is an intentionally red TDD reproduction listed in [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md): it may stay out of `shardDep`, so the aggregate stays green, until the commit that fixes it registers it there, and until then its test artifact is added to `test-compile` directly (`if (g_test_compile_step) |c| c.dependOn(&x_tests.step);`).
- **Run `zig build test-compile` before claiming the aggregate is green.** It compiles every artifact the aggregate `test` step runs, in all shards, and every executable target, without running any of them. A sweep of named steps cannot see aggregate artifacts that have no named step, so a sweep can pass while the aggregate does not even compile (SONNY-2394). Executables join on their own, so a new one needs no registration; the exceptions are cross-target and Vulkan builds, and the executables that do not compile yet, listed in `build.zig`'s `rotted_executables` (SONNY-2746). It builds several hundred artifacts: run it on its own, not alongside other builds.

### Load Test Baseline Tracking

Load test results are tracked against baselines in `benchmarks/loadtest/` to detect performance regressions between releases. The system compares QPS and p50 latency at each concurrency level.

**Baseline file**: `benchmarks/loadtest/baseline.jsonl` (JSONL, one record per concurrency level)

```bash
# Run load tests (requires ../geode-test-harness with Go loadtest built)
cd ../geode-test-harness
GEODE_ADMIN_PASSWORD=<password> LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" make loadtest-go

# Compare results against baseline (from geode repo root)
make loadtest-compare

# Save current results as new baseline (after verified improvement)
make loadtest-save-baseline
```

**Regression thresholds** (configurable via `--threshold`):

- QPS: regression if current < baseline * 0.8 (20% drop)
- p50 latency: regression if current > baseline * 1.2 (20% increase)
- Error rate: regression if current > 10% and baseline was < 5%

**CI**: The `loadtest-regression` job in `.gitlab-ci.yml` runs comparison on MRs and main branch pushes (`allow_failure: true` initially).

**Updating baselines**: After performance improvements, run `make loadtest-save-baseline` to update the baseline. Commit the updated `baseline.jsonl` with the performance change.

### Geodetestlab Integration Test Suite

The full integration test suite lives in `../geode-test-harness/`. We highly recommend using the unified test target which runs the `geodetestlab` unit tests, integration tests, shell tests, and load tests all together:

```bash
# Run the complete test suite (unit, integration, shell, load tests)
cd ../geode-test-harness
make test-everything GEODE_BINARY=/path/to/geode

# Run just the integration suite (198 specs, ~25 min with 2 workers)
GEODE_BINARY=/path/to/geode make test

# Run single spec
make test-spec SPEC=geodetestlab-cli/specs/my_spec.yml
```

### OTel Monitoring During Tests / Benchmarks (debugging)

When a bug report involves "hung for N minutes", "connection died", "chunk failed",
slow queries, or any cross-layer behavior, **run the suite with OTel monitoring
enabled** to capture every span and metric geode emits during the run. This is
how you triage cascading failures across QUIC ↔ executor ↔ WAL ↔ storage without
having to instrument by hand.

The harness ships a docker `otel/opentelemetry-collector-contrib` lifecycle and
a one-shot Make target:

```bash
cd ../geode-test-harness
# One-shot: start collector → run full suite → verify spans landed → stop collector
make test-everything-otel GEODE_BINARY=/path/to/geode

# Manual control (debugging a specific spec or load profile)
make otel-start                      # docker collector on :44318 / :44317
make otel-tail                       # docker logs -f (live span/metric stream)
GEODE_OTEL=1 make test-spec SPEC=specs/foo.yml
make otel-verify                     # assert spans with service.name=geode arrived
make otel-stop                       # tear down
```

**Generated artefacts** (all under `../geode-test-harness/reports/`, gitignored):

- `reports/spans.jsonl` — every span/metric in OTLP/JSON, one record per line.
  Filter with `jq '.resourceSpans[].scopeSpans[] | select(.scope.name=="wal")'`.
- `reports/otel-collector.log` — drained collector stdout.
- `reports/.otel-env` — exact `OTEL_*` env vars sourced into the test run.

**InstrumentationScopes that fire** (updated 2026-05-29 — see [docs/OBSERVABILITY_ARCHITECTURE.md](docs/OBSERVABILITY_ARCHITECTURE.md)):

> **IMPORTANT:** dependent-library otel seams (wal, gql, dns, vulkan, thread_pool, repl, slog,
> protobuf) are **OFF** — every lib hardcodes `observability.enabled = false` and geode passes no
> `-Dwith_otel`. So those lib scopes do **NOT** fire (zero overhead). geode emits its OWN telemetry
> under `com.geodedb.geode`, and bridges lib-internal QUIC stats into `geode.runtime.*`.

| Scope | What geode emits |
|---|---|
| `com.geodedb.geode` (metrics) | `geode.query.*` (count/active/execution.duration/parse.duration/rows.returned), `geode.transport.*` (connection/request.duration/inflight/bytes), `geode.storage.*`, `geode.wal.*`, `geode.index.*`, `geode.transaction.*`, `geode.security.authorization.check.*`, `geode.security.rls.evaluation.*` (when an RLS policy is active), `geode.audit.*`, `geode.server.*` |
| `com.geodedb.geode` (`geode.runtime.*`) | 76 observable gauges bridging the runtime registry: QUIC RTT/cwnd/bytes-in-flight (`geode.runtime.quic_*`), 20 poll-phase timings, 13 stream-write counters, 24 first-stream phase metrics, `geode.runtime.proto_reader_*`, leaked-conn reaper |
| `com.geodedb.geode` (traces) | `geode.query.execute` SERVER span per statement (bounded attrs only). geode-side periodic flush drains the BSP (no-pool BSP has no timer) |

**Common debugging recipes**:

- *"chunk failed: driver: bad connection"* — look for `geode.transport.request`
  spans whose status is error and check `quic_active_connections` over the
  surrounding window. If `quic_min_smoothed_rtt_ns=12297829382473034410`
  (`0xAAAA…`) shows up, that's an uninit-stat sentinel — focus on whether
  the connection ever completed handshake.
- *Slow query investigation* — diff `gql.execute.PARSE` and
  `geode.query.execute` durations to see whether time is in parse, plan, or
  execute.
- *Pipeline cascade* — the `wal.*` span that errors first names the
  operation type (e.g. `wal.create_edge`); pair with `geode.graph_store.*`
  to localize.

The harness `CLAUDE.md` (`../geode-test-harness/CLAUDE.md`) has the deep dive
on collector defaults, port overrides, and `scripts/otel-collector.sh`
internals.

### Recent Test Improvements (October 2025)

- **stdin handling** in test runner fixed (critical issue)
- **Multi-statement execution** in CLI (session management workflows)
- **Reserved keywords** as parameter names ($count, $name, etc.)
- **IF NOT EXISTS** support in parameter clauses
- See [docs/TEST_RUNNER_FIXES_OCTOBER_2025.md](docs/TEST_RUNNER_FIXES_OCTOBER_2025.md) for details

## 🔧 Development Setup

### Quick Start (Recommended for New Developers)

```bash
# Clone and setup everything automatically
git clone https://gitlab.com/devnw/codepros/geode/geode.git
cd geode
make setup-dev
```

This installs pre-commit hooks, builds the project, and runs tests.

### Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for code quality enforcement:

```bash
# Install hooks (done automatically by setup-dev)
make pre-commit-install

# Run all checks manually
make pre-commit

# Update hooks to latest versions
make pre-commit-update
```

**Hooks run on commit:** formatting, linting, compilation checks
**Hooks run on push:** cross-compilation, full tests, CANARY verification

### Build & Server

```bash
# Build debug version
make build

# Build release version
make release

# Start server (QUIC+TLS only)
./zig-out/bin/geode serve --listen 0.0.0.0:3141

# Interactive shell
./zig-out/bin/geode shell

# Execute queries
./zig-out/bin/geode query "RETURN 1 AS x"
```

### Common Make Targets

```bash
make help              # Show all available targets
make setup-dev         # Full development setup (recommended)
make build             # Debug build
make release           # Release build
make test              # Run unit tests
make fmt               # Format Zig code
make pre-commit        # Run pre-commit checks
make cross-compile     # Cross-compile for all platforms
make geodetestlab-comprehensive  # Full integration test suite
make loadtest-compare  # Compare load test results against baseline
make loadtest-save-baseline  # Save current results as new baseline
```

## 📋 Code Conventions

### Language & Style

- **Language**: Zig 0.16.0+
- **Comments**: Minimal unless required for clarity
- **CANARY Markers**: Required for all implementations
- **Memory Safety**: Proper allocation/deallocation patterns

### Mutex Lock Ordering (GAP-0278)

When acquiring multiple mutexes, always acquire in this order (lower tier first):

| Tier | Mutex | Module | Notes |
|------|-------|--------|-------|
| 0 | `graph_handles_mutex` | `graph_storage_adapter.zig` | Graph handle map — brief lookups only, NEVER during data ops |
| 0.5 | `merge_tuple_locks[..]` | `graph_storage_adapter.zig` | Striped per-`(label, merge props)` MERGE tuple locks (GAP-0894). Acquired ONLY by the two bulk-MERGE fast paths (`bulkMergeNodeWithReservedIdForTenant`, `bulkMergeNodeWithReservedIdMultiPropForTenant`) and ONLY as the OUTERMOST graph lock: strict order is `merge_tuple_locks[i]` → per-graph `rwlock` (SHARED) → `shard_locks[..]`. **ENG-3914 (RC-2):** the `rwlock` SHARED hold must span the ENTIRE probe→insert, never be dropped and re-taken — the general MERGE path (`execution/crud_operations.zig` `executeMerge`, run under the connection handler's whole-graph `rwlock` EXCLUSIVE) takes NO tuple lock, so any zero-reader gap lets it complete a full probe→CREATE for the same key and duplicate the node. A caller holding `rwlock` (SHARED or EXCLUSIVE) must NEVER then acquire a tuple lock — that reversal is the ABBA deadlock. |
| 1 | `store_mutex` / per-graph `rwlock` | `graph_store.zig` / `graph_storage_adapter.zig` | Graph data — per-graph locks use alphabetical acquire order for multi-graph |
| 1 | `merge_prop_index_mutex` | `graph_store.zig` | MERGE property index — leaf-level, serializes `addToMergePropertyIndex` / `removeFromMergePropertyIndex` / `lookupMergeCandidate` |
| 1 | `perf_c_refcount_mutex` | `graph_store.zig` | PERF-C tenant-keyed refcount maps (issue #814) — leaf-level; serializes `bumpRefcount` / `decRefcount` and the `listNodeLabels` / `listEdgeTypes` / `listPropertiesForLabel` readers. MAY be acquired while `labels_rwlock` is held EXCLUSIVE (writers reach `bumpLabelCount` / `decLabelCount` inside their labels critical section), so the strict ordering is `labels_rwlock` → `perf_c_refcount_mutex`. |
| 1.5 | `rebuild_mutex` | `index/index_manager.zig` | Advanced-index REGISTRY + rebuild mutex. Guards `advanced_vector_indexes` AND every `VectorIndexWrapper.refs`/`dropped` in-flight reference (`requireVectorIndex` / `releaseVectorIndex`). Every vector-wrapper teardown runs under it, so "held ⇒ no wrapper can be destroyed"; DROP INDEX and the rebuild SWAP wait on `vector_drained` (the wait RELEASES this mutex). **INVARIANT: NEVER acquire a graph lock while holding `rebuild_mutex`** — `rebuildAdvancedVectorIndexNonBlocking` releases it before taking the SHARED lock for its snapshot and again for its drain. A caller MAY hold a graph lock and then take this one (DROP INDEX DDL, the `#875` drain); never the reverse. |
| 1.6 | `rebuild_window_mutex` | `index/index_manager.zig` | Guards `rebuild_windows` only. Leaf, strictly BELOW `rebuild_mutex` — `tryIncrementalInsertForProperty` takes `rebuild_mutex` then this one; nothing ever takes `rebuild_mutex` while holding this. |
| 2 | `catalog_mutex` | `execution.zig` | Schema catalog |
| 3 | `connections_mutex` | `transport/quic.zig` | QUIC connection list |
| 3 | `pending_destroy_mutex` | `transport/quic.zig` | Deferred cleanup |
| 4 | `fle_catalog_mutex` | `schema/fle_catalog.zig` | FLE field metadata |
| 4 | `global_mutex` (FLE) | `fle_integration.zig` | FLE role state |
| 5 | `user_store_mutex` | `user_management.zig` | Auth user store |
| 5 | `session_mutex` | `session_storage.zig` | Session state |
| 6 | `audit_mutex` | `procedure_registry.zig` | Audit logger |
| 6 | `tde_mutex` | `procedure_registry.zig` | TDE engine |
| 6 | `cdc_mutex` | `procedure_registry.zig` | CDC engine |
| 7 | `store_mutex` (timeseries) | `timeseries/timeseries.zig` | Timeseries Store (`std.Io.Mutex`) — guards concurrent ingest/read from the QUIC worker pool. Leaf lock: touches no other geode lock and is NEVER held while acquiring another lock. |

Never hold a higher-tier mutex while acquiring a lower-tier one. Thread-local atomics (`std.atomic.Value`) don't require ordering.

### Testing Requirements

- **Unit Tests**: All components must have test coverage
- **Integration Tests**: End-to-end scenario verification  
- **Regression Tests**: Automated prevention of known issues
- **Performance Tests**: Benchmark validation for optimizations

## 🎯 Implementation Methodology

### Evidence-Based Development

1. **CANARY Markers**: All features tracked with governance compliance
2. **Test-Driven**: Implementation verified through automated testing
3. **Performance Validation**: Benchmarks required for optimization claims
4. **Documentation**: All features documented with implementation proof

### Quality Gates

- **Test Coverage**: Keep the local `zig build test-*` baseline green (expected ~175/179 named steps; track the canonical baseline and regressions in [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md)), and pass `zig build test-compile` before calling the aggregate `zig build test` green (see Zig Test Conventions above)
- **Memory Safety**: Zero memory leaks in test runs
- **Standards Compliance**: Keep the ISO conformance suite green (96/96 in `tests/gql_iso_conformance.zig`, `zig build test-iso-conformance`) and the executed-query `gql_conformance` suite green (20/20, `zig build test-gql-conformance`)
- **Performance**: No regressions in core operations

## 📍 Current Status

**ALL HIGH/MEDIUM/LOW PRIORITY TODO ITEMS COMPLETED**

Based on [TODO.md](docs/TODO.md), all 7 development phases (Phases 2-7) have been implemented with testing and documentation. The project is **DEVELOPMENT READY (single-tenant)**. Open items remain (see [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md), the canonical register): GAP-0256 (release signing, Blocked on org signing infra), GAP-0838 (cross-pod cluster, Blocked — repo-side fixes landed, real-cluster k8s validation owed), GAP-0873 (per-tenant at-rest encryption, deferred to GAP-0290), and GAP-0885 (security sibling backlog residuals). GAP-0893 (gRPC transport) was re-diagnosed 2026-08-25 — the "vendor `grpc_zig` blocker" was stale (fixed upstream in v0.1.8; geode pins v0.1.9) and the real cause was two geode-side defects in `src/transport/grpc_tls.zig` / `grpc_server.zig`, now fixed with `zig build test-grpc-raw-io` + `test-transport-parity` 12/12 as gates. GAP-0514 (CANARY IMPL coverage) closed 2026-06-11. Operators MUST review the Known Limitations section above before deploying.

**Multi-tenancy caveat:** Multi-tenancy isolation is materially stronger after the 2026-06-09/10 hardening branch — graph-level isolation, query-layer tenant filtering (GAP-0509), wired expression RLS (GAP-0511), strict-tenancy auto-default (GAP-0848), tenant-hierarchy read-path enforcement (GAP-0846), FLE request-context (GAP-0852), and tenant-drop cascade (GAP-0847) are all in place. Documented residuals: per-tenant at-rest encryption keys are deferred (`docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`), the LSP tenant is client-asserted (GAP-0818, Partial), per-tenant quotas are not implemented, and the cross-cutting concern has not been end-to-end audited against a multi-tenant benchmark suite. See [FEATURES_OVERVIEW.md](docs/FEATURES_OVERVIEW.md) for details.

## 🔧 Unified CLI Architecture

**Complete Migration Achieved**:

- ✅ **Single Binary**: `./zig-out/bin/geode` (unified architecture)
- ✅ **Zero Subprocess Calls**: Eliminated geodec/geoded spawning
- ✅ **Server-Only Mode**: All operations require QUIC server connection
- ✅ **Local Test Baseline**: see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (canonical; expected ~175/179 named `zig build test-*` steps pass)

---

## 📚 For Comprehensive Information

**See the complete documentation in [`./docs/`](docs/)** for detailed technical specifications, API references, performance analysis, and implementation guides.

*Last Updated: 2026-06-11*
*Status: DEVELOPMENT READY (single-tenant) - ISO conformance suite 96/96 (parse-only scope), local test baseline per [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) (see Known Limitations for multi-tenant, distributed, and backup gaps)*
*License: Apache License, Version 2.0 - Copyright 2024-2025 CodePros*

## Important Development Guidelines

- You have completely botched the geodetestlab fixes by mocking and simulating the responses from `geode` in the test harness itself. NEVER EVER DO THIS! Always add the complex missing logic and fixes to the code to make the tests work unless the tests are actually wrong
- NO MOCK DATA, NO SIMULATION, IMPLEMENT THE COMPLEX FEATURES
- Always verify against the authoritative GQL specification before making architectural changes. The official ISO/IEC 39075:2024 standard is the source of truth, not assumptions or secondary sources.
