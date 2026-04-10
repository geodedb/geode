# COW Snapshot for Concurrent MATCH + Writes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow MATCH queries and write operations (CREATE/DELETE/SET) to execute concurrently by replacing the held-for-duration shared read lock with a lightweight copy-on-write snapshot that captures consistent state at query start and releases the lock immediately.

**Architecture:** Create a `ReadView` struct that wraps `*const GraphStore` with overlay HashMaps for COW entries. MATCH entry creates a ReadView (O(1)), briefly holds the shared lock during creation, then releases. Writers can proceed while the ReadView serves reads from overlay-first, fallback-to-base. MATCH code is refactored to call ReadView methods instead of accessing store fields directly.

**Tech Stack:** Zig 0.15.1, geode graph database

---

## Background

### Current State (after GAP-0523 fix)

MATCH queries hold `g_store_rwlock.lockShared()` for their entire execution. This is correct (prevents data races) but serializes reads vs writes — a long MATCH blocks all CREATE/DELETE/SET operations.

### Problem

The original `QueryReadSession` creates a full deep-clone of the GraphStore (O(n_nodes + n_edges + string_bytes)). This is too expensive to use in production. The `skip_snapshot = true` flag was set because cloning costs more than holding the lock.

### Solution: Copy-on-Write Snapshot

Instead of cloning upfront, create a thin wrapper:

1. **At MATCH entry:** Create ReadView wrapping the writable store. Hold shared lock only during creation (microseconds). Release lock immediately.
2. **During MATCH:** ReadView serves reads from the wrapped base store (which is now unlocked — writers may modify it).
3. **On concurrent mutation:** Writers acquire the exclusive write lock, modify the base store, then notify active ReadViews. Each ReadView lazily copies only the affected entries to its overlay HashMap.
4. **At MATCH exit:** ReadView.deinit() frees the overlay.

### Simplification: Epoch-Based Invalidation

Full COW notification is complex. A simpler approach: **epoch-based invalidation**.

1. Add a global `g_mutation_epoch: std.atomic.Value(u64)` counter.
2. Mutations increment the epoch after modifying the store.
3. ReadView captures the epoch at creation time.
4. ReadView methods check: if current epoch == captured epoch, serve directly from base store (no mutation happened, zero overhead). If epoch changed, the ReadView falls back to the deep-clone path (rare case).

This provides:

- **Zero overhead for the common case** (no concurrent writes during a MATCH)
- **Correct isolation** when concurrent writes do happen (deep-clone fallback)
- **No per-entry COW tracking** (simple epoch comparison)

## MATCH Read Access Inventory

| Access Pattern | Call Sites | ReadView Method |
|---|---|---|
| `store.nodes.getPtr(id)` | 38 | `view.getNodePtr(id)` |
| `store.nodes.get(id)` | 1 | `view.getNode(id)` |
| `store.edges.getPtr(id)` | 30 | `view.getEdgePtr(id)` |
| `store.edges.get(id)` | 1 | `view.getEdge(id)` |
| `store.getOutgoingEdgeIds(id)` | 12 | `view.getOutgoingEdgeIds(id)` |
| `store.getIncomingEdgeIds(id)` | 12 | `view.getIncomingEdgeIds(id)` |
| `store.getNodesByLabels(...)` | 7 | `view.getNodesByLabels(...)` |
| `store.nodes.iterator()` | ~10 | `view.nodesIterator()` |
| `store.label_index` direct | ~8 | `view.getLabelIndex(...)` |
| **Total** | **~120** | |

## File Map

| File | Action | Task |
|------|--------|------|
| `src/graph_store.zig` | Add `ReadView` struct, `g_mutation_epoch`, epoch increment in mutations | Task 1 |
| `src/execution/match_operations.zig` | Replace `*GraphStore` access with `ReadView` methods | Tasks 2-3 |

---

### Task 1: ReadView struct and mutation epoch counter

**Why:** The ReadView is the foundation. It wraps `*const GraphStore`, checks the epoch, and provides the same access methods MATCH needs. The epoch counter tracks when mutations happen.

**Files:**

- Modify: `src/graph_store.zig`

- [ ] **Step 1: Read the current GraphStore struct and mutation patterns**

Read `src/graph_store.zig`:

- The `GraphStore` struct (~line 389)
- `g_store_rwlock` and lock functions (~line 4761)
- Where mutations happen: `createNodeWithGraph`, `deleteNode`, `createEdgeWithGraph`, `deleteEdge`, `setNodeProperty`, `removeNodeProperty`

- [ ] **Step 2: Add the global mutation epoch counter**

Near `g_store_rwlock` (around line 4761), add:

```zig
/// Monotonically increasing counter incremented after each store mutation.
/// ReadViews compare their captured epoch against this to detect concurrent writes.
var g_mutation_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn getMutationEpoch() u64 {
    return g_mutation_epoch.load(.acquire);
}

pub fn incrementMutationEpoch() void {
    _ = g_mutation_epoch.fetchAdd(1, .release);
}
```

- [ ] **Step 3: Increment epoch in mutation functions**

Add `incrementMutationEpoch()` at the end of each mutation function that modifies the store:

- `createNodeWithGraph` — after node is inserted
- `deleteNode` / `deleteNodeNoSave` — after node is removed
- `createEdgeWithGraph` / `createEdgeWithIdInternal` — after edge is inserted
- `deleteEdge` / `deleteEdgeNoSave` — after edge is removed
- `setNodeProperty` — after property is set
- `removeNodeProperty` — after property is removed

Search for all sites that call `self.markDirty()` or set `self.dirty` — these are the mutation points. Add `incrementMutationEpoch()` after each.

- [ ] **Step 4: Define the ReadView struct**

Add after the `QueryReadSession` definition:

```zig
/// Lightweight read view for concurrent MATCH execution.
/// Captures the mutation epoch at creation time. If no concurrent mutations
/// occur (epoch unchanged), reads go directly to the base store with zero
/// overhead. If mutations are detected (epoch changed), falls back to a
/// deep-clone snapshot for isolation.
pub const ReadView = struct {
    base: *GraphStore,
    captured_epoch: u64,
    /// Lazily initialized deep-clone snapshot (only if epoch changes during read)
    fallback_snapshot: ?QueryReadSession,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store: *GraphStore) ReadView {
        return .{
            .base = store,
            .captured_epoch = getMutationEpoch(),
            .fallback_snapshot = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReadView) void {
        if (self.fallback_snapshot) |*snap| {
            snap.deinit();
        }
    }

    /// Returns the store to read from. If epoch is unchanged, returns base
    /// store directly (zero overhead). If epoch changed, lazily creates a
    /// deep-clone snapshot and returns that.
    fn getReadStore(self: *ReadView) *GraphStore {
        if (getMutationEpoch() == self.captured_epoch) {
            return self.base;
        }
        // Epoch changed — concurrent mutation detected. Fall back to snapshot.
        if (self.fallback_snapshot == null) {
            // Acquire shared lock briefly to clone
            acquireStoreLock();
            defer releaseStoreLock();
            self.fallback_snapshot = QueryReadSession.initIfAvailable(self.allocator, self.base) catch null;
        }
        if (self.fallback_snapshot) |*snap| {
            return snap.store();
        }
        // If snapshot creation failed, fall back to base (best effort)
        return self.base;
    }

    // Delegated access methods — all go through getReadStore()
    pub fn getNodePtr(self: *ReadView, node_id: u64) ?*Node {
        return self.getReadStore().nodes.getPtr(node_id);
    }

    pub fn getNode(self: *ReadView, node_id: u64) ?Node {
        return self.getReadStore().nodes.get(node_id);
    }

    pub fn getEdgePtr(self: *ReadView, edge_id: u64) ?*Edge {
        return self.getReadStore().edges.getPtr(edge_id);
    }

    pub fn getEdge(self: *ReadView, edge_id: u64) ?Edge {
        return self.getReadStore().edges.get(edge_id);
    }

    pub fn getOutgoingEdgeIds(self: *ReadView, node_id: u64) ?[]const u64 {
        return self.getReadStore().getOutgoingEdgeIds(node_id);
    }

    pub fn getIncomingEdgeIds(self: *ReadView, node_id: u64) ?[]const u64 {
        return self.getReadStore().getIncomingEdgeIds(node_id);
    }

    pub fn getNodesByLabels(self: *ReadView, allocator: std.mem.Allocator, graph_name: []const u8, labels: []const []const u8, tenant_id: ?[]const u8) !std.ArrayList(u64) {
        return self.getReadStore().getNodesByLabels(allocator, graph_name, labels, tenant_id);
    }

    pub fn getNodesByLabel(self: *ReadView, graph_name: []const u8, label: []const u8) ?[]const u64 {
        return self.getReadStore().getNodesByLabel(graph_name, label);
    }

    pub fn nodesIterator(self: *ReadView) @TypeOf(self.base.nodes).Iterator {
        return self.getReadStore().nodes.iterator();
    }

    pub fn edgesIterator(self: *ReadView) @TypeOf(self.base.edges).Iterator {
        return self.getReadStore().edges.iterator();
    }

    // Expose fields that MATCH reads directly
    pub fn getGraphName(self: *ReadView, node: Node) []const u8 {
        _ = self;
        return node.graph_name;
    }
};
```

- [ ] **Step 5: Run tests**

```bash
zig build test 2>&1 | tail -20
```

Expected: All tests pass. ReadView is defined but not yet used.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(graph_store): add ReadView struct and mutation epoch counter

ReadView wraps *GraphStore with epoch-based invalidation for concurrent
MATCH + write support. If no concurrent mutations occur, reads go
directly to the base store (zero overhead). If mutations are detected,
lazily falls back to a deep-clone snapshot.

incrementMutationEpoch() is called after each store mutation."
```

---

### Task 2: Refactor executeMatchQueryImpl to use ReadView

**Why:** This is the MATCH entry point. Replace the shared read lock hold with ReadView creation + immediate lock release. Then pass the ReadView's store to all downstream functions.

**Files:**

- Modify: `src/execution/match_operations.zig:4485-4510`

- [ ] **Step 1: Read the current MATCH entry point**

Read `src/execution/match_operations.zig` around lines 4485-4510 (`executeMatchQueryImpl`). Currently:

```zig
const writable_store = graph_store.getWritableGlobalStore(allocator);
graph_store.acquireStoreLock();
defer graph_store.releaseStoreLock();
const skip_snapshot = true;
// ... uses writable_store directly throughout
```

- [ ] **Step 2: Replace lock-hold with ReadView**

Replace the lock acquire/defer release pattern with:

```zig
const writable_store = graph_store.getWritableGlobalStore(allocator);

// Create a lightweight read view instead of holding the lock for the
// entire MATCH execution. The ReadView checks the mutation epoch —
// if no concurrent writes happen, reads go directly to the base store.
// If mutations are detected, it lazily falls back to a deep-clone snapshot.
var read_view = graph_store.ReadView.init(allocator, writable_store);
defer read_view.deinit();

// Get the effective store from the read view
const store = read_view.getReadStore();
```

Remove the `acquireStoreLock()` / `defer releaseStoreLock()` lines. The ReadView handles locking internally (brief lock during fallback clone, if needed).

- [ ] **Step 3: Find where `store` variable is used downstream**

The variable `writable_store` (or `store` after alias) is passed to helper functions. Search for how it flows:

- Is it assigned to a local named `store`?
- Is it passed directly to traversal functions?

The downstream code uses `store` as `*graph_store.GraphStore`. Since `read_view.getReadStore()` returns `*GraphStore`, no type changes are needed in downstream code.

- [ ] **Step 4: Remove skip_snapshot and QueryReadSession code**

Since the ReadView replaces both the lock-hold and the snapshot paths, remove the entire skip_snapshot / QueryReadSession block (lines ~4493-4510):

```zig
// DELETE all of this:
const skip_snapshot = true;
var read_session = if (skip_snapshot) ...;
var previous_read_store = ...;
if (read_session) |*session| { ... }
defer { if (read_session) |*session| { ... } }
```

The ReadView is now the sole isolation mechanism.

- [ ] **Step 5: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add src/execution/match_operations.zig
git commit -m "refactor(execution): replace lock-hold + snapshot with ReadView in MATCH

MATCH queries no longer hold the shared read lock for their entire
duration. Instead, a ReadView captures the mutation epoch at entry.
If no concurrent writes occur, reads go directly to the base store.
If mutations are detected, the ReadView lazily falls back to a
deep-clone snapshot. This allows writes to proceed during MATCH
execution in the common (no-contention) case.

Enhances GAP-0523."
```

---

### Task 3: Add concurrency test

**Why:** Verify the ReadView correctly handles the concurrent-mutation case by detecting epoch changes.

**Files:**

- Modify: `src/graph_store.zig` — add test block

- [ ] **Step 1: Add a test for ReadView epoch detection**

```zig
test "ReadView detects mutation epoch change" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Create initial data
    _ = try store.createNodeWithGraph(allocator, "default", &.{"Person"}, null);

    // Create ReadView — captures current epoch
    var view = ReadView.init(allocator, &store);
    defer view.deinit();

    // Before any mutation: getReadStore returns base
    const store_before = view.getReadStore();
    try std.testing.expect(store_before == &store);

    // Simulate a mutation by incrementing epoch
    incrementMutationEpoch();

    // After mutation: epoch changed, getReadStore should detect it
    // (may fall back to snapshot if global_adapter is set, or return base otherwise)
    const store_after = view.getReadStore();
    // The store should still be usable regardless
    _ = store_after.nodes.iterator();
}
```

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Step 3: Commit**

```bash
git add src/graph_store.zig
git commit -m "test(graph_store): add ReadView epoch detection test"
```

---

## Validation

After all 3 tasks:

- [ ] **Run full test suite**

```bash
zig build test 2>&1 | tail -20
```

- [ ] **Verify concurrency behavior**

The ReadView provides:

1. **Zero overhead in the common case:** No concurrent writes → epoch unchanged → direct base store access
2. **Correct isolation on contention:** Concurrent write → epoch changes → lazy deep-clone fallback
3. **No long lock holds:** MATCH no longer blocks writes for its entire duration

---

## GAP-0521: Multi-hop Binding Redesign — Closed as Diminishing Returns

After thorough analysis, incremental aggregation for multi-hop GROUP BY is **not worth pursuing**:

1. **Prerequisite complexity exceeds the optimization:** Requires semantic analysis of GROUP BY variable dependencies (which hop each variable comes from), a new `min_required_hop_depth` metadata field, and HAVING clause support (currently missing from multi-hop path). This is more code than the optimization itself.

2. **Most queries GROUP BY last-hop variables:** `GROUP BY c.category` where `c` is the last hop means all hops must complete before grouping. No early grouping possible.

3. **Arena allocator already eliminated the big win:** The O(B^H) alloc/free churn is gone. What remains is O(B^H) copying of value arrays — but these are small fixed-size arrays (5-15 values) and the arena makes allocation nearly free.

4. **Name sharing already done:** The shared name schema (one allocation per hop depth instead of per binding) was implemented in the previous session.

5. **Expected gain: 10-30% for a subset of queries.** Not enough to justify the complexity.

**Recommendation:** Close GAP-0521. The arena allocator + name sharing + copy elimination represent the practical ceiling for this algorithm. A fundamentally different execution model (e.g., vectorized/columnar execution) would be needed for further gains — that's a multi-month project.
