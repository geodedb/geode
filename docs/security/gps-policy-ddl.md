# GPS Phase 4 — Policy DDL + Persistent Catalog

## What landed

- **`src/security/role_resolver.zig`** — Extracted from `main.zig` (carry-forward from Phase 3); isolated unit test for HAS_ROLE traversal (`tests/test_gps_role_resolver.zig`).
- **`src/security/policy_catalog.zig`** — In-memory PolicyCatalog with add/list/remove and WriteThroughHooks for external state synchronization.
- **`src/security/policy_persistence.zig`** — Persists Policy nodes in `__geode_security` graph with HMAC chain (mirrors `auth_graph_manager` design).
- **Parser support** — `CREATE POLICY name ON GRAPH * FOR READ;`, `DROP POLICY [IF EXISTS] name;`, `SHOW POLICIES;` — full AST representation.
- **DDL dispatch** — Routed through `auth_dispatch` module; reuses existing authorization framework.
- **Catalog hydration at startup** — Server reads persisted Policy nodes from `__geode_security` at startup and populates PolicyCatalog.
- **Write-through hooks** — Installed in `main.zig`; every add/remove operation syncs to persistent storage.
- **`decide()` policy evaluation** — Consults the catalog after builtin-role and graph-grant evaluation. When a policy with `expression_source = "true"` matches a query binding, returns `.allow` with reason `policy_match`.

## What did NOT change

- **Real expression compilation** — Phase 4 only supports the literal `"true"` predicate. Phase 5+ compiles real expressions through the RLS VM.
- **`ALTER POLICY`** — Deferred; would require mutation of Policy nodes and rehydration.
- **`SHOW GRANTS FOR <user>`** — Query-time grant enumeration; deferred to Phase 5+.
- **`EXPLAIN POLICY`** — Policy evaluation tracing; deferred.
- **ABAC attribute predicates** — Attribute map plumbing and context threading; deferred to Phase 5+.
- **`WITH CHECK` / `MASK` / classification obligations** — Data modification scopes and redaction; deferred.
- **`(:Tenant)`, `(:ApiKey)`, `(:ServiceAccount)`, `(:KeyGrant)` catalog objects** — Additional principal types and their authorization models; deferred to later phases.

## Fail-open site status

### Site #2: Graph-grant additive widening — **PARTIAL**

- **What changed**: Phase 4 introduces a real `(:Policy)` catalog as the new authoritative model for explicit access decisions.
- **What remains**: Legacy `graph_grant_check_fn` widening still active in `decide()` for back-compat with existing deployments.
- **Closing rationale**: The policy catalog now owns graph-level grant decisions. Phase 5 will migrate existing grants to Policy rows and disable legacy widening.
- **Commits**: `fb67fbb0` (catalog), `13d99fd0` (DDL), `c2832c26` (persistence), `c3c62059` (evaluation).

### Site #3: RLS no-policy default-allow — **PARTIAL**

- **What changed**: Phase 4 introduces explicit policy evaluation. The policy *layer* is fail-closed: no policy match → no allow from the policy layer.
- **What remains**: The row-level RLS engine still returns rows when no `Policy` applies in its scope — that's by design (backward compat with pre-policy row access).
- **Closing rationale**: The policy *catalog* is fail-closed. The row *engine* default is deferred pending Phase 5+ expression compilation, which can override per-policy. Policies themselves own "allow by absence" configuration.
- **Design note**: This layering is intentional: policies are an opt-in *overlay* on existing row access; they don't retroactively deny pre-existing data.

## CANARY markers landed in Phase 4

- **`REQ-GPS-PDP-008`** (AuthRoleGraphLookupIsolated) — Coverage gap from Phase 3 closed; isolated unit test verifies HAS_ROLE traversal.
- **`REQ-GPS-CATALOG-001`** — In-memory catalog operations (add/list/remove/lookup).
- **`REQ-GPS-CATALOG-002`** — Persistence module with HMAC chain synchronization.
- **`REQ-GPS-DDL-001`** — Parser, AST, and DDL dispatch for CREATE/DROP/SHOW POLICY.
- **`REQ-GPS-DDL-002`** — Hydration at server startup (loading persisted policies).
- **`REQ-GPS-POLICY-EVAL-001`** — `decide()` policy evaluation (literal "true" support).

## Phase 5 handoff

1. **Compile `expression_source` through RLS VM** — Replace hardcoded `"true"` with real bytecode evaluation.
2. **ABAC predicates + attribute map plumbing** — Thread principal attributes (tenant, user, roles, context) for predicate evaluation.
3. **Procedure registry mandatory EXECUTE_PROCEDURE decision** — Close fail-open site #5.
4. **MCP per-caller principal threading** — Close fail-open site #8.
5. **FLE explicit DECRYPT_FIELD / UNWRAP_KEY actions** — Close fail-open site #9.
6. **Migration tooling** — Script to convert legacy `graph_grant_check_fn` results to Policy rows.
7. **`ALTER POLICY` support** — Mutation and re-persistence.
8. **`EXPLAIN POLICY`** — Tracing and debugging.

## Implementation notes

### PolicyCatalog design

- Keyed by policy name (string).
- Stores `{name, expression_source, description, created_at, modified_at}`.
- WriteThroughHooks enable external audit/persistence without blocking the critical path.
- Lookup is O(1) in-memory; persistence is handled asynchronously by the hook.

### Persistence layer

- Mirrors `auth_graph_manager`: Policy nodes are stored in `__geode_security` graph with property `policy_data_json`.
- HMAC chain integrity (properties set in order, no gaps).
- Hydration at startup reads all `(:Policy)` nodes and reconstructs the catalog.
- Write-through hooks serialize Policy → node, persist to `__geode_security`, verify HMAC.

### `decide()` integration

- Policy evaluation happens *after* builtin-role and graph-grant checks.
- If a policy matches the query binding (e.g., `ON GRAPH *` for a `match` query), the decision is `.allow` with reason `policy_match`.
- If no policy matches, the decision falls through to legacy graph-grant widening (for now).
- Future: replace legacy widening with explicit deny.

### Backward compatibility

- Existing deployments without `CREATE POLICY` statements continue to work (empty catalog, no policy-layer filtering).
- Legacy `graph_grant_check_fn` widening remains active during Phase 4 to ensure seamless upgrade.
- Phase 5 migration tooling will convert grants to Policy rows; Phase 6+ can disable legacy widening.

---

**Closing commit**: `40e0f151` (fail-open sites #2 and #3 marked PARTIAL)  
**GPS Phase 4 status**: Complete (DDL, catalog, persistence, evaluation)  
**Next**: Phase 5 — Real expression compilation and Phase 5 handoff items.
