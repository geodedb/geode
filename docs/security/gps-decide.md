# GPS Phase 2 — `decide()` API Outcome

## What landed in Phase 2

`src/security/gps.zig` defines the central `decide()` entry point together
with the supporting types: `Action`, `ResourceRef`, `DecisionRequest`,
`PolicyDecisionKind`, `PolicyDecision`, `Obligation`, and `AuditFields`.

`src/security/principal_derive.zig` introduces `derivePrincipal()`, a
transport-agnostic helper that builds a `Principal` from a `DeriveArgs` struct.
All three transport sites (QUIC, gRPC, distributed coordinator) now call
`derivePrincipal()` instead of each constructing a `Principal` literal
independently.

`execution.checkPermission()` is now a thin adapter: it builds a
`DecisionRequest` from the `ExecutionContext` and delegates to `decide()`.
The function body no longer contains any authorization logic of its own.

The two direct `user_mgmt.hasPermission()` calls in
`src/transport/grpc_server.zig` (formerly at lines 1506 and 2077) have been
replaced with `gps.decide()` calls.

## Evaluation order inside `decide()`

`decide()` follows a deterministic, short-circuiting evaluation sequence:

1. **Insecure-allow-all gate** — if `--insecure-allow-all` was passed at
   server startup, return `.allow` immediately with `reason_code =
   "insecure_allow_all"`. This is the ONLY fast-path allow.
2. **Authentication check** — if `principal.username == null`, return
   `.unauthenticated`.
3. **Builtin-role grant** — map `principal.roles[]` → `Role` enum, call
   `user_management.hasPermission(role, permission)`. Return `.allow` if
   any role permits the action.
4. **Graph-grant widening** — if the builtin-role check produced a deny AND
   the principal has a non-null `active_graph`, consult
   `multi_graph_security.graph_grant_check_fn`. Return `.allow` if the
   graph grant widens the permission. (Phase 4 will replace this with
   first-class `Policy` rows.)
5. **Default deny** — return `.deny` with `reason_code = "no_matching_grant"`.

## What did NOT change (bit-identical outcomes)

Every pre-Phase-2 allow/deny outcome is preserved for authenticated sessions:

- Admin, User, ReadWrite, ReadOnly — all four builtin roles produce identical
  outcomes for Read, Write, and Schema permissions.
- Per-graph grants (GRANT WRITE ON GRAPH hr) continue to widen access
  additively. No deny grants exist in Phase 2.
- The `checkPermission` caller interface (`!void`) is unchanged; callers that
  received `error.Unauthorized` or `error.Unauthenticated` before continue to
  receive the same errors.

## What intentionally changed (the two fail-closed conversions)

### Site #1 — Auth-disabled implicit allow (partial closure)

Previously, `checkPermission` returned `void` (allow) when
`user_mgmt.isAuthEnabled()` returned `false`. In Phase 2, `decide()` has NO
implicit allow path. The `--insecure-allow-all` flag at server startup is
the only explicit bypass.

A legacy compatibility shim in `checkPermission` (CANARY `STATUS=EXEMPT`,
`ASPECT=FailOpenInterim`) preserves the `!isAuthEnabled()` short-circuit for
existing CLI/test fixtures that do not pass `--insecure-allow-all`. Phase 3
will remove this shim and require the explicit flag.

**Closure status:** partially closed. The `decide()` code path is fully
fail-closed; the `checkPermission` shim remains for compatibility.
Closing commit: `36742374`.

### Site #4 — RLS VM no-result implicit allow (fully closed)

Previously, when the RLS expression VM produced no Boolean result (because the
policy expression had no reachable exit path), the row was returned. This was a
fail-open default. In Phase 2, the VM returns `error.IndeterminatePolicy` and
`decide()` maps this to `.deny` with `reason_code = "rls_indeterminate"`.

The CANARY on this site (`src/security/rls_core.zig:1366`) has been updated
to `STATUS=COMPLETE`. Closing commit: `234e7e9d`.

## `--insecure-allow-all` compatibility mode

`gps.setInsecureAllowAll(true)` / `gps.isInsecureAllowAll()` are the runtime
accessors. `src/server/cli_args.zig` parses `--insecure-allow-all` and calls
`setInsecureAllowAll(true)` at startup, emitting a `WARN` log line. This flag
is intended exclusively for development environments and must NEVER be set in
production. It is NOT the same as "auth disabled" — it bypasses authorization
but does not disable authentication.

## `resolveRoleFromGraph` — auth cache and HAS_ROLE edge lookup

Phase 2 also closed a role-resolution bug affecting the QUIC auth cache. When
a user is created via GQL DDL (`CREATE USER ... ROLE readonly`), the internal
`writerCreateUser` path bumps `auth_version` in the `__geode_security` graph.
On the next QUIC connection, `refreshCachedUserIfStale` detects the version
mismatch and re-fetches from persistent storage via `lookupPersistentAuthUser`.

Previously, `duplicatePersistentUser` called `authRoleFromRecord` which only
checked `is_superuser` and always returned `.ReadWrite` for non-admin users,
discarding the role that was persisted as a HAS_ROLE edge in the security graph.

`resolveRoleFromGraph` (in `src/server/main.zig`) now traverses the
`__geode_security` graph: it finds the `User` node by `username`, follows
outgoing `HAS_ROLE` edges, reads the `name` property of each target `Role`
node, and maps it through `Role.fromString()`. The fallback is the legacy
`authRoleFromRecord` behavior. Closing commit: `6a307cf0`.

## How to call `decide()` in new code (Phase 2+)

```zig
const gps = @import("security/gps.zig");

const req = gps.DecisionRequest{
    .principal = principal_ptr,   // *const principal.Principal
    .action = .write,             // gps.Action
    .resource = .{ .graph = "hr" }, // gps.ResourceRef
};
const decision = try gps.decide(allocator, &req);
switch (decision.kind) {
    .allow => {},
    .unauthenticated => return error.Unauthenticated,
    else => return error.Unauthorized,
}
```

`decision.cacheable` is `false` for all Phase 2 decisions. Phase 7 will
introduce a decision cache keyed by `(principal.auth_version, policy_version,
action, resource_id)`.

## Fail-open sites remaining open after Phase 2

Sites #2, #3, #5, #6, #7, #8, #9 remain open as documented in
`docs/security/gps-fail-open-sites.md`. Phase 3+ will close them per the
schedule in that document.

## Unit test coverage

`tests/test_gps_decide.zig` — covers:

- `PolicyDecisionKind` distinctness
- `decide()` with empty Principal → unauthenticated
- Builtin-role grant table (Admin/User/ReadWrite/ReadOnly × Read/Write/Schema)
- Graph-grant widening (ReadOnly + GRANT WRITE ON GRAPH hr)
- `checkPermission` / `decide()` parity across all 4 roles × 2 permissions

`tests/test_gps_principal_derive.zig` — covers `derivePrincipal()` for QUIC
and anonymous inputs.

Black-box spec: `../geode-test-harness/geodetestlab-cli/specs/gps_decide_smoke.yml`
— proves the wire-level deny outcome (SQLSTATE 42501) for a ReadOnly user
attempting CREATE is identical to the pre-Phase-2 behavior.

## Known coverage gap: `resolveRoleFromGraph` (REQ-GPS-PDP-008)

`resolveRoleFromGraph` in `src/server/main.zig` (added in Phase 2, commit
`6a307cf0`) traverses HAS_ROLE edges in the `__geode_security` graph to map
a `UserRecord` to the correct `Role` enum, correcting the pre-GPS fallback
that always returned `.ReadWrite` for non-superusers.

**Why an isolated unit test is blocked:**

`src/server/main.zig` is a binary entry file (`geode_exe` in `build.zig`),
not a library module. The file carries heavy binary-only dependencies:
QUIC transport, gRPC server, LSP server, cert generator, metrics server,
thread pool, and multiple named modules that are only wired for `geode_exe`
(e.g. `index_selectivity`, `text_formatter`, `otel_metrics`, `txn`). There
is no named module wrapper for `src/server/main.zig` accessible to a
standalone test executable.

Moving the function to a library module (e.g. `src/security/role_resolver.zig`
re-exported through `src/lib.zig`) would make it testable in isolation, but
that refactor is a Phase 4+ concern because it touches the auth startup path.

**Existing indirect coverage:**

- `tests/test_user_management.zig` — exercises `createUser` / `assignRole` /
  `lookupUser` round-trips through the in-memory user store, verifying that
  role assignment survives a reload.
- `tests/test_gps_principal_derive.zig` — verifies that `derivePrincipal()`
  correctly populates `Principal.roles` from the resolved `User.role`.
- The integration suite in `../geode-test-harness/` covers the full
  QUIC auth path: a user created with `CREATE USER … ROLE ReadOnly` is denied
  `CREATE GRAPH` at the wire level, exercising `resolveRoleFromGraph` →
  `duplicatePersistentUser` → `lookupPersistentAuthUser` → `derivePrincipal`
  → `decide()` end-to-end.

**Remediation plan:** In Phase 4, extract `resolveRoleFromGraph` (and
`authRoleFromRecord`) into `src/security/role_resolver.zig`, add a named
module entry in `build.zig`, and add `tests/test_gps_resolve_role_from_graph.zig`
with an in-memory `GraphStore` fixture (User node + HAS_ROLE edge + Role node).
Tag the new test with `CANARY: REQ=REQ-GPS-PDP-008; ASPECT=AuthRoleGraphLookupIsolated`.
