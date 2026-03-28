# Complete Storage Engine Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy `graph_store.zig` (4000+ lines, in-memory HashMap + `graph_store.dat`) with the per-graph storage engine as the sole source of truth, rewriting all 652 references across 52 files.

**Architecture:** New `graph_store.zig` is a complete rewrite providing the same type names (`Node`, `Edge`, `PropertyValue`, `GraphStore`) backed by `StorageAdapter` → `GraphEngine` per-graph files. UUIDv7 IDs externally, dense slot IDs internally via persistent `id_map.dat`. Engine-aware LRU caching for pointer stability. Native lazy iterators for edge traversal.

**Tech Stack:** Zig 0.15.1, graph_storage engine library (in `docker/zig-packages/`), QUIC transport, protobuf serialization

**Spec:** `docs/superpowers/specs/2026-03-28-storage-engine-complete-migration.md`

---

## File Map

### New Files

| File | Purpose |
|------|---------|
| `src/storage/id_map.zig` | Persistent bidirectional UUIDv7 ↔ engine slot mapping |
| `src/graph_store.zig` (complete rewrite) | Cache + API over StorageAdapter, replaces 4178-line legacy file |

### Enhanced Files

| File | Changes |
|------|---------|
| `src/storage/graph_storage_adapter.zig` | Edge properties, full iteration, stats API, native iterators |

### Consumer Updates (52 files)

All files importing `graph_store` continue to work because we keep the same module name and type names (`Node`, `Edge`, `PropertyValue`, `GraphStore`). The internal implementation changes completely.

Key files requiring logic changes (not just import compatibility):

- `src/execution/match_operations.zig` — 72+ direct HashMap accesses → API calls
- `src/execution/graph_algorithms.zig` — 20+ replacements
- `src/execution/crud_operations.zig` — write paths + ID generation
- `src/execution/aggregation_evaluation.zig` — 11+ replacements
- `src/execution/centrality_algorithms.zig` — adjacency access
- `src/execution/recursion_handler.zig` — edge iteration
- `src/execution/statement_dispatcher.zig` — graph registry
- `src/ml/integration_enhanced.zig` — 13 adjacency replacements
- `src/server/server_init.zig` — initialization flow
- `src/wal.zig` — persistence hooks
- `src/schema/catalog.zig` — graph registry
- `src/planner/cbo.zig` — statistics provider
- `src/value_types.zig` — Node/Edge pointer types

---

## Task 1: Create ID Map Module

**Files:**

- Create: `src/storage/id_map.zig`

This module provides persistent bidirectional mapping between UUIDv7 external IDs and dense engine slot IDs. It is self-contained with no dependencies on GraphStore.

- [ ] **Step 1: Create `src/storage/id_map.zig` with core struct and operations**

The ID map needs:

- `HashMap(u64, u64)` for uuid→slot and slot→uuid
- Atomic write to `id_map.dat` via temp+rename
- Load from `id_map.dat` on startup
- UUIDv7 generation using timestamp + atomic counter

```zig
// src/storage/id_map.zig
// Persistent bidirectional UUIDv7 <-> engine slot ID mapping.
//
// Each graph maintains its own IdMap persisted to graphs/<uuid>/id_map.dat.
// Format: 32-byte header + 16-byte entries (uuid7 u64 + slot u64).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAGIC = "GIDM".*;
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 32;
pub const ENTRY_SIZE: usize = 16;

pub const IdMap = struct {
    allocator: Allocator,
    uuid_to_slot: std.AutoHashMap(u64, u64),
    slot_to_uuid: std.AutoHashMap(u64, u64),
    edge_uuid_to_slot: std.AutoHashMap(u64, u64),
    edge_slot_to_uuid: std.AutoHashMap(u64, u64),
    dirty: bool = false,

    pub fn init(allocator: Allocator) IdMap {
        return .{
            .allocator = allocator,
            .uuid_to_slot = std.AutoHashMap(u64, u64).init(allocator),
            .slot_to_uuid = std.AutoHashMap(u64, u64).init(allocator),
            .edge_uuid_to_slot = std.AutoHashMap(u64, u64).init(allocator),
            .edge_slot_to_uuid = std.AutoHashMap(u64, u64).init(allocator),
        };
    }

    pub fn deinit(self: *IdMap) void {
        self.uuid_to_slot.deinit();
        self.slot_to_uuid.deinit();
        self.edge_uuid_to_slot.deinit();
        self.edge_slot_to_uuid.deinit();
    }

    pub fn putNode(self: *IdMap, uuid7: u64, slot_id: u64) !void {
        try self.uuid_to_slot.put(uuid7, slot_id);
        try self.slot_to_uuid.put(slot_id, uuid7);
        self.dirty = true;
    }

    pub fn putEdge(self: *IdMap, uuid7: u64, engine_edge_id: u64) !void {
        try self.edge_uuid_to_slot.put(uuid7, engine_edge_id);
        try self.edge_slot_to_uuid.put(engine_edge_id, uuid7);
        self.dirty = true;
    }

    pub fn removeNode(self: *IdMap, uuid7: u64) void {
        if (self.uuid_to_slot.fetchRemove(uuid7)) |kv| {
            _ = self.slot_to_uuid.remove(kv.value);
        }
        self.dirty = true;
    }

    pub fn removeEdge(self: *IdMap, uuid7: u64) void {
        if (self.edge_uuid_to_slot.fetchRemove(uuid7)) |kv| {
            _ = self.edge_slot_to_uuid.remove(kv.value);
        }
        self.dirty = true;
    }

    pub fn nodeSlot(self: *const IdMap, uuid7: u64) ?u64 {
        return self.uuid_to_slot.get(uuid7);
    }

    pub fn nodeUuid(self: *const IdMap, slot_id: u64) ?u64 {
        return self.slot_to_uuid.get(slot_id);
    }

    pub fn edgeSlot(self: *const IdMap, uuid7: u64) ?u64 {
        return self.edge_uuid_to_slot.get(uuid7);
    }

    pub fn edgeUuid(self: *const IdMap, engine_edge_id: u64) ?u64 {
        return self.edge_slot_to_uuid.get(engine_edge_id);
    }

    pub fn nodeCount(self: *const IdMap) u64 {
        return self.uuid_to_slot.count();
    }

    pub fn edgeCount(self: *const IdMap) u64 {
        return self.edge_uuid_to_slot.count();
    }

    /// Save to file atomically (write to .tmp then rename).
    pub fn saveToDisk(self: *const IdMap, dir_path: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/id_map.dat", .{dir_path});
        defer self.allocator.free(path);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/id_map.dat.tmp", .{dir_path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        const writer = file.writer(&buf);

        // Header
        try writer.writeAll(&MAGIC);
        try writer.writeInt(u32, VERSION, .little);
        try writer.writeInt(u64, self.uuid_to_slot.count(), .little);
        try writer.writeInt(u64, self.edge_uuid_to_slot.count(), .little);
        try writer.writeInt(u32, 0, .little); // reserved/crc placeholder

        // Node entries
        var node_it = self.uuid_to_slot.iterator();
        while (node_it.next()) |entry| {
            try writer.writeInt(u64, entry.key_ptr.*, .little);
            try writer.writeInt(u64, entry.value_ptr.*, .little);
        }

        // Edge entries
        var edge_it = self.edge_uuid_to_slot.iterator();
        while (edge_it.next()) |entry| {
            try writer.writeInt(u64, entry.key_ptr.*, .little);
            try writer.writeInt(u64, entry.value_ptr.*, .little);
        }

        try file.sync();
        try std.fs.cwd().rename(tmp_path, path);
    }

    /// Load from disk. Returns error if file doesn't exist or is corrupt.
    pub fn loadFromDisk(allocator: Allocator, dir_path: []const u8) !IdMap {
        const path = try std.fmt.allocPrint(allocator, "{s}/id_map.dat", .{dir_path});
        defer allocator.free(path);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        const reader = file.reader(&read_buf);

        // Read and validate header
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;

        const version = try reader.readInt(u32, .little);
        if (version != VERSION) return error.UnsupportedVersion;

        const node_count = try reader.readInt(u64, .little);
        const edge_count = try reader.readInt(u64, .little);
        _ = try reader.readInt(u32, .little); // reserved

        var map = IdMap.init(allocator);
        errdefer map.deinit();

        // Read node entries
        var i: u64 = 0;
        while (i < node_count) : (i += 1) {
            const uuid7 = try reader.readInt(u64, .little);
            const slot_id = try reader.readInt(u64, .little);
            try map.uuid_to_slot.put(uuid7, slot_id);
            try map.slot_to_uuid.put(slot_id, uuid7);
        }

        // Read edge entries
        i = 0;
        while (i < edge_count) : (i += 1) {
            const uuid7 = try reader.readInt(u64, .little);
            const engine_id = try reader.readInt(u64, .little);
            try map.edge_uuid_to_slot.put(uuid7, engine_id);
            try map.edge_slot_to_uuid.put(engine_id, uuid7);
        }

        map.dirty = false;
        return map;
    }
};

/// Generate a UUIDv7-style time-based unique ID.
/// 48-bit millisecond timestamp | 16-bit atomic counter.
pub fn generateUuidV7() u64 {
    const State = struct {
        var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    };
    const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
    const counter_val = State.counter.fetchAdd(1, .monotonic);
    return (timestamp_ms << 16) | @as(u64, @as(u16, @truncate(counter_val)));
}

// Tests
test "IdMap put and lookup" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    try map.putNode(0xAABB, 0);
    try map.putNode(0xCCDD, 1);
    try std.testing.expectEqual(@as(u64, 0), map.nodeSlot(0xAABB).?);
    try std.testing.expectEqual(@as(u64, 0xAABB), map.nodeUuid(0).?);
    try std.testing.expect(map.nodeSlot(0x9999) == null);
}

test "IdMap remove" {
    var map = IdMap.init(std.testing.allocator);
    defer map.deinit();

    try map.putNode(0xAABB, 0);
    map.removeNode(0xAABB);
    try std.testing.expect(map.nodeSlot(0xAABB) == null);
    try std.testing.expect(map.nodeUuid(0) == null);
}

test "generateUuidV7 is unique" {
    const a = generateUuidV7();
    const b = generateUuidV7();
    try std.testing.expect(a != b);
}
```

- [ ] **Step 2: Run tests to verify IdMap works**

Run: `zig build test --filter "IdMap" 2>&1 | tail -20`
Expected: All IdMap tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/storage/id_map.zig
git commit -m "feat: add persistent UUIDv7 ID map module"
```

---

## Task 2: Enhance StorageAdapter

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig`

Add edge property support, full node/edge iteration, statistics API, and expose native iterators that the new GraphStore will use.

- [ ] **Step 1: Add edge property methods to StorageAdapter**

Add after the existing `removeNodeProperty` method (around line 455):

```zig
    /// Set a property on an edge.
    pub fn setEdgeProperty(self: *StorageAdapter, graph_name: []const u8, from_slot: u64, to_slot: u64, edge_id: u64, key: []const u8, value: graph_store_mod.PropertyValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        // Find the edge in the outgoing adjacency list to get its prop_head
        var iter = try mg.engine.expandOut(from_slot, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.edge_id == edge_id) {
                const storage_val = toStorageProperty(value);
                const new_prop_head = try mg.engine.putProperty(entry.prop_head, key, storage_val);
                if (new_prop_head != entry.prop_head) {
                    // Update the edge entry's prop_head in the adjacency store
                    try mg.engine.updateEdgePropHead(from_slot, edge_id, new_prop_head);
                }
                return;
            }
        }
        return error.EdgeNotFound;
    }

    /// Get a property from an edge.
    pub fn getEdgeProperty(self: *StorageAdapter, graph_name: []const u8, from_slot: u64, edge_id: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        var iter = try mg.engine.expandOut(from_slot, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.edge_id == edge_id) {
                if (entry.prop_head == 0) return null;
                return mg.engine.getProperty(entry.prop_head, key, allocator);
            }
        }
        return error.EdgeNotFound;
    }
```

- [ ] **Step 2: Add full node iteration via engine scan**

Add a method that uses the engine's `NodeStore.scanAll` callback:

```zig
    /// Iterate all nodes in a graph via engine callback.
    /// Returns arrays of (slot_id, NodeRec) pairs.
    pub fn scanAllNodes(self: *StorageAdapter, graph_name: []const u8, allocator: Allocator) ![]ScanEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return error.GraphNotFound;
        var result = std.ArrayList(ScanEntry).init(allocator);
        errdefer result.deinit();

        mg.engine.node_store.scanAll(&result, struct {
            fn callback(ctx: *std.ArrayList(ScanEntry), node_id: gs.NodeId, rec: gs.node.NodeRec) void {
                ctx.append(ctx.allocator, .{ .slot_id = node_id, .rec = rec }) catch {};
            }
        }.callback);

        return result.toOwnedSlice(allocator);
    }

    pub const ScanEntry = struct {
        slot_id: u64,
        rec: gs.node.NodeRec,
    };
```

- [ ] **Step 3: Add statistics API**

```zig
    pub const GraphStats = struct {
        node_count: u64,
        edge_count: u64,
        pages_used: u64,
        label_count: u32,
    };

    pub fn getGraphStats(self: *StorageAdapter, graph_name: []const u8) ?GraphStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const mg = self.engines.get(graph_name) orelse return null;
        return GraphStats{
            .node_count = mg.engine.nodeCount(),
            .edge_count = mg.engine.edgeCount(),
            .pages_used = mg.engine.manifest.nodes_pages +
                mg.engine.manifest.adj_out_pages +
                mg.engine.manifest.adj_in_pages +
                mg.engine.manifest.props_pages +
                mg.engine.manifest.var_store_pages,
            .label_count = @intCast(mg.label_dict.count()),
        };
    }
```

- [ ] **Step 4: Run `zig build test` to ensure compilation**

Run: `zig build test 2>&1 | tail -20`
Expected: Compiles. Some tests may fail due to existing issues — that's OK at this stage.

- [ ] **Step 5: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat: enhance StorageAdapter with edge props, iteration, stats"
```

---

## Task 3: Rewrite graph_store.zig — Types and Core Cache

**Files:**

- Rewrite: `src/graph_store.zig` (delete old content, write new)

This is the largest task. The new file keeps the same module-level type names (`Node`, `Edge`, `PropertyValue`, `GraphStore`) so that all 52 importing files continue to compile with minimal changes.

**CRITICAL:** Before rewriting, back up the old file for reference during consumer migration.

- [ ] **Step 1: Back up old graph_store.zig**

```bash
cp src/graph_store.zig src/graph_store_legacy_backup.zig.bak
```

- [ ] **Step 2: Write new graph_store.zig — types, constants, imports**

Replace the entire file. Start with types that must match the old signatures exactly:

Read the old file's Node, Edge, PropertyValue, Path, PathOptions, ExpandOptions, PathFilter, MutationOp, and all WAL hook types. The new file must export identical types.

Write the new `src/graph_store.zig` with:

1. Same type definitions (Node, Edge, PropertyValue, etc.) — field-compatible
2. New GraphStore struct backed by StorageAdapter + IdMap + caches
3. Same global singleton pattern (getGlobalStore, etc.)
4. Same locking API (acquireStoreLock, etc.)
5. Same WAL hooks and mutation notification interfaces
6. All persistence replaced with adapter.checkpointAll()

The file should be structured as:

- **Section 1:** Imports and constants
- **Section 2:** Public types (Node, Edge, PropertyValue, Path*, MutationOp, etc.)
- **Section 3:** GraphStore struct definition with cache fields
- **Section 4:** GraphStore methods — lifecycle (init, deinit)
- **Section 5:** GraphStore methods — graph management (createGraph, dropGraph, etc.)
- **Section 6:** GraphStore methods — node CRUD
- **Section 7:** GraphStore methods — edge CRUD
- **Section 8:** GraphStore methods — properties
- **Section 9:** GraphStore methods — labels
- **Section 10:** GraphStore methods — traversal and paths
- **Section 11:** GraphStore methods — queries and counts
- **Section 12:** Global singleton, locking, persistence thread, WAL hooks
- **Section 13:** UUIDv7 generation (moved from old file, uses id_map.generateUuidV7)

Key design points for the implementation:

- `nodes: std.AutoHashMap(u64, Node)` — keyed by UUIDv7, values are full Node structs for pointer stability
- `edges: std.AutoHashMap(u64, Edge)` — keyed by UUIDv7
- `outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64))` — node UUIDv7 → edge UUIDv7s
- `incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64))` — same
- `label_index: std.StringHashMap(std.ArrayList(u64))` — label → node UUIDv7s
- `graphs: std.StringHashMap(void)` — graph registry
- `adapter: *StorageAdapter` — per-graph engine backend
- `id_maps: std.StringHashMap(*IdMap)` — per-graph ID mappings

Every mutation method:

1. Generates UUIDv7 for new entities
2. Translates to engine slot ID via IdMap
3. Calls StorageAdapter method
4. Updates in-memory cache
5. Fires mutation notification if set

Every read method:

1. Checks cache first (HashMap lookup)
2. If cache miss, reads from engine via adapter, populates cache
3. Returns pointer to cached entry (pointer stability)

Startup flow:

1. Open adapter (loads graph engines from per-graph directories)
2. For each graph: load IdMap from `id_map.dat` (or create empty if fresh)
3. Populate caches by scanning engine nodes/edges via adapter
4. Ready for queries

Persistence flow (background thread):

1. Every 1 second: `adapter.checkpointAll()` (flushes buffer pool pages)
2. Save dirty IdMaps to `id_map.dat`
3. No `graph_store.dat` serialization

The agent implementing this task should:

- Read `src/graph_store_legacy_backup.zig.bak` for exact type definitions and method signatures
- Read `src/storage/graph_storage_adapter.zig` for available adapter methods
- Read `src/storage/id_map.zig` for IdMap API
- Ensure every public method from the old GraphStore exists in the new one (same name, compatible signature)
- NoSave variants should still exist but can simply delegate to the normal variant (engine handles persistence)

- [ ] **Step 3: Verify compilation**

Run: `zig build test 2>&1 | head -50`

Fix any compilation errors iteratively. The goal is that all existing files that import graph_store still compile.

- [ ] **Step 4: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat: rewrite graph_store.zig with engine-backed storage + UUIDv7"
```

---

## Task 4: Update Execution Engine — CRUD Operations

**Files:**

- Modify: `src/execution/crud_operations.zig`

This file has 173 references to graph_store types, primarily PropertyValue conversions in CREATE/SET operations. Most PropertyValue usage continues to work unchanged since we kept the same type. The key changes are:

- `store.nodes.getPtr(id)` → `store.getNodePtr(id)` (if old method removed) or use the new cache's HashMap
- Write operations go through store methods (which write-through to engine)

- [ ] **Step 1: Update all direct HashMap accesses in crud_operations.zig**

The agent should:

1. Read the file and find every `store.nodes.getPtr(`, `store.nodes.get(`, `store.edges.getPtr(`, `store.edges.get(` call
2. These should work unchanged if the new GraphStore exposes the same `nodes` and `edges` fields (which it does — they're still AutoHashMaps in the cache)
3. Find every `store.outgoing_edges.get(` and `store.incoming_edges.get(` — same story
4. Verify createNodeWithGraph, createEdgeWithGraph, setNodeProperty, etc. are called through the store methods (not bypassed)
5. Test compile

- [ ] **Step 2: Verify compilation and run unit tests**

Run: `zig build test 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add src/execution/crud_operations.zig
git commit -m "refactor: update crud_operations for new storage engine"
```

---

## Task 5: Update Execution Engine — Match Operations

**Files:**

- Modify: `src/execution/match_operations.zig`

This is the highest-impact file with 72+ direct HashMap accesses. Key changes:

- All `store.nodes.getPtr(id)` → works via cache (same field name)
- All `store.nodes.iterator()` → works via cache
- `store.getEdgesFrom(id)` → still works (method exists on new GraphStore)
- `store.getEdgesTo(id)` → still works
- `store.getNodesByLabels(graph, labels)` → still works

The agent should verify every access pattern compiles and test.

- [ ] **Step 1: Audit and fix all direct accesses**

The agent should:

1. Read the full file
2. Check every `store.` reference still compiles against the new GraphStore
3. Fix any incompatibilities
4. Pay special attention to lines 5132-5154 (variable-length path execution) which directly accesses `store.incoming_edges` and `store.outgoing_edges`

- [ ] **Step 2: Verify compilation**

Run: `zig build test 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "refactor: update match_operations for new storage engine"
```

---

## Task 6: Update Execution Engine — Algorithms and Aggregation

**Files:**

- Modify: `src/execution/graph_algorithms.zig`
- Modify: `src/execution/aggregation_evaluation.zig`
- Modify: `src/execution/recursion_handler.zig`
- Modify: `src/execution/centrality_algorithms.zig`
- Modify: `src/execution/statement_dispatcher.zig`
- Modify: `src/execution/statement_handlers.zig`
- Modify: `src/graph/builtin_algorithms.zig`

Same pattern as Tasks 4-5. Verify all `store.` accesses compile against new GraphStore.

- [ ] **Step 1: Update graph_algorithms.zig** (20+ accesses)

All `store.nodes.iterator()`, `store.edges.iterator()`, `store.nodes.get/getPtr()` — verify against new cache fields.

- [ ] **Step 2: Update aggregation_evaluation.zig** (11+ accesses)

Node iteration for COUNT, COLLECT, MIN, MAX, GROUP BY.

- [ ] **Step 3: Update recursion_handler.zig** (5 accesses)

Edge iteration for recursive closure computation.

- [ ] **Step 4: Update centrality_algorithms.zig**

Adjacency access via `store.getOutgoingEdgeIds()`, `store.getIncomingEdgeIds()`.

- [ ] **Step 5: Update statement_dispatcher.zig** (7 accesses)

Graph registry: `store.graphs.contains()` → `store.graphExists()` if graphs field removed, or keep as-is if cache exposes `graphs` field.

- [ ] **Step 6: Update remaining execution files**

`statement_handlers.zig`, `builtin_algorithms.zig` — same verification pattern.

- [ ] **Step 7: Verify compilation**

Run: `zig build test 2>&1 | tail -20`

- [ ] **Step 8: Commit**

```bash
git add src/execution/ src/graph/
git commit -m "refactor: update algorithms and execution for new storage engine"
```

---

## Task 7: Update Server, WAL, Security, and Planner

**Files:**

- Modify: `src/server/server_init.zig` — initialization flow
- Modify: `src/server/quic_connection_handler.zig` — imports
- Modify: `src/wal.zig` — persistence hooks
- Modify: `src/schema/catalog.zig` — graph registry
- Modify: `src/server/rls_filter.zig` — Value.Node access
- Modify: `src/server/proto_util.zig` — Node/Edge serialization
- Modify: `src/transport/grpc_server.zig` — getGlobalStore calls
- Modify: `src/planner/cbo.zig` — statistics provider
- Modify: `src/server/query_plan_cache.zig` — StoreStats

- [ ] **Step 1: Update server_init.zig**

Replace initialization flow:

- Remove: `graph_store.initGlobalAdapter()` call (adapter is now internal to GraphStore)
- Remove: migration detection code
- Change: `getGlobalStore(allocator)` now initializes the engine-backed store
- The new GraphStore's `initGlobalStore(allocator, data_dir)` handles adapter creation internally

```zig
// In server_init.zig, replace the old initialization block with:
if (data_dir) |dir| {
    _ = try graph_store.initGlobalStore(allocator, dir);
}
const store = graph_store.getGlobalStore(allocator);
```

- [ ] **Step 2: Update wal.zig**

The WAL hooks (`setWalPersistenceHooks`) should still work. The checkpoint callback now calls `store.checkpoint()` which calls `adapter.checkpointAll()` internally. Verify the hook function signatures match.

- [ ] **Step 3: Update catalog.zig**

Graph registry operations:

- `catalog.graphs.put(name, {})` → Should use store.createGraph() or keep the catalog's own registry
- Verify catalog serialization still works (geode_catalog.dat is separate from graph_store.dat)

- [ ] **Step 4: Wire planner statistics**

In `src/planner/cbo.zig`, add an implementation of `StorageStatsProvider` that reads from the new GraphStore's stats:

```zig
// In cbo.zig, add after the StorageStatsProvider definition:
pub fn createEngineStatsProvider(store: *@import("graph_store.zig").GraphStore) StorageStatsProvider {
    const Dispatch = struct {
        fn getRowCount(ctx: *anyopaque, table: []const u8) u64 {
            const s = @as(*@import("graph_store.zig").GraphStore, @ptrCast(@alignCast(ctx)));
            return s.getNodeCountForGraph(table);
        }
        // ... other vtable methods
    };
    return StorageStatsProvider{
        .ctx = @ptrCast(store),
        .vtable = &.{
            .getRowCount = &Dispatch.getRowCount,
            // ...
        },
    };
}
```

- [ ] **Step 5: Update query_plan_cache.zig StoreStats**

The `StoreStats` struct should pull from GraphStore's real engine stats instead of hardcoded zeros.

- [ ] **Step 6: Update all remaining server files**

`quic_connection_handler.zig`, `rls_filter.zig`, `proto_util.zig`, `grpc_server.zig` — verify imports and `getGlobalStore()` calls compile.

- [ ] **Step 7: Verify compilation**

Run: `zig build test 2>&1 | tail -20`

- [ ] **Step 8: Commit**

```bash
git add src/server/ src/wal.zig src/schema/ src/planner/ src/transport/
git commit -m "refactor: update server, WAL, planner for new storage engine"
```

---

## Task 8: Update Remaining Files

**Files:**

- Modify: `src/value_types.zig` — Node/Edge imports
- Modify: `src/eval.zig` — edge iteration
- Modify: `src/eval/call_handlers.zig` — function calls
- Modify: `src/execution/pattern_helpers.zig` — property conversion
- Modify: `src/execution/return_and_sorting.zig` — result handling
- Modify: `src/execution/value_utilities.zig` — value operations
- Modify: `src/execution/result_utils.zig` — result formatting
- Modify: `src/ml/integration_enhanced.zig` — adjacency access
- Modify: `src/temporal/time_travel.zig` — snapshot access
- Modify: `src/exec.zig` — execution handling
- Modify: `src/security/` files — auth, RLS
- Modify: `src/storage/backup.zig` — backup/restore
- Modify: `src/fuzz/graphstore_durability_fuzz.zig` — fuzzing
- Modify: Any remaining files referencing graph_store

- [ ] **Step 1: Update value_types.zig**

The `Value` union imports `@import("graph_store.zig").Node` and `@import("graph_store.zig").Edge`. Since we kept the same type names and module name, this should compile without changes. Verify.

- [ ] **Step 2: Update eval.zig and eval/call_handlers.zig**

Edge iteration patterns (`store.edges.iterator()`). Verify they work with the new cache's edges HashMap.

- [ ] **Step 3: Update ml/integration_enhanced.zig**

13 adjacency accesses (`self.graph.outgoing_edges.get()`, etc.). If the new GraphStore still has `outgoing_edges` and `incoming_edges` as public fields, these work unchanged. If not, provide accessor methods.

- [ ] **Step 4: Update storage/backup.zig**

Remove legacy `readGraphStorePayload()` fallback. Backup should only read from per-graph layout.

- [ ] **Step 5: Update all remaining files**

Sweep all 52 files that import graph_store. The agent should:

1. `grep -rn '@import("graph_store' src/` to find all import sites
2. `grep -rn '@import("../graph_store' src/` for relative imports
3. Verify each compiles
4. Fix any breakage

- [ ] **Step 6: Delete legacy backup**

```bash
rm src/graph_store_legacy_backup.zig.bak
```

- [ ] **Step 7: Delete migration.zig**

```bash
rm src/storage/migration.zig
```

Update any files that import migration.zig.

- [ ] **Step 8: Verify full compilation**

Run: `zig build test 2>&1 | tail -30`
Expected: Clean compilation. Tests may still have failures — that's addressed in Task 9.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: update all remaining files for new storage engine"
```

---

## Task 9: Fix Unit Tests

**Files:**

- Modify: Various test files across `src/`
- Modify: `src/graph_store.zig` (fix issues found during testing)

- [ ] **Step 1: Run full unit test suite and collect failures**

Run: `zig build test 2>&1 | tee /tmp/test_output.txt | tail -50`

- [ ] **Step 2: Fix test failures iteratively**

For each failure:

1. Read the error message
2. Identify whether it's a compilation error (missing method, wrong type) or logic error
3. Fix in the appropriate file
4. Re-run affected tests

Common expected issues:

- Methods with slightly different signatures (e.g., return type changes)
- Missing NoSave variants
- Path algorithm methods that need engine-backed implementation
- Fuzz test expectations that assumed graph_store.dat format

- [ ] **Step 3: Run full test suite again**

Run: `zig build test 2>&1 | tail -20`
Expected: All unit tests pass.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix: resolve unit test failures after storage migration"
```

---

## Task 10: Build and Smoke Test

**Files:**

- None (verification only)

- [ ] **Step 1: Build debug binary**

Run: `make build 2>&1 | tail -20`
Expected: Successful build.

- [ ] **Step 2: Start server and verify basic operations**

Run:

```bash
rm -rf /tmp/geode_test_data
./zig-out/bin/geode serve --listen 0.0.0.0:3141 --data-dir /tmp/geode_test_data &
sleep 2
./zig-out/bin/geode query "CREATE (:Person {name: 'Alice', age: 30})" --insecure --user geode --pass "$(cat /tmp/geode_test_data/.geode_hmac_key 2>/dev/null || echo test)"
./zig-out/bin/geode query "MATCH (n:Person) RETURN n.name, n.age" --insecure --user geode --pass "$(cat /tmp/geode_test_data/.geode_hmac_key 2>/dev/null || echo test)"
kill %1
```

Verify:

- Server starts without errors
- CREATE succeeds
- MATCH returns the created node with correct properties
- Per-graph directory created in `/tmp/geode_test_data/graphs/`
- `id_map.dat` exists in the graph directory
- No `graph_store.dat` exists

- [ ] **Step 3: Verify per-graph files**

```bash
ls -la /tmp/geode_test_data/graphs/*/
```

Expected: Each graph directory has `nodes.store`, `adj_*.store`, `props.store`, `var.store`, `manifest.*`, `wal/`, and `id_map.dat`.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve smoke test issues"
```

---

## Task 11: Geodetestlab Full Suite

**Files:**

- Modify: Various files to fix test failures

- [ ] **Step 1: Run full geodetestlab suite**

```bash
cd ../geode-test-harness
GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode make test 2>&1 | tee /tmp/geodetestlab_output.txt | tail -50
```

- [ ] **Step 2: Analyze failures**

```bash
grep -c "FAIL\|PASS" /tmp/geodetestlab_output.txt
grep "FAIL" /tmp/geodetestlab_output.txt | head -30
```

- [ ] **Step 3: Fix failures iteratively**

For each failing spec:

1. Run the specific spec: `make test-spec SPEC=geodetestlab-cli/specs/<name>.yml`
2. Read the failure output
3. Identify root cause (missing feature, wrong behavior, timing issue)
4. Fix in geode source code
5. Rebuild: `cd ../geode && make build`
6. Re-run the spec

Common expected issues:

- UUIDv7 IDs are different format than old time-based IDs (test assertions on ID format)
- Edge property operations not fully wired
- Path algorithms returning different ordering
- Graph isolation behavior changes
- Timing issues (engine checkpoint vs immediate visibility)

- [ ] **Step 4: Run full suite again**

```bash
cd ../geode-test-harness
GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode make test 2>&1 | tail -20
```

Target: **100% pass rate** (all 3844 tests pass).

- [ ] **Step 5: Commit all fixes**

```bash
cd ../geode
git add -A
git commit -m "fix: achieve 100% geodetestlab pass rate with new storage engine"
```

---

## Task 12: Cleanup and Final Verification

**Files:**

- Delete: `src/storage/migration.zig` (if not already deleted)
- Delete: Any remaining legacy references

- [ ] **Step 1: Verify no graph_store.dat references remain**

```bash
grep -rn "graph_store\.dat" src/ | grep -v ".bak" | grep -v "test" | grep -v "legacy"
```

Expected: Zero results (or only in docs/comments).

- [ ] **Step 2: Verify no dual-write code remains**

```bash
grep -rn "dual-write\|dual_write\|global_vtable" src/
```

Expected: Zero results.

- [ ] **Step 3: Run full unit test suite one final time**

Run: `zig build test 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 4: Run full geodetestlab suite one final time**

```bash
cd ../geode-test-harness
GEODE_BINARY=$(pwd)/../geode/zig-out/bin/geode make test 2>&1 | tail -20
```

Expected: 100% pass rate.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: cleanup legacy storage references"
```

---

## Dependency Graph

```
Task 1 (IdMap)  ──────────────┐
                               ├──→ Task 3 (Rewrite graph_store.zig)
Task 2 (StorageAdapter)  ─────┘           │
                                          ├──→ Task 4 (crud_operations)
                                          ├──→ Task 5 (match_operations)
                                          ├──→ Task 6 (algorithms + aggregation)
                                          ├──→ Task 7 (server + planner)
                                          └──→ Task 8 (remaining files)
                                                      │
                                                      ├──→ Task 9 (fix unit tests)
                                                      │         │
                                                      │         ├──→ Task 10 (smoke test)
                                                      │         │         │
                                                      │         │         ├──→ Task 11 (geodetestlab)
                                                      │         │         │         │
                                                      │         │         │         └──→ Task 12 (cleanup)
```

Tasks 1 and 2 can run in parallel.
Tasks 4-8 can run in parallel after Task 3 completes.
Tasks 9-12 are sequential.
