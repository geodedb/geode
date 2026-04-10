# graph-storage Performance Fixes (Ranks 8-10)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce checkpoint write amplification by making derived index saves conditional, and add a zero-copy property decode path to eliminate allocation churn during property scans.

**Architecture:** Add per-index dirty flags to `GraphEngine` so checkpoint only rewrites index snapshots that actually changed. Add `decodeView()` to `property.zig` that returns string/ext slices pointing into caller-provided bytes (zero-copy), and expose it through a view-based iterator variant.

**Tech Stack:** Zig 0.15.1, graph-storage library

**Working directory:** `~/src/devnw/zig/graph-storage`

---

## Background

From the [perf review](../perf-review-geode-26-04-09.md):

- **Rank 8** (`rebuildExactNodePropertyIndex` on open): Geode rebuilds a full-graph property index on every graph open. The root cause is that graph-storage's `PropertyChainIndex` is per-prop_head digests, not a `(key, value) → NodeId` posting index. This is a larger structural change — out of scope here. Geode's adapter-side workaround (lazy rebuild or persistence) is addressed separately.

- **Rank 9** (checkpoint writes full derived index snapshots): `engine_persist.checkpoint()` unconditionally calls `saveDerivedIndexes()` on every checkpoint, rewriting `labels.idx`, `props.idx`, and `edges.idx` even when indexes haven't changed. Fix: per-index dirty flags.

- **Rank 10** (property decode allocates for strings/ext): `property.decode()` calls `allocator.dupe()` for every string and ext value. The vtable wrapper in `interface.zig:wrapPropIterator` decodes on every `next()`. Fix: add `decodeView()` that borrows from the caller's byte slice.

## Scope

This plan covers **Ranks 9 and 10**. Rank 8 (property-value posting index) is a larger structural redesign that needs its own plan.

**Rank 6** (snapshot/read-view) requires changes in both repos and a design decision between COW, buffer-pool reads, and MVCC. That needs brainstorming first.

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/engine.zig` | Modify: add 3 dirty flags, set them in mutation functions | Task 1 |
| `src/engine_persist.zig` | Modify: make `saveDerivedIndexes` call conditional | Task 1 |
| `src/engine_index.zig` | Modify: accept per-index dirty flags | Task 1 |
| `src/property.zig` | Modify: add `decodeView()` function | Task 2 |
| `src/interface.zig` | Modify: add view-based iterator variant | Task 3 |

---

### Task 1: Per-index dirty flags for conditional checkpoint saves

**Perf review rank:** 9 (Huge for mutation-heavy workloads)
**Why:** Every checkpoint rewrites all three derived index snapshots (`labels.idx`, `props.idx`, `edges.idx`) regardless of whether those indexes changed. With per-index dirty flags, checkpoint only rewrites snapshots for indexes that were actually modified since the last checkpoint.

**Files:**

- Modify: `src/engine.zig:79-110` (GraphEngine struct) — add dirty flag fields
- Modify: `src/engine.zig` — set flags at mutation sites (lines 626, 668, 709, 714, 749, 770, 792)
- Modify: `src/engine_persist.zig:231-264` — conditional saveDerivedIndexes
- Modify: `src/engine_index.zig:173-180` — accept dirty flags

- [ ] **Step 1: Read the current GraphEngine struct**

Read `src/engine.zig` lines 79-110. Confirm:

- `persistence_dirty: bool = false` at line 109 is the only dirty flag
- `label_index`, `property_index`, `edge_index` fields exist but have no per-index dirty tracking

- [ ] **Step 2: Add per-index dirty flags to GraphEngine**

In `src/engine.zig`, add three new fields after `persistence_dirty` (around line 109):

```zig
    persistence_dirty: bool = false,
    label_index_dirty: bool = false,
    property_index_dirty: bool = false,
    edge_index_dirty: bool = false,
```

- [ ] **Step 3: Set `label_index_dirty` at mutation sites**

In `src/engine.zig`, find the two sites that modify `label_index`:

At line 770 (`label_index.addNode`), add after it:

```zig
        try self.label_index.addNode(label, node_id);
        self.label_index_dirty = true;
```

At line 792 (`label_index.removeNode`), add after it:

```zig
        self.label_index.removeNode(label, node_id);
        self.label_index_dirty = true;
```

- [ ] **Step 4: Set `edge_index_dirty` at mutation sites**

At line 626 (`edge_index.put`), add after:

```zig
        try self.edge_index.put(edge_id, .{ ... });
        self.edge_index_dirty = true;
```

At line 668 (`edge_index.remove`), add after:

```zig
        _ = self.edge_index.remove(edge_id);
        self.edge_index_dirty = true;
```

- [ ] **Step 5: Set `property_index_dirty` at mutation sites**

At line 709 (`property_index.removeChain`):

```zig
            self.property_index.removeChain(owner);
            self.property_index_dirty = true;
```

At line 714 (`property_index.upsertKey`):

```zig
            try self.property_index.upsertKey(owner, key, encoded_buf.items);
            self.property_index_dirty = true;
```

At line 749 (`property_index.removeKey`):

```zig
            self.property_index.removeKey(owner, key);
            self.property_index_dirty = true;
```

At line 343 (`property_index.refreshFromIterator`):

```zig
        try self.property_index.refreshFromIterator(prop_head, &iter);
        self.property_index_dirty = true;
```

- [ ] **Step 6: Make saveDerivedIndexes conditional in engine_persist.zig**

In `src/engine_persist.zig`, replace line 256:

```zig
    // Old: engine_index.saveDerivedIndexes(engine);
    // New: only save indexes that changed since last checkpoint
    try engine_index.saveDerivedIndexesConditional(
        engine,
        engine.label_index_dirty,
        engine.property_index_dirty,
        engine.edge_index_dirty,
    );

    // Reset per-index dirty flags after saving
    engine.label_index_dirty = false;
    engine.property_index_dirty = false;
    engine.edge_index_dirty = false;
```

- [ ] **Step 7: Add saveDerivedIndexesConditional in engine_index.zig**

In `src/engine_index.zig`, add after line 180:

```zig
/// Conditionally save derived index snapshots — only rewrites files for indexes
/// that have been modified since the last checkpoint.
pub fn saveDerivedIndexesConditional(
    engine: *GraphEngine,
    label_dirty: bool,
    property_dirty: bool,
    edge_dirty: bool,
) !void {
    if (label_dirty) {
        const label_file = engine.file_manager.getFile(.label_idx) orelse return error.LabelIndexFileNotOpen;
        try engine.label_index.saveToFile(label_file, engine.manifest.counter);
    }
    if (property_dirty) {
        const prop_file = engine.file_manager.getFile(.prop_idx) orelse return error.PropertyIndexFileNotOpen;
        try engine.property_index.saveToFile(prop_file, engine.manifest.counter);
    }
    if (edge_dirty) {
        const edge_file = engine.file_manager.getFile(.edge_idx) orelse return error.EdgeIndexFileNotOpen;
        try saveEdgeIndex(engine, edge_file);
    }
}
```

Keep the original `saveDerivedIndexes` function as-is for use by `rebuildDerivedIndexes` and `close()`.

- [ ] **Step 8: Run tests**

```bash
cd ~/src/devnw/zig/graph-storage
zig build test 2>&1 | tail -20
```

Expected: All 19 tests pass. Key test to verify: `"checkpoint persists labels.dict, labels.idx and props.idx snapshots"` — this test creates data, checkpoints, and verifies persistence. It should still pass because the dirty flags are set during data creation.

- [ ] **Step 9: Commit**

```bash
cd ~/src/devnw/zig/graph-storage
git add src/engine.zig src/engine_persist.zig src/engine_index.zig
git commit -m "perf(checkpoint): conditional derived index saves with per-index dirty flags

Only rewrite labels.idx, props.idx, and edges.idx when their
corresponding in-memory indexes have been modified since the last
checkpoint. Reduces checkpoint cost from O(total index size) to
O(changed index size) for workloads that only modify a subset of
index types."
```

---

### Task 2: Zero-copy `decodeView()` for property values

**Perf review rank:** 10 (Medium — depends on property-scan usage)
**Why:** `property.decode()` calls `allocator.dupe()` for every string and ext value. During property scans (e.g., WHERE clause evaluation, RETURN property access), this creates allocation churn. A zero-copy decode that borrows from the source bytes eliminates these allocations when the caller can guarantee the bytes remain valid.

**Files:**

- Modify: `src/property.zig:98-165` — add `decodeView()` next to existing `decode()`

- [ ] **Step 1: Read the current decode function**

Read `src/property.zig` lines 98-165. Note:

- Lines 135 and 156: `allocator.dupe(u8, bytes[...])` for string and ext
- The function returns `DecodeResult { value: PropertyValue, bytes_read: usize }`
- String case: reads u32 length, then dupes `bytes[5..5+len]`
- Ext case: reads u16 type_tag + u32 data_len, then dupes `bytes[7..7+len]`

- [ ] **Step 2: Add `decodeView()` function**

Add after `decode()` (after line 165):

```zig
/// Zero-copy decode: string and ext slices borrow directly from `bytes`.
/// Caller must ensure `bytes` remains valid for the lifetime of the returned value.
/// No allocator needed — no heap allocation occurs.
pub fn decodeView(bytes: []const u8) !DecodeResult {
    if (bytes.len == 0) return error.UnexpectedEndOfInput;

    const tag: Tag = @enumFromInt(bytes[0]);
    switch (tag) {
        .null => return .{ .value = .null, .bytes_read = 1 },
        .bool => {
            if (bytes.len < 2) return error.UnexpectedEndOfInput;
            return .{ .value = .{ .bool = bytes[1] != 0 }, .bytes_read = 2 };
        },
        .int => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const val = std.mem.littleToNative(i64, @bitCast(bytes[1..9].*));
            return .{ .value = .{ .int = val }, .bytes_read = 9 };
        },
        .float => {
            if (bytes.len < 9) return error.UnexpectedEndOfInput;
            const bits = std.mem.littleToNative(u64, @bitCast(bytes[1..9].*));
            return .{ .value = .{ .float = @bitCast(bits) }, .bytes_read = 9 };
        },
        .string => {
            if (bytes.len < 5) return error.UnexpectedEndOfInput;
            const len = std.mem.littleToNative(u32, @bitCast(bytes[1..5].*));
            const total = 5 + @as(usize, len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            // Borrow directly from source bytes — no allocation
            return .{
                .value = .{ .string = bytes[5..total] },
                .bytes_read = total,
            };
        },
        .decimal => {
            if (bytes.len < 18) return error.UnexpectedEndOfInput;
            const coeff = std.mem.littleToNative(i128, @bitCast(bytes[1..17].*));
            const scale = bytes[17];
            return .{ .value = .{ .decimal = .{ .coeff = coeff, .scale = scale } }, .bytes_read = 18 };
        },
        .ext => {
            if (bytes.len < 7) return error.UnexpectedEndOfInput;
            const type_tag = std.mem.littleToNative(u16, @bitCast(bytes[1..3].*));
            const data_len = std.mem.littleToNative(u32, @bitCast(bytes[3..7].*));
            const total = 7 + @as(usize, data_len);
            if (bytes.len < total) return error.UnexpectedEndOfInput;
            // Borrow directly from source bytes — no allocation
            return .{
                .value = .{ .ext = .{ .type_tag = type_tag, .data = bytes[7..total] } },
                .bytes_read = total,
            };
        },
    }
}
```

- [ ] **Step 3: Run tests**

```bash
cd ~/src/devnw/zig/graph-storage
zig build test 2>&1 | tail -20
```

Expected: All tests pass. The new function is additive — no existing code is changed.

- [ ] **Step 4: Commit**

```bash
cd ~/src/devnw/zig/graph-storage
git add src/property.zig
git commit -m "feat(property): add decodeView() for zero-copy property decoding

Returns string/ext slices that borrow directly from the source byte
buffer instead of heap-allocating copies. Caller must ensure the
source bytes remain valid for the lifetime of the returned value.
No allocator parameter needed — zero heap allocation."
```

---

### Task 3: View-based property iterator in interface.zig

**Perf review rank:** 10 (continuation)
**Why:** The vtable wrapper `wrapPropIterator` in `interface.zig:500` calls `property.decode()` on every `next()`, allocating for every string/ext property. Adding a view-based variant that uses `decodeView()` eliminates these allocations when the caller can work with borrowed slices.

**Files:**

- Modify: `src/interface.zig:492-529` — add `wrapPropIteratorView()` variant
- Modify: `src/interface.zig:64-80` — add `PropertyIteratorView` type

- [ ] **Step 1: Read the current wrapPropIterator**

Read `src/interface.zig` lines 492-529. Note:

- Line 500: `const val = try property_mod.decode(self.alloc, slice.encoded_value)` — this is the allocation hotspot
- The wrapper converts `PropStore.PropIterator` (zero-copy) into `PropertyIterator` (decoded values)
- `PropertyEntry` at lines 23-26 holds `key: []const u8` and `value: PropertyValue`

- [ ] **Step 2: Add PropertyEntryView type**

Near the existing `PropertyEntry` definition (around line 23), add:

```zig
/// Property entry with values that borrow from pinned page memory.
/// Valid only while the underlying iterator's page frame is pinned.
/// Do NOT store these beyond the current iteration step.
pub const PropertyEntryView = struct {
    key: []const u8,
    value: PropertyValue, // string/ext slices borrow from page bytes
};
```

- [ ] **Step 3: Add PropertyIteratorView type**

After the existing `PropertyIterator` definition (around line 80), add:

```zig
/// Like PropertyIterator but yields zero-copy PropertyEntryView values.
/// String/ext slices borrow from pinned page memory and are only valid
/// until the next next() call or deinit().
pub const PropertyIteratorView = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) anyerror!?PropertyEntryView,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: PropertyIteratorView) anyerror!?PropertyEntryView {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: PropertyIteratorView) void {
        self.vtable.deinit(self.ptr);
    }
};
```

- [ ] **Step 4: Add wrapPropIteratorView function**

After the existing `wrapPropIterator` (around line 529), add:

```zig
/// Wraps a concrete PropIterator into a type-erased PropertyIteratorView.
/// Uses decodeView() instead of decode() — zero-copy, no allocation per next().
fn wrapPropIteratorView(comptime RealIter: type, concrete_iter: RealIter) anyerror!PropertyIteratorView {
    const State = struct {
        iter: RealIter,

        fn next(vp: *anyopaque) anyerror!?PropertyEntryView {
            const self: *@This() = @ptrCast(@alignCast(vp));
            if (try self.iter.next()) |slice| {
                const val = try property_mod.decodeView(slice.encoded_value);
                return PropertyEntryView{
                    .key = slice.key,
                    .value = val.value,
                };
            }
            return null;
        }

        fn deinit(vp: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(vp));
            self.iter.deinit();
        }
    };

    // Allocate state on the iterator's own allocator
    const state = try concrete_iter.store.buffer_pool.allocator.create(State);
    state.* = .{ .iter = concrete_iter };

    return .{
        .ptr = @ptrCast(state),
        .vtable = &.{
            .next = State.next,
            .deinit = State.deinit,
        },
    };
}
```

- [ ] **Step 5: Expose view iterator via GraphStorage vtable**

Add a `getAllPropertiesView` method to the vtable that returns `PropertyIteratorView`. This follows the pattern of the existing `getAllPropertiesFn` at lines 317-321:

```zig
fn getAllPropertiesViewFn(ptr: *anyopaque, prop_head: u64) anyerror!PropertyIteratorView {
    const self: *T = @ptrCast(@alignCast(ptr));
    const concrete_iter = try self.getAllProperties(prop_head);
    return wrapPropIteratorView(@TypeOf(concrete_iter), concrete_iter);
}
```

Add corresponding field to the vtable struct and wire it up.

- [ ] **Step 6: Run tests**

```bash
cd ~/src/devnw/zig/graph-storage
zig build test 2>&1 | tail -20
```

Expected: All tests pass. The new types and functions are additive.

- [ ] **Step 7: Commit**

```bash
cd ~/src/devnw/zig/graph-storage
git add src/interface.zig
git commit -m "feat(interface): add PropertyIteratorView for zero-copy property iteration

Adds PropertyIteratorView and wrapPropIteratorView that use decodeView()
instead of decode(). String/ext property values borrow from pinned page
memory instead of heap-allocating copies. Callers must consume values
before calling next() or deinit()."
```

---

## Validation

After all 3 tasks:

- [ ] **Run the full test suite**

```bash
cd ~/src/devnw/zig/graph-storage
zig build test 2>&1 | tail -20
```

- [ ] **Run integration tests**

```bash
cd ~/src/devnw/zig/graph-storage
zig build integration-test 2>&1 | tail -20
```

- [ ] **Verify checkpoint behavior**

The key test `"checkpoint persists labels.dict, labels.idx and props.idx snapshots"` must pass. This test creates nodes with labels and properties, checkpoints, then verifies the index files exist and are loadable. With conditional saves, the dirty flags should be set during data creation and cleared after checkpoint.

---

## Geode Integration (After These Changes)

After these changes are committed to graph-storage:

1. Update geode's `build.zig.zon` to point to the new graph-storage commit
2. Geode's `StorageAdapter` can optionally use `PropertyIteratorView` for scan-heavy operations
3. The checkpoint improvement is automatic — no geode changes needed

---

## Out of Scope

### Rank 8: Property-Value Posting Index

The current `PropertyChainIndex` maps `prop_head → [{ key, value_hash }]` (per-node digests). What geode needs is `(label, key, value_hash) → [NodeId]` (a posting index for fast `MATCH (n:Label {key: value})` lookups). This is a significant structural addition that needs:

- New `PropertyValueIndex` data structure with posting lists
- Integration into `putPropertyTxn` / `deletePropertyTxn`
- Persistence format and snapshot management
- Geode adapter migration off its rebuild-on-open index

This needs its own plan.

### Rank 6: Lightweight Snapshot/Read-View

The current snapshot creates a full deep-copy of the GraphStore (O(graph_size)). Options for a lightweight alternative:

- **COW semantics**: Only copy nodes/edges modified during query execution
- **Buffer-pool reads**: Use pinned pages directly for reads with page-level isolation
- **MVCC version chains**: Multi-version concurrency in the in-memory store

This needs brainstorming before planning — multiple valid approaches with different tradeoffs for memory, complexity, and concurrency.
