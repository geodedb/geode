# Geode Graph Database (spyderorg) – Documentation (v0.19.0-dev)

This directory contains the Geode documentation set for v0.19.0-dev. See the versioned index below for the complete guide.

- v0.18.0 Index: v0.18.0/index.md
  - Executive Summary: v0.18.0/executive_summary.md
  - Background & Context: v0.18.0/background.md
  - Data Model & GQL: v0.18.0/data_model_gql.md
  - Architecture & Storage: v0.18.0/architecture_storage.md
  - Interfaces — CLI: v0.18.0/interfaces_cli.md
  - Interfaces — Clients: v0.18.0/interfaces_clients.md
  - Security & Governance: v0.18.0/security_governance.md
  - Deployment & Operations: v0.18.0/deployment_operations.md
  - Performance & Scalability: v0.18.0/performance_scalability.md
  - Development & Contributing: v0.18.0/development_contributing.md
  - FAQ & Glossary: v0.18.0/faq_glossary.md
  - Roadmap: v0.18.0/roadmap.md
  - Citations: v0.18.0/citations.md

## New in v0.19.0-dev:
- **Index Operations**: Full support for CREATE/DROP INDEX with btree, hash, fulltext, spatial (R-tree), and vector (HNSW) types
- **Backup/Restore**: BACKUP TO and RESTORE FROM operations with point-in-time recovery support
- **Variable-Length Paths**: Enhanced path patterns with *min..max syntax for flexible graph traversal
- **Vector Search**: HNSW-based k-nearest neighbor search for embedding similarity
- **Spatial Indexing**: R-tree implementation for geographic and spatial queries
- **Enhanced Testing**: Comprehensive regression and integration test suites

See [NEW_FEATURES.md](NEW_FEATURES.md) for detailed documentation of new features.

Notes:
- Transport is QUIC+TLS only; no plaintext TCP.
- MVCC snapshot‑isolation transactions; WAL/ARIES recovery; optional TDE.
- Deterministic MATCH engine with bounded path expansions; US001 guard for unordered pagination.
- Federated read queries via coordinator/shards; cross‑shard writes not yet supported.
- Tamper‑evident audit logging with hash‑chaining and signed digests.
- Evidence‑driven governance: CANARY annotations with generated status.csv.
- Full-featured indexing: btree, hash, fulltext, spatial (R-tree), vector (HNSW) indexes
- Comprehensive backup/restore with compression and incremental backup support
