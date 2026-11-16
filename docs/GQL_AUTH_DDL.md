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

### Read-only requests (SONNY-2751)

A request sent with `ExecuteRequest.read_only` set (QUIC and gRPC), and every
`query` call of an MCP server started read-only, refuses every statement in
this reference that changes something: `CREATE` / `ALTER` / `DROP USER`
(an `ALTER USER <self> SET PASSWORD` included), `CREATE` / `DROP ROLE`,
`GRANT`, `REVOKE`, and the policy DDL (`CREATE` / `ALTER` / `DROP POLICY`),
for every role, Admin included, with SQLSTATE 42501 (`Read-only request:
data modification rejected`) and nothing changed. A `CALL` of a mutating
`geode.auth.*` procedure is refused the same way. The `SHOW` statements and
the read-only procedures (`geode.auth.user_list`, `user_show`,
`user_permissions`, `role_list`, `policy_list`, `grant_list`, `apikey_list`,
`apikey_check_scope`) still run. Before SONNY-2751 the security DDL counted
as a read and ran on a read-only request, and `CALL geode.auth.grant_list`
was refused.

### Password policy (SONNY-6331)

`CREATE USER ... SET PASSWORD`, `ALTER USER ... SET PASSWORD` and the
procedures they map to (`geode.auth.user_create`, `user_reset_password`,
and `user_change_password`) apply the server's password policy
([USER_AUTH.md](USER_AUTH.md#2-unified-password-policy-all-users)): at least
20 characters (`GEODE_PASSWORD_MIN_LENGTH`), an upper and a lower case
letter, at least 3 space-separated words (`GEODE_PASSWORD_MIN_WORDS`). A
password it refuses fails the statement with SQLSTATE 22000 and a message
naming the first rule broken, with the configured limit (for example
`Password too short (minimum 20 characters)`); the message never contains
the password, and nothing is created or changed. Before SONNY-6331 `CREATE
USER` applied an older rule (8 characters, a letter and a digit) and a
password change applied none. Existing passwords keep working; the policy is
checked when a password is set.

### Password changes (SONNY-6359)

- `ALTER USER <self> SET PASSWORD '<new>'` (the session's own user) is
  handled by the QUIC and gRPC password intercept, so it also works while
  the session must reset its password.
- `ALTER USER <other> SET PASSWORD '<new>'` runs as
  `geode.auth.user_reset_password`: an Admin only (42501 otherwise), with the
  password policy (22000), audited like the other admin procedures. Over QUIC
  and gRPC the intercept used to refuse it with 42501 for everyone, Admin
  included. A session that must reset its own password cannot change
  another user's (08P01) until it has.
- `geode.auth.user_change_password(username, old, new)` checks `old`
  against the stored password; an empty or wrong one fails with 28000 and
  changes nothing. An empty `old` used to skip the check.

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
permissions. With `FOR <username>`, an Admin role is required unless
`<username>` is the current user; a refusal answers 42501 and is audited
like the admin-only procedures (SONNY-6269, the `SHOW GRANTS` rule below).
`CALL geode.auth.user_permissions([<username>])` has the same rule; without
a username it lists the caller's permissions. For a user that does not
exist an Admin gets 42002 (`User does not exist`); it used to be answered
with the `user` role's permissions (SONNY-6291).

`CALL geode.auth.user_show([<username>])` (username, email, role, status)
follows the same rule (SONNY-6291): a user may show itself; another user
needs the Admin role, and a refusal answers 42501 and is audited. A user
that does not exist is an error: 42002 for an Admin, and for anyone else
the same 42501 refusal as another user's, so a non-admin cannot probe
which users exist. It used to show any user to any authenticated user, and
made up a row (`unknown` / `user` / `active`) for a missing one.

Failures are GQLSTATUS errors, never a 00000 status row starting `error:`
(SONNY-6359): `CREATE USER` / `geode.auth.user_create` of a user that exists
fails with 42710 and of a reserved name (`geode-cluster`) with 42939;
`geode.auth.user_assign_role` without a user or role fails with 22023 and of
a user that does not exist with 42002 for an Admin; a privilege other than
`READ`, `WRITE`, `SCHEMA` or `ALL` fails with 22023; and an
`ALTER USER ... ENABLE | DISABLE` or role change that fails for another
reason (the security graph cannot be read) fails with that error (58000).

The other `geode.auth.*` procedures follow the same rule (SONNY-6367). A
user that does not exist fails with 42002 for an Admin (42501 for anyone
else, as above): `ALTER USER ... ENABLE | DISABLE` /
`geode.auth.user_enable` / `user_disable` (they answered `enabled <user>`),
`user_set_attribute`, `mfa_setup`, `mfa_verify`, `mfa_enable` and
`mfa_disable`. A missing argument fails with 22023: `user_set_attribute`
without a user or key, `role_create` without a name, `user_import` without
a user or hash or with an algorithm other than `argon2id` / `blake2b`,
`mfa_enable` without a six-digit code (and `mfa_disable` with a code that is
not six digits). `user_import` of a user that exists fails with 42710, and
under FIPS with 0A000. `mfa_setup` with MFA turned off on the server
(`GEODE_ENABLE_MFA`) fails with 0A000. `mfa_verify` and `mfa_enable`
answer success only for a code that verifies: a user with no TOTP secret
fails with 55000 (`mfa_not_enrolled`), a code that does not verify with
28000 (`invalid token`), and a user locked out after five failed
verifications with 53400. `mfa_verify` and `mfa_enable` share one per-user
attempt count and lockout (SONNY-6623). They answered 00000 with a status row
(`rate_limited`, `mfa_not_enrolled`, `invalid token`, or an `error` column).
A `mfa_verify` whose attempt record cannot be made (out of memory) fails
with 53000 without checking the code (SONNY-6602; it was checked and not
counted toward the lockout).

MFA is not enforced at login (SONNY-6602; story SONNY-6604): HELLO never
asks for a TOTP code or a recovery code. `mfa_setup` (every shape:
`mfa_secret`, `recovery_codes`; or `provisioning_uri`, `secret` with
`show-uri`) and `mfa_enable` (`status`, `username`) answer an extra last
column, `warning`, that says so; no procedure redeems the recovery codes
`mfa_setup` issues.

`mfa_setup` stores the enrollment in `__geode_security` (the secret in the
user record, sealed with AES-256-GCM under a key derived from the HMAC key
(SONNY-6609), the recovery codes as SHA-256 digests, MFA off until a code
verifies), and `mfa_enable` / `mfa_disable` set the user's stored
`mfa_enabled`; the server loads the enrollments back at startup and
`DROP USER` removes them (SONNY-6608). A change that cannot be stored is
refused with 58030 and not applied. See
[USER_AUTH.md](USER_AUTH.md#mfa-is-not-enforced-at-login) for how the
secret is protected at rest.

`GRANT <priv> ON GRAPH g TO <user>` and `REVOKE <priv> ON GRAPH g FROM
<user>` (and `geode.auth.grant` / `revoke`) of a user that does not exist
fail with 42002 (`User does not exist`) and change nothing (SONNY-6345).
They used to succeed (SQLSTATE 00000) with a status row `error: user not
found: <user>`. Without a security graph to look users up in (an embedded
executor with no persistence wired), they fail with 58030 and grant or
revoke nothing.

The `geode.auth.apikey_*` procedures (`apikey_create`, `apikey_list`,
`apikey_revoke`, `apikey_check_scope`, and any other `apikey_` name) answer
0A000: the server has no API-key store, and its QUIC / gRPC handshake does
not authenticate by key (SONNY-6291). They were stubs: `apikey_check_scope`
answered `scope granted` for any key and `apikey_revoke` answered
`revoked` having revoked nothing. `apikey_create` and `apikey_revoke`
still need the Admin role (42501 first for anyone else).

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
| `admin` | Full administrative access — required for user/role mutations, FLE/TDE key administration and CDC administration (every `cdc.*` procedure and the CDC_DIAGNOSTICS / CDC_CONTROL frames, SONNY-6570) |
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

Only a built-in role (`admin`, `readwrite`, `user`, `readonly`) can be granted
to a user. A role made with `CREATE ROLE <custom-name>` carries no privileges
(it stores a name and a description; per-graph privileges are granted to users
with `GRANT ... ON GRAPH`), so granting it would confer nothing:
`GRANT ROLE <custom> TO <user>`, `ALTER USER <user> SET ROLE <custom>` and
`geode.auth.user_assign_role(<user>, <custom>)` fail with SQLSTATE 0A000 and
change nothing (SONNY-6292). They used to answer `assigned custom role ...`
and keep the name in an in-memory table that was never saved, survived
`DROP ROLE` (a role re-created under the same name went back to its old
members) and was read by no authorization path. A role name that is neither
built-in nor custom is still an error (`UnknownRole`).

A superuser (the bootstrap admin, or any user stored with `is_superuser`)
always resolves to `admin`, whatever role edge it holds. Giving it any other
role (`ALTER USER <superuser> SET ROLE readonly`, `geode.auth.user_assign_role`,
or offline `geode user assign-role` / `user update --role`) fails with
SQLSTATE 0A000 (`SuperuserRoleFixed`; offline: exit 1) and changes nothing
(SONNY-6369). It used to store the role and report it assigned, and the next
login resolved `admin` again. `SET ROLE admin` for a superuser is a no-op.

---

## Persistence

All auth DDL mutations persist to the HMAC-chained `__geode_security` graph via
`AuthGraphManager` and survive a server restart. Specifically:

- **`CREATE USER`** → a `User` node is created in `__geode_security`.
- **`DROP USER`** → the `User` node is removed from `__geode_security`. A user
  that does not exist fails with 42002 (SONNY-6609; it answered `deleted
  <name>`); `DROP USER IF EXISTS` answers `no user <name>; nothing dropped`.
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
- **`CALL geode.auth.mfa_setup`** → the user record's `mfa_secret` is set and
  `mfa_enabled` cleared, and a `MfaRecoveryCodes` node `(user_id, digests)`
  holds the recovery codes as SHA-256 digests (SONNY-6608).
  **`mfa_enable`** / **`mfa_disable`** → `mfa_enabled` on the `User` node.
  Both bump `auth_version`. `DROP USER` removes the `MfaRecoveryCodes` node.

### When a save fails (SONNY-1333)

A statement whose write to `__geode_security` fails answers an error, never
its success text, and leaves nothing usable that is not stored:

| Statement | On a failed save |
|---|---|
| `GRANT <priv> ON GRAPH g TO u` | 58030 (`GrantNotPersisted`): nothing is granted. Every privilege of the statement (all three for `ALL`) is stored and added to the live grant table, or none is: what one statement added is taken out again, as `CREATE POLICY` takes out a policy whose save failed. A grant held before the statement is kept. Retry the statement. |
| `REVOKE <priv> ON GRAPH g FROM u` | 58030 (`RevokeNotPersisted`): the privilege is taken away in memory first, so it stops at once, but its stored record remains and is loaded at the next start. Retry the statement to remove it. (A record removed whose chain seal failed is sealed again in the same statement; if that holds, the revoke succeeds.) Every action of `ALL` is attempted. This is fail-closed, unlike `DROP POLICY`, which on a failed save keeps the policy in memory and in the store. |
| `CREATE USER` | 58030 (`UserNotPersisted`): the user is not created (in memory or in the store). A user stored without its role edge is removed again, so the retry succeeds. |
| `geode.auth.user_import` | 58030 (`UserNotPersisted`, SONNY-3038): the user is not imported (in memory or in the store). |
| `DROP USER` | 58030 (`UserNotPersisted`): the user stays stored, and is **locked out** now (see below). Retry the statement. |
| `ALTER USER u SET PASSWORD` | 58030: the stored password stays, and the user is locked out: neither the old password (it may be why it was changed) nor the new one works. |
| `ALTER USER u DISABLE` | 58030: the user stays stored as active, and is locked out. |
| `ALTER USER u ENABLE` | 58030: the user stays disabled. |
| `ALTER USER u SET ROLE r` | 58030: the stored role stays. A downgrade (to a role that allows less) locks the user out; an upgrade does not. The role change (revoke the other built-in role edges, assign the new one) is stored whole or not at all. |
| `CREATE ROLE` | 58030 (`RoleNotPersisted`): the role is not created. |
| `DROP ROLE` | 58030 (`RoleNotPersisted`): the role is removed in memory first, so it stops at once, but its stored record remains and is loaded at the next start. Retry the statement. |

**Locked out (SONNY-3038).** The in-memory user record cannot carry a
change the store does not have: it is reloaded from `__geode_security`
whenever its auth version differs, or when it is not cached. So a
security-reducing change that could not be saved (a delete, a disable, a
password change, a role downgrade) is enforced by locking the user out: it
cannot authenticate and its sessions are no longer current. The lock lasts
until a later change to that user is saved (a saved delete, create, enable
or disable clears every lock; a saved password change clears a password
lock, a saved role change a role lock) or the server restarts, when the
stored user applies. This is fail-closed, like `REVOKE`. Inside the auth
manager, a change that fails part way (the chain seal included) is undone,
so the stored record, its HMAC and the chain agree and the next start
verifies; the same holds for `CREATE` and `ALTER POLICY`, and `DROP POLICY`
removes every stored policy of the name.

**`DROP POLICY` is one step (SONNY-6273).** It computes the new chain seal
(every allocation of it) while the policy's records are still stored, then
removes them and stores that seal. A failure before the removal answers an
error with the records, the catalog entry and the chain as they were: a
deny policy keeps denying, an allow policy keeps allowing, now and after a
restart, and the retry drops it. Once the records are gone the drop
succeeds sealed; only if the graph store refuses the seal write is the
chain sealed again (twice).

`SHOW GRANTS` reads the stored records, so it shows what the next start
will load. These write-throughs undo themselves and run outside the
statement undo (SONNY-3348), so a `GRANT`, `REVOKE`, `CREATE USER` or any
of the statements above inside an explicit transaction is not undone by
`ROLLBACK`. Residuals: if the undo of a failed change itself fails (a
second failure), the error is logged and what the first one wrote remains;
a removal (`DROP USER`, `DROP ROLE`, `REVOKE`) whose chain seal fails
twice is reported failed with the record already gone, and the chain does
not verify until the next saved change reseals it (for `DROP POLICY`, only
when the graph store refuses the seal write twice, SONNY-6273); a lock that
could not be recorded (no memory) is logged and not enforced; and a failure
inside the graph store's own node create or delete can leave a
half-written node behind, which these undos do not repair.

On startup, `server_init` hydrates the security state from `__geode_security`:
users are loaded via the existing `PersistentUserResolver`; custom roles are
loaded via `auth_dispatch.hydrateCustomRolesFromGraph`; per-graph grants are
loaded via `auth_startup_hydration.hydrateGraphGrants`; FLE role grants via
`auth_startup_hydration.hydrateFleRoleGrants`; GPS policies via
`policy_persistence.hydrateCatalog`; the tenant hierarchy and quotas from the
tenant registry. **Each loads every stored record or the server refuses to
start** (SONNY-6567): they were best-effort, logging a warning, and a server
could run with part of its roles, grants or policies (a deny policy that was
not loaded hides nothing). A stored FLE role grant whose user was deleted is
not loaded (it names no one). Hydration still tolerates the records it always
tolerated by design: a duplicate or uncompilable stored policy (GAP-0923).

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

### HMAC key

The records are sealed with a 256-bit HMAC key, resolved in this order:
`GEODE_AUTH_HMAC_KEY` (64 hex characters), `GEODE_TDE_KEY` (64 hex
characters; the key is derived from it), then `<data dir>/.geode_hmac_key`
(mode 0600). A server creates `.geode_hmac_key` only on a **first boot** (no
auth records yet). **A data directory that has auth records and no key
refuses to start** with `HMAC key required` naming the three sources, and
writes nothing (SONNY-6322; it used to write a new random key that could never
verify the chain, exit `AuthChainTampered`, and leave that key behind). Backups
do not hold the key (SONNY-6299): restore with the source server's key. Because
the environment comes first, `geode restore --hmac-key-file` is refused when
`GEODE_TDE_KEY` or `GEODE_AUTH_HMAC_KEY` is set (`HmacKeySourceConflict`): a
key file planted in the restored directory would never be read. A backup taken
with `GEODE_TDE_KEY` set is encrypted under it, so it is restored with the
source server's `GEODE_TDE_KEY` (and `GEODE_AUTH_HMAC_KEY`, if it had one) and
no key file (SONNY-6386). A server restore (QUIC/gRPC `restore`) verifies the restored copy's chain with
the server's own key before it reports success; a backup sealed under another
key fails and leaves nothing behind. To accept records whose key is lost, an
operator re-seals them under a new key: `geode auth reseal --data-dir <dir>`.

`<data dir>` is the directory the server resolved and locked, however it was
given: `--data-dir`, else `GEODE_DATA_DIR`, else the per-user default
(`$XDG_STATE_HOME/geode`, `$HOME/.local/state/geode`, `$TMPDIR/geode-<uid>`).
Until SONNY-6339 the key lookup saw only the `--data-dir` flag: a server
started with `GEODE_DATA_DIR` or the default neither read nor created the key
and ran with the auth graph disabled, so users, roles, grants and policies
were kept in memory and lost at restart, with no error. **A server never runs
without the auth graph any more:** it refuses to start when a key source is
set but unusable (a malformed or unreadable `.geode_hmac_key`, a non-empty
`GEODE_AUTH_HMAC_KEY` that is not 64 hex characters, which used to be
skipped in favour of the file, or a non-empty `GEODE_TDE_KEY` that is not 64
hex characters, SONNY-6386), when the key file cannot be created, or when
the store or the auth graph cannot be opened (`[startup] HMAC key unusable`,
`[startup] ... refusing to start without durable auth state`).

---

## Known Limitations

1. **No model for `GRANT <privilege>` without `ON GRAPH`.** A global per-privilege
   grant or revoke (e.g. `GRANT WRITE TO alice` with no graph qualifier, or
   `geode.auth.grant` / `revoke` with an empty resource) fails with SQLSTATE
   0A000 and changes nothing; it used to answer 00000 with a `note:` row
   (SONNY-6359). Global privilege is governed by the user's role — there is
   no per-privilege override model at the global level. Likewise a grant on
   every graph, `geode.auth.grant(<priv>, <user>, '*')`, fails with 0A000
   (`GrantWildcardNotSupported`) and stores nothing (SONNY-3135): it used to
   store a grant on a graph literally named `*`, which no request matches.
   For every graph use a built-in role or `CREATE POLICY ... ON GRAPH *`.
   `geode.auth.revoke(<priv>, <user>, '*')` still removes such a grant an
   older release stored.

2. **Custom roles carry no privileges and cannot be granted to users.**
   Roles created via `CREATE ROLE <custom-name>` are stored (and persisted) in
   the role catalog, but there is no privilege model for them and no
   membership: the user record's `role` field holds one of the four built-in
   roles. Granting a custom role (`ALTER USER ... SET ROLE`, `GRANT ROLE ... TO
   ...`, `geode.auth.user_assign_role`) is refused with SQLSTATE 0A000
   (SONNY-6292). Privileged custom roles with persisted membership are a
   feature that is not implemented.

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

6. **`IF EXISTS` on `DROP ROLE` is effectively always-satisfied.** The
   underlying `geode.auth.role_delete` degrades gracefully on a missing role
   rather than returning an error. `DROP USER` of a missing user fails with
   42002 (SONNY-6609), and `DROP USER IF EXISTS` is the no-op form.

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
   This includes a user's own `ALTER USER <self> SET PASSWORD` and the
   forced reset after a `password_reset_required` login (SONNY-1332,
   2026-11-13): the QUIC and gRPC transports handle those themselves, and
   they used to write the new password on the one node they reached, leaving
   the old one valid on every other member. Offline `geode user ...` and
   `geode auth init` commands against a stopped member's data dir still
   write that member only: they are the per-member seeding path, so run the
   same commands against every member.

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
