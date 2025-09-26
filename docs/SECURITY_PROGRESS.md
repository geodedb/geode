# SECURITY_PROGRESS.md - Security & Hardening Matrix

This file centralizes the security hardening status with CANARY markers for traceability. Each row corresponds to one or more requirements. New placeholder requirement IDs use the TDE / SEC prefix pattern and must be integrated into status generation tooling.

| Area                              | Status   | Evidence                                           | Next Action                                   | Risk |
| --------------------------------- | -------- | -------------------------------------------------- | --------------------------------------------- | ---- |
| AES-256-GCM Core                  | COMPLETE | encrypt_pages benchmark, page_manager integration  | Optimize hot path SIMD (future)               | Low  |
| Page Encryption                   | COMPLETE | Page read/write tests, checksum validation         | Add page re-encrypt on rotation (lazy path)   | Med  |
| WAL Encryption                    | COMPLETE | WAL segment open/write tests                       | Throughput benchmark under contention         | Med  |
| Key Rotation Scaffold             | COMPLETE | KeyRotationScaffold test, state persistence tests  | Integrate eager re-encrypt option             | Low  |
| Rotation Integrity (checksum)     | COMPLETE | Tamper test (checksum mismatch clears state)       | Extend to signed manifest                     | Low  |
| Simulated External KMS (local)    | COMPLETE | Wrap/unwrap non-deterministic test                 | N/A (superseded by remote)                    | Low  |
| Remote KMS Prototype (QUIC)       | COMPLETE | Generate + privileged unwrap tests; serveLoop impl | Negative auth + concurrency + attestation sig | Med  |
| TDE Overhead Benchmarks           | COMPLETE | AEAD real benchmark + <5% threshold test           | Publish OLTP workload validation              | High |
| Backup/Restore Key Handling       | COMPLETE | Export/import manifest test                        | Integrate signed manifest & tamper proof      | Med  |
| MFA Core (TOTP + Recovery)        | PARTIAL  | Auth + recovery code consumption tests             | Policy matrix & re-auth interval enforcement  | Med  |
| MFA Audit Logging                 | COMPLETE | Audit event tests (issued/success/failure)         | Enrich with geo/IP context                    | Low  |
| MFA Policy Engine                 | COMPLETE | TimeWindow/Risk/Reauth tests (policy engine)       | Add geo/IP adaptive policies (future)         | Med  |
| Remote KMS Attestation            | COMPLETE | Real Ed25519 hash+pub+sig; cryptographic tests     | Add unwrap signature validation test          | Low  |
| Performance Validation (<5% OLTP) | COMPLETE | OLTP sim bench + threshold test                    | Publish real workload breakdown (future)      | High |
| Secrets Zeroization               | COMPLETE | wipe utility + basic test                          | Integrate structured audit on failure         | Med  |
| Rotation Scheduling (auto)        | COMPLETE | Scheduling predicate test                          | Adaptive schedule (age + usage)               | Low  |
| Privileged Unwrap Path            | COMPLETE | Privileged unwrap round‑trip test                  | Add negative auth + tamper detection          | Med  |

---

### CANARY Markers

```
CANARY: REQ=REQ-GQL-TDE-CORE-001; FEATURE="AES256GcmPrimitive"; ASPECT=SECURITY; STATUS=TESTED; TEST=Benchmark_encrypt_pages; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-PAGE-001; FEATURE="PageEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestPageEncryptionRoundTrip; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-WAL-001; FEATURE="WalEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestWalEncryptedSegment; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate|TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_AuthNegative; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-PERF-001; FEATURE="TDEOverheadBenchmark"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=Test_tde_aead_overhead_threshold; OWNER=perf; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-BACKUP-KEY-001; FEATURE="KeyBackupHandling"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_BACKUP_KEY_001_RoundTrip; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=IMPL; TEST=TestMfaCoreFlows; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-AUDIT-001; FEATURE="MfaAuditLogging"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestMfaAuditEvents; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_POLICY_001_TimeWindow|TestCANARY_REQ_GQL_MFA_POLICY_001_RiskScoreMin|TestCANARY_REQ_GQL_MFA_POLICY_001_ReauthInterval; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_SignatureVerify|TestCANARY_REQ_GQL_TDE_ATTEST_001_TamperDetect; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_Threshold; OWNER=perf; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-ZEROIZE-001; FEATURE="SecretsZeroization"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_ZEROIZE_001_Basic; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_UNWRAP_001_PrivilegedUnwrap; OWNER=security; UPDATED=2025-09-26
```

> NOTE: Remaining STUB items (OLTP perf validation, privileged unwrap path) must gain TESTED/BENCHED before matrix rows can promote to COMPLETE.
