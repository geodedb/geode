# SECURITY_PROGRESS.md - Security & Hardening Matrix

This file centralizes the security hardening status with CANARY markers for traceability. Each row corresponds to one or more requirements. New placeholder requirement IDs use the TDE / SEC prefix pattern and must be integrated into status generation tooling.

| Area                              | Status   | Evidence                                          | Next Action                                    | Risk |
| --------------------------------- | -------- | ------------------------------------------------- | ---------------------------------------------- | ---- |
| AES-256-GCM Core                  | COMPLETE | encrypt_pages benchmark, page_manager integration | Optimize hot path SIMD (future)                | Low  |
| Page Encryption                   | COMPLETE | Page read/write tests, checksum validation        | Add page re-encrypt on rotation (lazy path)    | Med  |
| WAL Encryption                    | COMPLETE | WAL segment open/write tests                      | Throughput benchmark under contention          | Med  |
| Key Rotation Scaffold             | COMPLETE | KeyRotationScaffold test, state persistence tests | Integrate eager re-encrypt option              | Low  |
| Rotation Integrity (checksum)     | COMPLETE | Tamper test (checksum mismatch clears state)      | Extend to signed manifest                      | Low  |
| Simulated External KMS (local)    | COMPLETE | Wrap/unwrap non-deterministic test                | N/A (superseded by remote)                     | Low  |
| Remote KMS Prototype (QUIC)       | PARTIAL  | Remote generate/rotate test                       | Auth (mTLS / token), async loop, attestation   | High |
| TDE Overhead Benchmarks           | COMPLETE | AEAD real benchmark + <5% threshold test          | Publish OLTP workload validation               | High |
| Backup/Restore Key Handling       | PENDING  | N/A                                               | Design envelope export/import semantics        | Med  |
| MFA Core (TOTP + Recovery)        | PARTIAL  | Auth + recovery code consumption tests            | Policy matrix & re-auth interval enforcement   | Med  |
| MFA Audit Logging                 | COMPLETE | Audit event tests (issued/success/failure)        | Enrich with geo/IP context                     | Low  |
| MFA Policy Engine                 | PARTIAL  | Evaluator unit tests                              | Expand condition set (time-of-day, risk score) | Med  |
| Remote KMS Attestation            | PENDING  | N/A                                               | Envelope signing + verification                | High |
| Performance Validation (<5% OLTP) | PENDING  | Synthetic benchmark only                          | Run representative OLTP suite & publish report | High |
| Secrets Zeroization               | PENDING  | N/A                                               | Explicit wipe & audit for failures             | Med  |
| Rotation Scheduling (auto)        | COMPLETE | Scheduling predicate test                         | Adaptive schedule (age + usage)                | Low  |
| Privileged Unwrap Path            | PENDING  | N/A                                               | Secure unwrap via remote KMS with auth         | High |

---

### CANARY Markers

```
CANARY: REQ=REQ-GQL-TDE-CORE-001; FEATURE="AES256GcmPrimitive"; ASPECT=SECURITY; STATUS=TESTED; TEST=Benchmark_encrypt_pages; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-PAGE-001; FEATURE="PageEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestPageEncryptionRoundTrip; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-WAL-001; FEATURE="WalEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestWalEncryptedSegment; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-001; FEATURE="KeyRotationScaffold"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_key_rotation.zig; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-KEYROT-STATE-001; FEATURE="KeyRotationStatePersistence"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_SEC_KEYROT_STATE_001_LoadSave; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_Generate; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-PERF-001; FEATURE="TDEOverheadBenchmark"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=Test_tde_aead_overhead_threshold; OWNER=perf; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-BACKUP-KEY-001; FEATURE="KeyBackupHandling"; ASPECT=SECURITY; STATUS=STUB; TEST=NONE; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestMfaCoreFlows; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-AUDIT-001; FEATURE="MfaAuditLogging"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestMfaAuditEvents; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-MFA-POLICY-001; FEATURE="MfaPolicyEngine"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestMfaPolicyEvaluator; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=SECURITY; STATUS=STUB; TEST=NONE; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PERFORMANCE; STATUS=STUB; TEST=NONE; OWNER=perf; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-ZEROIZE-001; FEATURE="SecretsZeroization"; ASPECT=SECURITY; STATUS=STUB; TEST=NONE; OWNER=security; UPDATED=2025-09-26
CANARY: REQ=REQ-GQL-SEC-UNWRAP-001; FEATURE="PrivilegedUnwrapPath"; ASPECT=SECURITY; STATUS=STUB; TEST=NONE; OWNER=security; UPDATED=2025-09-26
```

> NOTE: STUB requirements will fail strict status assertions if marked COMPLETE elsewhere without corresponding TESTED or BENCHED upgrades.
