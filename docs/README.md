# Geode Documentation

**Technical documentation for the Geode graph database - December 2025**

## Overview

Geode is an enterprise-ready graph database with 98.6% ISO/IEC 39075:2024 GQL compliance.

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
- **[User Authentication](USER_AUTH.md)** - RBAC/ABAC with MFA
- **[Audit Logging](AUDIT_LOGGING.md)** - Audit capabilities

### Advanced Features
- **[ML Graph Embeddings](ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk
- **[Real-time Analytics](REAL_TIME_ANALYTICS.md)** - Streaming analytics
- **[Materialized Views](MATERIALIZED_VIEWS.md)** - View management
- **[Enhanced Transaction Isolation](ENHANCED_TRANSACTION_ISOLATION.md)** - MVCC
- **[Distributed Query Coordination](DISTRIBUTED_QUERY_COORDINATION.md)** - Federation

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
1. **S3 Cloud Backup** - Digital Ocean Spaces integration
2. **REPL QUIC Integration** - Interactive shell
3. **Vector Operations** - HNSW indexing with SIMD
4. **ML Graph Embeddings** - Node2Vec, GraphSAGE, DeepWalk
5. **Real-time Analytics** - Streaming with pattern detection
6. **Enhanced Transaction Isolation** - MVCC with SSI
7. **Distributed Query Coordination** - Federation-aware optimization
8. **Materialized Views** - Refresh strategies with dependency tracking
9. **CLI Subprocess Elimination** - Unified binary architecture
10. **Advanced Security** - Enhanced RLS with policy evaluation

### Quality Metrics
- **94.7% Test Pass Rate** (1199/1266 non-skipped tests)
- **98.6% GQL Compliance** (69/70 ISO tests)
- **1016 CANARY Markers** tracking governance

### Known Issues
See [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) for current test limitations:
- Setup data persistence (34 tests affected)
- WITH + aggregation + WHERE (server hang)
- CASE expressions in MATCH context
- 67 remaining test failures

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
