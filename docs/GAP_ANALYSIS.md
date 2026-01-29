# Gap Analysis

**Last Updated**: January 29, 2026
**Verified By**: Requirements-to-Unit-Test Gap Analysis Audit
**GitLab Source of Truth**: <https://gitlab.com/devnw/codepros/geode/geode/-/issues?label_name=gap>

## Summary

| Category | Open Gaps | Severity |
|----------|-----------|----------|
| Test | 1 | Medium |
| CI-CD | 1 | Medium |
| Documentation | 4 | High |
| **Total Open Gaps** | **6** | |

## Open Gaps

### GAP-0243: Performance optimization IMPL markers not updated to TESTED despite tests existing

- **GitLab issue:** [#377](https://gitlab.com/devnw/codepros/geode/geode/-/issues/377)
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** CANARY governance (commits cf04cffd, 713f43c3 from 2026-01-26)
- **Current state (evidence):**
  - `src/cli/main.zig:612,1841,1974` — 3 IMPL markers (WriteStall, AdaptiveBackoff)
  - `src/transport/quic.zig:212,310` — 2 IMPL markers (ConnectionRemoval, StreamRemoval O(1))
  - `src/transport/stream_scheduler.zig:3,44` — 2 IMPL markers (DRRScheduler)
  - `src/transport/thread_pool.zig:3,99,262` — 3 IMPL markers (ThreadPool)
  - `tests/test_performance_optimizations.zig` — 556 lines, 21 test functions (PASS)
  - Command: `zig build test` → PASS (verified 2026-01-26)
- **Why this is a gap:** Tests exist and pass, but CANARY markers remain at IMPL status, violating governance requirements
- **Impact/Risk:** False positive governance warnings, inaccurate status.csv statistics
- **Recommended fix:** Update CANARY markers from `STATUS=IMPL` to `STATUS=TESTED`, reference test file
- **Acceptance criteria:** All 10 affected CANARY markers updated; `grep ",IMPL," docs/status.csv | grep REQ-PERF` returns 0 matches

---

### GAP-0244: Performance benchmarks not enforced in CI merge gates

- **GitLab issue:** [#378](https://gitlab.com/devnw/codepros/geode/geode/-/issues/378)
- **Category:** CI-CD
- **Severity:** Medium
- **Requirement source:** REQ-0009 (Performance Targets), `docs/loadtest/DATA_MODEL.md:394-402`
- **Current state (evidence):**
  - `tests/benchmark*.zig` — 146 benchmark files exist
  - `.gitlab-ci.yml:255-260` — test-zig-unit runs unit tests only, not benchmarks with budgets
  - Command: `grep -i "benchmark" .gitlab-ci.yml` → Only line 118 (comment in canary-lint)
  - Documented SLAs: p99 < 100ms for Timeline queries, p95 < 50ms for Vector Search
  - Variance envelope thresholds: CV ≤ 0.22, p95/mean ≤ 2.55 (in benchmark files, not CI-enforced)
- **Why this is a gap:** Performance budgets documented but not enforced as CI merge gate
- **Impact/Risk:** Performance regressions can be merged silently without detection
- **Recommended fix:** Add dedicated CI job `test-performance-benchmarks` with `allow_failure: false`
- **Acceptance criteria:** CI job runs benchmarks on MRs; enforces latency budgets; blocks merge on regression

---

### GAP-0245: API Keys authentication documented but not implemented

- **GitLab issue:** [#396](https://gitlab.com/devnw/codepros/geode/geode/-/issues/396)
- **Category:** Documentation
- **Severity:** High
- **Requirement source:** `docs/USER_AUTH.md` authentication methods table
- **Current state (evidence):**
  - Documentation claims: "API Keys - Service accounts, automation - Medium-High security"
  - `grep -r "api_key\|ApiKey\|API_KEY" src/security/` → No production implementation
  - `geodetestlab/specs/geode_auth.yml:28-32` → Placeholder "api_token" in test spec, marked optional
  - No API key generation, validation, storage, or revocation mechanisms in codebase
  - No dedicated API key data structures or endpoints
- **Why this is a gap:** Documentation advertises API key authentication as available, but zero production code exists
- **Impact/Risk:** Users expecting API key auth for service accounts will find feature unavailable; misleading documentation
- **Recommended fix:** Either implement API key authentication or remove/qualify claim in documentation
- **Acceptance criteria:** Either (a) API key generation/validation implemented with tests, or (b) documentation updated to mark as "Planned"

---

### GAP-0246: LDAP/Active Directory authentication documented but not implemented

- **GitLab issue:** [#397](https://gitlab.com/devnw/codepros/geode/geode/-/issues/397)
- **Category:** Documentation
- **Severity:** High
- **Requirement source:** `docs/USER_AUTH.md` authentication methods table
- **Current state (evidence):**
  - Documentation claims: "LDAP/Active Directory - Enterprise environments - High security"
  - `grep -ri "ldap\|active_directory\|activedirectory" src/` → Zero matches
  - No LDAP client library integration
  - No LDAP bind, search, or authentication flow implementations
  - No AD-specific configuration or schema mapping
- **Why this is a gap:** Documentation advertises enterprise LDAP/AD integration, but no implementation exists
- **Impact/Risk:** Enterprise customers expecting AD integration will be unable to use it; critical for enterprise adoption
- **Recommended fix:** Either implement LDAP/AD authentication backend or remove/qualify claim in documentation
- **Acceptance criteria:** Either (a) LDAP authentication backend with bind/search/auth implemented, or (b) documentation updated to mark as "Planned"

---

### GAP-0247: OAuth2/OIDC authentication documented but not implemented

- **GitLab issue:** [#398](https://gitlab.com/devnw/codepros/geode/geode/-/issues/398)
- **Category:** Documentation
- **Severity:** High
- **Requirement source:** `docs/USER_AUTH.md` authentication methods table
- **Current state (evidence):**
  - Documentation claims: "OAuth2/OIDC - SSO integration, cloud-native - High security"
  - `grep -ri "oauth\|oidc\|openid" src/` → Zero matches
  - No OAuth2 client or provider implementation
  - No OpenID Connect discovery, token exchange, or ID token validation
  - No authorization server integration
- **Why this is a gap:** Documentation advertises OAuth2/OIDC for SSO, but no implementation exists
- **Impact/Risk:** Cloud-native deployments expecting SSO integration will find feature unavailable
- **Recommended fix:** Either implement OAuth2/OIDC client support or remove/qualify claim in documentation
- **Acceptance criteria:** Either (a) OAuth2/OIDC client with token validation implemented, or (b) documentation updated to mark as "Planned"

---

### GAP-0248: mTLS authentication documented as "Very High" security but only transport-level implemented

- **GitLab issue:** [#399](https://gitlab.com/devnw/codepros/geode/geode/-/issues/399)
- **Category:** Documentation
- **Severity:** High
- **Requirement source:** `docs/USER_AUTH.md` authentication methods table
- **Current state (evidence):**
  - Documentation claims: "mTLS (Mutual TLS) - Zero-trust, service mesh - Very High security"
  - `src/transport/quic.zig:507-549` → `connectEx()` accepts `client_cert_path` and `client_key_path`
  - Transport layer supports TLS 1.3 with client certificate presentation
  - **However:** No application-level client certificate authentication exists
  - Certificates are used for transport security, NOT as a primary authentication mechanism
  - No certificate-to-user mapping, no cert-based session establishment, no cert DN extraction for auth
  - Users cannot authenticate using client certificates instead of username/password
- **Why this is a gap:** mTLS transport security ≠ mTLS authentication; documentation implies cert-based user auth
- **Impact/Risk:** Zero-trust deployments expecting cert-based auth will find only transport-level mTLS
- **Recommended fix:** Either implement application-level cert authentication or clarify documentation to distinguish transport mTLS from auth mTLS
- **Acceptance criteria:** Either (a) Certificate-based user authentication implemented (cert DN → user mapping), or (b) documentation clarified: "mTLS transport security" vs "mTLS authentication"

---

## Test Coverage Summary

| Component | Source Files | Inline Tests | External Tests | Status |
|-----------|-------------|--------------|----------------|--------|
| CLI | 11 | 185 | 15+ | Excellent |
| Security | 28 | 97 | 30+ | Excellent |
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

## Governance Status

| Status | Count | Percentage |
|--------|-------|------------|
| TESTED | 3,120 | 83.0% |
| EXEMPT | 400 | 10.6% |
| BENCHED | 219 | 5.8% |
| IMPL | 35 | 0.9% |
| COMPLETE | 4 | 0.1% |
| STUB | 0 | 0.0% |
| **Total** | **3,778** | |

Note: 35 IMPL entries include 19 from recent performance optimizations (GAP-0243) plus 16 in test/CLI/build files.

## CI Enforcement Status

| Gate | Status | Evidence |
|------|--------|----------|
| Unit tests block merge | ✅ Enforced | `.gitlab-ci.yml:259` - `allow_failure: false` |
| ReleaseSafe tests | ✅ Enforced | `.gitlab-ci.yml:288` - `allow_failure: false` |
| GQL compliance tests | ✅ Enforced | `.gitlab-ci.yml:336` - `allow_failure: false` |
| Comprehensive tests | ✅ Enforced | `.gitlab-ci.yml:381` - `allow_failure: false` |
| CANARY lint | ✅ Enforced | `.gitlab-ci.yml:140` - `allow_failure: false` |
| Canaryscan verify | ✅ Enforced | `.gitlab-ci.yml:172` - `allow_failure: false` |
| Conformance sync | ✅ Enforced | `.gitlab-ci.yml:242` - `allow_failure: false` |
| **Performance benchmarks** | ❌ **Not enforced** | **GAP-0244** - No benchmark CI job |

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
- **Benchmarks**: `tests/benchmark_*.zig` (146 files) - inline variance checks, not CI-gated
- **CI Runner**: GitLab CI with custom Zig Docker image

### Commands

```bash
# Unit tests
zig build test --summary all

# GQL compliance
python3 scripts/test/extended_test_runner.py geode_gql_compliance

# Comprehensive
make geodetestlab-comprehensive

# Bug regression tests
python3 scripts/test/extended_test_runner.py gap_0242
```

---

**Resolved gaps have been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).**

Previous resolutions (January 25, 2026):

- GAP-0225 through GAP-0242: All resolved with tests and GitLab issues closed
