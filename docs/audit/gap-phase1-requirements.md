# Gap Analysis — Phase 1: Requirements Collection

**Generated:** 2026-04-16
**Auditor:** Claude Opus 4.7 (1M context)
**Scope:** Entire Geode repo (`/home/benji/src/devnw/codepros/geode/geode`)
**Methodology:** Collect requirements from authoritative platform (GitLab issues) + secondary docs (TODO/FEATURES/AUDIT) + CANARY markers in source

---

## 1. Platform

| Field | Value |
|-------|-------|
| Platform | GitLab |
| Project | `devnw/codepros/geode/geode` |
| Remote | `git@gitlab.com:devnw/codepros/geode/geode.git` |
| Auth status | OK (`glab auth status` logged in as `benjiv`; warning about token file validity but API calls succeed) |
| CLI tool | `glab` |

---

## 2. Label Taxonomy Verification

All required gap-analysis labels already exist on the GitLab project — no creation needed.

| Label | Status | Description |
|-------|--------|-------------|
| `gap` | EXISTS | Gap analysis identified item (red #FF0000) |
| `priority::critical` | EXISTS | Critical priority (#dc143c) |
| `priority::high` | EXISTS | High priority (#ff6347) |
| `priority::medium` | EXISTS | Medium priority (#ffa500) |
| `priority::low` | EXISTS | Low priority (#90ee90) |
| `type::feature` | EXISTS (in use on #705, #707) | |
| `type::bug` | EXISTS (open issue count: 6) | |
| `type::enhancement` | EXISTS (open issue count: 2) | |
| `type::security` | EXISTS (open issue count: 11) | |
| `type::performance` | EXISTS (open issue count: 9) | |
| `type::code-quality` | EXISTS (open issue count: 10) | |
| `type::hardening` | EXISTS (open issue count: 2) | |
| `type::infra` | EXISTS (open issue count: 1) | |
| `confidence::confirmed` | EXISTS | |
| `confidence::suspected` | EXISTS | |
| `severity::p0/p1/p2/p3` | EXISTS (perf severity scale) | |
| `severity::critical/high/medium/low/info` | EXISTS (security severity scale) | |
| `status::triage` | EXISTS | |
| `status::done` | EXISTS | |
| `area::app / area::db / area::infra` | EXISTS | |
| `category::*` (maintainability, readability, tests, api-contract, architecture, ci-cd, cleanup, deps, docs, perf) | EXISTS | |

**Note:** The project has an extensive existing label taxonomy (~100 labels). There are a few duplicate labels with different colors (e.g. `priority::critical` exists twice with colors #dc143c and #6699cc) — this is pre-existing drift, not Phase 1 scope to fix. Candidate follow-up: consolidate the duplicate color variants.

---

## 3. Requirements from Issue Tracker (Authoritative)

### 3.1 Totals

| Slice | Count |
|-------|-------|
| All issues (ever) | 697 |
| **Open** | **154** |
| Closed | 543 |
| Open with `gap` label | 64 |
| Open `type::security` | 11 |
| Open `type::performance` | 9 |
| Open `type::code-quality` | 10 |
| Open `type::feature` | 8 |
| Open `type::bug` | 6 |
| Open `type::hardening` | 2 |
| Open `type::enhancement` | 2 |
| Open `type::infra` | 1 |

Source: `glab api .../issues_statistics` and `glab api .../issues?state=opened&labels=...` header-count queries.

### 3.2 Structured Requirement Tracker Issues (REQ-#### in GitLab)

Authoritative requirement records exist as GitLab issues #239–#308 per `docs/REQUIREMENTS.md`. These are the source-of-truth requirement records. Core buckets:

| REQ ID | Scope | GitLab Issue |
|--------|-------|--------------|
| REQ-0001 | Standards & Conformance | #239 |
| REQ-0002 | Language Surface | #240 |
| REQ-0003 | Engine Contract | #241 |
| REQ-0004 | Transactions & Storage | #242 |
| REQ-0005 | Security | #243 |
| REQ-0006 | Distributed & Ops | #244 |
| REQ-0007 | Tooling & Governance | #245 |
| REQ-0008 | Platform & Build | #246 |
| REQ-0009 | Performance Targets (non-binding) | #247 |
| REQ-DOC-* (30+ issues) | Doc-mirror requirements for Advanced Security, Argon2id, TDE/KMS, FLE, User Auth, GQL Conformance, Unicode, VALUES→MATCH, Transactions, Session Mgmt, Enhanced Isolation, Binary Protocol, QUIC, Governance, Status Ledger, Testing, CLI Subprocess, LSP, REPL, clients, Materialized Views, BM25 optimizer, Graph Algorithms, Telemetry, Completion Summary | #260–#308 |

### 3.3 Top Open Gap Clusters (64 `gap`-labeled open issues)

- **Multi-tenancy / RLS / FLE (7 issues):** #702–#707, #709 — per-tenant TDE keys, per-tenant quotas, tenant_id audit segregation, FLE TOCTOU, FLE tenant hardcoding, RLS value bridge wiring, cross-graph traversal leak.
- **Performance (9 issues, P1–P3):** #662 (RwLock write starvation), #665 (getEdgesFrom/To allocation churn), #670 (initCapacity(0) reallocation), #675 (64KB write buffer), #679 (no LIMIT pushdown), #683 (env syscalls per connection), #688 (two-write QUIC framing), #692 (WAL 256B allocation), #695 (flow-control backoff sleep), #698 (no per-connection L1 AST cache), #700 (CSR adjacency unused), #701 (no mandatory CI perf gate).
- **Code Quality (10 issues):** #663 (757 `catch {}` swallowed errors, CRITICAL), #669 (handleClientMessage 1393 lines), #671 (266 alloc / 0 errdefer in match_operations), #673 (57 allocs / 2 errdefers in eval.zig), #677 (zero test coverage for 3260 lines: twophase/cluster/sharding), #681 (magic 1000000 x14), #684 (catch continue drops errors), #686 (Proto/Zig schema drift), #691 (no error taxonomy), #693 (shallow distributed tests), #696 (dead imports / test stubs in prod).
- **Security Hardening (GAP-0513–0529):** #664 (federation unauthenticated when token unset), #666 (deterministic nonce in ReleaseSmall), #667 (ABAC disabled by default), #668 (GQL injection via MCP), #672 (single-org supply chain), #674 (Prometheus no auth), #676 (Default Docker CMD no auth), #678 (timing side-channel cluster token), #680 (memset vs secureZero), #682 (ALTER USER authz gap), #685 (16MB protobuf DoS), #687 (shell=True in Python scripts), #689 (CI cache poisoning), #690 (--insecure health check), #694 (Nginx H2C smuggling), #697 (unpinned Docker package versions), #699 (107 shellcheck findings).

### 3.4 CANARY-Cross-Referenced Requirement Ledger

`tools/canaryscan/status.csv` is a committed JSONL/CSV ledger that is the machine-readable mirror of CANARY markers in source. Counts from the committed snapshot:

| Status | Count |
|--------|-------|
| TESTED | 3099 |
| IMPL (untested) | 358 |
| EXEMPT | 270 |
| BENCHED | 259 |
| **Unique requirement IDs** | **2652** |
| **Total ledger rows** | **3986** |

Raw CANARY marker count in working tree (Grep): ~4493 occurrences across 500+ files (includes tests/bench comments + MD references). The 2,224 figure in `CLAUDE.md` refers to distinct `req,feature` tuples in status.csv — both numbers are internally consistent with how each source counts.

---

## 4. Requirements from Repo Docs

All doc-resident requirements discovered are already mirrored in GitLab per `docs/REQUIREMENTS.md` (which is explicitly structured as a flatfile mirror: *"This page mirrors GitLab requirement issues. GitLab is the source of truth for status and details."*).

| Doc | Lines | Role in Audit | Tracker Parity |
|-----|-------|---------------|----------------|
| `docs/REQUIREMENTS.md` | 108 | Index of ~60 REQ-####/REQ-DOC-* tracker issues | All linked |
| `docs/TODO.md` | 504 | Phase completion log (Phases 2–7 all marked ✅) | Captured in completion_reports + REQ-DOC-ALL_PHASES (#272) |
| `docs/FEATURES_OVERVIEW.md` | 273 | Feature catalog mirrored into doc-REQs (#260–#308) | Covered |
| `docs/GAP_ANALYSIS.md` | 2238 | Live gap log — 7 open gaps (1 crit, 2 high, 1 med, 1 low, 4 blocked, 1 won't-do) | Gaps GAP-0246/0247/0256/0526–0529 tracked in GitLab |
| `docs/GAP_ANALYSIS_RESOLVED.md` | headers | Archive of resolved gaps pre-2026-04-09 | Closed issues in tracker |
| `docs/FULL_AUDIT_2026_04_06.md` | 331 | 04-06 audit snapshot + 04-11 closure-note footer; 12 GAP-05xx tracked | All mapped to issues #664, #666, #667, #668, etc. |
| `docs/DISTRIBUTED_GAP_ANALYSIS.md` | — | Distributed module audit — all 49 gaps closed 2026-04-10 | Closed in tracker |
| `docs/DISTRIBUTED_*_GAP_ANALYSIS.md` (perf/quality/security) | — | Domain-specific audits — findings promoted to GAP-06xx/07xx issues | Tracked |

**Conclusion:** No new tracker issues are required from docs scan. `docs/REQUIREMENTS.md` is a clean mirror; `docs/GAP_ANALYSIS.md` references tracker issue URLs for every open gap. The 2026-04-11 audit closures are reflected in both docs and issue state.

### Potential doc-only items flagged for Phase 2 verification

- **`GAP-0526`, `GAP-0527`, `GAP-0528`, `GAP-0529`** in `docs/GAP_ANALYSIS.md` are written without GitLab issue links (appear as plain text bullets under "High/Medium/Low"). Phase 2 must confirm whether these map to the already-existing issues #690 (GAP-0526), #694 (GAP-0527), #697 (GAP-0528), #699 (GAP-0529) — the `GAP-05xx` numbering appears to have been reused between docs and issues. If they are *distinct* items (e.g., the doc's "glab CLI unavailable" for GAP-0526 vs the tracker's "Health check --insecure flag"), new issues must be created. Current evidence: title mismatch suggests a renumber/drift already exists.

---

## 5. Reconciled Requirements Snapshot

| Bucket | Doc Source | Tracker Source | State |
|--------|-----------|----------------|-------|
| Standards/Conformance (ISO GQL 39075:2024) | REQUIREMENTS.md | #239 + REQ-DOC-GQL_* (#308, #291, #275) | 100% (70/70 tests) |
| Security — FLE/TDE/RLS/Audit/Auth | REQUIREMENTS.md Security section | #243 + #280–#289 + 11 open security gaps | Partial, open gaps tracked |
| Multi-tenancy isolation | CLAUDE.md Known Limitations + FULL_AUDIT_2026_04_06 | GAP-0509/0510/0511/0512/0514 (closed or partial) + #702–#707 open | GAP-0509/0510 closed 2026-04-11; GAP-0514 open (governance) |
| Distributed coordination | DISTRIBUTED_GAP_ANALYSIS.md | #244 + all closed 2026-04-10 (commit 68ff42c4) | Closed |
| Performance (P1–P3) | PERF_GAP_ANALYSIS.md families | 9 open `type::performance` issues | Open, triaged |
| Code quality | QUALITY_GAP_ANALYSIS.md | 10 open `type::code-quality` issues | Open, triaged |
| Platform / Build / CI-CD | REQUIREMENTS.md | #246, #263 + perf gate #701, CI cache #689 | Partial |
| Zig 0.16.0 migration (just shipped) | Recent commits 35149ed..3f06a9e | No dedicated issue — migration captured in commits + KNOWN_TEST_ISSUES.md | **POTENTIAL GAP — confirm in Phase 2** |

---

## 6. Conflicts / Ambiguities

1. **CANARY totals drift across sources.**
   - `CLAUDE.md`: "~2,224 CANARY markers"
   - `docs/TODO.md`: "1,735 markers tracking 2,190+ requirements"
   - `docs/FULL_AUDIT_2026_04_06.md`: totals add to 2,196 (1559+322+247+68)
   - `tools/canaryscan/status.csv` snapshot (current): 3,986 rows, 2,652 unique REQ IDs, 358 IMPL untested (not 322)
   - Canary Grep across working tree: ~4,493 matches.
   Different sources count different things (file-level markers vs REQ tuples vs file×aspect rows). Not strictly a conflict, but needs a single canonical figure referenced consistently. **Action: defer to `status.csv` as the one source.**

2. **Zig version drift in docs.**
   Recent commits migrated to Zig 0.16.0 (commit `3f06a9e1`), but `CLAUDE.md` states `Zig 0.15.1+` and `docs/TODO.md` header still says "Zig 0.15.1". Docs have not been refreshed. **Not a requirements gap per se but will affect any build-system acceptance criteria.**

3. **`GAP-0526`–`GAP-0529` number collision.**
   `docs/GAP_ANALYSIS.md` cites GAP-0526 as "glab CLI unavailable", but issue #690 titled "GAP-0526: Health check uses --insecure flag" uses the same ID. Same pattern for 0527/0528/0529. The doc may be out-of-sync or the numbering was overloaded during the 2026-04-14 Requirements audit. Phase 2 must resolve (either renumber doc items or create dedicated tracker issues for the doc variants).

4. **`docs/REQUIREMENTS.md` last open-gap entry `GAP-0249 Concurrent MERGE data race (SIGSEGV)` links to #542 (Critical)** — not listed in `docs/GAP_ANALYSIS.md`'s open-gap table, which currently shows 7 open. Either it has been closed and the REQUIREMENTS.md mirror is stale, or GAP_ANALYSIS.md missed it. Phase 2 verification needed.

5. **`type::performance` as a label group** is used extensively but is not in the README's documented "type::*" taxonomy set (`feature|bug|enhancement|security`). Similarly `type::code-quality`, `type::hardening`, `type::infra`, `type::supply-chain` are in use. The taxonomy is richer than spec'd — **not a gap, but worth recording for report generation consistency**.

---

## 7. Phase 2 Inputs (what the next phase will analyze)

- **Primary input:** 154 open issues × 2652 unique REQ IDs in `status.csv` × 70+ doc-REQ issues.
- **Open investigation items:**
  - Resolve 5 conflicts above.
  - Confirm or open an issue for **Zig 0.16.0 migration acceptance** (tests/coverage deltas).
  - Confirm `GAP-0514` (358 IMPL-status CANARY markers) scan scope for hygiene sprint.
  - Verify `GAP-0249` / #542 state vs doc mirror.

---

## 8. Phase 1 Summary

- **Platform auth:** OK
- **Label taxonomy:** complete, no creation needed
- **Tracker requirements:** 154 open / 543 closed / 697 total; 64 open `gap`-labeled
- **Doc requirements mirrored in tracker:** 100% (per `docs/REQUIREMENTS.md` mirror design)
- **CANARY requirement ledger:** 2,652 unique REQ IDs tracked; 3,099 TESTED, 358 IMPL untested (GAP-0514)
- **Net new issues to create from docs:** **0 (pending 5 conflict resolutions in Phase 2)**
- **Residual risk:** Zig 0.16.0 migration has no dedicated tracker issue — Phase 2 decision required.
