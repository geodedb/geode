# Bug: Concurrent bulk-edge insert silently drops IdMap mapping → `EdgeSlotMappingMissing`

**Status:** **RESOLVED** 2026-04-27 — two-part fix landed:

1. `src/graph_store.zig` `createEdgeWithGraphAndTenant`: replaced the silent
   `catch break :blk null` arms with `try` /
   `return error.{Source,Target}NodeNotFound` so engine errors propagate to the
   caller instead of being swallowed (the Tier-1 fix from §5.1).
2. `src/storage/graph_storage_adapter.zig` `createEdge`: gated the per-shard
   `addEdgeTxn` fast path on `shardOfNode(from) == shardOfNode(to)`.  Cross-
   shard edges now fall through to `ShardedGraphEngine.addEdge` →
   `crossShardAddEdge` (2PC), which is the correct routing for that case.

The Tier-1 fix surfaced the underlying bug (per §6 step 2): the per-shard
`addEdgeTxn` fast path was being taken for cross-shard edges, where the
target node lives on a different shard's `node_store` and the engine's
`getNode(to)` returns null → `error.NodeNotFound`.  The (now-deleted) silent
fallback was the only thing masking this in the bulk-ingest path.

After the combined fix, `zig build test-two-phase-edge-lock` passes
deterministically (3/3 tests, 800/800 parallel edges, throughput within
1.5× of the single-thread baseline) across repeated runs.

**Original status:** OPEN — pre-existing on `main` (reproduces both with and
without the 2026-04-27 IdMap mutex hardening; mutex makes the symptom worse
but is not causal).

**Discovered:** 2026-04-27 while running `zig build test-two-phase-edge-lock`
during the post-IdMap-mutex unit-test pass.

**Reporter:** Claude (during /codepros:bug-fix iter loop on the geode push
backlog).

**Severity:** HIGH for any caller that mixes `bulkInsertEdgeWithIds` with
follow-up property writes under multi-threaded contention; LOW for
single-threaded callers and for the steady-state msft-graph ingest path that
already serialises through the per-graph write lock.

**Filed against:** `src/graph_store.zig` —
`createEdgeWithGraphAndTenant` (line 2975) silent error swallowing in the
`adapter_edge` block (lines 2982–2992).

---

## 1. Symptom

`zig build test-two-phase-edge-lock` fails on
`tests/bulk_ingest/test_two_phase_edge_lock.zig:197 "two-phase lock: 16 threads
beat single-thread by >= 4x"` with multiple

```
error: EdgeSlotMappingMissing
    src/graph_store.zig:907 in requireEdgeSlot
    src/graph_store.zig:3434 in setEdgePropertiesBatch
    src/storage/graph_storage_adapter.zig:1820 in bulkInsertEdgeWithIds
    tests/bulk_ingest/test_two_phase_edge_lock.zig:137 in twoPhaseInsertEdge
    tests/bulk_ingest/test_two_phase_edge_lock.zig:181 in concurrentWorker
```

…followed by

```
expected 800, found <N>
testing.zig:118 in expectEqualInner
test_two_phase_edge_lock.zig:276 in test
```

where `N < 800` (16 threads × 50 edges each).

**Observed N (varies with contention shape):**

| Branch                              | N (parallel_edges) | Edges lost |
|-------------------------------------|--------------------|------------|
| `main` baseline (no IdMap mutex)    | 663                | 137        |
| `main` + IdMap `std.Io.Mutex` fix   | 434                | 366        |

The IdMap mutex serialises IdMap reads/writes (it fixes a separate, real
segfault path), but it slows each thread enough that more workers reach the
buggy code window simultaneously, so the silent-fallback failure mode shows up
*more often*. Removing the mutex is **not** a fix — it just hides one of two
co-existing bugs.

---

## 2. Reproduction

### 2.1 Minimal repro

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode
zig build test-two-phase-edge-lock 2>&1 | tail -60
```

Reproduces deterministically on every run on a 16-CPU host. Reproduces less
reliably (sometimes 0–10 lost) on 4-CPU CI runners — concurrency is the
forcing function.

### 2.2 Test source

`tests/bulk_ingest/test_two_phase_edge_lock.zig:197` (constants at lines
161–162):

- `thread_count = 16`
- `edges_per_thread = 50`
- Each worker holds the per-graph **EXCLUSIVE write lock** via
  `acquireGraphWriteLockCancelable` for the full duration of one edge insert
  (lines 132–137).

So the failure is **not** caused by overlapping write critical sections — the
lock is real and the deadline is generous (30 s). The bug occurs *inside* one
worker's exclusive write window, between `createEdgeWithGraph` and
`setEdgePropertiesBatch` (separated by ~1 µs in the same thread).

---

## 3. Root cause

### 3.1 The smoking-gun code

`src/graph_store.zig:2975-3052` —
`GraphStore.createEdgeWithGraphAndTenant`:

```zig
pub fn createEdgeWithGraphAndTenant(...) !u64 {
    const adapter_edge: ?struct { ... } = blk: {
        const vt = global_vtable orelse break :blk null;
        const im = self.getOrCreateIdMap(graph_name) catch break :blk null;
        const from_slot = im.nodeSlot(@as(u128, from_id)) orelse break :blk null;
        const to_slot   = im.nodeSlot(@as(u128, to_id))   orelse break :blk null;
        const edge_slot = vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type)
            catch break :blk null;                           // ← (A)
        break :blk .{ .vt = vt, .from_slot = from_slot,
                      .to_slot = to_slot, .edge_slot = edge_slot };
    };

    try self.ensureGraph(graph_name);
    const id = generateTimeBasedId();

    if (adapter_edge) |persisted_edge| {
        // …persist + insert into IdMap…
        const im = try self.getOrCreateIdMap(graph_name);
        try im.insertEdgeWithSlot(@as(u128, id), persisted_edge.edge_slot);   // ← (B)
    }
    // ↓ ALWAYS runs, even when (A) failed and IdMap was NOT updated:
    try self.edges.put(id, edge);                                              // ← (C)

    return id;
}
```

There are **five** places inside the `blk` block that can `break :blk null`:

1. `global_vtable == null` — never happens after server boot.
2. `getOrCreateIdMap` returns `error.OutOfMemory`.
3. `im.nodeSlot(from_id) == null` — endpoint was just deleted.
4. `im.nodeSlot(to_id)   == null` — endpoint was just deleted.
5. **`vt.createEdgeFn(...)` returns ANY error.** ← This is the one that fires.

When (5) happens, `adapter_edge` is `null`, so the `if (adapter_edge) |…|`
block at line 2999 is skipped. **No IdMap insert.** But execution continues
into line 3035 (`try self.edges.put(id, edge);`), so the edge is still
written to the in-memory store.

The caller (`bulkInsertEdgeWithIds`) then proceeds:

```zig
// src/storage/graph_storage_adapter.zig:1798–1820
const edge_id = try store.createEdgeWithGraph(...);          // returns id
…
try store.setEdgePropertiesBatch(edge_id, entries);          // → requireEdgeSlot → boom
```

`setEdgePropertiesBatch` (`src/graph_store.zig:3434`) calls
`requireEdgeSlot` (`graph_store.zig:905-908`) which looks up
`id_map.edgeSlot(edge_id)` — **which was never inserted**, because point (B)
above was skipped.

Result: `error.EdgeSlotMappingMissing`.

### 3.2 Why does `vt.createEdgeFn` fail under contention?

`vt.createEdgeFn` routes into `StorageAdapter.createEdge` (per-graph), which
goes through the sharded engine's edge allocator. Under contention from 16
parallel inserters, the most likely failure modes are:

- **Per-graph adapter allocator returning `error.OutOfMemory`** during shard
  rehash — needs verification under the perf harness; not yet
  instrumented.
- **`error.GraphNotFound`** if `ensureGraphExistsForBulk` did not yet run on
  this thread — the test holds the per-graph write lock but the adapter's
  `graphs` registry is itself a `StringHashMap` and another thread's
  `ensureGraph` could in principle be mid-rehash, returning a transient
  miss.
- **`error.DuplicateEdgeSlot`** in the engine if two threads' UUIDv7 IDs
  collide on the engine slot allocator — UUIDv7 has microsecond resolution
  so 16 parallel threads inserting in the same microsecond can theoretically
  collide on the per-shard sequence counter. Needs a counter dump to
  confirm.

The root fix does **not** depend on which of these errors fires. The bug is
that we silently drop into the in-memory-only branch instead of returning
the underlying error to the caller.

### 3.3 Why this is invisible single-threaded

In single-threaded use:

- `ensureGraph` always returns the same registry slot.
- UUIDv7 IDs cannot collide (single thread → strictly monotonic timestamp).
- Per-shard allocators have no concurrent writers.

So the `catch break :blk null` arm at line 2986 is unreachable in practice.
The test's BASELINE phase (lines 225–253) exercises the same code path
single-threaded and inserts all 800 edges cleanly — confirming the failure
is concurrency-only.

---

## 4. Why the IdMap `std.Io.Mutex` fix is correct but insufficient

The IdMap fix in `src/storage/id_map.zig` (commit pending) replaces an
unsynchronized `std.AutoHashMap` access with a `std.Io.Mutex` that
serialises every `insertEdge*`, `removeEdge`, `edgeSlot`, `nodeSlot`, etc.
This is necessary because `IdMap` is shared across threads and the previous
code raced on `AutoHashMap.put` (memory corruption + sporadic
`EdgeSlotMappingMissing` via a *different* path: torn writes).

After the mutex:

- The torn-write path is closed.
- Every `EdgeSlotMappingMissing` we see in the failing test traces back to
  the silent-fallback bug described in §3.1 — i.e. the mapping was *never
  inserted*, not corrupted.

So the IdMap mutex is a **prerequisite** for fixing this bug, but it is not
sufficient on its own.

---

## 5. Proposed fixes (ordered by surgical-ness)

### 5.1 Tier 1 — Stop swallowing the error (recommended, ~10 LoC)

In `src/graph_store.zig:2982-2992`, change the `catch break :blk null` arms
to propagate the error:

```diff
 const adapter_edge: ?struct { ... } = blk: {
     const vt = global_vtable orelse break :blk null;
-    const im = self.getOrCreateIdMap(graph_name) catch break :blk null;
-    const from_slot = im.nodeSlot(@as(u128, from_id)) orelse break :blk null;
-    const to_slot   = im.nodeSlot(@as(u128, to_id))   orelse break :blk null;
-    const edge_slot = vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type)
-        catch break :blk null;
+    const im = try self.getOrCreateIdMap(graph_name);
+    const from_slot = im.nodeSlot(@as(u128, from_id))
+        orelse return error.SourceNodeNotFound;
+    const to_slot   = im.nodeSlot(@as(u128, to_id))
+        orelse return error.TargetNodeNotFound;
+    const edge_slot = try vt.createEdgeFn(vt.ctx, graph_name, from_slot,
+                                           to_slot, edge_type);
     break :blk .{ ... };
 };
```

The `vt == null` arm is the only legitimate fallback — kept as `orelse
break :blk null` so server-startup paths that pre-populate the in-memory
store still work.

The `try` chain converts (a) "endpoint deleted in flight" into the
canonical `Source/TargetNodeNotFound` error that callers already handle,
and (b) "engine allocator failed" into a pass-through error that the
caller can decide to retry or surface.

### 5.2 Tier 2 — Add a debug assertion before `self.edges.put` (~3 LoC)

```zig
if (build_options.debug_assertions and global_vtable != null and adapter_edge == null) {
    std.debug.panic("createEdgeWithGraphAndTenant: dropped adapter persistence " ++
                     "for graph='{s}' from={d} to={d}", .{graph_name, from_id, to_id});
}
```

This catches any future code that re-introduces the silent fallback.

### 5.3 Tier 3 — Return-codes audit (largest scope, follow-up)

`grep -rn "catch break :blk" src/graph_store.zig` returns ~40 hits. Many are
legitimate (e.g. optional dirty-tracking that should not fail the mutation),
but several mirror this same pattern of "silently skip adapter persistence
on error". A targeted audit should enumerate which ones actually need the
silent fallback (fewer than half, by inspection).

Track as a separate work item; not blocking for the current fix.

---

## 6. Test plan for the fix

After applying §5.1:

1. `zig build test-two-phase-edge-lock` should still fail, but with a
   *different* error: `error.SourceNodeNotFound` /
   `error.TargetNodeNotFound` / the underlying engine error from
   `createEdgeFn` instead of `EdgeSlotMappingMissing` from
   `setEdgePropertiesBatch`. This proves the silent fallback is closed.
2. Investigate the now-surfaced underlying error in
   `bulkInsertEdgeWithIds`. Likely candidates and follow-up fixes:
   - **`error.GraphNotFound`** → adapter `graphs` registry needs the same
     mutex treatment as the IdMap (separate bug).
   - **`error.DuplicateEdgeSlot`** → engine slot allocator needs an atomic
     fetch-add instead of read/write split (separate bug).
   - **Intermittent `error.OutOfMemory`** → genuine resource issue; back
     off and retry.
3. After the underlying engine fix, the test should pass with `parallel_edges
   == 800` AND demonstrate the ≥1.5× speedup the test originally asserts at
   line 297.

---

## 7. Files referenced

- `src/graph_store.zig:2975-3052` — `createEdgeWithGraphAndTenant` (root cause).
- `src/graph_store.zig:905-908`  — `requireEdgeSlot` (where the symptom
  surfaces).
- `src/graph_store.zig:3429-3485` — `setEdgePropertiesBatch` (caller of
  `requireEdgeSlot`).
- `src/storage/graph_storage_adapter.zig:1757-1825` —
  `bulkInsertEdgeWithIds` (high-level caller).
- `src/storage/id_map.zig` — IdMap mutex fix (sister change, prerequisite).
- `tests/bulk_ingest/test_two_phase_edge_lock.zig:197-330` — failing test.
- `build.zig:3539` — `test-two-phase-edge-lock` build step.

---

## 8. Cross-references

- Sister bug: `IdMap` `std.AutoHashMap` race (closed by 2026-04-27 IdMap
  mutex commit — see `src/storage/id_map.zig` history).
- Adjacent code path with the same anti-pattern:
  `createEdgeWithIdInternal` (`src/graph_store.zig:3054-3133`) — uses
  `try self.requireNodeSlot(...)` instead of `orelse break :blk null`,
  which is what §5.1 wants `createEdgeWithGraphAndTenant` to do too. Use as
  the reference pattern.
- The `acquireGraphWriteLockCancelable` per-graph rwlock
  (`src/graph_store.zig:5468-5512`) does serialise exclusive writers
  correctly — the bug is **not** a missing lock, it's a swallowed error
  *inside* the locked region.
