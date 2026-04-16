# Security Gap Analysis

Last updated: 2026-04-16
Scope (Phase 3, 2026-04-16): `src/security/rls_core.zig`, `src/security/audit.zig`, `src/cli/geode_audit_verify.zig`, `src/security/vault_kms_provider.zig`, `src/security/geode_auth_lib.zig`, `src/distributed/*`, `src/execution/aggregation_evaluation.zig`, `src/monitoring/metrics_server.zig`, `config/nginx/conf.d/geode.conf`, `src/cli/main.zig`, `src/cli/cli_dispatcher.zig`
Scope (Original, 2026-04-10): `src/migration/mod.zig`, `src/cli/backup_cli.zig`
Audited by: Claude Opus 4.6 / Opus 4.7 (adversarial security review)

---

## Phase 3 Audit (2026-04-16) — Core Security Engines

### Summary

- **Total new findings:** 10 (3 confidential — active-exploit potential)
- **Critical (Risk >= 24):** 3 — SEC-RLS-01 (30), SEC-AUD-01 (24), SEC-INFRA-01 (24) — **all 3 CLOSED 2026-04-16**
- **High (Risk 12-20):** 3 — SEC-RLS-02 (16), SEC-AUD-02 (12), SEC-KMS-01 (12), SEC-INFRA-03 (15) — **SEC-RLS-02, SEC-AUD-02, SEC-KMS-01 CLOSED 2026-04-16**
- **Medium (Risk 7-10):** 2 — SEC-MTI-01 (10), SEC-AUTH-01 (9) — **SEC-MTI-01 CLOSED 2026-04-16**
- **Low (Risk <=6):** 2 — SEC-MON-01 via #674 (6), SEC-CLI-01 (6), SEC-INFRA-02 (2)
- **Open:** 3 (SEC-INFRA-03 #743, SEC-AUTH-01 #742, SEC-CLI-01 #744, SEC-MON-01 #674, SEC-INFRA-02 #740 deferred to Wave 5/6; see per-row status below)
- **Closed (2026-04-16):** 7 (SEC-RLS-01 #723, SEC-RLS-02 #732, SEC-AUD-01 #727, SEC-AUD-02 #738, SEC-INFRA-01 #737, SEC-MTI-01 #739, SEC-KMS-01 #741)
- **Confidential:** 3 (#723, #727, #732) — all 3 CLOSED with confidentiality-preserving wording

### Top 5 Risks (Phase 3, Open)

| Rank | Risk | ID | Finding | Issue |
|------|------|-----|---------|-------|
| 1 | 30 | SEC-RLS-01 | RLS VM stack OOB — arbitrary write in auth fast-path | [#723](https://gitlab.com/devnw/codepros/geode/geode/-/issues/723) (confidential) |
| 2 | 24 | SEC-AUD-01 | Audit verifier skips seq_no — chain splice undetectable | [#727](https://gitlab.com/devnw/codepros/geode/geode/-/issues/727) (confidential) |
| 3 | 24 | SEC-INFRA-01 | GEODE_CLUSTER_INSECURE works in release — cluster MITM | [#737](https://gitlab.com/devnw/codepros/geode/geode/-/issues/737) |
| 4 | 16 | SEC-RLS-02 | RLS raw-string fallthrough — `raw=\"1\"` bypasses every deny | [#732](https://gitlab.com/devnw/codepros/geode/geode/-/issues/732) (confidential) |
| 5 | 15 | SEC-INFRA-03 | Cluster bearer token — single shared secret, no rotation | [#743](https://gitlab.com/devnw/codepros/geode/geode/-/issues/743) |

### Critical Attack Chain (Phase 3)

`GEODE_CLUSTER_INSECURE=1` set via `/proc/1/environ` leak or supervisor misconfig (SEC-INFRA-01) → QUIC TLS peer verification off across federation/Raft → on-path attacker exfiltrates `GEODE_CLUSTER_TOKEN` from first federation HELLO (SEC-INFRA-03) → attacker forges peer cert → Raft leader election flipped → insider reads `audit.jsonl.key` (SEC-AUD-02, colocated) → forges signed sub-chain with seq_no gap → verifier returns clean \"OK\" (SEC-AUD-01) → forensic timeline silently lossy. **Effect: full cluster compromise with deniable tampering.**

Separately, once the GQL->bytecode parser lands (GAP-0510 follow-up), SEC-RLS-01 (stack OOB) becomes a pre-auth arbitrary-write primitive triggered by any admin `CREATE POLICY` — today constrained to manually-pinned `CompiledExpression` paths (test shims, migrations).

### Stack-Ranked New Findings Table

| Rank | ID | Severity | Risk | Finding | Component | CWE/OWASP | Evidence (file:line) | Issue | Status |
|------|-----|----------|------|---------|-----------|-----------|----------------------|-------|--------|
| 1 | SEC-RLS-01 | Critical | 30 | RLS VM stack OOB write | security/rls_core | CWE-787 / A04:2021 | rls_core.zig:642-848 | [#723](https://gitlab.com/devnw/codepros/geode/geode/-/issues/723) confidential | **Closed 2026-04-16** (`4b5fc453` — stack bounds + opcode validator; 6 regression tests in `tests/test_rls_vm_bounds.zig`) |
| 2 | SEC-AUD-01 | Critical | 24 | Audit verifier skips seq_no | cli/geode_audit_verify | CWE-345 / A09:2021 | geode_audit_verify.zig:60-128 | [#727](https://gitlab.com/devnw/codepros/geode/geode/-/issues/727) confidential | **Closed 2026-04-16** (`a2d168bc` — seq_no monotonicity assertion + error; 2 regression tests in `tests/test_audit_verify_seq_no.zig`) |
| 3 | SEC-INFRA-01 | Critical | 24 | GEODE_CLUSTER_INSECURE in release | distributed (x6) | CWE-295 / A02:2021 | cluster_auth, federation, raft_consensus, twophase, query_transport, cluster | [#737](https://gitlab.com/devnw/codepros/geode/geode/-/issues/737) | **Closed 2026-04-16** (`40ac14bc` — Debug-only gate + release refusal + counter metric `geode_cluster_insecure_refused_total`; 2 regression tests in `tests/test_cluster_insecure_gate.zig`) |
| 4 | SEC-RLS-02 | High | 16 | RLS raw-string interpreter fallthrough | security/rls_core | CWE-94 / A03:2021 | rls_core.zig:631, 1441-1532 | [#732](https://gitlab.com/devnw/codepros/geode/geode/-/issues/732) confidential | **Closed 2026-04-16** (`b5487d04` — fail-closed by default; `-Dallow-rls-raw-interp=false` default; 1 regression test) |
| 5 | SEC-INFRA-03 | Medium | 15 | Cluster token single shared bearer | distributed/cluster_auth | CWE-798 / A07:2021 | cluster_auth.zig:17-56 | [#743](https://gitlab.com/devnw/codepros/geode/geode/-/issues/743) | Open (Wave 5 — deferred; per-node mTLS + SPIFFE/SVID rotation scaffold) |
| 6 | SEC-AUD-02 | High | 12 | audit.jsonl + signing key colocated | security/audit | CWE-312, CWE-798 / A09:2021 | audit.zig:343-345; commit c8b7c44f | [#738](https://gitlab.com/devnw/codepros/geode/geode/-/issues/738) | **Closed 2026-04-16** (`e751ed0c` — `git rm --cached audit.jsonl`; `.gitignore` covers future checkins) |
| 7 | SEC-KMS-01 | Medium | 12 | Vault KMS empty env_map | security/vault_kms_provider | CWE-88, CWE-306 / A02:2021 | vault_kms_provider.zig:163,167,251,270 | [#741](https://gitlab.com/devnw/codepros/geode/geode/-/issues/741) | **Closed 2026-04-16** (`f9daea3a` — `getEnvMap` inherit + `validateVaultPath` allowlist; 4 inline regression tests) |
| 8 | SEC-MTI-01 | Medium | 10 | Aggregation dead-code no tenant filter | execution/aggregation_evaluation | CWE-863 / A01:2021 | aggregation_evaluation.zig:629-692 | [#739](https://gitlab.com/devnw/codepros/geode/geode/-/issues/739) | **Closed 2026-04-16** (`fa34d617` — deleted 419 LOC of dead unsafe evaluators + dropped re-exports) |
| 9 | SEC-AUTH-01 | Medium | 9 | Blake2b legacy: no password_reset_required | security/geode_auth_lib | CWE-521, CWE-916 / A07:2021 | geode_auth_lib.zig:1068-1092 | [#742](https://gitlab.com/devnw/codepros/geode/geode/-/issues/742) | Open (Wave 6 — partial-do; full migration is Won't-Do per vendor ownership; see Won't-Do section) |
| 10 | SEC-CLI-01 | Low | 6 | --insecure-tls-skip-verify in release | cli/main, cli_dispatcher | CWE-295 / A02:2021 | main.zig:1054, cli_dispatcher.zig:490 | [#744](https://gitlab.com/devnw/codepros/geode/geode/-/issues/744) | Open (Wave 3 — deferred; low priority) |
| 11 | SEC-MON-01 | Low | 6 | Metrics endpoint no auth (timing oracle at re-impl) | monitoring/metrics_server | CWE-306, CWE-200 / A07 | metrics_server.zig:47-97, 102 | [#674](https://gitlab.com/devnw/codepros/geode/geode/-/issues/674) (existing) | Open (Phase 3 comment; deferred) |
| 12 | SEC-INFRA-02 | Medium | 2 | nginx h2c residual on Grafana vhost | config/nginx | CWE-444 / A10:2021 | geode.conf:20-29 | [#740](https://gitlab.com/devnw/codepros/geode/geode/-/issues/740) | Open (Wave 6 — deferred; low priority) |

### Findings by Area (Phase 3)

**Row-Level Security:**

- SEC-RLS-01 (#723, confidential, Risk 30) — VM stack OOB write
- SEC-RLS-02 (#732, confidential, Risk 16) — raw-string fallthrough
- #707 (existing) — RLS value bridge not wired into match loop

**Audit Log Integrity:**

- SEC-AUD-01 (#727, confidential, Risk 24) — verifier skips seq_no
- SEC-AUD-02 (#738, Risk 12) — signing key colocated with log

**Cluster / Distributed:**

- SEC-INFRA-01 (#737, Risk 24) — insecure mode cluster-wide
- SEC-INFRA-03 (#743, Risk 15) — shared bearer token, no rotation

**KMS / Cryptography:**

- SEC-KMS-01 (#741, Risk 12) — Vault KMS empty env + path injection
- SEC-AUTH-01 (#742, Risk 9) — Blake2b legacy reset flag

**Multi-Tenant Isolation:**

- SEC-MTI-01 (#739, Risk 10) — aggregation dead-code revival risk

**Operations / Hardening:**

- SEC-CLI-01 (#744, Risk 6) — insecure TLS flag in release
- SEC-MON-01 (#674, Risk 6) — metrics auth (updated with Phase 3 context)
- SEC-INFRA-02 (#740, Risk 2) — nginx h2c residual

### Roadmap (Phase 3)

**Quick Wins (< 1 day each):**

- SEC-AUD-01: add `seq_no` assertion in verifier loop (~10 LoC).
- SEC-AUD-02: `git rm --cached audit.jsonl`; update `.gitignore`; add pre-commit + CI guard.
- SEC-MTI-01: replace aggregation dead-code bodies with `@compileError` or delete.
- SEC-CLI-01: add `builtin.mode == .Debug` gate on `--insecure-tls-skip-verify`.
- SEC-AUTH-01: set `password_reset_required = true` in Blake2b success path.

**Medium (1-5 days each):**

- SEC-RLS-01: add bounds checks on every push/pop opcode; fuzz harness.
- SEC-RLS-02: reject `raw != null and compiled == null` at load; force compile.
- SEC-INFRA-01: Debug-mode gate across 6 modules; startup banner; Prometheus gauge; audit event.
- SEC-KMS-01: inherit env with `std.process.getEnvMap`; validate `self.key_path`; startup self-test.
- SEC-INFRA-02: remove h2c headers from Grafana `location /`; scope to `/api/live/ws`.

**Strategic (> 5 days):**

- SEC-INFRA-03: per-node mTLS cert pinning, token → SPIFFE/SVID; rotation command.
- SEC-MON-01: re-implement metrics endpoint with bearer/mTLS auth.

### Immediate Actions

No findings require immediate credential rotation. Priority actions:

1. **7-day SLA:** SEC-RLS-01 (#723), SEC-AUD-01 (#727), SEC-INFRA-01 (#737) — all three are on the Critical path and block the GAP-0510 RLS-engine landing and any production multi-node deployment.
2. **30-day SLA:** SEC-RLS-02 (#732), SEC-AUD-02 (#738) — chain-breakers for SEC-AUD-01 and SEC-RLS-01.
3. **Git hygiene:** run `git rm --cached audit.jsonl` and sweep `.gitignore` before next CI tarball rev.

### Blockers and Unknowns

- **Supply-chain CVE re-scan:** 3 outstanding Trivy CVEs (2 HIGH, 1 MEDIUM) flagged in audit brief but not re-run this phase. Re-run `trivy image` against published container; track in a SEC-SCN-01 placeholder if confirmed.
- **QUIC vendor audit:** TLS/QUIC cryptographic defaults not reviewed in Phase 3 — scope is vendored `zig-quic@2ca4f8db`. Pending vendor audit, assume TLS 1.3 AEAD is correct.
- **24 git-pinned Zig modules in `build.zig.zon`** — no lockfile signing; a malicious commit to any of auth/fle/audit/wal/raft/quic/graph_storage lands on next `zig build`. Supply-chain hardening is strategic.

---

## Migration Engine Audit (2026-04-10 — original scope)

## Summary

- **Total findings:** 24 (13 prior + 11 new from re-audit)
- **Critical:** 0
- **High:** 5 -- 3 closed, 2 won't do, 0 open
- **Medium:** 9 -- 6 closed, 2 won't do, 1 open (SEC-MIG-02)
- **Low:** 10 -- 8 closed, 2 won't do, 0 open
- **Closed / Implemented:** 16 (7 prior + 5 closed 2026-04-05 + 4 closed 2026-04-10)
- **Won't Do:** 5 (unsigned ledger, weak checksum, GQL injection, missing authz, password exposure)
- **Open:** 1 (SEC-MIG-02)
- **Confidential issues:** 2 (#592, #598)

### Top 5 Risks (Overall)

| Rank | Risk Score | Finding | Status |
|------|-----------|---------|--------|
| 1 | 64 | Path traversal in applyUpMigrations (CWE-22) | Closed |
| 2 | 64 | Unsigned ledger file -- full state forgery (CWE-345) | Won't Do |
| 3 | 64 | GQL injection via migration file content (CWE-94) | Won't Do |
| 4 | 48 | JSON injection via unescaped row.name (CWE-74/116) | Closed |
| 5 | 40 | No cryptographic signing of migration files (CWE-345) | **Open (NEW)** |

### Top 5 Risks (Open Only)

| Rank | Risk Score | Finding | ID |
|------|-----------|---------|-----|
| 1 | 32 | No CI pipeline migration guard (CWE-829) | SEC-MIG-02 |

### Critical Attack Chain

Ledger tampering (#573) -> injected name with `../` -> `applyDownMigrations` constructs `{name}.down.gql` -> `joinPath` joins unsanitized name (#572) -> `readFileAlloc` reads arbitrary file (8MB) -> content passed to `executor.execFn` = arbitrary GQL injection (#598). Combined effect: **full database compromise from filesystem write access to migrations dir**.

**Deployment model:** CLI tool requiring local shell access. Risk is significantly amplified in CI/CD pipelines and shared development environments where the migrations directory is writable by build processes.

**New attack surface (re-audit):** Unsigned migration files (SEC-MIG-01) combined with no CI guard (SEC-MIG-02) means a compromised CI runner or malicious MR can inject arbitrary GQL that executes without review. Cross-process lock gap (SEC-MIG-04) enables concurrent migration execution in multi-runner CI environments.

---

## Prior Findings (Original Audit)

### Stack-Ranked Prior Findings Table

| Rank | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence (file:line) | Issue URL | Fix | Owner | Due | Status |
|------|----------|-----------|---------|-----------|-----------|---------------------|-----------|-----|-------|-----|--------|
| 1 | HIGH | 64 | Path traversal in applyUpMigrations | migration | CWE-22 / A01:2021 | mod.zig:273-274, 346 | [#572](https://gitlab.com/devnw/codepros/geode/geode/-/issues/572) | GAP-0285: name sanitization rejects `../`, `/`, `\`. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 2 | HIGH | 64 | Unsigned ledger file | migration | CWE-345 / A08:2021 | mod.zig:165-200, 235-255 | [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573) | GAP-0286: too invasive, needs separate sprint with migration path design | migration | -- | Won't Do |
| 3 | HIGH | 64 | GQL injection via migration file content | migration | CWE-94 / A03:2021 | mod.zig:348-351 | [#598](https://gitlab.com/devnw/codepros/geode/geode/-/issues/598) | SEC-598: needs DDL sandbox architecture | migration | -- | Won't Do |
| 4 | HIGH | 48 | JSON injection via unescaped row.name | migration | CWE-74, CWE-116 / A03:2021 | mod.zig:214-215 | [#592](https://gitlab.com/devnw/codepros/geode/geode/-/issues/592) | GAP-0287: std.json.stringify. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 5 | MEDIUM | 36 | TOCTOU race in global lock | migration | CWE-362, CWE-367 / A04:2021 | mod.zig:279-311 | [#606](https://gitlab.com/devnw/codepros/geode/geode/-/issues/606) | GAP-0293: std.Thread.Mutex. Commit 0d39cd15. | migration | -- | Closed / Implemented |
| 6 | MEDIUM | 36 | CLI path traversal in cmdMigrateCreate | cli | CWE-22 / A01:2021 | backup_cli.zig:1309-1351 | [#614](https://gitlab.com/devnw/codepros/geode/geode/-/issues/614) | GAP-0301: name sanitization. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 7 | MEDIUM | 36 | No authorization enforcement | migration | CWE-862 / A01:2021 | mod.zig (entire module) | [#617](https://gitlab.com/devnw/codepros/geode/geode/-/issues/617) | GAP-0300: needs architectural decision on auth boundary | migration | -- | Won't Do |
| 8 | MEDIUM | 24 | Integer overflow in statusReport version parsing | migration | CWE-190 / A04:2021 | mod.zig:449-452 | [#602](https://gitlab.com/devnw/codepros/geode/geode/-/issues/602) | GAP-0292: shared parseVersion with overflow guard. Commit c49dc110. | migration | -- | Closed / Implemented |
| 9 | MEDIUM | 24 | Weak checksum (28-bit FNV-1a prefix) | migration | CWE-328 / A02:2021 | mod.zig:110-127, 534 | [#612](https://gitlab.com/devnw/codepros/geode/geode/-/issues/612) | GAP-0294: breaking change, needs versioned ledger format | migration | -- | Won't Do |
| 10 | LOW | 16 | Resume slots silent overwrite + undefined memory | migration | CWE-908 | mod.zig:603-614 | [#620](https://gitlab.com/devnw/codepros/geode/geode/-/issues/620) | GAP-0289/0303: alloc.dupe + error on full. Commit 7c545694. | migration | -- | Closed / Implemented |
| 11 | LOW | 16 | --password visible in process listing | cli | CWE-214 / A07:2021 | backup_cli.zig:1186-1192 | [#627](https://gitlab.com/devnw/codepros/geode/geode/-/issues/627) | SEC-627: CLI backlog item | migration | -- | Won't Do |
| 12 | LOW | 12 | Ledger use_last enables stealthy field override | migration | CWE-345 / A08:2021 | mod.zig:178 | [#622](https://gitlab.com/devnw/codepros/geode/geode/-/issues/622) | SEC-622: parse option changed to error. Commit f64bf2c6. | migration | -- | Closed / Implemented |
| 13 | LOW | 8 | Global policy_mode unsynchronized | migration | CWE-362 | mod.zig:491 | [#625](https://gitlab.com/devnw/codepros/geode/geode/-/issues/625) | GAP-0302: std.atomic.Value. Commit 0d39cd15. | migration | -- | Closed / Implemented |

### Verification Summary (Re-Audit)

All 7 prior fixes verified intact in current codebase. All 5 Won't Do items confirmed as still applicable with documented rationale.

---

## New Findings (Re-Audit: 2026-04-01)

### Stack-Ranked New Findings Table

| Rank | ID | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence (file:line) | Fix Guidance | Owner | SLA | Status |
|------|-----|----------|-----------|---------|-----------|-----------|---------------------|--------------|-------|-----|--------|
| 1 | SEC-MIG-01 | HIGH | 40 | No cryptographic signing of migration files -- executed verbatim from filesystem | migration | CWE-345 / A08:2021 | mod.zig:415-418 | HMAC-SHA256 signing with `.sig` sidecar files; `verifyMigrationSignature` before execution; `--allow-unsigned` escape hatch; constant-time comparison; `geode migrate sign` CLI command. 15 new tests. | migration | -- | Closed (2026-04-10) |
| 2 | SEC-MIG-03 | MEDIUM | 36 | `migrate status`/`create` have zero authentication -- local filesystem only | cli | CWE-306 / A07:2021 | backup_cli.zig:1052, 1283 | Require HMAC key for CLI migration commands | migration | -- | Closed (2026-04-10) |
| 3 | SEC-MIG-04 | MEDIUM | 36 | In-process lock provides no cross-process protection | migration | CWE-362, CWE-667 / A04:2021 | mod.zig:329-373 | Added FileLock with flock() on `.migration_lock` file for cross-process safety | migration | -- | Closed (2026-04-10) |
| 4 | SEC-MIG-02 | MEDIUM | 32 | No CI pipeline migration guard -- .gql files not reviewed/validated by CI | ci | CWE-829 / A08:2021 | .gitlab-ci.yml | Add CI job to lint/validate .gql migration files; require approval for changes | migration | 90 days | Open |
| 5 | SEC-MIG-05 | MEDIUM | 24 | Drift evasion via FNV-1a collision + unsigned ledger | migration | CWE-328 / A02:2021 | mod.zig:124-160 | Added SHA-256 content hash (content_sha256 field); full exact match; backwards-compatible with FNV-1a prefix for legacy entries | migration | -- | Closed (2026-04-10) |
| 6 | SEC-MIG-10 | LOW | 24 | `--dir` accepts arbitrary paths without validation | cli | CWE-22 / A01:2021 | backup_cli.zig:1069, 1141, 1303 | Added isPathSafe validation rejecting `..` components in `--dir` path | migration | -- | Closed / Implemented (2026-04-05) |
| 7 | SEC-MIG-06 | LOW | 24 | No file permissions set on ledger/migration files (default umask) | migration | CWE-732 / A01:2021 | mod.zig:286 | Set `0o600` permissions on ledger and migration files after creation | migration | -- | Closed / Implemented (2026-04-05) |
| 8 | SEC-MIG-11 | LOW | 24 | Password visible in process listing (duplicate of #627 scope, new path) | cli | CWE-214 / A07:2021 | backup_cli.zig:1186-1192 | Added GEODE_BACKUP_PASSWORD env var support; deprecates --password flag | migration | -- | Closed / Implemented (2026-04-05) |
| 9 | SEC-MIG-07 | LOW | 16 | Predictable temp file name (ms timestamp) | migration | CWE-377 / A01:2021 | mod.zig:282 | Replaced ms timestamp with crypto.random suffix for temp file naming | migration | -- | Closed / Implemented (2026-04-05) |
| 10 | SEC-MIG-08 | LOW | 8 | Resume token memory leak (8 slots max) | migration | CWE-401 / A04:2021 | mod.zig:700-713 | Added evictCompletedSlots() — completed (done=true) tokens are freed and slots reclaimed when full | migration | -- | Closed (2026-04-10) |
| 11 | SEC-MIG-09 | LOW | 4 | CLI version counter overflow in cmdMigrateCreate | cli | CWE-190 / A04:2021 | backup_cli.zig:1342-1347 | Added saturating arithmetic for version counter increment | migration | -- | Closed / Implemented (2026-04-05) |

### New Finding Details

#### SEC-MIG-01: No Cryptographic Signing of Migration Files

- **Severity:** HIGH | **Risk Score:** 40 (Impact: 5 x Likelihood: 2 x 4)
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity) | **OWASP:** A08:2021 Software and Data Integrity Failures
- **Exploit surface:** Local filesystem / CI pipeline
- **Summary:** Migration `.gql` files are read from disk and executed verbatim by the migration engine with no integrity verification. Any process with write access to the migrations directory can inject arbitrary GQL.
- **Evidence:** `mod.zig:415-418` -- `readFileAlloc` followed by direct execution without signature check.
- **Attack scenario:** Attacker gains write access to migrations directory (compromised CI runner, shared dev environment, supply chain attack on dependency that writes to project root). Injects malicious `.gql` file. Next `migrate up` executes it with full database privileges.
- **Likelihood:** Score 2 -- requires filesystem write access to migrations directory. Elevated in CI/CD where build processes have write access.
- **Fix guidance:** Implement Ed25519 or HMAC-SHA256 signing of migration files. Store signatures in a `.sig` sidecar file or in the ledger. Verify before execution. Reject unsigned migrations by default with `--allow-unsigned` escape hatch.
- **Acceptance criteria:** (1) Unsigned migration files are rejected by default. (2) Tampered migration files (modified after signing) are rejected. (3) `--allow-unsigned` flag exists for development use.
- **Confidence:** `confidence::confirmed` -- code path verified.

#### SEC-MIG-02: No CI Pipeline Migration Guard

- **Severity:** MEDIUM | **Risk Score:** 32 (Impact: 4 x Likelihood: 2 x 4)
- **CWE:** CWE-829 (Inclusion of Functionality from Untrusted Control Sphere) | **OWASP:** A08:2021
- **Exploit surface:** CI/CD pipeline
- **Summary:** `.gql` migration files are not linted, validated, or gated by CI. Any MR adding or modifying migration files is merged without automated review.
- **Evidence:** `.gitlab-ci.yml` -- no job validates migration file content or requires approval for changes to `migrations/` directory.
- **Attack scenario:** Malicious or compromised contributor adds a migration file containing destructive GQL (DROP, data exfiltration). MR is merged without CI flagging the migration content.
- **Likelihood:** Score 2 -- requires MR access; mitigated by code review but not by automation.
- **Fix guidance:** Add a CI job that (1) parses migration files for DDL-only statements, (2) flags non-DDL operations, (3) requires CODEOWNERS approval for `migrations/**/*.gql` changes.
- **Acceptance criteria:** (1) CI job runs on all MRs touching `migrations/`. (2) Non-DDL statements are flagged. (3) CODEOWNERS rule covers migration directory.
- **Confidence:** `confidence::confirmed` -- CI config reviewed.

#### SEC-MIG-03: Migration CLI Commands Have Zero Authentication -- **CLOSED (2026-04-10)**

- **Severity:** MEDIUM | **Risk Score:** 36 (Impact: 3 x Likelihood: 3 x 4)
- **CWE:** CWE-306 (Missing Authentication for Critical Function) | **OWASP:** A07:2021 Identification and Authentication Failures
- **Exploit surface:** Local shell / CI pipeline
- **Summary:** `migrate status` and `migrate create` commands operate directly on the filesystem without any authentication. Any local user or CI process can enumerate migration state and create new migrations.
- **Evidence:** `backup_cli.zig:1052` (`cmdMigrateStatus`), `backup_cli.zig:1283` (`cmdMigrateCreate`) -- no auth checks.
- **Resolution:** Both commands now require the HMAC signing key (via `GEODE_MIGRATION_HMAC_KEY` env var or `.hmac_key` file) as proof of admin authorization. `migrate status` accepts `--allow-unauthenticated` for dev use. `migrate create` auto-signs the created migration file (accepts `--no-sign` for dev use). Unauthenticated calls exit with an error message.
- **Confidence:** `confidence::confirmed` -- code paths verified.

#### SEC-MIG-04: In-Process Lock Provides No Cross-Process Protection -- **CLOSED (2026-04-10)**

- **Severity:** MEDIUM | **Risk Score:** 36 (Impact: 3 x Likelihood: 3 x 4)
- **CWE:** CWE-362 (Concurrent Execution Using Shared Resource with Improper Synchronization), CWE-667 (Improper Locking) | **OWASP:** A04:2021
- **Exploit surface:** Multi-process deployment / CI pipeline
- **Summary:** The migration global lock uses `std.Thread.Mutex`, which only protects within a single process. Multiple Geode processes or CI runners can execute migrations concurrently, causing ledger corruption or partial application.
- **Evidence:** `mod.zig:329-373` -- mutex is process-local.
- **Resolution:** Added `FileLock` struct that uses `flock(LOCK_EX)` on a `.migration_lock` file in the migrations directory. Both `applyUpMigrations` and `applyDownMigration` acquire the file lock before the in-process mutex. The OS automatically releases the lock if the process crashes. The in-process mutex is retained for thread safety within the same process. 2 unit tests added.
- **Confidence:** `confidence::confirmed` -- mutex scope verified.

#### SEC-MIG-05: Drift Evasion via FNV-1a Collision + Unsigned Ledger -- **CLOSED (2026-04-10)**

- **Severity:** MEDIUM | **Risk Score:** 24 (Impact: 3 x Likelihood: 2 x 4)
- **CWE:** CWE-328 (Use of Weak Hash) | **OWASP:** A02:2021 Cryptographic Failures
- **Exploit surface:** Local filesystem
- **Summary:** FNV-1a hash used for drift detection is 28-bit truncated, making collisions computationally trivial. Combined with the unsigned ledger (#573), an attacker can replace migration file content while preserving the hash prefix.
- **Evidence:** `mod.zig:124-160` -- FNV-1a hash computation with `startsWith` matching on hex prefix.
- **Resolution:** Added `content_sha256` field to `StatusRow` — full 64-char SHA-256 hex of migration file content. `applyUpMigrations` stores SHA-256 alongside FNV-1a prefix. `computeFingerprint` uses SHA-256 when available, falling back to FNV-1a for legacy entries. `checksumValidate` accepts both 64-char (SHA-256 exact match) and 7-char (legacy FNV-1a prefix) manifests. Backwards-compatible: old ledgers with zero SHA-256 field continue to work. 5 new unit tests added.
- **Confidence:** `confidence::confirmed` -- hash algorithm and matching logic verified.

#### SEC-MIG-06: No File Permissions Set on Ledger/Migration Files -- **CLOSED (2026-04-05)**

- **Severity:** LOW | **Risk Score:** 24 (Impact: 2 x Likelihood: 3 x 4)
- **CWE:** CWE-732 (Incorrect Permission Assignment for Critical Resource) | **OWASP:** A01:2021
- **Exploit surface:** Shared filesystem
- **Summary:** Ledger and migration files are created with default umask permissions (often 0644 or 0666). Other local users can read migration content and ledger state.
- **Evidence:** `mod.zig:286` -- file creation without explicit permission mode.
- **Resolution:** Set `0o600` permissions on ledger files after creation.
- **Confidence:** `confidence::confirmed` -- file creation call verified.

#### SEC-MIG-07: Predictable Temp File Name -- **CLOSED (2026-04-05)**

- **Severity:** LOW | **Risk Score:** 16 (Impact: 2 x Likelihood: 2 x 4)
- **CWE:** CWE-377 (Insecure Temporary File) | **OWASP:** A01:2021
- **Exploit surface:** Local filesystem
- **Summary:** Temporary files use millisecond timestamp as suffix, making the name predictable. A local attacker can pre-create the file (symlink attack) to redirect writes.
- **Evidence:** `mod.zig:282` -- timestamp-based temp file naming.
- **Resolution:** Replaced millisecond timestamp with crypto.random suffix for temp file naming.
- **Confidence:** `confidence::confirmed` -- naming logic verified.

#### SEC-MIG-08: Resume Token Memory Leak -- **CLOSED (2026-04-10)**

- **Severity:** LOW | **Risk Score:** 8 (Impact: 1 x Likelihood: 2 x 4)
- **CWE:** CWE-401 (Missing Release of Memory after Effective Lifetime) | **OWASP:** A04:2021
- **Exploit surface:** Internal (long-running process)
- **Summary:** Resume tokens (8 slots max) are allocated but never freed during normal operation. In long-running processes, repeated migration attempts accumulate leaked token memory.
- **Evidence:** `mod.zig:700-713` -- token allocation without corresponding deallocation.
- **Resolution:** Added `evictCompletedSlots()` function called by `getOrInitResume` when all 8 slots are full. Completed (done=true) tokens have their heap memory freed and are compacted out of the array, making room for new tokens. The existing `resetResumeSlots()` still provides full manual cleanup. 2 new unit tests verify eviction of completed slots and preservation of active slots.
- **Confidence:** `confidence::confirmed` -- verified with unit tests under repeated migrate cycles.

#### SEC-MIG-09: CLI Version Counter Overflow -- **CLOSED (2026-04-05)**

- **Severity:** LOW | **Risk Score:** 4 (Impact: 1 x Likelihood: 1 x 4)
- **CWE:** CWE-190 (Integer Overflow or Wraparound) | **OWASP:** A04:2021
- **Exploit surface:** CLI (local)
- **Summary:** Version counter in `cmdMigrateCreate` can overflow if enough migrations are created. Overflow would cause version number collision or wrap to zero.
- **Evidence:** `backup_cli.zig:1342-1347` -- version increment without overflow check.
- **Resolution:** Added saturating arithmetic for version counter increment.
- **Confidence:** `confidence::suspected` -- theoretical; would require impractically large number of migrations in practice.

#### SEC-MIG-10: `--dir` Accepts Arbitrary Paths Without Validation -- **CLOSED (2026-04-05)**

- **Severity:** LOW | **Risk Score:** 24 (Impact: 3 x Likelihood: 2 x 4)
- **CWE:** CWE-22 (Improper Limitation of a Pathname to a Restricted Directory) | **OWASP:** A01:2021
- **Exploit surface:** CLI (local)
- **Summary:** The `--dir` CLI flag accepts any filesystem path without validation. An attacker with CLI access can point migrations at arbitrary directories, potentially reading or writing outside expected boundaries.
- **Evidence:** `backup_cli.zig:1069`, `backup_cli.zig:1141`, `backup_cli.zig:1303` -- `--dir` argument used directly.
- **Resolution:** Added isPathSafe validation rejecting `..` components in `--dir` path.
- **Confidence:** `confidence::confirmed` -- argument handling verified.

#### SEC-MIG-11: Password Visible in Process Listing -- **CLOSED (2026-04-05)**

- **Severity:** LOW | **Risk Score:** 24 (Impact: 3 x Likelihood: 2 x 4)
- **CWE:** CWE-214 (Invocation of Process Using Visible Sensitive Information) | **OWASP:** A07:2021
- **Exploit surface:** Local system (process table)
- **Summary:** Password passed via `--password` CLI flag is visible in `/proc/*/cmdline` and `ps` output. Related to prior #627 but with additional affected code paths.
- **Evidence:** `backup_cli.zig:1186-1192` -- password read from CLI args.
- **Resolution:** Added GEODE_BACKUP_PASSWORD env var support; CLI reads password from env var when available, deprecating --password flag.
- **Confidence:** `confidence::confirmed` -- CLI argument handling verified.

---

## Findings by Area

### Input Validation / Path Traversal

- **#572** (HIGH/64): `applyUpMigrations` joins user-supplied names via `std.fs.path.join` with no `..` sanitization -- **Closed**
- **#614** (MEDIUM/36): `cmdMigrateCreate` takes migration name from CLI args without sanitization -- **Closed**
- **#602** (MEDIUM/24): `statusReport` version parsing has no integer overflow guard -- **Closed**
- **SEC-MIG-10** (LOW/24): `--dir` accepts arbitrary paths without validation -- **Closed (2026-04-05)**
- **SEC-MIG-09** (LOW/4): CLI version counter overflow in `cmdMigrateCreate` -- **Closed (2026-04-05)**

### Data Integrity

- **#573** (HIGH/64): Ledger JSON has no HMAC/signature -- full state forgery from filesystem write -- **Won't Do**
- **#592** (HIGH/48): `writeLedgerJson` does not escape `row.name` -- JSON injection -- **Closed**
- **#612** (MEDIUM/24): 28-bit FNV-1a prefix with `startsWith` matching -- weak integrity check -- **Won't Do**
- **#622** (LOW/12): `use_last` duplicate field behavior enables stealthy field override -- **Closed**
- **SEC-MIG-01** (HIGH/40): No cryptographic signing of migration files -- **Open**
- **SEC-MIG-05** (MEDIUM/24): Drift evasion via FNV-1a collision + unsigned ledger -- **Closed (2026-04-10)**

### Injection

- **#598** (HIGH/64): Migration file content (up to 8MB) passed verbatim to `executor.execFn` as GQL -- **Won't Do**

### Access Control

- **#617** (MEDIUM/36): No authorization checks in migration module -- any caller can run migrations -- **Won't Do**
- **#606** (MEDIUM/36): Global lock has TOCTOU race -- concurrent migration execution possible -- **Closed**
- **SEC-MIG-03** (MEDIUM/36): `migrate status`/`create` have zero authentication -- **Closed (2026-04-10)**
- **SEC-MIG-04** (MEDIUM/36): In-process lock provides no cross-process protection -- **Closed (2026-04-10)**

### CI/CD / Supply Chain

- **SEC-MIG-02** (MEDIUM/32): No CI pipeline migration guard -- .gql files not reviewed/validated -- **Open**

### Operations / Hardening

- **#627** (LOW/16): `--password` CLI argument visible in process listing -- **Won't Do**
- **#620** (LOW/16): Resume slots use `undefined` memory and silently overwrite when full -- **Closed**
- **#625** (LOW/8): `policy_mode` global variable has no synchronization -- **Closed**
- **SEC-MIG-06** (LOW/24): No file permissions set on ledger/migration files -- **Closed (2026-04-05)**
- **SEC-MIG-07** (LOW/16): Predictable temp file name (ms timestamp) -- **Closed (2026-04-05)**
- **SEC-MIG-08** (LOW/8): Resume token memory leak (8 slots max) -- **Closed (2026-04-10)**
- **SEC-MIG-11** (LOW/24): Password visible in process listing (additional paths) -- **Closed (2026-04-05)**

---

## Roadmap

### Quick Wins (< 1 day each)

| Finding | Fix | Status |
|---------|-----|--------|
| Path traversal in names | Add `containsAny(name, "../\\")` reject | Closed |
| JSON injection in writeLedgerJson | Escape `"`, `\`, control chars in `row.name` | Closed |
| Integer overflow in statusReport | Add `if (j > 17) break;` guard | Closed |
| CLI path traversal | Validate `[a-zA-Z0-9_-]` pattern | Closed |
| use_last -> error | Change parse option | Closed |
| policy_mode sync | Use `std.atomic.Value` | Closed |
| Resume slots init | Change `= undefined` to `= std.mem.zeroes(...)` | Closed |
| **SEC-MIG-06: File permissions** | Set `0o600` on ledger files at creation | **Closed (2026-04-05)** |
| **SEC-MIG-07: Temp file naming** | Use crypto random suffix | **Closed (2026-04-05)** |
| **SEC-MIG-09: Version counter overflow** | Saturating arithmetic | **Closed (2026-04-05)** |
| **SEC-MIG-10: `--dir` validation** | isPathSafe rejects `..` components | **Closed (2026-04-05)** |

### Medium (1-5 days each)

| Finding | Fix | Status |
|---------|-----|--------|
| TOCTOU lock race | Add mutex; wire lock into apply functions | Closed |
| **SEC-MIG-01: Migration file signing** | Ed25519 or HMAC-SHA256 signing + verify before execution | **Open -- Priority 1** |
| **SEC-MIG-02: CI migration guard** | Add CI job to lint/validate .gql files + CODEOWNERS | **Open -- Priority 2** |
| **SEC-MIG-04: Cross-process flock()** | Added FileLock with flock() on `.migration_lock` file | **Closed (2026-04-10)** |
| **SEC-MIG-05: SHA-256 hash upgrade** | Added content_sha256 field with full exact match | **Closed (2026-04-10)** |
| **SEC-MIG-11: GEODE_BACKUP_PASSWORD env var** | Added env var support | **Closed (2026-04-05)** |

### Strategic (> 5 days)

| Finding | Fix | Status |
|---------|-----|--------|
| GQL injection via file content | Restricted query executor for migrations (DDL-only sandbox) | Won't Do |
| Missing authorization | Auth context threading through migration API + role checks | Won't Do |
| **SEC-MIG-03: CLI auth for status/create** | HMAC key required for status/create; auto-sign on create | **Closed (2026-04-10)** |

### Won't Do (Documented Rationale)

| Finding | Issue | Rationale |
|---------|-------|-----------|
| Unsigned ledger (#573) | [#573](https://gitlab.com/devnw/codepros/geode/geode/-/issues/573) | Too invasive; needs separate sprint with migration path design |
| GQL injection (#598) | [#598](https://gitlab.com/devnw/codepros/geode/geode/-/issues/598) | Needs DDL sandbox architecture -- separate project |
| Missing authz (#617) | [#617](https://gitlab.com/devnw/codepros/geode/geode/-/issues/617) | Needs architectural decision on auth boundary (module vs. CLI) |
| Weak checksum (#612) | [#612](https://gitlab.com/devnw/codepros/geode/geode/-/issues/612) | Breaking change; needs versioned ledger format |
| Password exposure (#627) | [#627](https://gitlab.com/devnw/codepros/geode/geode/-/issues/627) | CLI backlog item; low priority given local-only attack surface |

---

## Blockers and Unknowns

1. **GQL injection (#598):** Confirming whether the QueryExecutor can be sandboxed to DDL-only requires understanding the full query execution path. A simpler alternative is requiring signed migration files (SEC-MIG-01).

2. **Authorization (#617):** The migration module is a standalone library -- threading auth context requires API changes to all public functions. Need to decide: auth at module boundary vs. auth at CLI boundary only.

3. **Unsigned ledger (#573):** Migration path for existing unsigned ledgers needs design -- reject-and-require-re-init vs. auto-sign-on-first-read.

4. **Cross-process locking (SEC-MIG-04):** `flock()` behavior varies across NFS and network filesystems. Need to document supported filesystem requirements.

5. **Migration signing (SEC-MIG-01):** Key management for signing -- reuse existing HMAC key infrastructure or introduce separate signing keys? Need design decision before implementation.

### What Would Confirm Suspected Issues

- **SEC-MIG-08 (memory leak):** Run repeated migrate up/down cycles under memory profiler. Confirm token slots are never freed. (Confidence: suspected)
- **SEC-MIG-09 (version overflow):** Create migrations until version counter wraps. Verify behavior. (Confidence: suspected -- theoretical, impractical in practice)
- **#622 (use_last override):** Craft a ledger JSON with duplicate `version` keys and verify the parser accepts the last value silently. (Confidence: suspected -> would confirm with test) -- **Now Closed**
- **#625 (policy_mode race):** Run concurrent `enforcePolicy("STRICT")` and `isStrictPolicy()` calls across threads. (Confidence: suspected -- Zig's memory model may make this benign on x86, but UB per spec) -- **Now Closed**

---

## Immediate Actions Required

No findings require immediate rotation or emergency remediation. All new findings are defense-in-depth improvements for a CLI tool requiring local filesystem access. The highest priority item (SEC-MIG-01: migration file signing) should be planned for the next sprint.

### Recommended Priority Order for New Findings

1. ~~**SEC-MIG-01** (HIGH/40) -- Migration file signing~~ -- **Closed (2026-04-10)**
2. ~~**SEC-MIG-04** (MEDIUM/36) -- Cross-process flock() locking~~ -- **Closed (2026-04-10)**
3. **SEC-MIG-02** (MEDIUM/32) -- CI pipeline migration guard -- **Open (only remaining item)**
4. ~~**SEC-MIG-06** (LOW/24) -- File permissions on ledger~~ -- **Closed (2026-04-05)**
5. ~~**SEC-MIG-11** (LOW/24) -- GEODE_BACKUP_PASSWORD env var~~ -- **Closed (2026-04-05)**
6. ~~**SEC-MIG-10** (LOW/24) -- `--dir` path validation~~ -- **Closed (2026-04-05)**
7. ~~**SEC-MIG-07** (LOW/16) -- Predictable temp file naming~~ -- **Closed (2026-04-05)**
8. ~~**SEC-MIG-08** (LOW/8) -- Resume token memory leak~~ -- **Closed (2026-04-10)**
9. ~~**SEC-MIG-09** (LOW/4) -- Version counter overflow~~ -- **Closed (2026-04-05)**
10. ~~**SEC-MIG-03** (MEDIUM/36) -- CLI auth for status/create~~ -- **Closed (2026-04-10)**
11. ~~**SEC-MIG-05** (MEDIUM/24) -- SHA-256 hash upgrade~~ -- **Closed (2026-04-10)**
