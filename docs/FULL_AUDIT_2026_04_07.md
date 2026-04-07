# Full Codebase Audit Summary

**Date:** 2026-04-07
**Auditor:** Claude Opus 4.6 (automated 4-domain audit)

## Repository

- **Project:** Geode Graph Database
- **Platform:** GitLab (devnw/codepros/geode/geode)
- **Languages:** Zig 0.15.1 (510 files, 264,355 LOC), Python (tooling), Go (CANARY scanner), Shell
- **Scope:** Entire repository

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| TESTED | 1,581 | 71.1% |
| IMPL (no test) | 341 | 15.3% |
| EXEMPT | 247 | 11.1% |
| BENCHED | 68 | 3.1% |
| **Total CANARY** | **2,224** | |

**GitLab issues:** 709 total (8 new created during audit for undocumented multi-tenancy gaps)

**Key gaps:**

- **341 IMPL markers** across 319 unique requirements lack test verification
- **RLS expression engine (GAP-0510):** Label-deny enforcement is wired (20+ call sites). Full expression engine (2,782 lines, bytecode VM) remains unwired — `setGlobalExprRLSEngine()` never called in production
- **Distributed module (GAP-0513):** Improved from 10 to 1 zero-test file (`query_transport.zig`, 779 lines). Test density remains low for several large files
- **Multi-tenancy (GAP-0279-0295):** 12 of 17 gaps verified fixed. Residual: GAP-0294 (RLS fail-open on temporal), GAP-0287 (broken CIDR matching in dead code)
- **CBO planner:** `src/planner/cbo.zig` explicitly states "functions are stubbed out"

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 4 |
| Medium | 3 |
| Low | 2 |

**Critical findings:**

- **692 `catch {}` sites** silently swallowing errors across 113 files — includes WAL (11 sites), QUIC transport (16), CRUD operations (16). Data loss risk in WAL path. (GAP-QE3, issue #663)
- **3,473-line `executeMatchQueryImpl` function** — untestable, unmaintainable. (issue #401)
- **2,296 cross-file duplicate code blocks** — primarily in `execution/` subdirectory

**High findings:**

- **192 storage calls inside loops (N+1 pattern)** — concentrated in `crud_operations.zig`
- **Unbounded `getAllNodes()`** — loads entire node set into memory, no pagination
- **38 files exceed 1,000 lines** — 20 exceed 2,000 lines
- **60 unused imports** — 43 concentrated in `lib.zig`

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 (Critical) | 1 |
| P1 (High) | 3 |
| P2 (Medium) | 4 |
| P3 (Low) | 3 |

**P0 finding:** Poll thread 1ms sleep + handler 2ms condvar wait = **2.4ms p50 latency floor**. The poll/wait cycle directly accounts for observed baseline latency. Reducing poll sleep to 100-200us would likely halve p50.

**P1 findings:**

- **`scanAllNodes` holds adapter mutex during entire page scan** — same deadlock pattern as `getNodesByLabel` (fixed earlier today), but `scanAllNodes` was not fixed. Blocks ALL adapter operations during scan.
- **`checkpointAll` holds adapter mutex during engine checkpoint** for ALL graphs — blocks concurrent queries during persistence tick.
- **N+1 edge allocation in MATCH traversal** — `getEdgesFrom`/`getEdgesTo` allocate per-call inside node loop. 2000-4000 heap allocations per 1000-node query.

**P2 findings:**

- Per-request heap allocations in `writeServerPacket` (546+ allocs/sec at baseline)
- Double-scan in `getEdgesByType` (O(2E))
- PollSync broadcast wakes ALL handler threads (thundering herd at c=8+)
- `BufferedProtoReader` 2ms condvar wait appears at 4 separate locations

### Security

| Risk Level | Count |
|-----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 4 |

**Critical:**

- **`--no-auth` complete authentication bypass** — disables ALL auth/authz/RLS/session management. Default is secure (auth enabled), but no runtime guard prevents production use of the flag.

**High:**

- **ML algorithms use `null` tenant_id** — Node2Vec/GraphSAGE access all tenant data without authorization check
- **RLS expression bypass** — property/temporal policies silently ignored; only label-deny enforced
- **MCP server `auth_mode=none`** — allows unauthenticated database access via AI/LLM integration

**Medium:**

- Cluster token truncated at 256 bytes (federation auth)
- No rate limiting on Raft/2PC cluster token validation
- HMAC key at predictable path; admin password printed to stderr
- `BufferedProtoReader` does not zero password bytes from transport buffer
- Lazy session invalidation on role change (TOCTOU window)

**Low:**

- Metrics endpoint unauthenticated when bound to 0.0.0.0 (default is localhost)

1. `GEODE_CLUSTER_INSECURE` not guarded for release builds

- Private keys committed in git history (test certs, not production)
- AES-256-GCM uses empty AAD in TDE/backup encryption

**SAST:** 6 findings (2 curl-pipe-bash, 2 subprocess shell=True, 1 nginx H2C smuggling, ShellCheck 431 items)

**Secret detection:** 46 gitleaks findings — all test keys/tokens in YAML specs (false positives confirmed). 5 historical private key commits in git history (test certs).

## Cross-Domain Summary

| Domain | Findings | Top Severity |
|--------|----------|-------------|
| Gap Analysis | 341 IMPL markers, 5 residual gaps | High (RLS expression bypass) |
| Quality | 12 findings | Critical (692 catch {}, monster function) |
| Performance | 11 findings | P0 (latency floor from poll/wait) |
| Security | 13 findings | Critical (--no-auth bypass) |
| **Total** | **~380+** | |

## Top 10 Findings (Cross-Domain, by Severity)

| # | Domain | Finding | Severity |
|---|--------|---------|----------|
| 1 | Security | `--no-auth` complete authentication bypass | Critical |
| 2 | Quality | 692 `catch {}` silent error suppression (WAL data loss risk) | Critical |
| 3 | Quality | 3,473-line `executeMatchQueryImpl` function | Critical |
| 4 | Security | RLS expression engine not wired (property/temporal policies ignored) | High |
| 5 | Security | ML algorithms cross-tenant access via null tenant_id | High |
| 6 | Security | MCP server unauthenticated mode | High |
| 7 | Performance | 2.4ms p50 latency floor from poll/wait cycle | P0 |
| 8 | Performance | `scanAllNodes` holds adapter mutex during full scan (deadlock risk) | P1 |
| 9 | Performance | `checkpointAll` blocks all queries during persistence | P1 |
| 10 | Performance | N+1 edge allocation in MATCH traversal | P1 |

## Immediate Actions Recommended

- **`scanAllNodes` mutex fix** — apply the same brief-mutex pattern used for `getNodesByLabel` (fixed today). Prevents deadlock with concurrent ingest.
- **Poll thread sleep reduction** — reduce from 1ms to 100-200us. Single-line change with ~50% p50 improvement.
- **RLS expression wiring** — call `setGlobalExprRLSEngine()` during server init and invoke expression evaluation from the match loop. Without this, property-based RLS policies are security theater.
- **WAL `catch {}` audit** — the 11 `catch {}` sites in `wal.zig` risk silent data loss. Replace with proper error propagation or at minimum logging.

## Blockers

- `make build` fails due to Zig 0.15.1 `f128` bug in std — `zig build test` passes (exit 0)
- Integration tests (geodetestlab) require running server + external test harness — not run
- No SAST/DAST tooling for Zig — ecosystem limitation
- No dependency vulnerability scanning for Zig packages — no lockfile format exists

---

*Generated by automated 4-domain audit pipeline. All findings are based on static analysis and code review — no runtime testing was performed.*
