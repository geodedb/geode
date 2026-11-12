# SECURITY_PROGRESS.md - Security & Hardening Matrix

This matrix reflects updated evidence as of 2025-09-27, including Remote KMS negative auth, attestation, unwrap concurrency variance, and OLTP overhead publication sync. Network transport variance benchmarking will be reintroduced in a future slice; current benchmark uses documented local fallback.

| Area                              | Status   | Evidence                                                                                                      | Next Action                                                          | Risk |
| --------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---- |
| AES-256-GCM Core                  | COMPLETE | encrypt_pages benchmark, page_manager integration                                                             | Optimize hot path SIMD (future)                                      | Low  |
| Page Encryption                   | COMPLETE | Page read/write tests, checksum validation                                                                    | Add page re-encrypt on rotation (lazy path)                          | Med  |
| WAL Encryption                    | COMPLETE | WAL segment open/write tests                                                                                  | Throughput benchmark under contention                                | Med  |
| Key Rotation (policy-enforced)    | COMPLETE | GAP-0890: rotateNow refuses under min_interval, max_age forces; real lazy re-wrap test (`zig build test-gap0890`) + measured benchmark (`bench-tde-key-rotate`) | Eager full-scan re-encrypt NOT implemented (lazy `reencryptPage` only) | Low  |
| Rotation Integrity (checksum)     | COMPLETE | Tamper test (checksum mismatch clears state)                                                                  | Extend to signed manifest                                            | Low  |
| Simulated External KMS (local)    | PARTIAL  | `external_kms_client.zig` tamper test in `tests/test_external_kms_provider.zig`, which no build step compiles  | Register the test                                                    | Low  |
| Remote KMS Prototype (QUIC)       | COMPLETE | Generate + privileged unwrap tests; serveLoop impl                                                            | Negative auth + concurrency + attestation sig                        | Med  |
| Remote KMS Concurrency Variance   | COMPLETE | BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance (cv=0.028597, p95_mean_ratio=1.0148) | Add transport (QUIC) realism benchmark variant (documented fallback) | Med  |
| TDE Overhead Benchmarks           | PARTIAL  | The AEAD benchmark and <5% threshold test were never compiled and were removed (SONNY-6298); see the OLTP row  | Publish OLTP workload validation                                     | High |
| Backup/Restore Key Handling       | NOT IMPLEMENTED | Key-registry export/import (`backup_key_envelope.zig`) was never compiled and was removed (SONNY-6298) | Implement if needed                                                  | Med  |
| MFA Core (TOTP + Recovery)        | PARTIAL  | Auth + recovery code consumption tests                                                                        | Policy matrix & re-auth interval enforcement                         | Med  |
| MFA Audit Logging                 | COMPLETE | Audit event tests (issued/success/failure)                                                                    | Enrich with geo/IP context                                           | Low  |
| MFA Policy Engine                 | COMPLETE | TimeWindow/Risk/Reauth tests (policy engine)                                                                  | Add geo/IP adaptive policies (future)                                | Med  |
| Remote KMS Attestation            | COMPLETE | Real Ed25519 hash+pub+sig; cryptographic tests                                                                | Add unwrap signature validation test                                 | Low  |
| Performance Validation (<5% OLTP) | COMPLETE | OLTP sim bench + threshold test                                                                               | Publish real workload breakdown (future)                             | High |
| Secrets Zeroization               | PARTIAL  | Callers use `std.crypto.secureZero` directly; `src/security/test_secure_zero.zig` checks `kms.zig` and `tde_nonce_gen.zig` for bare `@memset`. The `secure_mem.zig` wipe utility was never compiled and was removed (SONNY-6298) | Integrate structured audit on failure                                | Med  |
| Rotation Scheduling (operator)    | PARTIAL  | `scheduleRotation` predicate + `rotateIfDue` tick (injected clock, `test-gap0890`); NO in-server timer — scheduling is operator/cron-invoked (GAP-0890 residual) | In-server scheduler only if a production consumer of KeyRegistry lands | Low  |
| Privileged Unwrap Path            | COMPLETE | Privileged unwrap round‑trip test                                                                             | Add negative auth + tamper detection                                 | Med  |
| TDE File-Level Encryption         | PARTIAL  | Schema catalogs (`catalog.zig`, `fle_catalog.zig`) are written through tde_file_encryption.zig; the R-tree, Patricia, domain-trie and JSONB indexes have no on-disk snapshot (SONNY-6298) | N/A                                                                  | Low  |

---

## CANARY Markers

```
CANARY: REQ=REQ-GQL-TDE-CORE-001; FEATURE="AES256GcmPrimitive"; ASPECT=SECURITY; STATUS=TESTED; TEST=Benchmark_encrypt_pages; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-PAGE-001; FEATURE="PageEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestPageEncryptionRoundTrip; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-WAL-001; FEATURE="WalEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestWalEncryptedSegment; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate|TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_AuthNegative; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeSingleUse|TestCANARY_REQ_GQL_MFA_CORE_001_ReauthIntervalPolicyTrigger|TestCANARY_REQ_GQL_MFA_CORE_001_ElevationTtlExpiry|TestCANARY_REQ_GQL_MFA_CORE_001_DynamicPolicyCacheBypass|TestCANARY_REQ_GQL_MFA_CORE_001_EndToEndElevationFlow; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-AUDIT-001; FEATURE="MfaAuditLogging"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestMfaAuditEvents; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow|TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin|TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_SignatureVerify|TestCANARY_REQ_GQL_TDE_ATTEST_001_TamperDetect; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_Threshold; OWNER=perf; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/tde_filelevel_encryption.yml; OWNER=security; UPDATED=2026-01-28
```

> NOTE: Remaining STUB items (OLTP perf validation, privileged unwrap path) must gain TESTED/BENCHED before matrix rows can promote to COMPLETE.

### Notes

- Remote KMS concurrency variance benchmark currently operates in local direct mode (QUIC layer bypassed) due to instability observed in vendored QUIC accept loop under threaded load. This is explicitly a fallback to provide governance evidence; a future enhancement will reintroduce network transport to validate end-to-end latency variance.
