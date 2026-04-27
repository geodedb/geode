# Bug: `GraphStore.merge_prop_index` HashMap pointer_stability race

**Status:** **RESOLVED** 2026-04-27 — added `merge_prop_index_mutex`
(`std.Io.Mutex`) to `GraphStore` and acquired it inside
`addToMergePropertyIndex`, `removeFromMergePropertyIndex`,
`removeAllMergePropertyIndexEntries`, and `lookupMergeCandidate`.

**Discovered:** 2026-04-27, surfaced as a pre-existing flake during
post-mortem of the bulk-edge cross-shard fix
(`docs/bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md`).

**Severity:** HIGH — every `bulk_insert_node` op routed through the
`group_commit` shard workers exercises this code path; ~3% probability
per `applyShardBatch` of tripping the panic at production scales
(8K-node msft-graph batches → near-certain crash on a 16-shard host).

---

## 1. Symptom

```
thread <id> panic: reached unreachable code
std/debug.zig:420:14: in assert (std.zig)
    if (!ok) unreachable; // assertion failure
std/debug.zig:1823:15: in lock (std.zig)
    assert(l.state == .unlocked);
std/hash_map.zig:1113:44: in getOrPutContextAdapted__anon_… (std.zig)
    self.pointer_stability.lock();
std/hash_map.zig:1100:56: in getOrPutContext (std.zig)
std/hash_map.zig:1026:52: in putContext (std.zig)
std/hash_map.zig:323:45: in put (std.zig)
src/graph_store.zig:1666:46: in addToMergePropertyIndex (lib.zig)
    try self.merge_prop_index.put(key_copy, node_id);
src/graph_store.zig:2033:41: in setNodeProperty (lib.zig)
    self.addToMergePropertyIndex(node.graph_name, node.labels, key, value_copy, node_id) catch {};
src/storage/graph_storage_adapter.zig:1392:38: in bulkInsertNodeWithReservedId (lib.zig)
    try store.setNodeProperty(reserved_id, kv.key, kv.value);
src/storage/group_commit.zig:375:66: in applyShardBatch (lib.zig)
    if (self.adapter.bulkInsertNodeWithReservedId( …
```

Pre-fix: panics ~1/15 runs of `test-group-commit-coordinator`
"16 concurrent submitters land all ops + coalesce batches".

The new tighter reproducer (`tests/test_merge_prop_index_concurrent.zig`)
reproduces the bug 100% of the time pre-fix (confirmed 10/10 runs) and
passes 100% of the time post-fix (confirmed 10/10 runs).

---

## 2. Root cause

`GraphStore.merge_prop_index` is a `std.StringHashMap(u64)` shared by
every thread that mutates the in-memory store.  Before the fix, its
mutators (`addToMergePropertyIndex`, `removeFromMergePropertyIndex`,
`removeAllMergePropertyIndexEntries`) and reader
(`lookupMergeCandidate`) had no lock.

Under group-commit, `applyShardBatch` runs on a per-shard worker
thread; the coordinator spawns N workers that drain shard queues in
parallel.  Each worker eventually calls `bulkInsertNodeWithReservedId`
→ `setNodeProperty` → `addToMergePropertyIndex` →
`merge_prop_index.put`.  When two workers `put` simultaneously and
trigger a rehash, the HashMap's `pointer_stability` mutex catches the
overlap and panics with `assert(l.state == .unlocked)`.

The `merge_prop_index` is GLOBAL across shards — not per-shard — so
shard-local locking does not protect it.  A dedicated mutex on
`GraphStore` is required.

---

## 3. Fix

Added `merge_prop_index_mutex: std.Io.Mutex = std.Io.Mutex.init` to
`GraphStore` and acquire it (lock + `defer unlock`) at the entry of
each access function.

The mutex is tier 1 per the CLAUDE.md mutex-ordering table (alongside
`store_mutex` / per-graph `rwlock`).  Every function that takes it is
a leaf call — none of them call back into another `merge_prop_index`
function while holding the lock — so there is no nesting / lock-order
risk.

`lookupMergeCandidate` was changed from `*const GraphStore` to
`*GraphStore` so it can call `lockUncancelable` on the mutex.  All
existing callers already pass `*GraphStore`, so the signature change
is binary-compatible at the call sites.

---

## 4. Test plan

Added `tests/test_merge_prop_index_concurrent.zig`:

- 16 threads × 200 unique-value inserts each = 3,200 distinct keys.
- Every insert hits the `else` (allocate + put) branch, maximising
  rehash chance.
- Pre-fix: panics 10/10 runs.  Post-fix: passes 10/10 runs.

Wired as `zig build test-merge-prop-index-concurrent` (also runs
inside `zig build test`).

Also re-ran the original flaky test 20× (`test-group-commit-coordinator`):
post-fix 20/20 pass (vs. ~1/15 panic rate pre-fix on HEAD).

---

## 5. Files referenced

- `src/graph_store.zig` — mutex field added near `merge_prop_index`,
  acquired in 4 functions.
- `tests/test_merge_prop_index_concurrent.zig` — new regression test.
- `build.zig` — added `test-merge-prop-index-concurrent` step.
