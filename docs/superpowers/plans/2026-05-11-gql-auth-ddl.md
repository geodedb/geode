# GQL Auth DDL (CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class GQL DDL statements for user, role, and grant management — parsed over the wire and routed to the existing `geode.auth.*` procedure handlers — so clients can run `CREATE USER alice SET PASSWORD 's3cret!1'`, `GRANT ROLE auditor TO alice`, `DROP USER alice`, `SHOW USERS`, etc., instead of `CALL geode.auth.user_create(...)`.

**Architecture:** ISO/IEC 39075:2024 GQL defines none of these statements, so these are documented **Geode extensions**. The token/keyword layer lives in an *external* package (`gql`, vendored at `zig-pkg/gql-0.1.3-…/`), which we do **not** modify. Instead, the new statements are parsed as **soft keywords** — `CREATE`/`DROP` are already real keyword tokens, so after them we peek at the next identifier token's text (`USER`/`ROLE`); `GRANT`/`REVOKE`/`ALTER` lead the statement as plain `identifier` tokens, handled in `parseStatement`'s existing `.identifier` branch (same mechanism `BACKUP`/`RESTORE` already use). Parsed statements become new `ast.Statement` union variants. Execution maps each variant onto an existing `geode.auth.*` handler via a thin new helper in `src/execution/auth_dispatch.zig` — so authorization (Admin-required), audit, password policy, and the HMAC-chained `__geode_security` persistence are all inherited unchanged. No backend logic is reimplemented.

**Tech Stack:** Zig 0.16, in-tree GQL parser (`src/gql/`), execution engine (`src/execution/`), `zig build test` for unit tests, `../geode-test-harness` geodetestlab for over-the-wire integration tests.

**Out of scope (tracked as follow-up plans):** `CREATE POLICY` / RLS DDL, FLE DDL (`CALL geode.fle.*` stays the interface for now), tenant DDL, and making `GRANT <privilege>` *persistent* (today `geode.auth.grant` is a status-formatting stub for the privilege form; the role-assignment form `GRANT ROLE … TO …` does persist via `user_assign_role`). This plan only exposes what the backend already does.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `src/gql/ast.zig` | Modify | Add 7 statement structs + 7 `Statement` union variants + small `GrantSubject`/`GrantPrivilege` enums + 2 `ShowType` variants |
| `src/gql/parser.zig` | Modify | New parse fns; hook into `parseCreateStatement`, `parseDropStatement`, `parseStatement` (`.identifier` arm), `parseShowStatement` |
| `src/gql/print.zig` | Modify | Add `tagName` arms (exhaustive switch) for the 7 new variants |
| `src/execution/auth_dispatch.zig` | Modify | Add one `pub fn callAuthProcedure(allocator, ctx, proc_name, string_args)` helper that builds a synthetic `CallProcedure` and delegates to the existing `execute()` (which enforces auth) |
| `src/execution/admin_ddl.zig` | **Create** | Map each new `ast.Statement` variant → `auth_dispatch.callAuthProcedure(...)` |
| `src/execution.zig` | Modify | Add the 7 new arms to the `executeStatementWithContext` switch; intercept `SHOW USERS/ROLES`; delegate to `admin_ddl` |
| `build.zig` | Modify (only if needed) | Wire `src/execution/admin_ddl.zig` if execution submodules are registered individually (verify — most are reached via `@import` from `execution.zig`, so likely no change) |
| `tests/test_auth_ddl_parser.zig` | **Create** | Parser unit tests for all new syntax (direct lexer+parser, no server) |
| `../geode-test-harness/geodetestlab-cli/specs/geode_auth_ddl.yml` | **Create** | Over-the-wire integration test against a real geode server |
| `docs/GQL_AUTH_DDL.md` | **Create** | Document the extension grammar |
| `CLAUDE.md` | Modify | Note the new DDL surface in the feature list / known-limitations |

**Soft-keyword reference (no external package changes needed):**
- Real keyword tokens already available and reused: `CREATE`, `DROP`, `SHOW`, `SET`, `ON`, `GRAPH`, `TO`, `FROM`, `READ`, `WRITE`, `ALL`, `SCHEMA`, `IF`, `EXISTS`.
- Soft keywords (matched by `std.ascii.eqlIgnoreCase` on an `identifier` token's `.lexeme`): `USER`, `ROLE`, `GRANT`, `REVOKE`, `ALTER`, `PASSWORD`, `EMAIL`, `ENABLE`, `DISABLE`, `DESCRIPTION`, `USERS`, `ROLES`.

---

## Chosen Grammar (GQL-flavored / minimal)

```
CREATE USER <name> SET PASSWORD <string> [ EMAIL <string> ] [ ROLE <name> ]
ALTER  USER <name> SET PASSWORD <string>
ALTER  USER <name> SET ROLE <name>
ALTER  USER <name> ENABLE
ALTER  USER <name> DISABLE
DROP   USER <name> [ IF EXISTS ]

CREATE ROLE <name> [ SET DESCRIPTION <string> ]
DROP   ROLE <name> [ IF EXISTS ]

GRANT  ROLE <rolename> TO <username>                                          -- → geode.auth.user_assign_role(user, role)
GRANT  ( READ | WRITE | SCHEMA | ALL ) [ ON GRAPH <name> ] TO <username>      -- → geode.auth.grant(perm, user, graph?)
REVOKE ( READ | WRITE | SCHEMA | ALL ) [ ON GRAPH <name> ] FROM <username>    -- → geode.auth.revoke(perm, user, graph?)

SHOW USERS                                                                    -- → geode.auth.user_list()
SHOW ROLES                                                                    -- → geode.auth.role_list()
```

`<name>` / `<username>` / `<rolename>` accept an `identifier` token (or a quoted identifier). `<string>` is a `string_lit` token (single- or double-quoted). Option clauses after `SET` are order-independent and parsed in a loop like `parseBackupStatement` does for `WITH` options.

Mapping table (the only execution logic — everything else is delegated):

| Statement | `proc_name` | args (all strings) |
|---|---|---|
| `CREATE USER n SET PASSWORD p [EMAIL e] [ROLE r]` | `geode.auth.user_create` | `[n, p, e_or_"", r_or_"user"]` |
| `ALTER USER n SET PASSWORD p` | `geode.auth.user_reset_password` | `[n, p]` |
| `ALTER USER n SET ROLE r` | `geode.auth.user_assign_role` | `[n, r]` |
| `ALTER USER n ENABLE` | `geode.auth.user_enable` | `[n]` |
| `ALTER USER n DISABLE` | `geode.auth.user_disable` | `[n]` |
| `DROP USER n [IF EXISTS]` | `geode.auth.user_delete` | `[n]` (IF EXISTS swallows not-found in `admin_ddl`) |
| `CREATE ROLE n [SET DESCRIPTION d]` | `geode.auth.role_create` | `[n, d_or_""]` |
| `DROP ROLE n [IF EXISTS]` | `geode.auth.role_delete` | `[n]` |
| `GRANT ROLE r TO u` | `geode.auth.user_assign_role` | `[u, r]` |
| `GRANT priv [ON GRAPH g] TO u` | `geode.auth.grant` | `[priv, u, g_or_""]` |
| `REVOKE priv [ON GRAPH g] FROM u` | `geode.auth.revoke` | `[priv, u, g_or_""]` |
| `SHOW USERS` | `geode.auth.user_list` | `[]` |
| `SHOW ROLES` | `geode.auth.role_list` | `[]` |

> Note `user_reset_password` (not `user_change_password`) is used for `ALTER USER … SET PASSWORD` because the DDL form does not carry the old password; `user_reset_password` is the Admin-only reset path (`handleUserResetPassword` at `src/execution/auth_dispatch.zig:542`). The Admin gate in `auth_dispatch.execute` is what authorizes it.

---

### Task 1: AST — new statement structs and union variants

**Files:**
- Modify: `src/gql/ast.zig` (the `Statement` union is at lines 7-55; the `Expr` union starts at line 252; the DDL structs like `CreateSchemaStatement` are around line 583; `ShowType` enum at line 542)

- [ ] **Step 1: Add the new statement structs to `src/gql/ast.zig`**

Insert in the "statements" region (after `DropGraphTypeStatement` — search for it — and before the `Expr` union at line 252):

```zig
// ---------------------------------------------------------------------------
// Geode extension: auth DDL (not part of ISO/IEC 39075:2024).
// Parsed via soft keywords; executed by src/execution/admin_ddl.zig which maps
// each variant onto an existing geode.auth.* procedure handler.
// ---------------------------------------------------------------------------

pub const CreateUserStatement = struct {
    name: []const u8,
    password: []const u8,
    email: ?[]const u8 = null,
    role: ?[]const u8 = null,
};

pub const AlterUserAction = union(enum) {
    set_password: []const u8,
    set_role: []const u8,
    enable,
    disable,
};

pub const AlterUserStatement = struct {
    name: []const u8,
    action: AlterUserAction,
};

pub const DropUserStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const CreateRoleStatement = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const DropRoleStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const GrantPrivilege = enum { read, write, schema, all };

pub const GrantSubject = union(enum) {
    role: []const u8, // GRANT ROLE <name> TO <user>
    privilege: GrantPrivilege, // GRANT READ|WRITE|SCHEMA|ALL [ON GRAPH g] TO <user>
};

pub const GrantStatement = struct {
    subject: GrantSubject,
    on_graph: ?[]const u8 = null, // only meaningful for privilege form
    grantee: []const u8, // username
};

pub const RevokeStatement = struct {
    privilege: GrantPrivilege, // REVOKE only supports the privilege form
    on_graph: ?[]const u8 = null,
    grantee: []const u8,
};

pub fn grantPrivilegeName(p: GrantPrivilege) []const u8 {
    return switch (p) {
        .read => "READ",
        .write => "WRITE",
        .schema => "SCHEMA",
        .all => "ALL",
    };
}
```

- [ ] **Step 2: Add the 7 union variants to `Statement` in `src/gql/ast.zig`**

In `pub const Statement = union(enum) { ... }` (lines 7-55), add after `DropGraphType: DropGraphTypeStatement,`:

```zig
    // Geode extension: auth DDL
    CreateUser: CreateUserStatement,
    AlterUser: AlterUserStatement,
    DropUser: DropUserStatement,
    CreateRole: CreateRoleStatement,
    DropRole: DropRoleStatement,
    Grant: GrantStatement,
    Revoke: RevokeStatement,
```

- [ ] **Step 3: Add `users` and `roles` to `ShowType` in `src/gql/ast.zig`**

`pub const ShowType = enum { indexes, constraints, tables, graphs, procedures, functions };` is at line 542. Add two members:

```zig
    users,
    roles,
```

- [ ] **Step 4: Build to surface every exhaustive switch that now fails**

Run: `zig build 2>&1 | head -60`
Expected: compile errors of the form `error: switch must handle all possibilities` (and/or `unhandled enumeration value`) pointing at — at minimum — `src/gql/print.zig` (`tagName`, ~line 154) and `src/execution.zig` (`executeStatementWithContext`, ~line 965), plus possibly a semantic-analysis pass over `ast.Statement` and `src/gql/main.zig`, plus a `ShowType` switch wherever `SHOW` is dispatched. **Write down the exact file:line list it reports — Tasks 2/3/6 will fix each one.**

- [ ] **Step 5: Commit**

```bash
git add src/gql/ast.zig
git commit -m "feat(gql): add auth DDL AST nodes (CREATE/ALTER/DROP USER, ROLE, GRANT/REVOKE)"
```

---

### Task 2: Parser — recognize the new statements

**Files:**
- Modify: `src/gql/parser.zig` — `parseStatement` `.identifier` arm (~line 619), `parseCreateStatement` (~line 4215), `parseDropStatement` (~line 5550), `parseShowStatement` (~line 5303). Add new private parse fns near `parseBackupStatement` (~line 6160). Helpers added near `expectIdentifierOrKeyword` (~line 268).

- [ ] **Step 1: Add small helpers in `Parser`**

After `expectIdentifierOrKeyword` (~line 268), add:

```zig
/// Read an object name: an identifier or a quoted identifier.
fn parseName(self: *Parser) ParserError![]const u8 {
    if (self.cur.kind == .quoted_identifier or self.cur.kind == .identifier) {
        const out = self.cur.lexeme;
        self.advance();
        return out;
    }
    return self.unexpected("expected a name (identifier)");
}

/// Read a quoted string literal.
fn parseStringLit(self: *Parser) ParserError![]const u8 {
    if (self.cur.kind != .string_lit) return self.unexpected("expected a quoted string literal");
    const out = self.cur.lexeme;
    self.advance();
    return out;
}

/// True if the current token is an identifier whose text equals `kw` (case-insensitive).
fn softKw(self: *Parser, kw: []const u8) bool {
    return self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, kw);
}
```

> Grep first for an existing string-literal helper: `grep -n "fn parseString\|string_lit" src/gql/parser.zig`. If one already exists, reuse it and drop `parseStringLit`.

- [ ] **Step 2: Hook `CREATE USER` / `CREATE ROLE` into `parseCreateStatement`**

In `parseCreateStatement` (~line 4215), add a soft-keyword check **before** the existing `.GRAPH` / `.PROPERTY` / `.SCHEMA` / `.INDEX` / `.CONSTRAINT` dispatch (so `USER`/`ROLE` win):

```zig
        if (self.softKw("USER")) {
            self.advance(); // consume USER
            return self.parseCreateUser();
        }
        if (self.softKw("ROLE")) {
            self.advance(); // consume ROLE
            return self.parseCreateRole();
        }
```

- [ ] **Step 3: Add `parseCreateUser` and `parseCreateRole`** (near `parseBackupStatement`, ~line 6160):

```zig
fn parseCreateUser(self: *Parser) ParserError!ast.Statement {
    const name = try self.parseName();
    _ = try self.expect(.SET);
    if (!self.softKw("PASSWORD")) return self.unexpected("expected PASSWORD after SET in CREATE USER");
    self.advance(); // PASSWORD
    const password = try self.parseStringLit();

    var email: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    // Order-independent trailing options: EMAIL <str> and ROLE <name>
    while (self.softKw("EMAIL") or self.softKw("ROLE")) {
        if (self.softKw("EMAIL")) {
            self.advance();
            email = try self.parseStringLit();
        } else { // ROLE
            self.advance();
            role = try self.parseName();
        }
    }
    return .{ .CreateUser = .{ .name = name, .password = password, .email = email, .role = role } };
}

fn parseCreateRole(self: *Parser) ParserError!ast.Statement {
    const name = try self.parseName();
    var description: ?[]const u8 = null;
    if (self.cur.kind == .SET) {
        self.advance();
        if (!self.softKw("DESCRIPTION")) return self.unexpected("expected DESCRIPTION after SET in CREATE ROLE");
        self.advance();
        description = try self.parseStringLit();
    }
    return .{ .CreateRole = .{ .name = name, .description = description } };
}
```

- [ ] **Step 4: Hook `DROP USER` / `DROP ROLE` into `parseDropStatement`**

In `parseDropStatement` (~line 5550), before `return error.UnexpectedToken;`, add:

```zig
        if (self.softKw("USER")) {
            self.advance();
            return self.parseDropUserOrRole(true);
        }
        if (self.softKw("ROLE")) {
            self.advance();
            return self.parseDropUserOrRole(false);
        }
```

And add the parse fn near the others:

```zig
fn parseDropUserOrRole(self: *Parser, is_user: bool) ParserError!ast.Statement {
    var if_exists = false;
    if (self.cur.kind == .IF) {
        self.advance();
        if (self.cur.kind != .EXISTS) return self.unexpected("expected EXISTS after IF");
        self.advance();
        if_exists = true;
    }
    const name = try self.parseName();
    if (is_user) return .{ .DropUser = .{ .name = name, .if_exists = if_exists } };
    return .{ .DropRole = .{ .name = name, .if_exists = if_exists } };
}
```

- [ ] **Step 5: Hook `ALTER`, `GRANT`, `REVOKE` into `parseStatement`'s `.identifier` arm**

In `parseStatement` (~line 602), the `.identifier => blk_ident: { ... }` block currently handles `BACKUP`/`RESTORE`. Extend it (keep the existing two branches; add three):

```zig
            .identifier => blk_ident: {
                if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "BACKUP")) {
                    break :blk_ident self.parseBackupStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "RESTORE")) {
                    break :blk_ident self.parseRestoreStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "ALTER")) {
                    break :blk_ident self.parseAlterStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "GRANT")) {
                    break :blk_ident self.parseGrantStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "REVOKE")) {
                    break :blk_ident self.parseRevokeStatement();
                }
                return error.UnexpectedToken;
            },
```

- [ ] **Step 6: Add `parseAlterStatement`, `parseGrantStatement`, `parseRevokeStatement`** (near the others):

```zig
fn parseAlterStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.identifier); // ALTER
    if (!self.softKw("USER")) return self.unexpected("only ALTER USER is supported");
    self.advance(); // USER
    const name = try self.parseName();

    if (self.softKw("ENABLE")) {
        self.advance();
        return .{ .AlterUser = .{ .name = name, .action = .enable } };
    }
    if (self.softKw("DISABLE")) {
        self.advance();
        return .{ .AlterUser = .{ .name = name, .action = .disable } };
    }
    _ = try self.expect(.SET);
    if (self.softKw("PASSWORD")) {
        self.advance();
        const pw = try self.parseStringLit();
        return .{ .AlterUser = .{ .name = name, .action = .{ .set_password = pw } } };
    }
    if (self.softKw("ROLE")) {
        self.advance();
        const r = try self.parseName();
        return .{ .AlterUser = .{ .name = name, .action = .{ .set_role = r } } };
    }
    return self.unexpected("expected PASSWORD or ROLE after ALTER USER ... SET");
}

fn parseGrantPrivilege(self: *Parser) ParserError!ast.GrantPrivilege {
    switch (self.cur.kind) {
        .READ => { self.advance(); return .read; },
        .WRITE => { self.advance(); return .write; },
        .SCHEMA => { self.advance(); return .schema; },
        .ALL => { self.advance(); return .all; },
        else => return self.unexpected("expected one of READ, WRITE, SCHEMA, ALL"),
    }
}

fn parseOnGraphClause(self: *Parser) ParserError!?[]const u8 {
    if (self.cur.kind != .ON) return null;
    self.advance(); // ON
    if (self.cur.kind != .GRAPH) return self.unexpected("expected GRAPH after ON");
    self.advance(); // GRAPH
    return try self.parseName();
}

fn parseGrantStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.identifier); // GRANT
    if (self.softKw("ROLE")) {
        self.advance(); // ROLE
        const role_name = try self.parseName();
        _ = try self.expect(.TO);
        const grantee = try self.parseName();
        return .{ .Grant = .{ .subject = .{ .role = role_name }, .on_graph = null, .grantee = grantee } };
    }
    const priv = try self.parseGrantPrivilege();
    const on_graph = try self.parseOnGraphClause();
    _ = try self.expect(.TO);
    const grantee = try self.parseName();
    return .{ .Grant = .{ .subject = .{ .privilege = priv }, .on_graph = on_graph, .grantee = grantee } };
}

fn parseRevokeStatement(self: *Parser) ParserError!ast.Statement {
    _ = try self.expect(.identifier); // REVOKE
    const priv = try self.parseGrantPrivilege();
    const on_graph = try self.parseOnGraphClause();
    _ = try self.expect(.FROM);
    const grantee = try self.parseName();
    return .{ .Revoke = .{ .privilege = priv, .on_graph = on_graph, .grantee = grantee } };
}
```

- [ ] **Step 7: Add `SHOW USERS` / `SHOW ROLES` to `parseShowStatement`**

In `parseShowStatement` (~line 5303), inside the `if (std.ascii.eqlIgnoreCase(type_str, ...))` chain, add two branches before the `else { return error.UnexpectedToken; }`:

```zig
            } else if (std.ascii.eqlIgnoreCase(type_str, "USERS") or
                std.ascii.eqlIgnoreCase(type_str, "USER"))
            {
                break :blk .users;
            } else if (std.ascii.eqlIgnoreCase(type_str, "ROLES") or
                std.ascii.eqlIgnoreCase(type_str, "ROLE"))
            {
                break :blk .roles;
```

- [ ] **Step 8: Build (parser changes should compile; execution/print still broken)**

Run: `zig build 2>&1 | head -40`
Expected: `parser.zig` itself compiles; remaining errors are still only the exhaustive switches noted in Task 1 Step 4. If `parser.zig` errors, fix it now.

- [ ] **Step 9: Commit**

```bash
git add src/gql/parser.zig
git commit -m "feat(gql): parse auth DDL statements (soft-keyword grammar)"
```

---

### Task 3: Print support — make the `ast.Statement` exhaustive switches compile

**Files:**
- Modify: `src/gql/print.zig` (`tagName`, ~line 154)
- Modify: any *other* file Task 1 Step 4 flagged with an exhaustive `switch` over `ast.Statement` (e.g. a semantic-analysis pass, `src/gql/main.zig`). For each, the fix is a trivial passthrough/no-op arm — the new statements have no nested clauses worth walking.

- [ ] **Step 1: Add `tagName` arms in `src/gql/print.zig`**

In `fn tagName(st: ast.Statement) []const u8` (line 154), add before the closing `};`:

```zig
        .CreateUser => "CreateUser",
        .AlterUser => "AlterUser",
        .DropUser => "DropUser",
        .CreateRole => "CreateRole",
        .DropRole => "DropRole",
        .Grant => "Grant",
        .Revoke => "Revoke",
```

- [ ] **Step 2: Fix any other flagged exhaustive switches**

For each file:line from Task 1 Step 4 that is *not* `print.zig` `tagName` and *not* `execution.zig` `executeStatementWithContext` (handled in Task 6): open it, find the `switch` over the statement, add the seven new arms. If the switch is "walk nested expressions / collect temporals / semantic-check", the correct body is empty (these statements carry only string fields):

```zig
        .CreateUser, .AlterUser, .DropUser, .CreateRole, .DropRole, .Grant, .Revoke => {},
```

(If a switch *returns* a value, mirror what a comparable simple statement like `.Backup` or `.CreateSchema` returns.)

- [ ] **Step 3: Build**

Run: `zig build 2>&1 | head -40`
Expected: the only remaining error is in `src/execution.zig` (`executeStatementWithContext` and/or a `ShowType` switch) — fixed in Task 6. If other files still error, repeat Step 2.

- [ ] **Step 4: Commit**

```bash
git add src/gql/print.zig
# plus any other files touched in Step 2
git commit -m "feat(gql): handle auth DDL statements in AST visitor switches"
```

---

### Task 4: `auth_dispatch` helper — synthesize a CALL and reuse the authorized handler

**Files:**
- Modify: `src/execution/auth_dispatch.zig` (the `execute` fn is at line 282; `ast` is imported at line 53, `value_types`/`Value` at lines 54-58 and around line 67)

- [ ] **Step 1: Verify the `ast.Expr.Ident` payload type**

Run: `grep -n "IdentRepr\|Ident:" src/gql/ast.zig`
The handlers never read the callee, so any valid `Ident` value works — but you need the right type to construct it. If `IdentRepr == []const u8` (a typical alias), `.{ .Ident = "" }` is fine; otherwise use that type's zero value. **Note what you found.**

- [ ] **Step 2: Add the public helper at the end of `src/execution/auth_dispatch.zig`**

```zig
// ---------------------------------------------------------------------------
// DDL bridge: lets src/execution/admin_ddl.zig invoke the existing geode.auth.*
// handlers with plain string arguments. Authorization (Admin-required for write
// procedures), audit, password policy, and __geode_security persistence all run
// through the unchanged execute() path -- nothing is reimplemented here.
// ---------------------------------------------------------------------------

/// Build a synthetic `CALL <proc_name>(arg0, arg1, ...)` with String literal
/// arguments and dispatch it through `execute()`. Caller owns the returned
/// ExecutionResult (free with `result.deinit(allocator)`).
pub fn callAuthProcedure(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    proc_name: []const u8,
    string_args: []const []const u8,
) !ExecutionResult {
    const arg_ptrs = try allocator.alloc(*ast.Expr, string_args.len);
    defer allocator.free(arg_ptrs);
    var made: usize = 0;
    defer {
        var i: usize = 0;
        while (i < made) : (i += 1) allocator.destroy(arg_ptrs[i]);
    }
    for (string_args, 0..) |s, i| {
        const e = try allocator.create(ast.Expr);
        e.* = .{ .String = s };
        arg_ptrs[i] = e;
        made = i + 1;
    }

    const callee = try allocator.create(ast.Expr);
    defer allocator.destroy(callee);
    callee.* = .{ .Ident = "" }; // STEP 1: replace "" if IdentRepr is not []const u8

    const call_proc = ast.CallProcedure{
        .procedure = .{ .Call = .{ .callee = callee, .args = arg_ptrs } },
    };

    const maybe = try execute(allocator, proc_name, call_proc, context);
    return maybe orelse error.UnknownProcedure;
}
```

- [ ] **Step 3: Build**

Run: `zig build 2>&1 | head -30`
Expected: `auth_dispatch.zig` compiles; still only `execution.zig` errors remain.

- [ ] **Step 4: Commit**

```bash
git add src/execution/auth_dispatch.zig
git commit -m "feat(execution): add auth_dispatch.callAuthProcedure DDL bridge"
```

---

### Task 5: `admin_ddl.zig` — map AST variants onto `geode.auth.*` calls

**Files:**
- Create: `src/execution/admin_ddl.zig`

- [ ] **Step 1: Verify two facts before writing**

Run: `grep -n "pub const Value" src/execution.zig` — if `execution.zig` does not re-export `Value`, in the file below replace `execution.Value` with `value_types.Value` and add `const value_types = @import("../value_types.zig");`.
Run: `grep -n "UserNotFound\|RoleNotFound\|NotFound" src/execution/auth_dispatch.zig src/security/user_management.zig` and re-read `handleUserDelete` (`src/execution/auth_dispatch.zig:396`) and `handleRoleDelete` (`:751`): determine whether a missing entity surfaces as a Zig `error.*` or as a result row with `status: "error: ..."`. If it's a Zig error, note the exact name(s) for the `if_exists` swallow below. If it's a result row (like `handleUserCreate`'s failure path), then there is nothing to catch — drop the `catch` blocks below and just return the result; leave a one-line comment that `IF EXISTS` is a no-op because the handler already degrades gracefully.

- [ ] **Step 2: Create `src/execution/admin_ddl.zig`**

```zig
//! Geode extension: execution of auth DDL statements (CREATE/ALTER/DROP USER,
//! CREATE/DROP ROLE, GRANT/REVOKE, SHOW USERS/ROLES). Every variant maps onto an
//! existing geode.auth.* procedure handler via auth_dispatch.callAuthProcedure,
//! so authorization, audit, password policy, and persistence are inherited.
// CANARY: REQ=REQ-GQL-AUTH-DDL-001; FEATURE="GQL Auth DDL"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=parser; UPDATED=2026-05-11

const std = @import("std");
const ast = @import("../gql/ast.zig");
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const auth_dispatch = @import("auth_dispatch.zig");
const Value = execution.Value; // STEP 1: switch to value_types.Value if not re-exported

fn emptyResult(allocator: std.mem.Allocator) !ExecutionResult {
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

pub fn executeCreateUser(allocator: std.mem.Allocator, s: ast.CreateUserStatement, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_create", &.{
        s.name,
        s.password,
        s.email orelse "",
        s.role orelse "user",
    });
}

pub fn executeAlterUser(allocator: std.mem.Allocator, s: ast.AlterUserStatement, ctx: ExecutionContext) !ExecutionResult {
    return switch (s.action) {
        .set_password => |pw| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_reset_password", &.{ s.name, pw }),
        .set_role => |r| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_assign_role", &.{ s.name, r }),
        .enable => auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_enable", &.{s.name}),
        .disable => auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_disable", &.{s.name}),
    };
}

pub fn executeDropUser(allocator: std.mem.Allocator, s: ast.DropUserStatement, ctx: ExecutionContext) !ExecutionResult {
    const r = auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_delete", &.{s.name});
    if (s.if_exists) {
        return r catch |err| switch (err) {
            error.UserNotFound, error.NotFound => return emptyResult(allocator), // STEP 1: adjust to real error set
            else => return err,
        };
    }
    return r;
}

pub fn executeCreateRole(allocator: std.mem.Allocator, s: ast.CreateRoleStatement, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_create", &.{ s.name, s.description orelse "" });
}

pub fn executeDropRole(allocator: std.mem.Allocator, s: ast.DropRoleStatement, ctx: ExecutionContext) !ExecutionResult {
    const r = auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_delete", &.{s.name});
    if (s.if_exists) {
        return r catch |err| switch (err) {
            error.RoleNotFound, error.NotFound => return emptyResult(allocator), // STEP 1: adjust to real error set
            else => return err,
        };
    }
    return r;
}

pub fn executeGrant(allocator: std.mem.Allocator, s: ast.GrantStatement, ctx: ExecutionContext) !ExecutionResult {
    return switch (s.subject) {
        .role => |role_name| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_assign_role", &.{ s.grantee, role_name }),
        .privilege => |p| auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.grant", &.{
            ast.grantPrivilegeName(p),
            s.grantee,
            s.on_graph orelse "",
        }),
    };
}

pub fn executeRevoke(allocator: std.mem.Allocator, s: ast.RevokeStatement, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.revoke", &.{
        ast.grantPrivilegeName(s.privilege),
        s.grantee,
        s.on_graph orelse "",
    });
}

pub fn executeShowUsers(allocator: std.mem.Allocator, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_list", &.{});
}

pub fn executeShowRoles(allocator: std.mem.Allocator, ctx: ExecutionContext) !ExecutionResult {
    return auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.role_list", &.{});
}
```

- [ ] **Step 3: Wire into the build only if execution submodules are registered individually**

Run: `grep -n "execution/auth_dispatch\|execution/statement_handlers\|execution/storage_dispatch" build.zig`
- If those appear: add `src/execution/admin_ddl.zig` the same way alongside `auth_dispatch.zig`.
- If they do not appear (the usual case — submodules are reached via `@import` from `execution.zig`): no `build.zig` change; the file becomes live when Task 6 adds the `@import`.

- [ ] **Step 4: Build** — `zig build 2>&1 | grep admin_ddl` should be empty (the file is syntactically valid). The build still fails on the `execution.zig` switch until Task 6.

- [ ] **Step 5: Commit**

```bash
git add src/execution/admin_ddl.zig build.zig
git commit -m "feat(execution): add admin_ddl module mapping auth DDL to geode.auth.* handlers"
```

---

### Task 6: Wire execution dispatch in `src/execution.zig`

**Files:**
- Modify: `src/execution.zig` — `executeStatementWithContext` switch (~line 965), and the `.Show` arm (find where `ShowStatement` is handled — it delegates to `statement_handlers.executeShow`; we intercept `users`/`roles` first).

- [ ] **Step 1: Import `admin_ddl` at the top of `src/execution.zig`**

Near the other `@import("execution/...")` lines (search for an existing `auth_dispatch`/`statement_handlers` import):

```zig
const admin_ddl = @import("execution/admin_ddl.zig");
```

- [ ] **Step 2: Add the 7 new arms to the `executeStatementWithContext` switch (~line 965)**

```zig
        .CreateUser => |s| return admin_ddl.executeCreateUser(allocator, s, context),
        .AlterUser => |s| return admin_ddl.executeAlterUser(allocator, s, context),
        .DropUser => |s| return admin_ddl.executeDropUser(allocator, s, context),
        .CreateRole => |s| return admin_ddl.executeCreateRole(allocator, s, context),
        .DropRole => |s| return admin_ddl.executeDropRole(allocator, s, context),
        .Grant => |s| return admin_ddl.executeGrant(allocator, s, context),
        .Revoke => |s| return admin_ddl.executeRevoke(allocator, s, context),
```

> Match the surrounding style — if nearby arms use `.X => { ... return ExecutionResult{...}; }`, write `.CreateUser => |s| { return admin_ddl.executeCreateUser(allocator, s, context); },` etc. Either compiles.

- [ ] **Step 3: Route `SHOW USERS` / `SHOW ROLES`**

Find the `.Show => |show_stmt| { ... }` arm. Before it delegates to the existing show handler, add:

```zig
            switch (show_stmt.show_type) {
                .users => return admin_ddl.executeShowUsers(allocator, context),
                .roles => return admin_ddl.executeShowRoles(allocator, context),
                else => {},
            }
            // ... existing delegation continues here
```

> If `.Show` is actually dispatched inside `src/execution/statement_handlers.zig` `executeShow` via its own `switch (show_type)`, add the two arms there instead — `zig build` will point at the exhaustive `ShowType` switch that needs them. Pick whichever location already owns the `ShowType` switch; the other one needs `.users, .roles => {}` (or delegation) too.

- [ ] **Step 4: Build — should now be green**

Run: `zig build 2>&1 | head -30`
Expected: builds with no errors. If any `ShowType` exhaustive switch elsewhere complains, add `.users, .roles => {}` there.

- [ ] **Step 5: Run the existing unit-test suite to confirm no regressions**

Run: `zig build test 2>&1 | tail -30`
Expected: same pass/fail counts as before this branch. There are known pre-existing perf/coordinator failures unrelated to this work — compare against a clean `git stash` baseline if unsure. No *new* failures.

- [ ] **Step 6: Commit**

```bash
git add src/execution.zig src/execution/statement_handlers.zig
git commit -m "feat(execution): dispatch auth DDL statements + SHOW USERS/ROLES"
```

---

### Task 7: Parser unit tests

**Files:**
- Create: `tests/test_auth_ddl_parser.zig`
- Modify: `tests/all_tests.zig` (only if it lists test files individually — check first)

- [ ] **Step 1: Inspect how an existing parser test is wired**

Run: `sed -n '1,30p' tests/test_count_distinct_parser.zig` and `grep -n "test_count_distinct_parser\|test_user_management" tests/all_tests.zig build.zig`. Note whether `tests/all_tests.zig` does `_ = @import("test_xxx.zig");` per file, or whether the build globs `tests/test_*.zig`, or whether each test file is a separate build step.

- [ ] **Step 2: Write the test file `tests/test_auth_ddl_parser.zig`**

```zig
const std = @import("std");
const parser_mod = @import("gql/parser.zig");
const lexer_mod = @import("gql/lexer.zig");
const ast = @import("gql/ast.zig");

// CANARY: REQ=REQ-GQL-AUTH-DDL-002; FEATURE="GQL Auth DDL"; ASPECT=Parser; STATUS=TESTED; TEST=self; OWNER=parser; UPDATED=2026-05-11

fn parseOne(src: []const u8, arena: *std.heap.ArenaAllocator) !ast.Statement {
    var lx = lexer_mod.Lexer.init(src);
    var p = parser_mod.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.statements.len);
    return prog.statements[0];
}

test "parse CREATE USER with password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE USER alice SET PASSWORD 's3cret!1'", &arena);
    try std.testing.expect(st == .CreateUser);
    try std.testing.expectEqualStrings("alice", st.CreateUser.name);
    try std.testing.expectEqualStrings("s3cret!1", st.CreateUser.password);
    try std.testing.expect(st.CreateUser.email == null);
    try std.testing.expect(st.CreateUser.role == null);
}

test "parse CREATE USER with email and role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE USER bob SET PASSWORD 'pw12345x' EMAIL 'bob@x.io' ROLE readwrite", &arena);
    try std.testing.expect(st == .CreateUser);
    try std.testing.expectEqualStrings("bob@x.io", st.CreateUser.email.?);
    try std.testing.expectEqualStrings("readwrite", st.CreateUser.role.?);
}

test "parse ALTER USER SET PASSWORD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER USER alice SET PASSWORD 'newpass99'", &arena);
    try std.testing.expect(st == .AlterUser);
    try std.testing.expect(st.AlterUser.action == .set_password);
    try std.testing.expectEqualStrings("newpass99", st.AlterUser.action.set_password);
}

test "parse ALTER USER SET ROLE / ENABLE / DISABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        const st = try parseOne("ALTER USER alice SET ROLE admin", &arena);
        try std.testing.expect(st.AlterUser.action == .set_role);
        try std.testing.expectEqualStrings("admin", st.AlterUser.action.set_role);
    }
    {
        const st = try parseOne("ALTER USER alice ENABLE", &arena);
        try std.testing.expect(st.AlterUser.action == .enable);
    }
    {
        const st = try parseOne("ALTER USER alice DISABLE", &arena);
        try std.testing.expect(st.AlterUser.action == .disable);
    }
}

test "parse DROP USER / DROP ROLE with IF EXISTS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        const st = try parseOne("DROP USER alice", &arena);
        try std.testing.expect(st == .DropUser);
        try std.testing.expectEqualStrings("alice", st.DropUser.name);
        try std.testing.expect(!st.DropUser.if_exists);
    }
    {
        const st = try parseOne("DROP ROLE IF EXISTS auditor", &arena);
        try std.testing.expect(st == .DropRole);
        try std.testing.expectEqualStrings("auditor", st.DropRole.name);
        try std.testing.expect(st.DropRole.if_exists);
    }
}

test "parse CREATE ROLE with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE ROLE auditor SET DESCRIPTION 'read-only auditor'", &arena);
    try std.testing.expect(st == .CreateRole);
    try std.testing.expectEqualStrings("auditor", st.CreateRole.name);
    try std.testing.expectEqualStrings("read-only auditor", st.CreateRole.description.?);
}

test "parse GRANT ROLE TO user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("GRANT ROLE auditor TO alice", &arena);
    try std.testing.expect(st == .Grant);
    try std.testing.expect(st.Grant.subject == .role);
    try std.testing.expectEqualStrings("auditor", st.Grant.subject.role);
    try std.testing.expectEqualStrings("alice", st.Grant.grantee);
}

test "parse GRANT privilege ON GRAPH TO user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("GRANT READ ON GRAPH sales TO alice", &arena);
    try std.testing.expect(st == .Grant);
    try std.testing.expect(st.Grant.subject == .privilege);
    try std.testing.expect(st.Grant.subject.privilege == .read);
    try std.testing.expectEqualStrings("sales", st.Grant.on_graph.?);
    try std.testing.expectEqualStrings("alice", st.Grant.grantee);
}

test "parse REVOKE privilege FROM user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("REVOKE WRITE FROM alice", &arena);
    try std.testing.expect(st == .Revoke);
    try std.testing.expect(st.Revoke.privilege == .write);
    try std.testing.expect(st.Revoke.on_graph == null);
    try std.testing.expectEqualStrings("alice", st.Revoke.grantee);
}

test "parse SHOW USERS / SHOW ROLES" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        const st = try parseOne("SHOW USERS", &arena);
        try std.testing.expect(st == .Show);
        try std.testing.expect(st.Show.show_type == .users);
    }
    {
        const st = try parseOne("SHOW ROLES", &arena);
        try std.testing.expect(st.Show.show_type == .roles);
    }
}
```

- [ ] **Step 3: Wire the test file in (only if Step 1 showed it's needed)**

If `tests/all_tests.zig` lists per-file imports: add `_ = @import("test_auth_ddl_parser.zig");` next to the other parser tests. If the build globs `tests/test_*.zig`, do nothing. If individual files become build steps, add one matching `test_count_distinct_parser.zig`'s pattern in `build.zig`.

- [ ] **Step 4: Run the new tests — expect PASS**

Run: `zig build test 2>&1 | grep -iE "auth_ddl|[0-9]+ (passed|failed)"` (or whatever single-file/focused invocation the other `tests/test_*.zig` use — check `build.zig`).
Expected: all 10 new tests PASS, no new failures elsewhere. If a test fails, the usual culprit is a soft keyword you forgot to `advance()` past, or `parseName` not accepting the token kind in question — fix in Task 2.

- [ ] **Step 5: Commit**

```bash
git add tests/test_auth_ddl_parser.zig tests/all_tests.zig
git commit -m "test(gql): parser unit tests for auth DDL statements"
```

---

### Task 8: Over-the-wire integration test (geodetestlab)

**Files:**
- Create: `../geode-test-harness/geodetestlab-cli/specs/geode_auth_ddl.yml`

This is the real "over the wire" verification — boots a geode server (auth enabled, `GEODE_ADMIN_PASSWORD` set), connects as admin, runs the DDL, asserts on results. **Do not mock anything — run against the real binary** (project rule: "NO MOCK DATA, NO SIMULATION").

- [ ] **Step 1: Inspect an existing spec to copy the exact YAML schema**

Run: `ls ../geode-test-harness/geodetestlab-cli/specs/ | grep -iE "auth|user|admin|security"` and `grep -rl "geode.auth" ../geode-test-harness/geodetestlab-cli/specs/`. `cat` the closest match. Match its structure exactly (step keys, expectation syntax, how it sets env / admin creds, how it asserts on rows/errors). If no auth spec exists, copy the structure of any spec that runs a sequence of queries and checks output.

- [ ] **Step 2: Write `geode_auth_ddl.yml` (adapt field names to the harness's actual schema from Step 1)**

```yaml
name: geode_auth_ddl
description: GQL auth DDL (CREATE/ALTER/DROP USER, ROLE, GRANT/REVOKE, SHOW) over the wire
# auth must be enabled; the harness should connect as the bootstrap admin (GEODE_ADMIN_PASSWORD)
steps:
  - name: create user
    query: "CREATE USER ddl_alice SET PASSWORD 'Passw0rd!ddl' EMAIL 'alice@ddl.test' ROLE readwrite"
    expect:
      rows_min: 1
      row_contains: "created ddl_alice"      # handleUserCreate status -> "created <name>" (verify wording)

  - name: show users includes alice
    query: "SHOW USERS"
    expect:
      row_contains: "ddl_alice"

  - name: create role
    query: "CREATE ROLE ddl_auditor SET DESCRIPTION 'integration test role'"
    expect: { rows_min: 1 }

  - name: grant role to user
    query: "GRANT ROLE ddl_auditor TO ddl_alice"
    expect: { rows_min: 1 }

  - name: alter user password
    query: "ALTER USER ddl_alice SET PASSWORD 'Passw0rd!ddl2'"
    expect: { rows_min: 1 }

  - name: disable then enable
    query: "ALTER USER ddl_alice DISABLE"
    expect: { rows_min: 1 }
  - name: re-enable
    query: "ALTER USER ddl_alice ENABLE"
    expect: { rows_min: 1 }

  - name: grant privilege on graph
    query: "GRANT READ ON GRAPH default TO ddl_alice"
    expect:
      row_contains: "Granted READ"           # handleGrantRevoke status format (verify)

  - name: revoke privilege
    query: "REVOKE READ ON GRAPH default FROM ddl_alice"
    expect:
      row_contains: "Revoked READ"

  - name: drop role idempotent
    query: "DROP ROLE IF EXISTS ddl_auditor"
    expect: { ok: true }

  - name: drop user
    query: "DROP USER ddl_alice"
    expect: { ok: true }

  - name: drop user again without IF EXISTS is an error
    query: "DROP USER ddl_alice"
    expect: { error: true }                  # verify: only if user_delete on missing user surfaces an error

  - name: drop missing user with IF EXISTS is ok
    query: "DROP USER IF EXISTS ddl_alice"
    expect: { ok: true }
```

> Adjust `row_contains` to the exact handler status text — re-read `handleUserCreate`/`handleRoleCreate`/`handleRoleDelete`/`handleUserResetPassword`/`handleUserEnableDisable`/`handleGrantRevoke` in `src/execution/auth_dispatch.zig` (lines ~318-880) for the precise wording, or relax to `rows_min: 1`. If `user_delete` on a missing user does *not* error (matches the `if_exists`/STEP 1 finding in Task 5), delete the "drop user again is an error" step.
> If the harness can open a *second* (non-admin) connection, add one negative step: a non-admin running `CREATE USER ...` must get an authorization error (`auth_dispatch.execute` returns `error.Unauthorized` for non-Admin write procedures). If it can't, leave a `# TODO` and rely on the existing `geode.auth.*` permission tests.

- [ ] **Step 3: Build geode and run the spec**

```bash
zig build -Doptimize=ReleaseSafe        # or `make build` for debug
cd ../geode-test-harness
make test-spec SPEC=geodetestlab-cli/specs/geode_auth_ddl.yml GEODE_BINARY="$(pwd)/../geode/zig-out/bin/geode"
```
Expected: spec passes all steps. Result-text mismatch → fix the expectation, not the handler. Parse error → fix the parser (Task 2). Authorization failure → confirm the harness is connecting as admin.

- [ ] **Step 4: Sanity-check a neighboring spec still passes**

Run: `cd ../geode-test-harness && make test-spec SPEC=<an-existing-auth-or-cli-spec>.yml GEODE_BINARY="$(pwd)/../geode/zig-out/bin/geode"` — confirm no regression nearby.

- [ ] **Step 5: Commit (in the geode-test-harness repo)**

```bash
cd ../geode-test-harness
git add geodetestlab-cli/specs/geode_auth_ddl.yml
git commit -m "test: geodetestlab spec for GQL auth DDL over the wire"
```

---

### Task 9: Documentation + CLAUDE.md

**Files:**
- Create: `docs/GQL_AUTH_DDL.md`
- Modify: `CLAUDE.md`
- (CANARY markers were already added inline in `src/execution/admin_ddl.zig` Task 5 Step 2, `tests/test_auth_ddl_parser.zig` Task 7 Step 2, and `src/gql/parser.zig` — add one there now if not yet done.)

- [ ] **Step 1: Add a CANARY marker near the new parse functions in `src/gql/parser.zig`** (above `parseCreateUser`):

```zig
// CANARY: REQ=REQ-GQL-AUTH-DDL-003; FEATURE="GQL Auth DDL"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_auth_ddl_parser.zig; OWNER=parser; UPDATED=2026-05-11
```

Run `make status-generate` if it exists; confirm `grep -rn "REQ-GQL-AUTH-DDL" .` finds all three markers.

- [ ] **Step 2: Create `docs/GQL_AUTH_DDL.md`**

```markdown
# GQL Auth DDL (Geode extension)

ISO/IEC 39075:2024 GQL does not define user/role/grant statements. Geode adds the
following statements as an extension. They are thin syntactic sugar over the
`geode.auth.*` procedures: identical authorization (Admin required for mutations,
read-only listing for any authenticated user), audit, password policy, and the
HMAC-chained `__geode_security` persistence apply. Authentication itself is still
established by the QUIC `HELLO` handshake — these statements manage *other* users.

## Grammar

    CREATE USER <name> SET PASSWORD <string> [ EMAIL <string> ] [ ROLE <name> ]
    ALTER  USER <name> SET PASSWORD <string>
    ALTER  USER <name> SET ROLE <name>
    ALTER  USER <name> ENABLE | DISABLE
    DROP   USER <name> [ IF EXISTS ]

    CREATE ROLE <name> [ SET DESCRIPTION <string> ]
    DROP   ROLE <name> [ IF EXISTS ]

    GRANT  ROLE <rolename> TO <username>
    GRANT  READ | WRITE | SCHEMA | ALL [ ON GRAPH <name> ] TO <username>
    REVOKE READ | WRITE | SCHEMA | ALL [ ON GRAPH <name> ] FROM <username>

    SHOW USERS
    SHOW ROLES

`USER`, `ROLE`, `GRANT`, `REVOKE`, `ALTER`, `PASSWORD`, `EMAIL`, `ENABLE`,
`DISABLE`, `DESCRIPTION` are *soft* keywords (still usable as identifiers).

## Mapping to procedures

| Statement | Procedure |
|---|---|
| `CREATE USER` | `geode.auth.user_create` |
| `ALTER USER … SET PASSWORD` | `geode.auth.user_reset_password` |
| `ALTER USER … SET ROLE` | `geode.auth.user_assign_role` |
| `ALTER USER … ENABLE/DISABLE` | `geode.auth.user_enable` / `geode.auth.user_disable` |
| `DROP USER` | `geode.auth.user_delete` |
| `CREATE ROLE` | `geode.auth.role_create` |
| `DROP ROLE` | `geode.auth.role_delete` |
| `GRANT ROLE … TO …` | `geode.auth.user_assign_role` |
| `GRANT <priv> … TO …` | `geode.auth.grant` |
| `REVOKE <priv> … FROM …` | `geode.auth.revoke` |
| `SHOW USERS` / `SHOW ROLES` | `geode.auth.user_list` / `geode.auth.role_list` |

## Known limitations

- `GRANT <privilege>` / `REVOKE <privilege>` route to `geode.auth.grant` /
  `geode.auth.revoke`, which acknowledge the request but do not yet persist a
  per-graph privilege grant — only the role-assignment form (`GRANT ROLE … TO …`,
  `ALTER USER … SET ROLE …`) changes durable state today. Durable privilege grants
  are tracked for a follow-up plan.
- `CREATE POLICY` (RLS), FLE schema DDL, and tenant DDL are *not* part of this
  surface — use `CALL geode.fle.*` and the RLS engine API for now.
```

- [ ] **Step 3: Update `CLAUDE.md`**

In the feature list (the "✅ ALL MAJOR FEATURES" section or a parser/security bullet) add:
`**GQL Auth DDL** — CREATE/ALTER/DROP USER, CREATE/DROP ROLE, GRANT/REVOKE, SHOW USERS/ROLES (Geode extension; see docs/GQL_AUTH_DDL.md). Routes to existing geode.auth.* handlers — same authorization, audit, persistence.`
And under "Known Limitations":
`**Privilege grants not persistent (yet)**: GRANT/REVOKE <privilege> route to geode.auth.grant/revoke which do not yet persist per-graph grants; GRANT ROLE … TO … does persist. Follow-up plan tracked.`

- [ ] **Step 4: Build + full test once more**

Run: `zig build && zig build test 2>&1 | tail -20`
Expected: green build; no new test failures vs. baseline.

- [ ] **Step 5: Commit**

```bash
git add src/gql/parser.zig docs/GQL_AUTH_DDL.md CLAUDE.md
git commit -m "docs(gql): document auth DDL extension; add CANARY markers"
```

---

## Self-Review

- **Spec coverage** — the user asked for "CREATE USER/ROLE/POLICY/GRANT over the wire … and FLE support and all user management, tenant management, etc." This plan delivers the **auth DDL core** (USER/ROLE/GRANT/REVOKE + ALTER USER + SHOW USERS/ROLES) — the agreed Phase-1 scope (the user chose "auth DDL core first" + "GQL-flavored / minimal" + "reuse existing dispatch handlers"). `POLICY` DDL, FLE DDL, and tenant DDL are explicitly deferred to follow-up plans; the deferral is stated in the header, `docs/GQL_AUTH_DDL.md`, and `CLAUDE.md`.
- **Placeholder scan** — every code step contains complete code. Four points are marked "verify"/"STEP 1" rather than guessed, because they are facts about types/error-sets that can't be pinned without running the build: (1) `ast.Expr.Ident`'s payload type (`IdentRepr`), (2) whether `execution.zig` re-exports `Value`, (3) the exact error/result behavior of `handleUserDelete`/`handleRoleDelete` on a missing entity, (4) the exact handler status-text wording for the geodetestlab assertions. Each carries the exact `grep` to run and a fallback. This is intentional — inventing field names would be worse.
- **Type consistency** — `CreateUserStatement` / `AlterUserStatement` / `DropUserStatement` / `CreateRoleStatement` / `DropRoleStatement` / `GrantStatement` / `RevokeStatement`, `AlterUserAction` (`.set_password`/`.set_role`/`.enable`/`.disable`), `GrantSubject` (`.role`/`.privilege`), `GrantPrivilege` (`.read`/`.write`/`.schema`/`.all`), and `grantPrivilegeName` are defined in Task 1 and used with the same names/fields in Tasks 2, 3, 5, 6, 7. `auth_dispatch.callAuthProcedure(allocator, context, proc_name, string_args)` is defined in Task 4 and called with that exact signature in Task 5. `admin_ddl.executeCreateUser/executeAlterUser/executeDropUser/executeCreateRole/executeDropRole/executeGrant/executeRevoke/executeShowUsers/executeShowRoles` are defined in Task 5 and called in Task 6. `ShowType.users`/`.roles` added in Task 1, parsed in Task 2 Step 7, dispatched in Task 6 Step 3, tested in Task 7. Consistent.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-11-gql-auth-ddl.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?

---

# ADDENDUM (2026-05-11) — expanded scope per user feedback during execution

The user added two requirements mid-execution. This addendum amends the plan; where it conflicts with the tasks above, the addendum wins.

## A. Built-in `admin` role must be first-class; default user is a member

Findings: `src/security/user_management.zig` `ensureDefaultUser` already creates the bootstrap user with `Role.Admin`, and `src/execution/auth_dispatch.zig` `handleRoleList` already lists built-in roles `["admin","user","readwrite","readonly"]`. **But** `handleUserAssignRole` (`src/execution/auth_dispatch.zig`) is a status-formatting **stub** — it does not mutate the user's role. So `ALTER USER x SET ROLE admin` / `GRANT ROLE admin TO x` would lie.

**Fix (new Task — "Backend: real role assignment + built-in role hardening", runs after Task 4, before the admin_ddl module):**
- In `src/security/user_management.zig`: add `pub fn assignRole(allocator, username, role: Role) !void` that looks up the user (in-memory cache and persistent resolver), validates, sets `user.role`, increments `auth_version` (to invalidate live sessions — mirror `updateUserPassword`), and re-persists via whatever path `updateUserPassword`/`createUser` use. Return `error.UserNotFound` if absent.
- In `src/execution/auth_dispatch.zig` `handleUserAssignRole`: parse the `role` arg, resolve via `user_mgmt.Role.fromString` first; if that returns null, accept a *custom* role name only if it exists in `g_custom_roles` (otherwise `error.RoleNotFound` / a `"error: unknown role"` status row, matching how other handlers report failures). On a recognized built-in role, call `user_mgmt.assignRole(...)`. (Custom-role membership beyond the built-in enum is not modeled on `User` today; for a custom role, record nothing structural but return a clear status — do **not** silently claim success on an unknown role.)
- In `handleRoleCreate`: if `role_name` case-insensitively matches a built-in (`admin`/`user`/`readwrite`/`readonly`), do **not** add it to `g_custom_roles`; return status `"already exists: <name> (built-in)"`.
- In `handleRoleList`: skip any `g_custom_roles` entry whose key case-insensitively shadows a built-in (dedup).
- Tests: extend `tests/test_user_management.zig` (or add `tests/test_role_assignment.zig`) — create a user as `user`, assign `admin`, assert the stored role changed and `auth_version` bumped; assign an unknown role → error; `role_create("admin")` → no duplicate in `role_list`.

## B. Wire introspection: `SHOW VERSION`, `SHOW CAPABILITIES`, `SHOW PERMISSIONS [FOR <user>]`

The geode-ui needs the connected server's version and an `admin_writable` capability over the wire, plus a `SHOW PERMISSIONS`-style RBAC introspection op. Add three more `SHOW` forms (Geode extensions, not ISO GQL):

- `SHOW VERSION` → one row, column `version`, value = the server build version. Source: `@import("build_options").version` if it carries a real version; otherwise fall back to the `.version` field in `build.zig.zon` (`"0.1.4"`) — the implementer should grep and pick the most accurate one. No auth required beyond an established connection.
- `SHOW CAPABILITIES` → rows of `feature, supported` (Value `.Str` "true"/"false" or a Bool — match how other boolean-ish results are emitted in this codebase). Include at minimum: `auth_ddl=true`, `admin_writable=true`, `role_ddl=true`, `grant_ddl=true`, `show_permissions=true`, `policy_ddl=false`, `fle_ddl=false`, `tenant_ddl=false`. This is the canonical accessor the UI's `handlers_capabilities.go` will consult.
- `SHOW PERMISSIONS [FOR <username>]` → maps to `geode.auth.user_permissions(username)`. If `FOR <username>` is omitted, use the current authenticated user (`context.user`); if that is also null (auth disabled), default to `"user"` permissions or return an empty result — match `handleUserPermissions`'s existing behavior. `user_permissions` is in `read_only_set`, so any authenticated user may call it.

**AST changes (additive — done as the first sub-steps of the parser task since Task 1 is already committed):**
- Add to `ShowType`: `permissions`, `version`, `capabilities`.
- Add to `ShowStatement`: `target: ?[]const u8 = null` (the `FOR <username>` argument; null for VERSION/CAPABILITIES and bare PERMISSIONS).

**Parser (extend `parseShowStatement`):** recognize soft keywords `PERMISSIONS`/`PERMISSION`, `VERSION`, `CAPABILITIES`/`CAPABILITY`. For `PERMISSIONS`, optionally consume `FOR` (a real keyword token) then a name into `.target`.

**Execution (extend `admin_ddl.zig` + the `.Show` routing in `execution.zig` / `statement_handlers.zig`):**
- `executeShowPermissions(allocator, target_or_null, ctx)` → username = `target orelse ctx.user orelse ""`; `auth_dispatch.callAuthProcedure(allocator, ctx, "geode.auth.user_permissions", &.{username})`.
- `executeShowVersion(allocator)` → build one-row result with column `version`.
- `executeShowCapabilities(allocator)` → build the `feature, supported` table above. (These two don't go through `auth_dispatch` — there's no `geode.auth.*` handler for them; build the `ExecutionResult` directly in `admin_ddl.zig`, same shape as the handlers do.)

**Tests:** add parser tests for `SHOW VERSION`, `SHOW CAPABILITIES`, `SHOW PERMISSIONS`, `SHOW PERMISSIONS FOR alice` (assert `show_type` and `target`). Add geodetestlab steps: `SHOW VERSION` (rows_min 1), `SHOW CAPABILITIES` (row_contains `admin_writable` and `true`), `SHOW PERMISSIONS FOR <admin user>` (row_contains `schema`), and a role-assignment round-trip: `CREATE USER ddl_carol SET PASSWORD 'Passw0rd!c' ROLE user` → `SHOW PERMISSIONS FOR ddl_carol` (only `read`) → `ALTER USER ddl_carol SET ROLE admin` → `SHOW PERMISSIONS FOR ddl_carol` (now includes `schema`) → cleanup `DROP USER ddl_carol`.

**Docs:** add the three SHOW forms and the role-assignment behavior to `docs/GQL_AUTH_DDL.md` and `CLAUDE.md`. Note for the future POLICY plan: align `CREATE POLICY` to `CREATE POLICY <name> ON <Label> [FOR <op>] [TO <role>] USING (<expr>) [WITH CHECK (<expr>)]` (matches the existing `src/security/rls_core.zig` `Policy` fields `graph/table/operation/roles/using_expr/check_expr`); the geode-ui's guessed `CREATE POLICY … AS '<expr>'` form can be supported as an alias if convenient.
