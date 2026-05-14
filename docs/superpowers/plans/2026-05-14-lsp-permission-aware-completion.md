# Permission-Aware LSP Schema Completion + Monaco UI Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Geode LSP server schema-aware and permission-filtered so that the Monaco editor inside `../geode-ui` shows the *user's accessible* node labels, edge types, and properties as completion suggestions, plus hover schema info and richer diagnostics — usable end-to-end through a browser.

**Architecture:**
1. The Zig LSP (`src/cli/lsp/`) keeps its stdio transport for terminal editors and gets a parallel TCP transport.
2. `geode serve` co-hosts the LSP TCP listener (loopback by default) so LSP sessions share the same in-process `GraphStore`, `Catalog`, and auth/RLS modules — no QUIC hop.
3. The LSP gets an authenticated per-session `ExecutionContext`, a TTL-cached `SchemaProvider`, and a `CompletionContext` analyzer that inspects the cursor position to decide whether to suggest labels, edge types, properties, variables, or keywords.
4. `geode-ui`'s Go backend exposes `/ws/lsp` as a WebSocket-to-TCP bridge (auth via existing JWT, mirrors `ws_query.go`).
5. The React app wires Monaco to a `monaco-languageclient` over that WebSocket.

**Tech Stack:**
- Zig 0.16 (LSP core, schema introspection, TCP transport, auth, hover, diagnostics)
- Go 1.22 (geode-ui backend WS↔TCP proxy via `gorilla/websocket`)
- TypeScript 5.8 + React 18 + `@monaco-editor/react@4.7.0` + `monaco-languageclient` + `vscode-ws-jsonrpc`
- Tests: Zig embedded `test` blocks + `geodetestlab` YAML specs + Go `_test.go` + Jest

**Out of scope (follow-on plans):**
- `textDocument/codeAction` quick-fixes
- `workspace/executeCommand` (EXPLAIN/runQuery as virtual docs)
- `workspace/symbol`, `textDocument/rename`
- Persistent property catalog (incremental, on writes)
- Schema-aware autocomplete inside string literals or comments

---

## File Structure

**New files (Zig):**
- `src/cli/lsp/schema_provider.zig` — TTL-cached, permission-filtered schema lookup service
- `src/cli/lsp/auth.zig` — JWT validation + per-session `AuthState` + `ExecutionContext` binding
- `src/cli/lsp/completion_context.zig` — cursor-position token analyzer
- `src/cli/lsp/tcp_transport.zig` — TCP variant of `Transport` (delivered inside `transport.zig` as `TcpTransport`)
- `src/execution/schema_introspection.zig` — `listLabelsForUser`, `listEdgeTypesForUser`, `listPropertiesForLabelForUser`, `canUserAccessGraph`
- `src/execution/schema_change_notifier.zig` — process-wide invalidation registry
- Test files: `schema_provider_test.zig`, `auth_test.zig`, `completion_context_test.zig`, `tcp_transport_test.zig`, `tests/test_schema_introspection.zig`

**Modified files (Zig):**
- `src/cli/lsp/transport.zig` — refactor `Transport` into a tagged union of `stdio` + `tcp`
- `src/cli/lsp/features.zig` — `provideCompletion` and `provideHover` take `*SchemaProvider`, use `CompletionContext`
- `src/cli/lsp/server.zig` — `Session` fields hold `AuthState` + `SchemaProvider`; new `initialize` auth path; gate non-init requests
- `src/cli/main.zig` — wire `geode lsp --listen tcp://...` flag and `--no-auth`
- `src/server/main.zig` — spawn LSP TCP listener thread when `serve` starts
- `src/graph_store.zig` — new `listEdgeTypes(allocator, tenant)` and `listPropertiesForLabel(allocator, tenant, label)`; lift `listNodeLabels` to a public method
- `src/execution/statement_handlers.zig` — delete the file-private `listNodeLabels` and call the new public method on `GraphStore`
- `src/security/auth_graph_manager.zig` — expose `canUserAccessGraph(user, graph) bool`

**New files (Go, `../geode-ui/`):**
- `internal/server/ws_lsp.go` — WebSocket handler that proxies to upstream geode LSP TCP
- `internal/server/ws_lsp_test.go`

**Modified files (Go, `../geode-ui/`):**
- `internal/server/server.go` — register `/ws/lsp` route under existing auth middleware; add `UpstreamLspAddr` config

**New files (TypeScript, `../geode-ui/`):**
- `src/lib/lsp/client.ts` — monaco-languageclient bootstrap
- `src/lib/lsp/websocketTransport.ts` — WebSocket → vscode-ws-jsonrpc transport adapter
- `src/lib/lsp/__tests__/client.test.ts`
- `src/lib/lsp/__tests__/websocketTransport.test.ts`

**Modified files (TypeScript, `../geode-ui/`):**
- `src/components/editor/GqlEditor.tsx` — wire LSP client on mount, dispose on unmount; reconnect on token refresh
- `package.json` — add `monaco-languageclient`, `vscode-ws-jsonrpc`, `vscode-languageserver-protocol`, `vscode-languageclient`

---

## Phase 1 — Schema Introspection APIs in Zig (foundation)

### Task 1: Add `listEdgeTypes` to `graph_store.zig`

**Files:**
- Modify: `src/graph_store.zig` — add after `pub fn listGraphNames` (around line 963)
- Test: `src/graph_store.zig` (embedded `test "..."` block at the bottom)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/graph_store.zig`:

```zig
test "listEdgeTypes returns unique edge types filtered by tenant" {
    const testing = std.testing;
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    const n1 = try store.createNode(&.{"A"}, .{}, "tenant-a");
    const n2 = try store.createNode(&.{"A"}, .{}, "tenant-a");
    const n3 = try store.createNode(&.{"A"}, .{}, "tenant-b");
    _ = try store.createEdge(n1, n2, "KNOWS", .{}, "tenant-a");
    _ = try store.createEdge(n1, n2, "LIKES", .{}, "tenant-a");
    _ = try store.createEdge(n3, n3, "FOLLOWS", .{}, "tenant-b");

    const types_a = try store.listEdgeTypes(testing.allocator, "tenant-a");
    defer {
        for (types_a) |t| testing.allocator.free(t);
        testing.allocator.free(types_a);
    }
    try testing.expectEqual(@as(usize, 2), types_a.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="listEdgeTypes"`
Expected: FAIL with `no field or member function named 'listEdgeTypes'`.

- [ ] **Step 3: Implement `listEdgeTypes`**

Add to `src/graph_store.zig` next to `listGraphNames`:

```zig
/// Returns a de-duplicated, allocator-owned slice of edge type names.
/// `filter_tenant == null` returns all edge types (admin path). Caller must
/// free each slice and the outer slice.
pub fn listEdgeTypes(
    self: *GraphStore,
    allocator: std.mem.Allocator,
    filter_tenant: ?[]const u8,
) ![][]const u8 {
    var type_set = std.StringHashMap(void).init(allocator);
    defer type_set.deinit();

    var edge_it = self.edges.iterator();
    while (edge_it.next()) |entry| {
        const edge = entry.value_ptr.*;
        if (filter_tenant) |tid| {
            if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
        }
        const copy = try allocator.dupe(u8, edge.edge_type);
        errdefer allocator.free(copy);
        const r = try type_set.getOrPut(copy);
        if (r.found_existing) allocator.free(copy);
    }

    var out = try std.ArrayList([]const u8).initCapacity(allocator, type_set.count());
    errdefer out.deinit(allocator);
    var k_it = type_set.keyIterator();
    while (k_it.next()) |k| try out.append(allocator, k.*);
    return out.toOwnedSlice(allocator);
}
```

If `edge.edge_type` is not the actual field name (check the `Edge` struct around `src/graph_store.zig` for the real label field — likely `edge_type` or `label`), substitute the actual field name and update the test to match.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -Dtest-filter="listEdgeTypes"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): add listEdgeTypes for schema introspection"
```

---

### Task 2: Add `listPropertiesForLabel` to `graph_store.zig`

**Files:**
- Modify: `src/graph_store.zig` — same region as Task 1
- Test: `src/graph_store.zig` (embedded)

- [ ] **Step 1: Write the failing test**

```zig
test "listPropertiesForLabel returns dedup properties for nodes with label in tenant" {
    const testing = std.testing;
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    _ = try store.createNode(&.{"Person"}, .{ .name = "Alice", .age = 30 }, "tenant-a");
    _ = try store.createNode(&.{"Person"}, .{ .name = "Bob", .email = "b@x.io" }, "tenant-a");
    _ = try store.createNode(&.{"Product"}, .{ .sku = "X" }, "tenant-a");
    _ = try store.createNode(&.{"Person"}, .{ .secret = 1 }, "tenant-b");

    const props = try store.listPropertiesForLabel(testing.allocator, "tenant-a", "Person");
    defer {
        for (props) |p| testing.allocator.free(p);
        testing.allocator.free(props);
    }
    try testing.expectEqual(@as(usize, 3), props.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="listPropertiesForLabel"`
Expected: FAIL.

- [ ] **Step 3: Implement `listPropertiesForLabel`**

```zig
/// Returns the set of property keys observed on nodes that carry `label`
/// in `filter_tenant`. Caller owns each slice and the outer slice.
pub fn listPropertiesForLabel(
    self: *GraphStore,
    allocator: std.mem.Allocator,
    filter_tenant: ?[]const u8,
    label: []const u8,
) ![][]const u8 {
    var prop_set = std.StringHashMap(void).init(allocator);
    defer prop_set.deinit();

    var node_it = self.nodes.iterator();
    while (node_it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (filter_tenant) |tid| {
            if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
        }
        var has_label = false;
        for (node.labels) |l| {
            if (std.mem.eql(u8, l, label)) {
                has_label = true;
                break;
            }
        }
        if (!has_label) continue;

        var p_it = node.properties.iterator();
        while (p_it.next()) |p| {
            const copy = try allocator.dupe(u8, p.key_ptr.*);
            errdefer allocator.free(copy);
            const r = try prop_set.getOrPut(copy);
            if (r.found_existing) allocator.free(copy);
        }
    }

    var out = try std.ArrayList([]const u8).initCapacity(allocator, prop_set.count());
    errdefer out.deinit(allocator);
    var k_it = prop_set.keyIterator();
    while (k_it.next()) |k| try out.append(allocator, k.*);
    return out.toOwnedSlice(allocator);
}
```

If `node.properties` is not a `StringHashMap` (verify against the actual `Node` definition near the top of `graph_store.zig`), adapt the iteration. The de-dup approach is unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -Dtest-filter="listPropertiesForLabel"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): add listPropertiesForLabel for schema introspection"
```

---

### Task 3: Promote `listNodeLabels` to a public method on `GraphStore`

**Files:**
- Modify: `src/graph_store.zig` — add `pub fn listNodeLabels`
- Modify: `src/execution/statement_handlers.zig` — delete file-private function and call the method

- [ ] **Step 1: Test**

```zig
test "GraphStore.listNodeLabels is callable and filters by tenant" {
    const testing = std.testing;
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Visible"}, .{}, "tenant-a");
    _ = try store.createNode(&.{"Hidden"}, .{}, "tenant-b");

    const labels = try store.listNodeLabels(testing.allocator, "tenant-a");
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Visible", labels[0]);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Move the body**

Copy `fn listNodeLabels` (the file-private one at `src/execution/statement_handlers.zig:44-82`) into `src/graph_store.zig` as `pub fn listNodeLabels(self: *GraphStore, allocator, filter_tenant)`. Use `self.nodes` instead of the parameter.

Update `src/execution/statement_handlers.zig:203` to call `read_store.listNodeLabels(allocator, session_tenant)` and delete the file-private function (and its keep-alive imports if any).

- [ ] **Step 4: Run all tests**

Run: `zig build test 2>&1 | tail -20`
Expected: previous SHOW TABLES tests still pass; new test passes.

- [ ] **Step 5: Commit**

```bash
git add src/graph_store.zig src/execution/statement_handlers.zig
git commit -m "refactor(storage): promote listNodeLabels to a public method"
```

---

### Task 4: Expose `canUserAccessGraph` in `auth_graph_manager.zig`

**Files:**
- Modify: `src/security/auth_graph_manager.zig`

- [ ] **Step 1: Confirm the lookup table exists**

Run: `grep -n "user_graph_grants\|grantUserGraphPermission\|fn .*UserGraphPermission" src/security/auth_graph_manager.zig`
Expected: identifies the grant map field and the existing `grantUserGraphPermission` function (file:line ~964).

- [ ] **Step 2: Write the failing test**

Append:

```zig
test "canUserAccessGraph returns true after grant and false after revoke" {
    const testing = std.testing;
    var mgr = try AuthGraphManager.initForTesting(testing.allocator);
    defer mgr.deinit();

    try testing.expect(!mgr.canUserAccessGraph("alice", "trade"));
    _ = try mgr.grantUserGraphPermission("alice", "trade", .READ);
    try testing.expect(mgr.canUserAccessGraph("alice", "trade"));
    _ = try mgr.revokeUserGraphPermission("alice", "trade");
    try testing.expect(!mgr.canUserAccessGraph("alice", "trade"));
}
```

If `initForTesting` is not a real helper, look for the existing test constructor and substitute its name (search `test ".*AuthGraphManager"` for the pattern).

- [ ] **Step 3: Implement `canUserAccessGraph`**

```zig
/// Returns true if `user` is admin or has at least one grant on `graph_name`.
/// The caller may apply role checks for stricter semantics; the LSP uses this
/// as a coarse "is graph visible" filter for completion suggestions.
pub fn canUserAccessGraph(self: *AuthGraphManager, user: []const u8, graph_name: []const u8) bool {
    self.grants_mutex.lock();
    defer self.grants_mutex.unlock();

    if (self.userIsAdmin(user)) return true;

    var it = self.user_graph_grants.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*; // expected layout: "<user>::<graph>"
        const sep = std.mem.indexOf(u8, key, "::") orelse continue;
        if (!std.mem.eql(u8, key[0..sep], user)) continue;
        if (!std.mem.eql(u8, key[sep + 2 ..], graph_name)) continue;
        return true;
    }
    return false;
}
```

If the key encoding is different (check `grantUserGraphPermission` for the actual `try std.fmt.allocPrint(...)` format), adjust the parse. The signature stays the same.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="canUserAccessGraph"
git add src/security/auth_graph_manager.zig
git commit -m "feat(security): expose canUserAccessGraph as a coarse visibility gate"
```

---

### Task 5: Create `src/execution/schema_introspection.zig`

**Files:**
- Create: `src/execution/schema_introspection.zig`
- Create: `tests/test_schema_introspection.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_schema_introspection.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const intro = @import("../src/execution/schema_introspection.zig");
const graph_store = @import("../src/graph_store.zig");

test "listLabelsForUser filters by tenant" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{}, "tenant-a");
    _ = try store.createNode(&.{"Secret"}, .{}, "tenant-b");

    const ctx = intro.IntrospectionContext{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = .ReadOnly,
        .graph_name = "default",
    };
    const labels = try intro.listLabelsForUser(alloc, &store, ctx);
    defer intro.freeStringList(alloc, labels);
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Person", labels[0]);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test -Dtest-filter="listLabelsForUser"`
Expected: FAIL (module does not exist).

- [ ] **Step 3: Implement the module**

Create `src/execution/schema_introspection.zig`:

```zig
const std = @import("std");
const graph_store = @import("../graph_store.zig");
const auth_graph = @import("../security/auth_graph_manager.zig");

pub const IntrospectionContext = struct {
    user: []const u8,
    tenant_id: ?[]const u8,
    role: @import("../security/user_management.zig").Role,
    graph_name: []const u8,
    /// Optional injection point for the auth manager; null skips per-graph
    /// gating (permissive default for tests; the LSP wires in the global).
    auth_mgr: ?*auth_graph.AuthGraphManager = null,
};

pub fn freeStringList(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

fn graphVisible(ctx: IntrospectionContext) bool {
    if (ctx.role == .Admin) return true;
    const mgr = ctx.auth_mgr orelse return true;
    return mgr.canUserAccessGraph(ctx.user, ctx.graph_name);
}

pub fn listLabelsForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listNodeLabels(allocator, ctx.tenant_id);
}

pub fn listEdgeTypesForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listEdgeTypes(allocator, ctx.tenant_id);
}

pub fn listPropertiesForLabelForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
    label: []const u8,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listPropertiesForLabel(allocator, ctx.tenant_id, label);
}

pub fn listGraphsForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    const all = try store.listGraphNames(allocator);
    if (ctx.role == .Admin or ctx.auth_mgr == null) return all;

    var keep = try std.ArrayList([]const u8).initCapacity(allocator, all.len);
    errdefer keep.deinit(allocator);
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        if (ctx.auth_mgr.?.canUserAccessGraph(ctx.user, all[i])) {
            try keep.append(allocator, all[i]);
        } else {
            allocator.free(all[i]);
        }
    }
    allocator.free(all);
    return keep.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Register the test file in `build.zig`**

Open `build.zig`, find where existing `tests/test_*.zig` files are added (search `tests/test_gap0509_tenant_isolation`), and add `tests/test_schema_introspection.zig` next to that block using the same pattern.

- [ ] **Step 5: Run + commit**

```bash
zig build test -Dtest-filter="listLabelsForUser"
git add src/execution/schema_introspection.zig tests/test_schema_introspection.zig build.zig
git commit -m "feat(execution): permission-filtered schema_introspection module"
```

---

## Phase 2 — LSP SchemaProvider with TTL Cache

### Task 6: Create `src/cli/lsp/schema_provider.zig` skeleton

**Files:**
- Create: `src/cli/lsp/schema_provider.zig`
- Create: `src/cli/lsp/schema_provider_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const testing = std.testing;
const SchemaProvider = @import("schema_provider.zig").SchemaProvider;
const intro = @import("../../execution/schema_introspection.zig");
const graph_store = @import("../../graph_store.zig");

test "SchemaProvider returns labels accessible to the user" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{}, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = .ReadOnly,
        .graph_name = "default",
    });
    defer sp.deinit();

    const labels = try sp.getLabels();
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Person", labels[0]);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement `SchemaProvider` (no cache yet)**

```zig
const std = @import("std");
const intro = @import("../../execution/schema_introspection.zig");
const graph_store = @import("../../graph_store.zig");

pub const SchemaProvider = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: intro.IntrospectionContext,

    labels: ?[][]const u8 = null,
    edge_types: ?[][]const u8 = null,
    properties: std.StringHashMap([][]const u8) = undefined,
    properties_initialized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *graph_store.GraphStore,
        ctx: intro.IntrospectionContext,
    ) SchemaProvider {
        return .{
            .allocator = allocator,
            .store = store,
            .ctx = ctx,
            .properties = std.StringHashMap([][]const u8).init(allocator),
            .properties_initialized = true,
        };
    }

    pub fn deinit(self: *SchemaProvider) void {
        if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
        if (self.edge_types) |es| intro.freeStringList(self.allocator, es);
        if (self.properties_initialized) {
            var it = self.properties.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                intro.freeStringList(self.allocator, e.value_ptr.*);
            }
            self.properties.deinit();
        }
    }

    pub fn getLabels(self: *SchemaProvider) ![]const []const u8 {
        if (self.labels == null) {
            self.labels = try intro.listLabelsForUser(self.allocator, self.store, self.ctx);
        }
        return self.labels.?;
    }

    pub fn getEdgeTypes(self: *SchemaProvider) ![]const []const u8 {
        if (self.edge_types == null) {
            self.edge_types = try intro.listEdgeTypesForUser(self.allocator, self.store, self.ctx);
        }
        return self.edge_types.?;
    }

    pub fn getPropertiesFor(self: *SchemaProvider, label: []const u8) ![]const []const u8 {
        if (self.properties.get(label)) |existing| return existing;
        const key = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(key);
        const props = try intro.listPropertiesForLabelForUser(self.allocator, self.store, self.ctx, label);
        try self.properties.put(key, props);
        return props;
    }
};
```

- [ ] **Step 4: Register test file in `build.zig`** (same pattern as Task 5)

- [ ] **Step 5: Run + commit**

```bash
zig build test -Dtest-filter="SchemaProvider returns labels"
git add src/cli/lsp/schema_provider.zig src/cli/lsp/schema_provider_test.zig build.zig
git commit -m "feat(lsp): add SchemaProvider with lazy fetch"
```

---

### Task 7: Add TTL expiry + `invalidate()` to SchemaProvider

**Files:**
- Modify: `src/cli/lsp/schema_provider.zig`
- Modify: `src/cli/lsp/schema_provider_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "SchemaProvider re-fetches labels after TTL expiry" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{}, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "alice", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();
    sp.ttl_ns = 1;

    _ = try sp.getLabels();
    _ = try store.createNode(&.{"Product"}, .{}, "tenant-a");
    std.Thread.sleep(2);
    const labels = try sp.getLabels();
    try testing.expectEqual(@as(usize, 2), labels.len);
}

test "SchemaProvider.invalidate() drops cached data" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"X"}, .{}, "tenant-a");

    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();
    _ = try sp.getLabels();
    sp.invalidate();
    try testing.expect(sp.labels == null);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Add TTL fields + `invalidate` + rewrite `getLabels`**

Add to the `SchemaProvider` struct:

```zig
pub const DEFAULT_TTL_NS: i128 = 5 * std.time.ns_per_s;

ttl_ns: i128 = DEFAULT_TTL_NS,
labels_fetched_at_ns: i128 = 0,
edge_types_fetched_at_ns: i128 = 0,
properties_fetched_at_ns: std.StringHashMap(i128) = undefined,
```

Initialize `properties_fetched_at_ns` in `init`, free in `deinit`.

```zig
fn nowNs() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    std.posix.clock_gettime(.MONOTONIC, &ts) catch return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub fn invalidate(self: *SchemaProvider) void {
    if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
    self.labels = null;
    if (self.edge_types) |es| intro.freeStringList(self.allocator, es);
    self.edge_types = null;
    var it = self.properties.iterator();
    while (it.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        intro.freeStringList(self.allocator, e.value_ptr.*);
    }
    self.properties.clearRetainingCapacity();
    self.properties_fetched_at_ns.clearRetainingCapacity();
}

pub fn getLabels(self: *SchemaProvider) ![]const []const u8 {
    const now = nowNs();
    if (self.labels == null or (now - self.labels_fetched_at_ns) >= self.ttl_ns) {
        if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
        self.labels = try intro.listLabelsForUser(self.allocator, self.store, self.ctx);
        self.labels_fetched_at_ns = now;
    }
    return self.labels.?;
}
```

Apply the same TTL pattern to `getEdgeTypes` and `getPropertiesFor`.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="SchemaProvider"
git add src/cli/lsp/schema_provider.zig src/cli/lsp/schema_provider_test.zig
git commit -m "feat(lsp): TTL expiry and invalidate() in SchemaProvider"
```

---

### Task 8: Thread-safety for SchemaProvider

**Files:**
- Modify: `src/cli/lsp/schema_provider.zig`
- Modify: `src/cli/lsp/schema_provider_test.zig`

- [ ] **Step 1: Test**

```zig
test "SchemaProvider is safe under concurrent access" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"P"}, .{}, "tenant-a");
    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();

    const Run = struct {
        fn go(p: *SchemaProvider) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) _ = p.getLabels() catch {};
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Run.go, .{&sp});
    for (threads) |t| t.join();
}
```

- [ ] **Step 2: Run — flaky pass without mutex**

- [ ] **Step 3: Add mutex**

```zig
mu: std.Thread.Mutex = .{},
```

Wrap `getLabels`, `getEdgeTypes`, `getPropertiesFor`, and `invalidate` bodies with `self.mu.lock(); defer self.mu.unlock();`.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="SchemaProvider"
git add src/cli/lsp/schema_provider.zig src/cli/lsp/schema_provider_test.zig
git commit -m "feat(lsp): thread-safe SchemaProvider with mutex"
```

---

### Task 9: SchemaProvider invalidation hook for DDL writes

**Files:**
- Create: `src/execution/schema_change_notifier.zig`
- Modify: `src/cli/lsp/schema_provider.zig`
- Modify: `src/execution/statement_handlers.zig` (CREATE/DROP completion points)

- [ ] **Step 1: Create the registry**

```zig
const std = @import("std");

pub const Callback = struct {
    ctx: *anyopaque,
    invoke: *const fn (*anyopaque) void,
};

var g_mu: std.Thread.Mutex = .{};
var g_callbacks: std.ArrayList(Callback) = .empty;

pub fn register(cb: Callback) !void {
    g_mu.lock();
    defer g_mu.unlock();
    try g_callbacks.append(std.heap.page_allocator, cb);
}

pub fn unregister(ctx: *anyopaque) void {
    g_mu.lock();
    defer g_mu.unlock();
    var i: usize = 0;
    while (i < g_callbacks.items.len) {
        if (g_callbacks.items[i].ctx == ctx) {
            _ = g_callbacks.swapRemove(i);
        } else i += 1;
    }
}

pub fn notify() void {
    g_mu.lock();
    const snapshot = g_callbacks.items;
    g_mu.unlock();
    for (snapshot) |cb| cb.invoke(cb.ctx);
}
```

- [ ] **Step 2: Fire `notify()` at DDL completion**

In `src/execution/statement_handlers.zig` after successful `CREATE NODE` (when a new label is introduced), `DROP GRAPH`, and the CREATE/DROP edge handlers, add:

```zig
@import("schema_change_notifier.zig").notify();
```

Also fire from any spot in `src/execution/admin_ddl.zig` that mutates `__geode_security`-visible state (CREATE USER, GRANT, REVOKE) so the LSP can re-pull `canUserAccessGraph` results.

- [ ] **Step 3: Wire SchemaProvider register/unregister**

In `src/cli/lsp/schema_provider.zig`:

```zig
const notifier = @import("../../execution/schema_change_notifier.zig");

fn onSchemaChange(ctx: *anyopaque) void {
    const self: *SchemaProvider = @ptrCast(@alignCast(ctx));
    self.invalidate();
}

pub fn registerInvalidation(self: *SchemaProvider) !void {
    try notifier.register(.{ .ctx = self, .invoke = onSchemaChange });
}

pub fn unregisterInvalidation(self: *SchemaProvider) void {
    notifier.unregister(self);
}
```

- [ ] **Step 4: Test**

```zig
test "SchemaProvider invalidates on DDL notification" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"A"}, .{}, "tenant-a");
    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();
    try sp.registerInvalidation();
    defer sp.unregisterInvalidation();

    _ = try sp.getLabels();
    @import("../../execution/schema_change_notifier.zig").notify();
    try testing.expect(sp.labels == null);
}
```

Run: `zig build test -Dtest-filter="invalidates on DDL"` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/execution/schema_change_notifier.zig src/execution/statement_handlers.zig src/cli/lsp/schema_provider.zig src/cli/lsp/schema_provider_test.zig
git commit -m "feat(lsp): wire SchemaProvider invalidation to DDL events"
```

---

## Phase 3 — LSP Auth + Per-Session Context

### Task 10: Create `src/cli/lsp/auth.zig`

**Files:**
- Create: `src/cli/lsp/auth.zig`
- Create: `src/cli/lsp/auth_test.zig`

- [ ] **Step 1: Failing test**

```zig
const std = @import("std");
const testing = std.testing;
const auth = @import("auth.zig");

test "AuthState.fromInitializeOptions parses geode.authToken" {
    const alloc = testing.allocator;
    const init_opts =
        \\{"geode":{"authToken":"eyJhbGciOi.test.signature","graph":"trade","tenant":"tA"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, init_opts, .{});
    defer parsed.deinit();
    var state = try auth.AuthState.fromInitializeOptions(alloc, parsed.value);
    defer state.deinit(alloc);
    try testing.expectEqualStrings("eyJhbGciOi.test.signature", state.token);
    try testing.expectEqualStrings("trade", state.graph orelse "");
    try testing.expectEqualStrings("tA", state.tenant_id orelse "");
}

test "AuthState.fromInitializeOptions errors on missing token" {
    const alloc = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    try testing.expectError(
        auth.AuthError.MissingToken,
        auth.AuthState.fromInitializeOptions(alloc, parsed.value),
    );
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```zig
const std = @import("std");

pub const AuthError = error{
    MissingToken,
    InvalidToken,
    ExpiredToken,
    BadFormat,
    OutOfMemory,
};

pub const AuthState = struct {
    token: []const u8,
    user: []const u8 = "",
    role: @import("../../security/user_management.zig").Role = .ReadOnly,
    graph: ?[]const u8 = null,
    tenant_id: ?[]const u8 = null,
    verified: bool = false,

    pub fn fromInitializeOptions(
        allocator: std.mem.Allocator,
        params: std.json.Value,
    ) AuthError!AuthState {
        if (params != .object) return AuthError.BadFormat;
        const geode_obj = params.object.get("geode") orelse return AuthError.MissingToken;
        if (geode_obj != .object) return AuthError.BadFormat;
        const tok = geode_obj.object.get("authToken") orelse return AuthError.MissingToken;
        if (tok != .string) return AuthError.BadFormat;
        var s = AuthState{ .token = try allocator.dupe(u8, tok.string) };
        if (geode_obj.object.get("graph")) |g| {
            if (g == .string) s.graph = try allocator.dupe(u8, g.string);
        }
        if (geode_obj.object.get("tenant")) |t| {
            if (t == .string) s.tenant_id = try allocator.dupe(u8, t.string);
        }
        return s;
    }

    pub fn deinit(self: AuthState, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.graph) |g| allocator.free(g);
        if (self.tenant_id) |t| allocator.free(t);
        if (self.user.len > 0) allocator.free(self.user);
    }
};
```

- [ ] **Step 4: Register test file in `build.zig`; run + commit**

```bash
zig build test -Dtest-filter="AuthState"
git add src/cli/lsp/auth.zig src/cli/lsp/auth_test.zig build.zig
git commit -m "feat(lsp): AuthState parses initializeOptions.geode.*"
```

---

### Task 11: Validate JWT inside `AuthState.verify`

**Files:**
- Modify: `src/cli/lsp/auth.zig`
- Modify: `src/cli/lsp/auth_test.zig`

- [ ] **Step 1: Locate the existing JWT verifier**

Run: `grep -rn "fn verifyToken\|fn parseJWT\|fn validateJWT" src/server src/security 2>/dev/null | head`. Use whichever function the QUIC server already calls when validating bearer tokens (likely `src/server/jwt.zig` with `verifyToken(allocator, raw) -> Claims`). The exact import path is what to use below.

- [ ] **Step 2: Failing test**

```zig
test "AuthState.verify rejects empty token" {
    const alloc = testing.allocator;
    var s = auth.AuthState{ .token = try alloc.dupe(u8, "") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.MissingToken, s.verify(alloc));
}
```

- [ ] **Step 3: Run — fail**

- [ ] **Step 4: Implement `verify`**

Add to `auth.zig`:

```zig
const jwt_mod = @import("../../server/jwt.zig"); // adjust path per Step 1 finding
const user_mgmt = @import("../../security/user_management.zig");

pub fn verify(self: *AuthState, allocator: std.mem.Allocator) AuthError!void {
    if (self.token.len == 0) return AuthError.MissingToken;
    var claims = jwt_mod.verifyToken(allocator, self.token) catch |e| switch (e) {
        error.Expired => return AuthError.ExpiredToken,
        else => return AuthError.InvalidToken,
    };
    defer claims.deinit(allocator);
    self.user = try allocator.dupe(u8, claims.subject);
    if (user_mgmt.lookupRole(self.user)) |r| self.role = r;
    self.verified = true;
}
```

Add a second test using a real signed token from the existing test helpers (search `mintTestToken\|signForTest` in `src/server/`):

```zig
test "AuthState.verify accepts a freshly minted token" {
    const alloc = testing.allocator;
    const tok = try jwt_mod.signForTest(alloc, "alice");
    defer alloc.free(tok);
    var s = auth.AuthState{ .token = try alloc.dupe(u8, tok) };
    defer s.deinit(alloc);
    try s.verify(alloc);
    try testing.expect(s.verified);
    try testing.expectEqualStrings("alice", s.user);
}
```

- [ ] **Step 5: Run + commit**

```bash
zig build test -Dtest-filter="AuthState"
git add src/cli/lsp/auth.zig src/cli/lsp/auth_test.zig
git commit -m "feat(lsp): verify JWT in AuthState.verify"
```

---

### Task 12: Add `Session` to `Server` holding `AuthState` + `SchemaProvider`

**Files:**
- Modify: `src/cli/lsp/server.zig`
- Create: `src/cli/lsp/server_auth_test.zig`

- [ ] **Step 1: Extend `Server` struct fields**

In `pub const Server = struct` (around `src/cli/lsp/server.zig:55`):

```zig
auth: ?@import("auth.zig").AuthState = null,
schema: ?*@import("schema_provider.zig").SchemaProvider = null,
exec_context: ?@import("../../execution.zig").ExecutionContext = null,
allow_unauth: bool = false,
```

In `deinit`:

```zig
if (self.auth) |*a| a.deinit(self.allocator);
if (self.schema) |sp| {
    sp.unregisterInvalidation();
    sp.deinit();
    self.allocator.destroy(sp);
}
```

- [ ] **Step 2: Bind during `handleInitialize`**

In `fn handleInitialize` (around line 276), after parsing `params`:

```zig
const init_opts: ?std.json.Value = if (params) |p|
    if (p == .object) p.object.get("initializationOptions") else null
else null;

if (init_opts) |opts| {
    var st = @import("auth.zig").AuthState.fromInitializeOptions(self.allocator, opts) catch |e| {
        return self.respondInitializeError(id, e);
    };
    st.verify(self.allocator) catch |e| {
        st.deinit(self.allocator);
        return self.respondInitializeError(id, e);
    };
    try self.bindSession(st);
} else if (self.allow_unauth) {
    try self.bindUnauthSession();
} else {
    return self.respondInitializeError(id, error.MissingToken);
}
```

Add:

```zig
fn bindSession(self: *Server, st: @import("auth.zig").AuthState) !void {
    const writable_store = @import("../../graph_store.zig").getWritableGlobalStore(self.allocator);
    const sp = try self.allocator.create(@import("schema_provider.zig").SchemaProvider);
    sp.* = @import("schema_provider.zig").SchemaProvider.init(self.allocator, writable_store, .{
        .user = st.user,
        .tenant_id = st.tenant_id,
        .role = st.role,
        .graph_name = st.graph orelse "default",
    });
    try sp.registerInvalidation();

    self.auth = st;
    self.schema = sp;
    self.exec_context = .{
        .catalog = @import("../../execution.zig").getGlobalCatalog(self.allocator),
        .user = st.user,
        .role = st.role,
        .tenant_id = st.tenant_id,
    };
}

fn respondInitializeError(self: *Server, id: std.json.Value, e: anyerror) !void {
    // Emit JSON-RPC error -32002 (ServerNotInitialized) with reason.
    const reason = switch (e) {
        error.MissingToken => "missing authentication token",
        error.InvalidToken => "invalid authentication token",
        error.ExpiredToken => "expired authentication token",
        error.BadFormat => "malformed initializationOptions",
        else => "authentication failed",
    };
    try self.writeErrorResponse(id, -32002, reason);
}
```

`writeErrorResponse` should already exist (search `respondError\|writeError\|sendError` in `server.zig`); otherwise add a thin helper that emits `{"jsonrpc":"2.0","id":<id>,"error":{"code":...,"message":...}}`.

- [ ] **Step 3: Reject non-init requests when not authenticated**

In `handleRequest` (around `src/cli/lsp/server.zig:235`), before dispatching anything except `initialize`/`shutdown`/`exit`:

```zig
if (!std.mem.eql(u8, method, "initialize") and
    !std.mem.eql(u8, method, "shutdown") and
    !std.mem.eql(u8, method, "exit"))
{
    const a = self.auth orelse return self.writeErrorResponse(id, -32002, "not authenticated");
    if (!a.verified) return self.writeErrorResponse(id, -32002, "not authenticated");
}
```

- [ ] **Step 4: Test**

Create `src/cli/lsp/server_auth_test.zig`. Use the in-memory loopback pattern from `e2e_test.zig` (read that file for the helper functions to drive `Server.run` with controlled stdin/stdout):

```zig
const std = @import("std");
const testing = std.testing;

test "Server rejects completion before initialize/auth" {
    // 1. Construct an in-memory Transport pair
    // 2. Spawn Server.run in a thread
    // 3. Write a textDocument/completion request without prior initialize
    // 4. Expect JSON-RPC error with code -32002
    // (Concrete pattern: copy the harness scaffolding from e2e_test.zig
    //  and call writeMessage with a completion request.)
}
```

Implement the body following the e2e harness.

- [ ] **Step 5: Register test file; run + commit**

```bash
zig build test -Dtest-filter="Server rejects completion"
git add src/cli/lsp/server.zig src/cli/lsp/server_auth_test.zig build.zig
git commit -m "feat(lsp): require authenticated initialize before any request"
```

---

### Task 13: `--no-auth` stdio mode for terminal editors

**Files:**
- Modify: `src/cli/main.zig` — `cmdLsp`
- Modify: `src/cli/lsp/server.zig`

- [ ] **Step 1: Parse flag in `cmdLsp`**

In `src/cli/main.zig` (find `fn cmdLsp`), add a flag loop:

```zig
var allow_unauth = false;
while (it.next()) |arg| {
    if (std.mem.eql(u8, arg, "--no-auth")) allow_unauth = true;
}
var srv = try Server.init(allocator, allow_unauth);
defer srv.deinit();
try srv.run();
```

- [ ] **Step 2: Update `Server.init` signature**

```zig
pub fn init(allocator: Allocator, allow_unauth: bool) !Server {
    var s: Server = .{
        .allocator = allocator,
        .transport = try Transport.initStdio(allocator),
        .documents = DocumentStore.init(allocator),
        .debounce_state = std.StringHashMap(DebounceState).init(allocator),
        .debounce_state_initialized = true,
        .allow_unauth = allow_unauth,
    };
    return s;
}
```

Also add `Server.initWithTransport(allocator, tx, allow_unauth)` for TCP callers (used by Phase 9).

- [ ] **Step 3: Implement `bindUnauthSession`**

```zig
fn bindUnauthSession(self: *Server) !void {
    const env_user = std.posix.getenv("USER") orelse "local";
    const st = @import("auth.zig").AuthState{
        .token = try self.allocator.dupe(u8, ""),
        .user = try self.allocator.dupe(u8, env_user),
        .role = .Admin,
        .verified = true,
        .graph = try self.allocator.dupe(u8, "default"),
        .tenant_id = null,
    };
    try self.bindSession(st);
}
```

- [ ] **Step 4: Test**

```zig
test "Server allows initialize without token when allow_unauth=true" {
    var srv = try Server.init(testing.allocator, true);
    defer srv.deinit();
    // Drive initialize with empty params via in-memory transport (same harness as Task 12).
    // Expect a result with capabilities — no error.
}
```

- [ ] **Step 5: Run + commit**

```bash
zig build test -Dtest-filter="allow_unauth"
git add src/cli/main.zig src/cli/lsp/server.zig src/cli/lsp/server_auth_test.zig
git commit -m "feat(lsp): --no-auth stdio mode for terminal editors"
```

---

## Phase 4 — Completion Context Analyzer

### Task 14: Create `completion_context.zig` with kind detection

**Files:**
- Create: `src/cli/lsp/completion_context.zig`
- Create: `src/cli/lsp/completion_context_test.zig`

- [ ] **Step 1: Failing test**

```zig
const std = @import("std");
const testing = std.testing;
const cc = @import("completion_context.zig");

test "detects label completion after (n:" {
    const ctx = cc.analyze("MATCH (n:", .{ .line = 0, .character = 9 });
    try testing.expectEqual(cc.Kind.label, ctx.kind);
    try testing.expectEqualStrings("", ctx.prefix);
}

test "detects label prefix" {
    const ctx = cc.analyze("MATCH (n:Per", .{ .line = 0, .character = 12 });
    try testing.expectEqual(cc.Kind.label, ctx.kind);
    try testing.expectEqualStrings("Per", ctx.prefix);
}

test "detects edge type after [r:" {
    const ctx = cc.analyze("MATCH (a)-[r:", .{ .line = 0, .character = 13 });
    try testing.expectEqual(cc.Kind.edge_type, ctx.kind);
}

test "detects property after n." {
    const ctx = cc.analyze("RETURN n.", .{ .line = 0, .character = 9 });
    try testing.expectEqual(cc.Kind.property, ctx.kind);
    try testing.expectEqualStrings("n", ctx.var_name orelse "");
}

test "falls back to keyword" {
    const ctx = cc.analyze("MAT", .{ .line = 0, .character = 3 });
    try testing.expectEqual(cc.Kind.keyword, ctx.kind);
    try testing.expectEqualStrings("MAT", ctx.prefix);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```zig
const std = @import("std");

pub const Kind = enum { keyword, label, edge_type, property, variable, parameter };

pub const Pos = struct { line: u32, character: u32 };

pub const Result = struct {
    kind: Kind,
    prefix: []const u8,
    var_name: ?[]const u8 = null,
};

pub fn analyze(text: []const u8, pos: Pos) Result {
    const offset = lineColToOffset(text, pos) orelse return .{ .kind = .keyword, .prefix = "" };
    const prefix_text = text[0..offset];

    var i: usize = prefix_text.len;
    while (i > 0 and (std.ascii.isAlphanumeric(prefix_text[i - 1]) or prefix_text[i - 1] == '_')) : (i -= 1) {}
    const prefix = prefix_text[i..];
    const head = prefix_text[0..i];

    var j: usize = head.len;
    while (j > 0 and std.ascii.isWhitespace(head[j - 1])) : (j -= 1) {}
    if (j == 0) return .{ .kind = .keyword, .prefix = prefix };

    const trig = head[j - 1];

    if (trig == ':') {
        var k: usize = j - 1;
        while (k > 0 and std.ascii.isWhitespace(head[k - 1])) : (k -= 1) {}
        while (k > 0 and (std.ascii.isAlphanumeric(head[k - 1]) or head[k - 1] == '_')) : (k -= 1) {}
        while (k > 0 and std.ascii.isWhitespace(head[k - 1])) : (k -= 1) {}
        if (k > 0) {
            const opener = head[k - 1];
            if (opener == '(') return .{ .kind = .label, .prefix = prefix };
            if (opener == '[') return .{ .kind = .edge_type, .prefix = prefix };
        }
        return .{ .kind = .label, .prefix = prefix };
    }

    if (trig == '.') {
        var k: usize = j - 1;
        while (k > 0 and (std.ascii.isAlphanumeric(head[k - 1]) or head[k - 1] == '_')) : (k -= 1) {}
        const var_name = head[k .. j - 1];
        return .{ .kind = .property, .prefix = prefix, .var_name = var_name };
    }

    if (trig == '$') return .{ .kind = .parameter, .prefix = prefix };

    return .{ .kind = .keyword, .prefix = prefix };
}

fn lineColToOffset(text: []const u8, pos: Pos) ?usize {
    var line: u32 = 0;
    var col: u32 = 0;
    for (text, 0..) |c, i| {
        if (line == pos.line and col == pos.character) return i;
        if (c == '\n') { line += 1; col = 0; } else col += 1;
    }
    if (line == pos.line and col == pos.character) return text.len;
    return null;
}
```

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="completion_context"
git add src/cli/lsp/completion_context.zig src/cli/lsp/completion_context_test.zig build.zig
git commit -m "feat(lsp): completion_context cursor analyzer"
```

---

### Task 15: Resolve a variable's label from MATCH bindings

**Files:**
- Modify: `src/cli/lsp/completion_context.zig`
- Modify: `src/cli/lsp/completion_context_test.zig`

- [ ] **Step 1: Failing test**

```zig
test "resolveVarLabel finds label from MATCH binding" {
    const text = "MATCH (n:Person)-[r:KNOWS]->(m:Product) RETURN n.";
    try testing.expectEqualStrings("Person", cc.resolveVarLabel(text, "n") orelse "");
    try testing.expectEqualStrings("Product", cc.resolveVarLabel(text, "m") orelse "");
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```zig
pub fn resolveVarLabel(text: []const u8, var_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '(') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const var_start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        const found_var = text[var_start..j];
        if (!std.mem.eql(u8, found_var, var_name)) continue;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        if (j >= text.len or text[j] != ':') continue;
        j += 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const lbl_start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        return text[lbl_start..j];
    }
    return null;
}
```

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="resolveVarLabel"
git add src/cli/lsp/completion_context.zig src/cli/lsp/completion_context_test.zig
git commit -m "feat(lsp): resolveVarLabel for property completion"
```

---

### Task 16: Extract variables in scope

**Files:**
- Modify: `src/cli/lsp/completion_context.zig`
- Modify: `src/cli/lsp/completion_context_test.zig`

- [ ] **Step 1: Test**

```zig
test "scopedVariables returns all bound variables" {
    const text = "MATCH (a:A)-[r:R]->(b:B) RETURN ";
    const alloc = testing.allocator;
    const vars = try cc.scopedVariables(alloc, text);
    defer alloc.free(vars);
    var have_a = false; var have_r = false; var have_b = false;
    for (vars) |v| {
        if (std.mem.eql(u8, v, "a")) have_a = true;
        if (std.mem.eql(u8, v, "r")) have_r = true;
        if (std.mem.eql(u8, v, "b")) have_b = true;
    }
    try testing.expect(have_a and have_r and have_b);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```zig
pub fn scopedVariables(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var set = std.StringHashMap(void).init(allocator);
    defer set.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '(' and c != '[') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        if (j == start) continue;
        try set.put(text[start..j], {});
    }
    var out = try std.ArrayList([]const u8).initCapacity(allocator, set.count());
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(allocator, k.*);
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="scopedVariables"
git add src/cli/lsp/completion_context.zig src/cli/lsp/completion_context_test.zig
git commit -m "feat(lsp): scopedVariables extractor"
```

---

## Phase 5 — Schema-Aware Completion

### Task 17: Extend `provideCompletion` signature

**Files:**
- Modify: `src/cli/lsp/features.zig` (line 384)
- Modify: `src/cli/lsp/server.zig` (caller around line 490)
- Modify: `src/cli/lsp/features_test.zig` and any other existing callers

- [ ] **Step 1: Update signature**

In `features.zig:384`:

```zig
pub fn provideCompletion(
    allocator: Allocator,
    doc: *const Document,
    line: u32,
    character: u32,
    schema: ?*@import("schema_provider.zig").SchemaProvider,
) ![]protocol.CompletionItem {
    _ = schema; // wired in Task 18
    // existing body unchanged for now
}
```

- [ ] **Step 2: Update caller in `server.zig:handleCompletion`**

```zig
const items = try features.provideCompletion(self.allocator, doc, line, ch, self.schema);
```

- [ ] **Step 3: Patch all existing test call sites**

Run: `grep -rn "provideCompletion(" src/cli/lsp/ | grep -v features.zig:384`

For every match in `*_test.zig` add `null` as the new last argument.

- [ ] **Step 4: Run + commit**

```bash
zig build test
git add src/cli/lsp/features.zig src/cli/lsp/server.zig src/cli/lsp/features_test.zig
git commit -m "refactor(lsp): thread SchemaProvider into provideCompletion signature"
```

---

### Task 18: Inject schema-derived completion items based on context

**Files:**
- Modify: `src/cli/lsp/features.zig`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Failing test**

```zig
test "provideCompletion offers labels after (n:" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{}, "tenant-a");
    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();

    var doc = try Document.fromText(alloc, "test:///q.gql", "MATCH (n:");
    defer doc.deinit();
    const items = try features.provideCompletion(alloc, &doc, 0, 9, &sp);
    defer alloc.free(items);

    var found = false;
    for (items) |it| if (std.mem.eql(u8, it.label, "Person")) { found = true; break; };
    try testing.expect(found);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement branching**

Replace the body of `provideCompletion`:

```zig
const ctx = @import("completion_context.zig").analyze(doc.text, .{ .line = line, .character = character });

var items = std.ArrayList(protocol.CompletionItem).empty;
errdefer items.deinit(allocator);

if (schema) |sp| {
    switch (ctx.kind) {
        .label => {
            const labels = sp.getLabels() catch &[_][]const u8{};
            for (labels) |lbl| {
                if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, lbl, ctx.prefix)) continue;
                try items.append(allocator, .{
                    .label = lbl,
                    .kind = .Class,
                    .detail = "Node label",
                    .documentation = "",
                    .insertText = lbl,
                });
            }
            return items.toOwnedSlice(allocator);
        },
        .edge_type => {
            const types = sp.getEdgeTypes() catch &[_][]const u8{};
            for (types) |t| {
                if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, t, ctx.prefix)) continue;
                try items.append(allocator, .{
                    .label = t, .kind = .Reference,
                    .detail = "Edge type", .documentation = "",
                    .insertText = t,
                });
            }
            return items.toOwnedSlice(allocator);
        },
        .property => {
            const var_name = ctx.var_name orelse return items.toOwnedSlice(allocator);
            const label = @import("completion_context.zig").resolveVarLabel(doc.text, var_name) orelse return items.toOwnedSlice(allocator);
            const props = sp.getPropertiesFor(label) catch &[_][]const u8{};
            for (props) |p| {
                if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, p, ctx.prefix)) continue;
                try items.append(allocator, .{
                    .label = p, .kind = .Field,
                    .detail = try std.fmt.allocPrint(allocator, "Property of {s}", .{label}),
                    .documentation = "", .insertText = p,
                });
            }
            return items.toOwnedSlice(allocator);
        },
        .parameter, .variable, .keyword => {
            // fall through to static items
        },
    }
}

// Static items — restore the existing keyword/function/type/procedure loops,
// but each loop now honors ctx.prefix via startsWithCI (added in Task 19).
```

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="offers labels"
git add src/cli/lsp/features.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): schema-aware completion for labels, edge types, properties"
```

---

### Task 19: Prefix filtering for static completions

**Files:**
- Modify: `src/cli/lsp/features.zig`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Failing test**

```zig
test "provideCompletion filters static keywords by prefix" {
    const alloc = testing.allocator;
    var doc = try Document.fromText(alloc, "test:///q.gql", "MAT");
    defer doc.deinit();
    const items = try features.provideCompletion(alloc, &doc, 0, 3, null);
    defer alloc.free(items);
    for (items) |it| {
        try testing.expect(startsWithCI(it.label, "MAT"));
    }
    try testing.expect(items.len < 50);
}

fn startsWithCI(s: []const u8, p: []const u8) bool {
    if (s.len < p.len) return false;
    for (p, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Add helper + filter loops**

In `features.zig`:

```zig
fn startsWithCI(s: []const u8, p: []const u8) bool {
    if (s.len < p.len) return false;
    for (p, 0..) |c, i| if (std.ascii.toLower(s[i]) != std.ascii.toLower(c)) return false;
    return true;
}
```

Inside the keyword loop:

```zig
for (language_metadata.keywords) |kw| {
    if (ctx.prefix.len > 0 and !startsWithCI(kw.name, ctx.prefix)) continue;
    // existing append
}
```

Apply the same guard to function, type, and procedure loops.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="filters static keywords"
git add src/cli/lsp/features.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): prefix-filter static completion items"
```

---

### Task 20: Geodetestlab integration spec (skipped placeholder)

**Files:**
- Create: `../geode-test-harness/geodetestlab-cli/specs/lsp_schema_completion.yml`

- [ ] **Step 1: Write the spec marked skipped**

```yaml
name: lsp_schema_completion
description: LSP completion suggests user-visible node labels after (n:
skip: "pending Phase 9 (WS endpoint not yet wired)"
setup:
  - "CREATE GRAPH demo;"
  - "USE GRAPH demo;"
  - "CREATE (:Person {name: 'alice'})"
  - "CREATE (:Product {sku: 'X'})"
steps:
  - lsp:
      method: initialize
      params:
        capabilities: {}
        initializationOptions:
          geode:
            authToken: "${AUTH_TOKEN}"
            graph: "demo"
            tenant: "${TENANT}"
      expect:
        result.capabilities.completionProvider: not_null
  - lsp:
      method: textDocument/didOpen
      params:
        textDocument:
          uri: "file:///q.gql"
          languageId: "gql"
          version: 1
          text: "MATCH (n:"
  - lsp:
      method: textDocument/completion
      params:
        textDocument: {uri: "file:///q.gql"}
        position: {line: 0, character: 9}
      expect:
        result_contains_label: "Person"
        result_contains_label: "Product"
```

- [ ] **Step 2: Commit**

```bash
git -C ../geode-test-harness add geodetestlab-cli/specs/lsp_schema_completion.yml
git -C ../geode-test-harness commit -m "test(lsp): schema completion spec (skipped, enabled in Task 37)"
```

---

## Phase 6 — Schema-Aware Hover

### Task 21: Hover on a label shows property list

**Files:**
- Modify: `src/cli/lsp/features.zig` — `provideHover` (line 208)
- Modify: `src/cli/lsp/server.zig` — `handleHover`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Failing test**

```zig
test "hover on label shows property list" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{ .name = "a", .age = 30 }, "tenant-a");
    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();

    var doc = try Document.fromText(alloc, "test:///q.gql", "MATCH (n:Person)");
    defer doc.deinit();
    const hover = (try features.provideHover(alloc, &doc, 0, 11, &sp)) orelse return error.NoHover;
    defer alloc.free(hover.contents);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "name") != null);
    try testing.expect(std.mem.indexOf(u8, hover.contents, "age") != null);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Update signature + add label branch**

```zig
pub fn provideHover(
    allocator: Allocator,
    doc: *const Document,
    line: u32,
    character: u32,
    schema: ?*@import("schema_provider.zig").SchemaProvider,
) !?protocol.Hover {
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    if (schema) |sp| {
        const labels = sp.getLabels() catch &[_][]const u8{};
        for (labels) |lbl| {
            if (!std.mem.eql(u8, lbl, word)) continue;
            const props = sp.getPropertiesFor(lbl) catch &[_][]const u8{};
            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, "**Label `");
            try buf.appendSlice(allocator, lbl);
            try buf.appendSlice(allocator, "`** *(Node)*\n\nProperties:\n");
            for (props) |p| {
                try buf.appendSlice(allocator, "- `");
                try buf.appendSlice(allocator, p);
                try buf.appendSlice(allocator, "`\n");
            }
            return .{ .contents = try buf.toOwnedSlice(allocator), .range = null };
        }
    }

    // ... existing keyword/function/type fallback
}
```

Update `handleHover` in `server.zig` to pass `self.schema`. Patch any other call sites in tests.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="hover on label"
git add src/cli/lsp/features.zig src/cli/lsp/server.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): schema-aware hover for labels"
```

---

### Task 22: Hover on edge type and property

**Files:**
- Modify: `src/cli/lsp/features.zig`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Tests** (mirror Task 21 for edge types and properties)

```zig
test "hover on edge type shows kind line" {
    // setup with a KNOWS edge
    // assert hover contents contain "Edge type" and "KNOWS"
}
test "hover on property shows owning label" {
    // text: "MATCH (n:Person) RETURN n.age"
    // hover at the `age` token; assert contents contain "Person" and "age"
}
```

- [ ] **Step 2: Implement** — add two more branches in `provideHover`:

```zig
const types = sp.getEdgeTypes() catch &[_][]const u8{};
for (types) |t| if (std.mem.eql(u8, t, word)) {
    return .{
        .contents = try std.fmt.allocPrint(allocator, "**Edge type `{s}`**\n\nUse in: `()-[r:{s}]->()`", .{ t, t }),
        .range = null,
    };
};

// Property hover — only if the word's left neighbor is `.` and the var resolves.
const offset_minus = if (offset >= word.len + 1) offset - word.len - 1 else 0;
if (offset > word.len and doc.text[offset_minus] == '.') {
    const var_end = offset_minus;
    var k: usize = var_end;
    while (k > 0 and (std.ascii.isAlphanumeric(doc.text[k - 1]) or doc.text[k - 1] == '_')) : (k -= 1) {}
    const var_name = doc.text[k..var_end];
    if (@import("completion_context.zig").resolveVarLabel(doc.text, var_name)) |lbl| {
        return .{
            .contents = try std.fmt.allocPrint(allocator, "**Property `{s}.{s}`**\n\nOn label `{s}`", .{ var_name, word, lbl }),
            .range = null,
        };
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
zig build test -Dtest-filter="hover on edge\|hover on property"
git add src/cli/lsp/features.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): schema-aware hover for edge types and properties"
```

---

## Phase 7 — Schema-Aware Diagnostics (minimal)

### Task 23: Warn on unknown labels with closest-match hint

**Files:**
- Modify: `src/cli/lsp/features.zig` — `provideDiagnostics`
- Modify: `src/cli/lsp/server.zig` — caller in `flushPendingDiagnostics`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Failing test**

```zig
test "diagnostics flag unknown labels with hint" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"}, .{}, "tenant-a");
    var sp = SchemaProvider.init(alloc, &store, .{
        .user = "u", .tenant_id = "tenant-a", .role = .ReadOnly, .graph_name = "default",
    });
    defer sp.deinit();

    var doc = try Document.fromText(alloc, "test:///q.gql", "MATCH (n:Persn) RETURN n");
    defer doc.deinit();
    const diags = try features.provideDiagnostics(alloc, &doc, &sp);
    defer alloc.free(diags);
    try testing.expect(diags.len >= 1);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "Person") != null);
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement** — extend `provideDiagnostics` to accept `*SchemaProvider`, scan label references using a simple `(<var>:<Label>)` regex-by-hand, and emit a `Warning` diagnostic for unknown labels with a "Did you mean X?" suffix when edit distance ≤ 2.

Add helpers to `features.zig`:

```zig
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0..b.len + 1], curr[0..b.len + 1]);
    }
    return prev[b.len];
}

fn closestLabel(target: []const u8, labels: []const []const u8) ?[]const u8 {
    var best_dist: usize = std.math.maxInt(usize);
    var best: ?[]const u8 = null;
    for (labels) |l| {
        const d = levenshtein(target, l);
        if (d < best_dist) { best_dist = d; best = l; }
    }
    return if (best_dist <= 2) best else null;
}
```

Then in `provideDiagnostics(allocator, doc, schema)`:

```zig
if (schema) |sp| {
    const labels = sp.getLabels() catch &[_][]const u8{};
    var i: usize = 0;
    const text = doc.text;
    while (i < text.len) : (i += 1) {
        if (text[i] != '(') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        if (j >= text.len or text[j] != ':') continue;
        j += 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const lbl_start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        const lbl = text[lbl_start..j];
        if (lbl.len == 0) continue;

        var known = false;
        for (labels) |l| if (std.mem.eql(u8, l, lbl)) { known = true; break; };
        if (known) continue;

        const hint = closestLabel(lbl, labels);
        const msg = if (hint) |h|
            try std.fmt.allocPrint(allocator, "Unknown label `{s}`. Did you mean `{s}`?", .{ lbl, h })
        else
            try std.fmt.allocPrint(allocator, "Unknown label `{s}`.", .{lbl});

        const pos_start = offsetToLineCol(text, lbl_start);
        const pos_end = offsetToLineCol(text, j);
        try diags.append(allocator, .{
            .range = .{ .start = pos_start, .end = pos_end },
            .severity = .Warning,
            .source = "geode-lsp",
            .message = msg,
        });
    }
}
```

(`offsetToLineCol` may already exist in `features.zig` — search; if not, add a small inverse of `lineColToOffset`.)

Update `flushPendingDiagnostics` in `server.zig` to pass `self.schema`.

- [ ] **Step 4: Run + commit**

```bash
zig build test -Dtest-filter="diagnostics flag unknown labels"
git add src/cli/lsp/features.zig src/cli/lsp/server.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): warn on unknown labels with closest-match hint"
```

---

### Task 24: Same diagnostic for edge types

**Files:**
- Modify: `src/cli/lsp/features.zig`
- Modify: `src/cli/lsp/features_test.zig`

- [ ] **Step 1: Test** — mirror Task 23 with `MATCH (a)-[r:NOWS]-(b)` where `KNOWS` exists.

- [ ] **Step 2: Implement** — second pass in `provideDiagnostics` scanning for `]-[<var>:<Type>]` references; reuse `closestLabel`-style helper against `sp.getEdgeTypes()`.

- [ ] **Step 3: Run + commit**

```bash
zig build test -Dtest-filter="diagnostics flag unknown edge"
git add src/cli/lsp/features.zig src/cli/lsp/features_test.zig
git commit -m "feat(lsp): warn on unknown edge types with closest-match hint"
```

---

## Phase 8 — TCP Transport for LSP

### Task 25: Refactor `Transport` into a tagged union

**Files:**
- Modify: `src/cli/lsp/transport.zig`
- Modify: `src/cli/lsp/transport_test.zig` (existing)
- Modify: `src/cli/lsp/server.zig` — `init` and `deinit`
- Modify: `src/cli/main.zig` — `cmdLsp`

- [ ] **Step 1: Restructure**

Rename the existing `pub const Transport = struct { ... }` to `pub const StdioTransport = struct { ... }` (move `init` body, but keep field names). Then add:

```zig
pub const Transport = union(enum) {
    stdio: StdioTransport,
    tcp: TcpTransport, // declared in Task 26

    pub fn initStdio(allocator: Allocator) TransportError!Transport {
        return .{ .stdio = try StdioTransport.init(allocator) };
    }

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .stdio => |*s| if (@hasDecl(StdioTransport, "deinit")) s.deinit(),
            .tcp => |*t| t.deinit(),
        }
    }

    pub fn readMessage(self: *Transport) ![]const u8 {
        return switch (self.*) {
            .stdio => |*s| s.readMessage(),
            .tcp => |*t| t.readMessage(),
        };
    }

    pub fn writeMessage(self: *Transport, msg: []const u8) !void {
        return switch (self.*) {
            .stdio => |*s| s.writeMessage(msg),
            .tcp => |*t| t.writeMessage(msg),
        };
    }

    pub fn logMessage(self: *Transport, level: []const u8, msg: []const u8) void {
        switch (self.*) {
            .stdio => |*s| s.logMessage(level, msg),
            .tcp => |*t| t.logMessage(level, msg),
        }
    }
};
```

- [ ] **Step 2: Update callers**

`server.zig`: replace `try Transport.init(allocator)` with `try Transport.initStdio(allocator)`.

`main.zig:cmdLsp`: same substitution where the stdio path is used.

- [ ] **Step 3: Add a placeholder `TcpTransport` so `Transport` compiles**

```zig
pub const TcpTransport = struct {
    pub fn deinit(_: *TcpTransport) void {}
    pub fn readMessage(_: *TcpTransport) ![]const u8 { return error.NotImplemented; }
    pub fn writeMessage(_: *TcpTransport, _: []const u8) !void { return error.NotImplemented; }
    pub fn logMessage(_: *TcpTransport, _: []const u8, _: []const u8) void {}
};
```

Task 26 fleshes this out.

- [ ] **Step 4: Run all existing LSP tests**

```bash
zig build test -Dtest-filter="lsp\|Transport\|e2e_test"
```

Expected: PASS (same behavior, new union dispatch).

- [ ] **Step 5: Commit**

```bash
git add src/cli/lsp/transport.zig src/cli/lsp/server.zig src/cli/main.zig
git commit -m "refactor(lsp): Transport tagged union of stdio + tcp"
```

---

### Task 26: Implement `TcpTransport`

**Files:**
- Modify: `src/cli/lsp/transport.zig`
- Create: `src/cli/lsp/tcp_transport_test.zig`

- [ ] **Step 1: Test**

```zig
const std = @import("std");
const testing = std.testing;
const transport_mod = @import("transport.zig");

test "TcpTransport roundtrips an LSP frame" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.deinit();
    const port = listener.listen_address.in.getPort();

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn accept(l: *std.net.Server) !void {
            const conn = try l.accept();
            var tx = try transport_mod.Transport.initTcp(testing.allocator, conn.stream);
            defer tx.deinit();
            try tx.writeMessage("{\"echo\":1}");
        }
    }.accept, .{&listener});

    const client = try std.net.tcpConnectToHost(testing.allocator, "127.0.0.1", port);
    var rx = try transport_mod.Transport.initTcp(testing.allocator, client);
    defer rx.deinit();
    const msg = try rx.readMessage();
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("{\"echo\":1}", msg);
    server_thread.join();
}
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

Replace the placeholder `TcpTransport` with:

```zig
pub const TcpTransport = struct {
    allocator: Allocator,
    stream: std.net.Stream,

    pub fn init(allocator: Allocator, stream: std.net.Stream) TransportError!TcpTransport {
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn deinit(self: *TcpTransport) void { self.stream.close(); }

    fn readAdapter(ctx: *anyopaque, dest: []u8) framer_mod.FramerError!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ctx));
        return self.stream.read(dest) catch return framer_mod.FramerError.ReadFailed;
    }

    pub fn readMessage(self: *TcpTransport) ![]const u8 {
        var f = framer_mod.Framer.init(readAdapter, self);
        return f.readMessage(MAX_LSP_MESSAGE, self.allocator) catch |e| switch (e) {
            framer_mod.FramerError.EndOfStream => return TransportError.EndOfStream,
            framer_mod.FramerError.MissingContentLength => return TransportError.MissingContentLength,
            framer_mod.FramerError.InvalidContentLength => return TransportError.InvalidContentLength,
            framer_mod.FramerError.InvalidHeader => return TransportError.InvalidHeader,
            framer_mod.FramerError.ReadFailed => return TransportError.ReadFailed,
            framer_mod.FramerError.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn writeMessage(self: *TcpTransport, message: []const u8) !void {
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{message.len});
        defer self.allocator.free(header);
        try self.stream.writeAll(header);
        try self.stream.writeAll(message);
    }

    pub fn logMessage(_: *TcpTransport, _: []const u8, _: []const u8) void {}
};
```

Add to `Transport`:

```zig
pub fn initTcp(allocator: Allocator, stream: std.net.Stream) TransportError!Transport {
    return .{ .tcp = try TcpTransport.init(allocator, stream) };
}
```

- [ ] **Step 4: Register test in `build.zig`; run + commit**

```bash
zig build test -Dtest-filter="TcpTransport roundtrips"
git add src/cli/lsp/transport.zig src/cli/lsp/tcp_transport_test.zig build.zig
git commit -m "feat(lsp): TCP transport (same frame format as stdio)"
```

---

### Task 27: `geode lsp --listen tcp://127.0.0.1:PORT`

**Files:**
- Modify: `src/cli/main.zig` — `cmdLsp`

- [ ] **Step 1: Parse the flag**

```zig
var listen_addr: ?[]const u8 = null;
var allow_unauth = false;
while (it.next()) |arg| {
    if (std.mem.startsWith(u8, arg, "--listen=")) listen_addr = arg["--listen=".len..]
    else if (std.mem.eql(u8, arg, "--no-auth")) allow_unauth = true;
}
```

- [ ] **Step 2: TCP-listen branch**

```zig
if (listen_addr) |addr_raw| {
    const stripped = if (std.mem.startsWith(u8, addr_raw, "tcp://"))
        addr_raw["tcp://".len..]
    else
        addr_raw;
    var parts = std.mem.splitScalar(u8, stripped, ':');
    const host = parts.next() orelse return error.InvalidListenAddr;
    const port_str = parts.next() orelse return error.InvalidListenAddr;
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const a = try std.net.Address.parseIp(host, port);
    var listener = try a.listen(.{});
    defer listener.deinit();
    while (true) {
        const conn = try listener.accept();
        const tx = try transport.Transport.initTcp(allocator, conn.stream);
        var srv = try Server.initWithTransport(allocator, tx, allow_unauth);
        defer srv.deinit();
        srv.run() catch |e| std.log.err("LSP TCP session error: {s}", .{@errorName(e)});
    }
}
```

For `Server.initWithTransport`, accept an existing `Transport` value instead of building stdio.

- [ ] **Step 3: Smoke test**

```bash
./zig-out/bin/geode lsp --listen=tcp://127.0.0.1:3142 --no-auth &
printf 'Content-Length: 96\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}' | nc 127.0.0.1 3142
```

Expected: JSON-RPC response with `result.capabilities`.

- [ ] **Step 4: Commit**

```bash
git add src/cli/main.zig src/cli/lsp/server.zig
git commit -m "feat(cli): geode lsp --listen tcp:// + --no-auth"
```

---

## Phase 9 — Co-host LSP listener in `geode serve`

### Task 28: Spawn LSP listener thread inside `geode serve`

**Files:**
- Modify: `src/server/main.zig`

- [ ] **Step 1: Add config fields**

Find the server config struct (search `pub const ServerConfig\|struct {.*listen` in `src/server/main.zig`):

```zig
lsp_port: u16 = 3142,
lsp_loopback_only: bool = true,
```

Add CLI flag parsing (`--lsp-port`, `--lsp-bind-all`).

- [ ] **Step 2: Listener function**

```zig
fn runLspListener(allocator: std.mem.Allocator, port: u16, loopback_only: bool) !void {
    const host = if (loopback_only) "127.0.0.1" else "0.0.0.0";
    const addr = try std.net.Address.parseIp(host, port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    std.log.info("LSP listening on {s}:{d}", .{ host, port });
    while (true) {
        const conn = listener.accept() catch |e| {
            std.log.err("LSP accept error: {s}", .{@errorName(e)});
            continue;
        };
        const thr = std.Thread.spawn(.{}, runLspSession, .{ allocator, conn.stream }) catch |e| {
            std.log.err("LSP session spawn error: {s}", .{@errorName(e)});
            conn.stream.close();
            continue;
        };
        thr.detach();
    }
}

fn runLspSession(allocator: std.mem.Allocator, stream: std.net.Stream) void {
    const tx = transport.Transport.initTcp(allocator, stream) catch return;
    var srv = lsp.Server.initWithTransport(allocator, tx, false) catch return;
    defer srv.deinit();
    srv.run() catch |e| std.log.err("LSP session error: {s}", .{@errorName(e)});
}
```

- [ ] **Step 3: Spawn after QUIC server is up**

Find the spot in `runServer` (or equivalent) where QUIC is already accepting; insert:

```zig
if (cfg.lsp_port != 0) {
    const lsp_thr = try std.Thread.spawn(.{}, runLspListener, .{ allocator, cfg.lsp_port, cfg.lsp_loopback_only });
    lsp_thr.detach();
}
```

- [ ] **Step 4: Smoke test**

```bash
./zig-out/bin/geode serve --listen 0.0.0.0:3141 &
sleep 1
nc -z 127.0.0.1 3142  # expect success
```

- [ ] **Step 5: Commit**

```bash
git add src/server/main.zig
git commit -m "feat(server): co-host LSP TCP listener on 127.0.0.1:3142"
```

---

### Task 29: End-to-end Zig integration test

**Files:**
- Create: `tests/test_lsp_embedded_e2e.zig`

- [ ] **Step 1: Sketch**

```zig
const std = @import("std");
const testing = std.testing;

test "embedded LSP returns user-visible labels via TCP" {
    const alloc = testing.allocator;

    // 1. Boot the server in-process (reuse the harness from src/server/server_test.zig
    //    if `bootServerForTest(alloc) -> ServerHandle` is available).
    // 2. Issue a CREATE NODE :Person via the in-process executor so the store has data.
    // 3. Mint a JWT for "alice" via jwt_mod.signForTest.
    // 4. Open a TCP connection to 127.0.0.1:<test_port>.
    // 5. Send initialize with initializationOptions.geode.authToken = JWT.
    // 6. Send textDocument/didOpen with "MATCH (n:".
    // 7. Send textDocument/completion at line 0 char 9.
    // 8. Assert the response contains a CompletionItem with label "Person".
}
```

Use the in-process server harness; if none exists, mirror the pattern in `src/cli/lsp/e2e_test.zig` (in-memory transport) and substitute a TCP `Transport`.

- [ ] **Step 2: Wire into `build.zig` and run**

```bash
zig build test -Dtest-filter="embedded LSP returns user-visible"
```

- [ ] **Step 3: Commit**

```bash
git add tests/test_lsp_embedded_e2e.zig build.zig
git commit -m "test(lsp): end-to-end embedded LSP completion through TCP"
```

---

## Phase 10 — geode-ui WebSocket Bridge (Go)

### Task 30: Add `/ws/lsp` WebSocket handler

**Files:**
- Create: `../geode-ui/internal/server/ws_lsp.go`
- Create: `../geode-ui/internal/server/ws_lsp_test.go`
- Modify: `../geode-ui/internal/server/server.go`

- [ ] **Step 1: Failing test**

```go
package server

import (
    "net/http"
    "strings"
    "testing"
    "github.com/gorilla/websocket"
)

func TestWsLspRequiresAuth(t *testing.T) {
    srv := newTestServer(t)
    defer srv.Close()
    u := strings.Replace(srv.URL, "http", "ws", 1) + "/ws/lsp"
    _, resp, err := websocket.DefaultDialer.Dial(u, nil)
    if err == nil {
        t.Fatal("expected dial failure without token")
    }
    if resp == nil || resp.StatusCode != http.StatusUnauthorized {
        t.Fatalf("want 401, got %v", resp)
    }
}

func TestWsLspProxiesFrameToUpstream(t *testing.T) {
    upstream := newFakeLspTcp(t)
    defer upstream.Close()
    srv := newTestServerWithLsp(t, upstream.Addr())
    defer srv.Close()
    tok := mintTestToken(t, "alice")

    u := strings.Replace(srv.URL, "http", "ws", 1) + "/ws/lsp?access_token=" + tok
    c, _, err := websocket.DefaultDialer.Dial(u, nil)
    if err != nil {
        t.Fatal(err)
    }
    defer c.Close()
    payload := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
    if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
        t.Fatal(err)
    }
    got := upstream.WaitForFrame(t)
    if !strings.Contains(string(got), "initialize") {
        t.Fatalf("upstream got %q", got)
    }
}
```

Helpers `newTestServer`, `newTestServerWithLsp`, `newFakeLspTcp`, `mintTestToken` follow the pattern in `ws_query_test.go`.

- [ ] **Step 2: Run — fail**

```bash
cd ../geode-ui && go test ./internal/server/ -run TestWsLsp
```

- [ ] **Step 3: Implement handler**

```go
package server

import (
    "encoding/json"
    "fmt"
    "io"
    "net"
    "net/http"

    "github.com/gorilla/websocket"
)

type wsLspHandler struct {
    upstreamAddr string
    upgrader     websocket.Upgrader
    auth         AuthValidator
}

func newWsLspHandler(upstream string, auth AuthValidator) *wsLspHandler {
    return &wsLspHandler{
        upstreamAddr: upstream,
        auth:         auth,
        upgrader: websocket.Upgrader{
            CheckOrigin: func(r *http.Request) bool { return true },
        },
    }
}

func (h *wsLspHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    claims, ok := h.auth.FromRequest(r)
    if !ok {
        http.Error(w, "unauthorized", http.StatusUnauthorized)
        return
    }
    ws, err := h.upgrader.Upgrade(w, r, nil)
    if err != nil {
        return
    }
    defer ws.Close()

    tcp, err := net.Dial("tcp", h.upstreamAddr)
    if err != nil {
        ws.WriteMessage(websocket.CloseMessage, []byte("upstream dial failed"))
        return
    }
    defer tcp.Close()

    errCh := make(chan error, 2)
    go func() { errCh <- proxyWsToTcp(ws, tcp, claims) }()
    go func() { errCh <- proxyTcpToWs(tcp, ws) }()
    <-errCh
}

func proxyWsToTcp(ws *websocket.Conn, tcp net.Conn, claims *Claims) error {
    for {
        _, body, err := ws.ReadMessage()
        if err != nil {
            return err
        }
        body = injectAuthIntoInitialize(body, claims)
        header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))
        if _, err := tcp.Write([]byte(header)); err != nil {
            return err
        }
        if _, err := tcp.Write(body); err != nil {
            return err
        }
    }
}

func proxyTcpToWs(tcp net.Conn, ws *websocket.Conn) error {
    rd := newLspFrameReader(tcp)
    for {
        frame, err := rd.ReadFrame()
        if err == io.EOF {
            return nil
        }
        if err != nil {
            return err
        }
        if err := ws.WriteMessage(websocket.TextMessage, frame); err != nil {
            return err
        }
    }
}

// Inject claims.AccessToken into params.initializationOptions.geode.authToken
// only on the initial `initialize` request. Other frames are passed unchanged.
func injectAuthIntoInitialize(body []byte, claims *Claims) []byte {
    var msg map[string]any
    if err := json.Unmarshal(body, &msg); err != nil {
        return body
    }
    if m, ok := msg["method"].(string); !ok || m != "initialize" {
        return body
    }
    params, _ := msg["params"].(map[string]any)
    if params == nil {
        params = map[string]any{}
        msg["params"] = params
    }
    initOpts, _ := params["initializationOptions"].(map[string]any)
    if initOpts == nil {
        initOpts = map[string]any{}
        params["initializationOptions"] = initOpts
    }
    geode, _ := initOpts["geode"].(map[string]any)
    if geode == nil {
        geode = map[string]any{}
        initOpts["geode"] = geode
    }
    geode["authToken"] = claims.AccessToken
    if claims.TenantID != "" {
        geode["tenant"] = claims.TenantID
    }
    out, _ := json.Marshal(msg)
    return out
}
```

`newLspFrameReader` is a minimal `Content-Length: N\r\n\r\n<body>` parser — copy the pattern from `internal/server/result_codec.go` if a generic framer already exists, otherwise implement inline.

- [ ] **Step 4: Wire the route**

In `internal/server/server.go` where `/ws/query` is registered, add (under the same auth middleware):

```go
if cfg.LSP.Enabled {
    mux.Handle("/ws/lsp", authMiddleware(newWsLspHandler(cfg.LSP.UpstreamAddr, authValidator)))
}
```

- [ ] **Step 5: Run + commit**

```bash
cd ../geode-ui && go test ./internal/server/ -run TestWsLsp
git -C ../geode-ui add internal/server/ws_lsp.go internal/server/ws_lsp_test.go internal/server/server.go
git -C ../geode-ui commit -m "feat(server): /ws/lsp WebSocket bridge to upstream LSP TCP"
```

---

### Task 31: Config plumbing for `LSP.Enabled` + `LSP.UpstreamAddr`

**Files:**
- Modify: `../geode-ui/internal/server/server.go` (or wherever `Config` lives)
- Modify: `../geode-ui/geode.json`

- [ ] **Step 1: Extend the config struct**

```go
type LspConfig struct {
    UpstreamAddr string `json:"upstream_addr"`
    Enabled      bool   `json:"enabled"`
}

type Config struct {
    // ... existing fields ...
    LSP LspConfig `json:"lsp"`
}
```

Defaults applied on load: `UpstreamAddr = "127.0.0.1:3142"`, `Enabled = true`.

- [ ] **Step 2: Add to `geode.json` schema example** with comment.

- [ ] **Step 3: Test config defaults** in `internal/server/server_test.go`.

- [ ] **Step 4: Commit**

```bash
git -C ../geode-ui add internal/server/server.go geode.json
git -C ../geode-ui commit -m "feat(config): LspConfig (upstream addr + enabled toggle)"
```

---

## Phase 11 — Monaco LSP Client in geode-ui

### Task 32: Add LSP dependencies

**Files:**
- Modify: `../geode-ui/package.json`

- [ ] **Step 1: Install**

```bash
cd ../geode-ui
npm install --save monaco-languageclient@8 vscode-ws-jsonrpc@3 vscode-languageserver-protocol@3 vscode-languageclient@9
```

- [ ] **Step 2: Verify**

```bash
npm ls monaco-languageclient
```

- [ ] **Step 3: Commit**

```bash
git -C ../geode-ui add package.json package-lock.json
git -C ../geode-ui commit -m "chore(deps): add monaco-languageclient + transport"
```

---

### Task 33: WebSocket transport adapter

**Files:**
- Create: `../geode-ui/src/lib/lsp/websocketTransport.ts`
- Create: `../geode-ui/src/lib/lsp/__tests__/websocketTransport.test.ts`

- [ ] **Step 1: Failing test**

```ts
import { describe, it, expect, vi } from '@jest/globals'
import { createWebSocketTransport } from '../websocketTransport'

class MockWS {
  url: string
  onopen?: () => void
  onmessage?: (e: { data: string }) => void
  onclose?: () => void
  onerror?: (e: any) => void
  readyState = 1
  send = vi.fn()
  close = vi.fn()
  constructor(url: string) {
    this.url = url
    setTimeout(() => this.onopen?.(), 0)
  }
}

describe('createWebSocketTransport', () => {
  it('opens WebSocket with access_token', async () => {
    ;(globalThis as any).WebSocket = MockWS
    const t = await createWebSocketTransport({ url: 'ws://test/ws/lsp', accessToken: 'TKN' })
    expect((t as any).socket.url).toContain('access_token=TKN')
    t.dispose()
  })
})
```

- [ ] **Step 2: Run — fail**

```bash
cd ../geode-ui && npm test -- websocketTransport
```

- [ ] **Step 3: Implement**

```ts
import { toSocket, WebSocketMessageReader, WebSocketMessageWriter } from 'vscode-ws-jsonrpc'

export interface TransportOptions {
  url: string
  accessToken: string
}

export interface LspTransport {
  reader: WebSocketMessageReader
  writer: WebSocketMessageWriter
  socket: WebSocket
  dispose: () => void
}

export async function createWebSocketTransport(opts: TransportOptions): Promise<LspTransport> {
  const url = new URL(opts.url)
  url.searchParams.set('access_token', opts.accessToken)
  const ws = new WebSocket(url.toString())
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve()
    ws.onerror = (e) => reject(e)
  })
  const socket = toSocket(ws as any)
  const reader = new WebSocketMessageReader(socket)
  const writer = new WebSocketMessageWriter(socket)
  return {
    reader,
    writer,
    socket: ws,
    dispose: () => {
      reader.dispose()
      writer.dispose()
      ws.close()
    },
  }
}
```

- [ ] **Step 4: Run + commit**

```bash
npm test -- websocketTransport
git -C ../geode-ui add src/lib/lsp/websocketTransport.ts src/lib/lsp/__tests__/websocketTransport.test.ts
git -C ../geode-ui commit -m "feat(lsp): WebSocket→jsonrpc transport adapter"
```

---

### Task 34: `startLspClient`

**Files:**
- Create: `../geode-ui/src/lib/lsp/client.ts`
- Create: `../geode-ui/src/lib/lsp/__tests__/client.test.ts`

- [ ] **Step 1: Failing test**

```ts
import { describe, it, expect, vi } from '@jest/globals'

vi.mock('monaco-languageclient', () => ({
  MonacoLanguageClient: vi.fn().mockImplementation((cfg) => ({
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn().mockResolvedValue(undefined),
    _cfg: cfg,
  })),
}))

import { startLspClient } from '../client'
import { MonacoLanguageClient } from 'monaco-languageclient'

describe('startLspClient', () => {
  it('passes geode.authToken in initializationOptions', async () => {
    ;(globalThis as any).WebSocket = class {
      onopen?: () => void
      constructor() { setTimeout(() => this.onopen?.(), 0) }
      close() {}
    }
    const handle = await startLspClient({
      monaco: {} as any,
      url: 'ws://test/ws/lsp',
      accessToken: 'TKN',
      graph: 'demo',
      tenant: 'tA',
    })
    const cfg = (MonacoLanguageClient as any).mock.calls[0][0]
    expect(cfg.clientOptions.initializationOptions.geode).toEqual({
      authToken: 'TKN',
      graph: 'demo',
      tenant: 'tA',
    })
    await handle.dispose()
  })
})
```

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement**

```ts
import { MonacoLanguageClient } from 'monaco-languageclient'
import { CloseAction, ErrorAction } from 'vscode-languageclient'
import { createWebSocketTransport, LspTransport } from './websocketTransport'

export interface StartOptions {
  monaco: typeof import('monaco-editor')
  url: string
  accessToken: string
  graph: string
  tenant?: string
}

export interface LspClientHandle {
  dispose: () => Promise<void>
}

export async function startLspClient(opts: StartOptions): Promise<LspClientHandle> {
  const transport: LspTransport = await createWebSocketTransport({
    url: opts.url,
    accessToken: opts.accessToken,
  })

  const client = new MonacoLanguageClient({
    name: 'Geode GQL',
    clientOptions: {
      documentSelector: ['gql'],
      errorHandler: {
        error: () => ({ action: ErrorAction.Continue }),
        closed: () => ({ action: CloseAction.DoNotRestart }),
      },
      initializationOptions: {
        geode: { authToken: opts.accessToken, graph: opts.graph, tenant: opts.tenant },
      },
    },
    connectionProvider: {
      get: () => Promise.resolve({ reader: transport.reader, writer: transport.writer }),
    },
  })

  await client.start()
  return {
    dispose: async () => {
      try { await client.stop() } catch {}
      transport.dispose()
    },
  }
}
```

- [ ] **Step 4: Run + commit**

```bash
npm test -- lsp/client
git -C ../geode-ui add src/lib/lsp/client.ts src/lib/lsp/__tests__/client.test.ts
git -C ../geode-ui commit -m "feat(lsp): monaco-languageclient bootstrap"
```

---

### Task 35: Wire `LspClient` into `GqlEditor.tsx`

**Files:**
- Modify: `../geode-ui/src/components/editor/GqlEditor.tsx`

- [ ] **Step 1: Replace mount handler**

```tsx
import { useEffect, useRef } from 'react'
import Editor, { OnMount } from '@monaco-editor/react'
import { registerGqlLanguage, GQL_LANGUAGE_ID } from './gqlLanguage'
import { startLspClient, LspClientHandle } from '../../lib/lsp/client'
import { useAuthStore } from '../../store/auth'

export interface GqlEditorProps {
  value: string
  onChange: (next: string) => void
  onRun: () => void
  graph?: string
}

export function GqlEditor({ value, onChange, onRun, graph }: GqlEditorProps) {
  const lspRef = useRef<LspClientHandle | null>(null)
  const { accessToken, tenantId } = useAuthStore()

  const handleMount: OnMount = async (editor, monaco) => {
    registerGqlLanguage(monaco)
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, onRun)
    if (!accessToken) return
    try {
      lspRef.current = await startLspClient({
        monaco,
        url: `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/lsp`,
        accessToken,
        graph: graph || 'default',
        tenant: tenantId,
      })
    } catch (e) {
      // Editor still works without LSP; surface a console warning only.
      // eslint-disable-next-line no-console
      console.warn('LSP client failed to start', e)
    }
  }

  useEffect(() => () => { lspRef.current?.dispose() }, [])

  return <Editor language={GQL_LANGUAGE_ID} value={value} onChange={(v) => onChange(v ?? '')} onMount={handleMount} theme="vs-dark" />
}
```

- [ ] **Step 2: Manual test**

```bash
cd ../geode-ui && npm run start
# Browser: login → query editor → type "MATCH (n:" → dropdown shows your labels
```

- [ ] **Step 3: Commit**

```bash
git -C ../geode-ui add src/components/editor/GqlEditor.tsx
git -C ../geode-ui commit -m "feat(editor): wire monaco LSP client on mount"
```

---

### Task 36: Reconnect on token refresh / network drop

**Files:**
- Modify: `../geode-ui/src/lib/lsp/client.ts`
- Modify: `../geode-ui/src/components/editor/GqlEditor.tsx`

- [ ] **Step 1: Reconnect helper**

In `client.ts`, on transport close inside `startLspClient`, attempt up to 3 reconnects with exponential backoff (500 ms, 1500 ms, 4500 ms). Expose the reconnection state via a callback option `onStateChange(state: 'connecting'|'open'|'closed'|'failed')`.

- [ ] **Step 2: Wire token refresh in `GqlEditor.tsx`**

```tsx
useEffect(() => {
  if (!accessToken) return
  let cancelled = false
  ;(async () => {
    await lspRef.current?.dispose()
    if (cancelled) return
    lspRef.current = await startLspClient({ /* ... */ })
  })()
  return () => { cancelled = true }
}, [accessToken, tenantId, graph])
```

- [ ] **Step 3: Unit test** that mocks a WebSocket close and asserts a second `startLspClient` call happens.

- [ ] **Step 4: Commit**

```bash
npm test -- lsp/client
git -C ../geode-ui add src/lib/lsp/client.ts src/components/editor/GqlEditor.tsx
git -C ../geode-ui commit -m "feat(lsp): reconnect on auth refresh and network drop"
```

---

## Phase 12 — End-to-End Validation + Docs

### Task 37: Enable the geodetestlab spec

**Files:**
- Modify: `../geode-test-harness/geodetestlab-cli/specs/lsp_schema_completion.yml`

- [ ] **Step 1: Remove `skip:` marker** from the spec authored in Task 20.

- [ ] **Step 2: Run**

```bash
cd ../geode-test-harness
make test-spec SPEC=geodetestlab-cli/specs/lsp_schema_completion.yml GEODE_BINARY=/path/to/built/geode
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git -C ../geode-test-harness add geodetestlab-cli/specs/lsp_schema_completion.yml
git -C ../geode-test-harness commit -m "test(lsp): enable schema completion e2e spec"
```

---

### Task 38: Documentation

**Files:**
- Create: `docs/LSP_FEATURES.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write `docs/LSP_FEATURES.md`**

Sections:
- **Overview** — capabilities provided (completion, hover, diagnostics, definition, references, document symbols, semantic tokens, formatting, signature help).
- **Transports** — stdio (terminal editors) and TCP/127.0.0.1:3142 (browser via `geode-ui` `/ws/lsp` bridge).
- **Authentication** — JWT in `initializationOptions.geode.authToken`; stdio supports `--no-auth` for local dev; TCP **always** requires auth.
- **Schema-aware completion** — cursor-context detection (`(n:` → label, `[r:` → edge type, `n.` → property of `n`'s label) with TTL-cached, permission-filtered results.
- **Hover** — schema info for labels, edge types, properties.
- **Diagnostics** — warnings for unknown labels/edge types with closest-match hints.
- **TTL + DDL invalidation** — schema cached for 5 s; CREATE/DROP/ALTER fires an in-process invalidation broadcast.
- **Limitations** — list out-of-scope features (codeAction, executeCommand, workspace/symbol, rename, persistent property catalog) and link to the follow-on plans section.
- **Architecture diagram** — ASCII: browser ↔ geode-ui Go ↔ upstream geode TCP LSP ↔ in-process `schema_introspection`.

- [ ] **Step 2: Update `CLAUDE.md`**

Under "Essential References":

```markdown
- **[LSP Features](docs/LSP_FEATURES.md)** - Schema-aware completion, hover, and diagnostics with per-user permission filtering
```

- [ ] **Step 3: Commit**

```bash
git add docs/LSP_FEATURES.md CLAUDE.md
git commit -m "docs(lsp): schema-aware completion + transports"
```

---

## Verification Checklist (run before declaring the plan done)

- [ ] `zig build test` passes (existing tests + ~25 new tests across schema, schema_provider, auth, completion_context, features, transport, embedded e2e).
- [ ] `cd ../geode-ui && go test ./...` passes (new `ws_lsp` tests).
- [ ] `cd ../geode-ui && npm test` passes (new `client` + `websocketTransport` tests).
- [ ] `make test-spec SPEC=geodetestlab-cli/specs/lsp_schema_completion.yml` PASS.
- [ ] Manual browser smoke test: login → open query editor → type `MATCH (n:` → dropdown populated **only** with labels you can see, **not** labels in other tenants/graphs.
- [ ] Manual test: as a user without `GRANT ... ON GRAPH secret`, switch graph context to `secret` → empty completion suggestions (visibility gate working).
- [ ] Manual test: hover on a known label → property list; hover on `n.email` (where `n:Person`) → owning-label info.
- [ ] Manual test: type `MATCH (n:Persn)` → yellow squiggle with "Did you mean `Person`?".
- [ ] Manual test: `CREATE (:NewLabel {x:1})` via shell, return to editor within 6 seconds → `NewLabel` appears in completion suggestions (DDL notifier or TTL).
- [ ] No leaks: `zig build test -Doptimize=Debug 2>&1 | grep -i leak` shows none.

---

## Notes on follow-on plans

After this plan lands, the natural next plans (each ~20–30 tasks):

1. **Plan B — Schema-aware codeAction + quick fixes:** auto-rename unknown label, "Add LIMIT", "Use existing variable", "Wrap CREATE in MERGE".
2. **Plan C — workspace/executeCommand virtual docs:** `geode.explainQuery`, `geode.profileQuery`, `geode.refreshSchema`.
3. **Plan D — workspace/symbol + textDocument/rename:** cross-document label/type search, variable rename in scope.
4. **Plan E — Persistent property catalog:** incremental, write-side updates; replaces the live scan in `listPropertiesForLabel` with O(1) lookups.
5. **Plan F — UI affordances:** schema browser panel that mirrors LSP data, "Run with EXPLAIN" button, format-on-save, settings page for completion sources.
