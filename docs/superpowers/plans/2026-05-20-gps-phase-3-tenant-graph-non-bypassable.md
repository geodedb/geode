# GPS Phase 3 — Tenant + Graph Non-Bypassable Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tenant and graph isolation non-bypassable at every surface — metadata procedures, `SHOW` statements, and the graph-binding act itself. Closes fail-open sites #6 (`db.labels` etc. enumerate globally) and #7 (`SHOW GRAPHS` is global). Adds `BIND_GRAPH` and `SHOW_METADATA` as first-class GPS actions and routes every dispatch through `gps.decide()`.

**Architecture:** `decide()` gains evaluation paths for `Action.bind_graph` (consults the principal's `active_graph` and any graph grants for the target graph) and `Action.show_metadata` (always allowed at decision time; the metadata handlers themselves filter rows by tenant + accessible graphs). The metadata dispatch in `src/execution/meta_dispatch.zig` stops ignoring `ExecutionContext` (currently passes `_` for context) and threads `tenant_id` + `principal.active_graph` into `listNodeLabels`/`listEdgeTypes`/`listPropertiesForLabel`. The `USE GRAPH` site in `src/execution.zig:1732` adds a `gps.decide(.bind_graph)` call before switching graphs. `SHOW GRAPHS`, `SHOW INDEXES`, `SHOW CONSTRAINTS` filter results to only those the principal can `bind_graph`.

**Tech Stack:** Zig 0.16.0+, existing CANARY governance (`REQ=REQ-GPS-TENANT-*`, `REQ=REQ-GPS-METADATA-*`, `REQ=REQ-GPS-BIND-*`).

**Reference design:** `docs/geode-policy-plan.md` — Phase 3.

**Reference foundation:** `docs/security/gps-invariants.md`, `docs/security/gps-fail-open-sites.md` (sites #6, #7 — this plan closes them), `docs/security/gps-decide.md`.

---

## Carry-forward findings from Phase 2 folded into this plan

1. **Isolated unit test for `resolveRoleFromGraph()`** — Phase 2 final review noted that this auth fix is only covered by the parity test. Task 3-12 adds an isolated unit test.

---

## File Structure

**Create:**
- `tests/test_gps_metadata_filtering.zig` — Unit tests for tenant + graph filtering on `db.*` and `SHOW *` paths.
- `tests/test_gps_bind_graph.zig` — Tests for `USE GRAPH` going through `gps.decide(.bind_graph)`.
- `tests/test_gps_resolve_role_from_graph.zig` — The isolated test for the Phase 2 auth fix (carry-forward).
- `docs/security/gps-isolation.md` — Phase 3 outcome doc covering tenant/graph non-bypassable contract.
- Black-box spec at `../geode-test-harness/geodetestlab-cli/specs/gps_metadata_isolation_smoke.yml`.

**Modify:**
- `src/security/gps.zig` — Add `Action.bind_graph` and `Action.show_metadata` evaluation paths in `decide()`. `bind_graph` denies if the principal has no active_graph OR if a graph grant is required and absent. `show_metadata` is always `.allow` (filtering happens downstream).
- `src/execution/meta_dispatch.zig` — Each `handleDb*` function now passes `ExecutionContext` to `executeDb*`. Each `executeDb*` calls `gps.decide(.show_metadata, .metadata)` for audit, then filters store iteration by `ctx.tenant_id` + `ctx.principal.active_graph`.
- `src/execution/statement_handlers.zig` — `SHOW GRAPHS`/`SHOW INDEXES`/`SHOW CONSTRAINTS` filter results by tenant + graphs the principal can bind. The existing tenant filter on `SHOW TABLES` (line 152) is the template.
- `src/execution.zig` — The `UseGraph` case at line 1732 calls `gps.decide(.bind_graph, .{ .graph = name })` before applying the switch. Reject with `error.Unauthorized` if denied.
- `docs/security/gps-fail-open-sites.md` — Mark sites #6 and #7 as **CLOSED** with this phase's closing commit SHAs.

**Out of scope (Phase 4+):**
- Policy DDL (`CREATE POLICY`) — Phase 4.
- Persistent policy catalog — Phase 4.
- Mandatory `EXECUTE_PROCEDURE` decision — Phase 5.
- MCP per-caller principal — Phase 5.
- Distributed envelope policy-version propagation — Phase 6.

---

## Phase 3 Tasks

### Task 3-1: `Action.bind_graph` evaluation in `decide()`

**Files:** `src/security/gps.zig`, `tests/test_gps_bind_graph.zig`

- [ ] **Step 1: Write failing tests**

Create `tests/test_gps_bind_graph.zig`:

```zig
const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=AdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.bind_graph) allows Admin to bind any graph" {
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 1, .username = "admin", .session_id = null,
        .tenant_id = null, .active_graph = null,
        .roles = &role_names, .custom_roles = &.{},
        .auth_method = .password, .auth_version = 1,
        .mfa_state = .none, .elevation_until = null,
        .api_key_id = null, .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=GrantWidening; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.bind_graph) honors graph_grant_check_fn for non-admin users" {
    const execution = geode.execution;
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "bob") and std.mem.eql(u8, graph_name, "hr") and action == 0;
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 2, .username = "bob", .session_id = null,
        .tenant_id = null, .active_graph = "hr",
        .roles = &role_names, .custom_roles = &.{},
        .auth_method = .password, .auth_version = 1,
        .mfa_state = .none, .elevation_until = null,
        .api_key_id = null, .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };

    const req_hr = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d_hr = try gps.decide(std.testing.allocator, &req_hr);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_hr.kind);

    const req_sales = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "sales" },
    };
    const d_sales = try gps.decide(std.testing.allocator, &req_sales);
    try std.testing.expect(d_sales.kind != .allow);
}
```

- [ ] **Step 2: Run — fails** (existing decide() returns `.unauthorized` for `.bind_graph` because the action has no permission analogue).

- [ ] **Step 3: Add evaluation for `.bind_graph` in `decide()`**

In `src/security/gps.zig`, after the existing role-permission evaluation, add:

```zig
    // bind_graph: Admin always allowed; others require a Read grant on the target graph.
    if (req.action == .bind_graph) {
        for (req.principal.roles) |role_name| {
            if (std.mem.eql(u8, role_name, "Admin")) {
                return PolicyDecision{ .kind = .allow, .reason_code = "bind_graph_admin" };
            }
        }
        if (req.resource == .graph) {
            const target_graph = req.resource.graph;
            const execution = @import("../execution.zig");
            if (execution.graph_grant_check_fn) |grant_fn| {
                if (req.principal.username) |uname| {
                    if (grant_fn(uname, target_graph, 0)) {
                        return PolicyDecision{ .kind = .allow, .reason_code = "bind_graph_grant" };
                    }
                }
            }
        }
        return PolicyDecision{ .kind = .unauthorized, .reason_code = "bind_graph_no_evidence" };
    }
```

Add this BEFORE the existing builtin-role-evaluation block so `bind_graph` short-circuits the generic action mapping.

- [ ] **Step 4: Add test build step** — add `test-gps-bind-graph` to `build.zig` following the established pattern.

- [ ] **Step 5: Run and commit**

```bash
zig build test-gps-bind-graph
git add src/security/gps.zig tests/test_gps_bind_graph.zig build.zig
git commit -m "feat(gps): bind_graph action evaluated by decide()"
```

---

### Task 3-2: `USE GRAPH` calls `decide(.bind_graph)`

**Files:** `src/execution.zig` (around line 1732 — the `.UseGraph` case)

- [ ] **Step 1: Read the current USE GRAPH handler**

```bash
sed -n '1725,1800p' src/execution.zig
```

- [ ] **Step 2: Add an integration test in `tests/test_gps_bind_graph.zig`**

```zig
// CANARY: REQ=REQ-GPS-BIND-002; FEATURE="GPS BindGraph Action"; ASPECT=UseGraphAuthorization; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "USE GRAPH denied when decide(.bind_graph) returns unauthorized" {
    // Setup: install a stub grant fn that denies everything
    const execution = geode.execution;
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool { return false; }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    // (Set up a session with a non-admin Principal and exercise USE GRAPH.
    // The exact mechanics depend on how the executor is invoked in tests;
    // model after tests/test_gap0509_tenant_isolation.zig for a working
    // session-with-principal harness.)
    //
    // Assert that USE GRAPH on an unauthorized graph returns error.Unauthorized.
}
```

Adapt the test setup to match how existing geode integration tests construct a runnable executor with a non-admin Principal. Look at `tests/test_gap0509_tenant_isolation.zig` for the pattern.

- [ ] **Step 3: Insert the decide() call in the UseGraph branch**

Edit `src/execution.zig` around line 1752 (the existing `// USE GRAPH implementation - switch active graph context` block). Before the switch is applied, add:

```zig
            // CANARY: REQ=REQ-GPS-BIND-002; FEATURE="GPS BindGraph Action"; ASPECT=UseGraphAuthorization; STATUS=TESTED; TEST=tests/test_gps_bind_graph.zig; OWNER=security; UPDATED=2026-05-20
            // Phase 3: gate USE GRAPH on gps.decide(.bind_graph). Admin always
            // allowed; other users require a Read grant on the target graph.
            const gps = @import("security/gps.zig");
            if (context.principal) |p| {
                const req = gps.DecisionRequest{
                    .principal = p,
                    .action = .bind_graph,
                    .resource = .{ .graph = ug.name },
                };
                const decision = try gps.decide(std.heap.smp_allocator, &req);
                if (decision.kind != .allow) {
                    return error.Unauthorized;
                }
            }
```

When `context.principal` is null (legacy/test paths), the bind is allowed silently — Phase 1 behavior. Phase 3 does not retroactively gate paths that haven't been Principal-wired.

- [ ] **Step 4: Build, test, commit**

```bash
make build
zig build test-gps-bind-graph
git add src/execution.zig tests/test_gps_bind_graph.zig
git commit -m "feat(gps): USE GRAPH gated by decide(.bind_graph)"
```

---

### Task 3-3: `Action.show_metadata` evaluation + threading context into `db.*`

**Files:** `src/security/gps.zig`, `src/execution/meta_dispatch.zig`

- [ ] **Step 1: Add a `.show_metadata` allow-always branch in `decide()`**

In `src/security/gps.zig`, before the unauthenticated check (because metadata access is decided independently of standard role evaluation):

```zig
    if (req.action == .show_metadata) {
        // SHOW_METADATA is always allowed at the decision layer; the
        // metadata handlers themselves filter rows by tenant + graphs
        // accessible to the principal. Audit at this layer captures
        // who attempted what — denial is row-level downstream.
        return PolicyDecision{ .kind = .allow, .reason_code = "show_metadata_audit_only" };
    }
```

Place it before the bind_graph branch from Task 3-1 (or after — both fine, but document the order).

- [ ] **Step 2: Read `src/execution/meta_dispatch.zig` lines 53-95**

Inspect the existing `handleDbLabels` / `handleDbRelationshipTypes` / `handleDbPropertyKeys` handlers. They currently discard the ExecutionContext (`_: ExecutionContext`).

- [ ] **Step 3: Stop discarding the context**

Change each `handleDb*` signature so the context is actually used:

```zig
fn handleDbLabels(allocator: std.mem.Allocator, store: *graph_store.GraphStore, ctx: ExecutionContext) anyerror!ExecutionResult {
    return executeDbLabels(allocator, store, ctx);
}
```

Similarly for `handleDbRelationshipTypes` and `handleDbPropertyKeys`. The downstream `executeDb*` functions need updating to accept the new parameter.

- [ ] **Step 4: Commit**

```bash
git add src/security/gps.zig src/execution/meta_dispatch.zig
git commit -m "feat(gps): show_metadata action + thread ExecutionContext into db.* handlers"
```

Build and tests at this point: existing tests must still pass (tenant filtering is added in Tasks 3-4..3-6 next).

---

### Task 3-4: `db.labels()` filters by tenant + active graph

**Files:** `src/execution/meta_dispatch.zig`, `tests/test_gps_metadata_filtering.zig`

- [ ] **Step 1: Read `executeDbLabels` around line 98**

```bash
sed -n '95,140p' src/execution/meta_dispatch.zig
```

It currently calls something like `store.listAllLabels()` or iterates the store directly. The signature already accepts `*graph_store.GraphStore`. We need to additionally pass the tenant filter and active graph from `ctx`.

- [ ] **Step 2: Write failing test**

Create `tests/test_gps_metadata_filtering.zig` (or extend `tests/test_gap0509_tenant_isolation.zig` if that's the right place):

```zig
const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabels; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "db.labels() filters by tenant_id" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    // (Setup: create two tenants, each with distinct labels.
    // Run db.labels() in tenant A's context; assert only A's labels are returned.)
    // Pattern: model after tests/test_gap0509_tenant_isolation.zig
}
```

Fill in the setup using `tests/test_gap0509_tenant_isolation.zig` as the template.

- [ ] **Step 3: Implement tenant + graph filter in `executeDbLabels`**

Replace the existing all-labels iteration with `store.listNodeLabels(allocator, ctx.tenant_id)` if that helper exists (it should — Phase 0 invariants doc cites it). If only a global listing exists, add a guarded loop that skips nodes whose `tenant_id` doesn't match. Also filter by `ctx.principal.active_graph` if set.

Add the CANARY:
```zig
// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=DbLabelsFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
```

- [ ] **Step 4: Run, commit**

```bash
zig build test-gps-metadata-filtering
git add src/execution/meta_dispatch.zig tests/test_gps_metadata_filtering.zig build.zig
git commit -m "feat(gps): db.labels() filters by tenant and active graph"
```

---

### Task 3-5: `db.relationshipTypes()` filters

**Files:** `src/execution/meta_dispatch.zig`, `tests/test_gps_metadata_filtering.zig`

- [ ] Repeat the Task 3-4 pattern for `executeDbRelationshipTypes`. The store accessor is likely `listEdgeTypes(allocator, tenant)`.
- [ ] Test, build, commit `feat(gps): db.relationshipTypes() filters by tenant and active graph`.

---

### Task 3-6: `db.propertyKeys()` filters

**Files:** `src/execution/meta_dispatch.zig`, `tests/test_gps_metadata_filtering.zig`

- [ ] Repeat for `executeDbPropertyKeys`. Store accessor: `listPropertiesForLabel(allocator, label, tenant)` per CLAUDE.md mutex tier 1.
- [ ] Test, build, commit `feat(gps): db.propertyKeys() filters by tenant`.

---

### Task 3-7: `SHOW GRAPHS` filters by accessible graphs

**Files:** `src/execution/statement_handlers.zig`

- [ ] **Step 1: Find the SHOW GRAPHS handler**

```bash
grep -n "ShowGraphs\|SHOW GRAPHS\|fn handleShowGraphs\|show_graphs" src/execution/statement_handlers.zig src/execution.zig | head -10
```

- [ ] **Step 2: Write failing test**

A non-admin user with a grant on graph `hr` only should see `hr` in SHOW GRAPHS output but not `sales`.

- [ ] **Step 3: Implement filter** — for each graph in the enumeration, call `gps.decide(.bind_graph, .{ .graph = name })` and include only the ones that return `.allow`. Admin sees everything via the admin short-circuit from Task 3-1.

Add CANARY:
```zig
// CANARY: REQ=REQ-GPS-METADATA-002; FEATURE="GPS Metadata Isolation"; ASPECT=ShowGraphsFilter; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
```

- [ ] **Step 4: Test, build, commit** — `feat(gps): SHOW GRAPHS filters by principal's accessible graphs`

---

### Task 3-8: `SHOW INDEXES` and `SHOW CONSTRAINTS` filter by tenant + active graph

**Files:** `src/execution/statement_handlers.zig`

- [ ] Apply the same pattern as Task 3-7 for `SHOW INDEXES` and `SHOW CONSTRAINTS`. Filter by `ctx.tenant_id` + `ctx.principal.active_graph`. The legacy implementation enumerates globally — replace each loop's accept condition with a tenant+graph check.
- [ ] Test, build, commit `feat(gps): SHOW INDEXES/CONSTRAINTS filter by tenant and active graph`

---

### Task 3-9: Close fail-open sites #6 and #7 in the catalog

**Files:** `docs/security/gps-fail-open-sites.md`

- [ ] **Step 1:** Read `docs/security/gps-fail-open-sites.md` to confirm the current Status column for sites #6 and #7.

- [ ] **Step 2:** Update both rows to **CLOSED** with the closing commit SHAs. Sites #6 (metadata) closes when Tasks 3-4..3-6 land; site #7 (SHOW GRAPHS) closes when Task 3-7 lands. Use the actual commit hashes from this branch.

- [ ] **Step 3:** Commit — `docs(gps): close fail-open sites #6 and #7 in catalog`

---

### Task 3-10: E2E test — cross-tenant metadata isolation

**Files:** `tests/test_gps_metadata_filtering.zig` (extend)

- [ ] Add a comprehensive scenario test: create tenant A with labels [Employee, Department], tenant B with labels [Customer, Order]. Run `db.labels()` as user in tenant A — must return only Employee, Department. Run as Admin in tenant A — same result (admin still respects active tenant binding). Run as Admin in NO tenant — returns all.

This proves the closure of site #6 in a realistic scenario.

- [ ] Build, test, commit `test(gps): cross-tenant metadata isolation E2E`

---

### Task 3-11: Carry-forward — isolated unit test for `resolveRoleFromGraph()`

**Files:** `tests/test_gps_resolve_role_from_graph.zig`

- [ ] **Step 1: Locate `resolveRoleFromGraph`** — `grep -n "resolveRoleFromGraph" src/server/main.zig`. It was added in Phase 2 commit `6a307cf0`.

- [ ] **Step 2: Write a focused unit test** that:
  1. Creates a minimal in-memory graph with a User node and a Role node (e.g., "ReadOnly").
  2. Connects them with a HAS_ROLE edge.
  3. Calls `resolveRoleFromGraph(user_node_id)` and asserts the returned role is `.ReadOnly`.
  4. Also asserts the fallback (no edge → calls `authRoleFromRecord` → defaults based on `is_superuser`).

If `resolveRoleFromGraph` is private to `src/server/main.zig`, expose just enough surface to test it (a small wrapper in the same file). Mark with CANARY `REQ=REQ-GPS-PDP-008; ASPECT=AuthRoleGraphLookupIsolated`.

- [ ] **Step 3: Add `test-gps-resolve-role-from-graph` to build.zig**

- [ ] **Step 4: Build, test, commit** — `test(gps): isolated unit test for resolveRoleFromGraph HAS_ROLE traversal`

---

### Task 3-12: Black-box metadata isolation smoke spec

**Files:** `../geode-test-harness/geodetestlab-cli/specs/gps_metadata_isolation_smoke.yml`

- [ ] **Step 1:** Read an existing tenant-aware spec (e.g., `enterprise_test.gql` or `multi_graph.yml`) for the actual DSL.

- [ ] **Step 2:** Write a spec that:
  1. Creates two tenants (or graphs — whichever the harness supports today).
  2. Creates data with distinct labels in each.
  3. As a user bound to tenant A, runs `CALL db.labels()` and asserts the returned label set is exactly tenant A's.
  4. Cleanup.

- [ ] **Step 3:** Run via `make test-spec`. Pass.

- [ ] **Step 4:** Commit in the harness repo.

---

### Task 3-13: Phase 3 outcome doc

**Files:** `docs/security/gps-isolation.md`

- [ ] **Step 1:** Write `docs/security/gps-isolation.md` covering:
  - The non-bypassable tenant + graph contract Phase 3 establishes.
  - The two new GPS actions (`bind_graph`, `show_metadata`).
  - Which metadata handlers now thread context (every `db.*`, every `SHOW *`).
  - Compatibility note: paths without a non-null `ExecutionContext.principal` continue to work because `USE GRAPH` short-circuits the new check when `principal == null` — preserving legacy/test behavior.
  - Pointers to the closed sites in `gps-fail-open-sites.md`.
  - Phase 4 handoff: real policy DDL + persistent catalog.

- [ ] **Step 2:** Commit — `docs(gps): Phase 3 outcome doc — tenant + graph non-bypassable`

---

## Final Verification

- [ ] `make build && zig build test`. All GPS test steps pass.
- [ ] `grep -rn "REQ-GPS" src/ tests/ docs/ | wc -l` ≥ 180.
- [ ] Sites #6 and #7 marked CLOSED in `gps-fail-open-sites.md`.
- [ ] Manual smoke: start server, create tenant A & B with distinct labels, query `db.labels()` as tenant-A user — only tenant-A labels.
