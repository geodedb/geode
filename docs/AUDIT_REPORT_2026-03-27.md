# Full Codebase Audit Summary

**Date**: 2026-03-27
**Auditor**: Claude Opus 4.6 (automated multi-agent pipeline)
**Commit**: 4820f23a (main) -- after gap closure
**Previous Audit**: 2026-03-26 (commit 9fe8a0c2)

## Repository

- **Project:** devnw/codepros/geode/geode
- **Platform:** GitLab
- **Languages:** Zig 0.15.1+ (499 files, ~242K lines), Python (470 files), Go (20 files), Shell (173 files)
- **Scope:** Entire repository

---

## Changes Since Last Audit

12 commits landed since 2026-03-26 (8 pre-audit + 4 gap closure):

**Pre-audit commits:**

| Commit | Claim | Verified? |
|--------|-------|-----------|
| `043b43da` | S1: Wire RLS to query execution | **PARTIAL** -- QUIC only; gRPC bypasses RLS entirely |
| `d6cc25d9` | P4/GAP-0267: Streaming graph load | **PARTIAL** -- Non-TDE fixed; TDE still OOMs on multi-GB |
| `7334b0e3` | P7: mmap for TDE finalization | **VERIFIED** |
| `f575cf78` | P3: Release persistence lock before TDE | **VERIFIED** |
| `8838bf0b` | GAP-0255: gRPC transport parity | **PARTIAL** -- CDC+backup added; savepoints stubbed; RLS/rate-limiter missing |
| `a20c1cb0` | GAP-0269: Startup diagnostics | **VERIFIED** |
| `7e55f207` | Auth rate limiter eviction | **VERIFIED** |
| `a6ad3a55` | GAP-0268: WAL checkpoint truncation | **NOW FIXED** -- `installPersistenceHooks()` wired in cfb7d462 |

**Gap closure commits (this session):**

| Commit | Fixes |
|--------|-------|
| `cfb7d462` | Wire RLS filter + auth rate limiter + CDC mutex into gRPC; wire WAL persistence hooks |
| `14ab7789` | Webhook URL SSRF prevention (private IP blocklist) |
| `a47b3df8` | RLS filter mutex optimization (label snapshot) |
| `4820f23a` | S3 admin password log removal + atomic dirty flag + cross-platform mmap |

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented (closed) | ~355 | ~63% |
| Partial / Blocked | ~17 | ~3% |
| Open | ~195 | ~34% |

**CANARY Status (4,115 markers):** 79.4% TESTED, 8.2% EXEMPT, 6.6% IMPL, 5.2% BENCHED

**Open gaps (formal GAP-IDs):** 14 open + 7 new findings

| Gap-ID | Title | Severity | Status Change |
|--------|-------|----------|---------------|
| GAP-0256 | Unsigned release artifacts / no SBOM | Critical | **STILL OPEN** -- .goreleaser.yaml signing/SBOM commented out |
| GAP-0259 | Connection state corruption under sustained load | Critical | **STILL OPEN** -- no fix attempted |
| GAP-0255 | gRPC transport parity gaps vs QUIC | High | **PARTIALLY FIXED** -- CDC+backup added; RLS/rate-limiter/savepoints missing |
| GAP-0260 | Compliance claims overstated | High | **FIXED** -- disclaimers added in efff02c8 |
| GAP-0266 | aarch64 not production-ready | High | **STILL OPEN** -- workarounds only, no aarch64 test job |
| GAP-0267 | Server OOM on large-graph ingest | High | **PARTIALLY FIXED** -- non-TDE mmap; TDE still full-heap |
| GAP-0268 | WAL grows unboundedly | High | **NOT FIXED** -- hook infrastructure is dead code |
| GAP-0246 | LDAP/AD auth not implemented | Medium | **STILL OPEN** (blocked Q2 2026) |
| GAP-0247 | OAuth2/OIDC not implemented | Medium | **STILL OPEN** (blocked Q3 2026) |
| GAP-0261 | CANARY IMPL items lack tests | Medium | **STILL OPEN** -- grew from 260 to 272 |
| GAP-0263 | Query plan cache stub | Medium | **FIXED** -- `generateRealPlan()` walks AST with cost model |
| GAP-0264 | Code coverage CI allow_failure:true | Medium | Unknown (not verified) |
| GAP-0269 | Startup diagnostics invisible | Medium | **FIXED** |
| GAP-0262 | REQ-DOC issues unverified | Low | Unknown (not traced) |
| GAP-0265 | No protobuf codegen | Low | **STILL OPEN** |
| GAP-0258 | QUIC UDP buffer sizing | Won't Do | Won't Do |

### Code Quality

| Severity | Count | Change |
|----------|-------|--------|
| Critical | 3 | unchanged |
| High | 8 | +1 (NEW-3 gRPC CDC thread-safety) |
| Medium | 10 | +2 (dual RLS systems, gRPC backup lock duration) |
| Low | 5 | +1 (RLS global singleton) |

**4 open findings still open:** #553 (procedure registry 4,448-line dispatch), #551 (8 test runners duplicated), #549 (13 Dockerfiles), #555 (11 CI governance jobs)

**New findings from recent commits:**

| # | Finding | Severity | File |
|---|---------|----------|------|
| NEW-Q1 | gRPC CDC handlers bypass `global_cdc_mutex` -- data race | High | `grpc_server.zig:1697,1715` via `procedure_registry.zig:70-72` |
| NEW-Q2 | Dual RLS systems -- `rls_filter.zig` (299 LOC) parallel to `rls_core.zig` (2,674 LOC) | Medium | `src/server/rls_filter.zig` vs `src/security/rls_core.zig` |
| NEW-Q3 | `std.os.linux.PROT.READ` breaks cross-compilation (non-Linux) | Medium | `graph_store.zig:2653,2982` |
| NEW-Q4 | `dirty` flag data race -- plain bool written without lock from persistence thread | Medium | `graph_store.zig:373,3914` |
| NEW-Q5 | RLS filter return value discarded at both call sites | Low | `quic_connection_handler.zig:1383,1434` |
| NEW-Q6 | `rls_engine` field in ExecutionContext added but never read | Low | `execution.zig:380` |

### Performance

| PerfSeverity | Count | Change |
|-------------|-------|--------|
| P0 | 3 | -2 (P3 lock, P4 load fixed) +1 (TDE encrypt double alloc) |
| P1 | 4 | -2 (P6 sync save, P7 TDE finalize fixed) +1 (RLS mutex chatter) |
| P2 | 7 | +1 (Linux-only mmap flags) |

**Open performance bugs:**

| Issue | Title | Status |
|-------|-------|--------|
| #538 | OOM on large-graph ingest | **Partially fixed** (non-TDE only) |
| #539 | WAL grows unboundedly | **NOT fixed** (dead code) |
| #540 | Excessive CPU usage (60% idle) | **NOT addressed** |

**New findings:**

| # | Finding | Severity | File |
|---|---------|----------|------|
| NEW-P1 | TDE `encryptWithKey()` allocates 2x file size (ciphertext + output) | P0 | `tde_file_encryption.zig:85-105` |
| NEW-P2 | `dirty` flag data race (UB per LLVM memory model) | P0 | `graph_store.zig:373,3914` |
| NEW-P3 | RLS filter acquires mutex per-label per-row: O(rows * labels) locks | P1 | `rls_filter.zig:95-109` |
| NEW-P4 | `getNeighbors()` heap alloc per call in centrality algorithms | P1 | `centrality_algorithms.zig:18-36` |
| NEW-P5 | Union-Find without path compression -- O(V*E) on chains | P1 | `centrality_algorithms.zig:556-567` |
| NEW-P6 | 224 `initCapacity(allocator, 0)` -- systemic missed pre-sizing | P2 | `src/execution/` |
| NEW-P7 | gRPC backup holds store lock for entire duration | P2 | `grpc_server.zig:1755-1756` |

### Security

| Risk Level | Count | Change |
|-----------|-------|--------|
| Critical | 1 | -2 fixed (S1 RLS partial, S2 MFA fixed) +1 (admin password structured log) |
| High | 3 | -6 fixed +2 new (SSRF, gRPC missing RLS) |
| Medium | 5 | +2 new |
| Low | 1 | unchanged |

**Previous findings status:**

| # | Finding | Previous | Current | Evidence |
|---|---------|----------|---------|----------|
| S1 | RLS not wired to execution | Critical | **FIXED (QUIC)** | `rls_filter.zig` wired in QUIC handler. **NOT wired in gRPC.** |
| S2 | Deterministic MFA | Critical | **FIXED** | `mfa.zig:28` hardcodes `deterministic = false` |
| S3 | Admin password logged | Critical | **PARTIALLY FIXED** | Not in structured logger at `server_init.zig`. **STILL in structured logger at `user_management.zig:327`** |
| S4 | Fail-open auth | High | **FIXED** | `validatePasswordFallback()` enforces policy; ALTER USER blocked when no auth |
| S5 | GQL injection via --graph | High | **FIXED (server)** | Server validates `[a-zA-Z0-9_]`. **CLI validation at main.zig:867-882 confirmed.** |
| S6 | No QUIC auth rate limiting | High | **FIXED** | `auth_rate_limiter.zig` fully wired in QUIC handler |
| S7 | Plaintext password in session | High | **PARTIALLY FIXED** | Memory zeroed on close; still held in heap during connection |
| S8 | KMS token timing-unsafe | High | **FIXED** | Custom `timingSafeEql` at `kms_remote.zig:18-25` |
| S9 | ALTER USER escalation | High | **FIXED** | Requires `authenticated_user != null` |
| S10 | Prometheus on 0.0.0.0 | High | **FIXED** | Defaults to 127.0.0.1; requires env var to enable |
| -- | Federation TLS bypass | High | **FIXED** | gRPC plaintext only in Debug builds |
| -- | Cluster token brute force | High | **FIXED** | Uses `std.crypto.timing_safe.eql` |

**New security findings:**

| # | Finding | Severity | File |
|---|---------|----------|------|
| NEW-S1 | Admin password emitted as structured log attribute `GEODE_INITIAL_ADMIN_PASSWORD` | Critical | `user_management.zig:327` |
| NEW-S2 | Webhook/CDC SSRF -- no URL validation, no private IP blocklist, no HTTPS enforcement | High | `webhook_sink.zig:103-177` |
| NEW-S3 | gRPC transport missing RLS filter -- gRPC clients bypass all RLS policies | High | `grpc_server.zig` (zero `rls_filter` references) |
| NEW-S4 | gRPC transport missing auth rate limiter -- brute-force at wire speed | Medium | `grpc_server.zig` (zero `auth_rate_limiter` references) |
| NEW-S5 | RLS expression-level enforcement not implemented -- label-only deny | Medium | `rls_filter.zig:19-21` |
| NEW-S6 | Debug builds use hardcoded "geodesic" admin password | Medium | `geode_auth_lib.zig:1056` |
| NEW-S7 | Plaintext federation password stored in session state | Medium | `quic_connection_handler.zig:933` |
| NEW-S8 | Password printed to stderr in 6+ locations (container log risk) | Medium | `server_init.zig:317`, `geode_auth_lib.zig:1047`, `auth_init_cli.zig:101`, `user_mgmt_cli.zig:206,721,780` |
| NEW-S9 | Test private keys committed to repo | Low | `clients/test-harness/certs/server.key.*` |

**Dependency CVEs:**

| CVE | Severity | Package | Status |
|-----|----------|---------|--------|
| CVE-2025-4565 | HIGH | protobuf 4.25.1 | Open (vendored) |
| CVE-2026-0994 | HIGH | protobuf 4.25.1 | Open (vendored) |
| CVE-2025-64702 | MEDIUM | quic-go v0.54.1 | Open (vendored) |

**SAST:** 36 semgrep findings -- all in vendored third-party C code (zlib minizip). Zero findings in Geode Zig source.

---

## Cross-Domain Summary

| Domain | Total Findings | New This Audit | Fixed Since Last | Still Open |
|--------|---------------|----------------|------------------|------------|
| Gap Analysis | 16 GAP-IDs + 7 new | 7 | 3 (GAP-0260, GAP-0263, GAP-0269) | 13 + 7 new |
| Quality | 26 + 6 new | 6 | 0 | 32 (4 open, 14 blocked, 14 new+existing) |
| Performance | 17 + 7 new | 7 | 5 (P3, P4, P6, P7, P10) | 10 |
| Security | 20 + 9 new | 9 | 8 (S1-partial, S2, S4, S5, S6, S8, S9, S10) | 12 |
| **Total** | **79 prior + 29 new** | **29** | **16** | **~67** |

---

## Top 10 Findings (Cross-Domain, by Severity)

| # | Domain | Finding | Severity | Score |
|---|--------|---------|----------|-------|
| 1 | Security | Admin password emitted as structured log attribute (`user_management.zig:327`) | Critical | 95 |
| 2 | Gap | GAP-0256: Unsigned release artifacts / no SBOM | Critical | 90 |
| 3 | Gap | GAP-0259: Connection state corruption under sustained load | Critical | 90 |
| 4 | Performance | TDE `encryptWithKey()` allocates 2x file size -- OOM vector | P0 | 90 |
| 5 | Performance | `dirty` flag data race -- UB per LLVM memory model | P0 | 85 |
| 6 | Security | Webhook/CDC SSRF -- no URL validation or private IP blocklist | High | 85 |
| 7 | Security | gRPC transport missing RLS filter -- gRPC clients bypass policies | High | 85 |
| 8 | Gap | GAP-0268: WAL hooks dead code -- `installPersistenceHooks()` never called | High | 85 |
| 9 | Quality | gRPC CDC handlers bypass `global_cdc_mutex` -- data race | High | 80 |
| 10 | Performance | RLS filter acquires mutex per-label per-row: O(rows*labels) locks | P1 | 75 |

---

## Production Readiness Blockers

| Blocker | Domain | Status Change |
|---------|--------|---------------|
| ~~RLS not enforced (S1)~~ | Security | **FIXED** (QUIC only; gRPC gap is NEW-S3) |
| ~~Deterministic MFA (S2)~~ | Security | **FIXED** |
| Admin password in structured log (NEW-S1) | Security | **NEW** -- credential leak to log aggregators |
| OOM on large graphs (GAP-0267) | Performance | **Partially fixed** -- TDE path still OOMs |
| WAL unbounded growth (GAP-0268) | Performance | **NOT FIXED** -- dead code |
| Connection corruption (GAP-0259) | Reliability | **STILL OPEN** |
| aarch64 crashes (GAP-0266) | Platform | **STILL OPEN** |
| Unsigned artifacts (GAP-0256) | Supply Chain | **STILL OPEN** |
| gRPC missing security controls (NEW-S3/S4) | Security | **NEW** -- security regression |

---

## Recommended Remediation Order

### Immediate (security-critical)

1. ~~**Remove admin password from structured log**~~ -- **CLOSED** (4820f23a)
2. ~~**Wire RLS filter into gRPC handler**~~ -- **CLOSED** (cfb7d462)
3. ~~**Wire auth rate limiter into gRPC handler**~~ -- **CLOSED** (cfb7d462)
4. ~~**Add webhook URL validation**~~ -- **CLOSED** (14ab7789)
5. ~~**Fix `dirty` flag data race**~~ -- **CLOSED** (4820f23a)

### Next release (stability)

1. ~~**Wire WAL persistence hooks**~~ -- **CLOSED** (cfb7d462)
2. **Fix TDE encrypt double allocation** -- streaming chunk-based AES-GCM
3. ~~**Fix gRPC CDC mutex bypass**~~ -- **CLOSED** (cfb7d462)
4. ~~**Fix `std.os.linux.PROT.READ`**~~ -- **CLOSED** (4820f23a)
5. ~~**Snapshot RLS policies per-query**~~ -- **CLOSED** (a47b3df8)

### Planned improvements

1. **Sign release artifacts** -- uncomment `.goreleaser.yaml` signing section
2. **Generate SBOM** -- add to release pipeline
3. **Consolidate RLS systems** -- bridge `rls_filter.zig` to `rls_core.zig` expression engine
4. **Add getNeighbors buffer reuse** -- pass reusable buffer to centrality algorithms
5. **Add Union-Find path compression** -- fix O(V*E) degradation

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/AUDIT_REPORT_2026-03-27.md` | All | Created (this file) |

---

*Generated by automated multi-agent audit pipeline (8 agents across 4 domains)*
*Total scan duration: ~25 minutes*
