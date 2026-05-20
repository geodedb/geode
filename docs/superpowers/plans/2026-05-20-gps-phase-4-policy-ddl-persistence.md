# GPS Phase 4 — Policy DDL + Persistent Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the in-memory `g_policies` placeholder map with a real, parser-backed policy catalog persisted in the `__geode_security` graph. Add minimal but useful policy DDL (`CREATE POLICY`, `DROP POLICY`, `SHOW POLICIES`) and wire policy evaluation into `decide()`. Closes fail-open sites #2 (graph grants — promoted to first-class Policy rows) and #3 (RLS no-policy default-allow — policy catalog now owns "allow by absence" explicitly).

**Architecture:** New `src/security/policy_catalog.zig` manages `Policy` records (name, scope, action set, effect, expression source, enabled, timestamps, HMAC). Policies are persisted as `(:Policy)` nodes in `__geode_security`, hydrated at startup via the same machinery `auth_graph_manager` already uses. The expression source compiles to RLS VM bytecode using the existing `rls_core` infrastructure. `decide()` gains an "explicit policy evaluation" step after builtin-role grants but before fallthrough — when a Policy matches the (action, resource) tuple, its expression is evaluated against the principal+resource context; allow/deny is returned per the policy's effect. Sites #2 and #3 close because graph grants now exist as Policy rows and the catalog explicitly records "no policy = absent" (which `decide()` continues to map to deny when no other evidence allows). Phase 4 keeps the surface intentionally small: `CREATE POLICY`, `DROP POLICY`, `SHOW POLICIES` only — `ALTER POLICY`, `SHOW GRANTS`, ABAC attribute predicates, `WITH CHECK`, `MASK` obligations are deferred to Phase 5+.

**Tech Stack:** Zig 0.16.0+, CANARY governance (`REQ=REQ-GPS-DDL-*`, `REQ=REQ-GPS-CATALOG-*`, `REQ=REQ-GPS-POLICY-EVAL-*`).

**Reference design:** `docs/geode-policy-plan.md` — sections "DDL and API specification", "Policy persistence design".

---

## Carry-forward from Phase 3

1. **`resolveRoleFromGraph` coverage gap** — Phase 3 documented this as a Phase 4 remediation task. Extract from `src/server/main.zig` into `src/security/role_resolver.zig`, add isolated unit test.

---

## File Structure

**Create:**
- `src/security/policy_catalog.zig` — `Policy` type, in-memory catalog, `addPolicy`/`removePolicy`/`listPolicies` operations, plus the evaluation entry `evaluatePolicies(principal, action, resource) -> PolicyDecision`. The catalog is process-global and hydrated at startup.
- `src/security/policy_persistence.zig` — Reads/writes Policy nodes in `__geode_security`. Mirrors `auth_graph_manager` style (HMAC-sealed, atomic). Exposes `hydrateCatalog(allocator) -> PolicyCatalog` + `persistPolicy(name, ...) -> !void` + `removePolicy(name) -> !void`.
- `src/security/role_resolver.zig` — Carry-forward from Phase 3. Extracts `resolveRoleFromGraph` from `src/server/main.zig`. Includes the HAS_ROLE edge traversal and the fallback to `authRoleFromRecord`.
- `tests/test_gps_policy_catalog.zig` — Unit tests for in-memory catalog operations.
- `tests/test_gps_policy_persistence.zig` — Persistence round-trip tests.
- `tests/test_gps_policy_ddl_parser.zig` — Parser tests for CREATE / DROP / SHOW POLICY.
- `tests/test_gps_policy_evaluation.zig` — Decision-engine tests: simple allow/deny policies, multiple policies, policy + builtin-role interaction.
- `tests/test_gps_role_resolver.zig` — Isolated unit test for the extracted role resolver.
- `docs/security/gps-policy-ddl.md` — Phase 4 outcome doc covering DDL grammar, catalog lifecycle, evaluation order.

**Modify:**
- `src/gql/ast.zig` — Add `CreatePolicyStatement`, `DropPolicyStatement`, `ShowPoliciesStatement` AST variants.
- `src/gql/parser.zig` — Parse the three statements following the auth DDL pattern (the existing `CREATE USER`/`CREATE ROLE` parser code is the template).
- `src/execution/auth_dispatch.zig` — Replace the in-memory `g_policies` placeholder map with `policy_catalog` calls. The existing `handlePolicyCreate/List/Delete` functions become thin adapters.
- `src/execution/admin_ddl.zig` — Map the new AST variants to the auth_dispatch handlers (if the existing pattern uses an intermediate mapping layer).
- `src/security/gps.zig` — Add policy-catalog evaluation step in `decide()` after builtin roles, before fallthrough.
- `src/server/main.zig` — Remove `resolveRoleFromGraph` (now in role_resolver.zig); call the new module.
- `docs/security/gps-fail-open-sites.md` — Mark sites #2 and #3 as CLOSED with the closing commit SHAs.

**Out of scope (Phase 5+):**
- `ALTER POLICY` — defer (add/remove pattern is sufficient for Phase 4).
- `SHOW GRANTS FOR <user>` — defer.
- `EXPLAIN POLICY` — defer.
- ABAC attribute predicates (`principal.attributes.X`) — defer; expressions are limited to existing `current_user()`, `current_tenant()`, resource fields.
- `WITH CHECK` / `MASK` / classification obligations — defer.
- `ApiKey` / `ServiceAccount` / `KeyGrant` persistent objects — defer.

---

## Phase 4 Tasks

### Task 4-1: Extract `resolveRoleFromGraph` to dedicated module

**Files:** `src/security/role_resolver.zig` (new), `src/server/main.zig` (move out), `src/lib.zig` (re-export), `tests/test_gps_role_resolver.zig` (new), `build.zig` (new test step)

- [ ] **Step 1: Locate `resolveRoleFromGraph` in `src/server/main.zig`**

```bash
grep -n "fn resolveRoleFromGraph\|fn authRoleFromRecord" src/server/main.zig
```

Read the function and any helpers it calls (especially `authRoleFromRecord`).

- [ ] **Step 2: Move the function to `src/security/role_resolver.zig`**

Create the new file with the function body, the `authRoleFromRecord` helper, and any required imports. Make both functions `pub`. Update the original `src/server/main.zig` to import from the new module and delegate.

- [ ] **Step 3: Wire into `src/lib.zig`** — `pub const role_resolver = @import("security/role_resolver.zig");` inside the `security` struct.

- [ ] **Step 4: Write the isolated test in `tests/test_gps_role_resolver.zig`**

Construct a minimal in-memory graph with one User node and one Role node connected by HAS_ROLE. Call `role_resolver.resolveRoleFromGraph(user_node_id)` and assert the returned `Role` matches.

CANARY: `REQ=REQ-GPS-PDP-008; ASPECT=AuthRoleGraphLookupIsolated`.

- [ ] **Step 5: Add `test-gps-role-resolver` to build.zig**.

- [ ] **Step 6: Build, test, commit** — `refactor(gps): extract resolveRoleFromGraph to role_resolver.zig`.

---

### Task 4-2: Define the `Policy` type and in-memory catalog

**Files:** `src/security/policy_catalog.zig` (new), `tests/test_gps_policy_catalog.zig` (new), `src/lib.zig`, `build.zig`

- [ ] **Step 1: Write failing tests in `tests/test_gps_policy_catalog.zig`**

```zig
const std = @import("std");
const geode = @import("geode");
const cat = geode.security.policy_catalog;

// CANARY: REQ=REQ-GPS-CATALOG-001; FEATURE="GPS Policy Catalog"; ASPECT=AddListRemove; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "policy_catalog: add then list returns the policy" {
    var c = cat.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    try c.addPolicy(.{
        .name = "p1",
        .scope_graph = "*",
        .actions = &[_]cat.Action{ .read },
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    const list = c.listPolicies();
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("p1", list[0].name);
}

// CANARY: REQ=REQ-GPS-CATALOG-001; FEATURE="GPS Policy Catalog"; ASPECT=Remove; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "policy_catalog: remove deletes the named policy" {
    var c = cat.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    try c.addPolicy(.{ .name = "p2", .scope_graph = "*", .actions = &[_]cat.Action{ .read }, .effect = .allow, .expression_source = "true", .enabled = true });
    try c.removePolicy("p2");
    try std.testing.expectEqual(@as(usize, 0), c.listPolicies().len);
}
```

- [ ] **Step 2: Create `src/security/policy_catalog.zig`**

```zig
const std = @import("std");

pub const Action = enum {
    read, write, match_, create, update, delete, schema,
};

pub const Effect = enum { allow, deny };

pub const Policy = struct {
    name: []const u8,
    scope_graph: []const u8, // "*" for global, or graph name
    actions: []const Action,
    effect: Effect,
    expression_source: []const u8, // raw source; compiled lazily in Phase 4
    enabled: bool,
};

pub const PolicyCatalog = struct {
    allocator: std.mem.Allocator,
    policies: std.ArrayList(Policy),

    pub fn init(allocator: std.mem.Allocator) PolicyCatalog {
        return .{ .allocator = allocator, .policies = std.ArrayList(Policy).empty };
    }

    pub fn deinit(self: *PolicyCatalog) void {
        // Free owned name/scope/source/action strings if we duped them.
        for (self.policies.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.scope_graph);
            self.allocator.free(p.expression_source);
            self.allocator.free(p.actions);
        }
        self.policies.deinit(self.allocator);
    }

    pub fn addPolicy(self: *PolicyCatalog, args: PolicySpec) !void {
        // Dupe inputs so the catalog owns its strings
        const name_dupe = try self.allocator.dupe(u8, args.name);
        errdefer self.allocator.free(name_dupe);
        const scope_dupe = try self.allocator.dupe(u8, args.scope_graph);
        errdefer self.allocator.free(scope_dupe);
        const src_dupe = try self.allocator.dupe(u8, args.expression_source);
        errdefer self.allocator.free(src_dupe);
        const actions_dupe = try self.allocator.dupe(Action, args.actions);
        errdefer self.allocator.free(actions_dupe);

        try self.policies.append(self.allocator, .{
            .name = name_dupe,
            .scope_graph = scope_dupe,
            .actions = actions_dupe,
            .effect = args.effect,
            .expression_source = src_dupe,
            .enabled = args.enabled,
        });
    }

    pub fn removePolicy(self: *PolicyCatalog, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.policies.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.policies.items[i].name, name)) {
                const removed = self.policies.swapRemove(i);
                self.allocator.free(removed.name);
                self.allocator.free(removed.scope_graph);
                self.allocator.free(removed.expression_source);
                self.allocator.free(removed.actions);
                return;
            }
        }
        return error.PolicyNotFound;
    }

    pub fn listPolicies(self: *const PolicyCatalog) []const Policy {
        return self.policies.items;
    }
};

pub const PolicySpec = struct {
    name: []const u8,
    scope_graph: []const u8,
    actions: []const Action,
    effect: Effect,
    expression_source: []const u8,
    enabled: bool,
};

// Process-global catalog. Hydrated at server startup; consumed by gps.decide().
var g_catalog: ?*PolicyCatalog = null;

pub fn setGlobalCatalog(c: *PolicyCatalog) void {
    g_catalog = c;
}

pub fn getGlobalCatalog() ?*PolicyCatalog {
    return g_catalog;
}
```

- [ ] **Step 3: Wire into `src/lib.zig`** — `pub const policy_catalog = @import("security/policy_catalog.zig");` inside `security`.

- [ ] **Step 4: Add `test-gps-policy-catalog` step in build.zig**.

- [ ] **Step 5: Build, test, commit** — `feat(gps): in-memory policy catalog with add/list/remove`.

---

### Task 4-3: Parser support for CREATE POLICY / DROP POLICY / SHOW POLICIES

**Files:** `src/gql/ast.zig`, `src/gql/parser.zig`, `tests/test_gps_policy_ddl_parser.zig`, `build.zig`

- [ ] **Step 1: Locate the existing auth DDL parser code**

```bash
grep -n "CREATE USER\|fn parseCreateUser\|fn parseAuthDDL\|CreateUserStatement" src/gql/parser.zig src/gql/ast.zig | head -10
```

Read the structure of how `CREATE USER` is parsed. It's the template.

- [ ] **Step 2: Add AST variants in `src/gql/ast.zig`**

```zig
pub const CreatePolicyStatement = struct {
    name: []const u8,
    scope_graph: []const u8, // "*" for global
    actions: []const Action,
    effect: Effect, // allow or deny
    expression_source: []const u8,
};

pub const DropPolicyStatement = struct {
    name: []const u8,
    if_exists: bool,
};

pub const ShowPoliciesStatement = struct {};

pub const Action = enum { read, write, match_, create, update, delete, schema };
pub const Effect = enum { allow, deny };
```

Add the new variants to the existing `Statement` union (or wherever Statement variants live). Look at the existing `CreateUserStatement` placement.

- [ ] **Step 3: Add parser functions**

The grammar (slimmed from the design doc):

```
CreatePolicyStmt = "CREATE" "POLICY" Identifier "ON" "GRAPH" (Identifier | "*")
                   "FOR" ActionList
                   ("TO" RoleList)?    // ignored in Phase 4; defer
                   ("USING" Expression)?  // raw source; compiled later
                   ";"

DropPolicyStmt   = "DROP" "POLICY" ("IF" "EXISTS")? Identifier ";"
ShowPoliciesStmt = "SHOW" "POLICIES" ";"

ActionList = Action ("," Action)*
Action = "READ" | "WRITE" | "MATCH" | "CREATE" | "UPDATE" | "DELETE" | "SCHEMA"
Effect = (none, defaults to allow)   // Phase 4 deferred deny semantics
```

For Phase 4, all policies are `allow` by default — `deny` is Phase 5. The grammar may parse a `DENY` modifier but ignore it for now.

- [ ] **Step 4: Write parser tests in `tests/test_gps_policy_ddl_parser.zig`**

```zig
test "parser: CREATE POLICY parses minimal form" {
    const sql = "CREATE POLICY p1 ON GRAPH * FOR READ;";
    const ast = try parse(allocator, sql);
    defer ast.deinit();
    try std.testing.expectEqualStrings("p1", ast.create_policy.name);
    try std.testing.expectEqualStrings("*", ast.create_policy.scope_graph);
    try std.testing.expectEqual(@as(usize, 1), ast.create_policy.actions.len);
}

test "parser: DROP POLICY IF EXISTS parses" {
    const sql = "DROP POLICY IF EXISTS p1;";
    const ast = try parse(allocator, sql);
    defer ast.deinit();
    try std.testing.expect(ast.drop_policy.if_exists);
}

test "parser: SHOW POLICIES parses" {
    const sql = "SHOW POLICIES;";
    const ast = try parse(allocator, sql);
    defer ast.deinit();
}
```

Adapt `parse()` and result-access shape to the actual project test conventions.

- [ ] **Step 5: Build, test, commit** — `feat(gps): parser + AST for CREATE POLICY, DROP POLICY, SHOW POLICIES`.

---

### Task 4-4: Execute the DDL via auth_dispatch

**Files:** `src/execution/auth_dispatch.zig`, `src/execution/admin_ddl.zig` (if needed)

- [ ] **Step 1: Find the existing `handlePolicyCreate/Delete/List` placeholders**

```bash
grep -n "handlePolicyCreate\|g_policies\|handlePolicyList\|handlePolicyDelete" src/execution/auth_dispatch.zig | head -10
```

Read the placeholder implementations.

- [ ] **Step 2: Replace the in-memory `g_policies` map with `policy_catalog`**

The handlers should call `policy_catalog.getGlobalCatalog().?.addPolicy/.removePolicy/.listPolicies` instead of mutating a local StringHashMap.

- [ ] **Step 3: Wire the AST statements into the dispatch path**

Find where `CreateUserStatement` is dispatched (probably in `src/execution.zig` or `src/execution/admin_ddl.zig`) and add the same plumbing for the new policy statements.

- [ ] **Step 4: Add integration tests**

In `tests/test_gps_policy_catalog.zig` or a new `tests/test_gps_policy_ddl_integration.zig`, end-to-end test:
1. Run `CREATE POLICY p1 ON GRAPH * FOR READ;` through the executor.
2. Run `SHOW POLICIES;` and verify p1 is in the result.
3. Run `DROP POLICY p1;`.
4. Run `SHOW POLICIES;` and verify p1 is gone.

- [ ] **Step 5: Build, test, commit** — `feat(gps): wire CREATE/DROP/SHOW POLICY through auth_dispatch`.

---

### Task 4-5: Persistent storage of policies in `__geode_security`

**Files:** `src/security/policy_persistence.zig` (new), `src/security/auth_graph_manager.zig` (extend if needed), tests

- [ ] **Step 1: Inspect the existing auth_graph_manager persistence pattern**

```bash
grep -n "pub fn persist\|pub fn hydrate\|writerCreateUser\|writerCreateRole" src/security/auth_graph_manager.zig | head -10
```

The existing code persists `User`, `Role`, and `GraphGrant` objects with HMAC sealing. Follow the same pattern for `Policy`.

- [ ] **Step 2: Implement persistPolicy / removePolicy / hydratePolicies**

`persistPolicy(name, scope, actions, effect, expr_source, enabled)` writes a `(:Policy)` node in the `__geode_security` graph with the HMAC chain. `removePolicy(name)` deletes the node and re-seals. `hydratePolicies(allocator)` reads all `(:Policy)` nodes at startup and adds them to the in-memory catalog.

- [ ] **Step 3: Round-trip test in `tests/test_gps_policy_persistence.zig`**

1. Create a tmp data dir.
2. Persist a policy.
3. Restart the catalog (deinit + re-init).
4. Hydrate.
5. Assert the policy is present.

- [ ] **Step 4: Wire hydration at server startup**

In `src/server/main.zig`, near where `wireAuthDDLCallbacks` is called, also call `policy_persistence.hydrateCatalog`.

- [ ] **Step 5: Build, test, commit** — `feat(gps): persist policies in __geode_security with HMAC chain`.

---

### Task 4-6: Policy evaluation in `decide()`

**Files:** `src/security/gps.zig`, `tests/test_gps_policy_evaluation.zig`

- [ ] **Step 1: Add policy evaluation step in `decide()`**

After builtin-role evaluation produces a deny (or before it — order TBD per evaluation-order discussion):

```zig
    if (policy_catalog.getGlobalCatalog()) |catalog| {
        for (catalog.listPolicies()) |policy| {
            if (!policy.enabled) continue;
            if (!policyMatchesResource(policy, req.resource)) continue;
            if (!policyMatchesAction(policy, req.action)) continue;
            // For Phase 4, expression_source = "true" means unconditional allow.
            // Real expression compilation is Phase 5.
            if (std.mem.eql(u8, policy.expression_source, "true") and policy.effect == .allow) {
                return PolicyDecision{ .kind = .allow, .reason_code = "policy_match" };
            }
        }
    }
```

For Phase 4, we only support expression `true` (unconditional). Phase 5 will compile the expression source through `rls_core`.

- [ ] **Step 2: Add unit tests in `tests/test_gps_policy_evaluation.zig`**

- A principal with no builtin permissions but a matching `expression_source = "true"` policy gets `.allow` via `policy_match`.
- A non-matching policy is ignored.
- A disabled policy is ignored.

- [ ] **Step 3: Build, test, commit** — `feat(gps): decide() consults policy catalog for explicit allow`.

---

### Task 4-7: Close fail-open sites #2 and #3

**Files:** `docs/security/gps-fail-open-sites.md`, `src/execution.zig` (graph-grant comment update), `src/security/rls_core.zig` (no-policy comment update)

- [ ] **Step 1: Update the catalog**

Mark Site #2 (graph-grant additive widening) as **CLOSED** with this phase's closing commit SHA. Note that graph grants now exist as `(:Policy)` rows (when persisted as such — for Phase 4 the legacy `graph_grant_check_fn` continues to provide widening for back-compat, but the catalog is the new authoritative source). Effectively this is PARTIAL until Phase 5 migrates existing graph grants.

If "CLOSED" is too strong, mark **MIGRATING** or keep PARTIAL until Phase 5.

Mark Site #3 (RLS no-policy default-allow) similarly. Phase 4 introduces the catalog so "no policy = no allow" is explicit; the RLS row-level engine still returns rows when no policies match — but the policy *layer* is fail-closed.

- [ ] **Step 2: Update source CANARYs**

Find the two `REQ-GPS-INVARIANT-001 ASPECT=FailOpenInterim` markers on graph-grant widening and RLS no-policy. Update to `STATUS=COMPLETE` (if site is closed) or update the comment body to reflect Phase 4's progress.

- [ ] **Step 3: Commit** — `docs(gps): close/migrate fail-open sites #2 and #3 via policy catalog`.

---

### Task 4-8: Phase 4 outcome doc

**Files:** `docs/security/gps-policy-ddl.md` (new)

- [ ] Write a comprehensive Phase 4 outcome doc:

```markdown
# GPS Phase 4 — Policy DDL + Persistent Catalog

## What landed
- New `src/security/policy_catalog.zig`: in-memory `Policy` catalog with add/list/remove.
- New `src/security/policy_persistence.zig`: persists Policy nodes in `__geode_security`.
- Parser support: `CREATE POLICY name ON GRAPH * FOR READ;`, `DROP POLICY [IF EXISTS] name;`, `SHOW POLICIES;`.
- Catalog hydration at server startup; hot-add via DDL through `auth_dispatch`.
- `decide()` consults the catalog after builtin-role evaluation; `expression_source = "true"` is the only supported predicate for Phase 4.
- `role_resolver` extracted from main.zig (carry-forward from Phase 3).

## What did NOT change
- Real expression compilation. Phase 4 supports `"true"` only; Phase 5 wires the RLS VM compiler.
- ALTER POLICY, SHOW GRANTS, EXPLAIN POLICY — all Phase 5+.
- ABAC attribute predicates — Phase 5+.
- WITH CHECK / MASK / classification obligations — Phase 5+.

## Fail-open site status
- Site #2 (graph grant widening): PARTIAL — catalog is the authoritative model going forward; legacy widening still active for back-compat until Phase 5 migrates existing grants.
- Site #3 (RLS no-policy): PARTIAL — policy layer is fail-closed; row-level engine still returns rows by default.

## Phase 5 handoff
- Real expression compilation (compile `expression_source` → RLS bytecode at policy-add time).
- ABAC predicates and attribute map plumbing.
- Procedure registry mandatory `EXECUTE_PROCEDURE` decision (closes site #5).
- MCP per-caller principal threading (closes site #8).
- FLE explicit `DECRYPT_FIELD` / `UNWRAP_KEY` actions (closes site #9).
```

Commit — `docs(gps): Phase 4 outcome doc — policy DDL + persistent catalog`.

---

## Final Verification

- [ ] `make build && zig build test`. GPS test steps all pass.
- [ ] `grep -rn "REQ-GPS" src/ tests/ docs/ | wc -l` ≥ 230.
- [ ] Manual smoke: `CREATE POLICY p1 ON GRAPH * FOR READ;`, restart server, `SHOW POLICIES;` returns p1 (persistence works).
- [ ] Sites #2 and #3 marked PARTIAL or CLOSED in `gps-fail-open-sites.md`.
