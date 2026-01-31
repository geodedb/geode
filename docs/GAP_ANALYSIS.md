# Gap Analysis

**Last Updated**: January 31, 2026
**Verified By**: Requirements-to-Unit-Test Gap Analysis Audit
**GitLab Source of Truth**: <https://gitlab.com/devnw/codepros/geode/geode/-/issues?label_name=gap>

## Summary

| Category | Open Gaps | Severity |
|----------|-----------|----------|
| Test | 0 | - |
| CI-CD | 0 | - |
| Documentation | 0 | - |
| **Total Open Gaps** | **0** | |

**All gaps closed as of January 31, 2026.**

---

## Recently Closed Gaps (January 31, 2026)

### GAP-0249: MVCC lock table updates lost under contention

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Fixed lock acquisition to mutate the lock table in-place; added unit tests to assert lock table size and conflict handling.
- **Changes made:**
  - `src/server/txn/mvcc.zig` - Use `getOrPut` + value pointers for lock tracking
  - Added unit tests to validate lock table state on conflicts

---

### GAP-0250: MVCC commits did not persist versions

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Fixed version-chain updates to mutate the stored map entry; added unit tests to verify read-after-commit.
- **Changes made:**
  - `src/server/txn/mvcc.zig` - Use `getOrPut` + value pointers for version chains
  - Added unit tests for commit persistence

---

### GAP-0251: MVCC transaction cleanup leaked allocations

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Destroy MVCC transactions on commit/abort and during manager deinit; added unit tests to ensure no leaks on commit failure.
- **Changes made:**
  - `src/server/txn/mvcc.zig` - Cleanup on commit/abort and deinit
  - Added unit tests for commit failure cleanup

---

### GAP-0252: Commit failure paths left active transactions and undo logs

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Added rollback/undo cleanup on commit failures, and stopped autocommit paths from swallowing errors.
- **Changes made:**
  - `src/server/transaction_handlers.zig` - Rollback/undo on commit error
  - `src/server/query_executor.zig` - Autocommit failure handling

---

### GAP-0253: Phantom detection could mark failed transactions as committed

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Reordered commit flow so phantom checks happen before commit timestamp stamping; added tests for phantom conflict cleanup.
- **Changes made:**
  - `src/transactions/manager.zig` - Phantom checks before commit stamping
  - Added unit tests for phantom conflict behavior

---

### GAP-0254: Transaction write history grew without pruning

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Added write-history pruning and rollback cleanup for aborted transactions to prevent unbounded growth.
- **Changes made:**
  - `src/transactions/manager.zig` - Prune committed writes and remove aborted writes
  - Added unit tests for rollback cleanup

---

### GAP-0255: Undo log persistence dropped complex entries

- **Status:** ✅ **CLOSED**
- **Category:** Test
- **Resolution:** Implemented full serialization/deserialization for all undo entry types; added roundtrip persistence tests.
- **Changes made:**
  - `src/txn_undo_log.zig` - Complete binary encode/decode
  - Added unit tests for persistence roundtrips

---

## Recently Closed Gaps (January 30, 2026)

### GAP-0243: Performance optimization IMPL markers not updated to TESTED despite tests existing

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#377](https://gitlab.com/devnw/codepros/geode/geode/-/issues/377)
- **Category:** Test
- **Resolution:** Updated all 10 CANARY markers from `STATUS=IMPL` to `STATUS=TESTED` with TEST= references
- **Changes made:**
  - `src/cli/main.zig` - Updated 3 markers (WriteStall, AdaptiveBackoff)
  - `src/transport/quic.zig` - Updated 2 markers (ConnectionRemoval, StreamRemoval O(1))
  - `src/transport/stream_scheduler.zig` - Updated 2 markers (DRRScheduler)
  - `src/transport/thread_pool.zig` - Updated 3 markers (ThreadPool)
  - Regenerated `docs/status.csv` with updated marker counts
- **Verification:** `grep "STATUS=IMPL.*PERF" src/transport/*.zig src/cli/main.zig` returns 0 matches

---

### GAP-0244: Performance benchmarks not enforced in CI merge gates

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#378](https://gitlab.com/devnw/codepros/geode/geode/-/issues/378)
- **Category:** CI-CD
- **Resolution:** Added new CI job `test-performance-benchmarks` with `allow_failure: false`
- **Changes made:**
  - `.gitlab-ci.yml` - Added new job after `test-zig-release-safe`:
    - Runs performance tests with ReleaseSafe optimization
    - Blocks merge on failure
    - Includes CANARY marker for REQ-0009 compliance
- **Verification:** `grep -A5 "test-performance-benchmarks:" .gitlab-ci.yml` shows job configuration

---

### GAP-0245: API Keys authentication documented but not implemented

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#396](https://gitlab.com/devnw/codepros/geode/geode/-/issues/396)
- **Category:** Documentation
- **Resolution:** API Key authentication fully implemented
- **Implementation:**
  - `src/security/api_keys.zig` - Complete API key generation, validation, storage, revocation
  - Key format: `gk1.<token_id_b64url>.<secret_b64url>`
  - Features: Scoped permissions, expiration, usage tracking
  - Tests: `geodetestlab/specs/api_key_auth.yml`
- **Documentation updated:**
  - `docs/USER_AUTH.md` - Added Section 11 with API key usage examples
  - `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` - Added to authentication methods table

---

### GAP-0246: LDAP/Active Directory authentication documented but not implemented

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#397](https://gitlab.com/devnw/codepros/geode/geode/-/issues/397)
- **Category:** Documentation
- **Resolution:** Documentation updated to clarify LDAP/AD is planned, not implemented
- **Changes made:**
  - `docs/USER_AUTH.md` - Added "Planned Authentication Methods" table with Q2 2026 target
  - `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` - Added roadmap table showing LDAP as planned
  - Note added: "For enterprise SSO before LDAP is available, consider mTLS with PKI"
- **Acceptance criteria (b):** Documentation updated to mark as "Planned"

---

### GAP-0247: OAuth2/OIDC authentication documented but not implemented

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#398](https://gitlab.com/devnw/codepros/geode/geode/-/issues/398)
- **Category:** Documentation
- **Resolution:** Documentation updated to clarify OAuth2/OIDC is planned, not implemented
- **Changes made:**
  - `docs/USER_AUTH.md` - Added "Planned Authentication Methods" table with Q3 2026 target
  - `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` - Added roadmap table showing OAuth2 as planned
- **Acceptance criteria (b):** Documentation updated to mark as "Planned"

---

### GAP-0248: mTLS authentication documented as "Very High" security but only transport-level implemented

- **Status:** ✅ **CLOSED**
- **GitLab issue:** [#399](https://gitlab.com/devnw/codepros/geode/geode/-/issues/399)
- **Category:** Documentation
- **Resolution:** Application-level mTLS authentication fully implemented
- **Implementation:**
  - `src/security/mtls_provider.zig` - Complete certificate-to-user mapping:
    - Certificate fingerprint extraction (SHA-256)
    - Subject CN/DN extraction
    - Subject Alternative Name (SAN) support: email, DNS, URI
    - Certificate-to-user mapping management
  - `src/security/authn.zig` - Unified auth provider with mTLS as highest-priority method
  - Tests: `geodetestlab/specs/mtls_auth.yml`
- **Documentation updated:**
  - `docs/USER_AUTH.md` - Added mTLS usage examples in Section 11
  - `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` - mTLS listed as implemented in auth table
- **Acceptance criteria (a):** Certificate-based user authentication implemented

---

## Test Coverage Summary

| Component | Source Files | Inline Tests | External Tests | Status |
|-----------|-------------|--------------|----------------|--------|
| CLI | 11 | 185 | 15+ | Excellent |
| Security | 31 | 97+ | 33+ | Excellent |
| Types | 20 | 87+ | 20+ | Excellent |
| GQL Parser | 9 | 52 | 61 (test_syntax_validation.zig) | Excellent |
| Graph | 42 | 50 | 15+ | Good |
| Distributed | 19 | 47 | 25+ | Good |
| Storage | 25 | 30 | 15+ | Moderate |
| Monitoring | 6 | 19 | 5+ | Good |
| MVCC Advanced | 7 | 21 | 10+ | Good |
| Query/Runtime | 2+ | 14 | 10+ | Good |
| Containers | 2 | 13 | 5+ | Good |
| Type Promotion | 1 | 21 | 5+ | Good |
| CDC Core | 3 | 18 | 5+ | Good |
| Bug Regression | 1 | 0 | 12 (gap_0242_regression_tests.yml) | Excellent |
| **Transport Perf** | 3 | 0 | 21 (test_performance_optimizations.zig) | Good |
| **Auth Methods** | 3 | 0 | 3 (geodetestlab specs) | Good |

## Governance Status

| Status | Count | Percentage |
|--------|-------|------------|
| TESTED | 3,130+ | 83.5% |
| EXEMPT | 400 | 10.5% |
| BENCHED | 219 | 5.7% |
| IMPL | 25 | 0.7% |
| COMPLETE | 4 | 0.1% |
| STUB | 0 | 0.0% |
| **Total** | **4,046** | |

Note: IMPL count reduced from 35 to ~25 after GAP-0243 marker updates.

## CI Enforcement Status

| Gate | Status | Evidence |
|------|--------|----------|
| Unit tests block merge | ✅ Enforced | `.gitlab-ci.yml:259` - `allow_failure: false` |
| ReleaseSafe tests | ✅ Enforced | `.gitlab-ci.yml:288` - `allow_failure: false` |
| **Performance benchmarks** | ✅ Enforced | `.gitlab-ci.yml` - `test-performance-benchmarks` job (GAP-0244 fix) |
| GQL compliance tests | ✅ Enforced | `.gitlab-ci.yml:336` - `allow_failure: false` |
| Comprehensive tests | ✅ Enforced | `.gitlab-ci.yml:381` - `allow_failure: false` |
| CANARY lint | ✅ Enforced | `.gitlab-ci.yml:140` - `allow_failure: false` |
| Canaryscan verify | ✅ Enforced | `.gitlab-ci.yml:172` - `allow_failure: false` |
| Conformance sync | ✅ Enforced | `.gitlab-ci.yml:242` - `allow_failure: false` |

### Justified allow_failure: true

| Job | Line | Justification |
|-----|------|---------------|
| zig-format | 13 | Formatting is advisory, not blocking |
| governance-canary-drift | 111 | Warning only, count check is informational |
| governance-req-doc-reports | 213 | Reports are informational, not blocking |
| snapshot | 442 | Snapshot builds for non-tag commits |
| test-nix-flake | 559 | Nix builds may fail due to external dependencies |

## Test System Inventory

### Framework

- **Language**: Zig 0.15.2
- **Unit Tests**: Inline `test "..."` blocks in source files
- **Integration Tests**: External test files in `tests/` directory
- **E2E Tests**: `geodetestlab/` spec files with `extended_test_runner.py`
- **Benchmarks**: `tests/benchmark_*.zig` (146 files) - CI-enforced via `test-performance-benchmarks`
- **CI Runner**: GitLab CI with custom Zig Docker image

### Commands

```bash
# Unit tests
zig build test --summary all

# GQL compliance
python3 scripts/test/extended_test_runner.py geode_gql_compliance

# Comprehensive
make geodetestlab-comprehensive

# Performance benchmarks
zig build test -Doptimize=ReleaseSafe --summary all

# Bug regression tests
python3 scripts/test/extended_test_runner.py gap_0242
```

---

**Resolved gaps have been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).**

Previous resolutions:

- January 30, 2026: GAP-0243 through GAP-0248 resolved
- January 25, 2026: GAP-0225 through GAP-0242 resolved
