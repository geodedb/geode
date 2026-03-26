# Graph Storage Integration Plan — Phase 1: Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace geode's in-memory HashMap-based storage (`graph_store.zig`, `graph_handle.zig`, `graph_registry.zig`) with the new page-based `graph-storage` engine library, providing an adapter that bridges the new engine's API to geode's existing execution engine.

**Architecture:** The new `graph-storage` library uses a page-based storage model with fixed-size node records (40 bytes), adjacency-list edge blocks, a separate property store, and u32 label IDs via a label dictionary. Geode's execution engine expects string labels, inline property HashMaps, and graph-name-tagged nodes/edges. An adapter module (`src/storage/graph_storage_adapter.zig`) bridges these models — it manages one `GraphEngine` instance per named graph, maintains a label string↔LabelId dictionary, and translates between `graph-storage` PropertyValue and geode's PropertyValue. The adapter implements the same public methods as the current `GraphStore` so the 86+ consumer files can migrate incrementally.

**Tech Stack:** Zig 0.15.1, `graph-storage` library (v0.1.0 from `gitlab.com/devnw/zig/graph-storage`)

**Scope:** This is Phase 1 of 3. It delivers the dependency, adapter, and global singleton replacement. Phases 2-3 (execution engine migration, old code removal) are separate plans.

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `build.zig.zon` | Add `graph_storage` dependency |
| Modify | `build.zig` | Wire `graph_storage` module into root_mod and geode_exe |
| Create | `src/storage/graph_storage_adapter.zig` | Adapter bridging `GraphEngine` API to geode's `GraphStore` interface |
| Modify | `src/graph_store.zig` | Replace `getGlobalStore()` internals to return the adapter-backed store |
| Modify | `src/server/server_init.zig` | Initialize adapter with data_dir during server startup |

---

### Task 1: Add `graph-storage` Dependency to Build System

**Files:**

- Modify: `build.zig.zon` (add dependency entry)
- Modify: `build.zig` (wire module into root_mod and geode_exe)

- [ ] **Step 1: Get the dependency hash**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig fetch git+https://gitlab.com/devnw/zig/graph-storage.git#2a9bfaa 2>&1`

This prints the hash needed for `build.zig.zon`. Save the output hash.

If `zig fetch` doesn't work with the short commit, use the full URL:
Run: `cd /home/benji/src/devnw/zig/graph-storage && git rev-parse HEAD`
Then: `zig fetch git+https://gitlab.com/devnw/zig/graph-storage.git#<full-sha>`

- [ ] **Step 2: Add graph_storage to build.zig.zon**

In `build.zig.zon`, add to the `.dependencies` block after the `wal` entry (around line 85, in the "Phase 2: Core Libraries" or a new "Phase 8: Storage" section):

```zig
        // Page-based graph storage engine
        .graph_storage = .{
            .url = "git+https://gitlab.com/devnw/zig/graph-storage.git#<full-commit-sha>",
            .hash = "<hash-from-zig-fetch>",
        },
```

- [ ] **Step 3: Wire the module in build.zig**

In `build.zig`, after the existing dependency resolutions (around line 321), add:

```zig
    const graph_storage_dep = b.dependency("graph_storage", .{ .target = target, .optimize = optimize });
    const graph_storage_mod = graph_storage_dep.module("graph_storage");
```

Then add the import to `root_mod` (after line 427):

```zig
    root_mod.addImport("graph_storage", graph_storage_mod);
```

And to `geode_exe.root_module` (in the corresponding section, after line ~475):

```zig
    geode_exe.root_module.addImport("graph_storage", graph_storage_mod);
```

Also add it to the test module if there is one (search for `test_exe.root_module.addImport` or similar pattern).

- [ ] **Step 4: Verify the dependency resolves**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

Expected: Compiles without errors. The new module is available but not yet imported by any source file.

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon build.zig
git commit -m "feat: add graph-storage library dependency to build system"
```

---

### Task 2: Create the Storage Adapter Module

**Files:**

- Create: `src/storage/graph_storage_adapter.zig`

This is the core of the integration. The adapter wraps one `GraphEngine` per named graph and translates between the two APIs.

- [ ] **Step 1: Create the adapter file with type definitions**

Create `src/storage/graph_storage_adapter.zig` with the foundational types:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Bridge between the graph-storage engine library and geode's execution engine.
//!
//! Manages one `GraphEngine` per named graph, maintains a label string↔LabelId
//! dictionary, and translates between the two PropertyValue representations.

const std = @import("std");
const gs = @import("graph_storage");
const graph_store = @import("../graph_store.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.graph_storage_adapter);

/// A managed collection of GraphEngine instances, one per named graph.
pub const StorageAdapter = struct {
    allocator: Allocator,
    data_dir: []const u8,
    engines: std.StringHashMap(*ManagedGraph),
    default_engine: ?*ManagedGraph,
    config: gs.GraphConfig,
    mutex: std.Thread.Mutex,

    /// Per-graph engine wrapper with label dictionary.
    pub const ManagedGraph = struct {
        engine: *gs.GraphEngine,
        label_dict: LabelStringDict,
        name: []const u8,
        uuid: [16]u8,
    };

    /// Bidirectional label string ↔ LabelId mapping.
    pub const LabelStringDict = struct {
        allocator: Allocator,
        str_to_id: std.StringHashMap(gs.LabelId),
        id_to_str: std.AutoHashMap(gs.LabelId, []const u8),
        next_id: gs.LabelId,

        pub fn init(allocator: Allocator) LabelStringDict {
            return .{
                .allocator = allocator,
                .str_to_id = std.StringHashMap(gs.LabelId).init(allocator),
                .id_to_str = std.AutoHashMap(gs.LabelId, []const u8).init(allocator),
                .next_id = 1,
            };
        }

        pub fn getOrCreate(self: *LabelStringDict, label: []const u8) !gs.LabelId {
            if (self.str_to_id.get(label)) |id| return id;
            const id = self.next_id;
            self.next_id += 1;
            const owned = try self.allocator.dupe(u8, label);
            try self.str_to_id.put(owned, id);
            try self.id_to_str.put(id, owned);
            return id;
        }

        pub fn getString(self: *const LabelStringDict, id: gs.LabelId) ?[]const u8 {
            return self.id_to_str.get(id);
        }

        pub fn deinit(self: *LabelStringDict) void {
            var it = self.str_to_id.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            self.str_to_id.deinit();
            self.id_to_str.deinit();
        }
    };

    pub fn init(allocator: Allocator, data_dir: []const u8, config: gs.GraphConfig) !*StorageAdapter {
        const self = try allocator.create(StorageAdapter);
        self.* = .{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .engines = std.StringHashMap(*ManagedGraph).init(allocator),
            .default_engine = null,
            .config = config,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *StorageAdapter) void {
        var it = self.engines.valueIterator();
        while (it.next()) |mg| {
            mg.*.engine.close() catch {};
            mg.*.label_dict.deinit();
            self.allocator.free(mg.*.name);
            self.allocator.destroy(mg.*);
        }
        self.engines.deinit();
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }

    /// Get or create a GraphEngine for the named graph.
    pub fn getOrCreateGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.get(name)) |mg| return mg;

        // Generate UUID for new graph
        const uuid = @import("uuid").v7();

        var cfg = self.config;
        cfg.data_dir = self.data_dir;

        // Try to open existing graph, fall back to create
        const engine = gs.GraphEngine.open(self.allocator, self.data_dir, uuid, cfg) catch |err| blk: {
            if (err == error.GraphDirectoryMissing or err == error.IoError) {
                break :blk try gs.GraphEngine.create(self.allocator, self.data_dir, uuid, cfg);
            }
            return err;
        };

        const mg = try self.allocator.create(ManagedGraph);
        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.init(self.allocator),
            .name = try self.allocator.dupe(u8, name),
            .uuid = uuid,
        };
        try self.engines.put(mg.name, mg);
        return mg;
    }

    /// Check if a named graph exists.
    pub fn graphExists(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.engines.contains(name);
    }

    /// Drop a named graph.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.fetchRemove(name)) |entry| {
            entry.value.engine.close() catch {};
            entry.value.label_dict.deinit();
            self.allocator.free(entry.value.name);
            self.allocator.destroy(entry.value);
        }
    }

    /// List all graph names.
    pub fn listGraphNames(self: *StorageAdapter, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList([]const u8).init(allocator);
        var it = self.engines.keyIterator();
        while (it.next()) |key| {
            try result.append(try allocator.dupe(u8, key.*));
        }
        return result.toOwnedSlice();
    }
};
```

- [ ] **Step 2: Verify it compiles in isolation**

Add a temporary test import to verify syntax. Run:

`cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

If the file isn't yet imported by anything, create a minimal test:

```bash
echo 'test "adapter smoke" { _ = @import("storage/graph_storage_adapter.zig"); }' >> src/storage/mod.zig
```

Then run `zig build test`. Remove the temporary test line after verification.

- [ ] **Step 3: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat: create graph storage adapter bridging graph-storage engine to geode"
```

---

### Task 3: Add Property Value Translation

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig`

The adapter needs to translate between geode's `graph_store.PropertyValue` (String/Int/Float/Bool/Null/ExtValue/Decimal) and `graph-storage`'s `gs.PropertyValue` (string/int/float/bool/null/decimal/ext).

- [ ] **Step 1: Add property value translation functions**

Add to `src/storage/graph_storage_adapter.zig`:

```zig
/// Convert geode PropertyValue → graph-storage PropertyValue
pub fn toStorageProperty(val: graph_store.PropertyValue) gs.PropertyValue {
    return switch (val) {
        .String => |s| .{ .string = s },
        .Int => |i| .{ .int = i },
        .Float => |f| .{ .float = f },
        .Bool => |b| .{ .bool = b },
        .Null => .null,
        .Decimal => |d| .{ .decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => |ext| .{ .ext = .{ .type_tag = ext.type_tag, .data = ext.data } },
    };
}

/// Convert graph-storage PropertyValue → geode PropertyValue
pub fn fromStorageProperty(allocator: Allocator, val: gs.PropertyValue) !graph_store.PropertyValue {
    return switch (val) {
        .string => |s| .{ .String = try allocator.dupe(u8, s) },
        .int => |i| .{ .Int = i },
        .float => |f| .{ .Float = f },
        .bool => |b| .{ .Bool = b },
        .null => .Null,
        .decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => |e| .{ .ExtValue = .{ .type_tag = e.type_tag, .data = try allocator.dupe(u8, e.data) } },
    };
}
```

> **Note:** Check the exact field names and types on both sides. The geode `ExtValue` may have a different structure than shown — read `src/eval_extended.zig` to verify. Adapt the translation accordingly.

- [ ] **Step 2: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat: add property value translation between geode and graph-storage"
```

---

### Task 4: Add Node and Edge CRUD Methods to Adapter

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig`

These methods bridge geode's node/edge operations to the new engine.

- [ ] **Step 1: Add node CRUD methods**

```zig
// Inside StorageAdapter struct:

/// Create a node with string labels in the named graph.
/// Returns the allocated node ID.
pub fn createNode(self: *StorageAdapter, graph_name: []const u8, labels: []const []const u8) !u64 {
    const mg = try self.getOrCreateGraph(graph_name);
    const node_id = try mg.engine.allocNode();

    // Set labels via label dictionary
    for (labels) |label_str| {
        const label_id = try mg.label_dict.getOrCreate(label_str);
        try mg.engine.addLabel(node_id, label_id);
    }

    return node_id;
}

/// Delete a node by ID from the named graph.
pub fn deleteNode(self: *StorageAdapter, graph_name: []const u8, node_id: u64) !void {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    try mg.engine.deleteNode(node_id);
}

/// Get node labels as strings.
pub fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

    var result = std.ArrayList([]const u8).init(allocator);
    // Iterate label bitmap (u32)
    var bit: u5 = 0;
    while (bit < 32) : (bit += 1) {
        if (rec.label_set & (@as(u32, 1) << bit) != 0) {
            const label_id: gs.LabelId = @as(gs.LabelId, 1) + bit;
            if (mg.label_dict.getString(label_id)) |label_str| {
                try result.append(try allocator.dupe(u8, label_str));
            }
        }
    }
    return result.toOwnedSlice();
}
```

- [ ] **Step 2: Add edge CRUD methods**

```zig
/// Create an edge between two nodes in the named graph.
pub fn createEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8) !u64 {
    const mg = try self.getOrCreateGraph(graph_name);
    const rel_type = try mg.label_dict.getOrCreate(label);
    return try mg.engine.addEdge(from_id, to_id, rel_type);
}

/// Delete an edge by ID from the named graph.
pub fn deleteEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) !void {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    try mg.engine.removeEdge(from_id, to_id, edge_id);
}

/// Get outgoing edges from a node.
pub fn getOutgoingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    return try mg.engine.expandOut(node_id, null, allocator);
}

/// Get incoming edges to a node.
pub fn getIncomingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    return try mg.engine.expandIn(node_id, null, allocator);
}
```

- [ ] **Step 3: Add property methods**

```zig
/// Set a property on a node.
pub fn setNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, value: graph_store.PropertyValue) !void {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const storage_val = toStorageProperty(value);
    // putProperty returns the new prop_head — update the node record
    const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
    _ = try mg.engine.putProperty(rec.prop_head, key, storage_val);
}

/// Get a property from a node.
pub fn getNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, allocator: Allocator) !?graph_store.PropertyValue {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
    const val = try mg.engine.getProperty(rec.prop_head, key, allocator) orelse return null;
    return try fromStorageProperty(allocator, val);
}

/// Get all properties for a node.
pub fn getAllNodeProperties(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.PropertyEntry {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
    return try mg.engine.getAllProperties(rec.prop_head, allocator);
}
```

- [ ] **Step 4: Add label scan method**

```zig
/// Find all node IDs with a given label in a graph.
pub fn getNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    const label_id = mg.label_dict.str_to_id.get(label) orelse return allocator.alloc(u64, 0);
    return try mg.engine.scanLabel(label_id, allocator);
}
```

- [ ] **Step 5: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 6: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat: add node/edge/property CRUD methods to storage adapter"
```

---

### Task 5: Add Transaction and Persistence Methods

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig`

- [ ] **Step 1: Add transaction methods**

```zig
/// Begin a transaction on the named graph's engine.
pub fn beginTransaction(self: *StorageAdapter, graph_name: []const u8) !u64 {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    return try mg.engine.beginTxn();
}

/// Commit a transaction.
pub fn commitTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    try mg.engine.commitTxn(txn_id);
}

/// Abort a transaction.
pub fn abortTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
    const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
    try mg.engine.abortTxn(txn_id);
}

/// Checkpoint all engines (flush dirty pages, update manifest).
pub fn checkpointAll(self: *StorageAdapter) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var it = self.engines.valueIterator();
    while (it.next()) |mg| {
        try mg.*.engine.checkpoint();
    }
}

/// Get node count for a graph.
pub fn nodeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
    const mg = self.engines.get(graph_name) orelse return 0;
    return try mg.engine.nodeCount();
}

/// Get edge count for a graph.
pub fn edgeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
    const mg = self.engines.get(graph_name) orelse return 0;
    return try mg.engine.edgeCount();
}
```

- [ ] **Step 2: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat: add transaction and persistence methods to storage adapter"
```

---

### Task 6: Wire Adapter into Global Store Singleton

**Files:**

- Modify: `src/graph_store.zig` (add adapter initialization to `getGlobalStore`)
- Modify: `src/server/server_init.zig` (initialize adapter at startup)

This task connects the adapter to the existing global store pattern. The key change: `getGlobalStore()` returns the existing `GraphStore` but its underlying storage is backed by the adapter's `GraphEngine` instances.

- [ ] **Step 1: Add adapter global singleton**

In `src/graph_store.zig`, add near the top (around the existing `global_store` variable):

```zig
const graph_storage_adapter = @import("storage/graph_storage_adapter.zig");

var global_adapter: ?*graph_storage_adapter.StorageAdapter = null;

pub fn getGlobalAdapter() ?*graph_storage_adapter.StorageAdapter {
    return global_adapter;
}

pub fn initGlobalAdapter(allocator: std.mem.Allocator, data_dir: []const u8) !*graph_storage_adapter.StorageAdapter {
    if (global_adapter) |existing| return existing;

    const gs = @import("graph_storage");
    const adapter = try graph_storage_adapter.StorageAdapter.init(allocator, data_dir, gs.GraphConfig{
        .data_dir = data_dir,
    });
    global_adapter = adapter;
    return adapter;
}
```

- [ ] **Step 2: Initialize adapter in server startup**

In `src/server/server_init.zig`, after the existing store initialization (around line 258), add:

```zig
    // Initialize new graph-storage adapter alongside existing store
    if (data_dir) |dir| {
        _ = graph_store.initGlobalAdapter(allocator, dir) catch |err| {
            log.warn("Failed to initialize graph-storage adapter: {s}", .{@errorName(err)});
        };
    }
```

- [ ] **Step 3: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig src/server/server_init.zig
git commit -m "feat: wire graph-storage adapter into global store and server initialization"
```

---

### Task 7: Add Adapter Integration Tests

**Files:**

- Create: `src/storage/graph_storage_adapter_test.zig` (or embedded tests)

- [ ] **Step 1: Add embedded tests to the adapter**

Add to the bottom of `src/storage/graph_storage_adapter.zig`:

```zig
test "StorageAdapter: create and query graph" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, gs.GraphConfig{});
    defer adapter.deinit();

    // Create a graph
    const mg = try adapter.getOrCreateGraph("test_graph");
    _ = mg;

    // Verify it exists
    try std.testing.expect(adapter.graphExists("test_graph"));
    try std.testing.expect(!adapter.graphExists("nonexistent"));
}

test "StorageAdapter: create node with labels" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, gs.GraphConfig{});
    defer adapter.deinit();

    const labels = &[_][]const u8{ "Person", "Employee" };
    const node_id = try adapter.createNode("test_graph", labels);
    try std.testing.expect(node_id > 0);

    // Verify labels
    const retrieved_labels = try adapter.getNodeLabels("test_graph", node_id, allocator);
    defer {
        for (retrieved_labels) |l| allocator.free(l);
        allocator.free(retrieved_labels);
    }
    try std.testing.expectEqual(@as(usize, 2), retrieved_labels.len);
}

test "StorageAdapter: create and traverse edge" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, gs.GraphConfig{});
    defer adapter.deinit();

    const node_a = try adapter.createNode("g", &.{"A"});
    const node_b = try adapter.createNode("g", &.{"B"});
    const edge_id = try adapter.createEdge("g", node_a, node_b, "KNOWS");
    try std.testing.expect(edge_id > 0);

    const out = try adapter.getOutgoingEdges("g", node_a, allocator);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(node_b, out[0].neighbor);
}

test "StorageAdapter: drop graph" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, gs.GraphConfig{});
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("ephemeral");
    try std.testing.expect(adapter.graphExists("ephemeral"));

    try adapter.dropGraph("ephemeral");
    try std.testing.expect(!adapter.graphExists("ephemeral"));
}
```

- [ ] **Step 2: Run tests**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | tail -20`

Expected: All adapter tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "test: add integration tests for graph-storage adapter"
```

---

### Task 8: Verify Full Build and Existing Tests

- [ ] **Step 1: Run full build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build 2>&1 | tail -20`

- [ ] **Step 2: Run unit tests**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | tail -20`

- [ ] **Step 3: Run geodetestlab DSN spec (regression)**

Run: `cd /home/benji/src/devnw/codepros/geode/geode-test-harness && geodetestlab run --spec geodetestlab-cli/specs/dsn_graph_binding.yml 2>&1 | tail -15`

All existing tests must still pass — the adapter is added alongside (not replacing) the existing store.

- [ ] **Step 4: Fix any regressions**

- [ ] **Step 5: Final commit if fixes needed**

```bash
git add -A
git commit -m "fix: resolve regressions from graph-storage adapter integration"
```

---

## Phase 2 Preview (Separate Plan)

Phase 2 will migrate the execution engine to use the adapter:

- Modify `src/execution/match_operations.zig` to read from adapter instead of HashMap iteration
- Modify `src/execution/crud_operations.zig` to write via adapter
- Modify `src/execution/statement_dispatcher.zig` for graph management (CREATE/DROP GRAPH)
- Update all 86+ importer files incrementally

## Phase 3 Preview (Separate Plan)

Phase 3 will remove the old storage:

- Delete `src/graph_store.zig` (5,168 lines)
- Delete `src/graph_handle.zig` (640 lines)
- Delete `src/graph_registry.zig` (371 lines)
- Update all imports to use the adapter directly
- Remove legacy persistence code
