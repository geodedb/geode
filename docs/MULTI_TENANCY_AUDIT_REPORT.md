# Multi-Tenancy System Audit Report

**Date:** 2026-04-01
**Scope:** Multi-tenancy system and its controls
**Auditor:** Claude Opus 4.6 (automated, 16-agent pipeline)
**Branch:** `audit/multi-tenancy`

---

## Executive Summary

The multi-tenancy implementation in Geode is **facade-level**. The architecture accepts `tenant_id` in the HELLO protocol and stores it in session state, but **no code path enforces tenant isolation**. Additionally, 5 CRITICAL, 8 HIGH, and 7 MEDIUM severity findings were identified across security, performance, and code quality domains.

### Critical Findings Requiring Immediate Action

1. **Privilege escalation via unprotected admin procedures** (CVSS 9.8) — Any ReadOnly user can create Admin accounts
2. **Unauthenticated backup/restore** (CVSS 9.1) — Full database exfiltration without auth
3. **FLE global mutable role race** (CVSS 8.5) — Cross-tenant FLE decryption via TOCTOU
4. **Cross-tenant data isolation NOT enforced** — `tenant_id` stored but never checked
5. **RLS expression engine is dead code** — 3,712 lines never called from production

### Confirmed Attack Scenarios

| # | Scenario | Complexity | Impact |
|---|----------|-----------|--------|
| 1 | ReadOnly → Admin escalation via `CALL geode.auth.user_create` | Low | Full DB takeover |
| 2 | Unauthenticated DB exfiltration via `.backup` message | Low | Complete data theft |
| 3 | Cross-tenant data read via shared graph namespace | Low | Data leakage |
| 4 | FLE role race for encrypted field decryption | Medium | Encrypted data exposure |
| 5 | Password takeover via `user_change_password` bypass | Low | Account hijack |

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented (no gaps) | 3 | 18% |
| Partial | 5 | 29% |
| Not Implemented | 7 | 41% |
| Doc Conflict | 2 | 12% |

**17 new gaps identified** (GAP-0279 through GAP-0295):

| Gap-ID | Severity | Title | Classification |
|--------|----------|-------|----------------|
| GAP-0279 | Critical | Cross-tenant data isolation NOT enforced | missing-impl |
| GAP-0280 | Critical | RLS expression engine is dead code | missing-impl |
| GAP-0281 | High | FLE hooks hardcode tenant_id="default" | partial |
| GAP-0282 | High | Audit events always set tenant_id=null | partial |
| GAP-0283 | High | GraphRBACPolicy never instantiated in production | missing-impl |
| GAP-0284 | High | gRPC missing 6 security features QUIC has | partial |
| GAP-0285 | High | FLE global mutable role race condition (CWE-362) | security-vuln |
| GAP-0286 | High | gRPC rate limiter uses username not IP (CWE-307) | security-vuln |
| GAP-0287 | High | Broken IP CIDR matching in RLS | security-vuln |
| GAP-0288 | High | Documentation overstates multi-tenancy implementation | doc-conflict |
| GAP-0289 | Medium | No per-tenant resource quotas | missing-impl |
| GAP-0290 | Medium | No per-tenant TDE encryption keys | missing-impl |
| GAP-0291 | Medium | tenant_id in HELLO stored but never enforced (CWE-863) | partial |
| GAP-0292 | Medium | getAllNodes() returns cross-graph data | partial |
| GAP-0293 | Medium | Plaintext password retained in session state (CWE-256) | security-vuln |
| GAP-0294 | Medium | Fail-open RLS expression evaluation | security-vuln |
| GAP-0295 | Medium | graph_bound only blocks USE GRAPH, not cross-graph reads | partial |

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 8 |
| Medium | 5 |
| Low | 2 |

**Top findings:**

| # | Finding | File | Impact |
|---|---------|------|--------|
| Q1 | `executeCallProcedure` is 5,055 lines with 197 branches | procedure_registry.zig:160-5214 | Unmaintainable |
| Q2 | 11 functions duplicated verbatim between QUIC/gRPC | quic_connection_handler.zig, grpc_server.zig | gRPC fell behind on security |
| Q3 | 1,744 lines confirmed dead code | rls_enhanced.zig, graph_store.zig | Misleading codebase |
| Q4 | Dual RLS Value type system | rls_core.zig vs value_types.zig | Permanently blocks wiring |
| Q5 | 207 lines of LLM reasoning traces in writeCanonicalJson | rls_core.zig:1830-2036 | Harms readability |
| Q6 | ServerState init/deinit duplicated 3 times | QUIC (2 paths) + gRPC | Bug divergence |
| Q7 | `catch null` in 3 security-critical allocation paths | quic_connection_handler.zig:499,507,837 | Fail-open on OOM |
| Q8 | Audit hash chain breakable via silent hexToBytes failure | audit.zig:206 | Tamper evidence broken |

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 3 |
| P1 | 7 |
| P2 | 5 |

**Top findings:**

| # | Finding | File:Line | Est. Impact |
|---|---------|-----------|-------------|
| P1 | Argon2id (10-50ms) under global mutex | user_management.zig:196-214 | All queries freeze during auth |
| P2 | Single g_store_rwlock for all tenants | graph_store.zig:3602-3618 | Primary scalability bottleneck |
| P3 | getGlobalStore() heap alloc+mutex 4x/query | graph_store.zig:3748-3777 | 30-125ms/sec overhead at 5K QPS |
| P4 | getCurrentUserRole() leaks memory every call | fle_integration.zig:57-68 | ~1.7-4.3GB/day unbounded growth |
| P5 | isAuthEnabled() mutex for boolean read | user_management.zig:90-93 | Cascading stall during auth |
| P6 | PollSync broadcast wakes ALL 30+ threads | transport/quic.zig:105-106 | ~32K spurious wakeups/sec |
| P7 | executeMatchCallQuery ignores label index | match_operations.zig:397-439 | O(N_total) vs O(N_matching) |
| P8 | Audit logger mutex during file I/O + SHA-256 | audit.zig:213-276 | 50-200us serialized per event |

### Security

| Risk Level | Count |
|-----------|-------|
| Critical | 5 |
| High | 6 |
| Medium | 7 |
| Low | 1 |

**All security findings:**

| # | Severity | CWE | Finding | File:Line | CVSS |
|---|----------|-----|---------|-----------|------|
| S1 | CRITICAL | CWE-862 | Admin procedures no authZ checks | procedure_registry.zig:4490-4693 | 9.8 |
| S2 | CRITICAL | CWE-306 | Backup/Restore/CDC no auth | quic_connection_handler.zig:2060-2203 | 9.1 |
| S3 | CRITICAL | CWE-362 | FLE global mutable role race | fle_integration.zig:41-48 | 8.5 |
| S4 | CRITICAL | CWE-284 | Cross-tenant isolation not enforced | graph_store.zig:305-378 | 8.0 |
| S5 | CRITICAL | CWE-863 | RLS expression engine dead code | rls_core.zig (entire), execution.zig:383 | 8.0 |
| S6 | HIGH | CWE-620 | user_change_password bypasses old pw | procedure_registry.zig:4680-4688 | 7.2 |
| S7 | HIGH | CWE-287 | captureFromState failure → unauth streams | quic_connection_handler.zig:924-926 | 7.5 |
| S8 | HIGH | CWE-863 | tenant_id accepted but never enforced | quic_connection_handler.zig:1377 | 8.0 |
| S9 | HIGH | CWE-284 | FLE uses hardcoded "default" tenant | fle_hooks.zig:44, value_utilities.zig:239 | 7.5 |
| S10 | HIGH | CWE-863 | Fail-open RLS expression evaluation | rls_enhanced.zig:513-514 | 7.5 |
| S11 | HIGH | CWE-306 | gRPC missing mTLS + FLE + federation + pw reset | grpc_server.zig (absent) | 7.0 |
| S12 | MEDIUM | CWE-307 | gRPC rate limiter uses username not IP | grpc_server.zig:997 | 5.3 |
| S13 | MEDIUM | CWE-200 | getAllNodes() crosses graph boundaries | graph_store.zig:1190-1199 | 6.5 |
| S14 | MEDIUM | CWE-256 | Plaintext password in session memory | quic_connection_handler.zig:1372 | 4.9 |
| S15 | MEDIUM | CWE-434 | Upload backup no auth + file creation | quic_connection_handler.zig:2189 | 5.0 |
| S16 | MEDIUM | CWE-798 | HMAC key no rotation mechanism | auth_graph_manager.zig:158-241 | 4.3 |
| S17 | MEDIUM | CWE-324 | FLE rotation status is stub | fle_integration.zig:168-182 | 4.0 |
| S18 | MEDIUM | CWE-183 | Broken IP CIDR matching in RLS | rls_core.zig:1403, rls_enhanced.zig:724 | 5.5 |
| S19 | LOW | CWE-522 | Cluster token in env without rotation | quic_connection_handler.zig:1050 | 3.7 |

---

## Cross-Domain Summary

| Domain | Findings | Gaps Created |
|--------|----------|-------------|
| Gap Analysis | 17 | GAP-0279 – GAP-0295 |
| Quality | 18 | — |
| Performance | 15 | — |
| Security | 19 | — |
| **Total** | **69** | **17** |

---

## Remediation Priority

### P0 — Immediate (blocks any production deployment)

1. **S1: Add Admin authorization to `geode.auth.*` procedures** — `checkPermission(context, .Schema)` before all auth procedures
2. **S2: Add Admin auth to backup/restore/CDC handlers** — reject unauthenticated and non-Admin users
3. **S6: Fix `user_change_password` to return error on old pw failure** — change `catch { log.warn(...) }` to `catch { return error... }`
4. **S3/GAP-0285: Replace FLE global role with per-connection state** — move to `ServerState.fle_role` field
5. **P4: Fix `getCurrentUserRole()` memory leak** — free the env var allocation or cache it once

### P1 — Before security-sensitive deployment (1 sprint)

1. **P1: Move Argon2id outside user_store_mutex** — copy hash under lock, verify outside lock
2. **P5: Replace `isAuthEnabled()` mutex with atomic** — `std.atomic.Value(bool)`
3. **GAP-0284/S11: Port security features to gRPC** — extract shared `transport_common.zig`
4. **S12: Fix gRPC rate limiter key** — use peer IP not username
5. **S7: Fail connection on `captureFromState` error** — return error instead of continuing
6. **GAP-0281: Thread session tenant_id through FLE hooks** — replace hardcoded "default"
7. **GAP-0282: Wire AuditLogger and populate tenant_id** — connect to handlers, set tenant from session

### P2 — Before GA / enterprise readiness (1 milestone)

1. **GAP-0279: Implement real tenant isolation** — per-tenant graph namespacing or per-tenant stores
2. **GAP-0280: Wire RLS expression engine or document as incomplete** — resolve dual Value type system
3. **P2: Per-graph RwLock** — replace global `g_store_rwlock` with per-graph locks
4. **P3: Cache `getGlobalStore()` result in ExecutionContext** — eliminate 4x per-query overhead
5. **GAP-0288: Update documentation to reflect actual state** — remove false "Production Ready" claims for multi-tenancy
6. **Q1: Break up 5,055-line `executeCallProcedure`** — extract procedure handlers to separate files
7. **Q2: Extract shared QUIC/gRPC functions to `transport_common.zig`**

### P3 — Technical debt (ongoing)

1. **GAP-0289: Per-tenant resource quotas**
2. **GAP-0290: Per-tenant TDE keys**
3. **Q3: Remove 1,744 lines dead code** (rls_enhanced.zig, deprecated serializers)
4. **Q5: Clean LLM reasoning traces from writeCanonicalJson**
5. **P6: PollSync signal() instead of broadcast()**

---

## Positive Findings

| Area | Status | Evidence |
|------|--------|----------|
| AEAD nonce generation | Secure — random from CSPRNG | crypto/aead.zig:35 |
| HMAC key file permissions | 0o600 at creation | auth_graph_manager.zig:691 |
| Password zeroing on free | Present in both transports | quic_connection_handler.zig:550,763 |
| QUIC rate limiter | Correctly uses peer IP | quic_connection_handler.zig:1301 |
| Session storage | Token-based, not password | session_storage.zig:9 |
| Constant-time token compare | Federation auth uses `timingSafeEql` | quic_connection_handler.zig:1055 |
| TLS 1.3 enforcement | `allow_insecure=false` default | transport/quic.zig |
| Argon2id parameters | OWASP-compliant (m=19456, t=2, p=1) | user_management.zig |
| Password policy | 20-char minimum with complexity | geode_auth_lib.zig |

---

## Methodology

### 4-Phase 16-Agent Pipeline

| Phase | Agents | Duration | Purpose |
|-------|--------|----------|---------|
| 1: Orientation | gap-collector, quality-inventory, perf-context, security-inventory | ~3.5 min | Requirements, structure, baselines, attack surface |
| 2: Scanning | gap-scanner, quality-scanner, perf-scanner, security-scanner | ~5.5 min | Implementation tracing, code scanning, vuln detection |
| 3: Deep Analysis | gap-detector, quality-reviewer, perf-reviewer, security-reviewer | ~4.5 min | Classification, deep review, attack scenarios |
| 4: Tracking | (unified report) | — | Document creation |

### Files Analyzed (Multi-Tenancy Scope)

| Directory | Files | Lines |
|-----------|-------|-------|
| src/security/ | 28 | ~20,178 |
| src/server/ | 12 | ~12,382 |
| src/execution/ | 8 | ~27,769 |
| src/transport/ | 6 | ~4,568 |
| src/storage/ | 10 | ~5,409 |
| src/schema/ | 5 | ~2,811 |
| src/ (root) | 4 | ~10,003 |
| **Total** | **73** | **~83,120** |

---

*Generated: 2026-04-01 by automated 16-agent audit pipeline*
*Scope: Multi-tenancy system and controls*
*Next review: After P0 remediation complete*
