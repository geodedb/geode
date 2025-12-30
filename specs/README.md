# Geode Specifications Index

This directory contains specification and research documents for Geode's features. Specifications are organized by functional area and provide implementation guidance.

## Specification Status Legend

- **Implementation-Ready (9+/10)**: Detailed specs with file/line anchors, ready for coding
- **Research-Ready (5-7/10)**: Research completed, needs scoping for implementation
- **Pending Formalization**: Concepts defined but not fully specified

## Directory Structure

### `/adrs/` - Architecture Decision Records
- `ADR-001_deferred_gcs_metrics.md` - Deferred Grey Cardinal metrics decision (v0.16 vs v0.17)

### `/advanced-types/` - Type System Extensions
- `type-extensions-pr.md` - Vector, network (IPv4/IPv6/CIDR), geographic (Point/LineString/Polygon) types
- **Status**: Implementation-Ready (9.3/10)

### `/audit/` - Audit Logging & Compliance
- `prompt.md` - Tamper-evident, write-only auditing with hash chains and Ed25519 signatures
- **Status**: Implementation-Ready

### `/cli/` - CLI Unification
- `cli-audit-2025-09-27-pr.md` - Unified single `geode` binary specification
- **Status**: Implementation-Ready

### `/fuzz-framework/` - Fuzzing & Property Testing
- `research-pr.md` - Fuzzing framework design for property-based testing
- **Status**: Research-Ready

### `/gql/` - GQL ISO Compliance
- `gql-gap-analysis-2025-09-28-CP.md` - Critical gap analysis with file/line anchors
- `ebnf-grammar.md` - Complete EBNF for ISO/IEC 39075:2024 GQL (705 lines)
- **Status**: Implementation-Ready (9.6/10)

### `/grey-cardinal/` - Execution Tracking & Graph Algorithms
- `index.md` - Time-series, backup/restore, federated queries, advanced algorithms
- **Status**: Partial (70% time-series, 40% backup, 0% federated)

### `/hyperledger/` - Distributed Consensus & MVCC
- Research papers on distributed MVCC with graph isomorphism and transaction conflict control
- **Status**: Reference Material

### `/i18n/` - Internationalization
- `localization.docx` - Localization specification
- **Status**: Pending Formalization (Word doc only)

### `/logging/` - Logging Infrastructure
- `cef-pr.md` - CEF (Common Event Format) logging specification
- **Status**: Research-Ready

### `/mTLS/` - Mutual TLS
- `prompt.md` - mTLS implementation research
- **Status**: Research-Ready

### `/mvcc/` - Multi-Version Concurrency Control
- `repairing-conflicts-mvcc-transactions.md` - MV3C algorithm for conflict repair
- `early-detection-mvcc.md` - Early-detection strategies for MVCC conflicts
- **Status**: Reference Material

### `/raft/` - Raft Consensus
- `raft.pdf` - Raft consensus algorithm reference
- **Status**: Reference Material

### `/repl/` - Interactive Shell
- `repl-research-pr.md` - Comprehensive REPL spec (history, completion, multi-line, errors)
- **Status**: Implementation-Ready (9.6/10)

### `/security/` - Field-Level Encryption & Key Management
- `field-level-enc-research-report.md` - Production-ready FLE spec (AEAD, key hierarchy, RBAC)
- `enc-verification-testing.md` - Encryption verification & testing
- **Status**: Implementation-Ready

### `/signal-analysis/` - Signal Analysis & Anomaly Detection
- `integrating-signal-analysis.md` - Signal analysis integration spec
- **Status**: Research-Ready

### `/storage/` - Storage Engine Durability
- `storage-research-2025-09-27-PR.md` - WAL-based durability with file/line anchors
- **Status**: Implementation-Ready

### `/utf-16/` - UTF-16 Support
- `prompt.md` - UTF-16 input encoding support
- **Status**: Research-Ready

## Cross-References to Source

Key source file anchors from specifications:

### GQL Implementation (`src/gql/`)
- `token.zig` (L59-67, L73-86, L122-129) - Keywords, identifiers
- `lexer.zig` (L77-85) - Comment handling
- `parser.zig` (L480-488, L512-520) - ORDER BY, LIMIT/OFFSET

### Storage Implementation (`src/storage/`, `src/wal/`)
- `wal.zig` (L68-75, L343-355) - WAL record struct, segment rollover
- `page_manager.zig` (L28-36, L124-133) - Page header, insert operations

### Security Implementation (`src/security/`)
- `rls.zig` (L1020) - AuditEvent extension
- `audit.zig` (L154) - Append-only guards

## Priority Implementation Order

Based on specification completeness and impact:

1. **GQL Conformance Gaps** - 9 identified gaps with exact anchors
2. **Storage Durability** - Complete spec with cross-platform support
3. **Field-Level Encryption** - Complete spec with RBAC integration
4. **Audit Logging** - Tamper-evident design complete
5. **CLI Unification** - Unified binary spec with detailed anchors
6. **REPL Features** - Comprehensive spec ready for implementation

## Related Documentation

- [docs/GQL_COMPLIANCE.md](../docs/GQL_COMPLIANCE.md) - Current GQL compliance status
- [docs/FEATURES_OVERVIEW.md](../docs/FEATURES_OVERVIEW.md) - Feature catalog
- [docs/TODO.md](../docs/TODO.md) - Development priorities
