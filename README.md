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

## Documentation

- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Current implementation status and conformance gaps
- [NEXT.md](NEXT.md) - Development roadmap and priority slices
- [docs/README.md](docs/README.md) - Full documentation set (v0.18.0)

For CANARY governance and evidence tracking, see `tools/canaryscan/` and run:
```bash
cd tools/canaryscan && go run . --root ../.. --out ../../status.json --csv ../../status.csv
```
