# Geode Graph Database (spyderorg) – Documentation (v0.18.0)

This directory contains the Geode documentation set for v0.18.0. See the versioned index below for the complete guide.

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

Notes:
- Transport is QUIC+TLS only; no plaintext TCP.
- MVCC snapshot‑isolation transactions; WAL/ARIES recovery; optional TDE.
- Deterministic MATCH engine with bounded path expansions; US001 guard for unordered pagination.
- Federated read queries via coordinator/shards; cross‑shard writes not yet supported.
- Tamper‑evident audit logging with hash‑chaining and signed digests.
- Evidence‑driven governance: CANARY annotations with generated status.csv.
