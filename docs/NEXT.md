# NEXT — ISO‑GQL alignment (execution‑ready backlog)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting). Idempotent across runs.

Note: Completed items move to docs/IMPLEMENTED.md.

Build/test status snapshot
- zig build --release=safe: OK (Zig 0.14.1 toolchain observed)
- zig build test: OK; unit tests run; temporal formatting logs seen
- Binaries present (geoded/geodec stubs), protocol not yet wired

## Now (P0)

1. Protocol skeleton and CLI round‑trip
- Why: Unblocks end‑to‑end tests and conformance surfacing; foundation for sessions/transactions.
- What: Implement minimal binary protocol (docs/BINARY_PROTOCOL.md): HELLO, RUN_GQL, PULL; JSON Lines payloads; status_class/subclass; SCHEMA then BINDINGS with ordered flag + order_keys. Provide geoded server loop (TCP, framed) and geodec CLI that prints exact JSON required by tests.
- Acceptance (aligns with tests/e2e_protocol.zig):
  - RETURN 1 AS x ORDER BY x LIMIT 1 → exact two JSON lines (SCHEMA then ordered BINDINGS)
  - RETURN 1 LIMIT 10 OFFSET 5 → exit 2; stderr contains "US001" and anchor 16.18–16.19
  - RETURN a ORDER BY f(a) → exit 2; stderr contains "IllegalOrderKey" and anchor 14.10
  - RETURN 1 AS x UNION RETURN 1 AS x → BINDINGS with ordered=false and rows [{"x":1}]
  - CASE 3VL sanity per acceptance list
- ISO anchors: 14.10; 16.18–16.19; 23.2; 24.*
- Dependencies: diagnostics surface in src/diagnostics.zig; evaluator and planner helpers exist
- Scope: M • DRI: core

2. README troubleshooting section
- Why: Document codes for users and conformance reviewers.
- What: Add concise Codes table (US001, GroupByIllegal, IllegalOrderKey, TypeMismatch) with anchors and examples.
- Acceptance: README contains the table; linked from GAP_ANALYSIS.md.
- ISO anchors: 23.2; 24.*
- Scope: S • DRI: core

## Next (P1)

1. Planner/exec coverage hardening
- Why: Ensure ordered semantics and pagination are correct across expressions, aliases/ordinals, set ops, and aggregates.
- What: Multi-key ORDER metadata; ORDER BY over aliases/ordinals; set op then ORDER+LIMIT semantics; GROUP BY+HAVING+ORDER pipeline; US001 enforcement.
- Acceptance: E2E tests in tests/e2e_protocol_planner.zig and tests/e2e_protocol_more.zig pass; ordered/order_keys metadata correct; errors surface with ISO anchors.
- ISO anchors: 14.10; 14.12; 16.18–16.19
- Scope: M • DRI: core

2. Transaction demarcation (server only)
- Why: Align with ISO §8 and prepare for MVCC.
- What: BEGIN/COMMIT/ROLLBACK frames (no MVCC yet); per‑session state machine; wire outcomes and status codes.
- Acceptance: protocol tests for BEGIN/COMMIT/ROLLBACK happy path and rollback on error; session isolation at parser/eval level.
- ISO anchors: 8; 23.2; 24.*
- Scope: M • DRI: core

## Later (P2)

1. Storage engine baseline
- Why: Persistence and scalability.
- What: Slotted page layout, id allocators, CSR adjacency blocks, property heap; in‑process file; mmap or buffered IO.
- Acceptance: unit tests for page alloc/free, slot read/write, adjacency encode/decode; smoke benchmark ≥50k expands/sec (release, single node).
- ISO anchors: model §4; implementation policy in REQUIREMENTS.md §4
- Scope: L • DRI: storage

2. WAL/ARIES and recovery
- Why: Durability and crash safety.
- What: LSNs, log records (update/CLR/commit/abort), checkpoints, analysis→redo→undo; recovery driver.
- Acceptance: fault‑injection tests that recover committed changes and roll back uncommitted; page‑LSN assertions.
- ISO anchors: txn/durability cross‑refs; REQUIREMENTS.md §4
- Scope: L • DRI: storage

3. MVCC (SI) transactions
- Why: Correct isolation; prepare for DML.
- What: Version chains per record, snapshot reads, write locks for DML; protocol demarcation already present.
- Acceptance: visibility tests across concurrent sessions; phantom avoidance at SI scope.
- ISO anchors: §8
- Scope: L • DRI: core

4. Distributed scaffold (feature‑gated)
- Why: Future‑proofing interfaces.
- What: Leader‑only Raft stub, 2PC coordinator traits, shard map structures; no external net deps in tests.
- Acceptance: interface tests and no‑op stubs behind flags.
- Scope: L • DRI: dist

## Cutline
- Protocol/Server (HELLO/RUN_GQL/PULL) is the immediate gate for e2e.
- Transactions, Storage, WAL are next critical path to claim ACID.
- Distributed remains behind feature flags until single‑node ACID stabilizes.
