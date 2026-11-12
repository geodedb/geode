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

`execution.checkPermission()` was then a thin adapter that built a
`DecisionRequest` from the `ExecutionContext` and delegated to `decide()`.
It never gained a caller and was removed in SONNY-2781; the handlers' gates
call `decide()` (see "What each action enforces").

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
fail-closed; the `checkPermission` shim remained for compatibility.
Closing commit: `36742374`. (SONNY-2781 removed `checkPermission`, shim
included: it had no callers.)

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

## Authentication disabled (SONNY-2782)

Authentication disabled (`user_management.setAuthEnabled(false)`) is the
in-process, single-user mode: embedders and tests. It is not a serving
mode. `geode serve` enables authentication at startup whatever its flags
(`src/server/main.zig`); its `--no-auth` is refused outside Debug builds
and, in a Debug build, logs a warning and leaves authentication enabled.
`--insecure-allow-all` is a different switch: authentication stays on and
`decide` allows everything (see above).

With authentication disabled, on every transport (QUIC and gRPC alike):

- no request is authenticated: a session has no user and no role;
- no request is authorized per user: the handlers authorize, and give the
  executor, no principal (`session_graph.requestPrincipal`), and with no
  principal every gate answers yes, as for an in-process caller: the
  handlers' write and read gates (`requestChangePermitted`,
  `requestReadPermitted`), graph binding and schema (`mayBind`,
  `maySchema`), the procedure gate, and the executor's admin gates (policy
  DDL, `geode.auth.*`, `geode.rls.*`, `geode.tenant.*`), which check
  `isAuthEnabled` themselves. Every request runs as if by an administrator;
- GPS policies (allow and deny), per-graph grants and roles are not
  consulted, and RLS policies that name a user have no user to apply to;
- `--insecure-allow-all` changes nothing;
- tenant scoping is unchanged: a session's `tenant_id` still scopes what it
  sees, and strict tenancy still refuses an unscoped request;
- the read-only request floor (`ExecuteRequest.read_only`) still refuses a
  change.

With authentication enabled both handlers gate every session through the
same functions, whatever its role (a session with none is refused). Before
SONNY-2782 the QUIC handler gated only a session with a role, and the gRPC
handler skipped its read gate likewise but ran its write gate for every
session, so with authentication disabled gRPC refused every change (42501:
`decide` answered `unauthenticated`) unless `--insecure-allow-all` was set,
while QUIC ran it; and both handed the executor an anonymous principal,
which refused DDL and changing procedures on both.

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

### Fail-closed default role (2026-10, breaking)

`authRoleFromRecord` returned `.ReadWrite` for every non-superuser, so a
user with no stored built-in role could read and write every graph. It now
returns `.None` ("none"), a role with no builtin permission. In `decide()`:

- `.None` grants nothing in the builtin-role step, and is neither `Admin`
  (no admin shortcuts) nor `ReadWrite` (no permissive single-tenant bind).
- Its graph access is its per-graph grants, which `decide()` reads for
  every principal (see "Per-graph grants" below).

The handlers' read gate, `session_graph.programReadPermitted` (read on every
graph the program touches, the `default` graph included, which `mayBind`
lets every authenticated user bind), applies to principals without global
Read, which is `.None`. Every other principal reads as before.

Write grants are not capped at read for `.None`: per-graph grants are
documented as additive over the global role (docs/GQL_AUTH_DDL.md), so a
WRITE grant works as granted. See
[GQL_AUTH_DDL.md](../GQL_AUTH_DDL.md#users-with-no-stored-role-fail-closed-default).
Regression: `tests/test_default_role_fail_closed.zig`.

### Per-graph grants (REQ-SEC-PER-GRAPH-GRANTS, 2026-10, security fix)

`GRANT READ|WRITE|SCHEMA ON GRAPH g TO u` allows that action on `g` only, for
every role, from the moment the GRANT returns; `REVOKE` takes it away just
as fast.

**What was wrong.** For a user with an explicit role:

- `decide()` read grants only through the `(:Policy)` rows
  `grant_migration.zig` wrote at startup (Phase 6/7). A runtime GRANT
  updated the live `GraphRBACPolicy`, which `decide()` consulted only for
  `bind_graph` (and, since the fail-closed default role, for users with no
  stored role), so a GRANT
  took effect only after a restart.
- The migrated row was scoped to the grant's graph, but the handlers' write
  gate was `writePermitted`, `decide(write, database)`, and a graph-scoped
  allow policy matched every non-graph resource. After a restart a WRITE
  grant on one graph allowed writes on every graph. Any `CREATE POLICY ...
  ON GRAPH g FOR WRITE` did the same.
- REVOKE removed the `(:GraphGrant)` but never the migrated row, so a grant
  a restart had migrated stayed in force.

**What `decide()` does now.**

1. After the builtin-role step, for an action a grant covers (READ:
   `read`/`match_`; WRITE: `write`/`create`/`update`/`delete`; SCHEMA:
   `schema`) on a resource in one graph (`.graph`, `.node`, `.edge`; not
   `*`), it asks the live grant table (`execution.graph_grant_check_fn`,
   `server_init.graphGrantCheck`) for that user, graph and action.
   `reason_code = "graph_grant"`. A builtin role still allows the action on
   every graph. A request on no graph in particular (the database, a
   tenant, a procedure, metadata, `*`) is never allowed by a grant.
2. Allow policies match resources by `policyCovers`: a policy scoped
   to `*` covers everything; one scoped to graph `g` covers `g` and its
   nodes and edges, and nothing else. Since SONNY-2753 deny policies match
   by the same rule (see "Policy scope").
3. A deny policy is evaluated before both, so it overrides a grant.

GRANT and REVOKE update the live table at once (`server_init.grantApply`,
`grantRevoke`) and bump the policy version, so no cached decision outlives
them. The table is guarded by a mutex: every request reads it now.

**Handler gates.** QUIC and gRPC gate a program that changes data on the
graph it changes (`lock_graph`), for every principal: originally
`gps.writePermittedOn`, `decide(write, graph)`; since SONNY-2781
`gps.changePermittedOn`, by the program's actions (see "What each action
enforces"). A self-locking CALL (which takes each graph's lock itself) goes
through the database-wide `writePermitted`. Schema DDL goes through
`session_graph.maySchema` (`decide(schema, graph)`), so a SCHEMA grant
counts there at once; `maySchemaDatabase` (index and constraint DDL) asks
for schema on `*`, which no grant gives.

**Restart.** Grants are hydrated from the `(:GraphGrant)` nodes into the
live table (`wireAuthDDLCallbacks`). They are no longer migrated to
Policy rows; `grant_migration.retireMigratedGrantPolicies` drops the
`auto_migrated_grant_*` rows earlier versions wrote, from the catalog and
from `__geode_security`, at every startup.

Regression: `tests/test_per_graph_grants.zig`
(`zig build test-per-graph-grants`) and `tests/test_gps_grant_migration.zig`.

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
- the handlers' read, write and schema gates follow the builtin role table
  for all 4 roles (it replaced the `checkPermission` / `decide()` parity
  test when SONNY-2781 removed `checkPermission`)

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

## Deny-effect policies (SONNY-2744)

A GPS policy's effect is `allow` or `deny`. Before SONNY-2744, `decide()`
skipped deny-effect policies when it scanned the catalog, and the builtin-role
check ran before the catalog anyway, so a deny never denied.

`decide()` now checks deny-effect policies right after the authentication
check, before every path that can allow:

1. `--insecure-allow-all` → allow. This is the one exception: the flag
   bypasses all authorization, deny policies included.
2. No principal → `.unauthenticated`.
3. **An enabled deny-effect policy whose action, resource and USING
   expression match → `.deny`, reason `policy_deny`.**
4. The special cases (Admin shortcuts, bind_graph, admin_tenant), the
   builtin roles and the allow policies, as before.

### What each action enforces (SONNY-2781)

Every action a policy can name is asked for by an enforcement point, so a
deny naming it takes effect, and an allow naming it allows exactly that. A
statement's actions come from the one write walk that also decides the
lock and the read-only floor (`write_walk.Actions`, `StatementPlan.actions`),
so "does it change anything" and "which action is it" cannot disagree.

| Policy action | Requests it matches (`policyMatchesAction`) | Where they are asked |
|---|---|---|
| `READ` | `read`, `match_` | the read gate; read-only `CALL`s |
| `MATCH` | `match_` | the read gate |
| `WRITE` (umbrella) | `write`, `create`, `update`, `delete` | the write gate |
| `CREATE` | `create` | the write gate |
| `UPDATE` | `update` | the write gate |
| `DELETE` | `delete` | the write gate |
| `SCHEMA` | `schema` | the write gate for DDL; the executor's DDL gates |
| `DECRYPT_FIELD` | `decrypt_field` | field-level decryption |
| `UNWRAP_KEY` | `unwrap_key` | nothing: a deny naming it is refused |

**The read gate** (`session_graph.programReadPermitted`, both handlers)
asks `decide(match_, g)` for every principal, on every graph `g` the
program touches (`query_traits.programReadGraphList`): every statement on
graph data, subqueries and UNION arms with it, the MATCH of a data change
included, a PROFILE's statement, and the statement an EXPLAIN plans (its
plan reports the graph's indexes and estimates). A builtin role with Read,
a READ grant on `g`, or an allow naming READ or MATCH on `g` passes it. A
program that reads no store (`RETURN 1`) or touches no graph data (a lone
`USE GRAPH`; the security DDL) passes. A data change passes it too, on the
graph it changes, since it reads that graph: an allow-only principal needs
READ (or MATCH) there as well as the change action. The gate skipped
`decide` for every principal whose builtin role holds Read, so a DENY READ
or DENY MATCH did not stop a plain MATCH.

**The write gate** (`gps.changePermittedOn`, both handlers, on the graph
the program changes) asks, by what the program does:

| Statement | Asks |
|---|---|
| `CREATE`, `INSERT`, `INSERT VALUE`, `MERGE` | `create` |
| `SET`, `REMOVE`, a `MERGE`'s `ON MATCH SET` (or bare `SET`) | `update` |
| `DELETE`, `DETACH DELETE` | `delete` |
| graph, graph type, schema, index, constraint DDL | `write` and `schema` |
| a `CALL` of a procedure that changes data, `BACKUP`, `RESTORE` | `write`, `create`, `update` and `delete` |

So a DENY CREATE stops CREATE, INSERT and MERGE (and their PROFILE) and
nothing else; a DENY UPDATE stops SET, REMOVE and a MERGE that updates; a
DENY DELETE stops DELETE; a DENY WRITE stops all of them and the DDL; a
change the engine cannot break down (a procedure, BACKUP, RESTORE) is
stopped by a deny of WRITE, CREATE, UPDATE or DELETE. An allow naming
CREATE (and READ for the read gate) lets a principal create and nothing
more; an allow naming WRITE allows every data change but not DDL, which also
needs SCHEMA. A builtin role with Write, and a per-graph WRITE grant, allow
create, update, delete and write. A self-locking CALL, which writes every
graph, is gated by `gps.writePermitted` (see "Policy scope").

**DDL** also passes the executor's gates: `session_graph.maySchema` asks
`decide(schema, g)` on the graph a CREATE / DROP GRAPH names or index /
constraint DDL runs on, and `maySchemaDatabase` asks schema on every graph
for index, constraint and CREATE / DROP SCHEMA DDL.

**Procedures** ask `read` (read-only) or `write` (changes data) on the
procedure (`gps.procedurePermitted`), besides the read and write gates on
the graph they run on.

**Not covered:** the security DDL (CREATE/ALTER/DROP USER, CREATE/DROP
ROLE, GRANT, REVOKE, CREATE/ALTER/DROP POLICY). It changes stored security
state, not graph data: a read-only request refuses it (SONNY-2751), but it
takes no graph lock and no write gate, and keeps its own Admin (or self)
check, so a DENY WRITE does not reach it.

**Refused:** a deny naming UNWRAP_KEY, which no enforcement point asks for,
is refused when it is added (`PolicyCatalog.addPolicy*`,
`error.PolicyActionNotEnforced`), in DDL and at startup hydration alike (a
stored record has no bit for it, so hydration never meets one). An allow
naming it grants nothing and is accepted.

bind_graph, admin_tenant, execute_procedure and show_metadata have no policy
analogue, so no policy names them. `execution.checkPermission`, which had no
callers, was removed. Regression:
`zig build test-sonny2781-gps-action-enforcement`.

### Policy scope (SONNY-2753)

Allow and deny policies cover resources by one rule (`policyCovers`):

- A policy scoped to `*` covers everything.
- A policy scoped to graph `g` covers `g` and the nodes and edges in it,
  and nothing else: not another graph, not `*`, and not a request on no
  graph in particular (the database, a tenant, a procedure as such,
  metadata).

Where a request runs or changes:

- **One graph** (the handlers' write gate on the graph a program changes,
  schema DDL on a graph, field decryption, which asks on the node in the
  graph being read): the policies of that graph and `*` decide.
- **A procedure**: the procedure is no one graph's resource, so only a `*`
  policy (or a builtin role) allows it; and a deny scoped to the graph the
  procedure runs on (the session's graph; the default graph for the
  fulltext procedures) refuses it (`gps.procedurePermitted`).
- **Every graph at once** (a self-locking procedure CALL,
  `gps.writePermitted`; index, constraint and schema DDL, catalogued
  database-wide, `session_graph.maySchemaDatabase` /
  `gps.schemaPermittedEverywhere`): only a `*` policy (or a builtin role)
  allows it, and a deny on any graph refuses it, since it changes that graph
  too (`denyOnAnyGraph`). For the self-locking CALL that is a deny of WRITE,
  CREATE, UPDATE or DELETE; for the DDL a deny of SCHEMA.

A deny scoped to one graph used to match every non-graph resource, so a DENY
READ on `g` refused every read-only procedure on every graph, a deny on `g` a
node or edge of any graph, and a DENY DECRYPT_FIELD on `g` every decryption;
and a graph-scoped allow of DECRYPT_FIELD never applied. A DENY SCHEMA on
`g` did not refuse index DDL run from another graph, which binds `g` as well.
Regression: `zig build test-sonny2753-graph-scoped-deny`.

A deny whose USING expression does not compile (a record loaded fail-closed)
keeps denying until it is rewritten, and so does a deny when the principal's
attributes cannot be read.

**Where deny policies come from.** `CREATE POLICY` has no effect clause and
always creates allow policies. A deny reaches the catalog in two ways:

- from `__geode_security`, where a GPS :Policy record with
  `permissive = false` loads as effect deny. A record without the property
  is malformed and does not load (SONNY-2750);
- through the `PolicyCatalog` API.

**Who is affected.** The `decide()` callers that enforce:

- the QUIC and gRPC write gate (`gps.writePermitted`, which QUIC now consults
  for every authenticated session, SONNY-2743);
- `CALL` procedures (read or write on the procedure);
- FLE decryption (`decrypt_field`).

EXPLAIN POLICY reports the decision a statement would get, but enforces
nothing.

Regression suite:
[`tests/test_sonny2744_gps_deny.zig`](../../tests/test_sonny2744_gps_deny.zig)
(`zig build test-sonny2744-gps-deny`); the restart case is in
`tests/test_gps_policy_persistence.zig`.
