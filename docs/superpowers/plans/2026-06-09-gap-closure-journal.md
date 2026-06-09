# Gap Closure Journal — 2026-06-09 register

Append-only log of closed gaps from the 2026-06-09 gap register
(`docs/GAP_ANALYSIS.md`). One line per closed gap: `GAP-XXXX — <status> — commit <sha> — <summary>`.

GAP-0854 — closed — commit 15adb1ed — FLE configureField no longer corrupts the auth HMAC chain: the internal `__geode_security` graph is excluded from FLE encrypt/decrypt (`isSecurityGraphName`, src/graph_store.zig); restart regression `tests/test_gap0854_fle_chain.zig` (`zig build test-gap0854`).

GAP-0818 — closed — commit 38629a56 — LspContext { tenant_id, user_id, session_id } threaded through provideCompletion/provideHover/provideDefinition with a per-provider tenant gate (schemaTenantMatches); cross-tenant leak regression in tests/test_gap0818_lsp_context.zig (zig build test-gap0818), proven red→green.

GAP-0858 — closed — commit c67cd99b — Durable ALTER POLICY write-through to the HMAC-chained __geode_security graph: AuthGraphManager.alterPolicy re-persists under the same policy id (in-place :Policy node update — no stale old-name record on rename), recomputes the record HMAC, and reseals the chain; new AlterFn write-through hook wired in server_init.wireGpsPolicyHooks and called from the .AlterPolicy executor branch. Grammar extended with ALTER POLICY <name> RENAME TO <new_name> (alongside SET ENABLED). Restart regression tests/test_gap0858_alter_policy_persist.zig (zig build test-gap0858) asserts enable/disable + rename survive a simulated restart, verifyChain stays green, and no stale old-name record remains.
