# Structural Performance Fixes (GAP-0521, GAP-0523, Rank 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix MATCH concurrency safety (missing read lock), reduce multi-hop GROUP BY binding redundancy, and eliminate O(graph_size) property index rebuild on graph open.

**Architecture:** Add shared read lock around MATCH execution for correctness; share variable-name schemas across same-hop bindings and eliminate redundant grouping copies in multi-hop GROUP BY; persist the adapter's exact property index to disk for fast reload.

**Tech Stack:** Zig 0.15.1, geode graph database

---

## Background

### GAP-0523: Snapshot / Read-View Concurrency

**Critical finding:** The comment at `match_operations.zig:4494` claims "MATCH queries hold the store lock for the duration of execution" — but **they don't**. `acquireStoreLock()` is never called in the MATCH path. Multiple concurrent MATCH queries race on the writable store without synchronization. Any CREATE/DELETE during a MATCH could corrupt HashMap iteration.

**Fix:** Actually acquire the shared read lock (`g_store_rwlock.lockShared()`) at MATCH entry and release on exit. This is a correctness fix, not a performance optimization. Future COW snapshotting would allow concurrent reads+writes but is a separate multi-week effort.

### GAP-0521: Multi-hop GROUP BY Bindings

The arena allocator eliminated free-churn but didn't reduce allocation count. Two targeted optimizations:

1. **Name sharing:** All bindings at the same hop depth have identical variable names (e.g., after hop 2, every binding has `["a", "r1", "b", "r2", "c"]`). Currently each binding copies this array. Instead, store one name schema per hop depth and share it.

2. **Eliminate grouping copy:** The grouping phase (lines 4412-4418) copies each binding's arrays before storing in the group map. Since all bindings are arena-allocated and live until function exit, this copy is unnecessary — the grouping map can reference the existing binding directly.

### Rank 8: Property Index Persistence

`rebuildExactNodePropertyIndex` at adapter line 462-488 scans ALL nodes on every graph open, reading labels and properties for each. For large graphs this adds seconds to startup. The index can be persisted to disk alongside the graph data and reloaded on open — falling back to full rebuild only when the persisted version is stale.

## File Map

| File | Action | Task |
|------|--------|------|
| `src/execution/match_operations.zig:4486-4510` | Add shared read lock | Task 1 |
| `src/execution/match_operations.zig:4179-4470` | Name sharing + eliminate grouping copy | Task 2 |
| `src/storage/graph_storage_adapter.zig:57-151,462-488` | Persist/load property index | Task 3 |

---

### Task 1: Add shared read lock around MATCH execution (GAP-0523)

**Why:** MATCH queries currently access the writable GraphStore without any synchronization. Concurrent mutations can corrupt HashMap iteration. The existing `g_store_rwlock` (RwLock at `graph_store.zig:4761`) provides shared read locks that allow multiple concurrent readers but block writers.

**Files:**

- Modify: `src/execution/match_operations.zig:4486-4510`

- [ ] **Step 1: Read the current MATCH entry point**

Read `src/execution/match_operations.zig` around lines 4486-4510 (`executeMatchQueryImpl`). Confirm:

- `skip_snapshot = true` at line 4497
- No call to `acquireStoreLock()` or any mutex
- `getWritableGlobalStore(allocator)` is called at line 4489

- [ ] **Step 2: Find the lock API**

Read `src/graph_store.zig` to find:

- `acquireStoreLock()` — calls `g_store_rwlock.lockShared()` (shared read lock)
- `releaseStoreLock()` — calls `g_store_rwlock.unlockShared()`
- These are pub functions accessible from match_operations.zig

- [ ] **Step 3: Add shared read lock at MATCH entry**

In `executeMatchQueryImpl`, after getting the writable store, add lock acquire with defer release:

```zig
pub fn executeMatchQueryImpl(...) !ExecutionResult {
    const writable_store = graph_store.getWritableGlobalStore(allocator);

    // Acquire shared read lock for the duration of MATCH execution.
    // Multiple MATCH queries can hold this concurrently (shared/read lock),
    // but CREATE/DELETE/SET operations acquire the exclusive write lock,
    // preventing data races during iteration.
    graph_store.acquireStoreLock();
    defer graph_store.releaseStoreLock();

    // ... rest of function unchanged ...
```

**Important:** The lock is shared (read) — multiple MATCH queries can run concurrently. Only write operations (CREATE, DELETE, SET) acquire the exclusive lock and will wait for readers to finish.

- [ ] **Step 4: Update the comment about skip_snapshot**

Update the comment at line 4492-4496 to accurately reflect the new state:

```zig
    // Shared read lock is held for the duration of MATCH execution,
    // preventing concurrent mutations from corrupting iteration.
    // Snapshot isolation (deep-clone) is still skipped because the
    // clone cost is O(graph_size). The read lock provides correctness
    // while the writable store provides zero-cost reads.
    const skip_snapshot = true;
```

- [ ] **Step 5: Run tests**

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass. The lock is a no-op in single-threaded test execution.

- [ ] **Step 6: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "fix(execution): add shared read lock around MATCH execution

MATCH queries now acquire g_store_rwlock.lockShared() for the duration
of execution, preventing data races from concurrent mutations during
HashMap iteration. Multiple concurrent MATCH queries still run in
parallel (shared lock). Snapshot cloning remains disabled.
Closes GAP-0523."
```

---

### Task 2: Multi-hop GROUP BY binding optimization (GAP-0521)

**Why:** Two targeted optimizations that reduce allocation count without changing the algorithm:

1. **Name sharing:** Store one `[][]const u8` per hop depth, reference it from all bindings at that depth
2. **Eliminate grouping copy:** Reference arena-stable bindings directly in the group map

**Files:**

- Modify: `src/execution/match_operations.zig` — `executeMultiHopGroupBy` function (~lines 4154-4481)

- [ ] **Step 1: Read the current binding lifecycle**

Read lines 4179-4470. Understand:

- `MultiHopBinding` struct at line 4179: `env_names: [][]const u8`, `env_values: []Value`
- Per-hop expansion at lines 4341-4363: allocates new `env_names` + `env_values`, copies old entries, appends new
- Grouping copy at lines 4412-4418: copies env_names/env_values AGAIN before storing in group map

- [ ] **Step 2: Change MultiHopBinding to use shared name schema**

Replace the current struct:

```zig
const MultiHopBinding = struct {
    env_names: [][]const u8,
    env_values: []Value,
};
```

With:

```zig
const MultiHopBinding = struct {
    name_schema: []const []const u8, // Shared across all bindings at same depth
    env_values: []Value,             // Per-binding values (arena allocated)
};
```

- [ ] **Step 3: Create name schemas per hop depth**

Before the hop expansion loop, build the name schema incrementally:

```zig
// Build name schemas incrementally per hop depth.
// All bindings at the same depth share the same name array.
var current_schema = try arena.alloc([]const u8, 1);
current_schema[0] = first_hop.left.name orelse "_anon_left_0";
```

Then at each hop, extend the schema:

```zig
var new_var_count: usize = 1;
if (hop.rel.name != null) new_var_count += 1;
var new_schema = try arena.alloc([]const u8, current_schema.len + new_var_count);
@memcpy(new_schema[0..current_schema.len], current_schema);
// Append edge name and right node name
var schema_idx = current_schema.len;
if (hop.rel.name) |rel_name| {
    new_schema[schema_idx] = rel_name;
    schema_idx += 1;
}
new_schema[schema_idx] = hop.right.name orelse "_anon_right";
current_schema = new_schema;
```

Then each binding only needs `env_values` (not `env_names`):

```zig
// Per-binding: only allocate values, share name schema
var new_values = try arena.alloc(Value, current_schema.len);
@memcpy(new_values[0..binding.env_values.len], binding.env_values);
// Append new edge/node values
new_values[binding.env_values.len] = if (edge_ptr) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
if (hop.rel.name != null) {
    new_values[binding.env_values.len + 1] = Value{ .Node = right_node_ptr };
} else {
    new_values[binding.env_values.len] = Value{ .Node = right_node_ptr };
}

try next_bindings.append(arena, MultiHopBinding{
    .name_schema = current_schema, // Shared reference, not copied
    .env_values = new_values,
});
```

- [ ] **Step 4: Update Env construction to use name_schema**

In the WHERE filter and aggregation phases, replace:

```zig
const env = Env{
    .names = binding.env_names,
    .values = binding.env_values,
    ...
};
```

With:

```zig
const env = Env{
    .names = binding.name_schema,
    .values = binding.env_values,
    ...
};
```

- [ ] **Step 5: Eliminate the grouping copy**

In the grouping phase (lines 4412-4418), the code copies env_names and env_values before storing in the group map. Since all bindings are arena-allocated (stable until function exit), and name_schema is shared, just store the binding directly:

Remove:

```zig
var copy_names = try arena.alloc([]const u8, binding.env_names.len);
var copy_values = try arena.alloc(Value, binding.env_values.len);
for (binding.env_names, 0..) |name, i| {
    copy_names[i] = name;
    copy_values[i] = binding.env_values[i];
}
```

Replace with directly appending the existing binding to the group:

```zig
try grp.append(arena, binding); // Arena-stable, no copy needed
```

- [ ] **Step 6: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 7: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "perf(execution): share name schemas and eliminate grouping copy in multi-hop GROUP BY

All bindings at the same hop depth now share a single name_schema
array instead of each binding allocating its own copy. The grouping
phase references arena-stable bindings directly instead of copying.
Partially closes GAP-0521."
```

---

### Task 3: Persist adapter exact property index (Rank 8)

**Why:** `rebuildExactNodePropertyIndex` at line 462-488 scans ALL nodes on graph open, reading labels and properties. For a 1M node graph this adds seconds to startup. Persisting the index to a file alongside the graph data allows loading it directly.

**Files:**

- Modify: `src/storage/graph_storage_adapter.zig` — add save/load functions for `NodePropertyExactIndex`

- [ ] **Step 1: Read the current NodePropertyExactIndex structure**

Read lines 57-151. The index is:

```zig
pub const NodePropertyExactIndex = struct {
    map: std.StringHashMap(std.ArrayList(u64)),
    allocator: Allocator,
    // ...
    pub fn add(label_id, property_key, value_hash, node_id) !void
    pub fn remove(label_id, property_key, value_hash, node_id) void
    pub fn get(label_id, property_key, value_hash) ?[]u64
};
```

Keys are binary-encoded: `[u32 label_id][u32 key_len][key bytes][u64 value_hash]`

- [ ] **Step 2: Read the current rebuild function**

Read lines 462-488 (`rebuildExactNodePropertyIndex`). It:

1. Clears the index
2. Scans all nodes via `mg.engine.node_store.scanNodes()`
3. For each node with labels AND properties, calls `addNodePropertiesForLabels()`

Also read `openGraphLocked` (~line 1804) to see where rebuild is called during startup.

- [ ] **Step 3: Add saveToFile method to NodePropertyExactIndex**

Add a method that serializes the index to a file:

```zig
pub fn saveToFile(self: *const NodePropertyExactIndex, file: std.fs.File) !void {
    // Format:
    // [8 bytes magic "GENPIDX1"]
    // [u64 entry_count]
    // For each entry:
    //   [u32 key_len][key bytes][u64 posting_count][posting_count * u64 node_ids]

    try file.seekTo(0);
    try file.setEndPos(0); // Truncate

    var writer = file.writer();
    try writer.writeAll("GENPIDX1");

    var count: u64 = 0;
    var iter = self.map.iterator();
    while (iter.next()) |_| count += 1;
    try writer.writeInt(u64, count, .little);

    iter = self.map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const posting = entry.value_ptr.items;
        try writer.writeInt(u32, @intCast(key.len), .little);
        try writer.writeAll(key);
        try writer.writeInt(u64, @intCast(posting.len), .little);
        for (posting) |nid| {
            try writer.writeInt(u64, nid, .little);
        }
    }
}
```

- [ ] **Step 4: Add loadFromFile method**

```zig
pub fn loadFromFile(self: *NodePropertyExactIndex, file: std.fs.File) !bool {
    // Returns true if loaded successfully, false if file is missing/corrupt
    file.seekTo(0) catch return false;
    var reader = file.reader();

    var magic: [8]u8 = undefined;
    reader.readNoEof(&magic) catch return false;
    if (!std.mem.eql(u8, &magic, "GENPIDX1")) return false;

    const entry_count = reader.readInt(u64, .little) catch return false;

    self.clear();

    for (0..entry_count) |_| {
        const key_len = reader.readInt(u32, .little) catch return false;
        const key = try self.allocator.alloc(u8, key_len);
        reader.readNoEof(key) catch { self.allocator.free(key); return false; };

        const posting_count = reader.readInt(u64, .little) catch { self.allocator.free(key); return false; };
        var posting = try std.ArrayList(u64).initCapacity(self.allocator, posting_count);
        for (0..posting_count) |_| {
            const nid = reader.readInt(u64, .little) catch { posting.deinit(self.allocator); self.allocator.free(key); return false; };
            posting.appendAssumeCapacity(nid);
        }

        self.map.put(key, posting) catch { posting.deinit(self.allocator); self.allocator.free(key); return false; };
    }

    return true;
}
```

- [ ] **Step 5: Save index during checkpoint**

In the adapter's `checkpointAll` function (or wherever per-graph checkpoint is triggered), save the property index to a file in the graph's data directory:

```zig
// After engine checkpoint succeeds:
const index_path = try std.fmt.allocPrint(allocator, "{s}/prop_exact.idx", .{graph_data_dir});
defer allocator.free(index_path);
var file = try std.fs.cwd().createFile(index_path, .{ .truncate = true });
defer file.close();
try mg.exact_node_property_index.saveToFile(file);
```

- [ ] **Step 6: Load index on open (skip rebuild when fresh)**

In `openGraphLocked`, before `rebuildExactNodePropertyIndex`, try to load from file:

```zig
// Try loading persisted property index
const index_path = try std.fmt.allocPrint(self.allocator, "{s}/prop_exact.idx", .{graph_data_dir});
defer self.allocator.free(index_path);
const loaded = blk: {
    var file = std.fs.cwd().openFile(index_path, .{}) catch break :blk false;
    defer file.close();
    break :blk mg.exact_node_property_index.loadFromFile(file) catch false;
};

if (!loaded) {
    // Fallback: full rebuild from storage scan
    try rebuildExactNodePropertyIndex(mg);
}
```

- [ ] **Step 7: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 8: Commit**

```bash
git add src/storage/graph_storage_adapter.zig
git commit -m "perf(storage): persist exact property index to skip rebuild on open

Saves NodePropertyExactIndex to prop_exact.idx during checkpoint and
loads it on graph open. Falls back to full rebuild if persisted index
is missing or corrupt. Eliminates O(N) node scan on startup for
graphs with existing index files.
Addresses Rank 8 from perf review."
```

---

## Validation

After all 3 tasks:

- [ ] **Run full unit tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Verify concurrent safety manually** (Task 1)

The shared read lock prevents data races. In production, multiple MATCH queries acquire the shared lock concurrently; only CREATE/DELETE/SET acquire the exclusive lock and wait for readers.

---

## Out of Scope

### COW Snapshotting (Future GAP-0523 Enhancement)

The shared read lock fixes correctness but doesn't enable concurrent reads+writes. A future COW snapshot would:

- Create a lightweight "view" at MATCH entry (capture mutation epoch)
- On node/edge access: check if writable store was mutated; if so, lazily copy just that node
- Allow writes to proceed while reads use the pre-mutation snapshot

This requires wrapping all data access paths in MATCH with snapshot-aware getters — a multi-week refactor.

### Full Binding Redesign (Future GAP-0521 Enhancement)

The name-sharing and copy-elimination optimize the current algorithm. A deeper redesign would:

- Use indexed binding storage (flat arena + indices)
- Implement incremental aggregation (compute aggregates during traversal, not after)
- Cache group key hashes instead of serializing to strings

This changes the algorithm fundamentally and needs its own brainstorming session.
