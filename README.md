# Geode Graph Database - v0.18.0

## Overview

Geode is an ISO/IEC 39075:2024 (GQL) compliant, ACID graph database written in Zig 0.15.1. v0.18.0 focuses on reliability, durability, observability, and evidence‑driven governance.

- QUIC+TLS only transport
- MVCC transactions, WAL/ARIES recovery
- Deterministic MATCH engine with bounded expansions
- Distributed query federation (read path)
- S3 backups (full + incremental)
- CDC webhooks (hardened)
- Evidence governance via CANARY annotations

See docs/status.csv for up‑to‑date requirement coverage. All counts in this README are derived at build time and intentionally not duplicated here to avoid drift.

![Evidence Coverage](badges/evidence.svg)

## What’s New (since v0.18.0 scope)

### Tamper‑evident, write‑only auditing (default ON)

- Hash‑chained JSONL audit stream
- Periodic Merkle digests
- Ed25519 signatures on DIGEST records (default ON)
- Append‑only enforcement and tail recovery (ignores one trailing partial line)
- Verification CLI: geode‑audit

Usage:

```bash
# Verify an audit file
zig-out/bin/geode-audit verify --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB
```

Docs: docs/AUDIT_LOGGING.md

### WAL durability and space management

- WAL‑before‑data enforcement; commit‑flush policy knobs (always/every_n/time_window_ms)
- Directory‑level durability on segment rollover and snapshot rename
- Free Space Map (FSM) for page reuse; on‑page vacuum/defrag with physiological PageCompact WAL
- Index‑WAL commit coordination (Patricia now; generic hook for others)

### Evidence & governance

- docs/status.csv is generated from CANARY annotations (never hand‑edit)
- docs/GAP_ANALYSIS.md summarizes current evidence; remove stale metrics automatically

## Quick Start

```bash
# Build (Zig 0.15.1)
make build

# Start server (QUIC/TLS on 8443)
./zig-out/bin/geoded --data_dir ./data --log_json --result-format json

# Client
./zig-out/bin/geodec "MATCH (n) RETURN n LIMIT 10"
```

Optional dataset:

```bash
./scripts/load_example_dataset.sh
```

## Configuration

```bash
# Core
export GEODE_DATA_DIR=/var/lib/geode
export GEODE_LOG_LEVEL=info
export GEODE_LOG_FORMAT=json

# TDE (page+WAL encryption) – provide a 32‑byte hex key to enable
export GEODE_DISK_KEY_HEX=<64 hex chars>

# Audit signing (default: enabled). Non‑test builds require keys.
export GEODE_AUDIT_PUB=<ed25519 32‑byte pub hex>
export GEODE_AUDIT_SEC=<ed25519 64‑byte secret hex>

# S3 backups
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

## Architecture (high level)

- Engine: GQL parser → logical planner → physical operators (NodeScan/Expand/Filter/Project/Group/Order/Limit)
- Storage: Slotted pages, CSR adjacency, WAL/ARIES, MVCC, FSM, on‑page vacuum
- Distributed: Coordinator/worker federation (reads)
- Monitoring: JSON logs, Prometheus metrics, structured diagnostics

## CLI & Tools

- geoded – server
- geodec – client
- geode-audit – audit verification CLI (hash chain + digest signature checks)

## Documentation

- docs/AUDIT_LOGGING.md – tamper‑evident audit logging
- docs/GAP_ANALYSIS.md – evidence snapshot (derived from docs/status.csv)
- docs/REQUIREMENTS.md – compliance and system requirements
- docs/NEXT.md – near‑term roadmap
- docs/IMPLEMENTATION_REALITY.md – source‑of‑truth for what’s actually implemented

## Known limitations

- Distributed writes and cross‑shard transactions are not yet available
- FTS analyzers/BM25 in progress
- Remote KMS attestation/auth hardening ongoing

## License

MIT
