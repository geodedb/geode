# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Geode is an open-source, ACID-compliant graph database implementing ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig 0.15.1+ for low-level efficiency, it focuses on reliability, security, and deterministic behavior.

**Key Features (v0.18.0):**
- QUIC+TLS transport only with optional Transparent Data Encryption (TDE)
- MVCC with snapshot isolation; WAL/ARIES crash recovery
- Deterministic MATCH engine with bounded path expansions
- Federated reads via distributed coordinator/shards
- S3 backups (full/incremental); CDC webhooks
- Tamper‑evident audit log (hash chain + signed digests)
- Evidence governance via CANARY with generated status.csv
- **Comprehensive type system**: 50+ data types including network, spatial, temporal, JSON, and vector types
- **Advanced indexing**: Patricia trie (CIDR), R-tree (spatial), HNSW (vector KNN), with persistence

## Data Types and Functions

For a complete reference of all supported data types and functions, see [docs/TYPES_AND_FUNCTIONS.md](docs/TYPES_AND_FUNCTIONS.md). This includes:
- **Core types**: Numeric, string, temporal, binary
- **First-class types**: Network (IP/CIDR/MAC), geographic, cryptographic, vector
- **Advanced types**: JSONB, XML, URL, UUID, ranges, arrays, bit strings
- **Constructor functions** and **built-in functions** for all types
- **Persisted indexes** with snapshot/WAL support

## Development Commands

### Build Commands
```bash
# Build debug version (Zig + Go clients)
make build
# or: zig build

# Build release version
make release
# or: zig build -Doptimize=ReleaseSafe

# Build tools
make tools
# or: zig build tools

# Format all code
make fmt
```

### Test Commands
```bash
# Run all tests (Zig + Go + dataset integration)
make test
# or: zig build test

# Run specific test file
zig test tests/test_specific_file.zig

# Run integration tests
make integration-test

# Run dataset integration tests
make dataset-integration-test

# Run fuzz tests
make fuzz
# or: zig build fuzz

# Run benchmarks
make bench
# or: zig build bench
```

### Client Development
```bash
# Build Go client library (strict vendor mode)
make go-build

# Test Go clients
make go-test

# Run Go client example
make go-example

# Cross-compile clients for all platforms
make cross-clients

# Test cross-compiled clients
make test-cross-clients
```

### Server & CLI Commands
```bash
# Start server (QUIC+TLS only)
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443

# Run CLI client
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json

# Run unified CLI
./zig-out/bin/geode --help

# Run GQL CLI
./zig-out/bin/gql
```

### Governance & Quality
```bash
# Generate status.csv from CANARY markers
make status-generate

# Check for compile-time feature flags (enforces no flags)
make no-feature-flags

# Run governance checks
make governance-check

# Update status hash
make update-status-hash

# Show governance delta
make governance-delta
```

### Docker Operations
```bash
# Build Docker images
make docker-build

# Start singleton container
make docker-up-singleton

# Start distributed cluster
make docker-up-distributed

# Stop all containers
make docker-down

# Run Docker tests
make docker-test

# Full Docker CI pipeline
make docker-ci
```

### Development Verification
```bash
# Full E2E verification (strict)
make verify-all

# Faster dev verification (no fuzz/bench/docker/governance)
make verify-fast

# Full CI pipeline
make ci
```

## Architecture Overview

### Core Components
- **Parser/Lexer** (`src/gql/`): GQL language processing
- **Planner** (`src/planner/`): Query optimization and execution planning
- **Storage** (`src/storage/`): Page management, WAL, and persistence
- **Index** (`src/index/`): Multiple index types (B-tree, HNSW, R-tree, etc.)
- **Graph** (`src/graph/`): Graph algorithms and traversal
- **Security** (`src/security/`): TDE, audit, MFA, RLS/ABAC
- **Distributed** (`src/distributed/`): Raft consensus and federation
- **Monitoring** (`src/monitoring/`): Metrics and observability

### Key Execution Flow
1. **Parse**: GQL text → AST via lexer/parser
2. **Plan**: AST → logical operators → optimized physical plan
3. **Execute**: Physical operators over storage with index utilization
4. **Stream**: Results via SCHEMA + paged BINDINGS frames

### Storage & ACID
- **Pages**: Slotted page layout with CSR-style adjacency
- **WAL**: ARIES-style write-ahead logging with LSNs
- **MVCC**: Snapshot isolation with optimistic conflict detection
- **Recovery**: Crash recovery with undo/redo from WAL
- **Indexes**: Transactional maintenance across multiple index types

### Protocol
- **Transport**: QUIC+TLS only (no TCP fallback)
- **Frames**: HELLO, BEGIN/COMMIT/ROLLBACK, RUN_GQL, PULL
- **Results**: SCHEMA, BINDINGS (with ordering metadata), EXPLAIN/PROFILE
- **Diagnostics**: ISO GQLSTATUS codes with precedence rules

## Code Conventions

### Language & Style
- **Language**: Zig 0.15.1+
- **Formatting**: Use `zig fmt` for all Zig code
- **Go Code**: Use `go fmt` for client libraries
- **Comments**: Minimal comments unless required for clarity

### CANARY System
The project uses a CANARY annotation system for tracking implementation status:

```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="FeatureName"; ASPECT=AspectName; STATUS=IMPL|TESTED|BENCHED; TEST=TestName; OWNER=team; UPDATED=YYYY-MM-DD
```

**Important**: All implemented features must have CANARY markers. Tests should be named `TestCANARY_REQ_GQL_XXX_*` for traceability.

### File Organization
- **Tests**: Place in `tests/` directory with descriptive names
- **Benchmarks**: Use `benchmark_*.zig` naming pattern  
- **Canary Tests**: Use `canary_*.zig` for governance verification
- **Tools**: Utility programs in `tools/` directory
- **Examples**: Client examples in `examples/` and `clients/*/example/`

### Security Guidelines
- **Never log secrets**: No API keys, tokens, or sensitive data in logs
- **TDE**: Use placeholders like `{{KMS_ENDPOINT}}` for configuration
- **Audit**: All security-relevant operations must be auditable
- **RLS/ABAC**: Row-level security enforced via planner rewrite

## Testing Strategy

### Test Types
- **Unit Tests**: Component-level testing with `zig test`
- **Integration Tests**: End-to-end protocol and storage testing
- **Canary Tests**: Governance verification with CANARY markers
- **Fuzz Tests**: Randomized input testing in `fuzz/` directory
- **Benchmarks**: Performance regression testing

### Test Execution
- Tests must be deterministic (fixed seeds, no randomness)
- Maximum 512 MiB RAM usage per test
- 30-second timeout for E2E tests
- Cross-platform testing with Wine/QEMU when available

### Dataset Testing
Load the example social network dataset for integration testing:
```bash
make load-dataset
make dataset-integration-test
```

## Common Development Tasks

### Adding New Features
1. Implement with appropriate CANARY markers
2. Add comprehensive tests following naming conventions
3. Update documentation if user-facing
4. Run `make verify-fast` for quick validation
5. Run `make status-generate` to update governance tracking

### Debugging
- Use JSON logs with `--log_json` flag
- Check server stderr with `GEODE_CAPTURE_SERVER_STDERR` env var
- Profile with `EXPLAIN` and `PROFILE` query prefixes
- Monitor metrics via Prometheus integration

### Cross-Platform Development
- Test builds: `make cross-compile`
- Test clients: `make cross-clients && make test-cross-clients`
- Windows testing requires Wine
- ARM64 testing requires QEMU

## Environment Setup

### Prerequisites
- Zig 0.15.1+
- Go (for client libraries)
- Docker (for containerized testing)
- Git submodules: `git submodule update --init --recursive`

### Quick Start
```bash
# Initialize development environment
make dev-setup

# Build everything
make build

# Run basic tests
make test

# Start development server
./zig-out/bin/geoded --data_dir ./data --log_json
```

### Submodules
- QUIC library managed as git submodule in `vendor/quic/`
- Initialize with: `git submodule update --init --recursive`
- Check status with: `make quic-status`