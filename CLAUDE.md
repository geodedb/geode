# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🏆 Project Status (April 2026)

**DEVELOPMENT READY (single-tenant).** Geode is a feature-complete **single-tenant** graph database with strong compliance and active development. Multi-tenant deployments, distributed clusters, and the full RLS expression engine require additional review and test coverage before production use — see Known Limitations below.

- **✅ 97.4% Test Coverage** (1644/1688 tests - see [KNOWN_TEST_ISSUES.md](docs/KNOWN_TEST_ISSUES.md) for details)
- **✅ 100% GQL Compliance** (70/70 ISO/IEC 39075:2024 tests)
- **✅ ~2,224 CANARY Markers** tracking requirements (~71% TESTED, ~15% IMPL, ~11% EXEMPT, ~3% BENCHED; run `make status-generate` for current counts)
- **✅ Enterprise Features** implemented (TDE, audit, vector search, cloud backup, enhanced RLS) — see limitations below for multi-tenant caveats
- **✅ ALL TODO.md PHASES COMPLETE** - All 7 development phases implemented (Phases 2-7)

### Known Limitations

- **Single-tenant recommended for production.** Multi-tenant deployments require operator review of GAP-0514 (CANARY IMPL coverage) before enabling. The storage-level tenant isolation primitives (`getAllNodesForTenant`, `getNodesByLabels(..., tenant)`, `getEdgesByType(..., tenant, graph)`) are correct and regression-tested, but the full cross-cutting concern has not been end-to-end audited against a multi-tenant benchmark suite.
- **Multi-tenancy query isolation (GAP-0509, Closed 2026-04-11)**: all 17 full-scan sites and 7 label-indexed sites in `match_operations.zig` apply `passesTenantFilter`/`getNodesByLabels(..., tenant)`. `listNodeLabels`/`SHOW TABLES` now takes a `filter_tenant` parameter pulled from `ExecutionContext`. Regression cover in `tests/test_gap0509_tenant_isolation.zig`. Residual: `evaluateAggregation`/`evaluateAggregationWithLabels` in `aggregation_evaluation.zig` are currently dead code but would iterate `store.nodes` without a tenant filter if wired up — annotated with a `GAP-0509 WARNING` comment; delete or add a tenant parameter before wiring.
- **RLS expression engine (GAP-0510, Closed 2026-04-11)**: wired at server startup (`setGlobalExprRLSEngine` in `src/server/main.zig:638`) and read from the match loop (`passesRLSExprFilter` in `src/execution/match_operations.zig:125`). Compiled bytecode policies enforce property-based row-level filtering via `checkRowAccessByUsername`. Regression cover in `tests/test_rls_expr_engine_wiring.zig`. Residual: the GQL → bytecode pipeline for policy compilation is still manual — policies must be pinned with a pre-compiled `CompiledExpression` until the parser path lands. Temporal policies (`TemporalConstraint`) evaluate but have no end-to-end tests.
- **Distributed module (GAP-0513, Closed 2026-04-10)**: per `docs/DISTRIBUTED_GAP_ANALYSIS.md`, all distributed gaps closed via commit `68ff42c4`. NodeRegistry covered by `src/distributed/test_query_transport_node_registry.zig` (inline copy — see that file's note about drift risk). Activates only when `GEODE_CLUSTER_TOKEN` is set; `--no-cluster` (default) bypasses this path entirely.
- **Auth defaults**: Authentication is enabled by default (fail-closed) and must be configured with credentials before deployment.
- **CANARY coverage gap (GAP-0514, Open)**: ~15% of CANARY markers remain at `IMPL` status (implemented but not yet verified by a named test). This is governance/hygiene, not functional defect — all 1036 existing Zig tests pass. Tracked for a follow-up test-writing sprint targeting `execution.zig` and `graph_store.zig` first (27% of IMPL markers).
- **MCP server (GAP-0516, Partial)**: the `src/mcp/server.zig` handlers for resource subscriptions (`subscribeResource`/`unsubscribeResource`) are intentionally not implemented — Geode does not yet produce streaming resource-change notifications. Clients should poll via `readResource` instead. `completeHandler` forwards to the LSP completion path; `setLogLevelHandler` is a safe no-op that acknowledges the request without changing runtime verbosity.
- **Auth DDL persistence**: Auth DDL writes persist to the HMAC-chained `__geode_security` graph and survive restart (users, roles, password/role/active changes, and per-graph `GRANT … ON GRAPH …`). Hydrated at startup via `PersistentUserResolver`, `hydrateCustomRolesFromGraph`, and `GraphRBACPolicy.loadGraphGrants`. Residuals: no model for a `GRANT <privilege>` without `ON GRAPH` (global privilege is governed by the user's role); custom-role membership beyond the built-in role field is not modeled; RLS policy persistence is still TODO (separate plan); the BIND-time per-graph grant check is additive/permissive in default single-tenant config. See [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md) for the full persistence spec and known limitations.
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
- **[User Authentication](docs/USER_AUTH.md)** - RBAC/ABAC with MFA support
- **[GQL Auth DDL](docs/GQL_AUTH_DDL.md)** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW statements (Geode extension)

### Advanced Features

- **[ML Graph Embeddings](docs/ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk
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

1. **S3 Cloud Backup** - Production-ready with Digital Ocean Spaces integration
2. **REPL QUIC Integration** - Real-time interactive shell with comprehensive features
3. **Vector Operations** - HNSW indexing with 6 distance metrics and SIMD acceleration
4. **Performance Optimization** - 13.18x I/O improvement, memory-mapped operations
5. **IndexOptimizer** - Cost-based query planning with statistics integration
6. **ML Graph Embeddings** - Complete Node2Vec, GraphSAGE, DeepWalk implementation
7. **Real-time Analytics** - Streaming analytics with pattern detection and anomaly detection
8. **Enhanced Transaction Isolation** - Advanced MVCC with SSI and phantom read prevention
9. **Distributed Query Coordination** - Federation-aware optimization with load balancing
10. **Materialized View Refresh** - Complete refresh strategies with dependency tracking
11. **CLI Subprocess Elimination** - Unified binary architecture eliminating subprocess spawning
12. **Advanced Security Features** - Enhanced RLS with policy evaluation, expression compilation, and optimization
13. **GQL Auth DDL** - CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW USERS/ROLES/PERMISSIONS/VERSION/CAPABILITIES (Geode extension; see [docs/GQL_AUTH_DDL.md](docs/GQL_AUTH_DDL.md)). Routes to existing geode.auth.* handlers — same authorization, audit, and __geode_security persistence. user_assign_role now mutates the user's built-in role. All auth DDL writes persist to the `__geode_security` graph (HMAC-chained, hydrated at startup) and survive restart.

### 🏗️ Architecture Overview

**Core Components**:

- **Parser/Lexer** (`src/gql/`): 100% ISO GQL compliance (70/70 tests)
- **Query Planner** (`src/planner/`): Cost-based optimization with statistics
- **Storage Engine** (`src/storage/`): MVCC, WAL, TDE with <1% overhead
- **Index System** (`src/index/`): 6 index types including HNSW and R-tree
- **Security** (`src/security/`): Enterprise authentication, audit, encryption, enhanced RLS
- **Transport** (`src/transport/`): QUIC+TLS only with protocol compliance

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

- **CANARY System**: 2,178 governance markers tracking requirements
- **Geodetestlab**: 97.4% pass rate (1644/1688 tests passing)
- **ISO Compliance**: 100% GQL compliance (70/70 official test suite)
- **Performance Benchmarks**: Automated regression testing
- **Status Breakdown**: 71.0% TESTED, 14.2% IMPL, 11.6% EXEMPT, 3.1% BENCHED

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

**InstrumentationScopes that fire** (after merge commit `5609bc79`):

| Scope | Useful for |
|---|---|
| `com.geodedb.geode` | `geode.transport.request`, `geode.query.execute`, `geode.graph_store.{create_node,get_nodes_by_label}`, `gql.execute.PARSE`, `wal.{create,update,delete}_*` |
| `wal` | `wal.{replay,append,append_batch,commit,checkpoint,truncate}` |
| `gql` | `gql.execute.query` (parser entry inside the lib) |
| `dns` | DNS lookups (`client.zig`, `recursive.zig`, `stub.zig`) |
| `vulkan` | GPU compute ops (when present in the workload) |
| `thread_pool` | task lifecycle |
| `repl` | REPL command execution |
| `protobuf` / `slog` | bound for forward-compat; no internal spans today |

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
| 1 | `store_mutex` / per-graph `rwlock` | `graph_store.zig` / `graph_storage_adapter.zig` | Graph data — per-graph locks use alphabetical acquire order for multi-graph |
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

- **Test Coverage**: Must maintain >90% pass rate (currently 97.4%)
- **Memory Safety**: Zero memory leaks in test runs
- **Standards Compliance**: Maintain 100% GQL compliance (70/70 tests)
- **Performance**: No regressions in core operations

## 📍 Current Status

**ALL HIGH/MEDIUM/LOW PRIORITY TODO ITEMS COMPLETED**

Based on [TODO.md](docs/TODO.md), all major development priorities have been implemented with comprehensive testing and documentation. The project is **DEVELOPMENT READY (single-tenant)** -- core features are implemented, but multi-tenancy query isolation and expression RLS are not yet wired. Operators MUST review the Known Limitations section above before deploying.

**Multi-tenancy caveat:** Multi-tenancy isolation is partial. Graph-level isolation and FLE per-tenant keys work, but tenant_id enforcement at the query execution layer, per-tenant quotas, and full RLS expression coverage are still in progress. See [FEATURES_OVERVIEW.md](docs/FEATURES_OVERVIEW.md) for details.

## 🔧 Unified CLI Architecture

**Complete Migration Achieved**:

- ✅ **Single Binary**: `./zig-out/bin/geode` (unified architecture)
- ✅ **Zero Subprocess Calls**: Eliminated geodec/geoded spawning
- ✅ **Server-Only Mode**: All operations require QUIC server connection
- ✅ **97.4% Test Pass Rate**: 1644/1688 tests passing

---

## 📚 For Comprehensive Information

**See the complete documentation in [`./docs/`](docs/)** for detailed technical specifications, API references, performance analysis, and implementation guides.

*Last Updated: May 2026*
*Status: DEVELOPMENT READY (single-tenant) - 100% GQL compliance, 97.4% test pass rate (see Known Limitations for multi-tenant and distributed gaps)*
*License: Apache License, Version 2.0 - Copyright 2024-2025 CodePros*

## Important Development Guidelines

- You have completely botched the geodetestlab fixes by mocking and simulating the responses from `geode` in the test harness itself. NEVER EVER DO THIS! Always add the complex missing logic and fixes to the code to make the tests work unless the tests are actually wrong
- NO MOCK DATA, NO SIMULATION, IMPLEMENT THE COMPLEX FEATURES
- Always verify against the authoritative GQL specification before making architectural changes. The official ISO/IEC 39075:2024 standard is the source of truth, not assumptions or secondary sources.
