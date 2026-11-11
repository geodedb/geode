# GQL Auth DDL — Geode Extension Reference

Geode extends GQL with a set of declarative DDL statements for user and role
management. These statements are parsed via *soft keywords* (so `USER`, `ROLE`,
`GRANT`, `REVOKE`, `SHOW`, etc. remain valid as identifiers in ordinary queries)
and act as thin syntactic sugar over the existing `geode.auth.*` procedure
handlers — inheriting the same authorization rules (Admin role required for
mutations; any authenticated user may use read-only `SHOW` variants), audit
logging, password policy enforcement, and HMAC-chained `__geode_security`
persistence. **Authentication itself** (session establishment, credential
verification) still occurs via the QUIC HELLO handshake; these statements
manage *other* users and roles, not the caller's own session.

---

## Grammar

```
-- User management
CREATE USER <name> SET PASSWORD <string> [ EMAIL <string> ] [ ROLE <name> ]
ALTER  USER <name> SET PASSWORD <string>
ALTER  USER <name> SET ROLE <name>
ALTER  USER <name> ENABLE
ALTER  USER <name> DISABLE
DROP   USER <name> [ IF EXISTS ]

-- Role management
CREATE ROLE <name> [ SET DESCRIPTION <string> ]
DROP   ROLE <name> [ IF EXISTS ]

-- Privilege assignment
GRANT  ROLE <rolename> TO <username>
GRANT  READ  | WRITE | SCHEMA | ALL [ ON GRAPH <name> ] TO <username>
REVOKE READ  | WRITE | SCHEMA | ALL [ ON GRAPH <name> ] FROM <username>

-- Introspection
SHOW USERS
SHOW ROLES
SHOW PERMISSIONS [ FOR <username> ]
SHOW GRANTS [ FOR <username> ]
SHOW VERSION
SHOW CAPABILITIES
```

Names may be bare identifiers or quoted strings. `<string>` denotes a
single-quoted or double-quoted string literal.

---

## Statement to Procedure Mapping

| GQL Statement | Mapped `geode.auth.*` Procedure |
|---|---|
| `CREATE USER` | `geode.auth.user_create` |
| `ALTER USER ... SET PASSWORD` | `geode.auth.user_reset_password` |
| `ALTER USER ... SET ROLE` | `geode.auth.user_assign_role` |
| `ALTER USER ... ENABLE` | `geode.auth.user_enable` |
| `ALTER USER ... DISABLE` | `geode.auth.user_disable` |
| `DROP USER` | `geode.auth.user_delete` |
| `CREATE ROLE` | `geode.auth.role_create` |
| `DROP ROLE` | `geode.auth.role_delete` |
| `GRANT ROLE ... TO ...` | `geode.auth.user_assign_role` |
| `GRANT <priv> ... TO ...` | `geode.auth.grant` |
| `REVOKE <priv> ... FROM ...` | `geode.auth.revoke` |
| `SHOW USERS` | `geode.auth.user_list` |
| `SHOW ROLES` | `geode.auth.role_list` |
| `SHOW PERMISSIONS [ FOR ... ]` | `geode.auth.user_permissions` |
| `SHOW GRANTS [ FOR ... ]` | `geode.auth.grant_list` (plus the GPS policies that apply to the user) |
| `SHOW VERSION` | *(local — no auth handler)* |
| `SHOW CAPABILITIES` | *(local — no auth handler)* |

`SHOW PERMISSIONS` without a `FOR` clause uses the current authenticated user's
permissions. With `FOR <username>`, an Admin role is required.

`SHOW GRANTS` without a `FOR` clause shows the current user's grants. A user
may list its own grants (`FOR` its own name, or no `FOR`); another user's
need the Admin role, and a refusal answers 42501 and is audited like the
admin-only procedures. Columns: `policy_name`, `graph`, `actions`, `effect`,
`enabled`. The GPS policies that apply to the user come first (a policy
whose condition is `true` or names the user with `current_user() = '<name>'`).
Then one row per graph the user holds per-graph grants on, read from the
`GraphGrant` records in `__geode_security` (what the next start loads):
`policy_name` is null, `actions` lists the granted privileges (`read`,
`write`, `schema`), `effect` is `allow`, `enabled` is true. The procedure
`CALL geode.auth.grant_list([<username>])` returns the stored grants one
row per grant (`username`, `graph`, `action`) with the same authorization
(SONNY-1333).

Implementation: `src/gql/parser.zig` (parse) → `src/gql/ast.zig` (AST nodes) →
`src/execution/admin_ddl.zig` (execution) → `src/execution/auth_dispatch.zig`
(`callAuthProcedure` bridge).

---

## Built-in Roles

Geode ships four built-in roles that cannot be deleted:

| Role name | Meaning |
|---|---|
| `admin` | Full administrative access — required for user/role mutations |
| `user` | Standard authenticated user |
| `readwrite` | Read and write access to graph data |
| `readonly` | Read-only access to graph data |

The default bootstrap user (created by `ensureDefaultUser` at first startup) is
a member of the `admin` role.

### Users with no stored role (fail-closed default)

**Breaking change (2026-10).** A user whose record in `__geode_security`
carries no built-in role (no `HAS_ROLE` edge to `admin`, `user`, `readwrite`
or `readonly`, and not a superuser) used to resolve to `readwrite`: read and
write on every graph, with no grant. That failed open. Such a user now
resolves to `none`:

| | No stored role (`none`) |
|---|---|
| Global read, write or schema | None. |
| Admin (user, role, tenant, policy administration) | None. |
| A graph with no grant | No access: no bind (`USE GRAPH`, a HELLO graph), no read, no write. This includes the `default` graph every session starts on. |
| A graph with a per-graph grant | That grant's privileges there, as for every role (see Persistence): `READ` binds and reads it, `WRITE` writes it, `SCHEMA` changes its schema. `ALL` gives all three. To write a graph the user also needs `READ` on it, to bind it. |
| Programs that read no store (`RETURN 1`) | Allowed. |

`none` is the absence of a role, not a built-in role: `Role.fromString`
does not parse it, so `ALTER USER … SET ROLE none` does not assign it (it is
refused as an unknown role unless a custom role of that name exists). `SHOW USERS`
lists such a user with the role `none`. To give the user access, assign a
built-in role (`ALTER USER u SET ROLE readonly`) or grant per graph
(`GRANT READ ON GRAPH g TO u`).

`CREATE USER` without a `ROLE` clause is unaffected: it stores the `user`
role. Users are left with no stored role by records written outside the
auth DDL (older versions, direct imports into `__geode_security`). The
bootstrap admin is a superuser and resolves to `admin` with or without a
role edge. Explicitly assigned roles resolve exactly as before.

Write grants are not capped at read for these users. Grants are additive
over the global role and a `WRITE` grant allows writes on its graph "even if
the global role wouldn't" ([Per-graph grant semantics](#per-graph-grant-semantics));
capping them for one role would break that contract.

Implementation: `role_resolver.authRoleFromRecord` (the fallback),
`user_management.Role.None`, `gps.isGrantOnly`, the per-graph grant step of
`gps.decide`, `gps.writePermittedOn`, `gps.graphReadPermitted` and
`session_graph.programReadPermitted` (the QUIC and gRPC handler gates).
Regression: `tests/test_default_role_fail_closed.zig`
(`zig build test-default-role-fail-closed`).

`CREATE ROLE admin` (or any other built-in name) is **idempotent**: it returns
an acknowledgement of the form `"already exists: <name> (built-in)"` and does
not create a duplicate entry.

`ALTER USER ... SET ROLE` and `GRANT ROLE ... TO ...` both route to
`geode.auth.user_assign_role`, which calls `user_management.assignRole`. This
function sets `user.role` to the requested role and bumps `auth_version` to
invalidate live sessions; re-assigning the current role is a no-op (no version
bump).

---

## Persistence

All auth DDL mutations persist to the HMAC-chained `__geode_security` graph via
`AuthGraphManager` and survive a server restart. Specifically:

- **`CREATE USER`** → a `User` node is created in `__geode_security`.
- **`DROP USER`** → the `User` node is removed from `__geode_security`.
- **`ALTER USER … SET PASSWORD`** → the `password_hash` property is updated on
  the `User` node and `auth_version` is bumped (invalidating live sessions).
- **`ALTER USER … SET ROLE`** / **`GRANT ROLE … TO …`** → the user's built-in
  role is updated on the `User` node and `auth_version` is bumped. (A `HAS_ROLE`
  edge is written for the new assignment.)
- **`ALTER USER … ENABLE`** / **`DISABLE`** → the `is_active` flag on the `User`
  node is updated and `auth_version` is bumped.
- **`CREATE ROLE`** / **`DROP ROLE`** → a `Role` node is created/removed.
  Built-in role names (`admin`/`user`/`readwrite`/`readonly`) are idempotent on
  `CREATE ROLE` — the call returns `"already exists: <name> (built-in)"` and
  does nothing.
- **`GRANT READ|WRITE|SCHEMA|ALL ON GRAPH <g> TO <u>`** / **`REVOKE …`** → a
  `GraphGrant` node `(user_id, graph_name, action)` is created/removed in
  `__geode_security`, and the in-memory `GraphRBACPolicy` is updated immediately.
  See [Per-graph grant semantics](#per-graph-grant-semantics).

### When a save fails (SONNY-1333)

A statement whose write to `__geode_security` fails answers an error, never
its success text, and leaves nothing usable that is not stored:

| Statement | On a failed save |
|---|---|
| `GRANT <priv> ON GRAPH g TO u` | 58030 (`GrantNotPersisted`): nothing is granted. Every privilege of the statement (all three for `ALL`) is stored and added to the live grant table, or none is: what one statement added is taken out again, as `CREATE POLICY` takes out a policy whose save failed. A grant held before the statement is kept. Retry the statement. |
| `REVOKE <priv> ON GRAPH g FROM u` | 58030 (`RevokeNotPersisted`): the privilege is taken away in memory first, so it stops at once, but its stored record remains and is loaded at the next start. Retry the statement to remove it. (A record removed whose chain seal failed is sealed again in the same statement; if that holds, the revoke succeeds.) Every action of `ALL` is attempted. This is fail-closed, unlike `DROP POLICY`, which on a failed save keeps the policy in memory and in the store. |
| `CREATE USER` | Status `error: UserNotPersisted`: the user is not created (in memory or in the store). A user stored without its role edge is removed again, so the retry succeeds. |

`SHOW GRANTS` reads the stored records, so it shows what the next start
will load. These write-throughs undo themselves and run outside the
statement undo (SONNY-3348), so a `GRANT`, `REVOKE` or `CREATE USER` inside
an explicit transaction is not undone by `ROLLBACK`. Residuals: the other write-throughs (`DROP USER`, `ALTER USER`,
`CREATE` / `DROP ROLE`, `geode.auth.user_import`) still log a failed save and
report success (SONNY-3038); if the undo of a failed `GRANT` itself
fails (a second failure), the error is logged and the stored record remains
until revoked; and a failure inside the graph store's own node create or
delete can leave a half-written node behind, which these undos do not
repair.

On startup, `server_init` hydrates the security state from `__geode_security`:
users are loaded via the existing `PersistentUserResolver`; custom roles are
loaded via `auth_dispatch.hydrateCustomRolesFromGraph`; per-graph grants are
loaded via `GraphRBACPolicy.loadGraphGrants(agm.listGraphGrants(...))`. All
hydration is best-effort — a failure logs a warning and does not crash startup.

### Per-graph grant semantics

**Security fix (2026-10, REQ-SEC-PER-GRAPH-GRANTS).** For every role:

| | Effect |
|---|---|
| Global role permission (`readwrite` writes, `admin` everything, ...) | Allows the operation on **every** graph. Unchanged. |
| `GRANT READ ON GRAPH g TO u` | `u` may bind `g` (`USE GRAPH g`, a HELLO graph) and read it. |
| `GRANT WRITE ON GRAPH g TO u` | `u` may change data on `g`, and on no other graph. |
| `GRANT SCHEMA ON GRAPH g TO u` | `u` may create, replace or drop graph `g` (`CREATE GRAPH g`, `DROP GRAPH g`). Graph DDL also passes the write and bind gates, so a role without global write needs `WRITE` on `g` too (and `READ`, if it cannot bind `g` otherwise). Index and constraint DDL apply to every graph and still need the global schema permission (or a `FOR SCHEMA` policy on `*`). |
| `GRANT ALL ON GRAPH g TO u` | All three, on `g`. |
| `REVOKE ... ON GRAPH g FROM u` | Takes the privilege away. |
| A deny policy covering `g` | Overrides a grant on `g`. |

- **Additive.** A grant widens access beyond the global role, on its graph
  only; it never restricts what the global role allows.
- **Immediate.** `GRANT` and `REVOKE` take effect for the next statement on
  every session, with no restart and no reconnect: `gps.decide` reads the
  live grant table, and a change invalidates cached authorization decisions.
- **Scoped.** A grant counts only for a request on its graph. A database-wide
  request (a procedure, a self-locking `CALL`, index or constraint DDL) is
  never allowed by a grant.
- **Durable.** Grants survive a restart with the same scope: they are
  reloaded from their `GraphGrant` nodes.
- **Bind.** Binding a graph needs `READ` on it (or `admin`, or `readwrite` in
  a single-tenant deployment). A user that should write `g` and does not
  bind graphs through its role needs `READ` and `WRITE` on `g`.

Until 2026-10, for a user with an explicit role, a runtime `GRANT` took
effect only after a restart (grants reached authorization only as Policy
rows migrated from them at startup), and after that restart a `WRITE` grant
on one graph allowed writes on **every** graph (the database-wide write check
matched any graph-scoped allow policy). A `REVOKE` never removed the migrated
row, so a migrated grant could not be revoked. Startup now drops the
`auto_migrated_grant_*` policies earlier versions created (a policy an
operator named with that prefix is dropped too). If the drop cannot complete,
the migrated allow policies are disabled first and stay disabled, and the next
startup drops the rest (SONNY-4877). The same scoping applies to
`CREATE POLICY ... ON GRAPH g`: an allow policy scoped to one graph allows
on that graph only; use `ON GRAPH *` for every graph.

Implementation: the per-graph grant step of `gps.decide`,
`gps.allowPolicyCovers`, `gps.writePermittedOn` (the QUIC and gRPC write
gate), `session_graph.maySchema`, and
`grant_migration.retireMigratedGrantPolicies`. Regression:
`tests/test_per_graph_grants.zig` (`zig build test-per-graph-grants`).

The write-through path is implemented as injectable callbacks to avoid Zig module
diamond issues: `PersistentUserWriter` (user create/delete/password/role/active),
`RolePersistCallbacks` (role create/delete), and `GrantPersistCallbacks` (grant
create/revoke) are wired at startup in `server_init`.

---

## Known Limitations

1. **No model for `GRANT <privilege>` without `ON GRAPH`.** A global per-privilege
   grant (e.g. `GRANT WRITE TO alice` with no graph qualifier) is not persisted
   and returns an explanatory note. Global privilege is governed by the user's
   role — there is no per-privilege override model at the global level.

2. **Custom role membership beyond the built-in role field is not modeled.**
   Roles created via `CREATE ROLE <custom-name>` are stored in the role catalog,
   but the user record's `role` field only tracks the four built-in roles.
   Assigning a custom role via `ALTER USER ... SET ROLE` or `GRANT ROLE ... TO ...`
   returns an acknowledgement noting the assignment is not yet structurally
   tracked on the user record.

3. **Policy DDL persistence is implemented (GAP-0858, closed 2026-06-09).**
   `CREATE POLICY` / `ALTER POLICY ... SET ENABLED true|false` /
   `ALTER POLICY ... RENAME TO ...` / `DROP POLICY` write through to the
   HMAC-chained `__geode_security` graph (`AuthGraphManager.upsertPolicyNode`;
   hooks wired in `server_init.wireGpsPolicyHooks`) and survive restart — the
   `PolicyCatalog` (`src/security/policy_catalog.zig`) is re-hydrated from the
   store at startup. Restart regression:
   `tests/test_gap0858_alter_policy_persist.zig` (`zig build test-gap0858`)
   asserts enable/disable and rename survive re-hydration with the HMAC chain
   green. Residual: the GQL → bytecode pipeline for *expression* RLS policy
   compilation is still manual (pre-compiled `CompiledExpression` pinning) —
   see the RLS notes in [`../CLAUDE.md`](../CLAUDE.md) Known Limitations.

4. **The BIND-time per-graph grant check is additive (permissive in default
   config).** In the default single-tenant configuration a `readwrite` user
   can bind any graph, so a `GRANT READ ON GRAPH g TO u` only becomes
   load-bearing under stricter multi-tenant modes where graph-level access is
   restricted by default, for `readonly`/`user` principals, and for users with
   no stored role, for whom every grant is load-bearing.

5. **`SHOW GRANTS` shows per-graph grants and policies, not roles.** A
   user's built-in role and the permissions it gives are shown by
   `SHOW USERS` and `SHOW PERMISSIONS`. (Until SONNY-1333 there was no way to
   read a per-graph grant back.)

6. **`IF EXISTS` on `DROP USER` / `DROP ROLE` is effectively always-satisfied.**
   The underlying delete handlers (`geode.auth.user_delete`,
   `geode.auth.role_delete`) degrade gracefully on a missing entity rather than
   returning an error, so `IF EXISTS` acts as a no-op safeguard today.

7. **`CREATE POLICY`, FLE DDL, and tenant DDL are not part of this surface.**
   Use `CALL geode.fle.*` for field-level encryption schema management and the
   RLS engine API for row-level security policies. Tenant provisioning is also
   not available via GQL DDL. The `CALL geode.fle.*` procedures are the
   **supported, stable** surface for FLE schema management — see
   [Managing FLE Schema via `CALL geode.fle.*`](FIELD_LEVEL_ENCRYPTION.md#managing-fle-schema-via-call-geodefle-supported-stable-surface--gap-0845)
   in the FLE reference for the full procedure list and an end-to-end example
   (GAP-0845).

8. **Auth DDL is refused in cluster mode (2026-06-10).** When the node runs as
   part of a Raft cluster (`GEODE_CLUSTER_TOKEN` set), auth DDL
   (`CREATE/ALTER/DROP USER`, `CREATE/DROP ROLE`, `GRANT`/`REVOKE`) and the
   mutating `geode.auth.*` procedures fail closed via
   `cluster.gateUnreplicatedWrite()` — a follower returns `ClusterNotLeader`,
   the leader returns `ClusterWriteNotReplicable` — because there is no Raft
   replication slice for auth writes yet and the `__geode_security` graph is
   **per-node** (an ungated write would create users that exist on one node
   only). Standalone mode is unaffected. A replication slice for auth DDL is
   follow-up work. e2e: `tests/test_cluster_replicable_mutations.zig`
   ("cluster: unreplicated write surfaces fail closed").

### Future: `CREATE POLICY`

When `CREATE POLICY` lands it should follow:

```
CREATE POLICY <name> ON <Label>
  [ FOR READ | WRITE | ALL ]
  [ TO <role> [, <role>]* ]
  USING (<expr>)
  [ WITH CHECK (<expr>) ]
```

This matches the existing `src/security/rls_core.zig` `Policy` fields
(`graph`, `table`, `operation`, `roles`, `using_expr`, `check_expr`). The
geode-ui's guessed `CREATE POLICY ... AS '<expr>'` form may be supported as an
alias once the parser path lands.

---

*Last Updated: November 2026*
*Status: Geode extension — not part of ISO/IEC 39075:2024*
