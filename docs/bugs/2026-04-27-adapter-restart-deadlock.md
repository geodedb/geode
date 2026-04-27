# Bug: `NodePropertyExactIndex.loadFromFile` self-deadlock on adapter reopen

**Status:** **RESOLVED** 2026-04-27 — split `clear()` into `clear()`
(public, locks) and `clearLocked()` (assumes mutex held); changed the
in-function call inside `loadFromFile` to `clearLocked()`.

**Discovered:** 2026-04-27, surfaced as a pre-existing hang during
post-mortem of the bulk-edge cross-shard fix
(`docs/bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md`).

**Severity:** HIGH for any deployment that:

- checkpoints a graph with at least one indexed node property, AND
- restarts (the on-disk `prop_exact.idx` file exists, so reopen takes
  the `loadFromFile` branch instead of `rebuildExactNodePropertyIndex`).

The first such reopen will hang the process indefinitely.

---

## 1. Symptom

`StorageAdapter: registry persists graph discovery across restart`
(in-source test at `src/storage/graph_storage_adapter.zig:4466`,
test 93/153 in the `lib_unit_tests` binary) hangs the test runner
deterministically with no output.  GDB stack of the main thread:

```
storage.graph_storage_adapter.NodePropertyExactIndex.clear (line 87)
    self.mutex.lockUncancelable(io)            ← BLOCKED
storage.graph_storage_adapter.NodePropertyExactIndex.loadFromFile (line 250)
    self.clear()                                ← still holds self.mutex
storage.graph_storage_adapter.StorageAdapter.openGraphLocked (line 3418)
    mg.exact_node_property_index.loadFromFile(dir_path)
storage.graph_storage_adapter.StorageAdapter.getOrCreateGraph
test "adapter registry: persistence across restart"
```

The other 4 threads are idle thread-pool workers in
`pool.Core.workerMain` blocked on their own condition variables —
they aren't holding the mutex, so this is a *self-deadlock* of the
main test thread.

Also reproduces 100% in a standalone reproducer
(`tests/test_adapter_registry_restart.zig`) with no other prior tests
to provide leaked state.

---

## 2. Root cause

`NodePropertyExactIndex` (defined inline in
`src/storage/graph_storage_adapter.zig:59-288`) protects its
`std.StringHashMap(std.ArrayList(u64))` posting list with a
`std.Io.Mutex` field.  Mutator methods (`add`, `remove`, `get`,
`clear`, `saveToFile`, `loadFromFile`) all acquire the mutex at
function entry and release it on return.

`loadFromFile` (line 225) does:

```zig
self.mutex.lockUncancelable(io);
defer self.mutex.unlock(io);
…
self.clear();                       // ← self.mutex held; clear() locks it AGAIN
```

`std.Io.Mutex` is **non-reentrant**.  The recursive `lockUncancelable`
call inside `clear()` blocks forever waiting for the outer call to
release.

The bug only surfaces on the **reopen** path because that is the only
code path that exercises `loadFromFile`.  The `rebuildExactNodePropertyIndex`
fallback (used when no `prop_exact.idx` file exists) calls `clear()`
without holding the mutex, so it works fine.  A cold start (no prior
checkpoint → no on-disk index file → fallback path) never hits the
bug; only a *restart after checkpoint* does.

---

## 3. Fix

Split `clear()` into two functions:

```zig
fn clear(self: *NodePropertyExactIndex) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.clearLocked();
}

/// Caller must hold `self.mutex`.
fn clearLocked(self: *NodePropertyExactIndex) void {
    var it = self.postings.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(self.allocator);
    }
    self.postings.clearAndFree();
}
```

`loadFromFile` (line 250) now calls `clearLocked()` since it already
holds the mutex.  `rebuildExactNodePropertyIndex`
(graph_storage_adapter.zig:735) continues to call `clear()` since it
does not hold the mutex.

This matches the prevailing codebase pattern of `…Locked` suffix for
helpers that expect their caller to already hold the relevant mutex
(e.g. `requireExistingGraphLocked`, `findRegistryEntryLocked`,
`createGraphLocked`, `openGraphLocked`).

---

## 4. Test plan

Added `tests/test_adapter_registry_restart.zig`:

- Mirrors the in-source test 93 1:1 (open → createNode →
  setNodeProperty → checkpointAll → close → reopen → graphExists →
  listGraphNames → getOrCreateGraph → nodeCount).
- Pre-fix: hangs forever on the second `getOrCreateGraph` call.
- Post-fix: passes deterministically (5/5 runs).

Wired as `zig build test-adapter-registry-restart` (also runs inside
`zig build test`).

---

## 5. Files referenced

- `src/storage/graph_storage_adapter.zig:85-105` — `clear()` /
  `clearLocked()` split.
- `src/storage/graph_storage_adapter.zig:255-260` — `loadFromFile`
  now calls `clearLocked()`.
- `tests/test_adapter_registry_restart.zig` — new regression test.
- `build.zig` — added `test-adapter-registry-restart` step.
