# DESIGN_TDE_KMS.md - TDE Key Management & External KMS

> **2026-06-11 update (GAP-0864):** the "stub" framing below is historical.
> Real external-KMS network clients now exist in
> `src/security/external_kms_client.zig`: `VaultTransitClient` (Vault Transit
> encrypt/decrypt/rotate over `std.http`) and `AwsKmsClient` (AWS KMS
> Encrypt/Decrypt/GenerateDataKey), with production-safety guards
> (`KmsBackend.isProductionSafe`, `KmsConfig.validateForProduction`) covered by
> `tests/test_key_rotation_kms_envelopes.zig`, and a QUIC remote-KMS round-trip
> suite (`zig build test-remote-kms`). The Status Summary table at the bottom
> has been rebaselined; the design narrative is kept as written for history.

## Scope

This document captures the current (v0.18 -> v0.19 work-in-progress) design for Transparent Data Encryption (TDE) key hierarchy, rotation, persistence, and planned external KMS integration. It reflects the implemented mock/static providers plus the new ExternalKms stub. (Historical — see the 2026-06-11 update note above.)

## Goals

- Provide consistent key derivation for data & WAL encryption (AES-256-GCM primitives).
- Support rotation with persisted state (active key + history) enabling recovery and forensic replay.
- Allow pluggable providers (StaticEnv, MockKms, ExternalKms) without changing encryption code paths.
- Prepare for secure wrapping (envelope encryption) of data keys under a master key controlled by a remote KMS.

## Non-Goals (Now / Deferred)

- Real network KMS RPCs (HTTP/gRPC) — stub only.
- HSM integration.
- Multi-tenant key segregation policies.
- Key usage attestation / quorum authorization.

## Key Hierarchy (Implemented)

```
Master (provider source) -> Derivation -> { data_key, wal_key }
```

- StaticEnv: `GEODE_DISK_KEY_HEX` (32 bytes hex) -> direct expansion.
- MockKms: Deterministic SHA-256(seed||label) for reproducible tests.
- ExternalKms (stub): SHA-256(endpoint||api_key) => base digest; then DATA/WAL sub-digests.

## Rotation (Implemented)

- Registry tracks: active key, history entries (key id, activation timestamp, retired flag).
- Scheduling logic: min/max age thresholds -> triggers `rotateNow()` when exceeded.
- Persistence: JSON state (active + history) saved atomically; load tolerates missing file.
- Integrity: v1 adds `version` and 16-byte checksum (first 16 bytes of SHA-256 over concatenated materials). Loader: legacy (no checksum) accepted; mismatch clears state.

## Planned External KMS Integration

| Aspect            | Current                | Planned                                    |
| ----------------- | ---------------------- | ------------------------------------------ |
| Master Key Source | Derived digest         | Remote KMS generate + wrap                 |
| Envelope Wrapping | None (raw in memory)   | AES-KWP / RSA-OAEP / provider-native       |
| AuthN             | API key only (env)     | mTLS + short-lived tokens                  |
| Rotation Trigger  | Age-based local policy | KMS-driven policy hooks                    |
| Audit             | Local logging          | Remote KMS access logs + local correlation |

## Backup / Restore Handling (Planned)

1. Persist rotation state (already) alongside encrypted data pages.
2. On restore:
   - Load rotation state file first.
   - For each historical key id needed for page/WAL replay, request unwrap from KMS (future path) or derive (current stub paths).
3. Validate page LSN and encryption key id mapping before replay.
4. Fail fast if required historical key cannot be resolved.

## Security Considerations

- In-memory residency only; no plaintext key persisted (except derived via env / stub path).
- Recommend operators rotate out of StaticEnv/MockKms into real KMS before production certification.
- Add constant-time comparisons when introducing wrap tokens.
- Future hardening: key usage counters, zeroization on rotation retirement, page-level key id tagging.

## Testing Strategy

- Deterministic providers simplify reproducible benchmarks.
- CANARY markers ensure coverage tracking (`REQ-GQL-TDE-003/004/005/OVERHEAD-002`).
- Real-path overhead benchmark: ensures cost envelope prior to AEAD finalization of External KMS wrap path.

## Open Items

- External KMS network client & retry semantics.
- Secure storage of KMS credentials (vault / process isolation).
- Published performance target validation (<5% overhead) with AEAD encryption hot path.
- Backup key workflow finalization (staging keys pre-rotation).

## Status Summary

(Rebaselined 2026-06-11 — GAP-0864.)

| Component                    | Status                   |
| ---------------------------- | ------------------------ |
| StaticEnv Provider           | Stable                   |
| MockKms Provider             | Stable (test-only)       |
| ExternalKms Providers        | Implemented — `VaultTransitClient` + `AwsKmsClient` in `src/security/external_kms_client.zig` (`tests/test_key_rotation_kms_envelopes.zig`) |
| Rotation Persistence         | Implemented              |
| Real-Path Overhead Benchmark | Partial (XOR stream sim) |
| External KMS Network         | Implemented — real HTTP (Vault Transit, AWS KMS) + QUIC remote-KMS path (`zig build test-remote-kms`) |
| Backup Key Workflow          | Not Started              |
| Per-Tenant Keys              | Deferred (GAP-0873; see `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`) |
