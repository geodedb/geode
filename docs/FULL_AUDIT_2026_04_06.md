# Full Codebase Audit Summary

**Date:** 2026-04-06
**Auditor:** Claude Opus 4.6 (automated 16-agent pipeline)
**Methodology:** 5-phase audit: orientation, scanning, deep analysis, tracking, unified summary

## Repository

- **Project:** Geode Graph Database
- **Platform:** GitLab (gitlab.com/devnw/codepros/geode/geode)
- **Languages:** Zig 0.15.1+ (507 files, 261,361 lines), Python (tooling), Go (canaryscan)
- **Scope:** Entire repository (`src/`)

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented + Tested | 1,559 CANARY markers | 71.0% |
| Implemented (untested) | 322 CANARY markers | 14.7% |
| Exempt | 247 CANARY markers | 11.2% |
| Benched | 68 CANARY markers | 3.1% |

**Open gaps:** 16 total (Critical: 2, High: 4, Medium: 5, Low: 1, Blocked: 3, Won't Do: 1)

| Gap-ID | Title | Severity | Status |
|--------|-------|----------|--------|
| GAP-0509 | Cross-tenant query isolation NOT enforced (reopened GAP-0279) | Critical | Open |
| GAP-0256 | Unsigned release artifacts, no SBOM | Critical | Blocked |
| GAP-0510 | RLS expression engine (3,924 lines) is dead code (reopened GAP-0280) | High | Open |
| GAP-0513 | Distributed module: 3,540 lines / 10 files with zero tests | High | Open |
| GAP-0517 | "DEVELOPMENT READY" claim overstated | High | Open |
| GAP-0246 | LDAP/AD authentication | High | Blocked |
| GAP-0247 | OAuth2/OIDC authentication | Medium | Blocked |
| GAP-0511 | Audit events hardcode tenant_id=null in production | Medium | Open |
| GAP-0512 | getAllNodes() returns cross-graph data | Medium | Open |
| GAP-0514 | 322 CANARY IMPL markers (14.7% untested) | Medium | Open |
| GAP-0515 | FLE per-thread tenant/role not cleaned on connection close | Medium | Open |
| GAP-0516 | MCP server functions return NotImplemented | Low | Open |

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 4 |
| Medium | 3 |
| Low | 2 |

**Top findings:**

| # | Finding | Severity | Location |
|---|---------|----------|----------|
| Q1 | WAL sync() silently swallows fsync errors (CDC/audit WAL, not crash recovery) | Medium | `src/wal.zig:199` |
| Q2 | 765 `catch {}` sites (614 in production code) | High | 113 files |
| Q3 | Group-key serialization catch {} causes silent wrong results on OOM | High | `src/execution/match_operations.zig:1109-1118` |
| Q4 | toOwnedSlice catch "" merges all GROUP BY rows on OOM | High | `src/execution/match_operations.zig:1120` |
| Q5 | evalExpr is 2,124 lines, est. cyclomatic complexity ~130 | High | `src/eval.zig:666-2785` |
| Q6 | 33 files exceed 1,500 lines (guideline: 800 max) | Medium | Multiple |
| Q7 | Group-key serialization duplicated 4x | Medium | `match_operations.zig`, `execution.zig` |
| Q8 | 13-level nesting in match_operations.zig | Medium | `src/execution/match_operations.zig:1089` |
| Q9 | mTLS user allocPrint catch null -> unauthenticated on OOM | High | `src/server/quic_connection_handler.zig:932` |
| Q10 | 243 @ptrCast/@alignCast instances (most in GPU FFI) | Low | Multiple |
| Q11 | 8 math functions duplicated inline vs call_handlers | Low | `src/eval.zig:1571-1700` |

**Note:** WAL finding (Q1) was **downgraded** from Phase 2's CRITICAL assessment. Deep review revealed `src/wal.zig` is a CDC/audit WAL, not the crash recovery WAL. Physical durability is handled by the storage engine's own WAL. The fsync failure still risks audit trail gaps.

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 (Critical) | 1 |
| P1 (High) | 2 |
| P2 (Medium) | 4 |
| P3 (Low) | 3 |

**Top findings:**

| # | Finding | Severity | Impact | Fix Complexity |
|---|---------|----------|--------|---------------|
| P1 | Global g_store_rwlock held during full query execution (1-10ms) | P0 | 11% QPS regression c=2->c=4; blocks all reads during writes | L |
| P2 | getEdgesFrom/getEdgesTo allocation churn (25 call sites) | P1 | ~1,800 unnecessary allocs per multi-hop query | S |
| P3 | getEdgesByType O(E) full scan (no edge-type index) | P1 | Linear scan on every relationship-type MATCH | M |
| P4 | Unbounded thread spawning in distributed mode | P2 | Thread exhaustion under connection flood | M |
| P5 | MatchBinding.clone() cascade in multi-hop | P2 | O(bindings *hops* vars) allocations | M |
| P6 | QueryPlanCache stub-only (not wired to execution) | P2 | Every query re-planned | L |
| P7 | Per-stream thread spawning (not using thread pool) | P2 | Thread create/destroy overhead | S |
| P8 | PollSync contention (ALREADY MITIGATED by QUIC v0.1.10) | P3 | <1% impact remaining | S (cleanup) |
| P9 | Uncapacitated ArrayLists in transaction code | P3 | Repeated realloc during txn processing | S |
| P10 | getNodesByLabels triple-nested loop | P3 | O(N *L* L_avg) | S |

**Recommended priority:** P2 (edge alloc churn) first -- smallest effort, proven fix pattern exists at 1 site. Then P1 (store lock) -- highest impact but needs careful design. P8 (PollSync) is already mitigated.

### Security

| Risk Level | Count |
|-----------|-------|
| Critical | 5 |
| High | 5 |
| Medium | 5 |
| Low | 3 |

**Immediate actions required:** 3 (federation auth fix, KMS nonce fix, auth default flip)

| # | Finding | Severity | CWE | Location |
|---|---------|----------|-----|----------|
| S1 | Federation auth skipped when GEODE_CLUSTER_TOKEN unset (3 sites) | Critical | CWE-306 | `cluster.zig:497,531`, `twophase.zig:1029` |
| S2 | AES-GCM deterministic nonce reuse in local_dev KMS | Critical | CWE-323 | `kms.zig:168-172` |
| S3 | Hardcoded KMS seed 0x1234567890ABCDEF in prod path | Critical | CWE-330 | `storage_dispatch.zig:389` |
| S4 | Auth default fail-open (auth_enabled=false) | Critical | CWE-284 | `user_management.zig:220` |
| S5 | Hardcoded "testpass123!" in debug builds | Critical | CWE-798 | `user_mgmt_cli.zig:221,381` |
| S6 | GQL injection via graph name (mitigated by callers) | Medium | CWE-89 | `query_scope.zig:15-16` |
| S7 | Private keys in git history | High | CWE-312 | Git commits `9530366b`, `0c0f8a58` |
| S8 | .geode_admin_password/.geode_hmac_key not in .gitignore | High | CWE-312 | `.gitignore` |
| S9 | 765 catch {} in security-critical paths (audit, MFA, auth) | High | CWE-755 | `geode_auth_lib.zig`, `audit.zig` |
| S10 | Non-production KMS only warns, does not block | High | CWE-329 | `kms.zig:74-78` |
| S11 | Audit logging requires explicit opt-in | Medium | -- | `cli_dispatcher.zig:158` |
| S12 | gRPC plaintext fallback in debug mode | Medium | CWE-319 | `grpc_server.zig:84-90` |
| S13 | Generated password printed to stdout | Medium | CWE-532 | `user_mgmt_cli.zig:208` |
| S14 | MCP server allows .none auth mode | Medium | CWE-306 | `mcp/server.zig:27-33` |
| S15 | Vault KMS key_path not validated | Medium | CWE-22 | `vault_kms_provider.zig:154` |
| S16 | Self-signed cert dir created with catch {} | Low | -- | `quic.zig:498-517` |
| S17 | Timing-safe comparison truncates at 256 bytes | Low | CWE-208 | `cluster_auth.zig:18-24` |
| S18 | Migration scripts execute arbitrary GQL from filesystem | Low | CWE-94 | `migration/mod.zig:400` |

**GQL injection (S6) downgraded** from Phase 2's HIGH: deep review confirmed all callers validate graph_name against `[a-zA-Z_][a-zA-Z0-9_]*` before interpolation. Residual risk is defense-in-depth only.

## Cross-Domain Summary

| Domain | Findings | New Gaps | Critical | High | Medium | Low |
|--------|----------|----------|----------|------|--------|-----|
| Gap Analysis | 12 | 9 new + 4 reopened | 2 | 4 | 5 | 1 |
| Quality | 11 | -- | 0 | 4 | 3 | 2 |
| Performance | 10 | -- | 1 | 2 | 4 | 3 |
| Security | 18 | -- | 5 | 5 | 5 | 3 |
| **Total** | **51** | **13** | **8** | **15** | **17** | **9** |

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| docs/FULL_AUDIT_2026_04_06.md | All | Created (this file) |

## Top 15 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | File |
|---|--------|---------|----------|------|
| 1 | Security | Federation auth bypassed when GEODE_CLUSTER_TOKEN unset | Critical | `cluster.zig:497` |
| 2 | Security | AES-GCM nonce reuse in local_dev KMS | Critical | `kms.zig:168` |
| 3 | Security | Hardcoded KMS seed in production path | Critical | `storage_dispatch.zig:389` |
| 4 | Security | Auth default fail-open (auth_enabled=false) | Critical | `user_management.zig:220` |
| 5 | Security | Hardcoded "testpass123!" in debug builds | Critical | `user_mgmt_cli.zig:221` |
| 6 | Gap | Cross-tenant query isolation NOT enforced | Critical | `graph_store.zig:1655` |
| 7 | Perf | Global store lock held during full query execution | Critical | `graph_store.zig:4415` |
| 8 | Gap | Unsigned release artifacts, no SBOM | Critical | CI/CD |
| 9 | Gap | RLS expression engine (3,924 lines) dead code | High | `rls_core.zig` |
| 10 | Gap | 3,540 lines distributed code with zero tests | High | `src/distributed/` |
| 11 | Quality | Group-key catch {} causes silent wrong results | High | `match_operations.zig:1109` |
| 12 | Quality | mTLS auth bypassed on OOM (catch null) | High | `quic_connection_handler.zig:932` |
| 13 | Security | Private keys in git history | High | Git history |
| 14 | Security | .geode_admin_password not in .gitignore | High | `.gitignore` |
| 15 | Perf | Edge traversal alloc churn (25 sites, fix exists) | High | `match_operations.zig` |

## Recommended Action Plan

### Immediate (before any deployment)

1. **Fix federation auth bypass (S1)** -- Remove outer `if (getenv(...))` guard; call `validateClusterToken()` unconditionally. Refuse to start distributed mode without token. ~10 lines changed, 3 files.
2. **Block non-production KMS in release builds (S2/S3/S10)** -- Change warning to error in `kms.zig:74-78`. Remove hardcoded seed from `storage_dispatch.zig:389`. ~20 lines.
3. **Flip auth default to true (S4)** -- Change `init(false)` to `init(true)` in `user_management.zig:220`. ~1 line.
4. **Add .geode_admin_password/.geode_hmac_key to .gitignore (S8)** -- ~2 lines.

### Short-term (next sprint)

1. **Fix catch {} in group-key serialization (Q3/Q4)** -- Replace `catch {}` with `try` on key_writer ops. Extract `serializeGroupKey` helper. ~50 lines across 4 sites.
2. **Apply edge traversal fix to all 25 sites (P2)** -- Mechanical refactor using proven GAP-0425 pattern. ~200 lines.
3. **Fix mTLS OOM auth bypass (Q9)** -- Change `catch null` to `catch return error.OutOfMemory`. ~1 line.
4. **Remove hardcoded debug password (S5)** -- Require explicit `--password` or `--generate-password` in all build modes. ~10 lines.

### Medium-term (next quarter)

1. **Wire tenant isolation into query execution (GAP-0509)** -- Route MATCH through `getAllNodesForTenant()`. Major change to `src/execution.zig` and match_operations.
2. **Add distributed module tests (GAP-0513)** -- 10 files need test coverage, starting with sharding.zig and query_transport.zig.
3. **Update CLAUDE.md Known Limitations (GAP-0517)** -- Accurately document multi-tenancy, RLS, and distributed test coverage gaps.
4. **Begin evalExpr extraction (Q5)** -- Remove inline math/string function duplicates (~700 lines removable with zero behavior change).

### Long-term (architectural)

1. **Per-graph locking (P1)** -- Replace global RwLock with per-GraphStore locks. Requires cross-graph join lock ordering.
2. **Wire RLS expression engine or document as incomplete (GAP-0510)** -- 3,924 lines of dead code needs a decision.
3. **Reduce CANARY IMPL to <5% (GAP-0514)** -- Convert 322 IMPL markers to TESTED with test evidence.

## Blockers

- **GitLab auth token reported invalid** -- could not create/update issues programmatically. All findings documented in this file only.
- **No local code coverage tool** -- coverage runs only in CI. Local verification of test gaps requires CI pipeline.
- **Zig ecosystem lacks static analysis** -- no equivalent to clippy/golangci-lint for detecting code smells or complexity metrics.

## "DEVELOPMENT READY" Assessment

**Verdict: Partially accurate, overstated for multi-tenant and distributed deployments.**

| Claim | Verified |
|-------|----------|
| 100% GQL compliance (70/70) | Yes |
| 97.4% test pass rate | Yes (pass rate, not coverage) |
| Core query engine functional | Yes |
| QUIC+TLS transport production-grade | Yes |
| "All planned features implemented" | **No** -- multi-tenancy query isolation is dead code |
| "Distributed mode production-ready" | **No** -- 22.8% of module untested |
| "Enhanced RLS" | **No** -- only label-based filtering works |

**Recommendation:** Change status to "DEVELOPMENT READY (single-tenant)" or explicitly document that multi-tenancy, expression RLS, and distributed mode require additional hardening.
