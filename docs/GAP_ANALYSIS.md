# Gap Analysis

**Last Updated**: February 12, 2026
**Verified By**: Requirements-to-Unit-Test Gap Analysis Audit + Security Gap Analysis + Performance Review + Code Quality Review
**GitLab Source of Truth**: <https://gitlab.com/devnw/codepros/geode/geode/-/issues?label_name=gap>

## Summary

| Category | Open Gaps | Closed This Session | Severity |
|----------|-----------|---------------------|----------|
| CLI | 0 | 1 (GAP-0256) | Low |
| GQL Conformance | 1 | 0 | Medium |
| Security | 2 | 9 | Critical-Medium |
| Transport | 1 | 0 | High |
| Storage/Persistence | 1 | 0 | High |
| CI-CD / Supply Chain | 1 | 3 Won't Do + 3 Closed | Critical-Medium |
| Performance | 6 | 11 | P0-P2 |
| Code Quality | 6 | 8 | High-Low |
| Test | 0 | 0 | - |
| Documentation | 0 | 0 | - |
| **Total** | **18 Open** | **35 Closed** | |

**Related Documents**:

- [Performance Gap Analysis](PERF_GAP_ANALYSIS.md) — 17 findings (#444-#460), 11 closed
- [Quality Gap Analysis](QUALITY_GAP_ANALYSIS.md) — 14 new findings (#461-#474) + 15 prior findings (#400-#414), 8 closed this session

---

## Open Gaps

### GAP-0256: CLI `--insecure` flag should be renamed to `--insecure-tls-skip-verify`

- **Status:** ✅ **CLOSED** (February 12, 2026)
- **Category:** CLI
- **Severity:** Low
- **Resolution:** Already implemented. `--insecure-tls-skip-verify` is the primary flag; `--insecure` is a deprecated alias that prints a warning.
- **Evidence:**
  - `src/cli/main.zig:177-178` — Help text shows both flags
  - `src/cli/main.zig:883-887` — Query command parses both flags with deprecation warning
  - `src/cli/main.zig:3817-3821` — Shell command parses both flags with deprecation warning
  - `src/cli/cli_dispatcher.zig:502,628-629` — Shell completions for both flags
- **Acceptance criteria:**
  - [x] CLI accepts `--insecure-tls-skip-verify` as the primary flag
  - [x] CLI accepts `--insecure` as a deprecated alias with warning
  - [x] Documentation updated to reflect new flag name
  - [x] All client DSN parsers use `insecure_tls_skip_verify` as primary parameter

---

### GAP-0257: Missing ISO/IEC 39075:2024 full conformance evidence (beyond MATCH subset)

- **Status:** 🔴 **OPEN**
- **Category:** GQL Conformance
- **Severity:** Medium
- **Description:** Conformance evidence for full ISO/IEC 39075:2024 compliance is incomplete. Current profile and test coverage emphasize MATCH ordering/pagination and related diagnostics, while additional standard sections (DML/DDL, transactions, path semantics, functions, type system behaviors) need verified coverage. This gap tracks the missing evidence and any required implementation work to bring conformance proof in line with full compliance claims.
- **Affected areas:**
  - `docs/gql/GQL_CONFORMANCE_PROFILE.md` - Expand profile scope beyond MATCH subset
  - `tests/` and `geodetestlab/specs/` - Add/expand ISO conformance coverage for non-MATCH features
  - CI gating - Enforce expanded conformance suite
  - Documentation - Ensure published claims remain aligned with full compliance while evidence catches up
- **Acceptance criteria:**
  - [ ] Conformance profile expanded to cover all mandatory ISO/IEC 39075:2024 features
  - [ ] Conformance tests added for non-MATCH features (DML/DDL, transactions, functions, types)
  - [ ] CI enforces expanded conformance test suite with blocking failures
  - [ ] Evidence published to substantiate full ISO conformance claims in public docs

---

### GAP-0258: mTLS CLI commands not available over QUIC transport

- **Status:** 🔴 **OPEN**
- **Category:** Security
- **Severity:** Medium
- **Description:** The `mtls` CLI subcommand (certificate-to-user mapping, fingerprint mapping, SAN mapping, subject CN/DN mapping, strict mode) is not available when using the QUIC-only protobuf client. The command returns: `Error: 'mtls' CLI command is not available in the protobuf/QUIC-only client. Use server-side administration APIs instead.` This means mTLS certificate management cannot be performed via the CLI when using QUIC transport, which is the default and only supported transport. The mTLS functionality needs to be implemented for the QUIC transport layer.
- **Affected files:**
  - `src/cli/cli_dispatcher.zig` - mTLS command routing
  - `src/transport/quic.zig` - QUIC transport layer
  - `src/auth/mtls.zig` - mTLS authentication module
- **Acceptance criteria:**
  - [ ] `geode mtls map` commands work over QUIC transport
  - [ ] Certificate fingerprint, SAN, and subject mapping supported
  - [ ] mTLS strict mode enable/disable functional
  - [ ] Integration tests pass (`mtls_auth.yml` spec)
- **Test coverage:** 22 tests skipped in `geode-test-harness/geodetestlab-cli/specs/mtls_auth.yml` pending this fix
- **Related:** mTLS authentication documentation, QUIC transport implementation

---

### GAP-0259: Synchronous persistence blocks QUIC event loop, causing idle timeout disconnects

- **Status:** 🔴 **OPEN**
- **Category:** Transport
- **Severity:** High
- **Description:** When the GeodeDB server receives INSERT (or other write) statements, it persists data synchronously before returning the response. During this synchronous persistence, the QUIC event loop is blocked — the server cannot process QUIC keep-alive frames or respond to idle timeout probes. If the persistence operation takes longer than the server's 30-second QUIC idle timeout (`quicMaxIdleTimeout = 30 * time.Second`), the server closes the connection with `NO_ERROR (remote)`, even though the client is actively waiting for a response.

  **Observed behavior:** Bulk INSERT operations (e.g., migrating 35,000+ MAC OUI records) consistently fail after ~30 seconds with `transport read_length to 127.0.0.1:3141: NO_ERROR (remote)`. The client receives a clean QUIC close frame because the server's own idle timer fires while the persistence goroutine is blocking the connection's event loop.

  **Workaround:** Clients must batch multiple statements into a single combined query (e.g., 25 INSERTs joined with `;`) and open a fresh connection per batch. This ensures each request completes within the 30-second window, but adds significant client-side complexity and prevents use of standard connection pooling patterns.

  **Root cause:** The persistence path is synchronous and runs on the same goroutine (or blocks the same context) as the QUIC stream handler, preventing the QUIC connection from servicing its idle timeout and keep-alive mechanisms.

- **Affected files:**
  - `src/transport/quic.zig` - QUIC connection handler / stream processing
  - `src/server/query_executor.zig` - Write execution path that triggers persistence
  - `src/storage/` - Synchronous persistence implementation
- **Acceptance criteria:**
  - [ ] Server can process bulk INSERT workloads (35,000+ statements) without QUIC idle timeout disconnects
  - [ ] QUIC keep-alive frames are processed even while persistence is in progress
  - [ ] Persistence does not block the QUIC event loop / stream handler goroutine
  - [ ] Client can use a single long-lived connection for bulk write operations
  - [ ] Add integration test: 1,000+ sequential INSERTs over a single QUIC connection without timeout
- **Reproduction:**

  ```bash
  # Start GeodeDB server
  # Send >30s worth of INSERT statements over a single QUIC connection
  # Connection closes with NO_ERROR after ~30s regardless of client keep-alive settings
  ```

- **Related:** GAP-0260 (synchronous per-statement persistence)

---

### GAP-0260: Per-statement synchronous persistence causes excessive I/O for bulk operations

- **Status:** 🔴 **OPEN**
- **Category:** Storage/Persistence
- **Severity:** High
- **Description:** The GeodeDB server appears to perform a full synchronous persistence (fsync/flush to disk) after every individual INSERT statement. For bulk data loading scenarios (thousands of INSERTs), this results in excessive disk I/O and dramatically reduced throughput. Combined with the QUIC idle timeout issue (GAP-0259), this makes bulk loading impractical without client-side batching workarounds.

  **Observed behavior:** When sending individual INSERT statements sequentially, throughput degrades severely as the server blocks on disk I/O for each statement. The time to persist a single batch of 25 INSERTs (sent as one combined query) is roughly proportional to 25x individual persist operations, suggesting no write coalescing or WAL-based batching is in effect.

  **Expected behavior:** The server should support one or more of the following for bulk operations:
  1. **Write-ahead log (WAL) with group commit** — Buffer writes in a WAL and flush periodically or on transaction commit, not per-statement.
  2. **Batch/bulk INSERT optimization** — Detect multi-statement queries and defer persistence until the entire batch completes.
  3. **Configurable durability** — Allow clients to opt into relaxed durability for bulk loads (e.g., `SET sync_mode = 'batch'`), similar to PostgreSQL's `synchronous_commit = off`.

- **Affected files:**
  - `src/storage/` - Persistence layer, fsync strategy
  - `src/server/query_executor.zig` - Per-statement commit/persist triggers
  - `src/server/transaction_handlers.zig` - Transaction commit persistence
- **Acceptance criteria:**
  - [ ] Bulk INSERT of 35,000 records completes in under 60 seconds (currently requires ~10 minutes with workarounds)
  - [ ] Write-ahead log or group commit mechanism batches persistence across multiple statements
  - [ ] Single-statement durability guarantee preserved for non-bulk workloads (default behavior unchanged)
  - [ ] Benchmark added: bulk INSERT throughput (statements/second) for 1K, 10K, 50K records
- **Related:** GAP-0259 (QUIC idle timeout during persistence)

---

---

## Security Review Findings (February 11, 2026)

**Methodology**: Automated scanning (gitleaks, hadolint, shellcheck) + manual adversarial review
**Overall Security Posture**: 7/10 — Strong application security, weak supply chain and secret management

### Stack-Ranked Findings

| # | Severity | Risk | Title | Issue | Status |
|---|----------|------|-------|-------|--------|
| 1 | CRITICAL | 95 | Secrets tracked in git (.env) | [#428](https://gitlab.com/devnw/codepros/geode/geode/-/issues/428) | ✅ **CLOSED** — `.env` untracked from git |
| 2 | CRITICAL | 90 | TLS private keys tracked in git | [#429](https://gitlab.com/devnw/codepros/geode/geode/-/issues/429) | ✅ **CLOSED** — No keys tracked (verified) |
| 3 | CRITICAL | 85 | GoReleaser curl-pipe-bash in CI | [#430](https://gitlab.com/devnw/codepros/geode/geode/-/issues/430) | 🔴 OPEN — Requires CI pipeline refactor |
| 4 | HIGH | 80 | Zig compiler downloaded without checksum | [#431](https://gitlab.com/devnw/codepros/geode/geode/-/issues/431) | 🔴 OPEN — Requires CI image build changes |
| 5 | HIGH | 70 | Unpinned docker:latest in CI pipeline | [#432](https://gitlab.com/devnw/codepros/geode/geode/-/issues/432) | ⬜ **WON'T DO** — Handled via different controls (image registry pinning) |
| 6 | HIGH | 65 | Vault KMS subprocess injection risk | [#435](https://gitlab.com/devnw/codepros/geode/geode/-/issues/435) | ✅ **CLOSED** — Input validation added to `vault_kms_provider.zig` |
| 7 | MEDIUM | 55 | Dockerfile base images not digest-pinned | [#433](https://gitlab.com/devnw/codepros/geode/geode/-/issues/433) | ⬜ **WON'T DO** — Handled via image registry controls |
| 8 | MEDIUM | 55 | Pre-commit hooks pinned by tag, not hash | [#434](https://gitlab.com/devnw/codepros/geode/geode/-/issues/434) | ⬜ **WON'T DO** — Handled via different controls (CI catalog versioning) |
| 9 | MEDIUM | 55 | Missing release signatures and SBOM | [#439](https://gitlab.com/devnw/codepros/geode/geode/-/issues/439) | 🔴 OPEN — Requires release pipeline changes |
| 10 | MEDIUM | 50 | JSON parsing without depth limits (DoS) | [#436](https://gitlab.com/devnw/codepros/geode/geode/-/issues/436) | ✅ **CLOSED** — Depth limit of 64 already implemented |
| 11 | MEDIUM | 45 | MD5 in audit checksum | [#437](https://gitlab.com/devnw/codepros/geode/geode/-/issues/437) | ✅ **CLOSED** — Replaced with SHA-256 in `audit.zig` |
| 12 | MEDIUM | 45 | Unpinned apt/apk/pip in Dockerfiles | [#438](https://gitlab.com/devnw/codepros/geode/geode/-/issues/438) | ⬜ **WON'T DO** — Handled via image rebuild pipeline controls |
| 13 | MEDIUM | 45 | grpc-zig fetched as tarball, not git | [#443](https://gitlab.com/devnw/codepros/geode/geode/-/issues/443) | 🔴 OPEN — Requires build.zig.zon migration |
| 14 | LOW | 30 | Custom constant-time comparison | [#440](https://gitlab.com/devnw/codepros/geode/geode/-/issues/440) | ✅ **CLOSED** — Migrated to `std.crypto.timing_safe.eql` |
| 15 | LOW | 25 | Missing SHELL pipefail in Dockerfiles | [#442](https://gitlab.com/devnw/codepros/geode/geode/-/issues/442) | ✅ **CLOSED** — Added `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` to 5 Dockerfiles |
| 16 | LOW | 20 | Dockerfile.dev syntax error | [#441](https://gitlab.com/devnw/codepros/geode/geode/-/issues/441) | ✅ **CLOSED** — No syntax error found (verified valid) |

**Note on Won't Do items (#432, #433, #434, #438)**: These CI/CD hash and Docker tag pinning items are handled via different organizational controls (image registry pinning policies, CI catalog versioning, image rebuild pipeline schedules) rather than in-repo configuration. This is a deliberate architectural decision — future agents should not reopen these items.

### Positive Security Findings

- Argon2id with OWASP parameters for password hashing
- Constant-time comparison for all credential validation
- mTLS support with certificate-to-user mapping
- Non-root users in all production Dockerfiles
- QUIC+TLS 1.3 only transport (no insecure fallback)
- Dedicated timing attack test suite
- All Zig deps (except grpc-zig) use git+https with commit hashes
- Cargo.lock and package-lock.json committed with integrity hashes

### Remediation Priority (Updated February 12, 2026)

- **P0 (DONE)**: #428 ✅, #429 ✅ — Secrets removed from git tracking
- **P1 (Remaining)**: #430, #431 — CI supply chain (GoReleaser, Zig checksum)
- **P2 (Remaining)**: #439 — Release signatures and SBOM
- **P3 (Remaining)**: #443 — grpc-zig tarball→git migration
- **Won't Do**: #432, #433, #434, #438 — Handled via organizational controls
- **Done**: #435 ✅, #436 ✅, #437 ✅, #440 ✅, #441 ✅, #442 ✅

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
