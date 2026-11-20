# Geode Documentation

**Technical documentation for the Geode graph database - December 2025**

## Overview

Geode is a single-tenant graph database with strong ISO/IEC 39075:2024 GQL alignment — 106/106 named cases in its ISO conformance suite (`tests/gql_iso_conformance.zig`, `zig build test-iso-conformance`; parse-only scope). **Deployment status:** development-ready for single-tenant workloads. Multi-tenant and distributed deployments require operator review of the Known Limitations in [`../CLAUDE.md`](../CLAUDE.md) before production use. Canonical status: [GAP_ANALYSIS.md](GAP_ANALYSIS.md) + [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md).

## Directory Structure

```
docs/
├── architecture/       # System architecture and design
├── clients/            # Client library documentation (Go, Rust, Python, Zig)
├── completion_reports/ # Phase completion summaries
├── deployment/         # Deployment guides
├── development/        # Development tools and IDE integration
├── docker/             # Docker deployment guides
├── examples/           # Code examples and tutorials
├── gql/                # GQL conformance profiles
├── kb/                 # Knowledge base (GQL spec, algorithms, QUIC)
├── testing/            # Testing documentation
└── *.md                # Core feature documentation
```

## Quick Start

### Getting Started

- **[Features Overview](FEATURES_OVERVIEW.md)** - Feature catalog
- **[Quick Reference](QUICK_REFERENCE.md)** - Commands and syntax
- **[Usage Guide](USAGE.md)** - How to use Geode

### Technical Reference

- **[API Reference](API_REFERENCE.md)** - API documentation
- **[Types & Functions](TYPES_AND_FUNCTIONS.md)** - 50+ data types
- **[GQL Compliance](GQL_COMPLIANCE.md)** - ISO/IEC 39075:2024 conformance

### Enterprise Features

- **[KMS Provider System](KMS_PROVIDER_SYSTEM.md)** - Key management
- **[User Authentication](USER_AUTH.md)** - RBAC/ABAC (MFA not enforced at login yet, SONNY-6604)
- **[Audit Logging](AUDIT_LOGGING.md)** - Audit capabilities

### Advanced Features

- **[ML Graph Embeddings](ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk
- **[Real-time Analytics](REAL_TIME_ANALYTICS.md)** - Streaming analytics
- **[Materialized Views](MATERIALIZED_VIEWS.md)** - View management
- **[Enhanced Transaction Isolation](ENHANCED_TRANSACTION_ISOLATION.md)** - Status note: not implemented (removed 2026-11-11, SONNY-6298)
- **[Distributed Query Coordination](DISTRIBUTED_QUERY_COORDINATION.md)** - Status note: not implemented (removed 2026-11-11, SONNY-6279)

### Deployment

- **[Docker Quickstart](docker/QUICKSTART_DOCKER.md)** - Docker setup
- **[Deployment Guide](deployment/DEPLOYMENT.md)** - Production deployment
- **[NixOS Deployment](NIX_DEPLOYMENT.md)** - NixOS configuration

### Client Libraries

- **[Client Documentation](clients/)** - Multi-language clients
- **[Go/Rust Client Plan](clients/GO_RUST_CLIENT_DEVELOPMENT_PLAN.md)** - Client roadmap

### Testing

- **[Testing Guide](TESTING.md)** - Test execution
- **[Known Issues](KNOWN_TEST_ISSUES.md)** - Current limitations

## Implementation Status

### Completed Features

1. **Backup/Restore CLI** - local backup files (no S3 / Digital Ocean Spaces path in the binary; copy files with your own tool)
2. **REPL QUIC Integration** - Interactive shell
3. **Vector Operations** - HNSW indexing with SIMD
4. **ML Graph Embeddings** - Node2Vec, GraphSAGE, DeepWalk
5. **Real-time Analytics** - Streaming with pattern detection
6. **Enhanced Transaction Isolation** - Not implemented (removed 2026-11-11, SONNY-6298; the code was never compiled)
7. **Distributed Query Coordination** - Not implemented (removed 2026-11-11, SONNY-6279; the code was never compiled)
8. **Materialized Views** - Refresh strategies with dependency tracking
9. **CLI Subprocess Elimination** - Unified binary architecture
10. **Advanced Security** - Row-level security with policy evaluation (`src/security/rls_core.zig`)

### Quality Metrics

- **Local test baseline**: see [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) (canonical; expected ~175/179 named `zig build test-*` steps pass)
- **Integration (geodetestlab)**: fresh harness run owed; last dated snapshot ~97% (1644/1688, historical)
- **ISO conformance suite**: 106/106 named cases (`zig build test-iso-conformance`; parse-only scope); executed-query `gql_conformance` suite 21/21 (`zig build test-gql-conformance`)
- **5,937 CANARY Markers** (257 IMPL / 4.3%, 2026-11-11; run `make status-generate`)

### Known Issues

See [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) for the current canonical test baseline and per-step failure evidence, and [GAP_ANALYSIS.md](GAP_ANALYSIS.md) for open gaps.

## Reference Documents

### Core

| Document | Description |
|----------|-------------|
| [TODO.md](TODO.md) | Development status (all phases complete) |
| [GOVERNANCE.md](GOVERNANCE.md) | Governance and compliance |
| [CURRENT_ARCHITECTURE.md](CURRENT_ARCHITECTURE.md) | System architecture |

### Language

| Document | Description |
|----------|-------------|
| [EXPRESSION_OPERATORS.md](EXPRESSION_OPERATORS.md) | Expression operators |
| [TYPE_SYSTEM_EXTENSIONS.md](TYPE_SYSTEM_EXTENSIONS.md) | Type system |
| [TYPE_QUICK_REFERENCE.md](TYPE_QUICK_REFERENCE.md) | Type reference |

### Operations

| Document | Description |
|----------|-------------|
| [TRANSACTION_MANAGEMENT.md](TRANSACTION_MANAGEMENT.md) | Transaction handling |
| [SESSION_MANAGEMENT.md](SESSION_MANAGEMENT.md) | Session handling |
| [EXPLAIN_PROFILE.md](EXPLAIN_PROFILE.md) | Query profiling |

### Security

| Document | Description |
|----------|-------------|
| [ARGON2ID_IMPLEMENTATION.md](ARGON2ID_IMPLEMENTATION.md) | Password hashing |
| [FIELD_LEVEL_ENCRYPTION.md](FIELD_LEVEL_ENCRYPTION.md) | Field encryption |
| [DESIGN_TDE_KMS.md](DESIGN_TDE_KMS.md) | TDE design |

---

*Last Updated: December 2025*
