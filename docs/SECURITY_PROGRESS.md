# SECURITY_PROGRESS.md - Security & Hardening Matrix

This matrix reflects updated evidence as of 2025-09-27, including Remote KMS negative auth, attestation, unwrap concurrency variance, and OLTP overhead publication sync. Network transport variance benchmarking will be reintroduced in a future slice; current benchmark uses documented local fallback.

| Area                              | Status   | Evidence                                                                                                      | Next Action                                                          | Risk |
| --------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---- |
| AES-256-GCM Core                  | COMPLETE | encrypt_pages benchmark, page_manager integration                                                             | Optimize hot path SIMD (future)                                      | Low  |
| Page Encryption                   | COMPLETE | Page read/write tests, checksum validation                                                                    | Add page re-encrypt on rotation (lazy path)                          | Med  |
| WAL Encryption                    | PARTIAL  | The storage-engine WAL is encrypted with `GEODE_TDE_KEY` (the engine `encryption_key`); no test reads a WAL segment back to check it is ciphertext (SONNY-6422) | Add a WAL-ciphertext test                                            | Med  |
| Key Rotation (policy-enforced)    | COMPLETE | GAP-0890: rotateNow refuses under min_interval, max_age forces; real lazy re-wrap test (`zig build test-gap0890`) + measured benchmark (`bench-tde-key-rotate`) | Eager full-scan re-encrypt NOT implemented (lazy `reencryptPage` only) | Low  |
| Rotation Integrity (checksum)     | NOT IMPLEMENTED | `KeyRegistry` persists no state to checksum: the uncompiled `saveState`/`loadState` and their checksum test were removed (SONNY-6386) | Implement with persisted rotation state, if needed                   | Low  |
| Simulated External KMS (local)    | COMPLETE | `external_kms_client.zig` wrap/unwrap and tamper tests (`zig build test-external-kms-provider`); a local simulator, not a KMS | N/A                                                                  | Low  |
| Remote KMS Prototype (QUIC)       | COMPLETE | Generate + privileged unwrap tests; serveLoop impl                                                            | Negative auth + concurrency + attestation sig                        | Med  |
| Remote KMS Concurrency Variance   | COMPLETE | BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance (cv=0.028597, p95_mean_ratio=1.0148) | Add transport (QUIC) realism benchmark variant (documented fallback) | Med  |
| TDE Overhead Benchmarks           | PARTIAL  | The AEAD benchmark and <5% threshold test were never compiled and were removed (SONNY-6298); see the OLTP row  | Publish OLTP workload validation                                     | High |
| Backup/Restore Key Handling       | NOT IMPLEMENTED | Key-registry export/import (`backup_key_envelope.zig`) was never compiled and was removed (SONNY-6298) | Implement if needed                                                  | Med  |
| MFA Core (TOTP + Recovery)        | PARTIAL  | Auth + recovery code consumption tests                                                                        | Policy matrix & re-auth interval enforcement                         | Med  |
| MFA Audit Logging                 | NOT VERIFIED | No test checks MFA audit events (SONNY-6422)                                                                | Add an audit event test                                              | Low  |
| MFA Policy Engine                 | PARTIAL  | The TimeWindow/Risk/Reauth tests are in `tests/test_mfa_policies.zig`, which no build step compiles (SONNY-6422) | Register the test                                                    | Med  |
| Remote KMS Attestation            | COMPLETE | Real Ed25519 hash+pub+sig; cryptographic tests                                                                | Add unwrap signature validation test                                 | Low  |
| Performance Validation (<5% OLTP) | NOT VERIFIED | The OLTP threshold test `tests/test_tde_oltp_overhead_threshold.zig` is compiled by no build step (SONNY-6422) | Register and calibrate the measurement                               | High |
| Secrets Zeroization               | PARTIAL  | Callers use `std.crypto.secureZero` directly; `src/security/test_secure_zero.zig` checks `kms.zig` and `tde_nonce_gen.zig` for bare `@memset`. The `secure_mem.zig` wipe utility was never compiled and was removed (SONNY-6298) | Integrate structured audit on failure                                | Med  |
| Rotation Scheduling (operator)    | PARTIAL  | `scheduleRotation` predicate + `rotateIfDue` tick (injected clock, `test-gap0890`); NO in-server timer — scheduling is operator/cron-invoked (GAP-0890 residual) | In-server scheduler only if a production consumer of KeyRegistry lands | Low  |
| Privileged Unwrap Path            | COMPLETE | Privileged unwrap round‑trip test                                                                             | Add negative auth + tamper detection                                 | Med  |
| TDE File-Level Encryption         | PARTIAL  | Schema catalogs (`catalog.zig`, `fle_catalog.zig`) are written through tde_file_encryption.zig; the R-tree, Patricia, domain-trie and JSONB indexes have no on-disk snapshot (SONNY-6298) | N/A                                                                  | Low  |

---

## CANARY Markers

```
CANARY: REQ=REQ-GQL-TDE-CORE-001; FEATURE="AES256GcmPrimitive"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_tde_nonce.zig|tests/e2e_security_tde_mfa.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-PAGE-001; FEATURE="PageEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_gap0843_tenant_tde.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-WAL-001; FEATURE="WalEncryption"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_gap0890_rotation_policy.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_external_kms_provider.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/canary_remote_kms.zig|tests/canary_remote_kms_hardening.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/canary_mfa_recovery_code_contention.zig|tests/canary_mfa_risk_stepup.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-MFA-AUDIT-001; FEATURE="MfaAuditLogging"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/canary_remote_kms.zig|tests/canary_remote_kms_hardening.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PERFORMANCE; STATUS=IMPL; OWNER=perf; UPDATED=2026-11-12
CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/canary_remote_kms.zig; OWNER=security; UPDATED=2026-11-12
CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/tde_filelevel_encryption.yml; OWNER=security; UPDATED=2026-01-28
```

> NOTE (2026-11-12, SONNY-6422): this block used to cite tests that do not
> exist (`Benchmark_encrypt_pages`, `TestPageEncryptionRoundTrip`,
> `TestWalEncryptedSegment`, `tests/test_key_rotation.zig`,
> `TestMfaAuditEvents`, ...) or that no build step compiles
> (`tests/test_mfa_policies.zig`, `tests/test_remote_kms_attestation.zig`,
> `tests/test_remote_kms_auth_negative.zig`,
> `tests/canary_mfa_core_additional.zig`,
> `tests/test_tde_oltp_overhead_threshold.zig`). Each TESTED marker now cites
> test files a build step runs; WAL encryption, MFA audit logging, the MFA
> policy engine and the OLTP overhead validation have no compiled test and
> are IMPL.

### Notes

- Remote KMS concurrency variance benchmark currently operates in local direct mode (QUIC layer bypassed) due to instability observed in vendored QUIC accept loop under threaded load. This is explicitly a fallback to provide governance evidence; a future enhancement will reintroduce network transport to validate end-to-end latency variance.
