# GPS Phase 7 — Decision Cache, ALTER/SHOW/EXPLAIN, Wire Forwarding

## What landed

### Decision Cache (`src/security/decision_cache.zig`)

- Bounded LRU cache keyed by `(auth_version, policy_version, action_tag,
  resource_hash)`.
- Skip path: `auth_version = 0` bypasses the cache entirely (unauthenticated
  or `--insecure-allow-all` requests are never cached).
- Auto-invalidated on every policy catalog mutation (add/remove policy) via a
  hook in `policy_catalog.zig` that calls `decision_cache.invalidateAll()`.
- `ALTER POLICY` also bumps `policy_version` and invalidates the cache.
- Sub-µs lookups for cached decisions; LRU eviction prevents unbounded growth.
- CANARY: `REQ-GPS-CACHE-001` (commit `cd1c0524`)

### ALTER POLICY DDL (`src/security/policy_catalog.zig`, `src/gql/`)

- Syntax: `ALTER POLICY name SET ENABLED true|false`
- Parser (`src/gql/parser.zig`), AST node (`src/gql/ast.zig`), and executor
  (`src/execution.zig`, `src/execution/statement_handlers.zig`) all wired.
- Semantics: toggles the `enabled` flag on a Policy row, bumps `policy_version`,
  and invalidates the decision cache in one atomic sequence.
- Returns an error when the named policy does not exist.
- CANARY: `REQ-GPS-DDL-003` (commit `7e4f6cba`)

### SHOW GRANTS FOR `<user>` (`src/execution/statement_handlers.zig`)

- Syntax: `SHOW GRANTS FOR <username>`
- Enumerates policies from the catalog whose `expression_source` either
  references the given username as a subject OR is the unconditional literal
  `"true"` (universal policies).
- Phase 7 uses a text-match heuristic on `expression_source`; Phase 8+ may
  evaluate the compiled expression predicate directly.
- Returns columns: `policy_name`, `expression_source`, `enabled`.
- CANARY: `REQ-GPS-DDL-004` (commit `407c0d48`)

### EXPLAIN POLICY FOR `<inner_query>` (`src/execution/statement_handlers.zig`)

- Syntax: `EXPLAIN POLICY FOR <gql_statement>`
- Parses the inner query, classifies its top-level action via
  `classifyStatementAction()`, calls `gps.decide()` once with a synthetic
  resource derived from the inner query, and returns a single result row with
  `decision` and `reason_code`.
- Phase 7 emits one row per top-level statement; multi-action queries (e.g.
  `MATCH + DELETE`) get only the first classification. Multi-step EXPLAIN is
  deferred to Phase 8+.
- CANARY: `REQ-GPS-EXPLAIN-001` (commit `df719b7f`)

### MCP Wire-Level Principal Forwarding (`src/proto/schema.zig`, `src/server/quic_connection_handler.zig`)

- `ExecuteRequest` gains field 4 (`principal_envelope_bytes: []const u8`) in
  `src/proto/schema.zig`.
- Server-side unpack in `quic_connection_handler.zig`: when field 4 is present
  and non-empty, deserialize via `PrincipalEnvelope.deserialize()` and override
  connection identity with the envelope-supplied Principal. Malformed envelopes
  fall back silently to connection identity (fail-safe, not fail-open).
- MCP **send-side** remains PARTIAL: the external `geode-client-zig` package
  does not yet emit field 4. Requires a library release. MCP local pre-flight
  `decide()` calls in `server.zig` already use the correct per-caller Principal.
- CANARY: `REQ-GPS-WIRE-001` (commit `4e08ab5a`)

### Distributed Wire-Level Principal Forwarding (`src/distributed/query_transport.zig`)

- `NodeQuery` gains `principal_envelope_bytes` in the distributed schema;
  coordinator attaches the caller's envelope when dispatching sub-queries.
- `QueryOptions.principal_envelope_bytes` threads through
  `executeRemoteQuery()`, `batchQueries()`, and `connectionExecuteQuery()`.
- Worker side unpacks via the same `quic_connection_handler.zig` path and stamps
  `principal.source = .distributed_worker`.
- Distributed path is fully closed. Site #8 remains PARTIAL only on the
  MCP-client send side.
- CANARY: `REQ-GPS-WIRE-002` (commit `4e08ab5a`)

### Legacy `graph_grant_check_fn` Widening Removed (`src/security/gps.zig`)

- The additive graph-grant widening consumer inside `decide()` was removed.
  Phase 6 grant migration made it redundant: every legacy `(:GraphGrant)` record
  was converted to a `(:Policy)` row at startup.
- The `graph_grant_check_fn` function-pointer field itself remains in the struct
  for back-compat; only the widening consumer inside `decide()` is gone.
- CANARY: `REQ-GPS-PDP-003` (commit `b7125115`)

## CANARY ID corrections vs. plan

The task plan used provisional names. Actual IDs that shipped:

| Plan name | Actual ID | Rationale |
|---|---|---|
| REQ-GPS-ALTER-001 | REQ-GPS-DDL-003 | ALTER POLICY is the 3rd GPS DDL operation |
| REQ-GPS-SHOW-GRANTS-001 | REQ-GPS-DDL-004 | SHOW GRANTS FOR is the 4th GPS DDL operation |
| REQ-GPS-MCP-WIRE-001 | REQ-GPS-WIRE-001 | Unified under WIRE family (MCP + QUIC share schema field) |
| REQ-GPS-DIST-WIRE-001 | REQ-GPS-WIRE-002 | Unified under WIRE family (distributed coordinator/worker) |

## What did NOT change

- MCP send-side wire integration — blocked on `geode-client-zig` external
  package. Documented for Phase 8+.
- Persistence of ALTER POLICY mutations — in-memory only; restart loses ALTER
  state. Documented for Phase 8 (needs a write-through hook on
  `policy_persistence.zig`).
- Multi-step EXPLAIN POLICY — Phase 7 emits one row per top-level statement;
  compound queries get only the first classification.
- `principal.attributes.<deeper>` paths beyond Phase 6 single-level — deferred.

## Fail-open site final status

| Site | Description | Status |
|---|---|---|
| #1 | Auth-disabled early return | PARTIAL (by design — `--insecure-allow-all` is the canonical bypass) |
| #2 | Graph-grant additive widening | CLOSED via Phase 6 migration + Phase 7 widening removal (commit `b7125115`) |
| #3 | RLS no-policy default-allow | PARTIAL (row engine returns rows when no policies match, by design) |
| #4 | RLS VM no-result | CLOSED (Phase 2, commit `234e7e9d`) |
| #5 | Procedure classifier | CLOSED (Phase 5, commit `656710d0`) |
| #6 | Metadata global | CLOSED (Phase 3, commits `7246449e` / `c46ab43f` / `1a295c30`) |
| #7 | SHOW GRAPHS global | CLOSED (Phase 3, commit `fd7586da`) |
| #8 | MCP boundary | PARTIAL — distributed worker path closed in Phase 7; MCP-client send side blocked on external package |
| #9 | FLE hook-local | CLOSED (Phase 5, commit `c56f1d1a`) |

**7 CLOSED + 2 PARTIAL.** Sites #1 and #3 are PARTIAL by design (explicit
bypass flag and row-engine backward-compat respectively). Site #8 is PARTIAL
pending the external `geode-client-zig` package release.

## Phase 8+ handoff

- MCP send-side wire integration via `geode-client-zig` library update.
- ALTER POLICY persistence write-through to `__geode_security` graph.
- Multi-step EXPLAIN POLICY for compound queries.
- Remove the `graph_grant_check_fn` function-pointer field entirely (Phase 7
  only removed the widening consumer).
- Hashmap-backed `AttributeMap` for large attribute sets (current fixed-size
  array has a compile-time capacity cap).

## CANARY markers landed in Phase 7

- `REQ-GPS-CACHE-001` — decision cache (commit `cd1c0524`)
- `REQ-GPS-DDL-003` — ALTER POLICY DDL (commit `7e4f6cba`)
- `REQ-GPS-DDL-004` — SHOW GRANTS FOR (commit `407c0d48`)
- `REQ-GPS-EXPLAIN-001` — EXPLAIN POLICY FOR (commit `df719b7f`)
- `REQ-GPS-WIRE-001` — MCP/QUIC wire Principal field (commit `4e08ab5a`)
- `REQ-GPS-WIRE-002` — distributed wire Principal field (commit `4e08ab5a`)
- `REQ-GPS-PDP-003` — graph_grant_check_fn widening removed (commit `b7125115`)
