# Gap Register Closure (2026-06-09) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every actionable gap in the 2026-06-09 register of `docs/GAP_ANALYSIS.md` (37 items) with real code, tests, and docs — one commit per gap.

**Architecture:** Each task closes exactly one Gap-ID using TDD: write a failing test that proves the gap, implement the minimal fix, verify, commit. Where the register offers an "implement or trim/document" choice, this plan locks in the smallest honest option (noted per task). Blocked items (GAP-0256, GAP-0838, GAP-0849) get their blocked state documented with explicit unblock steps. Doc-drift items (GAP-0860, GAP-0861) run LAST so docs reflect the final state.

**Tech Stack:** Zig 0.16, `zig build` / `zig build test-<name>` targets, `zig fmt`. Pre-commit does NOT compile Zig — always run `zig build` before committing Zig changes. Integration harness (`../geode-test-harness`) is out of scope for per-task verification (too slow); use repo-local `zig build test-*` targets.

**Baseline (verified 2026-06-09):** `zig build` exit 0; sampled targets `test-gap0844`, `test-cluster-coord-config`, `test-gap0838-cluster-tls`, `test-fts-storage-adapter`, `test-cluster-forward-to-shard` all pass.

**Conventions for every task (do not repeat per task):**
1. Read the named source files FIRST; follow existing code style, allocator patterns, and CANARY marker conventions (`// CANARY: REQ=... STATUS=...`).
2. TDD: failing test → run to confirm fail → minimal implementation → run to confirm pass → `zig build` (whole repo) → `zig fmt` touched files → commit.
3. Commit message format: `fix: close GAP-XXXX - <short title>` (or `docs:`/`test:`/`chore:` as appropriate). One commit per gap.
4. After closing a gap, append a one-line closure note to the task journal `docs/superpowers/plans/2026-06-09-gap-closure-journal.md` (create on first use): `GAP-XXXX — closed/blocked/wont-do — commit <sha> — <one-line summary>`.
5. New test files go in `tests/` and must be wired into `build.zig` as a named test step (follow the existing `test-gap0838-cluster-tls` pattern).
6. Mutex acquisition must follow the lock-ordering table in CLAUDE.md (never hold a higher tier while acquiring a lower tier).

---

## Pass 1 — Critical bugs

### Task 1: GAP-0854 — FLE configureField corrupts auth/audit hash chain (Critical)

**Files:**
- Modify: `src/execution/storage_dispatch.zig` (~line 2868, `geode.fle.configureField` dispatch)
- Read/modify: `src/security/auth_graph_manager.zig` (HMAC chain append/verify path)
- Read: `src/server/server_init.zig:412-436` (restart chain verification), `src/schema/fle_catalog.zig`
- Test: `tests/test_gap0854_fle_chain.zig` (create), wire into `build.zig` as `test-gap0854`
- Reference: `docs/GAP_ANALYSIS.md` GAP-0854 row; `docs/bugs/` CaaST reproduction notes if present (grep `docs/` for `configureField`)

- [ ] **Step 1:** Investigate the exact corruption mechanism: how does `CALL geode.fle.configureField` write to the `__geode_security` graph (or its records) in a way that bypasses/breaks the HMAC chain? Trace from the CALL dispatch through `fle_catalog` persistence to `auth_graph_manager`'s chained writes. Record findings as comments in the test file header.
- [ ] **Step 2:** Write failing test `tests/test_gap0854_fle_chain.zig`: open a store, perform auth DDL (creates chained records), invoke the FLE configureField persistence path, close, re-open, and assert chain verification succeeds (currently expected to fail with `AuthChainTampered` per the reproduction). Run `zig build test-gap0854` — expect FAIL.
- [ ] **Step 3:** Implement the fix using whichever the investigation supports: (a) route FLE catalog mutations through the signed append/update path of `auth_graph_manager`, or (b) exclude FLE catalog records from chain computation deterministically (both at write AND verify). Prefer (a) — keeps FLE config tamper-evident.
- [ ] **Step 4:** Run `zig build test-gap0854` — expect PASS. Run `zig build` and the existing auth persistence test targets (grep `build.zig` for auth/security test steps) — expect PASS.
- [ ] **Step 5:** Commit `fix: close GAP-0854 - FLE configureField no longer corrupts auth chain`.

### Task 2: GAP-0818 — LSP feature providers lack caller identity (Critical, Partial)

**Files:**
- Modify: `src/cli/lsp/features.zig` (`provideCompletion` ~line 678, `provideHover`, `provideDefinition`)
- Modify: `src/cli/lsp/server.zig` (construct and pass context)
- Test: `tests/test_gap0818_lsp_context.zig` (create), wire as `test-gap0818`

- [ ] **Step 1:** Define `LspContext` struct (tenant_id, user_id, session_id — nullable where unauthenticated stdio applies) in `features.zig` or a small new `src/cli/lsp/context.zig`. Thread it as a parameter through `provideCompletion`, `provideHover`, `provideDefinition`.
- [ ] **Step 2:** Write failing test: two tenants with different schema entries; completion/hover for tenant A must not surface tenant B's labels/properties. Run `zig build test-gap0818` — expect FAIL (today providers see global schema).
- [ ] **Step 3:** Implement filtering: providers consult the context to scope schema lookups (reuse the existing per-user permission filtering noted in `docs/LSP_FEATURES.md`; extend to tenant). Update the CANARY marker at `features.zig:32` honestly (STATUS=TESTED only with the new test).
- [ ] **Step 4:** `zig build test-gap0818` PASS; run existing LSP test targets; `zig build` PASS.
- [ ] **Step 5:** Commit `fix: close GAP-0818 - thread tenant/user/session context through LSP providers`.

### Task 3: GAP-0858 — ALTER POLICY lost on restart (High)

**Files:**
- Modify: `src/security/policy_catalog.zig` (`alterPolicy` ~line 165)
- Read/modify: `src/security/auth_graph_manager.zig`, `src/server/server_init.zig` (hydration)
- Test: `tests/test_gap0858_alter_policy_persist.zig` (create), wire as `test-gap0858`

- [ ] **Step 1:** Read how `CREATE POLICY`/`DROP POLICY` persist to `__geode_security` and hydrate at startup (existing `test-gps-alter-policy` step shows the parser path works). Identify the missing write-through in `alterPolicy`.
- [ ] **Step 2:** Failing test: create policy → alter (disable + rename) → simulate restart (close + re-open store / re-run hydration) → assert altered state survives. Run `zig build test-gap0858` — expect FAIL.
- [ ] **Step 3:** Implement durable ALTER write-through using the same persistence pattern as CREATE/DROP (update-in-place or append-new-version, matching the chain rules from Task 1).
- [ ] **Step 4:** `zig build test-gap0858` PASS; existing GPS/policy targets PASS; `zig build` PASS.
- [ ] **Step 5:** Commit `fix: close GAP-0858 - durable ALTER POLICY write-through to __geode_security`.

---

## Pass 2 — Tenancy/security correctness

### Task 4: GAP-0832 — Unsafe field access in LSP server (Low, quick)

**Files:**
- Modify: `src/cli/lsp/server.zig:220-221`
- Test: extend an existing LSP server test file or create `tests/test_gap0832_lsp_decode.zig`, wire as `test-gap0832`

- [ ] **Step 1:** Read lines 200–240; identify the unsafe (unvalidated) JSON field access. Write failing test feeding a malformed message that today crashes/misbehaves. Expect FAIL (or crash).
- [ ] **Step 2:** Replace with validated decode (optional-field handling returning a proper JSON-RPC error instead of unchecked access).
- [ ] **Step 3:** Test PASS; `zig build` PASS. Commit `fix: close GAP-0832 - validated decode for LSP request fields`.

### Task 5: GAP-0850 — No refuse-to-start guard for --insecure-allow-all (Medium)

**Files:**
- Modify: `src/server/main.zig` (startup flag handling; the existing banner code is the anchor — grep `insecure-allow-all`)
- Test: `tests/test_gap0850_insecure_guard.zig` (create), wire as `test-gap0850`

- [ ] **Step 1:** Failing test: constructing server config with `insecure_allow_all=true` AND production conditions (release build mode OR `GEODE_ENV=production` env var) must return an error unless break-glass override `GEODE_INSECURE_ALLOW_ALL_I_UNDERSTAND=1` is set. Test the config-validation function directly (pure function — no server boot needed).
- [ ] **Step 2:** Implement: add a `validateInsecureMode(builtin.mode, env)` check called during startup before listeners bind; refuse with a clear fatal log naming the override. Keep Debug-build behavior permissive for tests EXCEPT when `GEODE_ENV=production` is set (so the test can exercise the guard in Debug).
- [ ] **Step 3:** Tests PASS; `zig build` PASS. Update `docs/security/MULTI_TENANT_HARDENING.md` insecure-mode section with the guard + override.
- [ ] **Step 4:** Commit `fix: close GAP-0850 - production refuse-to-start guard for --insecure-allow-all`.

### Task 6: GAP-0848 — Default tenancy treats unset tenant as unscoped (High)

**Files:**
- Modify: `src/server/main.zig` and/or tenancy config (grep `strict_tenancy` / `GEODE_STRICT_TENANCY`, GAP-0840 work)
- Read: `src/server/quic_connection_handler.zig` (where request tenant is resolved)
- Test: `tests/test_gap0848_tenancy_default.zig` (create), wire as `test-gap0848`

- [ ] **Step 1:** Read the existing strict-tenancy implementation (GAP-0840) to find where "multi-tenant mode" is detectable (e.g., >1 registered tenant, or tenancy registry non-empty).
- [ ] **Step 2:** Failing test: when the tenant registry has ≥1 non-default tenant configured and strict tenancy was NOT explicitly set, the effective config must resolve to strict (or startup must refuse permissive mode without explicit `GEODE_PERMISSIVE_TENANCY=1` override). Test the config-resolution function.
- [ ] **Step 3:** Implement auto-strict default (or guard) with the explicit override escape hatch; log the decision at startup.
- [ ] **Step 4:** Tests PASS; existing tenancy targets (grep build.zig for `tenant`) PASS; `zig build` PASS. Update `docs/security/MULTI_TENANT_HARDENING.md`.
- [ ] **Step 5:** Commit `fix: close GAP-0848 - strict tenancy default in multi-tenant mode`.

### Task 7: GAP-0846 — Tenant hierarchy not consulted in live read paths (High)

**Files:**
- Modify: `src/execution/match_operations.zig` (`passesTenantFilter` and label-indexed read sites)
- Read: `src/security/rls_core.zig:2097,2243` (`canAccessTenant`, `HierarchyManager`)
- Test: `tests/test_gap0846_tenant_hierarchy_reads.zig` (create), wire as `test-gap0846`

- [ ] **Step 1:** Read `passesTenantFilter` and `canAccessTenant`. Failing test: tenant hierarchy parent→child registered; a parent-scoped query must (per the documented hierarchy semantics) see child rows where `canAccessTenant` grants it, and an unrelated tenant must NOT; today the read path does exact-match only.
- [ ] **Step 2:** Wire hierarchy consultation into the tenant filter (single choke point preferred — extend `passesTenantFilter` to call `canAccessTenant` when a HierarchyManager is configured; keep exact-match fast path when no hierarchy exists).
- [ ] **Step 3:** Tests PASS including a cross-tenant leak regression (sibling tenants stay isolated); existing GAP-0509 tenant isolation test still PASS; `zig build` PASS.
- [ ] **Step 4:** Commit `fix: close GAP-0846 - enforce tenant hierarchy in query read paths`.

### Task 8: GAP-0852 — FLE per-thread role/tenant fallback (Medium, Partial)

**Files:**
- Modify: `src/execution/fle_hooks.zig`, `src/fle_integration.zig`, call sites (grep for the per-thread role/tenant accessors and `"default"` tenant fallback)
- Test: `tests/test_gap0852_fle_request_context.zig` (create), wire as `test-gap0852`

- [ ] **Step 1:** Enumerate every call site still using the per-thread fallback (grep). List them in the test file header.
- [ ] **Step 2:** Failing test: two concurrent (or interleaved) requests with different roles/tenants through the FLE enforcement path must each see their own context — simulate by setting thread-local to role A then invoking the context-bearing path with role B and asserting B wins; and assert that an absent tenant no longer silently becomes `"default"` when a request context is present.
- [ ] **Step 3:** Migrate call sites to the context-preferring helper (already exists per the register); remove the `"default"` tenant fallback where a request context exists; keep a documented fallback ONLY for genuinely contextless internal paths (startup hydration).
- [ ] **Step 4:** Tests PASS; existing FLE targets PASS; `zig build` PASS.
- [ ] **Step 5:** Commit `fix: close GAP-0852 - FLE enforcement uses request context for role and tenant`.

---

## Pass 3 — LSP group (guard first, then features, then tests)

### Task 9: GAP-0831 — Capability-vs-handler truthfulness guard (Medium)

**Files:**
- Read: `src/cli/lsp/server.zig` (capability advertisement + method dispatch table)
- Test: `tests/test_gap0831_lsp_capability_guard.zig` (create), wire as `test-gap0831`

- [ ] **Step 1:** Refactor (minimally) so the advertised `ServerCapabilities` and the method dispatch table are both introspectable from a test (e.g., expose a comptime/pub list of handled methods).
- [ ] **Step 2:** Structural test: for every capability advertised in `initialize`, assert a wired handler exists in the dispatch table; for every handler, assert the corresponding capability is advertised (bidirectional truthfulness). Run — fix any mismatch it reveals by TRIMMING the advertisement (do not stub handlers).
- [ ] **Step 3:** PASS; `zig build` PASS. Commit `test: close GAP-0831 - LSP capability/handler truthfulness guard`.

### Task 10: GAP-0816 — $/cancelRequest (High)

**Files:**
- Modify: `src/cli/lsp/server.zig`, `src/cli/lsp/features.zig`
- Test: `tests/test_gap0816_lsp_cancel.zig` (create), wire as `test-gap0816`

- [ ] **Step 1:** Failing test: send a request, then `$/cancelRequest` for its id; the response must be JSON-RPC error `-32800` (RequestCancelled). Also: cancelling an unknown id is a no-op.
- [ ] **Step 2:** Implement a pending-request table (id → cancellation flag); check the flag at provider entry (and at safe checkpoints in longer loops); respond `-32800` when cancelled.
- [ ] **Step 3:** PASS; truthfulness guard (Task 9) still PASS; `zig build` PASS. Commit `fix: close GAP-0816 - LSP $/cancelRequest handling with -32800 responses`.

### Task 11: GAP-0817 — positionEncoding negotiation (High)

**Files:**
- Modify: `src/cli/lsp/server.zig`, `src/cli/lsp/protocol.zig`, `src/cli/lsp/document.zig` (position mapping)
- Test: `tests/test_gap0817_lsp_position_encoding.zig` (create), wire as `test-gap0817`

- [ ] **Step 1:** Failing test: client offering `["utf-8"]` gets `utf-8` back in initialize result and offsets for a multi-byte (e.g., `é`, emoji) document line are computed in the negotiated encoding; client offering nothing gets the LSP-default `utf-16` and utf-16 code-unit offsets.
- [ ] **Step 2:** Implement: parse `general.positionEncodings` from client capabilities, store per-session encoding, answer in `initialize`, and route position↔offset conversion through an encoding-aware helper.
- [ ] **Step 3:** PASS; `zig build` PASS. Commit `fix: close GAP-0817 - LSP positionEncoding negotiation with multi-byte coverage`.

### Task 12: GAP-0820/0821/0822/0823/0824 — honest capability trim (Medium/Low, one commit per gap)

**Decision locked:** trim/non-support is the accepted completion path per the register ("or trim capabilities" / "or remove advertised support" / "or keep unadvertised" / "or explicit non-support contract"). Do NOT stub implementations.

**Files:**
- Modify: `src/cli/lsp/server.zig` (capabilities + graceful `MethodNotFound` handling)
- Test: extend `tests/test_gap0831_lsp_capability_guard.zig` + per-gap test cases in `tests/test_gap0820_0824_lsp_nonsupport.zig`, wire as `test-gap0820-0824`

For EACH of the five gaps, as separate commits:
- [ ] **GAP-0820:** Assert `workspace/*` capabilities (folders, symbol, configuration, applyEdit) are NOT advertised; requests get clean `MethodNotFound` (-32601), not a crash. Commit `fix: close GAP-0820 - explicit non-support for workspace/* (capabilities trimmed)`.
- [ ] **GAP-0821:** Same for `textDocument/rename` + `prepareRename` (`renameProvider` absent/false). Commit `fix: close GAP-0821 - explicit non-support for rename`.
- [ ] **GAP-0822:** Same for `textDocument/codeAction` (`codeActionProvider` absent/false). Commit `fix: close GAP-0822 - explicit non-support for codeAction`.
- [ ] **GAP-0823:** Same for `textDocument/inlayHint`. Commit `fix: close GAP-0823 - inlayHint unadvertised with test`.
- [ ] **GAP-0824:** Same for `willSave`/`willSaveWaitUntil`/`didSave` (didSave notification must be tolerated silently — notifications get no error response). Commit `fix: close GAP-0824 - save lifecycle non-support contract`.

### Task 13: GAP-0825 — transport framing conformance tests (Low)

**Files:**
- Read: the LSP framer (grep `Content-Length` under `src/cli/lsp/`)
- Test: `tests/test_gap0825_lsp_framing.zig` (create), wire as `test-gap0825`

- [ ] **Step 1:** Tests: valid Content-Length framing round-trip; header case-insensitivity; missing Content-Length → error; oversized/zero length handling; two messages back-to-back in one buffer; partial header across reads (if the framer supports incremental feed).
- [ ] **Step 2:** Fix any real defects the tests surface (validated decode, no panics on malformed headers). PASS; `zig build` PASS.
- [ ] **Step 3:** Commit `test: close GAP-0825 - LSP Content-Length framing conformance tests`.

### Task 14: GAP-0828 — DocumentStore reopen leak regression (Low)

**Files:**
- Read: `src/cli/lsp/document.zig`
- Test: `tests/test_gap0828_documentstore_reopen.zig` (create), wire as `test-gap0828`

- [ ] **Step 1:** Test with `std.testing.allocator` (leak-detecting): open document → close → reopen same URI → deinit store; allocator reports no leak. If the acknowledged leak reproduces, fix the double-retain/missing-free in the reopen path.
- [ ] **Step 2:** PASS; `zig build` PASS. Commit `test: close GAP-0828 - DocumentStore reopen leak regression`.

### Task 15: GAP-0826 — LSP perf/stress pack (Low; AFTER Task 10)

**Files:**
- Test: `tests/test_gap0826_lsp_stress.zig` (create), wire as `test-gap0826`

- [ ] **Step 1:** Stress tests (CI-safe, bounded): large document (≥1 MB) didOpen + completion latency sanity; many sequential requests (≥500) without leak (testing allocator); burst of requests then cancel-all (interacts with Task 10's table); large schema completion.
- [ ] **Step 2:** PASS; `zig build` PASS. Commit `test: close GAP-0826 - LSP performance/stress test pack`.

### Task 16: GAP-0827 — LSP 3.17 conformance pack (Low)

**Files:**
- Test: `tests/test_gap0827_lsp_conformance.zig` (create), wire as `test-gap0827`

- [ ] **Step 1:** Conformance suite over the stdio server loop covering, per LSP 3.17: initialize/initialized lifecycle ordering (requests before initialize → `-32002`), shutdown/exit semantics, unknown method → `-32601`, notification vs request handling, `$/cancelRequest` (Task 10), positionEncoding (Task 11), didOpen/didChange/didClose sequence, and error-object shape (code+message present).
- [ ] **Step 2:** Fix real defects surfaced (e.g., missing `-32002` pre-initialize guard). PASS; `zig build` PASS.
- [ ] **Step 3:** Commit `test: close GAP-0827 - LSP 3.17 protocol conformance pack`.

---

## Pass 4 — MCP, embedded API, distributed EXPLAIN, backup tests

### Task 17: GAP-0516 — MCP resource subscription contract (Medium)

**Decision locked:** document-the-subset path (register allows it). Subscriptions stay unimplemented; capability reporting must be truthful and tested.

**Files:**
- Modify: `src/mcp/server.zig:221-232` (+ capability advertisement)
- Test: activate the dead inline tests noted by the planner; add `tests/test_gap0516_mcp_capabilities.zig`, wire as `test-gap0516`

- [ ] **Step 1:** Test: server capabilities response must NOT advertise `resources.subscribe`; `resources/subscribe` request returns `MethodNotFound` with a message pointing to polling via `readResource`. Fix advertisement if it currently lies.
- [ ] **Step 2:** Resurrect/wire the inline dead-code tests in `src/mcp/server.zig` so they run under a named step.
- [ ] **Step 3:** Update `docs/` MCP section (CLAUDE.md Known Limitations already says this — make `docs/MCP_SERVER.md` or nearest doc match). PASS; `zig build` PASS.
- [ ] **Step 4:** Commit `fix: close GAP-0516 - truthful MCP capability reporting + subscription contract tests`.

### Task 18: GAP-0830 — MCP/LSP bridge governance (Low)

**Files:**
- Modify: `src/mcp/lsp.zig` (add CANARY marker)
- Create: `docs/MCP_LSP_BRIDGE.md`
- Test: governance check via existing CANARY tooling (`make status-generate` regenerates; add the marker correctly)

- [ ] **Step 1:** Write `docs/MCP_LSP_BRIDGE.md`: bridge contract (what LSP features MCP exposes, auth posture, transport), limitations, and the REQ id.
- [ ] **Step 2:** Add `CANARY: REQ=REQ-MCP-LSP-BRIDGE-001` marker(s) in `src/mcp/lsp.zig` with honest STATUS; add a small test exercising the bridge entry point if none exists (STATUS=TESTED) else STATUS=IMPL.
- [ ] **Step 3:** `make status-generate` clean; `zig build` PASS. Commit `docs: close GAP-0830 - MCP/LSP bridge contract doc + CANARY governance`.

### Task 19: GAP-0856 — distributed EXPLAIN/PROFILE (Medium)

**Decision locked:** implement serialization if the payload is already a string/rows shape (cheap); otherwise disable advertised remote support with a clear error + docs. Inspect first, then choose.

**Files:**
- Modify: `src/distributed/federation.zig:424`, `src/distributed/query_transport.zig:460`
- Test: `tests/test_gap0856_distributed_explain.zig` (create), wire as `test-gap0856`

- [ ] **Step 1:** Read both sites. EXPLAIN/PROFILE output in geode is row-shaped text (verify via the local EXPLAIN path). If the wire rows protocol can carry it, implement pass-through serialization; test asserts a distributed EXPLAIN returns plan rows instead of `error.Unsupported`.
- [ ] **Step 2:** If pass-through is NOT feasible in one task, instead: return a structured, documented error (`DistributedExplainUnsupported` with message) and assert docs (`docs/DISTRIBUTED_QUERY_COORDINATION.md`) say EXPLAIN/PROFILE are node-local only. Test asserts the graceful error and that the message names the limitation.
- [ ] **Step 3:** PASS; `zig build` PASS. Commit `fix: close GAP-0856 - distributed EXPLAIN/PROFILE (serialize or documented node-local scope)`.

### Task 20: GAP-0857 — embedded server API returns NotImplemented (Medium)

**Decision locked:** remove/gate cleanly (the file already documents three recommended alternatives).

**Files:**
- Modify: `src/lib.zig:594-608`
- Test: `tests/test_gap0857_lib_api.zig` (create), wire as `test-gap0857`

- [ ] **Step 1:** Replace the silent `NotImplemented` surface: mark `runServerWithArgs` (and any sibling embedded-server entry points) as explicitly unsupported — `@compileError` if feasible for comptime call sites, else a documented `error.EmbeddedServerUnsupported` with a message naming the supported alternatives. Remove "embedded server mode" claims from `src/lib.zig` doc comments and any docs that advertise it (grep `docs/` for embedded server).
- [ ] **Step 2:** Test: the public lib API surface compiles and the gated entry returns the documented error (if runtime-gated). PASS; `zig build` PASS.
- [ ] **Step 3:** Commit `fix: close GAP-0857 - gate embedded server API with documented unsupported error`.

### Task 21: GAP-0862 — backup shell tests accept NotImplemented (Medium)

**Files:**
- Locate: grep `tests/` and `scripts/` for backup specs accepting `NotImplemented` (planner: legacy backup shell tests)
- Modify: those test files; potentially `src/server/quic_connection_handler.zig` backup/restore handlers if assertions reveal real bugs
- Test: tightened existing tests + `tests/test_gap0862_backup_integrity.zig` if a Zig-level restore-integrity test is feasible, wire as `test-gap0862`

- [ ] **Step 1:** Enumerate every permissive pattern (accepting `NotImplemented`/`not implemented` as pass) in backup/restore tests. For each: determine whether the feature IS implemented (assert success + output shape) or NOT (move to an explicit `unsupported` list with a failing-if-it-starts-working assertion so implementation flips the test).
- [ ] **Step 2:** Add a restore data-integrity check: backup a graph with known nodes/edges → restore → assert node/edge counts and a sampled property round-trip.
- [ ] **Step 3:** All tightened tests PASS (fix real defects found, or split to unsupported list with documented status); `zig build` PASS.
- [ ] **Step 4:** Commit `test: close GAP-0862 - backup/restore tests assert real behavior, restore integrity check`.

---

## Pass 5 — Tenant lifecycle, TDE claims, CDC sinks, recursive CTE

### Task 22: GAP-0847 — tenant DDL scope + cascade drop + hardening docs (Medium)

**Decision locked:** document CALL-only administrative scope (no new GQL DDL — product-decision fast path the register allows); implement safe cascade data deletion on tenant drop; fix stale hardening doc.

**Files:**
- Modify: tenant drop path (grep `geode.tenant.` registration — likely `src/execution/` procedure registry / tenant registry module)
- Modify: `docs/security/MULTI_TENANT_HARDENING.md`
- Test: `tests/test_gap0847_tenant_drop_cascade.zig` (create), wire as `test-gap0847`

- [ ] **Step 1:** Failing test: create tenant → create tenant-scoped nodes/edges → `CALL geode.tenant.drop` (exact name from registry) → assert the tenant's data is deleted (no orphan rows visible to admin scans) and other tenants' data untouched. Decide+implement guard semantics: drop refuses when tenant has data unless `cascade=true` arg supplied (safe default).
- [ ] **Step 2:** Implement cascade deletion using existing per-tenant scan primitives (`getAllNodesForTenant`); respect lock ordering.
- [ ] **Step 3:** Update `MULTI_TENANT_HARDENING.md`: registry/CLI exist (remove the "no registry/CLI" claim), CALL-only DDL scope statement, cascade semantics.
- [ ] **Step 4:** PASS; tenant isolation regressions PASS; `zig build` PASS. Commit `fix: close GAP-0847 - tenant drop cascade + CALL-only DDL scope documented`.

### Task 23: GAP-0851 — per-tenant at-rest key segregation (Medium)

**Decision locked:** narrow production claims (register-sanctioned). Full per-tenant page tagging is deferred with a design note, NOT silently.

**Files:**
- Modify: docs making per-tenant at-rest claims (grep `docs/` for per-tenant key/TDE claims: `KMS_PROVIDER_SYSTEM.md`, `ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md`, `MULTI_TENANT_HARDENING.md`, `FEATURES_OVERVIEW.md`)
- Create: `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md` (short design/status note: current shared-master-key model, what per-tenant requires — key hierarchy, page tagging, backup/restore flow — and why deferred)

- [ ] **Step 1:** Grep and fix every doc claim implying per-tenant at-rest segregation exists; state the shared-master-key reality and point to the design note.
- [ ] **Step 2:** Write the design note. No code change. Commit `docs: close GAP-0851 - narrow at-rest encryption claims to shared-master-key reality`.

### Task 24: GAP-0853 — FLE DDL administrative surface (Low)

**Decision locked:** document CALL procedures as the supported surface.

**Files:**
- Modify: `docs/FIELD_LEVEL_ENCRYPTION.md` (or nearest FLE doc — grep)

- [ ] **Step 1:** Add an "Administrative surface" section: `CALL geode.fle.*` procedures are the supported configuration API; no GQL DDL planned; enumerate the procedures with one-line semantics (from the procedure registry).
- [ ] **Step 2:** Commit `docs: close GAP-0853 - document CALL geode.fle.* as supported FLE admin surface`.

### Task 25: GAP-0855 — Kafka/webhook CDC sink stubs (High, L)

**Files:**
- Modify: `src/streaming/sinks/webhook_sink.zig:160`, `src/streaming/sinks/kafka_sink.zig:153`
- Test: `tests/test_gap0855_webhook_sink.zig`, `tests/test_gap0855_kafka_sink.zig` (create), wire as `test-gap0855-webhook` / `test-gap0855-kafka`

Sub-task A — webhook (do first; std.http makes this tractable):
- [ ] **Step 1:** Failing test: in-test HTTP listener (std.net) receives a POSTed CDC event JSON from the sink; assert body, content-type, and configured auth header. Retry test: first attempt 500 → sink retries with backoff → succeeds; exhausted retries → sink reports delivery failure (no silent drop).
- [ ] **Step 2:** Implement delivery via Zig std http client (TLS supported for https URLs), configurable headers/auth token, bounded retries with backoff, and failure surfacing consistent with the sink interface.
- [ ] **Step 3:** PASS; `zig build` PASS. Commit `fix: close GAP-0855a - real webhook CDC sink delivery with retries and auth`.

Sub-task B — kafka (produce-only minimal client):
- [ ] **Step 4:** Research first (per dev workflow): check for an existing Zig Kafka client (devnw orgs, github) worth vendoring. If none suitable: implement a minimal Kafka wire-protocol producer — ApiVersions, Metadata, Produce (acks=1), over TCP with optional TLS (reuse the project's TLS stack) and SASL/PLAIN. Scope ONLY what the sink needs.
- [ ] **Step 5:** Failing test: a fake in-test broker (TCP listener speaking just enough protocol: ApiVersions + Metadata + Produce response) receives the produced record; assert topic/key/value. Retry-on-disconnect test.
- [ ] **Step 6:** Implement; PASS; `zig build` PASS. Commit `fix: close GAP-0855b - Kafka CDC sink minimal produce-only delivery`.
- [ ] **Fallback:** if the Kafka wire client proves >1 day of work mid-task, STOP, keep the webhook commit, and re-classify the Kafka half in the register as Partial with a written plan file `docs/superpowers/plans/2026-06-09-gap0855-kafka-plan.md` — do not stub or fake delivery.

### Task 26: GAP-0859 — recursive CTE docs/test drift (Medium)

**Files:**
- Modify: `tests/e2e_recursive_queries.zig` (remove stale `expectError(error.NotImplemented)`; enable real assertions)
- Read: `src/execution/query_execution.zig:1582` (fixpoint executor)
- Modify: `docs/GQL_COMPLIANCE.md` (+ any doc saying recursive CTE unimplemented — grep)

- [ ] **Step 1:** Rewrite the E2E test to run a real recursive CTE (fixpoint) query and assert produced rows. Run — if executor genuinely works, PASS; if it fails, fix the executor defects surfaced (this is the gap's point).
- [ ] **Step 2:** Update docs to implemented-with-coverage status; promote the CANARY marker only now.
- [ ] **Step 3:** PASS; `zig build` PASS. Commit `fix: close GAP-0859 - recursive CTE real E2E coverage + doc reconciliation`.

---

## Pass 6 — Governance, blocked items, final doc rebaseline

### Task 27: GAP-0514 — CANARY IMPL coverage debt (Medium, L)

**Files:**
- Run: `make status-generate`; read `tools/canaryscan/status.csv`
- Test: new named tests for the top IMPL hotspots
- Reference: the Phase 1A template noted in the register history

- [ ] **Step 1:** Re-enumerate current IMPL markers (`make status-generate`). Rank files by IMPL count.
- [ ] **Step 2:** For the top hotspot file, write tests covering its IMPL-marked behaviors and promote markers IMPL→TESTED only with a named passing test. Batch per file; commit per file (`test: GAP-0514 - promote <file> CANARY markers to TESTED`).
- [ ] **Step 3:** Repeat for the next hotspots within reasonable scope for this closure round (target: meaningfully reduce the IMPL percentage; total elimination may exceed this round — if so, record remaining count + per-phase plan in the journal and mark the gap Partial with explicit remaining scope, not Closed).
- [ ] **Step 4:** `make status-generate` regenerated and committed with each batch.

### Task 28: GAP-0256, GAP-0838, GAP-0849 — blocked items: document blocked state (one commit)

**Files:**
- Modify: `docs/GAP_ANALYSIS.md` (register rows: status → Blocked with explicit unblock steps)

- [ ] **Step 1:** GAP-0256: record blocked-on org-level signing infra (cosign keys/CI secrets); list the exact CI jobs to add when unblocked. GAP-0838: record the landed tls fix + the remaining unblock chain (push tls fix → bump quic tls pin → bump geode quic pin → re-vendor `zig-pkg/`) and the two NEW defects (DNS search domains, election-layer bug) as the active blockers. GAP-0849: blocked on upstream `geode-client-zig` tag for `9ba815e`; the moment it is published, bump `build.zig.zon:313-314` + re-vendor.
- [ ] **Step 2:** For GAP-0849, ALSO check now whether `../geode-client-zig` @ `9ba815e` is fetchable by hash without a tag (zig package manager can pin commit archives) — if yes, do the bump for real (test: `zig build` + client-dependent tests PASS) and close instead of block.
- [ ] **Step 3:** Commit `docs: GAP-0256/0838/0849 blocked-state documentation with unblock steps` (or `fix: close GAP-0849 - bump geode-client-zig pin to 9ba815e` if Step 2 succeeded).

### Task 29: GAP-0526/0527/0528/0529 — Won't-Do closures (one commit)

**Files:**
- Modify: `docs/GAP_ANALYSIS.md`

- [ ] **Step 1:** Verify each is actually in the historical body (not the 37-register): if a historical item is already excluded from the register, just annotate Won't-Do with reason (GAP-0526 env tooling; GAP-0527 stale snapshot superseded by current suite; GAP-0528 external harness spec; GAP-0529 speculative TODO without reproduction). If any IS in the register, same treatment but adjust register counts.
- [ ] **Step 2:** Commit `chore: close GAP-0526/0527/0528/0529 as won't-do with documented reasons`.

### Task 30: GAP-0829 — LSP docs drift (Medium; AFTER all LSP tasks)

**Files:**
- Modify: `docs/LSP_IMPLEMENTATION.md` (and `docs/LSP_FEATURES.md` if drifted), `docs/GAP_ANALYSIS_RESOLVED.md` LSP notes

- [ ] **Step 1:** Rewrite the feature table to match the post-Pass-3 reality: implemented handlers (completion/hover/definition/diagnostics + cancel + positionEncoding), explicit non-support list (workspace/*, rename, codeAction, inlayHint, save lifecycle), conformance/stress coverage, capability guard.
- [ ] **Step 2:** Commit `docs: close GAP-0829 - LSP docs match shipped handlers`.

### Task 31: GAP-0860 — test-status artifacts rebaseline (Medium)

**Files:**
- Modify: `docs/KNOWN_TEST_ISSUES.md`, `docs/TODO.md`, status artifacts (`tools/canaryscan/status.csv` via `make status-generate`)

- [ ] **Step 1:** Run the canonical local suite (`zig build test` + the named gap targets added in this plan); record date, command, pass/fail counts from THIS run.
- [ ] **Step 2:** Rewrite `KNOWN_TEST_ISSUES.md` from that run (remove stale January/May items that no longer reproduce; keep real known issues with current evidence). Note explicitly that the geodetestlab integration baseline requires a harness run and record the last known harness numbers as historical.
- [ ] **Step 3:** Commit `docs: close GAP-0860 - rebaseline test status artifacts from current run`.

### Task 32: GAP-0861 — README/CLAUDE claims rebaseline (Medium; LAST)

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/GQL_COMPLIANCE.md`, `docs/FEATURES_OVERVIEW.md`

- [ ] **Step 1:** Sweep for "100%", "production-ready", "all phases complete", "97.4%" claims; align each with the post-closure state: what is tested-now, what is single-tenant-recommended, what is blocked (GAP-0256/0838), what is explicitly unsupported (LSP trims, MCP subscriptions, embedded server).
- [ ] **Step 2:** Commit `docs: close GAP-0861 - rebaseline product claims against current state`.

### Task 33: Final verification + register close-out

- [ ] **Step 1:** Full validation: `zig build`, `zig build test`, all `test-gap08*` targets, `zig fmt --check src/ tests/`, `make status-generate`.
- [ ] **Step 2:** Update `docs/GAP_ANALYSIS.md` register: move every closed gap to `docs/GAP_ANALYSIS_RESOLVED.md` with commit SHAs; register keeps only Blocked/Partial items with their documented state; update summary counts.
- [ ] **Step 3:** Commit `docs: update gap analysis tracking - 2026-06-09 closure round`.

---

## Self-review notes

- Spec coverage: all 37 register items are covered — Tasks 1–27 implement, Task 28 documents the 3 blocked, Task 29 closes 4 historical won't-dos (outside the 37 but flagged by the planner), Tasks 30–32 are the doc-drift items ordered last, Task 33 closes out tracking. GAP-0849 has a real-closure attempt path (Task 28 Step 2).
- The "implement or trim" decisions are locked per task to prevent subagent scope drift.
- Type/code placeholders: tasks intentionally specify structural contracts (signatures, error names, test assertions) rather than full Zig bodies because every task modifies existing code the implementer must read first; each task names exact files/lines and exact verification commands.
