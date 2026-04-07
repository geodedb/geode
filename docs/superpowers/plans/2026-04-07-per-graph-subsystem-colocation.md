# Per-Graph Subsystem Data Colocation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move audit, timeseries, and full-text search (FTS) data storage from server-global locations into per-graph directories so each graph is a self-contained unit.

**Architecture:** Each `ManagedGraph` gains optional handles to a per-graph audit logger, timeseries store, and FTS index. Data files for these subsystems live inside `{data_dir}/graphs/{uuid_hex}/` alongside the existing graph engine files. Global singletons (`setGlobalAuditLogger`, `setGlobalTimeseriesStore`, global `IndexManager` FTS) remain for cross-graph or default-graph use but are backed by per-graph instances looked up by graph name at query time.

**Tech Stack:** Zig 0.15.1, existing `audit.zig`/`timeseries.zig`/`fulltext.zig` modules, `graph_storage_adapter.zig` `ManagedGraph` struct.

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `src/storage/per_graph_subsystems.zig` | Per-graph subsystem lifecycle: init/deinit audit, timeseries, FTS for a ManagedGraph |
| Modify | `src/storage/graph_storage_adapter.zig` | Add subsystem fields to `ManagedGraph`, call lifecycle on create/open/drop |
| Modify | `src/security/audit.zig` | Add `initWithPath` constructor taking explicit file path; keep existing `init` |
| Modify | `src/server/main.zig` | Replace global singleton init with per-graph wiring |
| Modify | `src/eval.zig` | Look up per-graph timeseries store from execution context instead of global |
| Modify | `src/index/index_manager.zig` | Support per-graph FTS index directories for persistence |
| Modify | `src/index/fulltext.zig` | Add `save`/`load` for FTS persistence to a directory |
| Modify | `src/execution.zig` | Thread graph name to timeseries/FTS lookups in evaluator |
| Create | `src/index/fulltext_persist.zig` | Serialize/deserialize `FullTextIndex` inverted index to disk |
| Test | `src/storage/test_per_graph_subsystems.zig` | Integration tests for per-graph lifecycle |

---

## Task 1: Per-Graph Audit Logger Path

**Files:**

- Modify: `src/security/audit.zig` — add `initForGraph` constructor
- Modify: `src/storage/graph_storage_adapter.zig:201-222` — add `audit_logger` field to `ManagedGraph`
- Modify: `src/storage/graph_storage_adapter.zig:1012-1051` — init audit in `createGraphLocked`
- Modify: `src/storage/graph_storage_adapter.zig:1054-1095` — init audit in `openGraphLocked`
- Modify: `src/storage/graph_storage_adapter.zig:216-221` — deinit audit in `ManagedGraph.deinit`

- [ ] **Step 1: Add `initForGraph` to AuditLogger**

In `src/security/audit.zig`, add a constructor that takes an explicit directory path for the audit JSONL file. This avoids env-var resolution and places the file inside the graph directory.

```zig
/// Initialize an audit logger writing to `{graph_dir}/audit.jsonl`.
/// Unlike `init`, this does NOT consult environment variables for the file path.
pub fn initForGraph(allocator: std.mem.Allocator, graph_dir: []const u8) !AuditLogger {
    const path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{graph_dir});
    var cfg = Config{ .enabled = true };
    cfg.file_path = path;
    var logger = try init(allocator, cfg);
    // Mark path as owned so deinit frees it
    logger.owns_file_path = true;
    return logger;
}
```

Add `owns_file_path: bool = false` field to `AuditLogger` and free in `deinit` if set.

- [ ] **Step 2: Verify existing audit tests still pass**

Run: `zig build test 2>&1 | grep -E "passed|failed"`
Expected: all existing tests pass, no regressions.

- [ ] **Step 3: Add `audit_logger` field to `ManagedGraph`**

In `src/storage/graph_storage_adapter.zig`, add an optional audit logger to the struct:

```zig
pub const ManagedGraph = struct {
    engine: *gs.GraphEngine,
    label_dict: LabelStringDict,
    name: []const u8,
    uuid: [16]u8,
    rwlock: std.Thread.RwLock = .{},
    audit_logger: ?*audit.AuditLogger = null, // Per-graph audit

    // ... existing methods ...

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        if (self.audit_logger) |al| {
            al.deinit();
            allocator.destroy(al);
        }
        self.engine.close() catch {};
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
```

- [ ] **Step 4: Initialize audit in `createGraphLocked` and `openGraphLocked`**

After the `ManagedGraph` is created, construct the graph directory path and init the audit logger:

```zig
// In createGraphLocked, after mg.* = .{ ... };
const graph_dir_path = try graphDirPath(self.allocator, self.data_dir, graph_uuid);
defer self.allocator.free(graph_dir_path);
mg.audit_logger = blk: {
    const al = self.allocator.create(audit.AuditLogger) catch break :blk null;
    al.* = audit.AuditLogger.initForGraph(self.allocator, graph_dir_path) catch {
        self.allocator.destroy(al);
        break :blk null;
    };
    break :blk al;
};
```

Add helper `graphDirPath`:

```zig
fn graphDirPath(allocator: Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/graphs/{}", .{ data_dir, std.fmt.fmtSliceHexLower(&uuid) });
}
```

Apply the same pattern in `openGraphLocked`.

- [ ] **Step 5: Build and run tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 6: Commit**

```bash
git add src/security/audit.zig src/storage/graph_storage_adapter.zig
git commit -m "feat(storage): per-graph audit logger colocation"
```

---

## Task 2: Per-Graph Timeseries Store

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig:201-222` — add `ts_store` field to `ManagedGraph`
- Modify: `src/storage/graph_storage_adapter.zig:1012-1095` — init timeseries in create/open
- Modify: `src/storage/graph_storage_adapter.zig:216-221` — deinit timeseries in `ManagedGraph.deinit`
- Modify: `src/eval.zig` — add per-graph timeseries lookup

- [ ] **Step 1: Add `ts_store` field to `ManagedGraph`**

```zig
pub const ManagedGraph = struct {
    engine: *gs.GraphEngine,
    label_dict: LabelStringDict,
    name: []const u8,
    uuid: [16]u8,
    rwlock: std.Thread.RwLock = .{},
    audit_logger: ?*audit.AuditLogger = null,
    ts_store: ?*ts_mod.Store = null, // Per-graph timeseries

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        if (self.ts_store) |ts| {
            ts.deinit();
            allocator.destroy(ts);
        }
        if (self.audit_logger) |al| {
            al.deinit();
            allocator.destroy(al);
        }
        self.engine.close() catch {};
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
```

- [ ] **Step 2: Init timeseries in `createGraphLocked` and `openGraphLocked`**

After audit init, add timeseries init using a subdirectory:

```zig
// In createGraphLocked, after audit init:
mg.ts_store = blk: {
    const ts_dir = std.fmt.allocPrint(self.allocator, "{s}/timeseries", .{graph_dir_path}) catch break :blk null;
    defer self.allocator.free(ts_dir);
    std.fs.cwd().makePath(ts_dir) catch break :blk null;
    const ts = self.allocator.create(ts_mod.Store) catch break :blk null;
    ts.* = ts_mod.Store.initWithConfig(self.allocator, .{ .data_dir = ts_dir }) catch {
        self.allocator.destroy(ts);
        break :blk null;
    };
    ts.loadFromDisk() catch {};
    break :blk ts;
};
```

Apply the same in `openGraphLocked`.

- [ ] **Step 3: Add per-graph timeseries lookup function**

In `src/storage/graph_storage_adapter.zig`, add a public accessor:

```zig
pub fn getTimeseriesStore(self: *StorageAdapter, graph_name: []const u8) ?*ts_mod.Store {
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return null;
    return mg.ts_store;
}
```

- [ ] **Step 4: Wire per-graph timeseries into eval.zig**

In `src/eval.zig`, modify `getGlobalTimeseriesStore` to check per-graph store first. Add a graph-context-aware lookup:

```zig
pub fn getTimeseriesStoreForGraph(graph_name: ?[]const u8) ?*ts.Store {
    if (graph_name) |name| {
        if (graph_store.getGlobalAdapter()) |adapter| {
            if (adapter.getTimeseriesStore(name)) |ts_store| {
                return ts_store;
            }
        }
    }
    // Fallback to global store for backward compatibility
    return getGlobalTimeseriesStore();
}
```

Update timeseries GQL function callsites to use `getTimeseriesStoreForGraph` with the session's current graph.

- [ ] **Step 5: Build and run tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 6: Commit**

```bash
git add src/storage/graph_storage_adapter.zig src/eval.zig
git commit -m "feat(storage): per-graph timeseries store colocation"
```

---

## Task 3: FTS Persistence Layer

**Files:**

- Create: `src/index/fulltext_persist.zig` — serialize/deserialize `FullTextIndex` to disk
- Modify: `src/index/fulltext.zig` — add `save`/`load` methods delegating to persist module

- [ ] **Step 1: Design FTS persistence format**

The FTS index has two main data structures to persist:

1. **Documents**: `AutoHashMap(u64, Document)` — doc_id → content + tokens
2. **Inverted index**: `StringHashMap(PostingList)` — term → posting list

Use a simple binary format:

```
[4 bytes] magic: "GFTS"
[4 bytes] version: 1
[4 bytes] document_count
  For each document:
    [8 bytes] doc_id
    [4 bytes] content_len
    [content_len bytes] content
[4 bytes] term_count
  For each term:
    [4 bytes] term_len
    [term_len bytes] term
    [4 bytes] posting_count
    [4 bytes] idf (f32 bits)
      For each posting:
        [8 bytes] doc_id
        [4 bytes] tf (f32 bits)
        [4 bytes] position_count
          For each position:
            [8 bytes] position (usize)
```

- [ ] **Step 2: Implement `save` in `fulltext_persist.zig`**

Create `src/index/fulltext_persist.zig`:

```zig
const std = @import("std");
const fulltext = @import("fulltext.zig");

const MAGIC = "GFTS";
const VERSION: u32 = 1;

pub fn save(index: *const fulltext.FullTextIndex, dir_path: []const u8, allocator: std.mem.Allocator) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/fulltext.idx", .{dir_path});
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var bw: [4096]u8 = undefined;
    const writer = file.writer(&bw);

    // Header
    try writer.writeAll(MAGIC);
    try writer.writeInt(u32, VERSION, .little);

    // Documents
    const doc_count: u32 = @intCast(index.documents.count());
    try writer.writeInt(u32, doc_count, .little);
    var doc_iter = index.documents.iterator();
    while (doc_iter.next()) |entry| {
        try writer.writeInt(u64, entry.key_ptr.*, .little);
        const content = entry.value_ptr.content;
        try writer.writeInt(u32, @intCast(content.len), .little);
        try writer.writeAll(content);
    }

    // Inverted index
    const term_count: u32 = @intCast(index.inverted_index.count());
    try writer.writeInt(u32, term_count, .little);
    var term_iter = index.inverted_index.iterator();
    while (term_iter.next()) |entry| {
        const term = entry.key_ptr.*;
        try writer.writeInt(u32, @intCast(term.len), .little);
        try writer.writeAll(term);
        const posting = entry.value_ptr.*;
        try writer.writeInt(u32, @intCast(posting.documents.len), .little);
        try writer.writeInt(u32, @bitCast(posting.idf), .little);
        for (posting.documents) |doc| {
            try writer.writeInt(u64, doc.doc_id, .little);
            try writer.writeInt(u32, @bitCast(doc.tf), .little);
            try writer.writeInt(u32, @intCast(doc.positions.len), .little);
            for (doc.positions) |pos| {
                try writer.writeInt(u64, @intCast(pos), .little);
            }
        }
    }
}
```

- [ ] **Step 3: Implement `load` in `fulltext_persist.zig`**

```zig
pub fn load(dir_path: []const u8, allocator: std.mem.Allocator) !fulltext.FullTextIndex {
    const path = try std.fmt.allocPrint(allocator, "{s}/fulltext.idx", .{dir_path});
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return fulltext.FullTextIndex.init(allocator);
        return err;
    };
    defer file.close();

    // Read and validate header, documents, inverted index
    // (mirror of save format above)
    // Return populated FullTextIndex
    var index = try fulltext.FullTextIndex.init(allocator);
    errdefer index.deinit();

    var reader = file.reader();
    // ... read magic, version, documents, terms ...
    // Implementation follows the format spec from Step 1

    return index;
}
```

- [ ] **Step 4: Add `save`/`load` delegates to `fulltext.zig`**

```zig
const fulltext_persist = @import("fulltext_persist.zig");

pub fn saveToDisk(self: *const FullTextIndex, dir_path: []const u8, allocator: std.mem.Allocator) !void {
    return fulltext_persist.save(self, dir_path, allocator);
}

pub fn loadFromDisk(dir_path: []const u8, allocator: std.mem.Allocator) !FullTextIndex {
    return fulltext_persist.load(dir_path, allocator);
}
```

- [ ] **Step 5: Write round-trip test**

```zig
test "FTS persist round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    var idx = try FullTextIndex.init(allocator);
    defer idx.deinit();
    try idx.indexDocument(42, "hello world test document");

    try idx.saveToDisk(dir_path, allocator);

    var loaded = try FullTextIndex.loadFromDisk(dir_path, allocator);
    defer loaded.deinit();

    // Verify document preserved
    const doc = loaded.documents.get(42);
    try std.testing.expect(doc != null);

    // Verify search works
    const results = try loaded.search("hello", allocator);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(u64, 42), results[0].doc_id);
}
```

- [ ] **Step 6: Run test**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 7: Commit**

```bash
git add src/index/fulltext_persist.zig src/index/fulltext.zig
git commit -m "feat(fts): add disk persistence for full-text search indexes"
```

---

## Task 4: Per-Graph FTS Colocation

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig:201-222` — add `fts_index` to `ManagedGraph`
- Modify: `src/storage/graph_storage_adapter.zig:1012-1095` — init/load FTS in create/open
- Modify: `src/storage/graph_storage_adapter.zig:216-221` — save/deinit FTS in `ManagedGraph.deinit`

- [ ] **Step 1: Add `fts_index` field to `ManagedGraph`**

```zig
pub const ManagedGraph = struct {
    engine: *gs.GraphEngine,
    label_dict: LabelStringDict,
    name: []const u8,
    uuid: [16]u8,
    rwlock: std.Thread.RwLock = .{},
    audit_logger: ?*audit.AuditLogger = null,
    ts_store: ?*ts_mod.Store = null,
    fts_index: ?*fulltext.FullTextIndex = null, // Per-graph FTS
    fts_dir: ?[]const u8 = null, // Owned path for FTS save-on-close

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        if (self.fts_index) |fts| {
            if (self.fts_dir) |dir| {
                fts.saveToDisk(dir, allocator) catch {};
                allocator.free(dir);
            }
            fts.deinit();
            allocator.destroy(fts);
        }
        if (self.ts_store) |ts| {
            ts.deinit();
            allocator.destroy(ts);
        }
        if (self.audit_logger) |al| {
            al.deinit();
            allocator.destroy(al);
        }
        self.engine.close() catch {};
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
```

- [ ] **Step 2: Init FTS in `createGraphLocked` and `openGraphLocked`**

```zig
// In createGraphLocked, after timeseries init:
mg.fts_index = blk: {
    const fts_dir = std.fmt.allocPrint(self.allocator, "{s}/fts", .{graph_dir_path}) catch break :blk null;
    errdefer self.allocator.free(fts_dir);
    std.fs.cwd().makePath(fts_dir) catch break :blk null;
    const fts = self.allocator.create(fulltext.FullTextIndex) catch {
        self.allocator.free(fts_dir);
        break :blk null;
    };
    fts.* = fulltext.FullTextIndex.init(self.allocator) catch {
        self.allocator.destroy(fts);
        self.allocator.free(fts_dir);
        break :blk null;
    };
    mg.fts_dir = fts_dir;
    break :blk fts;
};

// In openGraphLocked — load from disk instead of empty init:
mg.fts_index = blk: {
    const fts_dir = std.fmt.allocPrint(self.allocator, "{s}/fts", .{graph_dir_path}) catch break :blk null;
    errdefer self.allocator.free(fts_dir);
    const fts = self.allocator.create(fulltext.FullTextIndex) catch {
        self.allocator.free(fts_dir);
        break :blk null;
    };
    fts.* = fulltext.FullTextIndex.loadFromDisk(fts_dir, self.allocator) catch {
        self.allocator.destroy(fts);
        self.allocator.free(fts_dir);
        break :blk null;
    };
    mg.fts_dir = fts_dir;
    break :blk fts;
};
```

- [ ] **Step 3: Add FTS lookup accessor**

```zig
pub fn getFulltextIndex(self: *StorageAdapter, graph_name: []const u8) ?*fulltext.FullTextIndex {
    self.mutex.lock();
    defer self.mutex.unlock();
    const mg = self.engines.get(graph_name) orelse return null;
    return mg.fts_index;
}
```

- [ ] **Step 4: Build and run tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 5: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "feat(storage): per-graph full-text search index colocation"
```

---

## Task 5: Update Server Init to Use Per-Graph Subsystems

**Files:**

- Modify: `src/server/main.zig:389-426` — keep global audit as fallback, prefer per-graph
- Modify: `src/server/main.zig:626-647` — keep global timeseries as fallback, prefer per-graph
- Modify: `src/server/quic_connection_handler.zig` — route audit events to per-graph logger

- [ ] **Step 1: Update audit event routing in QUIC handler**

In `src/server/quic_connection_handler.zig`, after query execution, log audit events to the per-graph logger when available:

```zig
// After executeProgramWithContext succeeds:
const audit_logger = blk: {
    if (graph_store.getGlobalAdapter()) |adapter| {
        const graph_name = state.current_graph orelse break :blk audit.getGlobalAuditLogger();
        if (adapter.getAuditLogger(graph_name)) |al| break :blk al;
    }
    break :blk audit.getGlobalAuditLogger();
};
```

Add `getAuditLogger` accessor to `StorageAdapter` (same pattern as `getTimeseriesStore`).

- [ ] **Step 2: Keep global subsystem init as fallback**

The global audit logger and timeseries store remain in `src/server/main.zig` as fallbacks for:

- Cross-graph operations (auth events, server startup/shutdown)
- Default graph queries when no per-graph store exists
- Backward compatibility

No code removed — per-graph instances are checked first, globals are fallback.

- [ ] **Step 3: Build and run full test suite**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 4: Commit**

```bash
git add src/server/main.zig src/server/quic_connection_handler.zig src/storage/graph_storage_adapter.zig
git commit -m "feat(server): route subsystem operations to per-graph instances"
```

---

## Task 6: Integration Tests

**Files:**

- Create: `src/storage/test_per_graph_subsystems.zig`

- [ ] **Step 1: Write test for per-graph audit colocation**

```zig
test "per-graph audit writes to graph directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create adapter with temp data_dir
    // Create a graph
    // Verify audit.jsonl exists inside {data_dir}/graphs/{uuid}/
    // Write an audit event
    // Verify file content is valid JSONL
}
```

- [ ] **Step 2: Write test for per-graph timeseries colocation**

```zig
test "per-graph timeseries persists in graph directory" {
    // Create adapter + graph
    // Insert timeseries data via per-graph store
    // Verify timeseries/ subdirectory exists in graph dir
    // Deinit and reopen graph
    // Verify data survives restart via loadFromDisk
}
```

- [ ] **Step 3: Write test for per-graph FTS colocation**

```zig
test "per-graph FTS persists in graph directory" {
    // Create adapter + graph
    // Index a document via per-graph FTS
    // Verify fts/ subdirectory exists in graph dir
    // Deinit (triggers save) and reopen graph
    // Verify search returns indexed document
}
```

- [ ] **Step 4: Run all tests**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`
Expected: EXIT: 0

- [ ] **Step 5: Commit**

```bash
git add src/storage/test_per_graph_subsystems.zig
git commit -m "test(storage): per-graph subsystem colocation integration tests"
```

---

## Task 7: DROP GRAPH Cleanup

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig:348-385` — ensure `dropGraph` cleans up subsystem data

- [ ] **Step 1: Verify `dropGraph` calls `ManagedGraph.deinit`**

The existing `dropGraph` calls `mg.deinit(allocator)` which we've already updated to deinit audit, timeseries, and FTS. Verify the graph directory deletion (via `graph_dir.delete()`) also removes the subsystem subdirectories.

- [ ] **Step 2: Write test**

```zig
test "DROP GRAPH removes subsystem data" {
    // Create graph with audit + timeseries + FTS
    // Verify subsystem dirs exist
    // Drop graph
    // Verify entire graph directory is removed
}
```

- [ ] **Step 3: Run tests and commit**

Run: `zig build test 2>&1 | tail -3; echo "EXIT: $?"`

```bash
git add src/storage/graph_storage_adapter.zig src/storage/test_per_graph_subsystems.zig
git commit -m "feat(storage): DROP GRAPH cleans up colocated subsystem data"
```

---

## Notes

- **Lock ordering**: Per-graph subsystem init/access must NOT acquire `adapter.mutex` while holding a per-graph `rwlock` (see GAP-0278 lock tier table and the deadlock fix in `getNodesByLabel`). All subsystem accessors acquire `adapter.mutex` briefly for the `engines.get` lookup, then release before accessing the subsystem.
- **Migration**: Existing data at `{data_dir}/audit.jsonl` and `{data_dir}/timeseries/` is not migrated automatically. The global fallback handles existing deployments. A future migration task can move historical data into per-graph directories.
- **FTS persistence**: The `save` in `ManagedGraph.deinit` ensures FTS data is flushed on graceful shutdown. For crash recovery, the FTS index is rebuilt from the graph data on next open (same as current behavior where FTS is fully in-memory).
