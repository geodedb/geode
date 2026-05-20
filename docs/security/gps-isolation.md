# GPS Phase 3 — Tenant + Graph Non-Bypassable Enforcement

## What landed in Phase 3

- **`Action.bind_graph`** evaluated in `decide()`: Admin always allowed; non-admin requires a Read grant on the target graph via `graph_grant_check_fn`. Codified in `src/security/gps.zig`.
- **`USE GRAPH` gated**: `src/execution.zig` `.UseGraph` branch calls `gps.decide(.bind_graph)` before switching when a Principal is attached. Legacy/test paths without a Principal preserve current behavior.
- **`Action.show_metadata`** evaluated in `decide()`: always allowed for authenticated principals; filtering happens row-by-row downstream.
- **`db.labels()` / `db.relationshipTypes()` / `db.propertyKeys()`** filter by `ctx.tenant_id`. Admin with null tenant still sees everything; tenant-bound users see only their tenant.
- **`SHOW GRAPHS`** filters by `decide(.bind_graph)` per graph.
- **`SHOW INDEXES` / `SHOW CONSTRAINTS`** filter by tenant.

## What did NOT change in Phase 3

- The compatibility behavior when `ExecutionContext.principal == null`: `USE GRAPH` and metadata handlers continue to operate without the new gates. This preserves legacy/test paths and is appropriate for Phase 3.
- The `--insecure-allow-all` flag continues to short-circuit `decide()` regardless of metadata or graph state.
- The set of legacy fail-open sites #2, #3, #5, #8, #9. Those are Phase 4+ territory.

## Fail-open sites closed

- **Site #6** (metadata procedures enumerate globally) — CLOSED. Commits: 7246449e, c46ab43f, 1a295c30.
- **Site #7** (SHOW GRAPHS global) — CLOSED. Commit: fd7586da.

See `gps-fail-open-sites.md` for the up-to-date catalog.

## Compatibility note

The `meta_dispatch.execute` API now requires `ctx.tenant_id` and (optionally) `ctx.principal.active_graph` to produce filtered results. Callers that pass an empty ExecutionContext (`{.catalog = catalog}`) will get the unfiltered admin view — this matches pre-Phase-3 behavior bit-identically.

## Phase 4 handoff

Phase 4 introduces real policy DDL (`CREATE POLICY`, `ALTER POLICY`, `DROP POLICY`) and a persistent catalog in `__geode_security`. The Phase 3 actions (`bind_graph`, `show_metadata`) and Phase 2's bit-identical legacy preservation form the substrate on which DDL-driven policies will compose.

Phase 4 will also close the documented `resolveRoleFromGraph` coverage gap by extracting it from `src/server/main.zig` into a testable `src/security/role_resolver.zig` module.

## CANARY governance markers landed in Phase 3

- `REQ-GPS-BIND-001` — bind_graph evaluation (admin path + grant widening)
- `REQ-GPS-BIND-002` — USE GRAPH gating
- `REQ-GPS-METADATA-000` — show_metadata action + db.* context threading
- `REQ-GPS-METADATA-001` — db.labels filter
- `REQ-GPS-METADATA-002` — SHOW GRAPHS filter
- `REQ-GPS-METADATA-003` — SHOW INDEXES filter
- `REQ-GPS-METADATA-004` — SHOW CONSTRAINTS filter
- `REQ-GPS-METADATA-005` — comprehensive cross-tenant E2E
