# GPS Phase 0 — Fail-Open Sites Catalog

> Every place in `main` (as of 2026-05-20) where the current code returns an
> "allow" decision in the absence of explicit policy evidence. GPS Phase 2+
> will replace these with `decide()` calls that fail closed at the policy
> layer; until then, this list IS the documented set of compatibility-mode
> exceptions. Do not add new entries without updating this file.
>
> **Legend:** OPEN = still fail-open; PARTIAL = decide() is closed but a
> compatibility shim remains in checkPermission(); CLOSED = fully closed.

| # | Site | File:Line | Current behavior | Documented reason | GPS replacement | Status |
|---|------|-----------|------------------|-------------------|--------------------|--------|
| 1 | Auth-disabled early return | `src/execution.zig:842` | Returns `void` (allow) when `user_mgmt.isAuthEnabled()` is false. | Developer-mode default; CLAUDE.md says production enables auth (fail-closed). | Phase 2: moved behind explicit `--insecure-allow-all` flag (`decide()` has no implicit allow). A legacy shim in `checkPermission` stays for compat until Phase 3. Closing commit: `36742374`. | **PARTIAL** |
| 2 | Graph-grant additive widening | `src/execution.zig` (inside `decide()`) | When the builtin role check fails, an additive grant on the currently bound graph *widens* access. No deny semantics. | Compatibility for the original per-graph `GRANT … ON GRAPH …` model. | Phase 4: real `(:Policy)` catalog now the authoritative model. Legacy widening still active in `decide()` for back-compat. Phase 5 migrates existing grants to Policy rows. Closing commits: `fb67fbb0`, `13d99fd0`, `c2832c26`, `c3c62059`. | **PARTIAL** |
| 3 | RLS no-policy default-allow | `src/security/rls_core.zig:1083` `checkRowAccessByUsername` | When the policy set for a label is empty, the row is returned. | Backwards compatibility with pre-RLS data. | Phase 4: policy *layer* is fail-closed (no policy match → no allow from this layer). The row-level RLS engine still returns rows when no policies match in its scope — that's by design (row engine layer is permit-by-default for backward compat). Policy catalog owns explicit "allow by absence" configuration. Phase 5 enables real expression compilation to override per-policy. | **PARTIAL** |
| 4 | RLS VM no-result default-allow | `src/security/rls_core.zig:1366` | ~~When the expression VM produces no Boolean result, the row is returned.~~ Now returns `error.IndeterminatePolicy`; mapped to `deny` in `decide()`. | Defensive default during VM development. | Phase 2: **CLOSED**. Closing commit: `234e7e9d`. CANARY STATUS=COMPLETE. | **CLOSED** |
| 5 | Procedure registry skips classifier | `src/execution/procedure_registry.zig:105` | Dispatch executes any registered procedure without consulting `procedure_access.zig`. | The classifier was added later and the wiring was deferred. | Phase 5: mandatory `EXECUTE_PROCEDURE` decision before dispatch. | OPEN |
| 6 | Metadata procedures enumerate globally | `src/execution/meta_dispatch.zig:41` for `db.labels`/`db.relationshipTypes`/`db.propertyKeys` | Returns the union of all labels/types/keys across tenants and graphs. | Pre-multi-tenant API surface. | Phase 3: `executeDbLabels`, `executeDbRelationshipTypes`, `executeDbPropertyKeys` each filter by `ctx.tenant_id`; null tenant (admin path) still sees all. Closing commits: `7246449e` (db.labels), `c46ab43f` (db.relationshipTypes), `1a295c30` (db.propertyKeys). CANARY STATUS=TESTED in `tests/test_gps_metadata_filtering.zig`. | **CLOSED** |
| 7 | `SHOW GRAPHS` is global | `src/execution/statement_handlers.zig` (the `SHOW GRAPHS` case) | Lists every graph the server knows about. | Same as #6. | Phase 3: `executeShow` for `.graphs` now calls `gps.decide(.bind_graph)` per graph and omits graphs where the principal is denied; null principal retains legacy compat (all graphs returned). Closing commit: `fd7586da`. CANARY STATUS=TESTED in `tests/test_gps_metadata_filtering.zig`. | **CLOSED** |
| 8 | MCP boundary bearer-only | `src/mcp/server.zig` token check (server-wide) | A single bearer token authenticates the whole server; tool calls then use a generic client path with no per-caller principal. | MCP started as a single-tenant developer aid. | Phase 5: per-caller Principal threaded through MCP tools; LSP metadata filtered. | OPEN |
| 9 | FLE decryption gated by hook-local role check | `src/execution/fle_hooks.zig` decrypt path | Decryption authorized by current thread tenant + current user role; on failure returns `[REDACTED]`. | Original FLE design pre-dates GPS. | Phase 5: `DECRYPT_FIELD` and `UNWRAP_KEY` are explicit GPS actions. | OPEN |

## Invariant: no new entries without docs

Any PR that introduces a new "absence implies allow" behavior must add a row
here, with a reviewer-named GPS phase that will close it. A future CI hook
(out of scope for Phase 0) may fail the build if this table shrinks without a
matching `CANARY: REQ=REQ-GPS-INVARIANT-001` removal in the source.
