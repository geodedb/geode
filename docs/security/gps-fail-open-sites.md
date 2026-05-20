# GPS Phase 0 — Fail-Open Sites Catalog

> Every place in `main` (as of 2026-05-20) where the current code returns an
> "allow" decision in the absence of explicit policy evidence. GPS Phase 2+
> will replace these with `decide()` calls that fail closed at the policy
> layer; until then, this list IS the documented set of compatibility-mode
> exceptions. Do not add new entries without updating this file.

| # | Site | File:Line | Current behavior | Documented reason | Eventual GPS replacement |
|---|------|-----------|------------------|-------------------|--------------------------|
| 1 | Auth-disabled early return | `src/execution.zig:831` | Returns `void` (allow) when `user_mgmt.isAuthEnabled()` is false. | Developer-mode default; CLAUDE.md says production enables auth (fail-closed). | Phase 2: move behind explicit `--insecure-allow-all` flag; `decide()` never has an implicit allow path. |
| 2 | Graph-grant additive widening | `src/execution.zig:845` | When the builtin role check fails, an additive grant on the currently bound graph *widens* access. No deny semantics. | Compatibility for the original per-graph `GRANT … ON GRAPH …` model. | Phase 4: grants become first-class `Policy` rows with explicit allow/deny scopes. |
| 3 | RLS no-policy default-allow | `src/security/rls_core.zig:1065` `checkRowAccessByUsername` | When the policy set for a label is empty, the row is returned. | Backwards compatibility with pre-RLS data. | Phase 4: the policy layer is fail-closed; the row engine still returns rows when no `Policy` applies, but the policy catalog itself owns "allow by absence" only when explicitly configured. |
| 4 | RLS VM no-result default-allow | `src/security/rls_core.zig` (VM evaluation around line 1363 per `geode-policy-plan.md`) | When the expression VM produces no Boolean result, the row is returned. | Defensive default during VM development. | Phase 2: VM returns `error.IndeterminatePolicy`; `decide()` maps that to `deny` with a distinct reason code. |
| 5 | Procedure registry skips classifier | `src/execution/procedure_registry.zig:94` | Dispatch executes any registered procedure without consulting `procedure_access.zig`. | The classifier was added later and the wiring was deferred. | Phase 5: mandatory `EXECUTE_PROCEDURE` decision before dispatch. |
| 6 | Metadata procedures enumerate globally | `src/execution/meta_dispatch.zig:41` for `db.labels`/`db.relationshipTypes`/`db.propertyKeys` | Returns the union of all labels/types/keys across tenants and graphs. | Pre-multi-tenant API surface. | Phase 5: routed through `SHOW_METADATA` decision with per-row filtering. |
| 7 | `SHOW GRAPHS` is global | `src/execution/statement_handlers.zig` (the `SHOW GRAPHS` case) | Lists every graph the server knows about. | Same as #6. | Phase 5: filter by what the principal can `BIND_GRAPH`. |
| 8 | MCP boundary bearer-only | `src/mcp/server.zig` token check (server-wide) | A single bearer token authenticates the whole server; tool calls then use a generic client path with no per-caller principal. | MCP started as a single-tenant developer aid. | Phase 5: per-caller Principal threaded through MCP tools; LSP metadata filtered. |
| 9 | FLE decryption gated by hook-local role check | `src/execution/fle_hooks.zig` decrypt path | Decryption authorized by current thread tenant + current user role; on failure returns `[REDACTED]`. | Original FLE design pre-dates GPS. | Phase 5: `DECRYPT_FIELD` and `UNWRAP_KEY` are explicit GPS actions. |

## Invariant: no new entries without docs

Any PR that introduces a new "absence implies allow" behavior must add a row
here, with a reviewer-named GPS phase that will close it. A future CI hook
(out of scope for Phase 0) may fail the build if this table shrinks without a
matching `CANARY: REQ=REQ-GPS-INVARIANT-001` removal in the source.
