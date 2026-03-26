# Per-Graph Storage Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split monolithic `graph_store.dat` into per-graph UUID-named files with automatic migration.

**Architecture:** GraphStore internally routes data through per-graph `GraphHandle` structs. A `GraphRegistry` maps graph names to UUIDv7 filenames. On startup, detect legacy monolithic file and auto-migrate to split format. Each per-graph file is independently serialized with CRC32 and optional TDE.

**Tech Stack:** Zig 0.15.1, existing UUIDv7 (`src/uuid.zig`), CRC32 (`std.hash.crc`), TDE (`src/storage/tde_file_encryption.zig`)

**Spec:** `docs/superpowers/specs/2026-03-16-per-graph-storage-split-design.md`

---

## Chunk 1: GraphHandle and GraphRegistry (Foundation)

### Task 1: Create GraphHandle struct

**Files:**

- Create: `src/graph_handle.zig`
- Reference: `src/graph_store.zig:147-176` (Node/Edge structs), `src/graph_store.zig:342-392` (GraphStore fields)

- [ ] **Step 1: Create `src/graph_handle.zig` with the GraphHandle struct**

```zig
const std = @import("std");
const graph_store = @import("graph_store.zig");
const Node = graph_store.Node;
const Edge = graph_store.Edge;
const PropertyValue = graph_store.PropertyValue;

pub const GraphHandle = struct {
    allocator: std.mem.Allocator,
    uuid: [16]u8,
    name: []const u8,
    dirty: bool = false,
    available: bool = true,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    label_index: std.StringHashMap(std.ArrayList(u64)),
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    rwlock: std.Thread.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator, name: []const u8, uuid: [16]u8) !*GraphHandle {
        const handle = try allocator.create(GraphHandle);
        handle.* = .{
            .allocator = allocator,
            .uuid = uuid,
            .name = try allocator.dupe(u8, name),
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .label_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
        return handle;
    }

    pub fn deinit(self: *GraphHandle) void {
        // Free label_index keys and values
        var li = self.label_index.iterator();
        while (li.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();
        // Free adjacency lists
        var oi = self.outgoing_edges.iterator();
        while (oi.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.outgoing_edges.deinit();
        var ii = self.incoming_edges.iterator();
        while (ii.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.incoming_edges.deinit();
        // Free nodes (labels, properties, graph_name)
        var ni = self.nodes.iterator();
        while (ni.next()) |entry| {
            const node = entry.value_ptr;
            for (node.labels) |label| self.allocator.free(label);
            if (node.labels.len > 0) self.allocator.free(node.labels);
            var pi = node.properties.iterator();
            while (pi.next()) |prop| {
                self.allocator.free(prop.key_ptr.*);
                graph_store.freePropertyValue(self.allocator, prop.value_ptr.*);
            }
            node.properties.deinit();
            if (node.graph_name.len > 0 and node.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr)
                self.allocator.free(node.graph_name);
        }
        self.nodes.deinit();
        // Free edges similarly
        var ei = self.edges.iterator();
        while (ei.next()) |entry| {
            const edge = entry.value_ptr;
            self.allocator.free(edge.label);
            var pi = edge.properties.iterator();
            while (pi.next()) |prop| {
                self.allocator.free(prop.key_ptr.*);
                graph_store.freePropertyValue(self.allocator, prop.value_ptr.*);
            }
            edge.properties.deinit();
            if (edge.graph_name.len > 0 and edge.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr)
                self.allocator.free(edge.graph_name);
        }
        self.edges.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn nodeCount(self: *const GraphHandle) u64 {
        return self.nodes.count();
    }

    pub fn edgeCount(self: *const GraphHandle) u64 {
        return self.edges.count();
    }

    /// Rebuild label_index and adjacency indexes from nodes/edges.
    pub fn rebuildIndexes(self: *GraphHandle) !void {
        // Clear existing indexes
        var li = self.label_index.iterator();
        while (li.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.clearAndFree();
        var oi = self.outgoing_edges.iterator();
        while (oi.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.outgoing_edges.clearAndFree();
        var ii = self.incoming_edges.iterator();
        while (ii.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.incoming_edges.clearAndFree();

        // Rebuild from nodes
        var ni = self.nodes.iterator();
        while (ni.next()) |entry| {
            const node = entry.value_ptr;
            for (node.labels) |label| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}", .{label});
                const gop = try self.label_index.getOrPut(key);
                if (gop.found_existing) {
                    self.allocator.free(key);
                    try gop.value_ptr.append(self.allocator, entry.key_ptr.*);
                } else {
                    gop.value_ptr.* = std.ArrayList(u64).empty;
                    try gop.value_ptr.append(self.allocator, entry.key_ptr.*);
                }
            }
        }

        // Rebuild adjacency from edges
        var ei = self.edges.iterator();
        while (ei.next()) |entry| {
            const edge = entry.value_ptr;
            {
                const gop = try self.outgoing_edges.getOrPut(edge.from_id);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
                try gop.value_ptr.append(self.allocator, entry.key_ptr.*);
            }
            {
                const gop = try self.incoming_edges.getOrPut(edge.to_id);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
                try gop.value_ptr.append(self.allocator, entry.key_ptr.*);
            }
        }
    }

    /// Get node IDs matching a label in this graph.
    pub fn getNodesByLabel(self: *const GraphHandle, label: []const u8) ?[]const u64 {
        if (self.label_index.get(label)) |list| {
            return list.items;
        }
        return null;
    }
};
```

- [ ] **Step 2: Write unit tests for GraphHandle**

Add tests at the bottom of `src/graph_handle.zig`:

```zig
test "GraphHandle - init and deinit" {
    const allocator = std.testing.allocator;
    const uuid = [_]u8{1} ** 16;
    const handle = try GraphHandle.init(allocator, "test_graph", uuid);
    defer handle.deinit();
    try std.testing.expectEqualStrings("test_graph", handle.name);
    try std.testing.expect(handle.available);
    try std.testing.expect(!handle.dirty);
    try std.testing.expectEqual(@as(u64, 0), handle.nodeCount());
}

test "GraphHandle - rebuildIndexes" {
    const allocator = std.testing.allocator;
    const uuid = [_]u8{2} ** 16;
    const handle = try GraphHandle.init(allocator, "test", uuid);
    defer handle.deinit();

    // Add a node with labels
    const label = try allocator.dupe(u8, "Person");
    var labels = try allocator.alloc([]const u8, 1);
    labels[0] = label;
    try handle.nodes.put(1, .{
        .id = 1,
        .labels = labels,
        .properties = std.StringHashMap(PropertyValue).init(allocator),
        .graph_name = graph_store.DEFAULT_GRAPH_NAME,
    });

    try handle.rebuildIndexes();
    const ids = handle.getNodesByLabel("Person");
    try std.testing.expect(ids != null);
    try std.testing.expectEqual(@as(usize, 1), ids.?.len);
    try std.testing.expectEqual(@as(u64, 1), ids.?[0]);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test 2>&1 | grep -E "graph_handle|PASS|FAIL"`
Expected: All graph_handle tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/graph_handle.zig
git commit -m "feat: add GraphHandle struct for per-graph data isolation"
```

---

### Task 2: Create GraphRegistry for file mapping

**Files:**

- Create: `src/graph_registry.zig`
- Reference: `src/uuid.zig` (UUIDv7), `src/storage/tde_file_encryption.zig` (TDE)

- [ ] **Step 1: Create `src/graph_registry.zig` with serialization/deserialization**

```zig
const std = @import("std");
const uuid_mod = @import("uuid.zig");
const UuidV7 = uuid_mod.UuidV7;
const tde = @import("storage/tde_file_encryption.zig");
const crc = std.hash.crc;

pub const MAGIC = "GEODREG1";
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 44; // 8 + 4 + 4 + 8 + 8 + 8 + 4

pub const GraphEntry = struct {
    name: []const u8,
    uuid: [16]u8,
    node_count: u64,
    edge_count: u64,
};

pub const GraphRegistry = struct {
    allocator: std.mem.Allocator,
    next_node_id: u64 = 1,
    next_edge_id: u64 = 1,
    entries: std.ArrayList(GraphEntry),

    pub fn init(allocator: std.mem.Allocator) GraphRegistry {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(GraphEntry).empty,
        };
    }

    pub fn deinit(self: *GraphRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addGraph(self: *GraphRegistry, name: []const u8) ![16]u8 {
        const new_uuid = UuidV7.new();
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .uuid = new_uuid.bytes,
            .node_count = 0,
            .edge_count = 0,
        });
        return new_uuid.bytes;
    }

    pub fn removeGraph(self: *GraphRegistry, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.allocator.free(entry.name);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn findByName(self: *const GraphRegistry, name: []const u8) ?GraphEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn saveToFile(self: *const GraphRegistry, path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        var writer = file.deprecatedWriter();

        // Write header (CRC placeholder at offset 40)
        var header: [HEADER_SIZE]u8 = [_]u8{0} ** HEADER_SIZE;
        @memcpy(header[0..8], MAGIC);
        std.mem.writeInt(u32, header[8..12], VERSION, .little);
        std.mem.writeInt(u32, header[12..16], 0, .little); // reserved
        std.mem.writeInt(u64, header[16..24], self.next_node_id, .little);
        std.mem.writeInt(u64, header[24..32], self.next_edge_id, .little);
        std.mem.writeInt(u64, header[32..40], @intCast(self.entries.items.len), .little);
        // CRC at [40..44] patched after payload
        try writer.writeAll(&header);

        // Write entries and compute CRC over header (sans CRC field) + entries
        var hasher = crc.Crc32.init();
        hasher.update(header[0..40]); // hash header fields (not CRC slot)

        for (self.entries.items) |entry| {
            var name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len_buf, @intCast(entry.name.len), .little);
            hasher.update(&name_len_buf);
            try writer.writeAll(&name_len_buf);
            hasher.update(entry.name);
            try writer.writeAll(entry.name);
            hasher.update(&entry.uuid);
            try writer.writeAll(&entry.uuid);
            var nc_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &nc_buf, entry.node_count, .little);
            hasher.update(&nc_buf);
            try writer.writeAll(&nc_buf);
            var ec_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &ec_buf, entry.edge_count, .little);
            hasher.update(&ec_buf);
            try writer.writeAll(&ec_buf);
        }

        // Patch CRC
        const checksum = hasher.final();
        try file.seekTo(40);
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, checksum, .little);
        try file.writeAll(&crc_buf);

        // TDE encrypt if enabled, then atomic rename
        try tde.finalizeFile(self.allocator, tmp_path, path);
    }

    pub fn loadFromFile(self: *GraphRegistry, path: []const u8) !void {
        const data = tde.readDecryptedFile(self.allocator, path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(data);

        if (data.len < HEADER_SIZE) return error.InvalidFormat;

        // Validate magic
        if (!std.mem.eql(u8, data[0..8], MAGIC)) return error.InvalidMagic;
        const version = std.mem.readInt(u32, data[8..12], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        self.next_node_id = std.mem.readInt(u64, data[16..24], .little);
        self.next_edge_id = std.mem.readInt(u64, data[24..32], .little);
        const graph_count = std.mem.readInt(u64, data[32..40], .little);
        const stored_crc = std.mem.readInt(u32, data[40..44], .little);

        // Verify CRC (header sans CRC + payload)
        var hasher = crc.Crc32.init();
        hasher.update(data[0..40]);
        if (data.len > HEADER_SIZE) hasher.update(data[HEADER_SIZE..]);
        if (hasher.final() != stored_crc) return error.ChecksumMismatch;

        // Parse entries
        var offset: usize = HEADER_SIZE;
        var i: u64 = 0;
        while (i < graph_count) : (i += 1) {
            if (offset + 4 > data.len) return error.TruncatedFile;
            const name_len = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            if (offset + name_len > data.len) return error.TruncatedFile;
            const name = try self.allocator.dupe(u8, data[offset..][0..name_len]);
            offset += name_len;
            if (offset + 16 > data.len) return error.TruncatedFile;
            var uuid_bytes: [16]u8 = undefined;
            @memcpy(&uuid_bytes, data[offset..][0..16]);
            offset += 16;
            if (offset + 16 > data.len) return error.TruncatedFile;
            const node_count = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;
            const edge_count = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;
            try self.entries.append(self.allocator, .{
                .name = name,
                .uuid = uuid_bytes,
                .node_count = node_count,
                .edge_count = edge_count,
            });
        }
    }
};
```

Note: `tde.finalizeFile` may not exist — if not, implement the TDE-encrypt-then-rename pattern inline (read tmp file, encrypt if TDE enabled, write to final path, delete tmp). Check `src/graph_store.zig:finalizeTempFile` for the existing pattern and reuse it.

- [ ] **Step 2: Write unit tests for GraphRegistry**

```zig
test "GraphRegistry - round trip save/load" {
    const allocator = std.testing.allocator;
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    reg.next_node_id = 42;
    reg.next_edge_id = 99;
    const uuid1 = try reg.addGraph("default");
    const uuid2 = try reg.addGraph("analytics");

    // Save
    const path = "/tmp/test_graph_registry.dat";
    try reg.saveToFile(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Load into new registry
    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();
    try reg2.loadFromFile(path);

    try std.testing.expectEqual(@as(u64, 42), reg2.next_node_id);
    try std.testing.expectEqual(@as(u64, 99), reg2.next_edge_id);
    try std.testing.expectEqual(@as(usize, 2), reg2.entries.items.len);
    try std.testing.expectEqualStrings("default", reg2.entries.items[0].name);
    try std.testing.expect(std.mem.eql(u8, &uuid1, &reg2.entries.items[0].uuid));
    try std.testing.expectEqualStrings("analytics", reg2.entries.items[1].name);
    try std.testing.expect(std.mem.eql(u8, &uuid2, &reg2.entries.items[1].uuid));
}

test "GraphRegistry - CRC validation rejects corrupt data" {
    const allocator = std.testing.allocator;
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    _ = try reg.addGraph("test");
    const path = "/tmp/test_graph_registry_corrupt.dat";
    try reg.saveToFile(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Corrupt one byte in the payload
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekTo(HEADER_SIZE + 2);
    try file.writeAll(&[_]u8{0xFF});

    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();
    try std.testing.expectError(error.ChecksumMismatch, reg2.loadFromFile(path));
}

test "GraphRegistry - removeGraph" {
    const allocator = std.testing.allocator;
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    _ = try reg.addGraph("foo");
    _ = try reg.addGraph("bar");
    try std.testing.expect(reg.removeGraph("foo"));
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try std.testing.expectEqualStrings("bar", reg.entries.items[0].name);
    try std.testing.expect(!reg.removeGraph("nonexistent"));
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test 2>&1 | grep -E "graph_registry|PASS|FAIL"`
Expected: All graph_registry tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/graph_registry.zig
git commit -m "feat: add GraphRegistry for per-graph UUID file mapping"
```

---

## Chunk 2: Per-Graph File I/O

### Task 3: Per-graph file serialization and deserialization

**Files:**

- Modify: `src/graph_handle.zig`
- Reference: `src/graph_store.zig:2534-2714` (serializeToTempFile, serializePayload, writePropertyToWriter)
- Reference: `src/graph_store.zig:2857-3155` (loadFromFile, readExtValue)

The per-graph file uses the same node/edge serialization as the monolithic format EXCEPT:

- Different magic (`GEODGRF1` instead of `GEODGST1`)
- No graph registry section (only nodes and edges)
- `graph_name` field is NOT written per node/edge (implicit from file)
- Header is 36 bytes (not 60)

- [ ] **Step 1: Add `saveToFile` and `loadFromFile` to GraphHandle**

Port the serialization logic from `graph_store.zig:serializePayload` (lines 2608-2714) and `writePropertyToWriter` (lines 2717-2777) into GraphHandle, but skip the graph_name field during write. During load, populate node/edge graph_name from `self.name`.

Key constants:

```zig
pub const PER_GRAPH_MAGIC = "GEODGRF1";
pub const PER_GRAPH_VERSION: u32 = 1;
pub const PER_GRAPH_HEADER_SIZE: usize = 36; // 8+4+4+8+8+4
```

The property serialization (writePropertyToWriter, readProperty, writeExtValueToWriter, readExtValue) is complex (~700 lines handling 34 ExtValue types). **Reuse** the existing functions from `graph_store.zig` by either:
a) Making them `pub` on GraphStore and calling through a reference, or
b) Extracting them into a shared `src/storage/serialization.zig` module

Option (b) is cleaner. Extract these functions from graph_store.zig into a shared module:

- `writePropertyToWriter`
- `readProperty`
- `writeExtValueToWriter`
- `readExtValue`

Then both GraphStore (for migration/backward compat) and GraphHandle (for per-graph files) import from the shared module.

- [ ] **Step 2: Write tests for per-graph file round-trip**

```zig
test "GraphHandle - save and load per-graph file" {
    const allocator = std.testing.allocator;
    const uuid = [_]u8{3} ** 16;
    const handle = try GraphHandle.init(allocator, "test_graph", uuid);
    defer handle.deinit();

    // Add test data (node with properties)
    // ... (create node with label "Person", property name="Alice")

    const path = "/tmp/test_per_graph.dat";
    try handle.saveToFile(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Load into new handle
    const handle2 = try GraphHandle.init(allocator, "test_graph", uuid);
    defer handle2.deinit();
    try handle2.loadFromFile(path);

    try std.testing.expectEqual(handle.nodeCount(), handle2.nodeCount());
    // Verify node data round-tripped correctly
    const node = handle2.nodes.get(1).?;
    try std.testing.expectEqualStrings("test_graph", node.graph_name);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test 2>&1 | grep -E "graph_handle|PASS|FAIL"`

- [ ] **Step 4: Commit**

```bash
git add src/graph_handle.zig src/storage/serialization.zig
git commit -m "feat: add per-graph file I/O with shared serialization"
```

---

## Chunk 3: GraphStore Refactor

### Task 4: Add GraphHandle routing to GraphStore

**Files:**

- Modify: `src/graph_store.zig` (lines 342-392 struct, all accessor methods)
- Reference: `src/graph_handle.zig`

This is the core refactor. The strategy:

1. Add `graph_handles: std.StringHashMap(*GraphHandle)` to GraphStore
2. Add `graph_handles_mutex: std.Thread.Mutex` to GraphStore
3. Add `data_dir: []const u8` to GraphStore
4. Keep existing `nodes`, `edges`, `label_index`, `outgoing_edges`, `incoming_edges` as **computed views** during the transition — they point to the "current graph" handle's data, or are used for cross-graph iteration
5. Add `getHandle(graph_name) -> ?*GraphHandle` method
6. Modify `createGraph`/`dropGraph` to create/destroy GraphHandles
7. Modify `saveToFile` to save per-graph files + registry
8. Modify `loadFromFile` to detect format and load accordingly

**Important**: The existing `nodes`/`edges` fields on GraphStore are accessed by 100+ call sites. During this transition phase, keep them as the "default" graph's data for backward compatibility. Callers that already pass `graph_name` can be updated to use `getHandle()` directly. Callers that don't can be updated incrementally in later tasks.

- [ ] **Step 1: Add graph_handles field and getHandle method to GraphStore**

At `src/graph_store.zig:392`, add:

```zig
graph_handles: std.StringHashMap(*GraphHandle) = undefined,
graph_handles_mutex: std.Thread.Mutex = .{},
data_dir: []const u8 = "",
use_per_graph_storage: bool = false, // true after migration or fresh init with registry
```

Add method:

```zig
pub fn getHandle(self: *GraphStore, graph_name: []const u8) ?*GraphHandle {
    self.graph_handles_mutex.lock();
    defer self.graph_handles_mutex.unlock();
    return self.graph_handles.get(graph_name);
}
```

- [ ] **Step 2: Modify init to initialize graph_handles**

In `initWithTenant` (line 369-392), add:

```zig
.graph_handles = std.StringHashMap(*GraphHandle).init(allocator),
```

- [ ] **Step 3: Modify createGraph to create a GraphHandle**

In `createGraph` (line 612-619), after creating the graph name entry, also create a GraphHandle:

```zig
pub fn createGraph(self: *GraphStore, graph_name: []const u8) !void {
    if (self.graphs.contains(graph_name)) return error.GraphAlreadyExists;
    const name_copy = try self.allocator.dupe(u8, graph_name);
    try self.graphs.put(name_copy, {});
    if (self.use_per_graph_storage) {
        const uuid_v7 = UuidV7.new();
        const handle = try GraphHandle.init(self.allocator, graph_name, uuid_v7.bytes);
        self.graph_handles_mutex.lock();
        defer self.graph_handles_mutex.unlock();
        try self.graph_handles.put(try self.allocator.dupe(u8, graph_name), handle);
    }
    self.dirty = true;
}
```

- [ ] **Step 4: Modify dropGraph to destroy GraphHandle**

In `dropGraph` (line 621-633), after clearing nodes, also destroy the handle:

```zig
if (self.use_per_graph_storage) {
    self.graph_handles_mutex.lock();
    defer self.graph_handles_mutex.unlock();
    if (self.graph_handles.fetchRemove(graph_name)) |kv| {
        kv.value.deinit();
        self.allocator.free(kv.key);
    }
}
```

- [ ] **Step 5: Add per-graph save/load methods**

```zig
/// Save all dirty graph handles to individual files + registry.
pub fn savePerGraphFiles(self: *GraphStore) !void {
    const graph_handle = @import("graph_handle.zig");
    const graph_registry = @import("graph_registry.zig");
    _ = graph_handle;

    // Build registry from handles
    var reg = graph_registry.GraphRegistry.init(self.allocator);
    defer reg.deinit();
    reg.next_node_id = self.next_node_id;
    reg.next_edge_id = self.next_edge_id;

    const graphs_dir = try std.fmt.allocPrint(self.allocator, "{s}/graphs", .{self.data_dir});
    defer self.allocator.free(graphs_dir);
    std.fs.cwd().makePath(graphs_dir) catch {};

    self.graph_handles_mutex.lock();
    defer self.graph_handles_mutex.unlock();

    var it = self.graph_handles.iterator();
    while (it.next()) |entry| {
        const handle = entry.value_ptr.*;
        // Add to registry
        try reg.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, handle.name),
            .uuid = handle.uuid,
            .node_count = handle.nodeCount(),
            .edge_count = handle.edgeCount(),
        });
        // Save if dirty
        if (handle.dirty) {
            var uuid_str_buf: [36]u8 = undefined;
            const uuid_str = UuidV7.fromBytes(handle.uuid).toStringBuf(&uuid_str_buf) catch continue;
            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.dat", .{ graphs_dir, uuid_str });
            defer self.allocator.free(file_path);
            try handle.saveToFile(file_path);
            handle.dirty = false;
        }
    }

    // Save registry
    const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/graph_registry.dat", .{self.data_dir});
    defer self.allocator.free(reg_path);
    try reg.saveToFile(reg_path);

    self.dirty = false;
}

/// Load per-graph files from registry.
pub fn loadPerGraphFiles(self: *GraphStore) !void {
    const graph_registry = @import("graph_registry.zig");

    const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/graph_registry.dat", .{self.data_dir});
    defer self.allocator.free(reg_path);

    var reg = graph_registry.GraphRegistry.init(self.allocator);
    defer reg.deinit();
    try reg.loadFromFile(reg_path);

    self.next_node_id = reg.next_node_id;
    self.next_edge_id = reg.next_edge_id;

    const graphs_dir = try std.fmt.allocPrint(self.allocator, "{s}/graphs", .{self.data_dir});
    defer self.allocator.free(graphs_dir);

    for (reg.entries.items) |entry| {
        const handle = try GraphHandle.init(self.allocator, entry.name, entry.uuid);
        var uuid_str_buf: [36]u8 = undefined;
        const uuid_str = UuidV7.fromBytes(entry.uuid).toStringBuf(&uuid_str_buf) catch continue;
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.dat", .{ graphs_dir, uuid_str });
        defer self.allocator.free(file_path);

        handle.loadFromFile(file_path) catch |err| {
            log.err("Failed to load graph file", &.{
                Attr.string("graph", entry.name),
                Attr.string("error", @errorName(err)),
            });
            handle.available = false;
        };

        // Also populate the legacy flat maps for backward compat
        var ni = handle.nodes.iterator();
        while (ni.next()) |n| {
            try self.nodes.put(n.key_ptr.*, n.value_ptr.*);
        }
        var ei = handle.edges.iterator();
        while (ei.next()) |e| {
            try self.edges.put(e.key_ptr.*, e.value_ptr.*);
        }

        const name_key = try self.allocator.dupe(u8, entry.name);
        self.graph_handles_mutex.lock();
        try self.graph_handles.put(name_key, handle);
        self.graph_handles_mutex.unlock();
        try self.ensureGraphNoDirty(entry.name);
    }

    self.use_per_graph_storage = true;
    try self.rebuildIndexes();
}
```

- [ ] **Step 6: Modify saveToFile and loadFromFile to detect mode**

In `saveToFile` (line 2516): add check for `use_per_graph_storage`:

```zig
pub fn saveToFile(self: *GraphStore) !void {
    if (self.use_per_graph_storage) {
        return self.savePerGraphFiles();
    }
    // ... existing monolithic save logic
}
```

In `loadFromFile` (line 2857): after loading, check if registry exists:

```zig
pub fn loadFromFile(self: *GraphStore) !void {
    // Check for per-graph storage first
    const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/graph_registry.dat", .{self.data_dir});
    defer self.allocator.free(reg_path);
    if (std.fs.cwd().access(reg_path, .{})) {
        return self.loadPerGraphFiles();
    } else |_| {}

    // ... existing monolithic load logic
}
```

- [ ] **Step 7: Run full test suite**

Run: `zig build test`
Expected: All existing tests still pass (backward compat maintained)

- [ ] **Step 8: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat: add per-graph GraphHandle routing to GraphStore"
```

---

## Chunk 4: Migration

### Task 5: Implement monolithic-to-split migration

**Files:**

- Create: `src/storage/migration.zig`
- Modify: `src/server/server_init.zig` (line 223-336)
- Modify: `src/server/main.zig` (line 329-340)

- [ ] **Step 1: Create `src/storage/migration.zig`**

```zig
const std = @import("std");
const graph_store = @import("../graph_store.zig");
const GraphHandle = @import("../graph_handle.zig").GraphHandle;
const GraphRegistry = @import("../graph_registry.zig").GraphRegistry;
const UuidV7 = @import("../uuid.zig").UuidV7;
const log = @import("../log.zig");

pub const MigrationResult = struct {
    graphs_migrated: u64,
    total_nodes: u64,
    total_edges: u64,
};

/// Detect storage state and return required action.
pub const StorageState = enum {
    fresh,              // No data files exist
    legacy_monolithic,  // graph_store.dat exists, no registry
    per_graph,          // graph_registry.dat exists, graph_store.dat.migrated or absent
    interrupted,        // Both graph_store.dat AND graph_registry.dat exist (no .migrated)
};

pub fn detectStorageState(data_dir: []const u8, allocator: std.mem.Allocator) !StorageState {
    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat", .{data_dir});
    defer allocator.free(legacy_path);
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    const migrated_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat.migrated", .{data_dir});
    defer allocator.free(migrated_path);

    const has_legacy = if (std.fs.cwd().access(legacy_path, .{})) true else |_| false;
    const has_registry = if (std.fs.cwd().access(reg_path, .{})) true else |_| false;
    const has_migrated = if (std.fs.cwd().access(migrated_path, .{})) true else |_| false;

    if (has_registry and !has_legacy) return .per_graph;
    if (has_registry and has_migrated) return .per_graph; // post-migration normal state
    if (has_legacy and has_registry) return .interrupted;
    if (has_legacy and !has_registry) return .legacy_monolithic;
    return .fresh;
}

/// Migrate monolithic graph_store.dat to per-graph files.
pub fn migrateToPerGraph(data_dir: []const u8, allocator: std.mem.Allocator) !MigrationResult {
    std.debug.print("\n[MIGRATION] Migrating monolithic graph_store.dat to per-graph storage...\n", .{});

    // 1. Load monolithic file
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    try store.loadFromFile(); // loads the legacy monolithic file

    // 2. Create graphs/ directory
    const graphs_dir = try std.fmt.allocPrint(allocator, "{s}/graphs", .{data_dir});
    defer allocator.free(graphs_dir);
    try std.fs.cwd().makePath(graphs_dir);

    // 3. Build registry and write per-graph files
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    reg.next_node_id = store.next_node_id;
    reg.next_edge_id = store.next_edge_id;

    var result = MigrationResult{ .graphs_migrated = 0, .total_nodes = 0, .total_edges = 0 };

    // Iterate each graph
    var graph_iter = store.graphs.iterator();
    while (graph_iter.next()) |graph_entry| {
        const graph_name = graph_entry.key_ptr.*;
        const uuid_bytes = try reg.addGraph(graph_name);

        // Create handle and populate with this graph's nodes/edges
        const handle = try GraphHandle.init(allocator, graph_name, uuid_bytes);
        defer handle.deinit();

        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |n| {
            if (std.mem.eql(u8, n.value_ptr.graph_name, graph_name)) {
                // Deep copy node into handle
                try handle.nodes.put(n.key_ptr.*, n.value_ptr.*);
                result.total_nodes += 1;
            }
        }

        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.graph_name, graph_name)) {
                try handle.edges.put(e.key_ptr.*, e.value_ptr.*);
                result.total_edges += 1;
            }
        }

        try handle.rebuildIndexes();

        // Write per-graph file
        var uuid_str_buf: [36]u8 = undefined;
        const uuid_str = try UuidV7.fromBytes(uuid_bytes).toStringBuf(&uuid_str_buf);
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.dat", .{ graphs_dir, uuid_str });
        defer allocator.free(file_path);
        try handle.saveToFile(file_path);

        // Update registry entry counts
        for (reg.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, graph_name)) {
                entry.node_count = handle.nodeCount();
                entry.edge_count = handle.edgeCount();
            }
        }

        result.graphs_migrated += 1;
        std.debug.print("[MIGRATION] Graph '{s}': {d} nodes, {d} edges\n", .{
            graph_name, handle.nodeCount(), handle.edgeCount(),
        });
    }

    // 4. Save registry
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    try reg.saveToFile(reg_path);

    // 5. Rename old file to .migrated
    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat", .{data_dir});
    defer allocator.free(legacy_path);
    const migrated_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat.migrated", .{data_dir});
    defer allocator.free(migrated_path);
    try std.fs.cwd().rename(legacy_path, migrated_path);

    std.debug.print("[MIGRATION] Complete: {d} graphs, {d} nodes, {d} edges\n", .{
        result.graphs_migrated, result.total_nodes, result.total_edges,
    });

    return result;
}

/// Handle interrupted migration by cleaning up partial state and retrying.
pub fn recoverInterruptedMigration(data_dir: []const u8, allocator: std.mem.Allocator) !MigrationResult {
    std.debug.print("\n[MIGRATION] Recovering from interrupted migration...\n", .{});

    // Delete partial registry and graphs directory
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    std.fs.cwd().deleteFile(reg_path) catch {};

    const graphs_dir = try std.fmt.allocPrint(allocator, "{s}/graphs", .{data_dir});
    defer allocator.free(graphs_dir);
    std.fs.cwd().deleteTree(graphs_dir) catch {};

    // Re-run migration
    return migrateToPerGraph(data_dir, allocator);
}
```

- [ ] **Step 2: Write migration unit tests**

Add tests for `detectStorageState` and `migrateToPerGraph` using temp directories.

- [ ] **Step 3: Integrate migration into server startup**

In `src/server/server_init.zig` (around line 223), BEFORE loading the graph store:

```zig
const migration = @import("../storage/migration.zig");
const storage_state = try migration.detectStorageState(data_dir, allocator);
switch (storage_state) {
    .legacy_monolithic => {
        _ = try migration.migrateToPerGraph(data_dir, allocator);
    },
    .interrupted => {
        _ = try migration.recoverInterruptedMigration(data_dir, allocator);
    },
    .per_graph, .fresh => {},
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`

- [ ] **Step 5: Commit**

```bash
git add src/storage/migration.zig src/server/server_init.zig
git commit -m "feat: add automatic migration from monolithic to per-graph storage"
```

---

## Chunk 5: Update Callers (Execution Layer)

### Task 6: Update getGlobalStore and data_dir propagation

**Files:**

- Modify: `src/graph_store.zig` (getGlobalStore, line 3716-3780)
- Modify: `src/server/main.zig` (line 329)

- [ ] **Step 1: Propagate data_dir into GraphStore during initialization**

In `getGlobalStore` (line 3716), after creating the global store:

```zig
global_store.?.data_dir = if (last_data_dir) |dir| dir else "";
```

Also set `use_per_graph_storage` based on whether the registry was loaded.

- [ ] **Step 2: Run tests**

- [ ] **Step 3: Commit**

```bash
git add src/graph_store.zig src/server/main.zig
git commit -m "fix: propagate data_dir into GraphStore for per-graph file paths"
```

---

### Task 7: Update execution layer to route through GraphHandles

**Files:**

- Modify: `src/execution/match_operations.zig` (line 365, 592, 1227, 1642, 3180)
- Modify: `src/execution/crud_operations.zig` (line 358, 565, 763, 1335, 1389, 1694, 1961, 2378)
- Modify: `src/execution/statement_dispatcher.zig` (line 790, 817, 921, 932)

This is the largest task. The key change: where callers currently do:

```zig
const store = graph_store.getGlobalStore(allocator);
// access store.nodes, store.edges directly
```

They should now do:

```zig
const store = graph_store.getGlobalStore(allocator);
const handle = store.getHandle(current_graph) orelse return error.GraphNotFound;
// access handle.nodes, handle.edges
```

**However**, during the transition phase (Task 4 Step 5), we populate the legacy flat maps from all graph handles. So existing callers will STILL WORK — they just won't benefit from per-graph isolation yet.

The priority callers to update are:

1. `match_operations.zig` — already has `filter_graph` variable, easy to route
2. `crud_operations.zig` — already passes `graph_name` for node/edge creation
3. `statement_dispatcher.zig` — CREATE/DROP GRAPH already graph-aware

- [ ] **Step 1: Update match_operations.zig to use GraphHandle for label lookups**

At each `getGlobalStore` call site, check if `use_per_graph_storage` and route through handle:

```zig
const store = graph_store.getGlobalStore(allocator);
if (store.use_per_graph_storage) {
    if (store.getHandle(filter_graph)) |handle| {
        // Use handle.getNodesByLabel(label) instead of store.getNodesByLabel(filter_graph, label)
    }
}
```

This is incremental — the fallback is the existing flat map path.

- [ ] **Step 2: Update crud_operations.zig mutations to mark correct handle as dirty**

When nodes/edges are created/deleted, mark the appropriate GraphHandle as dirty:

```zig
if (store.use_per_graph_storage) {
    if (store.getHandle(graph_name)) |handle| {
        try handle.nodes.put(node_id, node);
        handle.dirty = true;
    }
}
// Also put in legacy flat map (backward compat during transition)
try store.nodes.put(node_id, node);
store.dirty = true;
```

- [ ] **Step 3: Update statement_dispatcher.zig CREATE/DROP GRAPH**

CREATE GRAPH should create GraphHandle + write per-graph file.
DROP GRAPH should destroy handle + delete file.

In CREATE GRAPH (line 817), after `graph_store.createGraph()`:

```zig
if (store.use_per_graph_storage) {
    if (store.getHandle(graph_name)) |handle| {
        var uuid_str_buf: [36]u8 = undefined;
        const uuid_str = UuidV7.fromBytes(handle.uuid).toStringBuf(&uuid_str_buf) catch "";
        const file_path = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}.dat", .{ store.data_dir, uuid_str });
        defer allocator.free(file_path);
        try handle.saveToFile(file_path);
    }
}
```

In DROP GRAPH (line 932), before `graph_store.dropGraph()`:

```zig
if (store.use_per_graph_storage) {
    if (store.getHandle(graph_name)) |handle| {
        // Delete file
        var uuid_str_buf: [36]u8 = undefined;
        const uuid_str = UuidV7.fromBytes(handle.uuid).toStringBuf(&uuid_str_buf) catch "";
        const file_path = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}.dat", .{ store.data_dir, uuid_str });
        defer allocator.free(file_path);
        std.fs.cwd().deleteFile(file_path) catch {};
    }
}
```

- [ ] **Step 4: Run full test suite**

Run: `zig build test`
Expected: All tests pass. Per-graph storage is used transparently.

- [ ] **Step 5: Commit**

```bash
git add src/execution/match_operations.zig src/execution/crud_operations.zig src/execution/statement_dispatcher.zig
git commit -m "feat: route execution layer through per-graph GraphHandles"
```

---

## Chunk 6: WAL and Persistence Updates

### Task 8: Update WAL checkpoint for per-graph saves

**Files:**

- Modify: `src/wal.zig` (line 575-587, checkpoint function)

- [ ] **Step 1: Modify checkpoint to save only dirty graph files**

Current checkpoint calls `store.saveToFile()` which now routes to `savePerGraphFiles()` when in per-graph mode. This already works because of Task 4's changes. Verify this path works correctly.

The key remaining issue: WAL truncation must only remove records up to the checkpoint LSN. Since `savePerGraphFiles` saves ALL dirty handles in one pass, the current behavior (truncate after save) is still correct.

- [ ] **Step 2: Test checkpoint with per-graph storage**

Create a test that:

1. Creates nodes in two different graphs
2. Triggers WAL checkpoint
3. Verifies only dirty graph files were updated
4. Verifies WAL was truncated correctly

- [ ] **Step 3: Commit**

```bash
git add src/wal.zig
git commit -m "fix: verify WAL checkpoint works with per-graph persistence"
```

---

### Task 9: Update backup system

**Files:**

- Modify: `src/server/backup_manager.zig`
- Modify: `src/cli/backup_cli.zig`

- [ ] **Step 1: Update backup to include graphs/ directory**

The backup manager needs to archive:

- `graph_registry.dat`
- All files in `graphs/` directory
- `geode_catalog.dat`
- `geode_wal.log`

Instead of just `graph_store.dat`.

- [ ] **Step 2: Update restore to recreate per-graph layout**

- [ ] **Step 3: Commit**

```bash
git add src/server/backup_manager.zig src/cli/backup_cli.zig
git commit -m "feat: update backup/restore for per-graph storage layout"
```

---

## Chunk 7: Integration Tests

### Task 10: Geodetestlab integration tests

**Files:**

- Create: `../geode-test-harness/geodetestlab-cli/specs/per_graph_storage.yml`

- [ ] **Step 1: Create per-graph storage integration test spec**

```yaml
name: Per-Graph Storage Isolation
version: '1.0'

setup:
- |
  CREATE GRAPH test_graph_a;
  CREATE GRAPH test_graph_b;

tests:
- name: 'Data isolation - graph A data not visible in graph B'
  query: |
    USE GRAPH test_graph_a;
    CREATE (:IsolationTest {id: 'a1', source: 'graph_a'});
    USE GRAPH test_graph_b;
    MATCH (n:IsolationTest) RETURN count(n) AS cnt
  expect:
    row_count: 1
    contains:
      cnt: 0

- name: 'Data in graph A is accessible'
  query: |
    USE GRAPH test_graph_a;
    MATCH (n:IsolationTest) RETURN n.source AS source
  expect:
    row_count: 1
    contains:
      source: graph_a

- name: 'CREATE and query in same graph'
  query: |
    USE GRAPH test_graph_b;
    CREATE (:IsolationTest {id: 'b1', source: 'graph_b'});
    MATCH (n:IsolationTest) RETURN n.source AS source
  expect:
    row_count: 1
    contains:
      source: graph_b

- name: 'DROP GRAPH removes data'
  query: |
    DROP GRAPH test_graph_b;
    CREATE GRAPH test_graph_b;
    USE GRAPH test_graph_b;
    MATCH (n:IsolationTest) RETURN count(n) AS cnt
  expect:
    row_count: 1
    contains:
      cnt: 0

teardown:
- |
  DROP GRAPH IF EXISTS test_graph_a;
  DROP GRAPH IF EXISTS test_graph_b;
```

- [ ] **Step 2: Create persistence test spec**

```yaml
name: Per-Graph Persistence
version: '1.0'

setup:
- |
  CREATE GRAPH persist_test;
  USE GRAPH persist_test;
  CREATE (:PersistNode {id: 'p1', value: 'survives_restart'});

tests:
- name: 'Data persists after creation'
  query: |
    USE GRAPH persist_test;
    MATCH (n:PersistNode) RETURN n.value AS val
  expect:
    row_count: 1
    contains:
      val: survives_restart

teardown:
- |
  DROP GRAPH IF EXISTS persist_test;
```

- [ ] **Step 3: Run integration tests**

Run: `python3 ../geode-test-harness/geodetestlab-cli/geodetestlab.py --spec ../geode-test-harness/geodetestlab-cli/specs/per_graph_storage.yml`

- [ ] **Step 4: Commit test specs**

```bash
cd ../geode-test-harness && git add geodetestlab-cli/specs/per_graph_storage.yml geodetestlab-cli/specs/per_graph_persistence.yml
git commit -m "test: add per-graph storage isolation and persistence specs"
```

---

### Task 11: Update existing test files

**Files:**

- Modify: All test files in `tests/` that call `getGlobalStore` (13 files, ~45 call sites)

These tests use the in-process GraphStore directly. They should continue to work unchanged because the legacy flat maps are still populated during the transition. Run the full test suite to verify.

- [ ] **Step 1: Run full unit test suite**

Run: `zig build test`
Expected: All 1688+ tests pass

- [ ] **Step 2: Run full geodetestlab suite**

Run: `python3 ../geode-test-harness/geodetestlab-cli/geodetestlab.py --specs ../geode-test-harness/geodetestlab-cli/specs/`
Expected: 97%+ pass rate maintained

- [ ] **Step 3: Fix any failures**

If tests fail, investigate and fix. Common issues:

- File path resolution (data_dir not set in test context)
- Missing graphs/ directory in test temp dirs
- Serialization format differences

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "test: verify all existing tests pass with per-graph storage"
```

---

## Chunk 8: Cleanup and Polish

### Task 12: Remove legacy flat map duplication

**Files:**

- Modify: `src/graph_store.zig`

Once all callers are routed through GraphHandles, remove the dual-write to legacy flat maps. This is a follow-up optimization — the initial implementation keeps backward compat.

- [ ] **Step 1: Audit remaining callers that access `store.nodes`/`store.edges` directly**
- [ ] **Step 2: Update remaining callers to use `getHandle()`**
- [ ] **Step 3: Remove dual-write in `loadPerGraphFiles`**
- [ ] **Step 4: Run full test suite**
- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: remove legacy flat map duplication, all callers use GraphHandle"
```

---

### Task 13: Tag release

- [ ] **Step 1: Push all changes**

```bash
git push origin main
```

- [ ] **Step 2: Tag release**

```bash
git tag -a v0.1.28 -m "feat: per-graph storage split with auto-migration"
git push origin v0.1.28
```

- [ ] **Step 3: Rebuild and install**

```bash
make release
sudo systemctl stop geode
sudo cp zig-out/bin/geode /usr/bin/geode
sudo systemctl start geode
```

- [ ] **Step 4: Verify migration on system server**

Check journal logs for migration output. Verify per-graph files exist:

```bash
sudo ls -la /var/lib/geode/graphs/
sudo cat /var/lib/geode/graph_registry.dat | hexdump -C | head -5
```
