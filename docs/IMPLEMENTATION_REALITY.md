# IMPLEMENTATION REALITY — v0.18.0

This is the ground truth synchronized with docs/status.csv and current source. Claims elsewhere must not exceed this document.

## Evidence Summary
**735 features** tracked with CANARY markers across the codebase.
- 504 TESTED with comprehensive test coverage
- 225 BENCHED with performance benchmarks
- 6 IMPL (implemented but not yet tested)

## Transport
- QUIC+TLS only; auto‑generated self‑signed certs. Implemented.

## Language & Engine
- ISO GQL minimum conformance: parser/lexer, MATCH/OPTIONAL, WHERE, RETURN, ORDER BY, LIMIT/OFFSET (US001 policy), aggregates, set ops. Implemented.
- Execution model: binding tables; deterministic ordering; bounded expansions with tie‑break. Implemented.

## Storage & Transactions
- MVCC (SI), WAL/ARIES, page LSN. Implemented.
- WAL‑before‑data enforcement; commit flush policy knobs; directory‑level durability (WAL segment rollover, index snapshot rename). Implemented.
- FSM + on‑page vacuum/defrag with PageCompact physiological WAL. Implemented.

## Indexes
- Persisted: Patricia (CIDR), R‑tree (spatial), Interval Tree (ranges), JSONB Inverted (jsonb), Domain Trie (suffix), HNSW (vectors). Implemented.
- Index‑WAL commit coordination hook (Patricia wired; generic coordinator available). Implemented.

## Security
- RLS/ABAC enforced. Implemented.
- Tamper‑evident audit logging: hash‑chained JSONL; periodic Merkle digests; Ed25519 signatures on DIGEST (default ON); append‑only; tail recovery (ignores one trailing partial). Implemented.
- geode‑audit CLI performs chain and digest presence checks; signature reporting road‑mapped. Implemented (chain verification path).
- TDE (AES‑GCM pages + WAL encryption), rotation scaffold; remote KMS prototype; overhead benches. Implemented.

## Distributed
- Read federation (coordinator/worker). Implemented.
- Distributed writes / cross‑shard txns. Not implemented.

## Backups & CDC
- S3 backups (full + incremental, multipart, checksums, resumable, PIT). Implemented.
- CDC webhook (headers, retries with backoff/jitter, DLQ, idempotency, metrics). Implemented.

## Observability
- JSON logs, Prometheus metrics, diagnostics precedence folding. Implemented.

## Build & Platform
- Zig 0.15.1 (Linux/glibc). Implemented.

## Defaults & Limits
- Audit signing enabled by default; non‑test builds require GEODE_AUDIT_PUB/SEC (else CONFIG_ERROR SIGNING_KEYS_MISSING).
- Audit append latency target ≤ 500 µs/event (excluding fsync).
- Commit flush default: always.

For detailed evidence and freshness, see docs/status.csv and docs/GAP_ANALYSIS.md. All claims here match the 735 CANARY markers (504 TESTED, 225 BENCHED) tracked in source.
