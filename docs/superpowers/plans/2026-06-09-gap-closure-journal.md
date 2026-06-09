# Gap Closure Journal — 2026-06-09 register

Append-only log of closed gaps from the 2026-06-09 gap register
(`docs/GAP_ANALYSIS.md`). One line per closed gap: `GAP-XXXX — <status> — commit <sha> — <summary>`.

GAP-0854 — closed — commit 15adb1ed — FLE configureField no longer corrupts the auth HMAC chain: the internal `__geode_security` graph is excluded from FLE encrypt/decrypt (`isSecurityGraphName`, src/graph_store.zig); restart regression `tests/test_gap0854_fle_chain.zig` (`zig build test-gap0854`).

GAP-0818 — closed — commit 38629a56 — LspContext { tenant_id, user_id, session_id } threaded through provideCompletion/provideHover/provideDefinition with a per-provider tenant gate (schemaTenantMatches); cross-tenant leak regression in tests/test_gap0818_lsp_context.zig (zig build test-gap0818), proven red→green.
