CRUSH.md — geode repo quick facts for agents

Build & run

- Build all: make build (builds both Zig and Go components)
- Build (release-safe): zig build -Drelease-safe
- Debug build: zig build
- Run server (QUIC): ./zig-out/bin/geoded --listen-quic 0.0.0.0:7567
- Run server (TCP): ./zig-out/bin/geoded --listen-tcp 127.0.0.1:7567
- Run CLI (QUIC): ./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --server 127.0.0.1:7567
- Run CLI (stdio): ./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --no-quic
- Generate TLS certificates: ./zig-out/bin/cert_gen
- Run Go example: make go-example

Tests

- All tests: zig build test
- Single test file: zig test src/main.zig
- E2E protocol tests: zig test tests/e2e_protocol.zig
- QUIC/TLS tests: zig test tests/e2e_quic_tls_comprehensive.zig
- Go client tests: make go-test (or cd clients/go/gql && go test -v)
- Note: tests should be deterministic, RSS ≤512 MiB, timeout ≤30s

Lint/format/typecheck

- Zig format: zig fmt .
- Typecheck (build graph): zig build
- C/clang format (if needed): clang-format -i <files> (see .clang-format)

Project conventions

- Language: Zig 0.13.0; Linux x86_64; default JSON output (TXT via --format=txt)
- Transport: QUIC with TLS 1.3 (default), TCP (legacy), stdio (backward compat)
- Imports: prefer std; avoid dynamic net deps; versions pinned if any third-party used
- File organization mirrors modules under src/ (gql/, parser/, planner.zig, exec.zig, protocol.zig, server/, client/, transport/)
- Names: lower_snake_case for vars/fns; UpperCamelCase for types; constants SCREAMING_SNAKE when appropriate
- Errors: return error unions; do not log secrets; map diagnostics to ISO GQLSTATUS with codes (US001, IllegalOrderKey, GroupByIllegal, TypeMismatch) and anchors
- Result encoding: JSON by default; include ordered flag and order_keys in bindings when applicable
- Policy: LIMIT/OFFSET requires stable ORDER (US001) unless configured; ORDER BY keys identifiers-only by default (IllegalOrderKey)
- Logging: JSON Lines at INFO; errors at ERROR
- Security: TLS 1.3 with self-signed certs for dev; production should use CA-signed certs

Pending Commit Message:
feat(transport): add QUIC with TLS 1.3 support for client-server communication

- Added QUIC transport layer with TLS 1.3 in src/transport/quic.zig
- Updated server to support --listen-quic flag for QUIC mode
- Updated client to use QUIC by default with --no-quic fallback
- Added certificate generation tool in src/tools/cert_gen.zig
- Updated Go client to support quic: DSN prefix with github.com/quic-go/quic-go
- Maintained backward compatibility with TCP and stdio modes
- All integration tests updated to use QUIC transport

New Features Implemented:

Core GQL Features:
- MATCH pattern matching with graph traversal (src/graph/pattern_matcher.zig)
- Property access for nodes and edges
- GROUP BY with aggregations (COUNT, SUM, AVG, MIN, MAX, STDEV, VARIANCE) (src/graph/aggregator.zig)
- Graph mutations (CREATE, UPDATE, DELETE, MERGE operations)

Storage Enhancements:
- Automatic WAL compaction with configurable thresholds (src/storage/wal_compactor.zig)
- B-tree indexes for property lookups (src/index/btree.zig)
- Cost-based query optimizer with statistics (src/planner/optimizer.zig)

Distributed Features:
- Raft consensus for leader election (src/distributed/raft_consensus.zig)
- Two-phase commit coordinator (src/distributed/twophase.zig)
- Consistent hashing for sharding (src/distributed/sharding.zig)

Performance & Monitoring:
- Comprehensive metrics collection (counters, gauges, histograms, timers) (src/monitoring/metrics.zig)
- Query profiling with detailed execution plans
- Prometheus export format support

Developer Experience:
- Complete API documentation (docs/API_DOCUMENTATION.md)
- Go query builder library (clients/go/gql/query_builder.go)
- Advanced query examples (examples/advanced_queries.gql)

Cursor/Copilot rules to honor

- .github/copilot-instructions.md defines scope (full DB), protocol frames, diagnostics policy, tests, and required outputs. Follow these when adding features or tests.

Notes for agents

- Use zig fmt before committing; keep functions small and testable.
- Prefer small, incremental changes; add unit + e2e coverage for new behavior.
- Do not introduce runtime network dependencies. Never commit secrets.
