# Gap Closure Journal — 2026-06-09 register

Append-only log of closed gaps from the 2026-06-09 gap register
(`docs/GAP_ANALYSIS.md`). One line per closed gap: `GAP-XXXX — <status> — commit <sha> — <summary>`.

GAP-0854 — closed — commit 91b2a7a2 — FLE configureField no longer corrupts the auth HMAC chain: the internal `__geode_security` graph is excluded from FLE encrypt/decrypt (`isSecurityGraphName`, src/graph_store.zig); restart regression `tests/test_gap0854_fle_chain.zig` (`zig build test-gap0854`).
