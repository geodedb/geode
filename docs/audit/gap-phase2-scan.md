# Gap Analysis — Phase 2: Implementation Scan

**Generated:** 2026-04-16
**Auditor:** Claude Opus 4.7 (1M context)
**Input:** Phase 1 — 154 open issues, 64 `gap`-labeled, 2,652 unique REQ IDs in `status.csv`.

---

## 1. Governance Tooling Run

| Tool | Command | Result |
|------|---------|--------|
| `tools/canary_lint.py` | `python3 tools/canary_lint.py` | **PASS** — "CANARY Lint: OK - All markers conform to schema" |
| `tools/status_generate.py` | `python3 tools/status_generate.py` | **PASS w/ drift** — wrote `docs/status.csv` items=4344; committed `tools/canaryscan/status.csv` has 3986 rows (gap of 358). |

**Ledger drift (canonical count, freshly generated `docs/status.csv`):**

| Status | Count |
|--------|-------|
| TESTED | 3417 |
| IMPL (untested) | 397 |
| EXEMPT | 307 |
| BENCHED | 219 |
| COMPLETE | 4 |
| blank | 16 |
| **Unique REQ IDs** | **2862** |

Compared to Phase 1 snapshot (3099/358/270/259, 2652 REQs), the fresh scan shows +210 REQs, +39 IMPL, +37 EXEMPT, −40 BENCHED. Coverage math (fresh): **TESTED / (TESTED+IMPL) = 89.6%**; **overall CANARY TESTED-or-BENCHED = 84.6%**. GAP-0514's 15% IMPL gap is now **10.4%** — improved but still open.

**New issues from status-gen:** 4 orphan rows with `STATUS=COMPLETE` (non-schema value — e.g. `docs/status.csv:233` `REQ-AUTH-001,UserManagement,Authentication,COMPLETE`) and 16 blank-status rows that appear to parse from `tf` block titles in docs (e.g. `"REQ-GQL-SET-OPERATIONS"" {`). These are CSV-generator bugs, not source-of-truth defects; tracked below under new potential issues.

---

## 2. Build / Test Status (Zig 0.16.0 migration acceptance)

| Check | Command | Result |
|-------|---------|--------|
| Debug build | `zig build` | **FAIL** — `src/cli/transport_response.zig:171: no field 'writeAll' in 'Io.File'` (+ 9 hidden refs; `src/client/query_result_accumulator.zig:145`, `src/cli/main.zig:1897`). 32/35 steps succeed. |
| `zig-out/bin/geode` | artifact | Stale (179M, last built 2026-04-16 10:06 before refactor). |

The Zig 0.16.0 migration series (`3f06a9e1` → `797cef1f` → `339050c2`) **regressed `zig build`** post-merge. `build.zig.zon:6` still pins `.minimum_zig_version = "0.15.1"` and `build.zig` has "Zig 0.15.1 migration" comments. `CLAUDE.md:267` still says `Zig 0.15.1+`. **Blocks all downstream test/coverage validation in this audit.** This warrants a **new tracker issue** (none exists today per Phase 1 §5).

---

## 3. Known-Issue Trace (CLAUDE.md residuals)

| Gap | Evidence | Status |
|-----|----------|--------|
| GAP-0509 residual (aggregation tenant) | `src/execution/aggregation_evaluation.zig:629-690` — explicit `GAP-0509 WARNING` comment + REQ-GAP-0509-AGG-TENANT-WARNING CANARY (STATUS=IMPL). Both `evaluateAggregationWithLabels` and `evaluateAggregation` iterate `store.nodes` with no `tenant_id` filter (lines 653, 692+). Guard comment present; functions called only from themselves (line 681 recursion) — confirmed dead but unsafe. | **IMPL + dead-but-unsafe**, consistent with docs. |
| GAP-0510 residual (RLS compilation) | Wiring present: `src/server/main.zig:714-715` (`setGlobalExprRLSEngine`), `src/execution/match_operations.zig:111-138` (`passesRLSExprFilter` → `checkRowAccessByUsername`). `CompiledExpression` only in `src/security/rls_types.zig` + `rls_enhanced.zig` — **no GQL→bytecode parser path found**; policies must be hand-compiled. | **Partial as documented.** |
| GAP-0514 (CANARY IMPL coverage) | Fresh scan: 397 IMPL rows (10.4% of total) vs docs' 15%. Hotspots: `src/client/repl/repl_dispatch.zig` (36), `src/cli/main.zig` (27), `src/server/quic_connection_handler.zig` (22), `src/client/repl/repl_loop.zig` (19), `src/transport/grpc_server.zig` (17). `execution.zig` / `graph_store.zig` no longer top hotspots — work progressed since docs. | **Open, improving.** |
| GAP-0516 (MCP handlers) | `src/mcp/server.zig:162-174` (subscribe/unsubscribe return `error.MethodNotFound` with CANARY STATUS=EXEMPT), `:197-201` (completeHandler returns `"[]"`), `:214-217` (setLogLevel silent success). All four carry explicit CANARY EXEMPT markers + spec references (§4.4, §6.2, §7.2) + regression tests at `:262-294`. | **Exempt-with-test** — consistent with docs. |
| NodeRegistry inline-copy drift | `src/distributed/test_query_transport_node_registry.zig:53-112` is a literal inline clone of `src/distributed/query_transport.zig:607-664` (NodeRegistry struct, 6 methods). Tracker-warn: no CI check enforces equivalence. | **Drift risk live.** |
| GAP-0249 conflict | `docs/GAP_ANALYSIS.md:480,1932` lists GAP-0249 as **CLOSED 2026-03-13**. `docs/REQUIREMENTS.md:82` still links it as open (issue #542). | **Doc mirror stale** — fix REQUIREMENTS.md. |

---

## 4. Stubs / Placeholders Inventory

- `Grep TODO|FIXME|XXX|HACK|unimplemented` → **24 total hits across 16 src/ files**. Highest concentrations: `src/security/test_fle_enforcement.zig` (4), `src/util/conformance_generator.zig` (3), `src/gql/print.zig` (2), `src/server/quic_connection_handler.zig` (2), `src/tools/run_variance_benches.zig` (2). Remaining 14 files carry 1 marker each. Low stub density — repo is cleaner than typical.
- **`catch {}` error-swallowing:** 653 occurrences across `src/` (Phase 1 issue #663 claimed 757; recent cleanup trimmed ~100). Still CRITICAL category.

---

## 5. Top Gaps (Phase 2 additions)

| Gap | Severity | Evidence |
|-----|----------|----------|
| **Zig 0.16.0 build regression** (no tracker issue) | Critical | `zig build` fails on `Io.File.writeAll` API; `build.zig.zon` version pin not bumped; docs cite 0.15.1. |
| **`docs/REQUIREMENTS.md` stale GAP-0249 link** | Low | Open in docs, closed in source-of-truth `GAP_ANALYSIS.md`. |
| **`status_generate.py` CSV schema violations** | Medium | Emits 4 `STATUS=COMPLETE` rows (not in TESTED/IMPL/EXEMPT/BENCHED taxonomy) and 16 rows with blank status parsed from `tf` block titles. Need generator fix or input-file clean-up. |
| **Committed `tools/canaryscan/status.csv` lags fresh scan by 210 REQs** | Low | Committed=2652, fresh=2862. Ledger must be regenerated & committed before closing GAP-0514 measurements. |

---

## 6. Phase 2 Summary

- **Governance tools:** canary-lint PASS; status-generate PASS but emits schema-invalid rows.
- **Build:** Zig 0.16.0 debug build **FAILS** — blocks end-to-end test coverage.
- **CLAUDE.md residuals all confirmed in source** (GAP-0509/0510/0514/0516 match documented state).
- **NodeRegistry drift risk is live** (literal inline duplicate in tests/).
- **4 new potential tracker issues** surfaced: (1) Zig 0.16.0 migration acceptance, (2) REQUIREMENTS.md GAP-0249 staleness, (3) status-generate schema violations, (4) committed status.csv lag.
- **GAP-0514 coverage improved** from documented 15% to observed 10.4% IMPL; hotspots shifted from `execution.zig` → REPL/CLI/QUIC layer.
