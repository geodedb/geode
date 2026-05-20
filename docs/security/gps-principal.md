# GPS Phase 1 — Canonical Principal

## What landed in Phase 1

`src/security/principal.zig` defines the canonical `Principal` type and a
`Principal.fromAuthState()` builder. `ExecutionContext` (in `src/execution.zig`)
gained an optional `principal: ?*const Principal = null` field. The three
production transports — QUIC (`src/server/quic_connection_handler.zig:3242`),
gRPC (`src/transport/grpc_server.zig:1959`), and the distributed coordinator
(`src/distributed/query_coordinator.zig:357`) — each construct a Principal
exactly once at the request boundary and assign it to the execution context.

## What did NOT change in Phase 1

- `checkPermission()` does not read `ExecutionContext.principal`.
- `rls_core.checkRowAccessByUsername` does not read `ExecutionContext.principal`.
- No new procedure, statement, or DDL consumes the principal.
- All existing tests pass with `principal: ?*const Principal = null`.

Phase 1 is intentionally a no-op for runtime authorization. It exists so that
Phase 2 (the `decide()` API) and every later phase can rely on a single, typed
principal arriving at every PEP without re-deriving it from `user`, `role`,
`tenant_id`, and `session_state` separately.

## Compatibility

The MCP and LSP paths funnel through QUIC and do not construct their own
`ExecutionContext`, so they inherit the principal from the QUIC handler
without any new code in Phase 1. Per-caller principal threading inside MCP
tools is a Phase 5 concern.

## How to read the principal in new code (Phase 2+)

```zig
const ctx = execution.getActiveContext() orelse return error.NoActiveContext;
if (ctx.principal) |p| {
    // Phase 2+: pass p to gps.decide()
    _ = p;
}
```

In Phase 2 every `decide()` call MUST receive a non-null `*const Principal`.
The Phase 0 invariants doc (`docs/security/gps-invariants.md`) lists the
single compatibility-mode exception (auth disabled in development).

## Phase 1 deviations from the plan worth noting

- The plan suggested `@import("../security/principal.zig")` for transport-
  side construction sites. Zig rejected this where the file is reachable via
  the `geode` module root; QUIC and gRPC use `geode.security.principal`
  instead. `src/distributed/query_coordinator.zig` uses
  `@import("../security/principal.zig")` because it is not reachable via
  the `geode` module.
- The optional black-box smoke spec in `../geode-test-harness/` was skipped
  because (a) the actual harness spec format differs significantly from
  what the plan prescribed, and (b) the in-process Zig test in
  `tests/test_gps_principal_propagation.zig` already covers the
  propagation invariant the spec was intended to verify.

## CANARY governance markers landed

- `REQ-GPS-INVARIANT-001` — 5 markers on documented fail-open sites
  (`STATUS=EXEMPT`).
- `REQ-GPS-PRINCIPAL-001` — Principal type and `empty()` constructor.
- `REQ-GPS-PRINCIPAL-002` — `Principal.fromAuthState()` builder.
- `REQ-GPS-PRINCIPAL-003` — `ExecutionContext.principal` field.
- `REQ-GPS-PRINCIPAL-004` — QUIC handler wiring.
- `REQ-GPS-PRINCIPAL-005` — gRPC handler wiring.
- `REQ-GPS-PRINCIPAL-006` — distributed coordinator wiring AND propagation
  test. (Two `ASPECT=` variants share this REQ.)

## Phase 2 audit: src/execution/call_operations.zig:145

Audit outcome (2026-05-20): the `ExecutionContext{ .catalog = catalog }` literal
at this line is **test-only**. It lives entirely inside the Zig test block
`test "executeCallStatement routes read-only procedures through QueryReadSession"`
(line 111–154). Production paths construct their `ExecutionContext` — and the
`principal` it carries — at the transport boundary (QUIC, gRPC, distributed
coordinator). No principal threading is required here; the comment added at the
call site documents this for future readers.
