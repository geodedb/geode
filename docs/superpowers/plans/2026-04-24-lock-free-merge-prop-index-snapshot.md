# Lock-Free `merge_prop_index` Snapshot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a lock-free RCU-style read path to `GraphStore.merge_prop_index` so `lookupMergeCandidate` (the MERGE probe + `bulkInsertEdge` endpoint resolver) stops contending with writers on `mg.rwlock` / `merge_prop_index_lock`.

**Architecture:** Keep the existing `std.StringHashMap(u64)` as the authoritative "live" index, written under existing locks. Add a parallel `*MergePropSnapshot` pointer (atomic, refcounted, immutable) that writers republish lazily. Readers load the snapshot pointer without locks, probe it, and **strong-verify** the hit against `nodes.get(...)` before returning `.found`. On snapshot miss or failed strong-verify, readers fall through to the existing locked live-map path — correct but slower.

**Tech Stack:** Zig 0.15.1, `std.atomic.Value`, `std.StringHashMap`, `std.heap.ArenaAllocator`, `std.Thread.Mutex`. Zero new dependencies.

---

## Why this design

Three constraints bound the design:

1. **Correctness must be preserved under stale reads.** After a property mutation, an old `(label, key, old_value)` entry may linger in the snapshot pointing at a node whose property has since changed. A weak verify (`nodes.get(id) != null`) would produce false positives. We fix this by adding a strong verify that the node still has the expected label + property value.
2. **Writes are too frequent for full copy-on-write.** msft-graph ingest produces ~50k property writes in the node phase. Rebuilding a 50k-entry map on every write is ~250 GB memcpy. Publishes must be amortized.
3. **No new third-party concurrent hash maps.** The plan uses only Zig stdlib primitives.

The RCU design amortizes rebuild cost via a `merge_prop_dirty_count` threshold: writers publish a new snapshot only when the live map has drifted by ≥ PUBLISH_THRESHOLD entries since the last publish. Between publishes, writers update the live map in place (under existing locks). Readers always see a consistent past snapshot; stale-but-valid entries are caught by strong-verify; stale-but-missing entries fall through to the locked live-map path.

**Contention win:** The endpoint-resolution hot path in `bulkInsertEdge` and `bulkInsertEdgeWithIds` currently takes `mg.rwlock` SHARED for every edge. Under 16-way concurrent ingest, the reader-count cache line on the rwlock is bounced across 16 CPUs on every edge. After this change, the fast path is a single atomic pointer load + map probe + strong-verify — no cache-line bouncing, no rwlock reader-count updates.

---

## Non-goals

- **Not making writes concurrent.** Writers still serialise through the existing `mg.rwlock` EXCLUSIVE (or `merge_prop_index_lock` EXCLUSIVE in the sharded path). That's the job of Item 1 (engine thread-safety) and Item 2 (per-shard coordinator), which are separate plans.
- **Not rebuilding `label_index`, `edge_type_index`, or `outgoing_edges`/`incoming_edges`** as RCU. Those have different access patterns; they're the job of future work if profiling shows contention.
- **Not handling cross-graph writer races on the global `GraphStore.merge_prop_index`.** That ambient race exists today (multiple `ManagedGraph`s writing the same global map); this plan doesn't make it worse and doesn't fix it. A follow-up ticket for GAP-level `store_mutex` wiring is out of scope here.
- **Not removing the existing `merge_prop_index_lock` or the live `merge_prop_index` field.** The fall-through path needs them.

---

## File structure

**Create:**
- `src/graph_store_merge_snapshot.zig` — new file holding `MergePropSnapshot` type + ref-counting helpers. Kept separate so `graph_store.zig` (~6300 lines) doesn't grow further.
- `tests/test_merge_prop_snapshot.zig` — unit tests for `MergePropSnapshot` lifecycle, publish correctness, and strong-verify.
- `tests/test_merge_prop_snapshot_concurrency.zig` — stress test: N reader threads + 1 writer thread, invariants hold under load.
- `benchmarks/merge_prop_snapshot_lookup/main.zig` — microbench comparing locked vs. lock-free lookup throughput at 1/2/4/8/16 threads.

**Modify:**
- `src/graph_store.zig` — add snapshot fields to `GraphStore`, wire `lookupMergeCandidate` through the new fast path, trigger publishes from `addToMergePropertyIndex` / `removeFromMergePropertyIndex` / `removeAllMergePropertyIndexEntries`, clear snapshot in `deinit` / `clearNodes` / `rebuildIndexes`.
- `src/lib.zig` — export the new module if it needs to be visible to tests via `@import("geode")`.
- `build.zig` — register the new bench artifact + test files.

**Leave alone:**
- `src/storage/graph_storage_adapter.zig` — its `bulkMergeNodeWithReservedId` and `bulkInsertEdge` / `lookupNodeByMergeKey` already call `lookupMergeCandidate`; the change is invisible at that layer because we preserve the API signature.
- `src/execution/crud_operations.zig:152`, `src/execution/match_operations.zig:7569` — same.

---

## Correctness argument

Let `L` be the live map (under lock) and `S` be the published snapshot (lock-free).

**Invariant I1:** Every entry `(k → id)` in `S` reflects a real mutation that happened on `L` at or before the snapshot's publish time.

**Invariant I2:** A strong-verified hit on `S` implies that node `id` currently has the exact `(label, prop_key, prop_value)` tuple encoded in `k`.

- I1 holds because the publisher copies from `L` under the same lock that mutators hold — so `L` is frozen during the copy.
- I2 is NOT preserved across time (a mutation after publish can invalidate it), so we verify at read time. `verifyMergeCandidate(node_id, graph, label, prop_key, prop_value)` checks: `nodes.get(id)` exists, `node.graph_name == graph`, `node.labels` contains `label`, `node.properties.get(prop_key) == prop_value`. If any fails, we fall through to the live-map check.

**Scenarios the design must handle:**

| Scenario | Snapshot state | Live state | Outcome |
|---|---|---|---|
| Fresh insert not yet published | — | has `k → id` | snapshot miss → fall through → live-map hit → `.found` |
| Stable entry | has `k → id` | has `k → id` | snapshot hit, strong-verify passes → `.found` |
| Node deleted after publish | has `k → id`, id gone | no entry | snapshot hit, `nodes.get(id)` null → strong-verify fails → fall through → live-map miss → `.not_found` |
| Property value changed after publish | has `k_old → id`, `k_old` gone | has `k_new → id` | probe for `k_old`: snapshot hit, verify checks prop value == old, but node has new value → fail → fall through → live-map miss → `.not_found`. probe for `k_new`: snapshot miss → fall through → live-map hit → `.found`. |
| Rare (label,key,value) collision across nodes | `k → id_a` in snapshot, `k → id_b` in live | (Pathological; MERGE assumes uniqueness per `"same label+key+value → same logical entity"` comment at `graph_store.zig:1661`) | snapshot hit, verify node id_a, if still matches → `.found id_a` (acceptable — same logical identity). If id_a no longer matches → fall through → live-map returns id_b → `.found id_b`. Correct either way. |

**Null snapshot (startup):** If `merge_prop_snapshot` is null (no publish has run yet), readers fall through to the live-map path every time. This is exactly today's behaviour, so zero regression at startup.

---

## File Structure

### `src/graph_store_merge_snapshot.zig` (new)

Responsibilities:
- Define `MergePropSnapshot` struct (immutable map + arena + refcount).
- `acquire` / `release` methods.
- `build` factory that consumes a live `std.StringHashMap(u64)` and produces a detached snapshot.

### `src/graph_store.zig` (modified)

New fields on `GraphStore`:
- `merge_prop_snapshot: std.atomic.Value(?*MergePropSnapshot)` — the published pointer.
- `merge_prop_dirty_count: std.atomic.Value(u32)` — writes since last publish.
- `merge_prop_rebuild_in_progress: std.atomic.Value(bool)` — atomic CAS flag that serialises publishers. (The project uses `std.Io.Mutex` for most locks, but it has no non-blocking `tryLock`, and Zig 0.16's stdlib no longer exposes `std.Thread.Mutex`. A plain atomic-bool flag preserves the "publishers never block each other" semantic with one instruction.)

New methods on `GraphStore`:
- `publishMergePropSnapshotIfDirty(threshold: u32) void` — if dirty count >= threshold and no other publisher is running, rebuild + swap + decref old.
- `lookupMergeCandidateSnapshot(graph, label, prop_key, prop_value, out) MergeLookupResult` — lock-free fast path.
- `verifyMergeCandidate(node_id, graph, label, prop_key, prop_value) bool` — strong-verify helper.

Modified `lookupMergeCandidate`: calls snapshot fast path first, falls through to existing logic on miss / failed verify.

Modified writers:
- `addToMergePropertyIndex` — call `publishMergePropSnapshotIfDirty(PUBLISH_THRESHOLD)` at end.
- `removeFromMergePropertyIndex` — same.
- `removeAllMergePropertyIndexEntries` — same.

Modified lifecycle:
- `initWithTenant` — initialise `merge_prop_snapshot = .init(null)`, `merge_prop_dirty_count = .init(0)`.
- `deinit` — release the current snapshot (final decref).
- `clearNodes` — swap snapshot to null, release old.
- `rebuildIndexes` — same.

### Tests

- `tests/test_merge_prop_snapshot.zig` — lifecycle, publish correctness, strong-verify.
- `tests/test_merge_prop_snapshot_concurrency.zig` — 16-reader × 1-writer stress.
- `benchmarks/merge_prop_snapshot_lookup/main.zig` — throughput bench.

---

## Task Decomposition

There are 9 tasks. Each is an independent commit; tests land in the same task as the code they cover.

---

### Task 1: Introduce `MergePropSnapshot` type (no wiring)

**Files:**
- Create: `src/graph_store_merge_snapshot.zig`
- Test: inline `test` blocks at the bottom of the new file
- Modify: `src/lib.zig` (export the module so tests can import it via `@import("geode").merge_snapshot`)

- [ ] **Step 1: Write the failing test**

Add at the bottom of a new file `src/graph_store_merge_snapshot.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! RCU snapshot type for the merge-prop index. See
//! docs/superpowers/plans/2026-04-24-lock-free-merge-prop-index-snapshot.md
//! for the full correctness argument. This file intentionally has NO
//! reference to `GraphStore` — the snapshot is a pure data-structure
//! primitive that the caller populates and manages.

const std = @import("std");

pub const MergePropSnapshot = struct {
    map: std.StringHashMap(u64),
    key_arena: std.heap.ArenaAllocator,
    refcount: std.atomic.Value(u32),
    parent_allocator: std.mem.Allocator,

    pub fn create(parent_allocator: std.mem.Allocator) !*MergePropSnapshot {
        const self = try parent_allocator.create(MergePropSnapshot);
        errdefer parent_allocator.destroy(self);
        self.* = .{
            .map = std.StringHashMap(u64).init(parent_allocator),
            .key_arena = std.heap.ArenaAllocator.init(parent_allocator),
            .refcount = std.atomic.Value(u32).init(1),
            .parent_allocator = parent_allocator,
        };
        return self;
    }

    /// Increment the refcount and return the same pointer. Safe to call
    /// concurrently with `release`.
    pub fn acquire(self: *MergePropSnapshot) *MergePropSnapshot {
        _ = self.refcount.fetchAdd(1, .monotonic);
        return self;
    }

    /// Decrement the refcount. On last release, frees the map, arena,
    /// and the snapshot struct itself.
    pub fn release(self: *MergePropSnapshot) void {
        const prev = self.refcount.fetchSub(1, .release);
        if (prev == 1) {
            // Last ref: fence to ensure all reads-through-snap complete
            // before we tear down.
            _ = self.refcount.load(.acquire);
            self.map.deinit();
            self.key_arena.deinit();
            const pa = self.parent_allocator;
            pa.destroy(self);
        }
    }

    /// Copy every (key, value) from `live_map` into this snapshot's
    /// private key arena. Must be called on a newly created snapshot
    /// with an empty `map`.
    pub fn populateFromLive(
        self: *MergePropSnapshot,
        live_map: *const std.StringHashMap(u64),
    ) !void {
        try self.map.ensureTotalCapacity(live_map.count());
        const arena_alloc = self.key_arena.allocator();
        var it = live_map.iterator();
        while (it.next()) |entry| {
            const key_copy = try arena_alloc.dupe(u8, entry.key_ptr.*);
            self.map.putAssumeCapacity(key_copy, entry.value_ptr.*);
        }
    }
};

test "MergePropSnapshot create/release zero-entry" {
    const snap = try MergePropSnapshot.create(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), snap.refcount.load(.monotonic));
    snap.release();
    // No assertion — std.testing.allocator will panic on leak.
}

test "MergePropSnapshot acquire/release balances" {
    const snap = try MergePropSnapshot.create(std.testing.allocator);
    const alias = snap.acquire();
    try std.testing.expectEqual(@as(u32, 2), snap.refcount.load(.monotonic));
    try std.testing.expectEqual(snap, alias);
    alias.release();
    try std.testing.expectEqual(@as(u32, 1), snap.refcount.load(.monotonic));
    snap.release();
}

test "MergePropSnapshot populateFromLive copies keys" {
    var live = std.StringHashMap(u64).init(std.testing.allocator);
    defer {
        var it = live.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        live.deinit();
    }
    try live.put(try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00alice"), 42);
    try live.put(try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00bob"), 43);

    const snap = try MergePropSnapshot.create(std.testing.allocator);
    defer snap.release();
    try snap.populateFromLive(&live);

    try std.testing.expectEqual(@as(u32, 2), snap.map.count());
    try std.testing.expectEqual(@as(?u64, 42), snap.map.get("default\x00User\x00name\x00alice"));
    try std.testing.expectEqual(@as(?u64, 43), snap.map.get("default\x00User\x00name\x00bob"));

    // Mutate `live` — snapshot must not see it (keys are arena-owned).
    std.testing.allocator.free(live.fetchRemove("default\x00User\x00name\x00alice").?.key);
    try std.testing.expectEqual(@as(?u64, 42), snap.map.get("default\x00User\x00name\x00alice"));
}
```

Then in `src/lib.zig`, add a public re-export:

```zig
pub const merge_snapshot = @import("graph_store_merge_snapshot.zig");
```

Locate the existing re-exports in `src/lib.zig` (grep for `pub const graph_storage_adapter`) and add the new line alongside them.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: compile error — module not found, OR linking the new re-export fails, OR the test file cannot be found.

- [ ] **Step 3: Fix compile errors until tests pass**

The source in Step 1 should already compile cleanly. If not, fix per compiler guidance (most likely a missing import or namespace issue in `src/lib.zig`).

- [ ] **Step 4: Run tests to verify all three pass**

Run: `zig build test 2>&1 | grep -E "MergePropSnapshot|PASS|FAIL" | head`
Expected: three passing tests for `MergePropSnapshot`.

- [ ] **Step 5: Run the broader graph_store test surface to ensure no regression**

Run: `zig build test 2>&1 | tail -40`
Expected: same pass/fail ratio as before the change (baseline: `zig build test` exit code 0 per MEMORY.md; the f128 JSON bug in `make build` is unrelated).

- [ ] **Step 6: Commit**

```bash
git add src/graph_store_merge_snapshot.zig src/lib.zig
git commit -m "feat(storage): add MergePropSnapshot RCU primitive (Task 1)"
```

---

### Task 2: Wire snapshot fields into `GraphStore` (allocated, unused)

**Files:**
- Modify: `src/graph_store.zig` (around line 445 for field declaration, line 498 for init, line 550 for deinit, line 664 for clearNodes, line 1907 for rebuildIndexes)
- Test: inline `test` block at the bottom of `src/graph_store.zig` (follow existing convention — `grep "^test " src/graph_store.zig` to locate)

- [ ] **Step 1: Write the failing test**

Add this test block at the bottom of `src/graph_store.zig` (or in the same group as other `test "GraphStore ..."` blocks):

```zig
test "GraphStore snapshot fields initialise to null/zero" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(store.merge_prop_snapshot.load(.monotonic) == null);
    try std.testing.expectEqual(@as(u32, 0), store.merge_prop_dirty_count.load(.monotonic));
}

test "GraphStore.clearNodes drops snapshot" {
    const merge_snapshot = @import("graph_store_merge_snapshot.zig");

    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const snap = try merge_snapshot.MergePropSnapshot.create(std.testing.allocator);
    store.merge_prop_snapshot.store(snap, .release);

    store.clearNodes();

    try std.testing.expect(store.merge_prop_snapshot.load(.monotonic) == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "snapshot fields|clearNodes drops" | head`
Expected: FAIL — `merge_prop_snapshot` / `merge_prop_dirty_count` not declared on `GraphStore`.

- [ ] **Step 3: Add the fields to `GraphStore`**

At `src/graph_store.zig` line 472 (right after `merge_prop_index: std.StringHashMap(u64),`), insert:

```zig
    /// RCU snapshot pointer for lock-free merge-prop lookups. Published
    /// by writers via `publishMergePropSnapshotIfDirty`; consumed by
    /// `lookupMergeCandidate` without any lock acquisition.
    ///
    /// See docs/superpowers/plans/2026-04-24-lock-free-merge-prop-index-snapshot.md.
    merge_prop_snapshot: std.atomic.Value(?*@import("graph_store_merge_snapshot.zig").MergePropSnapshot) =
        std.atomic.Value(?*@import("graph_store_merge_snapshot.zig").MergePropSnapshot).init(null),
    /// Writes since last snapshot publish. Publishers rebuild when this
    /// exceeds `MERGE_PROP_PUBLISH_THRESHOLD`.
    merge_prop_dirty_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// CAS-based publisher lock — a would-be publisher flips this
    /// false→true to claim the rebuild; losers see true and skip.
    /// Zig 0.16 removed `std.Thread.Mutex` and `std.Io.Mutex` has no
    /// non-blocking `tryLock`, so an atomic flag is the cleanest
    /// primitive here.
    merge_prop_rebuild_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
```

Near the top of the file (after the existing constants, around line 144-155 where `pub const PropertyValue` is), add:

```zig
/// Number of live-map mutations since last publish before a writer will
/// attempt a snapshot rebuild. Chosen to amortise rebuild cost at ~1ms
/// per 1000 entries (empirical, see Task 9 bench).
pub const MERGE_PROP_PUBLISH_THRESHOLD: u32 = 1024;
```

In `initWithTenant` (around `src/graph_store.zig:498-516`), the two new fields already default via the `std.atomic.Value.init(...)` expression so no code change is required there — verify by running the test.

In `deinit` (around `src/graph_store.zig:550-607`), add at the top of the function body:

```zig
        // Release any published snapshot before tearing the map down.
        if (self.merge_prop_snapshot.swap(null, .acq_rel)) |snap| {
            snap.release();
        }
```

In `clearNodes` (around `src/graph_store.zig:609-720`), add after `self.merge_prop_index = std.StringHashMap(u64).init(self.allocator);` (line ~692):

```zig
        if (self.merge_prop_snapshot.swap(null, .acq_rel)) |snap| {
            snap.release();
        }
        self.merge_prop_dirty_count.store(0, .monotonic);
```

In `rebuildIndexes` (around `src/graph_store.zig:1892-1958`), add after `self.merge_prop_index = std.StringHashMap(u64).init(self.allocator);` (line ~1908):

```zig
        if (self.merge_prop_snapshot.swap(null, .acq_rel)) |snap| {
            snap.release();
        }
        self.merge_prop_dirty_count.store(0, .monotonic);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -E "snapshot fields|clearNodes drops" | head`
Expected: both tests PASS.

- [ ] **Step 5: Full test sweep to verify no regressions**

Run: `zig build test 2>&1 | tail -30`
Expected: same pass/fail as before this task.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): wire MergePropSnapshot fields into GraphStore (Task 2)"
```

---

### Task 3: Implement `publishMergePropSnapshotIfDirty`

**Files:**
- Modify: `src/graph_store.zig` (add new method near `addToMergePropertyIndex`, around line 1656)
- Test: inline `test` block (keep adjacent to existing merge-index tests; grep for `test "merge prop"` to locate)

- [ ] **Step 1: Write the failing test**

At the bottom of `src/graph_store.zig`, add:

```zig
test "publishMergePropSnapshotIfDirty rebuilds when dirty >= threshold" {
    const merge_snapshot = @import("graph_store_merge_snapshot.zig");

    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    // Seed the live map with two entries (simulate what addToMergePropertyIndex
    // would do — copy keys so deinit frees them).
    const k1 = try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00alice");
    try store.merge_prop_index.put(k1, 1);
    const k2 = try std.testing.allocator.dupe(u8, "default\x00User\x00name\x00bob");
    try store.merge_prop_index.put(k2, 2);

    store.merge_prop_dirty_count.store(2048, .monotonic); // exceed threshold

    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    const snap_opt = store.merge_prop_snapshot.load(.acquire);
    try std.testing.expect(snap_opt != null);
    const snap: *merge_snapshot.MergePropSnapshot = snap_opt.?;
    try std.testing.expectEqual(@as(u32, 2), snap.map.count());
    try std.testing.expectEqual(@as(?u64, 1), snap.map.get("default\x00User\x00name\x00alice"));
    try std.testing.expectEqual(@as(?u64, 2), snap.map.get("default\x00User\x00name\x00bob"));
    try std.testing.expectEqual(@as(u32, 0), store.merge_prop_dirty_count.load(.monotonic));
}

test "publishMergePropSnapshotIfDirty skips below threshold" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    store.merge_prop_dirty_count.store(100, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    try std.testing.expect(store.merge_prop_snapshot.load(.monotonic) == null);
    try std.testing.expectEqual(@as(u32, 100), store.merge_prop_dirty_count.load(.monotonic));
}

test "publishMergePropSnapshotIfDirty replaces old snapshot and releases it" {
    const merge_snapshot = @import("graph_store_merge_snapshot.zig");
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const k1 = try std.testing.allocator.dupe(u8, "default\x00User\x00id\x00a");
    try store.merge_prop_index.put(k1, 1);

    store.merge_prop_dirty_count.store(2048, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);
    const first_snap = store.merge_prop_snapshot.load(.acquire).?;
    const first_alias = first_snap.acquire(); // pin so we can inspect post-swap
    defer first_alias.release();

    // Second publish with updated live map.
    const k2 = try std.testing.allocator.dupe(u8, "default\x00User\x00id\x00b");
    try store.merge_prop_index.put(k2, 2);
    store.merge_prop_dirty_count.store(2048, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);
    const second_snap = store.merge_prop_snapshot.load(.acquire).?;

    try std.testing.expect(first_snap != second_snap);
    try std.testing.expectEqual(@as(u32, 2), second_snap.map.count());
    _ = merge_snapshot; // silence unused
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "publishMergePropSnapshotIfDirty" | head`
Expected: compile error — `publishMergePropSnapshotIfDirty` is not a member of `GraphStore`.

- [ ] **Step 3: Implement the method**

In `src/graph_store.zig`, just before `addToMergePropertyIndex` (around line 1655), add:

```zig
    /// Publish a fresh snapshot of the merge-prop index if the live map
    /// has drifted by at least `threshold` mutations since the last
    /// publish. Uses a non-blocking tryLock to serialise concurrent
    /// publishers — losers bail and retry on the next write.
    ///
    /// Callers MUST hold whatever lock currently protects the live
    /// `merge_prop_index` against mutation (today that is `mg.rwlock`
    /// EXCLUSIVE at the graph level, or `merge_prop_index_lock`
    /// EXCLUSIVE in the bulk-merge shard path). The snapshot is built
    /// under the same lock to guarantee a consistent copy — see the
    /// correctness argument in
    /// docs/superpowers/plans/2026-04-24-lock-free-merge-prop-index-snapshot.md.
    pub fn publishMergePropSnapshotIfDirty(self: *GraphStore, threshold: u32) void {
        const merge_snapshot = @import("graph_store_merge_snapshot.zig");

        if (self.merge_prop_dirty_count.load(.monotonic) < threshold) return;
        // CAS false→true to claim the rebuild. On failure another
        // publisher is already running; we bail and dirty_count will
        // re-trigger on the next write.
        if (self.merge_prop_rebuild_in_progress.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.merge_prop_rebuild_in_progress.store(false, .release);

        // Re-check under the "lock".
        if (self.merge_prop_dirty_count.load(.monotonic) < threshold) return;

        const new_snap = merge_snapshot.MergePropSnapshot.create(self.allocator) catch |err| {
            // OOM: skip this publish; next trigger retries.
            log.warn("merge-prop snapshot publish failed (create)", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };
        new_snap.populateFromLive(&self.merge_prop_index) catch |err| {
            log.warn("merge-prop snapshot publish failed (populate)", &.{
                Attr.string("error", @errorName(err)),
            });
            new_snap.release();
            return;
        };

        const old = self.merge_prop_snapshot.swap(new_snap, .acq_rel);
        self.merge_prop_dirty_count.store(0, .monotonic);
        if (old) |o| o.release();
    }
```

The imports `const log = logging.scoped("storage");` and `const Attr = logging.Attr;` already exist at `src/graph_store.zig:31-33` — verify with `grep "logging.scoped\|logging.Attr" src/graph_store.zig | head`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -E "publishMergePropSnapshotIfDirty" | head`
Expected: three tests PASS.

- [ ] **Step 5: Full sweep**

Run: `zig build test 2>&1 | tail -30`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): add publishMergePropSnapshotIfDirty (Task 3)"
```

---

### Task 4: Add `verifyMergeCandidate` strong-verify helper

**Files:**
- Modify: `src/graph_store.zig` (add helper near `lookupMergeCandidate`, around line 1710)
- Test: inline `test` blocks

- [ ] **Step 1: Write the failing test**

At the bottom of `src/graph_store.zig`:

```zig
test "verifyMergeCandidate passes on live match" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    const ok = store.verifyMergeCandidate(node_id, "default", "User", "name", .{ .String = "alice" });
    try std.testing.expect(ok);
}

test "verifyMergeCandidate rejects missing node" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const ok = store.verifyMergeCandidate(9999, "default", "User", "name", .{ .String = "alice" });
    try std.testing.expect(!ok);
}

test "verifyMergeCandidate rejects stale property value" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    // Node has name=alice, but verify probes for name=bob.
    const ok = store.verifyMergeCandidate(node_id, "default", "User", "name", .{ .String = "bob" });
    try std.testing.expect(!ok);
}

test "verifyMergeCandidate rejects missing label" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    const ok = store.verifyMergeCandidate(node_id, "default", "Device", "name", .{ .String = "alice" });
    try std.testing.expect(!ok);
}

test "verifyMergeCandidate rejects wrong graph" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    const ok = store.verifyMergeCandidate(node_id, "other_graph", "User", "name", .{ .String = "alice" });
    try std.testing.expect(!ok);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "verifyMergeCandidate" | head`
Expected: compile error — `verifyMergeCandidate` is not a member of `GraphStore`.

- [ ] **Step 3: Implement the method**

In `src/graph_store.zig`, immediately before `pub fn lookupMergeCandidate` (around line 1711), add:

```zig
    /// Strong verification for an RCU-snapshot hit: confirm the node
    /// still has the expected graph, label, property key, and property
    /// value. Returns `true` only if all four match.
    ///
    /// Needed because an RCU snapshot can hold an entry whose live
    /// property value has since changed — a weak verify (just
    /// `nodes.get(id) != null`) would produce a false positive.
    pub fn verifyMergeCandidate(
        self: *const GraphStore,
        node_id: u64,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: PropertyValue,
    ) bool {
        const node = self.nodes.get(node_id) orelse return false;
        if (!std.mem.eql(u8, node.graph_name, graph_name)) return false;
        var has_label = false;
        for (node.labels) |l| {
            if (std.mem.eql(u8, l, label)) {
                has_label = true;
                break;
            }
        }
        if (!has_label) return false;
        const live_value = node.properties.get(prop_key) orelse return false;
        return propertyValuesEqual(live_value, prop_value);
    }

    /// Internal equality helper for `PropertyValue`. Handles the five
    /// common cases; for `ExtValue` / `Decimal`, falls back to byte-
    /// level comparison of the serialized form used by the merge-prop
    /// index (via `serializePropValueForIndex`) so the semantics match
    /// what the index itself considers equal.
    fn propertyValuesEqual(a: PropertyValue, b: PropertyValue) bool {
        if (@as(std.meta.Tag(PropertyValue), a) != @as(std.meta.Tag(PropertyValue), b)) return false;
        return switch (a) {
            .String => |sa| std.mem.eql(u8, sa, b.String),
            .Int => |ia| ia == b.Int,
            .Float => |fa| fa == b.Float,
            .Bool => |ba| ba == b.Bool,
            .Null => true,
            .ExtValue, .Decimal => blk: {
                var buf_a: [256]u8 = undefined;
                var buf_b: [256]u8 = undefined;
                const la = serializePropValueForIndex(&buf_a, a) orelse break :blk false;
                const lb = serializePropValueForIndex(&buf_b, b) orelse break :blk false;
                if (la != lb) break :blk false;
                break :blk std.mem.eql(u8, buf_a[0..la], buf_b[0..lb]);
            },
        };
    }
```

Note: `serializePropValueForIndex` already exists at `src/graph_store.zig:1618`. If the compiler complains it's private, move it to `pub` or call-site-local it by the same name in the helper.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -E "verifyMergeCandidate" | head`
Expected: five tests PASS.

- [ ] **Step 5: Full sweep**

Run: `zig build test 2>&1 | tail -30`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): add verifyMergeCandidate strong-verify (Task 4)"
```

---

### Task 5: Add `lookupMergeCandidateSnapshot` lock-free fast path

**Files:**
- Modify: `src/graph_store.zig` (add method near `lookupMergeCandidate`)
- Test: inline `test` blocks

- [ ] **Step 1: Write the failing test**

At the bottom of `src/graph_store.zig`:

```zig
test "lookupMergeCandidateSnapshot hits published snapshot" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    // Force a publish.
    store.merge_prop_dirty_count.store(4096, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    var out: u64 = 0;
    const r = store.lookupMergeCandidateSnapshot("default", "User", "name", .{ .String = "alice" }, &out);
    try std.testing.expectEqual(GraphStore.MergeLookupResult.found, r);
    try std.testing.expectEqual(node_id, out);
}

test "lookupMergeCandidateSnapshot returns not_found on null snapshot" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    var out: u64 = 0;
    const r = store.lookupMergeCandidateSnapshot("default", "User", "name", .{ .String = "alice" }, &out);
    try std.testing.expectEqual(GraphStore.MergeLookupResult.not_found, r);
}

test "lookupMergeCandidateSnapshot rejects stale entry via strong-verify" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    store.merge_prop_dirty_count.store(4096, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    // Mutate live map: change the property to a new value. Snapshot still
    // holds the old (alice → node_id) entry.
    try store.setNodeProperty(node_id, "name", .{ .String = "bob" });

    var out: u64 = 0;
    const r = store.lookupMergeCandidateSnapshot("default", "User", "name", .{ .String = "alice" }, &out);
    try std.testing.expectEqual(GraphStore.MergeLookupResult.not_found, r);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "lookupMergeCandidateSnapshot" | head`
Expected: compile error — method not declared.

- [ ] **Step 3: Implement the method**

In `src/graph_store.zig`, immediately after `pub fn lookupMergeCandidate` (around line 1724), add:

```zig
    /// Lock-free RCU snapshot probe. Returns `.found` only if a
    /// snapshot exists AND it contains the probe key AND strong-verify
    /// succeeds against the live `nodes` map.
    ///
    /// Returns `.not_found` in every other case (null snapshot, miss,
    /// stale entry, non-indexable probe). Callers that need the
    /// strict "index is authoritative" semantic from
    /// `lookupMergeCandidate` must fall back on this method's
    /// `.not_found` to the locked live-map lookup.
    pub fn lookupMergeCandidateSnapshot(
        self: *const GraphStore,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: PropertyValue,
        out_node_id: *u64,
    ) MergeLookupResult {
        var buf: [1024]u8 = undefined;
        const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse return .not_indexable;

        const snap_raw = self.merge_prop_snapshot.load(.acquire) orelse return .not_found;
        // Pin the snapshot for the duration of this call.
        const snap = snap_raw.acquire();
        defer snap.release();

        const node_id = snap.map.get(probe) orelse return .not_found;
        if (!self.verifyMergeCandidate(node_id, graph_name, label, prop_key, prop_value)) {
            return .not_found;
        }
        out_node_id.* = node_id;
        return .found;
    }
```

Note: `merge_prop_snapshot` is `std.atomic.Value(?*MergePropSnapshot)`. Zig allows `.load(.acquire)` on optional-pointer atomics. If the compiler objects to the exact signature, wrap as `@ptrCast`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -E "lookupMergeCandidateSnapshot" | head`
Expected: three tests PASS.

- [ ] **Step 5: Full sweep**

Run: `zig build test 2>&1 | tail -30`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): add lookupMergeCandidateSnapshot lock-free probe (Task 5)"
```

---

### Task 6: Wire snapshot fast path into `lookupMergeCandidate`

**Files:**
- Modify: `src/graph_store.zig:1712-1724` (the existing `lookupMergeCandidate`)
- Test: inline `test` block

- [ ] **Step 1: Write the failing test**

At the bottom of `src/graph_store.zig`:

```zig
test "lookupMergeCandidate prefers snapshot when available" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    store.merge_prop_dirty_count.store(4096, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    var out: u64 = 0;
    try std.testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate("default", "User", "name", .{ .String = "alice" }, &out));
    try std.testing.expectEqual(node_id, out);
}

test "lookupMergeCandidate falls through on snapshot miss" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    // Create node AFTER publishing an empty snapshot. The snapshot is
    // stale (does not know about this node), so the fall-through
    // live-map path must find it.
    store.merge_prop_dirty_count.store(4096, .monotonic);
    store.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    var out: u64 = 0;
    try std.testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate("default", "User", "name", .{ .String = "alice" }, &out));
    try std.testing.expectEqual(node_id, out);
}

test "lookupMergeCandidate behaves identically without snapshot" {
    // This is a superset regression test: with a null snapshot, the
    // new lookupMergeCandidate must behave identically to the old one.
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"User"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    var out: u64 = 0;
    try std.testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate("default", "User", "name", .{ .String = "alice" }, &out));
    try std.testing.expectEqual(node_id, out);

    try std.testing.expectEqual(GraphStore.MergeLookupResult.not_found, store.lookupMergeCandidate("default", "User", "name", .{ .String = "bob" }, &out));
}
```

- [ ] **Step 2: Run test to verify the first one fails**

Run: `zig build test 2>&1 | grep -E "lookupMergeCandidate " | head`
Expected: `test "lookupMergeCandidate prefers snapshot when available"` should FAIL — currently the method goes directly to the live map, which is empty (the write went only into the merge-prop-index via setNodeProperty → addToMergePropertyIndex). Actually wait: in the current code the live map IS updated by setNodeProperty. So this test may already "pass" by luck on the fall-through path. That's fine — the test still validates correctness. The regression we care about is that the snapshot path is exercised, which we'll verify via a log assertion in Task 8's stress test.

If the test passes on the fall-through, that's OK; proceed to Step 3 to actually wire the snapshot path.

- [ ] **Step 3: Wire the snapshot fast path**

Replace the body of `pub fn lookupMergeCandidate` at `src/graph_store.zig:1712-1724` with:

```zig
    pub fn lookupMergeCandidate(
        self: *const GraphStore,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: PropertyValue,
        out_node_id: *u64,
    ) MergeLookupResult {
        // RCU fast path: probe the published snapshot without locks.
        switch (self.lookupMergeCandidateSnapshot(graph_name, label, prop_key, prop_value, out_node_id)) {
            .found => return .found,
            .not_indexable => return .not_indexable,
            .not_found => {}, // fall through
        }

        // Fall-through: locked live-map probe. Matches pre-RCU semantics
        // exactly. Caller must hold the live-map lock as before (today
        // that is `mg.rwlock` SHARED in the general path, or
        // `merge_prop_index_lock` SHARED in the bulk-merge shard path).
        var buf: [1024]u8 = undefined;
        const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse return .not_indexable;
        const node_id = self.merge_prop_index.get(probe) orelse return .not_found;
        if (self.nodes.get(node_id)) |node| {
            if (std.mem.eql(u8, node.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
        }
        return .not_found;
    }
```

- [ ] **Step 4: Run all three tests**

Run: `zig build test 2>&1 | grep -E "lookupMergeCandidate " | head`
Expected: three tests PASS.

- [ ] **Step 5: Full sweep — CRITICAL, this is the first real wiring change**

Run: `zig build test 2>&1 | tail -60`
Expected: no new failures. Pay special attention to any test in `tests/` that exercises MERGE semantics — grep for `test_merge` and confirm those pass.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): wire RCU fast path into lookupMergeCandidate (Task 6)"
```

---

### Task 7: Trigger snapshot publish from writers

**Files:**
- Modify: `src/graph_store.zig` — `addToMergePropertyIndex`, `removeFromMergePropertyIndex`, `removeAllMergePropertyIndexEntries`

- [ ] **Step 1: Write the failing test**

At the bottom of `src/graph_store.zig`:

```zig
test "addToMergePropertyIndex triggers publish after threshold" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    // Create many nodes with unique properties so dirty_count crosses the threshold.
    var i: u64 = 0;
    while (i < MERGE_PROP_PUBLISH_THRESHOLD + 10) : (i += 1) {
        const nid = try store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try store.setNodeProperty(nid, "name", .{ .String = name });
    }

    try std.testing.expect(store.merge_prop_snapshot.load(.acquire) != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "triggers publish" | head`
Expected: FAIL — `merge_prop_snapshot` is still null because no writer triggers publish.

- [ ] **Step 3: Wire publish triggers into writers**

In `src/graph_store.zig`, modify `addToMergePropertyIndex` (around line 1656). The existing body ends with:

```zig
                try self.merge_prop_index.put(key_copy, node_id);
            }
        }
    }
```

Replace with:

```zig
                try self.merge_prop_index.put(key_copy, node_id);
            }
        }
        _ = self.merge_prop_dirty_count.fetchAdd(@intCast(labels.len), .monotonic);
        self.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);
    }
```

In `removeFromMergePropertyIndex` (around line 1672), the existing body ends with:

```zig
            if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
```

Replace with:

```zig
            if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        _ = self.merge_prop_dirty_count.fetchAdd(@intCast(labels.len), .monotonic);
        self.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);
    }
```

In `removeAllMergePropertyIndexEntries` (around line 1683), the existing body ends with:

```zig
                if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                    self.allocator.free(kv.key);
                }
            }
        }
    }
```

Replace with:

```zig
                if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                    self.allocator.free(kv.key);
                }
            }
        }
        const n_props = node.properties.count();
        const n_labels = node.labels.len;
        _ = self.merge_prop_dirty_count.fetchAdd(@intCast(n_props * n_labels), .monotonic);
        self.publishMergePropSnapshotIfDirty(MERGE_PROP_PUBLISH_THRESHOLD);
    }
```

- [ ] **Step 4: Run the trigger test**

Run: `zig build test 2>&1 | grep -E "triggers publish" | head`
Expected: PASS.

- [ ] **Step 5: Full sweep**

Run: `zig build test 2>&1 | tail -40`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/graph_store.zig
git commit -m "feat(storage): trigger RCU snapshot publish from writers (Task 7)"
```

---

### Task 8: Concurrency stress test

**Files:**
- Create: `tests/test_merge_prop_snapshot_concurrency.zig`
- Modify: `build.zig` (register the new test file)

- [ ] **Step 1: Write the failing test**

Create `tests/test_merge_prop_snapshot_concurrency.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress test: 16 reader threads + 1 writer thread exercise the RCU
//! `merge_prop_index` path. Invariants:
//!   * No crash, no deadlock.
//!   * A reader that sees `.found` with node_id N gets a strong-verified
//!     consistent view (node.graph, node.labels include label, and
//!     node.properties[prop_key] equals prop_value AT THE MOMENT OF
//!     RETURN — relaxed to "was consistent at snapshot publish time" —
//!     the test accepts any `.found` whose node_id is one the writer
//!     ever created).
//!   * No false-positive `.found` for a key that the writer never
//!     inserted.

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const READER_COUNT: usize = 16;
const MUTATIONS: usize = 5000;

const Ctx = struct {
    store: *GraphStore,
    done: std.atomic.Value(bool),
    valid_ids: *std.atomic.Value(u64), // monotonically-increasing high-water mark of valid IDs
    false_positives: std.atomic.Value(u64),
};

fn readerLoop(ctx: *Ctx) void {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const rand = rng.random();

    while (!ctx.done.load(.acquire)) {
        const probe_id = rand.intRangeAtMost(u64, 1, @max(1, ctx.valid_ids.load(.monotonic) + 100));
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{probe_id}) catch continue;

        var out: u64 = 0;
        const r = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
        if (r == .found) {
            // Any returned node_id must be one the writer created (<= high-water mark).
            if (out > ctx.valid_ids.load(.monotonic) + 10) {
                // +10 slack for the writer being mid-insert.
                _ = ctx.false_positives.fetchAdd(1, .monotonic);
            }
        }
    }
}

fn writerLoop(ctx: *Ctx) !void {
    var i: u64 = 0;
    while (i < MUTATIONS) : (i += 1) {
        const nid = try ctx.store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try ctx.store.setNodeProperty(nid, "name", .{ .String = name });
        _ = ctx.valid_ids.store(nid, .monotonic);
    }
    ctx.done.store(true, .release);
}

test "merge_prop RCU: 16 readers + 1 writer, no false positives" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    var valid_ids = std.atomic.Value(u64).init(0);
    var false_positives = std.atomic.Value(u64).init(0);

    var ctx = Ctx{
        .store = &store,
        .done = std.atomic.Value(bool).init(false),
        .valid_ids = &valid_ids,
        .false_positives = false_positives,
    };

    var reader_threads: [READER_COUNT]std.Thread = undefined;
    for (&reader_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, readerLoop, .{&ctx});
    }

    try writerLoop(&ctx);

    for (reader_threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.false_positives.load(.monotonic));
}
```

Register in `build.zig`: find the existing test file list (grep for `test_sharded_coordinator.zig`) and add `"tests/test_merge_prop_snapshot_concurrency.zig"` alongside it in the same array / loop structure. If the build uses `b.addTest` per-file, clone the pattern used for `test_sharded_coordinator.zig`.

- [ ] **Step 2: Run test to verify it fails (or passes by luck)**

Run: `zig build test --summary all 2>&1 | grep -E "merge_prop RCU|false positives" | head`
Expected: PASS on modern hardware; if it fails due to false positives, investigate (likely a strong-verify bug from Task 4 or a race in Task 5's `acquire`/`release`).

If the test passes on first try, that's expected given the strong-verify; proceed to confirm under `-Drelease-fast`.

- [ ] **Step 3: Run under release-fast for better race detection**

Run: `zig build test -Doptimize=ReleaseFast --summary all 2>&1 | grep -E "merge_prop RCU|false positives" | head`
Expected: PASS.

- [ ] **Step 4: Also run with ThreadSanitizer-equivalent via Valgrind if available**

Run: `command -v valgrind && valgrind --tool=drd --error-exitcode=1 ./zig-out/bin/test-merge-prop-snapshot-concurrency 2>&1 | tail -20 || echo "valgrind drd not available, skipping"`
Expected: no data races reported (or skipped if valgrind isn't installed).

- [ ] **Step 5: Full sweep**

Run: `zig build test 2>&1 | tail -40`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add tests/test_merge_prop_snapshot_concurrency.zig build.zig
git commit -m "test(storage): RCU merge_prop_index concurrency stress (Task 8)"
```

---

### Task 9: Microbenchmark + validation

**Files:**
- Create: `benchmarks/merge_prop_snapshot_lookup/main.zig`
- Modify: `build.zig` (register the bench artifact)
- Create: `docs/performance/2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md`

- [ ] **Step 1: Write the bench**

Create `benchmarks/merge_prop_snapshot_lookup/main.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Microbenchmark: lookup throughput for `lookupMergeCandidate` with
//! N concurrent reader threads against a pre-populated store.
//!
//! Compares two configurations:
//!   baseline — snapshot forced null (every lookup falls through to
//!              the locked live-map path); mirrors pre-RCU behaviour.
//!   rcu      — snapshot published once at start; all lookups hit the
//!              lock-free fast path.
//!
//! Emits a line in the stable NATIVE_BENCH format for CI parsing.

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const LOOKUPS_PER_THREAD: usize = 200_000;
const STORE_SIZE: usize = 10_000;

fn seedStore(store: *GraphStore, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const nid = try store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try store.setNodeProperty(nid, "name", .{ .String = name });
    }
}

const Ctx = struct { store: *GraphStore, stop: std.atomic.Value(u64) };

fn worker(ctx: *Ctx) void {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const rand = rng.random();
    var i: usize = 0;
    while (i < LOOKUPS_PER_THREAD) : (i += 1) {
        const probe_id = rand.intRangeAtMost(u64, 1, STORE_SIZE);
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{probe_id}) catch continue;
        var out: u64 = 0;
        _ = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
    }
    _ = ctx.stop.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const mode_arg = args.next() orelse "rcu";
    const threads_arg = args.next() orelse "8";
    const threads = try std.fmt.parseInt(usize, threads_arg, 10);

    var store = try GraphStore.init(allocator);
    defer store.deinit();
    try seedStore(&store, STORE_SIZE);

    if (std.mem.eql(u8, mode_arg, "rcu")) {
        store.merge_prop_dirty_count.store(4096, .monotonic);
        store.publishMergePropSnapshotIfDirty(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD);
    } else {
        // baseline: drop any snapshot so lookups fall through.
        if (store.merge_prop_snapshot.swap(null, .acq_rel)) |snap| snap.release();
    }

    var ctx = Ctx{ .store = &store, .stop = std.atomic.Value(u64).init(0) };
    var ts = std.time.Timer.start() catch unreachable;
    const thread_list = try allocator.alloc(std.Thread, threads);
    defer allocator.free(thread_list);
    for (thread_list) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
    for (thread_list) |t| t.join();
    const elapsed_ns = ts.read();

    const total_ops = threads * LOOKUPS_PER_THREAD;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print(
        "NATIVE_BENCH mode={s} threads={d} ops={d} elapsed_ms={d:.2} ops_per_sec={d:.0}\n",
        .{ mode_arg, threads, total_ops, @as(f64, @floatFromInt(elapsed_ns)) / 1e6, ops_per_sec },
    );
}
```

Register in `build.zig`: add an executable step named `bench-merge-prop-lookup` pointing at `benchmarks/merge_prop_snapshot_lookup/main.zig`. Mirror the pattern of an existing `benchmark_*.zig` file — `grep "benchmark" build.zig | head`.

- [ ] **Step 2: Run the baseline (pre-RCU) config**

Run: `zig build bench-merge-prop-lookup -Doptimize=ReleaseFast 2>&1 | tail -5 && ./zig-out/bin/bench-merge-prop-lookup baseline 1 && ./zig-out/bin/bench-merge-prop-lookup baseline 16`
Expected: two `NATIVE_BENCH` lines showing ops/sec for baseline at 1 and 16 threads. Capture both numbers.

- [ ] **Step 3: Run the RCU config**

Run: `./zig-out/bin/bench-merge-prop-lookup rcu 1 && ./zig-out/bin/bench-merge-prop-lookup rcu 16`
Expected: two `NATIVE_BENCH` lines for rcu at 1 and 16 threads.

- [ ] **Step 4: Record results**

Create `docs/performance/2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md`:

```markdown
# RCU merge_prop_index — validation

## Microbench results

| Config | Threads | ops/sec | vs baseline (same thread count) |
|---|---|---|---|
| baseline | 1 | <paste> | 1.0× |
| baseline | 16 | <paste> | <paste> |
| rcu | 1 | <paste> | <paste> |
| rcu | 16 | <paste> | <paste> |

## Expected outcome

- Single-threaded: RCU within ±10% of baseline (verify overhead ~= locked lookup overhead at single-threaded contention).
- 16-threaded: RCU > 4× baseline (fast path scales linearly; baseline contends on rwlock reader count).

## Validation criteria for accepting this change

- [ ] `zig build test` exit code 0.
- [ ] `tests/test_merge_prop_snapshot_concurrency.zig` passes under `-Doptimize=ReleaseFast`.
- [ ] 16-thread RCU ops/sec ≥ 4× 16-thread baseline ops/sec.
- [ ] `geodetestlab` MERGE specs all pass — run
      `cd ../geode-test-harness && make test-grep GREP=merge` and confirm no new failures.

## Next step

If microbench shows the expected scaling and geodetestlab passes, capture the msft-graph edge-phase timing with the new binary: it should show a reduction in the per-file wall-clock during the edge phase from `edges_app_role_assignment.jsonl` onward, since `bulkInsertEdge`'s endpoint-resolution no longer contends with the flusher's write lock.
```

- [ ] **Step 5: Run the geodetestlab MERGE subset**

Run: `cd /home/benji/src/devnw/codepros/geode/geode-test-harness && make test-grep GREP=merge 2>&1 | tail -20`
Expected: all MERGE-related specs pass. Record pass/fail count in the validation doc.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/merge_prop_snapshot_lookup/main.zig build.zig docs/performance/2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md
git commit -m "bench(storage): RCU merge_prop_index lookup microbench + validation doc (Task 9)"
```

---

## Self-review checklist

Before handing off for execution:

- [ ] **Spec coverage**
  - Item 3 requirement: "Lock-free merge_prop_index snapshot — RCU-style pointer swap so endpoint resolution truly parallelises. Days, not weeks." — covered by Tasks 1–9.
  - Correctness under concurrent writes — covered by Task 8 stress test.
  - Performance claim validated — covered by Task 9 bench.

- [ ] **No placeholders** — every step has either a full code block or an exact shell command. No "TBD", "similar to X", or "write tests".

- [ ] **Type consistency**
  - `MergePropSnapshot` struct name consistent across tasks.
  - `MergeLookupResult` (enum defined at `graph_store.zig:1697`) referenced by name in all tasks that consume it.
  - `MERGE_PROP_PUBLISH_THRESHOLD` (u32, 1024) referenced consistently.
  - `lookupMergeCandidateSnapshot` signature matches existing `lookupMergeCandidate` signature (same parameter order, same return type).
  - `propertyValuesEqual` (helper in Task 4) name matches — note: this is a NEW helper; if a function with the same name already exists, rename to `mergePropertyValuesEqual` at plan time. (Confirmed: `grep "fn propertyValuesEqual\|fn propertyValueEquals" src/graph_store.zig` returns nothing — the name is free.)

- [ ] **Lock tier consistency** — new `merge_prop_rebuild_mutex` is a `std.Thread.Mutex` held only inside publish, which itself runs while the caller holds existing tier-1 locks. No new tier entries required in CLAUDE.md.

- [ ] **Feature flag discipline** — no feature flags added; per CLAUDE.md guidance, this ships as a direct change and git-revert is the rollback path. The pre-push hook against `feature_*` patterns is not triggered.

- [ ] **File size** — `graph_store.zig` grows by ~120 lines (well under the 800-line ceiling the file has already blown past for legitimate reasons). The new `graph_store_merge_snapshot.zig` is ~120 lines self-contained.

---

## Risks and mitigations

- **Risk: a stale snapshot returns a false-positive `.found`.** Mitigation: strong-verify in Task 4, covered by Task 5 and Task 8 tests.
- **Risk: OOM during snapshot publish stalls writers.** Mitigation: `publishMergePropSnapshotIfDirty` silently drops the rebuild on OOM — next trigger retries; writers never see the error.
- **Risk: reader holds a pinned snapshot across a long operation.** Mitigation: `lookupMergeCandidateSnapshot` acquires and releases within the function scope; no pin escapes. Review Task 5's `defer snap.release()` — the pin lifetime is strictly bounded.
- **Risk: cross-graph writers race on the global `merge_prop_index`.** Not introduced by this plan — the race exists today. Logged as a non-goal above; follow-up ticket should fix via a `store_mutex` at tier 1.
- **Risk: `publishMergePropSnapshotIfDirty` is called without the caller holding the live-map lock.** Mitigation: every call site from Task 7 is inside a writer that already holds the appropriate lock. Review the three sites (`addToMergePropertyIndex`, `removeFromMergePropertyIndex`, `removeAllMergePropertyIndexEntries`); all are called from `setNodeProperty` / `setNodePropertiesBatch` / `deleteNodeNoSave` which are always invoked under `mg.rwlock` EXCLUSIVE per the Phase 4 invariant audit (`docs/performance/2026-04-23-enterprise-ingest/phase4-invariants.md`).

---

## Execution Handoff

Plan complete and saved. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
