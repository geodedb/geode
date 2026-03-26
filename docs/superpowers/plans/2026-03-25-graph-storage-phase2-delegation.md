# Graph Storage Phase 2: Strangler Fig Delegation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modify `GraphStore` methods to delegate to the `StorageAdapter` (from Phase 1) when it's initialized, keeping the old HashMap implementation as fallback.

**Architecture:** The strangler fig pattern: each `GraphStore` method gets an `if (global_adapter) |adapter|` check at the top. When the adapter is present, it handles the operation. When null, the existing code runs unchanged. This means zero changes to the 86+ consumer files — they keep calling the same `GraphStore` methods. We modify one method at a time, test after each, and can roll back any individual method independently.

**Tech Stack:** Zig 0.15.1, `graph-storage` library, existing `StorageAdapter` at `src/storage/graph_storage_adapter.zig`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/graph_store.zig` | Add adapter delegation to 16 methods |
| Modify | `src/storage/graph_storage_adapter.zig` | Add geode-compatible helper methods for type conversion |

---

### Task 1: Delegate Graph Management Methods

**Files:**

- Modify: `src/graph_store.zig:670` (graphExists), `src/graph_store.zig:685` (createGraph), `src/graph_store.zig:736` (dropGraph)

These three methods have the simplest signatures — they don't return complex types.

- [ ] **Step 1: Add adapter delegation to graphExists**

At line 670 of `src/graph_store.zig`, insert the adapter check at the TOP of the method body:

```zig
pub fn graphExists(self: *const GraphStore, graph_name: []const u8) bool {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        return adapter.graphExists(graph_name);
    }
    // Fallback: old HashMap implementation
    return self.graphs.contains(graph_name);
}
```

- [ ] **Step 2: Add adapter delegation to createGraph**

At line 685 of `src/graph_store.zig`, insert at the TOP of createGraph:

```zig
pub fn createGraph(self: *GraphStore, graph_name: []const u8) !void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        _ = try adapter.getOrCreateGraph(graph_name);
        // Also update local registry for backward compatibility during transition
        if (!self.graphs.contains(graph_name)) {
            const name_copy = try self.allocator.dupe(u8, graph_name);
            try self.graphs.put(name_copy, {});
        }
        return;
    }
    // Fallback: old HashMap implementation
    if (self.graphs.contains(graph_name)) {
        return error.GraphAlreadyExists;
    }
    // ... rest of existing code ...
```

Note: We also add to the local `graphs` registry for backward compat — other code checks `self.graphs.contains()` directly.

- [ ] **Step 3: Add adapter delegation to dropGraph**

At line 736 of `src/graph_store.zig`, insert at the TOP of dropGraph:

```zig
pub fn dropGraph(self: *GraphStore, graph_name: []const u8) !void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        try adapter.dropGraph(graph_name);
        // Also remove from local registry for backward compatibility
        if (self.graphs.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
        }
        return;
    }
    // Fallback: old implementation
    if (std.mem.eql(u8, graph_name, "default")) {
        return error.CannotDropDefaultGraph;
    }
    // ... rest of existing code ...
```

- [ ] **Step 4: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 5: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat: delegate graph management methods to storage adapter"
```

---

### Task 2: Delegate Node Creation and Deletion

**Files:**

- Modify: `src/graph_store.zig:784` (createNodeWithGraph), `src/graph_store.zig:3669` (deleteNode)

- [ ] **Step 1: Add adapter delegation to createNodeWithGraph**

Insert at the TOP of createNodeWithGraph (line 784). The method returns `!u64` (node ID) which is compatible:

```zig
pub fn createNodeWithGraph(self: *GraphStore, labels: [][]const u8, graph_name: []const u8) !u64 {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        const node_id = try adapter.createNode(graph_name, labels);
        // Also write to local store for read compatibility during transition
        try self.ensureGraph(graph_name);
        const id = node_id;
        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const node = Node{
            .id = id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };
        try self.nodes.put(id, node);
        // Update label index
        for (labels) |label| {
            const composite_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
            const gop = try self.label_index.getOrPut(composite_key);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(u64){};
            } else {
                self.allocator.free(composite_key);
            }
            try gop.value_ptr.append(self.allocator, id);
        }
        self.dirty = true;
        return id;
    }
    // Fallback: old implementation
    try self.ensureGraph(graph_name);
    // ... rest of existing code ...
```

**IMPORTANT:** Read the actual method body to understand the exact patterns for label_index updates, per-graph handle routing, etc. The code above is a guide — match the actual implementation patterns.

- [ ] **Step 2: Add adapter delegation to deleteNode**

Insert at the TOP of deleteNode (line 3669). The return type is `void`:

```zig
pub fn deleteNode(self: *GraphStore, node_id: u64) void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "default";
        adapter.deleteNode(gn, node_id) catch {};
        // Also delete from local store for read compatibility
        self.deleteNodeNoSave(node_id);
        self.dirty = true;
        return;
    }
    // Fallback: old implementation
    // ... existing code ...
```

- [ ] **Step 3: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat: delegate node creation and deletion to storage adapter"
```

---

### Task 3: Delegate Edge Creation and Deletion

**Files:**

- Modify: `src/graph_store.zig:1749` (createEdgeWithGraph), `src/graph_store.zig:3687` (deleteEdge)

- [ ] **Step 1: Add adapter delegation to createEdgeWithGraph**

```zig
pub fn createEdgeWithGraph(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8) !u64 {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        const edge_id = try adapter.createEdge(graph_name, from_id, to_id, edge_type);
        // Also write to local store for read compatibility
        try self.ensureGraph(graph_name);
        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };
        try self.edges.put(edge_id, edge);
        // Update adjacency indexes
        const out_gop = try self.outgoing_edges.getOrPut(from_id);
        if (!out_gop.found_existing) out_gop.value_ptr.* = std.ArrayList(u64){};
        try out_gop.value_ptr.append(self.allocator, edge_id);
        const in_gop = try self.incoming_edges.getOrPut(to_id);
        if (!in_gop.found_existing) in_gop.value_ptr.* = std.ArrayList(u64){};
        try in_gop.value_ptr.append(self.allocator, edge_id);
        self.dirty = true;
        return edge_id;
    }
    // Fallback: old implementation
    try self.ensureGraph(graph_name);
    // ... rest of existing code ...
```

- [ ] **Step 2: Add adapter delegation to deleteEdge**

```zig
pub fn deleteEdge(self: *GraphStore, edge_id: u64) void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        if (self.edges.get(edge_id)) |edge| {
            adapter.deleteEdge(edge.graph_name, edge.from_id, edge.to_id, edge_id) catch {};
        }
        // Also delete from local store
        self.deleteEdgeNoSave(edge_id);
        self.dirty = true;
        return;
    }
    // Fallback: old implementation
    // ... existing code ...
```

- [ ] **Step 3: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat: delegate edge creation and deletion to storage adapter"
```

---

### Task 4: Delegate Property Operations

**Files:**

- Modify: `src/graph_store.zig:1054` (setNodeProperty), `src/graph_store.zig:1135` (removeNodeProperty)

- [ ] **Step 1: Add adapter delegation to setNodeProperty**

```zig
pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "default";
        adapter.setNodeProperty(gn, node_id, key, value) catch {};
    }
    // ALWAYS update local store (for read compatibility)
    // ... existing code continues unchanged ...
```

Note: For setNodeProperty, we delegate to the adapter AND still run the old code. This is dual-write — the adapter gets the durable copy, the local HashMap stays updated for reads. This is simpler than converting the return path.

- [ ] **Step 2: Add adapter delegation to removeNodeProperty**

Same dual-write pattern:

```zig
pub fn removeNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) void {
    // Delegate to new storage adapter when available
    if (global_adapter) |adapter| {
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "default";
        adapter.removeProperty(gn, node_id, key) catch {};
    }
    // ALWAYS update local store (for read compatibility)
    // ... existing code continues unchanged ...
```

Note: The adapter may not have a `removeProperty` method yet. If not, add one in the adapter, or skip this delegation for now.

- [ ] **Step 3: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig src/storage/graph_storage_adapter.zig
git commit -m "feat: delegate property operations to storage adapter (dual-write)"
```

---

### Task 5: Delegate Count Operations

**Files:**

- Modify: `src/graph_store.zig:1262` (getNodeCount), `src/graph_store.zig:1266` (getEdgeCount)

- [ ] **Step 1: Add adapter delegation to getNodeCount and getEdgeCount**

These are simple — just add adapter checks. But since we're dual-writing, counts should match. Use the local HashMap count for now (it's always populated):

```zig
pub fn getNodeCount(self: *GraphStore) usize {
    // During transition, local store is always populated via dual-write
    return self.nodes.count();
}

pub fn getEdgeCount(self: *GraphStore) usize {
    return self.edges.count();
}
```

No change needed for Phase 2 since dual-write keeps the local HashMap in sync. Skip delegation for these.

- [ ] **Step 2: Commit (if any changes)**

```bash
git add src/graph_store.zig
git commit -m "docs: note count methods use local store during dual-write transition"
```

---

### Task 6: Full Build and Regression Verification

- [ ] **Step 1: Run full build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build 2>&1 | tail -10`

- [ ] **Step 2: Run unit tests**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | tail -20`

- [ ] **Step 3: Run geodetestlab regression**

Run: `cd /home/benji/src/devnw/codepros/geode/geode-test-harness && geodetestlab run --spec geodetestlab-cli/specs/dsn_graph_binding.yml 2>&1 | tail -15`

All existing tests must pass — the dual-write pattern ensures backward compatibility.

- [ ] **Step 4: Fix any regressions**

Common issues:

- Missing adapter methods (add them to `graph_storage_adapter.zig`)
- Type mismatches between adapter returns and GraphStore signatures
- Null graph_name when looking up nodes (use "default" fallback)

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "fix: resolve regressions from storage adapter delegation"
```
