# Geode Graph Database (spyderorg)

Geode is an open-source, ACID-compliant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL). Written in Zig for low-level efficiency, Geode focuses on reliability, security, and deterministic behavior.

Highlights (v0.18.0):
- QUIC+TLS transport only; optional Transparent Data Encryption (TDE)
- MVCC with snapshot isolation; WAL/ARIES crash recovery
- Deterministic MATCH engine; bounded path expansions; US001 guard
- Federated reads via distributed coordinator/shards
- S3 backups (full/incremental); CDC webhooks
- Tamper‑evident audit log (hash chain + signed digests)
- Evidence governance via CANARY with generated status.csv

See docs/README.md for the full documentation set (v0.18.0), including architecture, security, operations, and roadmap.
