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
| `SHOW VERSION` | *(local — no auth handler)* |
| `SHOW CAPABILITIES` | *(local — no auth handler)* |

`SHOW PERMISSIONS` without a `FOR` clause uses the current authenticated user's
permissions. With `FOR <username>`, an Admin role is required.

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

`CREATE ROLE admin` (or any other built-in name) is **idempotent**: it returns
an acknowledgement of the form `"already exists: <name> (built-in)"` and does
not create a duplicate entry.

`ALTER USER ... SET ROLE` and `GRANT ROLE ... TO ...` both route to
`geode.auth.user_assign_role`, which calls `user_management.assignRole`. This
function sets `user.role` to the requested role and bumps `auth_version` to
invalidate live sessions; re-assigning the current role is a no-op (no version
bump).

---

## Known Limitations

1. **Privilege grants not yet persistent.** `GRANT READ | WRITE | SCHEMA | ALL`
   and `REVOKE` route to `geode.auth.grant` / `geode.auth.revoke`, which
   acknowledge the request but do not yet persist a per-graph privilege entry.
   Only role assignment (`GRANT ROLE ... TO ...`, `ALTER USER ... SET ROLE ...`)
   changes durable state today.

2. **Custom role membership is not modeled on the user record.** Roles created
   via `CREATE ROLE <custom-name>` are stored in the role catalog, but the user
   record's `role` field only tracks the four built-in roles. Assigning a custom
   role via `ALTER USER ... SET ROLE` or `GRANT ROLE ... TO ...` returns an
   acknowledgement noting that the assignment is not yet structurally tracked.

3. **`IF EXISTS` on `DROP USER` / `DROP ROLE` is effectively always-satisfied.**
   The underlying delete handlers (`geode.auth.user_delete`,
   `geode.auth.role_delete`) degrade gracefully on a missing entity rather than
   returning an error, so `IF EXISTS` acts as a no-op safeguard today.

4. **`CREATE POLICY`, FLE DDL, and tenant DDL are not part of this surface.**
   Use `CALL geode.fle.*` for field-level encryption schema management and the
   RLS engine API for row-level security policies. Tenant provisioning is also
   not available via GQL DDL.

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

*Last Updated: May 2026*
*Status: Geode extension — not part of ISO/IEC 39075:2024*
