# CaaST Multi-Tenant Integration — Tenancy & FLE Findings (2026-06-08)

**Source:** Downstream findings from the CaaST platform's multi-tenant integration against Geode.
**Verified by:** Claude Opus 4.8 (1M) against `main` source as of 2026-06-08. Every citation below was opened and confirmed against current source — line numbers are post-verification, not carried over from earlier audits.
**Audience:** Geode maintainers + other agents acting on these issues.
**GitLab is the source of truth for gap status.** This document proposes new GAP IDs (GAP-0838 … GAP-0845); file issues and reconcile with `docs/GAP_ANALYSIS.md` when actioned.

CaaST is a multi-tenant compliance platform that uses Geode as its graph backend. Each CaaST customer is a Geode tenant. The findings below are the gaps that block CaaST from relying on Geode's *native* tenancy and field-level-encryption (FLE) isolation, forcing CaaST to either build its own isolation layer or accept a weaker posture. They are consistent with Geode's own published stance — Geode is **single-tenant-recommended for production** (`CLAUDE.md`, "Known Limitations") — and are intended to harden the multi-tenant path, not to contradict that stance.

---

## Summary

| ID | Area | Title | Severity | Status | One-line recommendation |
|----|------|-------|----------|--------|--------------------------|
| GAP-0838 | Tenancy | Tenant `HierarchyManager` is dead code, keyed on `u64`, never bridged to string `tenant_id` | High | Open | Add a provisioning API + documented `string↔u64` bridge, or re-key on string. |
| GAP-0839 | Tenancy | No tenant provisioning surface (no DDL, no CLI, no `CALL`, `admin_tenant` unwired, `setQuota` tests-only) | High | Open | Add a tenant lifecycle surface (DDL/CLI/procedure) + registry; wire `admin_tenant`. |
| GAP-0840 | Tenancy | `tenant_id="default"`/empty maps to a nil filter (sees ALL tenants) — cross-tenant-leak footgun | High | Open | Add opt-in strict mode that refuses unscoped reads; make default tenant non-privileged; doc warning. |
| GAP-0841 | Tenancy | Go client cannot use native tenancy; vendored proto is stale (missing `role`=8); generated pb.go has no `Role` | High | Open | Set `tenant_id`+`role` in `hello()`; resync the client's proto/pb.go with the server. |
| GAP-0842 | Tenancy | `--insecure-allow-all` short-circuits all authorization, including tenant isolation | Medium | Open (doc) | Document the production-safe config explicitly; consider failing closed when multi-tenant data is present. |
| GAP-0843 | FLE | At-rest TDE is not per-tenant; per-tenant key functions exist but are **unwired dead code**; page path uses one master key | Medium | Partial (2026-06-08) — page handler now real; per-tenant key funcs tested building blocks; per-page per-tenant TDE deferred to GAP-0290 | Wire `encryptForTenant`/`decryptForTenant` (or per-tenant-group keys) into the storage/page TDE path. |
| GAP-0844 | FLE | FLE tenant correctness depends on per-thread set/clear discipline (+ a process-global env override) | Medium | Open | Bind tenant/role to the request context, not the OS thread; remove/guard the `GEODE_CURRENT_ROLE` override. |
| GAP-0845 | FLE | FLE schema is not settable via standard GQL DDL — `CALL geode.fle.*` is the only path | Low | Open (doc) | Add first-class FLE DDL, or document the `CALL` workflow as the supported, stable path. |

### Verified-resolved (no longer true — recorded for traceability)

- **GAP-0294 (fail-open RLS) — RESOLVED.** `src/security/rls_enhanced.zig:114-126` now denies on evaluation error ("fail-closed"), and `:558-559` denies unrecognized expressions. The original `return true` is gone. Confirms `docs/GAP_ANALYSIS_RESOLVED.md:4330`.
- **GAP-0287 (broken CIDR) — RESOLVED.** `src/security/rls_enhanced.zig:695-748` is a correct octet-parsing IPv4 CIDR matcher with a proper prefix mask. The historically cited `rls_core.zig:1403` is now unrelated bytecode (`op_and`); the `startsWith` implementation no longer exists.

These two are explicitly **dropped** from the open findings because the current source contradicts the stale claims.

---

## Tenancy

### GAP-0838 — Tenant `HierarchyManager` is dead code, keyed on `u64`, never bridged to string `tenant_id`

- **Severity:** High
- **Area:** Tenancy / hierarchical access control
- **Evidence:**
  - `src/security/rls_core.zig:2086-2162` — `HierarchyManager` defines `tenant_hierarchy: std.AutoHashMap(u64, TenantNode)` (`:2088`), `TenantNode` (`:2092`), `getTenantPath(... tenant_id: u64)` (`:2143`), and `canAccessTenant(accessor_tenant: u64, target_tenant: u64)` (`:2148`). There is **no `addTenant`/`put`/insert method** on the struct.
  - The only writes to `tenant_hierarchy` are in tests: `tests/e2e_rls_enhanced.zig:98,107,116,134` call `tenant_hierarchy.put(1..4, …)` with hard-coded `u64` keys. No `src/` code ever populates it.
  - Everywhere else tenancy is a **string**: `src/graph_store.zig:171` `pub const DEFAULT_TENANT_ID = "default"`; HELLO/session/FLE/audit thread `tenant_id: []const u8` (e.g. `src/fle_integration.zig:90,105`; proto `tenant_id` string at `src/proto/geode.proto:80`).
- **Impact on CaaST:** CaaST models customers as a parent→child→sub-tenant tree (org → business unit → engagement). The only API that could answer "can tenant A see tenant B's data" (`canAccessTenant`) is unreachable in production: nothing populates the hierarchy, and even if it did, it is keyed on `u64` while every real tenant identifier on the wire/session/FLE/audit path is a string. The two representations are never bridged, so parent/child/sub-tenant access control is effectively absent. CaaST must implement tenant hierarchy entirely in its own application layer.
- **Recommended correction:**
  1. Add a production provisioning API that populates `tenant_hierarchy` (an `addTenant(parent, child)` / registry-backed loader), and
  2. Define and document a stable `string ↔ u64` tenant-id mapping (e.g. a registry that assigns the `u64` from the canonical string), **or** re-key `HierarchyManager` on `[]const u8` to match the rest of the system. Re-keying on string is the lower-risk option because it removes an entire class of mapping bugs.
  3. Add a production (non-test) regression covering ancestor/descendant access decisions through the real string-keyed path.

### GAP-0839 — No tenant provisioning surface

- **Severity:** High
- **Area:** Tenancy / lifecycle
- **Evidence:**
  - **No `CREATE TENANT` GQL DDL.** `docs/GQL_AUTH_DDL.md:177-180`: *"`CREATE POLICY`, FLE DDL, and tenant DDL are not part of this surface … Tenant provisioning is also not available via GQL DDL."*
  - **No `geode tenant` CLI subcommand.** `geode --help` lists: `serve, shell, query, lsp, backup, restore, migrate, auth, login, logout, user, role, policy, grant, revoke, completion, mcp` — no `tenant`.
  - **`admin_tenant` GPS action is unwired.** `src/security/gps.zig:54` defines `admin_tenant` in the `Action` enum; a repo-wide search for `admin_tenant` returns **only that definition line** — zero dispatch callers anywhere in `src/` or `tests/`.
  - **Per-tenant quotas are tests-only (GAP-0289).** `src/security/tenant_quota.zig:74` `setQuota(...)` is the only way to configure a non-default quota, and its only callers are the in-file `test` blocks (`:266,288,314,332`). Production transports call `acquireConnection`/`acquireQuery` (`src/transport/grpc_server.zig:251,2065`; `src/server/quic_connection_handler.zig:3837,5223`) but every tenant resolves to `default_quota` (`tenant_quota.zig:51,89`) because nothing ever calls `setQuota`.
- **Impact on CaaST:** A tenant only "exists" in Geode by virtue of data being written with its `tenant_id` tag. There is no create/list/describe/delete lifecycle, no enforced per-tenant quota configuration, and no audited admin action for tenant management (`admin_tenant` is defined but never checked). CaaST cannot onboard/offboard a customer atomically, cannot set noisy-neighbor limits per customer, and gets no authorization gate around tenant administration. Provisioning becomes implicit and unauditable.
- **Recommended correction:** Provide a first-class tenant lifecycle surface — `CREATE/DROP/SHOW TENANT` DDL **or** `geode tenant {create,list,show,drop}` CLI **or** `CALL geode.tenant.*` procedures — backed by a persistent tenant registry. Route it through the already-defined `admin_tenant` GPS action so tenant administration is authorized and audited. Wire `setQuota` into that surface so per-tenant quotas become configurable in production.

### GAP-0840 — `tenant_id="default"`/empty disables tenant isolation (footgun)

- **Severity:** High
- **Area:** Tenancy / data isolation
- **Evidence:**
  - `src/execution/crud_operations.zig:54-60` — `tenantFilterFromContext` returns `null` (no filter) when `context.tenant_id` equals `graph_store.DEFAULT_TENANT_ID`, and also returns `null` when `tenant_id` is unset:

    ```zig
    fn tenantFilterFromContext(context: ExecutionContext) ?[]const u8 {
        return if (context.tenant_id) |tid|
            (if (std.mem.eql(u8, tid, graph_store.DEFAULT_TENANT_ID)) null else tid)
        else
            null;
    }
    ```

  - `src/graph_store.zig:171` — `DEFAULT_TENANT_ID = "default"`, and it is the default value of `tenant_id` on stored records (`:187,201`). A `null` filter means "match all tenants".
- **Impact on CaaST:** A session that authenticates without a `tenant_id` (or with the literal `"default"`) is silently granted a cross-tenant view: every tenant-scoped read returns rows for **all** tenants. For a multi-tenant compliance platform this is a latent cross-tenant data-leak: a single misconfigured connection string, a forgotten `tenant_id`, or a stale "default" session reads every customer's data. The failure is silent (no error, just broader results), which is the worst kind for an isolation control.
- **Recommended correction:** Add an opt-in **strict tenancy mode** (config flag, e.g. `--strict-tenancy` / `GEODE_STRICT_TENANCY=1`) under which a request with no tenant scope is **rejected** rather than treated as all-tenants, and under which `"default"` is a normal, non-privileged tenant rather than a wildcard. Until that lands, add a prominent warning in the tenancy docs and emit a startup/`WARN` log whenever a tenant-scoped query runs with an empty/`default` tenant in a deployment that has more than one tenant's data present.

### GAP-0841 — Go client cannot use native tenancy; stale vendored proto drops `role`

- **Severity:** High
- **Area:** Tenancy / client parity
- **Evidence:**
  - **Server proto carries both fields.** `src/proto/geode.proto:77-86`: `HelloRequest` has `optional string tenant_id = 3;` and `optional string role = 8;  // FLE role for field-level access control`.
  - **Go client never sets them.** `geode-client-go/conn.go:341-352` builds `proto.HelloRequest{ Username, Password, ClientName, ClientVersion, WantedConformance }` and conditionally `Graph` — it sets **neither `TenantId` nor `Role`**.
  - **Vendored proto is stale.** `geode-client-go/proto/geode.proto` `HelloRequest` stops at `optional string graph = 7;` and is **missing `role = 8`** entirely.
  - **Generated pb.go reflects the stale proto.** `geode-client-go/proto/geode.pb.go:922` has `TenantId *string` (field 3) but there is **no `Role` field** generated — confirming the downstream observation. (The CaaST-vendored copy at `app/third_party/geode-client-go` has the same stale proto.)
- **Impact on CaaST:** CaaST's backend is Go and connects via `geode-client-go`. Because `hello()` never sends `tenant_id`, every CaaST connection lands on the `"default"` tenant — directly triggering the GAP-0840 wildcard footgun — and because the client's proto/pb.go lack `role`, CaaST cannot send the FLE role needed for field-level decryption. Native tenancy and FLE are unreachable from Go regardless of server support; CaaST must work around both.
- **Recommended correction:**
  1. Add `Tenant` and `Role` to the client `Config`, and set `req.TenantId` / `req.Role` in `conn.go hello()` when configured.
  2. Resync `geode-client-go/proto/geode.proto` with the server's canonical `src/proto/geode.proto` (add `role = 8`) and regenerate `geode.pb.go`; add a CI check that fails when the vendored proto drifts from the server proto.
  3. Propagate the fix to the CaaST-vendored copy under `app/third_party/geode-client-go`.

### GAP-0842 — `--insecure-allow-all` and the auth-disabled path bypass tenant isolation

- **Severity:** Medium (documentation / hardening)
- **Area:** Tenancy / authorization
- **Evidence:**
  - `src/security/gps.zig:160-172` — `decide()` first checks `g_insecure_allow_all`; if set it returns `{ .kind = .allow, .reason_code = "insecure_allow_all" }` before any tenant/RLS logic runs.
  - The flag is real and operator-settable: `src/server/cli_args.zig:383-385` parses `--insecure-allow-all`; `src/server/main.zig:881-883` calls `gps.setInsecureAllowAll(true)` and logs `SECURITY: … all authorization checks bypassed. NOT FOR PRODUCTION.`
  - **Correction to the original claim:** the *null-principal* path is **not** a bypass — `src/security/gps.zig:222-228` returns `{ .kind = .unauthenticated, .reason_code = "no_principal" }` (fail-closed). The bypass is specifically `--insecure-allow-all`; isolation also depends on authentication being enabled and a `Principal` being present. See `docs/security/gps-isolation.md`.
- **Impact on CaaST:** If a CaaST environment is ever started with `--insecure-allow-all` (e.g. copied from a dev compose file), tenant isolation, RLS, and FLE authorization are all silently disabled — every connection can read every tenant. This is a deployment-configuration cliff rather than a code defect, but it is severe for a multi-tenant product and easy to inherit from non-production examples.
- **Recommended correction:** Document the production-safe configuration explicitly in the tenancy/security docs ("never set `--insecure-allow-all`; auth must be enabled; a Principal with a `tenant_id` is required"). Consider a guard that **refuses to start with `--insecure-allow-all` when more than one tenant's data is present** on disk, or at minimum escalates the existing `WARN` to a startup-time confirmation/`--i-understand` gate.

---

## Field-Level Encryption (FLE) & At-Rest Encryption

### GAP-0843 — At-rest TDE is not per-tenant; per-tenant key functions are unwired dead code

- **Severity:** Medium
- **Area:** FLE / at-rest encryption (TDE)
- **Evidence:**
  - Per-tenant TDE key derivation **exists**: `src/security/tde.zig:462` `encryptForTenant(...)` and `:486` `decryptForTenant(...)` derive a per-tenant AES-256-GCM key via HKDF-SHA256 from the master key (`getOrInitTenantKeyManager` / `getKeyForTenant`), with `getTenantKeyStatus`/`rotateTenantKey` helpers (`:504,519`).
  - **But they are dead code:** a repo-wide search for `encryptForTenant`/`decryptForTenant` finds **zero callers in `src/`** and **zero tests**.
  - The actual TDE entry points use the **single master key**: `src/execution/storage_dispatch.zig:268` (`tde.encrypt`/`tde.decrypt`) for the test/diagnostic procedure, and the production page handler `handleTdeEncryptPage` (`src/execution/storage_dispatch.zig:919-938`) is a **stub** returning `success=true, page_id=0, encrypted_size=0`.
  - `docs/DESIGN_TDE_KMS.md:18` lists "Multi-tenant key segregation policies" as a future/non-current item. This is the standing GAP-0290 (open).
- **Impact on CaaST:** FLE *field* keys are per-tenant (TRK derived from `tenant_id` — good), but the at-rest storage/TDE layer effectively encrypts all tenants' pages/backups under one master key (and the per-tenant path that would fix this is unreachable). A single TDE/master-key compromise spans **every** CaaST customer's data at rest, defeating the per-tenant guarantee CaaST needs for compliance separation. The presence of correct-but-unwired `encryptForTenant` is itself a hazard: it reads as "done" in code review while providing no protection.
- **Recommended correction:** Wire `encryptForTenant`/`decryptForTenant` (or a per-tenant-group key strategy) into the real storage/page and backup TDE paths so at-rest data is encrypted under tenant-derived keys; implement `handleTdeEncryptPage` rather than stubbing it; add tests asserting that data encrypted under tenant A's key cannot be decrypted under tenant B's. Track under GAP-0290.
- **Resolution (2026-06-08) — tractable subset done; per-page per-tenant TDE deferred to GAP-0290:**
  - **Feasibility finding (the load-bearing constraint).** A clean per-tenant key boundary does **NOT** exist at the storage-page level. A geode "tenant" is a per-**record** string tag (`tenant_id` on each node/edge, default `"default"`); storage is per-**graph** (`{data_dir}/graphs/{uuid}/...`) and the per-graph storage engine is handed a **single** `encryption_key` (the master key) at init (`graph_store.initGlobalAdapter` → `GraphConfig.encryption_key`, `src/graph_store.zig:6989`). A single storage page can therefore hold records from **multiple** tenants, so "encrypt each page under its tenant's key" is not generally possible without **per-tenant page segregation** — a storage-model redesign that is out of scope and remains tracked under **GAP-0290**. (The parallel file-level `encryptWithTenantKey`/`decryptWithTenantKey` in `src/storage/tde_file_encryption.zig` are likewise unwired for the same reason.) Where a per-tenant key IS correct is a buffer of bytes known to belong to exactly one tenant (e.g. a future per-tenant backup/export, or FLE field values — FLE already does this) — not a page.
  - **DONE — `handleTdeEncryptPage` is no longer a stub** (`src/execution/storage_dispatch.zig`). It now performs a real AES-256-GCM encrypt of the supplied page bytes via the TDE engine and returns the real `page_id`, `encrypted_size`, and the `ciphertext` blob (`nonce ++ tag ++ data`, surfaced as `Bytea`). The old fake `success=true, page_id=0, encrypted_size=0` "reads-as-done-but-does-nothing" hazard is removed; if TDE is disabled or no key is loaded it now reports `success=false` honestly rather than fabricating a result. Key choice is the **master key** (the only correct key at the multi-tenant page boundary today).
  - **DONE — the per-tenant key functions are now correct, compiled, and tested building blocks.** Wiring them into a live test surfaced and fixed a latent compile bug (`TenantKeyManager.init` used bare `.mu = .{}`, invalid for `std.Io.Mutex` in Zig 0.16 — `src/security/tde_key_manager.zig`); that code had **never been compiled** because it had zero callers. They remain the public API awaiting GAP-0290's per-tenant page segregation.
  - **Tests (RED→GREEN), `tests/test_gap0843_tenant_tde.zig`** (`zig build test-gap0843-tenant-tde`, in the sharded `test` step): (1) **key isolation** — data encrypted under tenant A's HKDF-derived key fails to decrypt under tenant B's key (`error.AuthenticationFailed`, AEAD tag mismatch) and round-trips under A's own key; two tenants encrypting identical plaintext cross-decrypt-fail both directions; (2) **page round-trip** — `tde.encrypt_page` returns a real `ciphertext` whose decrypt recovers the original bytes exactly, and returns the supplied `page_id` (not the stub's 0). The page test was RED (missing `ciphertext` column) against the stub, GREEN after the implementation.
  - **Deferred (still GAP-0290):** per-page/per-tenant TDE and per-tenant at-rest backups require the per-tenant page-segregation storage change. See `docs/security/MULTI_TENANT_HARDENING.md` (GAP-0843 section).

### GAP-0844 — FLE tenant correctness depends on per-thread set/clear discipline (and a process-global env override)

- **Severity:** Medium
- **Area:** FLE / concurrency correctness
- **Evidence:**
  - `src/fle_integration.zig:57-138` — current tenant and role are stored in **per-thread** maps keyed by `std.Thread.Id`: `per_thread_roles` (`:64`) and `per_thread_tenants` (`:86`). `setCurrentTenantId`/`setCurrentUserRole` are expected to run at the start of query execution and `clearCurrentThreadState` (`:132-138`) **must** be called in the connection handler's `defer` block to prevent stale state leaking into the next connection that reuses the thread. This replaced the old process-global race (GAP-0285, RESOLVED).
  - `getCurrentTenantId` (`:105-109`) falls back to `"default"` when unset — re-entering the GAP-0840 wildcard footgun if `set` is missed.
  - `getCurrentUserRole` (`:115-124`) reads the **process-global** environment variable `GEODE_CURRENT_ROLE` *before* the per-thread map — a process-wide override that bypasses per-thread isolation.
- **Impact on CaaST:** Correctness is coupled to a strict set-on-HELLO / clear-on-close protocol on the OS thread. The current synchronous one-thread-per-connection model is safe, but the contract is fragile: a future async / work-stealing / thread-pool executor that moves a request across threads mid-flight would reopen exactly the cross-tenant FLE-key leak that GAP-0285 closed. The `GEODE_CURRENT_ROLE` env override is a second global-state path that could mask the intended per-thread role in a shared process. For CaaST this is latent risk that surfaces precisely when Geode scales its execution model.
- **Recommended correction:** Bind tenant/role to the **request/execution context** (the object already threaded through query execution) rather than the OS thread, so correctness survives any executor change. Remove the `GEODE_CURRENT_ROLE` env override from the production path (or gate it behind a test-only/`--insecure` flag) so role state has a single, request-scoped source of truth.
- **Resolution (2026-06-08):**
  - **PRIMARY — DONE.** The `GEODE_CURRENT_ROLE` process-global override was **removed entirely** from `getCurrentUserRole()` in `src/fle_integration.zig`. The per-thread role map (set on HELLO, cleared on close) is now the single source of truth, so no process-wide env var can mask a connection's authenticated role in a shared multi-tenant process. The env var was only ever a crutch for the old subprocess-spawning CLI test path, which the unified-binary architecture eliminated; test-only role injection uses the per-thread `setCurrentUserRole()` setter. Regression: `src/fle_integration.zig` → test `"GAP-0844: GEODE_CURRENT_ROLE env does not override per-thread role"` (run via `zig build test-gap0844`), red before the change, green after. The grep of the whole repo found only one other live consumer — the orphaned, CI-unwired `run_encryption_tests.py` (which pointed at a stale binary path); its env-var write was neutralized with a note. The stale TODO in `src/security/test_fle_enforcement.zig` ("Add production mode check that ignores GEODE_CURRENT_ROLE") was updated to record the resolution.
  - **SECONDARY — DEFERRED (forward-looking, not a live bug).** Binding role/tenant to `execution.ExecutionContext` instead of the OS thread is **not** a contained change: the obvious carrier, `execution.g_active_context` (`execution.zig:521`), is **itself a `threadlocal`**, so merely moving the FLE role/tenant onto it would add churn without removing the OS-thread coupling. A real fix requires the executor to stop being one-thread-per-connection *and* the context to be passed explicitly (not via a threadlocal) into ~12 `getCurrentUserRole`/`getCurrentTenantId` consumers across `graph_store.zig`, `value_utilities.zig`, `fle_hooks.zig`, `rewrite.zig`, plus an `fle_user_role` field populated at the `quic_connection_handler.zig` / `grpc_server.zig` request boundaries. That is a cross-cutting execution-model refactor; under the current synchronous one-thread-per-connection executor the per-thread model is correct (fragility, not a defect). A forward-looking comment documenting this deferral was added next to the per-thread maps in `src/fle_integration.zig`.

### GAP-0845 — FLE schema is not settable via standard GQL DDL

- **Severity:** Low (documentation / API surface)
- **Area:** FLE / DDL surface
- **Evidence:**
  - `docs/GQL_AUTH_DDL.md:158-160` and `:177-180` — FLE management is only available via `CALL geode.fle.*`; tenant DDL and FLE DDL are explicitly *not* part of the GQL DDL surface.
  - The `@encrypted` / `@visible` / `@searchable` field annotations are documented (see `docs/FIELD_LEVEL_ENCRYPTION.md`) but cannot be set through standard `CREATE`/`ALTER` DDL.
- **Impact on CaaST:** CaaST defines its schema (including which fields are encrypted) as part of its migration/DDL flow. Because FLE field configuration lives behind `CALL geode.fle.*` rather than DDL, CaaST cannot declare encrypted fields in the same place as the rest of its schema; encryption config drifts into a separate, procedural code path that is easy to miss when a new encrypted field is added.
- **Recommended correction:** Either add first-class FLE DDL (e.g. column/field annotations honored by `CREATE`/`ALTER`), or formally document `CALL geode.fle.*` as the **supported, stable** path for FLE schema management — including the full procedure list and an end-to-end example — so downstream consumers can depend on it.

---

## Cross-reference

These findings are tracked in `docs/GAP_ANALYSIS.md` (proposed GAP-0838 … GAP-0845). Verified-resolved items (GAP-0287, GAP-0294) remain closed in `docs/GAP_ANALYSIS_RESOLVED.md` and are recorded here only to document that the stale "still open" claims were checked and found false.
