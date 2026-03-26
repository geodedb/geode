# Graph Storage Phase 3: Old Storage Removal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `graph-storage` adapter the sole durable storage system. Remove old file persistence, delete `graph_handle.zig` and `graph_registry.zig`, and slim `graph_store.zig` to a type-definition + read-cache shim.

**Architecture:** Phase 2's dual-write already keeps both the adapter and the HashMap in sync. The HashMap stays as a **read cache** for the 9 files with 170+ direct accesses — changing those iteration patterns is unnecessary since the cache is always consistent. What we remove: (1) old file persistence (`saveToFile`, `loadFromFile`, `savePerGraphFiles`, etc.), (2) the background persistence thread, (3) per-graph handle management (`GraphHandle`, `GraphRegistry`), (4) dead code from graph_store.zig. On startup, the adapter loads data from its page-based files; the cache is populated via the adapter's loading routine.

**Tech Stack:** Zig 0.15.1, existing `StorageAdapter` at `src/storage/graph_storage_adapter.zig`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/graph_store.zig` | Remove persistence code, per-graph handles, persistence thread; keep types + cache + API |
| Delete | `src/graph_handle.zig` | Per-graph data containers — replaced by adapter's per-graph engines |
| Delete | `src/graph_registry.zig` | Graph name-to-UUID registry — replaced by adapter's engines map |
| Modify | `src/server/server_init.zig` | Use adapter as primary storage; skip old file loading when adapter is available |
| Modify | `src/storage/graph_storage_adapter.zig` | Add `loadAllIntoCache()` method to warm the HashMap cache on startup |
| Modify | `src/lib.zig` | Remove graph_handle, graph_registry re-exports if present |
| Modify | Files importing graph_handle/graph_registry | Update imports (likely <5 files) |

---

### Task 1: Remove Old File Persistence from GraphStore

**Files:**

- Modify: `src/graph_store.zig`

This is the biggest single task. We remove ~2000+ lines of serialization/deserialization code while keeping the types, cache HashMap, and public API methods.

- [ ] **Step 1: Identify and remove persistence methods**

In `src/graph_store.zig`, find and DELETE the bodies of these methods (replace with no-ops or remove entirely):

**Serialization methods to gut (replace body with `return;` or empty):**

- `saveToFile` (~line 2922) — replace with: `if (global_adapter) |a| { a.checkpointAll() catch {}; return; }`
- `saveIfDirty` (~line 3241) — replace with: `if (global_adapter) |a| { a.checkpointAll() catch {}; } self.dirty = false;`
- `serializeToTempFile` — delete entirely or make no-op
- `serializeToBuffer` — delete entirely or make no-op
- `savePerGraphFiles` (~line 2778) — delete entirely or make no-op
- `saveGraphHandleToFile` (~line 3866) — delete entirely
- `loadFromFile` (~line 3267) — replace with no-op (adapter handles loading)
- `loadPerGraphFiles` (~line 2854) — delete entirely
- `loadGraphHandleFromFile` (~line 3991) — delete entirely

**DO NOT delete:** Types (Node, Edge, PropertyValue, Path), public API methods (createNodeWithGraph, getEdgesFrom, etc.), cache HashMaps (nodes, edges, label_index, outgoing_edges, incoming_edges), or the methods from Phase 2 that delegate to the adapter.

- [ ] **Step 2: Remove the background persistence thread**

Find and delete:

- `startPersistenceThread` (~line 4397)
- `stopPersistenceThread` (~line 4409)
- `signalPersistence` (~line 4379)
- Any `persist_cond`, `persist_mutex`, `persist_thread` fields

Replace `startPersistenceThread` with a no-op that logs:

```zig
pub fn startPersistenceThread(self: *GraphStore, interval_ms: u64) void {
    _ = self;
    _ = interval_ms;
    // Persistence is now handled by graph-storage adapter checkpointing
}
```

- [ ] **Step 3: Remove per-graph handle fields and methods**

Remove from GraphStore struct:

- `graph_handles: std.StringHashMap(*GraphHandle)` field
- `graph_handles_rwlock: std.Thread.RwLock` field
- `use_per_graph_storage: bool` field
- `getHandle()` method
- All code blocks guarded by `if (self.use_per_graph_storage)` — replace with nothing (the adapter handles per-graph isolation)

**IMPORTANT:** Many methods have `if (self.use_per_graph_storage)` blocks that route to GraphHandle. These entire blocks can be deleted since the adapter handles per-graph isolation.

- [ ] **Step 4: Remove GraphHandle and GraphRegistry imports**

In `src/graph_store.zig`, find and remove:

```zig
const GraphHandle = @import("graph_handle.zig").GraphHandle;
const GraphRegistry = @import("graph_registry.zig").GraphRegistry;
```

And any code that references these types.

- [ ] **Step 5: Remove WAL/mutation callback infrastructure**

Remove:

- `setMutationNotify` (~line 4305)
- `setMutationNotifyInhibit` (~line 4310)
- `setWalPersistenceHooks` (~line 4335)
- Any `mutation_notify_fn`, `mutation_inhibit`, `wal_checkpoint_fn`, `wal_truncate_fn` fields

The adapter's GraphEngine has its own WAL.

- [ ] **Step 6: Remove TDE file encryption integration**

Remove any calls to:

- `tde.readDecryptedFile()` / `tde.writeEncryptedFile()`
- TDE-related imports and persistence hooks

The adapter's GraphEngine has optional AES-256 encryption built in (`GraphConfig.encryption_key`).

- [ ] **Step 7: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`

This WILL have errors from removed methods. Fix each one by:

- If a caller references a deleted method → make the method a no-op stub
- If a caller references a deleted field → remove the reference or stub it
- Iterate until the build passes

- [ ] **Step 8: Commit**

```bash
git add src/graph_store.zig
git commit -m "refactor: remove old file persistence from GraphStore — adapter is now sole storage"
```

---

### Task 2: Delete graph_handle.zig and graph_registry.zig

**Files:**

- Delete: `src/graph_handle.zig`
- Delete: `src/graph_registry.zig`
- Modify: Any files that import them (besides graph_store.zig which was updated in Task 1)

- [ ] **Step 1: Find all importers**

Run: `grep -rn "graph_handle\|graph_registry" src/ --include="*.zig" | grep -v "graph_store.zig" | grep -v ".zig-cache"`

For each file found:

- If it only imports types → remove the import
- If it calls methods → replace with adapter equivalents or remove dead code

- [ ] **Step 2: Delete the files**

```bash
rm src/graph_handle.zig src/graph_registry.zig
```

- [ ] **Step 3: Fix compilation errors**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`

Fix each error. Common patterns:

- `graph_handle.zig not found` → remove the import line
- `GraphHandle undefined` → remove code that references it
- `GraphRegistry undefined` → remove code that references it

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: delete graph_handle.zig and graph_registry.zig — replaced by adapter"
```

---

### Task 3: Update Server Initialization

**Files:**

- Modify: `src/server/server_init.zig`

The server currently loads from old files, initializes WAL, replays WAL. Replace with adapter-only initialization.

- [ ] **Step 1: Replace old storage initialization**

In `server_init.zig`, find the section that does:

```zig
const store = graph_store.getGlobalStore(allocator);
```

Replace the surrounding block (old file loading, WAL replay, persistence hooks) with:

```zig
    // Initialize graph-storage adapter as primary storage
    if (data_dir) |dir| {
        const adapter = try graph_store.initGlobalAdapter(allocator, dir);
        // Load existing graphs from adapter into the cache
        // The adapter's GraphEngines handle their own WAL replay on open()
        _ = adapter;
    }

    // Initialize the local cache (GraphStore) for backward-compatible reads
    const store = graph_store.getGlobalStore(allocator);
    _ = store;
```

Remove:

- Old WAL initialization (`wal.initGlobalWal`)
- Old WAL replay (`w.replay(store)`)
- Old persistence hooks (`installMutationCallback`, `installPersistenceHooks`)
- Old persistence thread start
- Old storage migration detection

The adapter's `GraphEngine.open()` automatically replays its own WAL on startup.

- [ ] **Step 2: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`

- [ ] **Step 3: Commit**

```bash
git add src/server/server_init.zig
git commit -m "refactor: use adapter as primary storage in server initialization"
```

---

### Task 4: Clean Up lib.zig and Storage Module Exports

**Files:**

- Modify: `src/lib.zig`
- Modify: `src/storage/mod.zig`

- [ ] **Step 1: Remove graph_handle and graph_registry from lib.zig**

In `src/lib.zig`, remove any re-exports of graph_handle or graph_registry:

```zig
// DELETE these lines if they exist:
pub const graph_handle = @import("graph_handle.zig");
pub const graph_registry = @import("graph_registry.zig");
```

- [ ] **Step 2: Update storage/mod.zig**

Add the adapter as the primary storage export:

```zig
pub const graph_storage_adapter = @import("graph_storage_adapter.zig");
```

- [ ] **Step 3: Verify build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`

- [ ] **Step 4: Commit**

```bash
git add src/lib.zig src/storage/mod.zig
git commit -m "refactor: update module exports — adapter replaces graph_handle/graph_registry"
```

---

### Task 5: Full Build, Tests, and Regression Verification

- [ ] **Step 1: Run full build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build 2>&1 | tail -20`

- [ ] **Step 2: Run unit tests**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | tail -20`

- [ ] **Step 3: Run geodetestlab regression**

Run: `cd /home/benji/src/devnw/codepros/geode/geode-test-harness && geodetestlab run --spec geodetestlab-cli/specs/dsn_graph_binding.yml 2>&1 | tail -15`

- [ ] **Step 4: Fix any regressions**

The most likely issues:

- Methods that were deleted but still called → stub them
- Fields that were removed but still referenced → remove the reference
- Test files that import deleted modules → update imports

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "fix: resolve all regressions from old storage removal"
```

---

## What This Achieves

After Phase 3:

- **`graph-storage` is the sole durable storage** — all data persists through GraphEngine page files
- **`graph_store.zig` is ~2000 lines** (down from ~5168) — types, cache, API shim
- **`graph_handle.zig` deleted** (640 lines removed)
- **`graph_registry.zig` deleted** (371 lines removed)
- **~3000 lines of persistence code removed** from graph_store.zig
- **Old WAL, persistence thread, TDE file hooks removed** — adapter handles all of this
- **Zero changes to Bucket C files** (match_operations, crud_operations, etc.) — they still read from the HashMap cache
- **All existing tests pass** — the cache ensures backward compatibility

## What Remains After Phase 3

The HashMap in graph_store.zig is an in-memory read cache. It's populated:

- On startup: by loading from the adapter (future optimization)
- During runtime: by the dual-write in Phase 2's method delegations

A future Phase 4 (optional) could:

- Add a `warmCacheFromAdapter()` routine for server restart scenarios
- Gradually migrate Bucket C files to use adapter directly (eliminating the cache)
- Eventually delete graph_store.zig entirely
