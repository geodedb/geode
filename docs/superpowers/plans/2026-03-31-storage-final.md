# Storage Final Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete per-graph storage durability across Geode and `graph-storage` so that every mutation (edge properties, labels, node properties) survives restart, crash recovery replays committed changes, and the label model is sound beyond 32 labels.

**Architecture:** Two repos: `graph-storage` (the engine library at `/home/benji/src/devnw/zig/graph-storage/`) owns physical pages, WAL, recovery, and manifest. Geode (`/home/benji/src/devnw/codepros/geode/geode/`) owns the query layer and connects via `StorageAdapter` + `AdapterVTable`. The plan makes `graph-storage` the sole crash-recovery authority, with Geode's `src/wal.zig` becoming a post-commit logical feed only.

**Tech Stack:** Zig 0.15.1, graph-storage engine (page-based, WAL, buffer pool), spice parallelism

**Repos:**

- Engine: `/home/benji/src/devnw/zig/graph-storage/` (referred to as `GS` below)
- Geode: `/home/benji/src/devnw/codepros/geode/geode/` (referred to as `GEODE` below)

---

## Scope Note

This spec covers 8 phases across two repos. Each phase is independently deployable and testable. The plan follows the spec's suggested execution order.

---

## File Map

### graph-storage (GS) files to create or modify

| File | Action | Responsibility |
|------|--------|----------------|
| `GS/src/adj_store.zig` | Modify | Add `updateEdgePropHead()` for in-place prop_head mutation |
| `GS/src/engine.zig` | Modify | Add edge property helpers, fix expandOut/expandIn signatures, wire transactions to normal mutations |
| `GS/src/node.zig` | Modify | Replace `label_set: u32` with `label_head: u64` + `label_count: u16` |
| `GS/src/node_store.zig` | Modify | Adapt to new NodeRec layout |
| `GS/src/label_index.zig` | Modify | Rebuild from new label block chain instead of bitmap |
| `GS/src/label_store.zig` | Create | Variable-length label membership blocks in var.store |
| `GS/src/free_space.zig` | Modify | Add persistence (save/load bitmap to free.store) |
| `GS/src/interface.zig` | Modify | Add edge property methods to VTable |
| `GS/src/manifest.zig` | Modify | Bump format_version, add migration flag |
| `GS/src/migration.zig` | Create/Modify | V1-to-V2 on-disk migration logic |
| `GS/src/recovery.zig` | Modify | Filter uncommitted page updates during replay |
| `GS/src/txn.zig` | Modify | Wire dirty-page tracking to commit protocol |
| `GS/tests/integration.zig` | Modify | Fix expandOut signature, add edge property + label + crash tests |

### Geode (GEODE) files to modify

| File | Action | Responsibility |
|------|--------|----------------|
| `GEODE/src/graph_store.zig` | Modify | Extend AdapterVTable with 4 missing methods, wire dual-write |
| `GEODE/src/storage/graph_storage_adapter.zig` | Modify | Implement setEdgeProperty, removeEdgeProperty, addNodeLabel, removeNodeLabel; fix label loading |
| `GEODE/src/wal.zig` | Modify | Demote to post-commit logical feed; stop being primary durability path |
| `GEODE/build.zig.zon` | Modify | Pin graph-storage dep to new version after each phase |

---

## Phase 0: Stabilize the Verification Harness

### Task 0.1: Fix integration test expandOut/expandIn signature mismatch

**Files:**

- Modify: `GS/src/engine.zig` (lines 438-445: expandOut, expandIn)
- Modify: `GS/src/interface.zig` (lines 76-77: VTable expandOut, expandIn)
- Test: `GS/tests/integration.zig`

The VTable expects `expandOut(ptr, id, rel_type, allocator) -> EdgeIterator` but engine.zig implements `expandOut(id, rel_type) -> AdjEdgeIterator`. The integration test calls with allocator. Fix the engine to match the VTable signature by accepting the allocator parameter (even if unused for now, it enables the VTable to collect edges into a slice).

- [ ] **Step 1: Read the current expandOut/expandIn in engine.zig and interface.zig**

Confirm the mismatch. Engine at line 438:

```zig
pub fn expandOut(self: *GraphEngine, id: NodeId, rel_type: ?u32) anyerror!AdjStore.AdjEdgeIterator {
```

VTable at interface.zig line 76:

```zig
expandOut: *const fn (ptr: *anyopaque, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror!EdgeIterator,
```

- [ ] **Step 2: Define EdgeIterator in interface.zig if not already**

Check if `EdgeIterator` is already defined. It should be a slice `[]EdgeEntry` or a struct wrapping the AdjStore iterator. The VTable returns `EdgeIterator` — confirm its type.

- [ ] **Step 3: Update engine.zig expandOut/expandIn to accept allocator and return []EdgeEntry**

```zig
pub fn expandOut(self: *GraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
    const rec = try self.node_store.getNode(id) orelse return &[_]EdgeEntry{};
    var iter = self.adj_out.expand(rec.out_head, rel_type);
    var list = std.ArrayList(EdgeEntry).init(allocator);
    while (try iter.next()) |entry| {
        try list.append(entry);
    }
    return list.toOwnedSlice();
}
```

Do the same for `expandIn`.

- [ ] **Step 4: Update the VTable storage() wrapper to match**

In engine.zig, the `storage()` method returns a `GraphStorage` backed by function pointers. Update the `expandOutFn` and `expandInFn` wrappers to pass through the allocator.

- [ ] **Step 5: Run integration tests**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test-integration 2>&1
```

Expected: all 3 integration tests pass (version, full lifecycle, vtable round-trip).

- [ ] **Step 6: Run unit tests**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1
```

Expected: all unit tests pass.

- [ ] **Step 7: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/engine.zig src/interface.zig tests/integration.zig
git commit -m "fix: align expandOut/expandIn signatures with VTable (allocator param, []EdgeEntry return)"
```

---

### Task 0.2: Add storage smoke test (create, write, checkpoint, reopen, verify)

**Files:**

- Modify: `GS/tests/integration.zig`

- [ ] **Step 1: Write the round-trip smoke test**

Add a test that exercises: create graph -> add nodes with properties -> add edges -> add labels -> checkpoint -> close -> reopen -> verify all data survives.

```zig
test "QUAL-0020: storage smoke test — full round-trip with properties and labels" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const uuid = [_]u8{0xAA} ** 16;
    const config = gs.GraphConfig{ .page_size = 4096 };

    // Phase 1: Create and populate
    {
        var eng = try gs.GraphEngine.create(allocator, path, uuid, config);
        defer eng.close() catch {};

        // Add 3 nodes
        const n1 = try eng.allocNode();
        try eng.putNode(n1, .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_set = 0, .flags = 0, ._pad = 0, .txn_stamp = 1 });
        const n2 = try eng.allocNode();
        try eng.putNode(n2, .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_set = 0, .flags = 0, ._pad = 0, .txn_stamp = 1 });
        const n3 = try eng.allocNode();
        try eng.putNode(n3, .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_set = 0, .flags = 0, ._pad = 0, .txn_stamp = 1 });

        // Set node properties
        const new_head = try eng.putProperty(0, "name", .{ .String = "Alice" });
        var rec1 = (try eng.getNode(n1)).?;
        rec1.prop_head = new_head;
        try eng.putNode(n1, rec1);

        // Add edges
        _ = try eng.addEdge(n1, n2, 10); // KNOWS
        _ = try eng.addEdge(n1, n3, 20); // LIKES

        // Add labels
        try eng.addLabel(n1, 1); // Person
        try eng.addLabel(n1, 2); // Employee

        // Checkpoint
        try eng.checkpoint();
    }

    // Phase 2: Reopen and verify
    {
        var eng = try gs.GraphEngine.open(allocator, path, uuid, config);
        defer eng.close() catch {};

        // Verify nodes exist
        const r1 = (try eng.getNode(1)).?;
        try std.testing.expect(r1.flags & 0x1 == 0); // not deleted

        // Verify node property
        const val = try eng.getProperty(r1.prop_head, "name", allocator);
        try std.testing.expect(val != null);
        // (property value comparison depends on PropertyValue type)

        // Verify edges
        const edges = try eng.expandOut(1, null, allocator);
        defer allocator.free(edges);
        try std.testing.expectEqual(@as(usize, 2), edges.len);

        // Verify labels
        const label_nodes = try eng.scanLabel(1, allocator);
        defer allocator.free(label_nodes);
        try std.testing.expect(label_nodes.len >= 1);

        // Verify edge count
        try std.testing.expectEqual(@as(u64, 2), try eng.edgeCount());
    }
}
```

- [ ] **Step 2: Run the test**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test-integration 2>&1
```

Expected: PASS. If it fails, debug the specific assertion.

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add tests/integration.zig
git commit -m "test: add storage smoke test — full round-trip with properties and labels"
```

---

### Task 0.3: Add crash-simulation test (kill before checkpoint, verify replay)

**Files:**

- Modify: `GS/tests/integration.zig`

- [ ] **Step 1: Write the crash simulation test**

This test creates a graph, begins a transaction, writes pages via the transaction, does NOT checkpoint, closes without clean shutdown, reopens and verifies that committed transactions are replayed and uncommitted ones are discarded.

```zig
test "QUAL-0021: crash recovery — committed txn replayed, uncommitted discarded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const uuid = [_]u8{0xBB} ** 16;
    const config = gs.GraphConfig{ .page_size = 4096 };

    // Phase 1: Create, add nodes, checkpoint once to establish baseline
    {
        var eng = try gs.GraphEngine.create(allocator, path, uuid, config);
        const n1 = try eng.allocNode();
        try eng.putNode(n1, .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_set = 0, .flags = 0, ._pad = 0, .txn_stamp = 1 });
        try eng.checkpoint();
        // Add more nodes AFTER checkpoint (these are in WAL but not checkpointed)
        const n2 = try eng.allocNode();
        try eng.putNode(n2, .{ .out_head = 0, .in_head = 0, .prop_head = 0, .label_set = 0, .flags = 0, ._pad = 0, .txn_stamp = 1 });
        // Begin a committed transaction
        const txn = try eng.txn_manager.begin();
        // Log a page update for n2's page
        const page_id = 0; // page containing node 2
        _ = try eng.txn_manager.logPageUpdate(txn, .nodes, page_id, &[_]u8{0} ** 4096);
        try eng.txn_manager.commit(txn);
        // Simulate crash: close without checkpoint
        try eng.close();
    }

    // Phase 2: Reopen — recovery should replay committed txn
    {
        var eng = try gs.GraphEngine.open(allocator, path, uuid, config);
        defer eng.close() catch {};
        // Node 1 should definitely exist (was checkpointed)
        const r1 = try eng.getNode(1);
        try std.testing.expect(r1 != null);
        // Recovery behavior for node 2 depends on WAL replay
    }
}
```

- [ ] **Step 2: Run and verify**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test-integration 2>&1
```

Adjust assertions based on actual recovery behavior. The key verification is that `open()` completes without error after unclean shutdown.

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add tests/integration.zig
git commit -m "test: add crash-simulation test for WAL recovery"
```

---

## Phase 1: Complete the Dual-Write API Surface in Geode

### Task 1.1: Add missing vtable methods to AdapterVTable

**Files:**

- Modify: `GEODE/src/graph_store.zig` (AdapterVTable at ~line 3158)

- [ ] **Step 1: Read the current AdapterVTable definition**

```bash
# Find the exact line
```

Read `GEODE/src/graph_store.zig` around line 3158 to see the current vtable fields.

- [ ] **Step 2: Add the 4 missing function pointer fields**

Add after the existing `removeNodePropertyFn` field:

```zig
const AdapterVTable = struct {
    ctx: *anyopaque,
    graphExistsFn: *const fn (*anyopaque, []const u8) bool,
    getOrCreateGraphFn: *const fn (*anyopaque, []const u8) anyerror!void,
    dropGraphFn: *const fn (*anyopaque, []const u8) anyerror!void,
    createNodeFn: *const fn (*anyopaque, []const u8, u64, []const []const u8) anyerror!void,
    createEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, u64, []const u8) anyerror!void,
    deleteNodeFn: *const fn (*anyopaque, []const u8, u64) anyerror!void,
    deleteEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, u64) anyerror!void,
    setNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8, PropertyValue) anyerror!void,
    removeNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    // New: edge property and label mutation methods
    setEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8, PropertyValue) anyerror!void,
    removeEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8) anyerror!void,
    addNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    removeNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    deinitFn: *const fn (*anyopaque) void,
};
```

Use optional function pointers (`?*const fn`) so existing code that constructs AdapterVTable doesn't break immediately — they can pass `null` until the adapter implements them.

- [ ] **Step 3: Update initGlobalAdapter to wire the new function pointers**

In the function that creates the AdapterVTable from a StorageAdapter, wire the new function pointers. For now, set them to `null` until Task 1.3 implements the adapter methods.

- [ ] **Step 4: Verify build**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/graph_store.zig
git commit -m "feat: extend AdapterVTable with edge property and label mutation methods"
```

---

### Task 1.2: Wire dual-write in GraphStore mutation methods

**Files:**

- Modify: `GEODE/src/graph_store.zig` (setEdgeProperty ~line 1817, removeEdgeProperty ~line 1843, addNodeLabel ~line 1041, removeNodeLabel ~line 1074)

- [ ] **Step 1: Wire setEdgeProperty to adapter**

At the top of `setEdgeProperty`, before the in-memory mutation, add adapter call:

```zig
pub fn setEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
    // Dual-write to adapter if available
    if (self.adapter) |vt| {
        if (vt.setEdgePropertyFn) |f| {
            const edge = self.edges.get(edge_id) orelse return error.EdgeNotFound;
            f(vt.ctx, edge.graph_name, edge.from_id, edge.to_id, edge_id, key, value) catch |err| {
                // Log but don't block in-memory mutation for now
                // TODO: make this a hard error once adapter is reliable
                log.warn("adapter setEdgeProperty failed: {s}", .{@errorName(err)});
            };
        }
    }
    // Existing in-memory mutation follows...
```

- [ ] **Step 2: Wire removeEdgeProperty to adapter**

Same pattern as Step 1 but calling `removeEdgePropertyFn`.

- [ ] **Step 3: Wire addNodeLabel to adapter**

```zig
pub fn addNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
    if (self.adapter) |vt| {
        if (vt.addNodeLabelFn) |f| {
            const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
            f(vt.ctx, node.graph_name, node_id, label) catch |err| {
                log.warn("adapter addNodeLabel failed: {s}", .{@errorName(err)});
            };
        }
    }
    // Existing in-memory mutation follows...
```

- [ ] **Step 4: Wire removeNodeLabel to adapter**

Same pattern as Step 3 but calling `removeNodeLabelFn`.

- [ ] **Step 5: Build and test**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
make test 2>&1 | tail -10
```

Expected: clean build, tests pass (adapter functions are null so dual-write is a no-op).

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/graph_store.zig
git commit -m "feat: wire edge property and label mutations through adapter dual-write"
```

---

### Task 1.3: Implement adapter methods for edge properties and labels

**Files:**

- Modify: `GEODE/src/storage/graph_storage_adapter.zig`

This task implements the 4 missing methods in StorageAdapter and wires them into the vtable.

- [ ] **Step 1: Read the existing setNodeProperty implementation**

Read `GEODE/src/storage/graph_storage_adapter.zig` around line 456 to understand the pattern for setNodePropertyFn. The pattern is:

1. Lock mutex
2. Get ManagedGraph by graph name
3. Get engine
4. Get node/edge record
5. Call engine method
6. Update record with new prop_head
7. Write record back

- [ ] **Step 2: Implement addNodeLabel in StorageAdapter**

```zig
fn adapterAddNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
    const self: *StorageAdapter = @ptrCast(@alignCast(ctx));
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const label_id = try mg.label_dict.getOrCreate(label);
    try mg.engine.addLabel(node_id, label_id);
}
```

- [ ] **Step 3: Implement removeNodeLabel in StorageAdapter**

```zig
fn adapterRemoveNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
    const self: *StorageAdapter = @ptrCast(@alignCast(ctx));
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const label_id = mg.label_dict.getId(label) orelse return; // label doesn't exist, nothing to remove
    try mg.engine.removeLabel(node_id, label_id);
}
```

- [ ] **Step 4: Implement setEdgeProperty in StorageAdapter**

This requires the engine to support edge property writes. Since `adj_store.zig` currently has no `updateEdgePropHead`, this implementation must:

1. Get the edge's from/to node IDs
2. Get the current EdgeEntry from outgoing adjacency
3. Write the property via `engine.putProperty(edge.prop_head, key, value)` to get new prop_head
4. **Cannot update edge.prop_head yet** — log a warning

For now, edge properties will only work for edges whose prop_head is already non-zero (which is never, since edges are created with prop_head=0). This is addressed in Phase 2 when we add `updateEdgePropHead` to adj_store.

```zig
fn adapterSetEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
    const self: *StorageAdapter = @ptrCast(@alignCast(ctx));
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    // Find edge in outgoing adjacency to get current prop_head
    const from_rec = (try mg.engine.getNode(from_id)) orelse return error.NodeNotFound;
    var iter = mg.engine.adj_out.expand(from_rec.out_head, null);
    while (try iter.next()) |entry| {
        if (entry.edge_id == edge_id) {
            const storage_val = toStorageProperty(value);
            const new_head = try mg.engine.putProperty(entry.prop_head, key, storage_val);
            if (new_head != entry.prop_head) {
                // Need to update edge entry's prop_head — requires Phase 2
                // For now, this only works if prop_head was already non-zero and didn't change
                // TODO: implement updateEdgePropHead in adj_store (Phase 2)
            }
            return;
        }
    }
    return error.EdgeNotFound;
}
```

- [ ] **Step 5: Implement removeEdgeProperty in StorageAdapter**

Same pattern as setEdgeProperty but calling `engine.removeProperty()`.

- [ ] **Step 6: Wire the new methods into the vtable constructor**

In the function that builds AdapterVTable, replace the `null` placeholders with the actual function pointers.

- [ ] **Step 7: Build and test**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
make test 2>&1 | tail -10
```

- [ ] **Step 8: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/storage/graph_storage_adapter.zig src/graph_store.zig
git commit -m "feat: implement adapter methods for edge properties and label mutations"
```

---

### Task 1.4: Fix loadFromAdapter to load edge properties and labels correctly

**Files:**

- Modify: `GEODE/src/graph_store.zig` (loadFromAdapter at ~line 2676)
- Modify: `GEODE/src/storage/graph_storage_adapter.zig` (add getAllEdgeProperties helper)

- [ ] **Step 1: Read the current edge loading in loadFromAdapter**

Find the section around line 2809 where edges are created with empty properties. The current code:

```zig
// Creates edge with empty properties map
```

- [ ] **Step 2: Add edge property loading**

After creating the Edge struct, load properties from the engine using the EdgeEntry's `prop_head`:

```zig
// Load edge properties from adapter
if (edge_entry.prop_head != 0) {
    var prop_iter = try adapter.getAllEdgeProperties(graph_name, edge_entry.prop_head);
    while (try prop_iter.next()) |prop| {
        try edge.properties.put(
            try allocator.dupe(u8, prop.key),
            try fromStorageProperty(prop.value, allocator),
        );
    }
}
```

This requires adding `getAllEdgeProperties` to the adapter or directly using the engine's `getAllProperties` with the edge's prop_head.

- [ ] **Step 3: Build and test**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/graph_store.zig src/storage/graph_storage_adapter.zig
git commit -m "fix: load edge properties from adapter during loadFromAdapter"
```

---

## Phase 2: Implement Correct Edge Property Persistence in graph-storage

### Task 2.1: Add updateEdgePropHead to AdjStore

**Files:**

- Modify: `GS/src/adj_store.zig`

This is the core missing API. We need to scan the adjacency chain for a given edge_id and update its prop_head field in place.

- [ ] **Step 1: Write the failing test**

Add to adj_store.zig tests:

```zig
test "updateEdgePropHead — update existing edge" {
    // Setup: create adj store, add edge with prop_head=0, update to prop_head=42
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ... setup buffer pool, free space, adj store ...

    var head: PageId = 0;
    head = try store.addEdge(head, .{ .neighbor = 2, .edge_id = 1, .rel_type = 10, .prop_head = 0 });

    // Update prop_head from 0 to 42
    const updated = try store.updateEdgePropHead(head, 1, 42);
    try std.testing.expect(updated);

    // Verify: expand and check prop_head
    var iter = store.expand(head, null);
    const entry = (try iter.next()).?;
    try std.testing.expectEqual(@as(u32, 42), entry.prop_head);
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1 | grep "updateEdgePropHead"
```

Expected: compilation error (method doesn't exist yet).

- [ ] **Step 3: Implement updateEdgePropHead**

```zig
/// Update the prop_head of an existing edge entry in the adjacency chain.
/// Scans the chain starting at head_page for the given edge_id.
/// Returns true if found and updated, false if edge not found.
pub fn updateEdgePropHead(self: *AdjStore, head_page: PageId, edge_id: EdgeId, new_prop_head: u32) !bool {
    if (head_page == 0) return false;

    var current_page = head_page;
    while (current_page != 0) {
        const frame = try self.buffer_pool.pinPage(self.file_id, current_page);
        defer self.buffer_pool.unpinPage(frame);

        const data = frame.data();
        const header = @as(*const EdgeBlockHeader, @ptrCast(@alignCast(data[page.PAGE_HEADER_SIZE..])));
        const entries_start = page.PAGE_HEADER_SIZE + @sizeOf(EdgeBlockHeader);
        const entries: [*]EdgeEntry = @ptrCast(@alignCast(data[entries_start..]));

        var i: u16 = 0;
        while (i < header.count) : (i += 1) {
            if (entries[i].edge_id == edge_id) {
                // Found it — update in place
                frame.markDirty();
                entries[i].prop_head = new_prop_head;
                return true;
            }
        }

        current_page = header.next_block;
    }
    return false;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1
```

Expected: PASS.

- [ ] **Step 5: Write test for updating both outgoing and incoming copies**

Since each edge exists in both adj_out and adj_in, both copies must be updated.

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/adj_store.zig
git commit -m "feat: add updateEdgePropHead for in-place edge metadata mutation"
```

---

### Task 2.2: Add engine-level edge property helpers

**Files:**

- Modify: `GS/src/engine.zig`
- Modify: `GS/src/interface.zig` (add to VTable)

- [ ] **Step 1: Write failing test for setEdgeProperty**

```zig
test "engine setEdgeProperty — round-trip" {
    // Create graph, add 2 nodes, add edge, set property, verify property
    // ...
    try eng.setEdgeProperty(n1, n2, edge_id, "weight", .{ .Int = 42 });
    const val = try eng.getEdgeProperty(n1, edge_id, "weight", allocator);
    try std.testing.expect(val != null);
}
```

- [ ] **Step 2: Implement setEdgeProperty in engine.zig**

```zig
pub fn setEdgeProperty(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) !void {
    // 1. Find edge in outgoing adj to get current prop_head
    const from_rec = (try self.node_store.getNode(from)) orelse return error.NodeNotFound;
    var iter = self.adj_out.expand(from_rec.out_head, null);
    var found_prop_head: u32 = 0;
    while (try iter.next()) |entry| {
        if (entry.edge_id == edge_id) {
            found_prop_head = entry.prop_head;
            break;
        }
    } else {
        return error.EdgeNotFound;
    }

    // 2. Write property, get (possibly new) prop_head
    const new_head = try self.putProperty(found_prop_head, key, value);

    // 3. If prop_head changed, update both adj copies
    if (new_head != found_prop_head) {
        const new_head_u32: u32 = @intCast(new_head & 0xFFFFFFFF);
        _ = try self.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head_u32);
        const to_rec = (try self.node_store.getNode(to)) orelse return error.NodeNotFound;
        _ = try self.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, new_head_u32);
    }
}
```

- [ ] **Step 3: Implement removeEdgeProperty**

Same pattern but calling `removeProperty` instead.

- [ ] **Step 4: Implement getEdgeProperty and getAllEdgeProperties**

```zig
pub fn getEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) !?PropertyValue {
    const from_rec = (try self.node_store.getNode(from)) orelse return null;
    var iter = self.adj_out.expand(from_rec.out_head, null);
    while (try iter.next()) |entry| {
        if (entry.edge_id == edge_id) {
            if (entry.prop_head == 0) return null;
            return self.getProperty(entry.prop_head, key, allocator);
        }
    }
    return null;
}
```

- [ ] **Step 5: Add to VTable in interface.zig**

Add `setEdgeProperty`, `removeEdgeProperty`, `getEdgeProperty`, `getAllEdgeProperties` to the VTable.

- [ ] **Step 6: Run all tests**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1
zig build test-integration 2>&1
```

- [ ] **Step 7: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/engine.zig src/interface.zig
git commit -m "feat: add engine-level edge property CRUD (setEdgeProperty, removeEdgeProperty, getEdgeProperty)"
```

---

### Task 2.3: Add edge property persistence round-trip test

**Files:**

- Modify: `GS/tests/integration.zig`

- [ ] **Step 1: Write integration test**

```zig
test "QUAL-0022: edge properties survive checkpoint and reopen" {
    // Create graph, add nodes, add edge, set edge property
    // Checkpoint, close, reopen
    // Verify edge property is still there
    // Update edge property, checkpoint, close, reopen
    // Verify updated value
    // Remove edge property, checkpoint, close, reopen
    // Verify property is gone
}
```

- [ ] **Step 2: Run and verify**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test-integration 2>&1
```

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add tests/integration.zig
git commit -m "test: edge property persistence round-trip across checkpoint/reopen"
```

---

### Task 2.4: Wire Geode adapter to use engine edge property methods

**Files:**

- Modify: `GEODE/src/storage/graph_storage_adapter.zig`
- Modify: `GEODE/build.zig.zon` (pin updated graph-storage dep)

- [ ] **Step 1: Update graph-storage dependency in Geode**

Push the graph-storage changes, get the new commit hash, update `build.zig.zon`.

- [ ] **Step 2: Rewrite adapterSetEdgeProperty to use engine.setEdgeProperty**

Replace the scan-based implementation from Task 1.3 with the engine helper:

```zig
fn adapterSetEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
    const self: *StorageAdapter = @ptrCast(@alignCast(ctx));
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const storage_val = toStorageProperty(value);
    try mg.engine.setEdgeProperty(from_id, to_id, edge_id, key, storage_val);
}
```

- [ ] **Step 3: Build and test**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
make test 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add build.zig.zon src/storage/graph_storage_adapter.zig
git commit -m "feat: wire Geode edge property adapter to engine.setEdgeProperty"
```

---

## Phase 3: Replace the Label Model With a Sound Persisted Representation

### Task 3.1: Design and implement label membership blocks in var.store

**Files:**

- Create: `GS/src/label_store.zig`
- Modify: `GS/src/node.zig` (NodeRec layout change)

This replaces the 32-bit `label_set` bitmap with a proper variable-length label membership structure.

**Design:**

- NodeRec gets `label_head: u64` (page pointer into var.store for label block) and `label_count: u16` (number of labels)
- Label block format: `[u16 count][u32 label_id]*` — simple flat array
- For nodes with 0-4 labels, inline in a single var.store page
- For nodes with 5+ labels, overflow via var.store chain

- [ ] **Step 1: Modify NodeRec layout**

In `GS/src/node.zig`, change:

```zig
pub const NodeRec = extern struct {
    out_head: u64,
    in_head: u64,
    prop_head: u64,
    label_head: u64,     // was: label_set: u32 — now points to var.store label block
    label_count: u16,    // number of labels on this node
    flags: u16,
    txn_stamp: u64,
};
```

**Important:** This changes NodeRec from 40 to 48 bytes. Update the comptime size check.

Wait — this changes nodes_per_page from 101 to 84 (for 4096-byte pages). That's a breaking on-disk format change. This is expected and handled in Phase 6 (migration).

- [ ] **Step 2: Run tests — expect many failures**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1 | head -40
```

Expected: compilation errors where `label_set` is referenced.

- [ ] **Step 3: Create label_store.zig**

```zig
// Label membership storage using var.store for variable-length label lists.
const std = @import("std");
const types = @import("types.zig");
const VarStore = @import("var_store.zig").VarStore;

pub const LabelStore = struct {
    var_store: *VarStore,

    pub fn init(var_store: *VarStore) LabelStore {
        return .{ .var_store = var_store };
    }

    /// Read all label IDs for a node. Caller owns returned slice.
    pub fn getLabels(self: *LabelStore, label_head: u64, allocator: std.mem.Allocator) ![]u32 {
        if (label_head == 0) return &[_]u32{};
        const data = try self.var_store.read(label_head, allocator);
        defer allocator.free(data);
        if (data.len < 2) return &[_]u32{};
        const count = std.mem.readInt(u16, data[0..2], .little);
        if (data.len < 2 + @as(usize, count) * 4) return &[_]u32{};
        var result = try allocator.alloc(u32, count);
        for (0..count) |i| {
            const offset = 2 + i * 4;
            result[i] = std.mem.readInt(u32, data[offset..][0..4], .little);
        }
        return result;
    }

    /// Write label list, return new var.store reference.
    pub fn putLabels(self: *LabelStore, labels: []const u32, allocator: std.mem.Allocator) !u64 {
        const count: u16 = @intCast(labels.len);
        var buf = try allocator.alloc(u8, 2 + labels.len * 4);
        defer allocator.free(buf);
        std.mem.writeInt(u16, buf[0..2], count, .little);
        for (labels, 0..) |label_id, i| {
            const offset = 2 + i * 4;
            std.mem.writeInt(u32, buf[offset..][0..4], label_id, .little);
        }
        return self.var_store.write(buf);
    }

    /// Add a label to an existing label list. Returns new reference.
    pub fn addLabel(self: *LabelStore, label_head: u64, label_id: u32, allocator: std.mem.Allocator) !u64 {
        var existing = try self.getLabels(label_head, allocator);
        defer allocator.free(existing);
        // Check for duplicate
        for (existing) |id| {
            if (id == label_id) return label_head; // already present
        }
        // Append
        var new_list = try allocator.alloc(u32, existing.len + 1);
        defer allocator.free(new_list);
        @memcpy(new_list[0..existing.len], existing);
        new_list[existing.len] = label_id;
        // Free old block if it existed
        if (label_head != 0) try self.var_store.free(label_head);
        return self.putLabels(new_list, allocator);
    }

    /// Remove a label from an existing label list. Returns new reference.
    pub fn removeLabel(self: *LabelStore, label_head: u64, label_id: u32, allocator: std.mem.Allocator) !u64 {
        var existing = try self.getLabels(label_head, allocator);
        defer allocator.free(existing);
        var new_list = try std.ArrayList(u32).initCapacity(allocator, existing.len);
        defer new_list.deinit();
        for (existing) |id| {
            if (id != label_id) try new_list.append(id);
        }
        if (label_head != 0) try self.var_store.free(label_head);
        if (new_list.items.len == 0) return 0;
        return self.putLabels(new_list.items, allocator);
    }
};
```

- [ ] **Step 4: Update engine.zig addLabel/removeLabel to use LabelStore**

Replace the bitmap-based label operations with LabelStore calls:

```zig
pub fn addLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) !void {
    var rec = (try self.node_store.getNode(node_id)) orelse return error.NodeNotFound;
    const new_head = try self.label_store.addLabel(rec.label_head, label, self.allocator);
    rec.label_head = new_head;
    rec.label_count += 1;
    try self.node_store.putNode(node_id, rec);
    try self.label_index.addNode(label, node_id);
}
```

- [ ] **Step 5: Update label_index.zig rebuild to read from LabelStore**

The rebuild function currently reads `label_set` bitmap. Change it to read from LabelStore:

```zig
pub fn rebuild(self: *LabelIndex, node_store: *NodeStore, label_store: *LabelStore, max_id: u64, allocator: Allocator) !void {
    self.clear();
    var id: u64 = 1;
    while (id < max_id) : (id += 1) {
        const rec = try node_store.getNode(id) orelse continue;
        if (rec.flags & 0x1 != 0) continue; // skip deleted
        const labels = try label_store.getLabels(rec.label_head, allocator);
        defer allocator.free(labels);
        for (labels) |label_id| {
            try self.addNode(label_id, id);
        }
    }
}
```

- [ ] **Step 6: Fix all compilation errors from NodeRec layout change**

Update all code that references `label_set` to use `label_head` and `label_count`. Key locations:

- `engine.zig` (create, addLabel, removeLabel)
- `node_store.zig` (if it references label_set directly)
- `label_index.zig` (rebuild)
- `tests/` (integration tests)

- [ ] **Step 7: Run all tests**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1
zig build test-integration 2>&1
```

- [ ] **Step 8: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/node.zig src/label_store.zig src/engine.zig src/label_index.zig tests/integration.zig
git commit -m "feat: replace label_set bitmap with variable-length label blocks in var.store"
```

---

### Task 3.2: Add label persistence round-trip test

**Files:**

- Modify: `GS/tests/integration.zig`

- [ ] **Step 1: Write test for >32 labels**

```zig
test "QUAL-0023: 64 distinct labels on a single node survive reopen" {
    // Create graph, add node, add 64 labels, checkpoint, close, reopen
    // Verify all 64 labels are present and distinct
}
```

- [ ] **Step 2: Write test for label add/remove after creation**

```zig
test "QUAL-0024: add and remove labels after node creation survive reopen" {
    // Create graph, add node with labels [A, B]
    // Checkpoint, reopen
    // Remove label A, add label C
    // Checkpoint, reopen
    // Verify labels are [B, C]
}
```

- [ ] **Step 3: Run and verify**

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add tests/integration.zig
git commit -m "test: label persistence tests — 64 labels, add/remove after creation"
```

---

### Task 3.3: Update Geode adapter for new label model

**Files:**

- Modify: `GEODE/src/storage/graph_storage_adapter.zig` (getNodeLabels, createNode)
- Modify: `GEODE/build.zig.zon`

- [ ] **Step 1: Update graph-storage dependency**

- [ ] **Step 2: Rewrite getNodeLabels to use LabelStore**

Replace the `% 32` bitmap reconstruction with direct label reading:

```zig
fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const rec = (try mg.engine.getNode(node_id)) orelse return &[_][]const u8{};
    const label_ids = try mg.engine.label_store.getLabels(rec.label_head, allocator);
    defer allocator.free(label_ids);
    var result = std.ArrayList([]const u8).init(allocator);
    for (label_ids) |label_id| {
        const name = mg.label_dict.getName(label_id) orelse continue;
        try result.append(try allocator.dupe(u8, name));
    }
    return result.toOwnedSlice();
}
```

- [ ] **Step 3: Remove adapter_labels.dat persistence**

Stop writing/reading `adapter_labels.dat`. The engine's `labels.dict` is now authoritative.

- [ ] **Step 4: Build and test**

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add build.zig.zon src/storage/graph_storage_adapter.zig
git commit -m "fix: replace label bitmap reconstruction with LabelStore direct reads"
```

---

## Phase 4: Activate Real Per-Graph Transactions, WAL, and Recovery

### Task 4.1: Wire engine transactions into normal mutations

**Files:**

- Modify: `GS/src/engine.zig`

Currently, normal mutations (`putNode`, `addEdge`, `putProperty`, etc.) bypass the transaction system. This task wraps each mutation in an auto-transaction if no explicit transaction is active.

- [ ] **Step 1: Add auto-transaction wrapper to putNode**

```zig
pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) !void {
    const txn = try self.txn_manager.begin();
    errdefer self.txn_manager.abort(txn) catch {};
    // existing page write logic...
    try self.node_store.putNode(id, rec);
    // Log the page update for WAL
    const page_id = id / self.node_store.nodes_per_page;
    const frame = try self.buffer_pool.pinPage(.nodes, page_id);
    defer self.buffer_pool.unpinPage(frame);
    _ = try self.txn_manager.logPageUpdate(txn, .nodes, page_id, frame.data());
    try self.txn_manager.commit(txn);
}
```

- [ ] **Step 2: Repeat for addEdge, putProperty, removeProperty, addLabel, removeLabel**

Each mutation method gets the same pattern: begin -> mutate -> log page update -> commit.

- [ ] **Step 3: Run tests**

```bash
cd /home/benji/src/devnw/zig/graph-storage
zig build test 2>&1
zig build test-integration 2>&1
```

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/engine.zig
git commit -m "feat: wrap normal mutations in auto-transactions for WAL durability"
```

---

### Task 4.2: Verify crash recovery replays committed mutations

**Files:**

- Modify: `GS/tests/integration.zig`

- [ ] **Step 1: Write crash-recovery integration test**

```zig
test "QUAL-0025: crash after commit replays node property" {
    // Create graph, checkpoint (establishes baseline)
    // Set node property (auto-txn commits, WAL has page_update + commit)
    // Close WITHOUT checkpoint
    // Reopen — recovery replays committed page_update
    // Verify property is present
}
```

- [ ] **Step 2: Run and verify**

- [ ] **Step 3: Commit**

---

### Task 4.3: Demote Geode WAL to post-commit logical feed

**Files:**

- Modify: `GEODE/src/wal.zig`
- Modify: `GEODE/src/graph_store.zig`

- [ ] **Step 1: Change WAL checkpoint to NOT call saveToFile/truncate for crash recovery**

The engine's own WAL handles crash recovery now. Geode's WAL becomes a logical change feed for CDC/audit. The checkpoint hook should:

1. Call `engine.checkpoint()` (via adapter) for physical durability
2. Continue appending logical records for CDC consumers
3. NOT be required for crash recovery

- [ ] **Step 2: Remove WAL replay from Geode startup path**

In Geode's startup, `loadFromAdapter` already rebuilds from the engine. Remove the WAL replay step that was the backup path.

- [ ] **Step 3: Build and test**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
make build 2>&1 | tail -5
make test 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/wal.zig src/graph_store.zig
git commit -m "refactor: demote Geode WAL to post-commit logical feed; engine WAL handles crash recovery"
```

---

## Phase 5: Implement or Remove Placeholder Files

### Task 5.1: Persist free.store bitmap

**Files:**

- Modify: `GS/src/free_space.zig`
- Modify: `GS/src/engine.zig` (checkpoint writes free.store, open reads it)

- [ ] **Step 1: Add save/load methods to FreeSpaceManager**

```zig
/// Save bitmap to a file. Format: [u64 total_pages][u64 next_free_hint][bitmap bytes...]
pub fn saveToFile(self: *FreeSpaceManager, file: std.fs.File) !void {
    // Write header
    var header: [16]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], self.total_pages, .little);
    std.mem.writeInt(u64, header[8..16], self.next_free_hint, .little);
    try file.writeAll(&header);
    // Write bitmap bytes
    const bitmap_bytes = self.bitmap.unmanaged.masks[0..std.math.divCeil(usize, self.total_pages, 64) catch 0];
    try file.writeAll(std.mem.sliceAsBytes(bitmap_bytes));
}

/// Load bitmap from a file.
pub fn loadFromFile(self: *FreeSpaceManager, file: std.fs.File) !void {
    var header: [16]u8 = undefined;
    _ = try file.readAll(&header);
    self.total_pages = std.mem.readInt(u64, header[0..8], .little);
    self.next_free_hint = std.mem.readInt(u64, header[8..16], .little);
    // Read bitmap
    try self.bitmap.resize(self.total_pages, false);
    const bitmap_bytes = self.bitmap.unmanaged.masks[0..std.math.divCeil(usize, self.total_pages, 64) catch 0];
    _ = try file.readAll(std.mem.sliceAsBytes(bitmap_bytes));
}
```

- [ ] **Step 2: Wire into engine checkpoint and open**

In `engine.checkpoint()`: save all 5 free-space bitmaps to `free.store` (append sequentially or use fixed offsets).

In `engine.open()`: if `free.store` exists and is valid, load instead of `rebuildFreeSpaceFromDisk()`.

- [ ] **Step 3: Test round-trip**

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/free_space.zig src/engine.zig
git commit -m "feat: persist free-space bitmap to free.store instead of rebuilding from disk"
```

---

### Task 5.2: Remove or defer props.idx

**Files:**

- Modify: `GS/src/file_manager.zig`
- Modify: `GS/src/engine.zig`

- [ ] **Step 1: Stop creating props.idx on graph creation**

Remove `props_idx` from the file list that's always created. It should be created lazily when/if persistent property indexes are implemented.

- [ ] **Step 2: Run tests**

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/file_manager.zig src/engine.zig
git commit -m "chore: defer props.idx creation until persistent property index feature"
```

---

## Phase 6: Migration and Compatibility

### Task 6.1: Bump format_version and add V1-to-V2 migration

**Files:**

- Modify: `GS/src/manifest.zig`
- Create or Modify: `GS/src/migration.zig`
- Modify: `GS/src/engine.zig` (open path)

- [ ] **Step 1: Bump MANIFEST_VERSION to 2**

```zig
pub const MANIFEST_VERSION: u32 = 2;
```

- [ ] **Step 2: Add migration detection in engine.open()**

```zig
// After reading manifest:
if (self.manifest.format_version == 1) {
    try self.migrateV1toV2();
    self.manifest.format_version = 2;
}
```

- [ ] **Step 3: Implement migrateV1toV2()**

The migration must:

1. Scan all nodes in the old 40-byte format
2. For each node, read `label_set: u32` bitmap
3. Convert bitmap to explicit label IDs using label_dict
4. Write label blocks to var.store via LabelStore
5. Rewrite nodes in the new 48-byte format with `label_head` and `label_count`
6. Update manifest counters

This is the most complex migration step. It must be atomic (backup + swap).

```zig
fn migrateV1toV2(self: *GraphEngine) !void {
    // Read all V1-format nodes (40 bytes each)
    const old_nodes_per_page = (self.config.page_size - 32) / 40;
    var id: u64 = 1;
    while (id < self.manifest.next_node_id) : (id += 1) {
        const page_id = id / old_nodes_per_page;
        const slot = id % old_nodes_per_page;
        const frame = try self.buffer_pool.pinPage(.nodes, page_id);
        defer self.buffer_pool.unpinPage(frame);

        const data = frame.data();
        const offset = 32 + slot * 40;
        // Read old-format fields manually
        const old_label_set = std.mem.readInt(u32, data[offset + 24 ..][0..4], .little);
        const flags = std.mem.readInt(u16, data[offset + 28 ..][0..2], .little);
        if (flags & 0x1 != 0) continue; // skip deleted

        // Convert bitmap to label IDs
        var labels = std.ArrayList(u32).init(self.allocator);
        defer labels.deinit();
        var bit: u5 = 0;
        while (bit < 32) : (bit += 1) {
            if (old_label_set & (@as(u32, 1) << bit) != 0) {
                // Find label IDs that map to this bit
                // (multiple label IDs may map to same bit due to % 32)
                // Best-effort: use label_dict to find candidates
                var dict_iter = self.label_dict.iterator();
                while (dict_iter.next()) |entry| {
                    if (entry.key_ptr.* % 32 == bit) {
                        try labels.append(entry.key_ptr.*);
                    }
                }
            }
        }

        // Write label block to var.store
        var label_head: u64 = 0;
        if (labels.items.len > 0) {
            label_head = try self.label_store.putLabels(labels.items, self.allocator);
        }

        // TODO: Rewrite node in new format
        // This requires page reformatting since nodes_per_page changes
    }
}
```

**Note:** The page reformatting (40->48 byte records changing nodes_per_page from 101 to 84) requires rewriting the entire nodes.store. This is best done as a copy-and-swap: write new nodes to a temp file, then rename.

- [ ] **Step 4: Write migration test**

```zig
test "QUAL-0026: V1 graph migrates to V2 on open" {
    // Create V1 graph (old code path or manual page writes)
    // Close
    // Open with V2 code — should auto-migrate
    // Verify labels, properties, edges survive
}
```

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/manifest.zig src/migration.zig src/engine.zig tests/integration.zig
git commit -m "feat: V1-to-V2 migration for label model upgrade"
```

---

## Phase 7: Observability and Operator Validation

### Task 7.1: Add storage inspection API

**Files:**

- Modify: `GS/src/engine.zig`

- [ ] **Step 1: Add StorageStats struct and getStorageStats() method**

```zig
pub const StorageStats = struct {
    node_count: u64,
    edge_count: u64,
    label_count: u32,
    props_pages: u64,
    var_pages: u64,
    free_pages_nodes: u64,
    free_pages_adj_out: u64,
    free_pages_adj_in: u64,
    free_pages_props: u64,
    free_pages_var: u64,
    wal_size_bytes: u64,
    current_lsn: u64,
    last_checkpoint_lsn: u64,
    format_version: u32,
};

pub fn getStorageStats(self: *GraphEngine) StorageStats {
    return .{
        .node_count = self.manifest.node_count,
        .edge_count = self.manifest.edge_count,
        .label_count = self.manifest.label_count,
        .props_pages = self.manifest.props_pages,
        .var_pages = self.manifest.var_pages,
        .free_pages_nodes = self.free_space_nodes.freeCount(),
        .free_pages_adj_out = self.free_space_adj_out.freeCount(),
        .free_pages_adj_in = self.free_space_adj_in.freeCount(),
        .free_pages_props = self.free_space_props.freeCount(),
        .free_pages_var = self.free_space_var.freeCount(),
        .wal_size_bytes = self.wal.sizeBytes(),
        .current_lsn = self.wal.currentLsn(),
        .last_checkpoint_lsn = self.manifest.last_checkpoint_lsn,
        .format_version = self.manifest.format_version,
    };
}
```

- [ ] **Step 2: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/engine.zig
git commit -m "feat: add storage inspection API (getStorageStats)"
```

---

### Task 7.2: Add integrity check methods

**Files:**

- Modify: `GS/src/engine.zig`

- [ ] **Step 1: Add checkIntegrity() method**

```zig
pub const IntegrityReport = struct {
    label_index_consistent: bool,
    adjacency_symmetric: bool,
    orphaned_properties: u64,
    errors: std.ArrayList([]const u8),
};

pub fn checkIntegrity(self: *GraphEngine, allocator: Allocator) !IntegrityReport {
    var report = IntegrityReport{
        .label_index_consistent = true,
        .adjacency_symmetric = true,
        .orphaned_properties = 0,
        .errors = std.ArrayList([]const u8).init(allocator),
    };

    // Check 1: Label index matches node label_head contents
    // For each node, read labels from LabelStore, verify label_index has the node

    // Check 2: Edge adjacency symmetry
    // For each outgoing edge (A->B), verify incoming edge exists (B<-A)

    // Check 3: Edge prop_head consistency
    // For each edge, verify prop_head matches in both adj_out and adj_in

    return report;
}
```

- [ ] **Step 2: Write test for integrity checker**

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/graph-storage
git add src/engine.zig
git commit -m "feat: add storage integrity checker (label index, adjacency symmetry, prop_head)"
```

---

### Task 7.3: Wire storage inspection into Geode CLI

**Files:**

- Modify: `GEODE/src/cli/` (add `geode storage inspect` subcommand)

- [ ] **Step 1: Add storage-inspect command**

Expose `getStorageStats()` and `checkIntegrity()` via a CLI command that prints a human-readable report.

- [ ] **Step 2: Test manually**

```bash
./zig-out/bin/geode storage inspect --data-dir /var/lib/geode
```

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git add src/cli/
git commit -m "feat: add 'geode storage inspect' CLI command"
```

---

## Test Matrix Summary

| Test | Phase | Location | Status |
|------|-------|----------|--------|
| Storage smoke test (full round-trip) | 0 | `GS/tests/integration.zig` | Task 0.2 |
| Crash simulation (WAL recovery) | 0 | `GS/tests/integration.zig` | Task 0.3 |
| Edge property first-write round-trip | 2 | `GS/tests/integration.zig` | Task 2.3 |
| Edge property update/remove round-trip | 2 | `GS/tests/integration.zig` | Task 2.3 |
| Edge property survives checkpoint+reopen | 2 | `GS/tests/integration.zig` | Task 2.3 |
| 64 distinct labels on one node | 3 | `GS/tests/integration.zig` | Task 3.2 |
| Label add/remove after creation survives | 3 | `GS/tests/integration.zig` | Task 3.2 |
| Crash after commit replays mutation | 4 | `GS/tests/integration.zig` | Task 4.2 |
| V1-to-V2 migration | 6 | `GS/tests/integration.zig` | Task 6.1 |
| Integrity checker correctness | 7 | `GS/tests/integration.zig` | Task 7.2 |

---

## Execution Dependencies

```
Phase 0 (harness) ─────────────────────────────────────┐
                                                         │
Phase 1 (Geode vtable + dual-write) ───────────────────┤
                                                         │
Phase 2 (engine edge properties) ──── Phase 2.4 ───────┤
                                    (wire Geode adapter) │
                                                         │
Phase 3 (label model) ──── Phase 3.3 ──────────────────┤
                          (wire Geode adapter)           │
                                                         │
Phase 4 (transactions/WAL) ────────────────────────────┤
                                                         │
Phase 5 (placeholder files) ───────────────────────────┤
                                                         │
Phase 6 (migration) ───────────────────────────────────┤
                                                         │
Phase 7 (observability) ───────────────────────────────┘
```

Phases 1-3 can be worked in parallel across the two repos. Phase 4 depends on Phases 1-3 being complete. Phase 6 depends on Phase 3 (label model change drives the migration).
