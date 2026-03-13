# Gap Analysis

Last updated: 2026-03-13
Audited by: Claude Opus 4.6 (requirements-to-code gap analysis)

## Summary

- **Total open gaps:** 4
- **Critical:** 1
- **High:** 1
- **Medium:** 2
- **Blocked (external dependency):** 3 (GAP-0246, GAP-0247, GAP-0256)
- **Closed this session (2026-03-13):** GAP-0248, GAP-0249, GAP-0250, GAP-0251, GAP-0252, GAP-0253

GitLab is the source of truth for all gap status and tracking. This document contains **OPEN gaps only**. Resolved items are in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Gaps

### ~~GAP-0249~~: Concurrent MERGE data race — **CLOSED / Already Fixed**

- **GitLab issue:** [#542](https://gitlab.com/devnw/codepros/geode/geode/-/issues/542)
- **Resolution (2026-03-13):** Already fixed. `isMutatingStatement()` in `quic_connection_handler.zig` detects `.Merge => true` and acquires exclusive write lock. Verified by code inspection. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### ~~GAP-0250~~: FLE plaintext fallback — **CLOSED / Already Fixed**

- **GitLab issue:** [#543](https://gitlab.com/devnw/codepros/geode/geode/-/issues/543)
- **Resolution (2026-03-13):** Already fixed. `fle_hooks.zig` returns `FLEHookError.EncryptionRequired` on encryption failure (fail-secure). Test documentation updated in `test_fle_enforcement.zig`. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### GAP-0256: Unsigned release artifacts and disabled SBOM generation

- **GitLab issue:** [#483](https://gitlab.com/devnw/codepros/geode/geode/-/issues/483)
- **Category:** Security / CI-CD
- **Severity:** Critical
- **Requirement source:** SLSA supply chain security, OWASP A08
- **Current state (evidence):**
  - `.goreleaser.yaml:723-732` — signing section is commented out ("Signs (optional - enable for production)")
  - No cosign integration for binary or container image signing
  - SBOM generation disabled
  - GPG signing only enabled for APT packages, not release binaries
- **Why this is a gap:** Release binaries cannot be verified for integrity or provenance. No software bill of materials for dependency auditing.
- **Impact/Risk:** Supply chain attack surface — users cannot verify artifact authenticity. Regulatory compliance gap for enterprise customers.
- **Recommended fix:** Enable cosign signing in GoReleaser; add SBOM generation (syft/cyclonedx); sign container images.
- **Acceptance criteria:** All release binaries signed; SBOM generated per release; container images signed. **Status: Blocked** — requires org-level signing infrastructure.

### ~~GAP-0248~~: mTLS X.509 parsing — **CLOSED / Implemented**

- **GitLab issue:** [#399](https://gitlab.com/devnw/codepros/geode/geode/-/issues/399)
- **Resolution (2026-03-13):** Full ASN.1/DER X.509 parser implemented in `src/security/mtls_provider.zig` (~300 lines). `extractIdentity()` now parses: serial_number, subject_cn, subject_dn, issuer_dn, not_before, not_after, san_dns, san_email, san_uri. 7 unit tests added and passing. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### GAP-0255: gRPC transport missing savepoint support and 7 message types vs QUIC

- **GitLab issue:** [#548](https://gitlab.com/devnw/codepros/geode/geode/-/issues/548)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** Transport parity requirement; [#515](https://gitlab.com/devnw/codepros/geode/geode/-/issues/515)
- **Current state (evidence):**
  - `src/transport/grpc_server.zig:1510-1512` — `handleSavepoint()` returns `success: false`
  - `src/transport/grpc_server.zig:1516-1518` — `handleRollbackTo()` returns `success: false`
  - Issue #515 documents 7 missing message types in gRPC vs QUIC handler
- **Why this is a gap:** gRPC clients get degraded functionality compared to QUIC. Savepoints required for complex transaction workflows.
- **Impact/Risk:** Clients using gRPC transport cannot use savepoints or 7 other operations available via QUIC.
- **Recommended fix:** Implement savepoint/rollback-to in gRPC handler; address missing message types per #515.
- **Acceptance criteria:** gRPC handler supports all message types that QUIC handler supports.

### ~~GAP-0251~~: Code coverage instrumentation — **CLOSED / Implemented**

- **GitLab issue:** [#544](https://gitlab.com/devnw/codepros/geode/geode/-/issues/544)
- **Resolution (2026-03-13):** Added `test-code-coverage` CI job in `.gitlab-ci.yml` using kcov for Zig DWARF instrumentation. Job collects coverage reports as artifacts with `coverage_regex`. Set to `allow_failure: true` initially to avoid blocking while baselines are established.

### ~~GAP-0252~~: CI benchmarks optional for releases — **CLOSED / Implemented**

- **GitLab issue:** [#545](https://gitlab.com/devnw/codepros/geode/geode/-/issues/545)
- **Resolution (2026-03-13):** Changed `build-release` benchmark dependency from `optional: true` to `optional: false` in `.gitlab-ci.yml`. Release builds now require benchmark completion.

### GAP-0246: LDAP/Active Directory authentication documented but not implemented

- **GitLab issue:** [#397](https://gitlab.com/devnw/codepros/geode/geode/-/issues/397)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** [REQ-DOC-USER_AUTH](https://gitlab.com/devnw/codepros/geode/geode/-/issues/289) — docs/USER_AUTH.md line 474
- **Current state (evidence):**
  - Zero occurrences of "LDAP", "ldap", "ActiveDirectory" in `src/security/`
  - `docs/USER_AUTH.md:474` — documented as planned for Q2 2026
- **Why this is a gap:** Enterprise auth method documented in requirements but no implementation exists.
- **Impact/Risk:** Enterprise customers expecting LDAP/AD integration cannot use it.
- **Recommended fix:** Implement LDAP bind-and-search client; DN template; group-to-role mapping.
- **Acceptance criteria:** LDAP/AD authentication functional with configurable DN template and role mapping. **Status: Blocked** — requires dedicated auth provider sprint.

### GAP-0247: OAuth2/OIDC authentication documented but not implemented

- **GitLab issue:** [#398](https://gitlab.com/devnw/codepros/geode/geode/-/issues/398)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** [REQ-DOC-USER_AUTH](https://gitlab.com/devnw/codepros/geode/geode/-/issues/289) — docs/USER_AUTH.md line 475
- **Current state (evidence):**
  - Zero occurrences of "OAuth", "oauth", "OIDC", "oidc" in `src/security/`
  - `docs/USER_AUTH.md:475` — documented as planned for Q3 2026
- **Why this is a gap:** Modern auth standard documented but not implemented.
- **Impact/Risk:** Cannot integrate with enterprise identity providers (Okta, Auth0, Azure AD, etc.).
- **Recommended fix:** Implement token introspection endpoint; OIDC discovery; claims-to-role mapping.
- **Acceptance criteria:** OAuth2/OIDC authentication functional with configurable provider. **Status: Blocked** — requires dedicated auth provider sprint.

### ~~GAP-0253~~: Cryptographic signature algorithms — **CLOSED / Implemented**

- **GitLab issue:** [#546](https://gitlab.com/devnw/codepros/geode/geode/-/issues/546)
- **Resolution (2026-03-13):** ECDSA P256 and P384 sign/verify implemented in `src/types/cryptographic.zig` using `std.crypto.sign.ecdsa.EcdsaP256Sha256` and `EcdsaP384Sha384`. Key generation, signing, and verification all functional. RSA PSS explicitly deferred (Zig stdlib limitation documented). Unit tests added and passing. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

---

## Additional Open Bugs (tracked separately, not gap-analysis items)

These are open bugs that may relate to requirement violations but are tracked as regular issues:

| Issue | Title | Severity | Relates to |
|-------|-------|----------|------------|
| [#540](https://gitlab.com/devnw/codepros/geode/geode/-/issues/540) | Excessive CPU usage: geode idles at ~60% CPU | High | REQ-0009 Performance |
| [#539](https://gitlab.com/devnw/codepros/geode/geode/-/issues/539) | WAL grows unboundedly across restarts | High | REQ-0004 Storage |
| [#538](https://gitlab.com/devnw/codepros/geode/geode/-/issues/538) | OOM on large-graph ingest | High | REQ-0004 Storage |
| [#541](https://gitlab.com/devnw/codepros/geode/geode/-/issues/541) | Weird behavior with password reset | Medium | REQ-0005 Security |
| [#515](https://gitlab.com/devnw/codepros/geode/geode/-/issues/515) | gRPC missing 7 message types | High | Transport parity |
| [#514](https://gitlab.com/devnw/codepros/geode/geode/-/issues/514) | gRPC 22023 error on rapid writes (aarch64) | Medium | REQ-0008 Platform |
| [#479](https://gitlab.com/devnw/codepros/geode/geode/-/issues/479) | gRPC segfault on aarch64 rapid writes | High | REQ-0008 Platform |

---

## Notes on Resolved Items

- **GAP-0245 (API Keys):** Closed 2026-03-13 — full implementation verified in `src/security/api_keys.zig`
- **GAP-0248 (mTLS X.509):** Closed 2026-03-13 — ASN.1/DER parser implemented in `mtls_provider.zig`, 7 unit tests
- **GAP-0249 (MERGE locking):** Closed 2026-03-13 — already fixed, `isMutatingStatement` detects Merge and acquires exclusive lock
- **GAP-0250 (FLE fail-secure):** Closed 2026-03-13 — already fixed, `fle_hooks.zig` returns `EncryptionRequired` error
- **GAP-0251 (Coverage CI):** Closed 2026-03-13 — kcov coverage job added to `.gitlab-ci.yml`
- **GAP-0252 (Benchmarks required):** Closed 2026-03-13 — release build benchmark dependency set to `optional: false`
- **GAP-0253 (ECDSA):** Closed 2026-03-13 — P256/P384 sign/verify implemented in `cryptographic.zig`
- **60 security findings** from previous audit: 47 closed/implemented, 6 closed (won't-do by policy), all resolved
- See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) for full resolved history
