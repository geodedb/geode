# Phase 4 invariant audit

**Date:** 2026-04-23
**Scope:** every mutation called between `acquireGraphWriteLockCancelable` (`src/server/quic_connection_handler.zig:2452`) and `releaseGraphLock` (`src/server/quic_connection_handler.zig:2856`) on the hot MERGE + CREATE edge path driven by `msft-graph seed`.
**Method:** static trace of `executeProgramWithContext` (`src/execution.zig:786`) → `executeMerge` / `executeCreate` (`src/execution/crud_operations.zig:{2101,1611}`) → `GraphStore` helpers (`src/graph_store.zig`) → `StorageAdapter` engine-txn methods (`src/storage/graph_storage_adapter.zig`).

A call site is classified by the data-structure race it exposes when two threads run it concurrently, not by its nominal "read vs write" verb. HashMap `put` / `getOrPut` on a growing table is the canonical *must-be-exclusive* case (rehash reallocates the slot array out from under a concurrent reader; CWE-362 data race → CWE-416 use-after-free). Sorted-ArrayList `insert` / `append` is the canonical *needs-fine-grained-lock* case (it's O(1) amortised work but still mutates shared backing memory). Map `get` / `getPtr` with no concurrent insert is the canonical *safe-during-reader* case.

---

## Must-be-exclusive (HashMap rehash, ArrayList realloc, linked-list insert)

Every site below must run on the **write** side of the Phase 4 split.

- `GraphStore.createNodeWithGraphAndTenant` @ `src/graph_store.zig:1086` — `self.nodes.put(id, node)`. `std.AutoHashMap(u64, Node)` insert can rehash; concurrent reader's `nodes.getPtr` becomes CWE-416.
- `GraphStore.createEdgeWithGraphAndTenant` @ `src/graph_store.zig:2854` — `self.edges.put(id, edge)`. Same rehash-race as above on `std.AutoHashMap(u64, Edge)`.
- `GraphStore.addToLabelIndex` @ `src/graph_store.zig:1396,1412` — `self.label_index.getOrPut(key)` allocates a new key slot; parent map rehash is the same CWE-362. The `sortedInsert` (line 1402/1418) into `ArrayList(u64)` *also* races even without rehash (see fine-grained section).
- `GraphStore.addToEdgeTypeIndex` @ `src/graph_store.zig:3039,3053` — same `std.StringHashMap` rehash pattern as `addToLabelIndex`.
- `GraphStore.addToAdjacencyIndex` @ `src/graph_store.zig:2981,2988` — `self.outgoing_edges.getOrPut(from_id)` and `self.incoming_edges.getOrPut(to_id)` on `std.AutoHashMap(u64, ArrayList(u64))`. Map-level rehash must be exclusive; the inner-list `append` becomes fine-grained (see below).
- `GraphStore.addToMergePropertyIndex` @ `src/graph_store.zig:1521` — `self.merge_prop_index.put(key_copy, node_id)` on `std.StringHashMap(u64)`. Phase-4 Task 15 reads this index during MATCH; concurrent insert during that read is CWE-362.
- `GraphStore.setNodeProperty` @ `src/graph_store.zig:1840` — `node.properties.getOrPut(key)` on the per-node `std.StringHashMap(PropertyValue)`. Even though the outer `nodes` map is not growing, the per-node value map IS growing, and a MATCH reader iterating `node.properties` races the insert.
- `GraphStore.setEdgeProperty` @ `src/graph_store.zig:3140` — symmetric: `edge.properties.getOrPut(key)` rehashes the per-edge map.
- `GraphStore.addNodeLabel` @ `src/graph_store.zig:2128-2137` — `allocator.alloc(new_labels)` + free of `node.labels` + pointer swap. A reader that captured `node.labels` on entry to MATCH and dereferences after this swap hits CWE-416.
- `IdMap.insertNodeWithSlot` / `IdMap.insertEdgeWithSlot` @ `src/graph_store.zig:1067,2837` — internal HashMap inserts inside the per-graph IdMap; same rehash-race class.
- `UndoLog.appendEntryLocked` @ `src/txn_undo_log.zig:601-606` — `self.entries.append(...)` + `self.entry_txns.append(...)`. The undo log has its own `list_mutex` so this is *intrinsically* safe, but it still reads `t_txn_state.txn_id` which was set up by the outer write-side caller, so the append itself must stay on the write side for logical consistency with the mutation it describes.
- `StorageAdapter.beginStatementTxn` / `beginSessionTxnLazy` @ `src/storage/graph_storage_adapter.zig:2545,2624` — `mg.engine.beginTxn()` mutates engine-internal txn tables (slot allocators, undo page map). Engine txn open / slot allocation / adapter record write for every `createNode`, `setNodeProperty`, `createEdge` call inside this txn must run while the writer side owns the graph.
- `GraphStore.ensureGraph` (called from `createNodeWithGraphAndTenant:1056` and `createEdgeWithGraphAndTenant:2813`) — `self.graphs.put` on a `std.StringHashMap`. Rare on the hot path (graph already exists) but still a rehash race when a new graph is born mid-ingest.
- `ExprRLSEngine` / `schema catalog` — `executeMerge` takes `ensureAutoIndexes` @ `src/execution/crud_operations.zig:2213`, which calls `catalog.ensureAutoIdIndex`. Per the tier table in `CLAUDE.md` (`catalog_mutex` tier 2), the catalog has its own mutex and is NOT protected by `mg.rwlock`; it's safe across the split as long as the tier order is preserved. **Flag**: the auto-index-ensure path also mutates `g_schema_epoch` (`bumpSchemaEpoch`), which is atomic (`.monotonic`) so is safe during a reader — listed here only to confirm it doesn't need the write lock.

---

## Safe-during-reader (read-only store access, atomic primitives)

These are every call made from the current critical section that does **not** mutate `GraphStore` state. All of them can run on the **read** side of the Phase 4 split (i.e. in the MATCH-resolve phase) without correctness risk.

- `findFirstMatchingNodeId` entire body @ `src/execution/crud_operations.zig:132-198` — pure read. Consults `read_store.lookupMergeCandidate` (which is `merge_prop_index.get` + `nodes.get`, both `HashMap.get`), then falls back to `getNodesByLabel` + `nodes.getPtr`. No mutation.
- `GraphStore.lookupMergeCandidate` @ `src/graph_store.zig:1567-1579` — `self.merge_prop_index.get(probe)` + `self.nodes.get(node_id)`. `std.StringHashMap.get` + `std.AutoHashMap.get` are pure reads; safe as long as no concurrent `put` runs (which is exactly what the Phase 4 split guarantees by partitioning reads and writes in time).
- `GraphStore.getNodesByLabel` @ `src/graph_store.zig:1583-1591` — `label_index.get(key)` returns a pointer into the posting list. Safe so long as `addToLabelIndex`/`removeFromLabelIndex` aren't running concurrently — again, the split guarantees that.
- `GraphStore.getOutgoingEdgeIds` (referenced from `findExistingEdgeId` @ `src/execution/crud_operations.zig:269`) — `outgoing_edges.get(from_id)`. Pure HashMap read.
- `findExistingEdgeId` @ `src/execution/crud_operations.zig:261-277` — read-only iteration over `outgoing_edges.get` slice; `edges.getPtr` per iteration.
- `nodeMatchesPattern` / `nodeIdMatchesPattern` / `edgeMatchesScopeAndType` @ `src/execution/crud_operations.zig:249-259,232-247` — pure field comparisons (`std.mem.eql` on `graph_name`, `tenant_id`, labels, properties).
- `evaluatePatternProps` @ `src/execution/crud_operations.zig` (via `envFromContext` → `eval.evalExpr`) — pure expression evaluation on the passed bindings map. No store mutation. (It *does* allocate into the caller allocator; that's not a race.)
- `tenantFilterFromContext` @ `src/execution/crud_operations.zig` — reads `context.auth_user.tenant_id` or similar; immutable.
- `fle_integration.getCurrentTenantId` @ `src/graph_store.zig:1039,2788` — reads a thread-local (FLE role state tier 4 mutex), but only the getter which does not mutate.
- `GraphStore.dirty.store(true, .release)` @ `src/graph_store.zig:1093,2864` — atomic write, no lock needed. Safe from either side but is only meaningful on the write side (no point dirtying during MATCH).
- `incrementMutationEpoch` @ `src/graph_store.zig:5418-5420` — atomic `fetchAdd`. Same class as `dirty`.
- `notifyMutation` @ `src/graph_store.zig:5484-5490` — dispatches to WAL callback; the WAL has its own buffer mutex. Write-side only in practice but does not require `mg.rwlock`.
- Transaction-context plumbing in `executeMerge` (`src/execution/crud_operations.zig:2122-2141`) — `sessionEngineTxnGraph()` reads a thread-local; `ad.beginSessionTxnLazy` is exclusive (see Must-be-exclusive) but the *decision* to call it is safe.
- `context.bindings.get` @ `src/execution/crud_operations.zig:2331-2345` — HashMap read on a per-statement binding map that is not shared across workers.

---

## Needs fine-grained lock (append to per-key posting list is safe with its own mutex)

These sites *look* like "must-be-exclusive" because they mutate, but they can be made concurrent with their own per-posting-list mutex once the outer HashMap is not simultaneously rehashing. Phase 4 Task 17 already tracks this work for the label index; listed here with the primitive for completeness so Task 15 knows the full surface.

- `GraphStore.addToLabelIndex`, the inner `sortedInsert` @ `src/graph_store.zig:1402,1418` — `ArrayList(u64).insert` on the posting list pointed to by `label_index.getPtr(probe_key)`. Adding a `std.Thread.Mutex` embedded in the list value (e.g. change `std.StringHashMap(std.ArrayList(u64))` to `std.StringHashMap(struct { list: ArrayList(u64), mutex: std.Thread.Mutex })`) lets N writers append to *different* labels concurrently, serialising only within a single label. This is the primary Phase 4 throughput win: in msft-graph, 90%+ of nodes share the `:User` or `:Device` label, but even with just two hot labels the contention halves.
- `GraphStore.addToEdgeTypeIndex`, inner `sortedInsert` @ `src/graph_store.zig:3045,3059` — identical pattern on `edge_type_index`. Apply the same per-posting-list mutex.
- `GraphStore.addToAdjacencyIndex`, the inner `append` @ `src/graph_store.zig:2985,2992` — `outgoing_edges.getPtr(from_id).append(edge_id)` and `incoming_edges.getPtr(to_id).append(edge_id)`. Add a `std.Thread.Mutex` to the adjacency-list value. This covers the `MATCH+CREATE edge` hot path in msft-graph's device-ownership statements.
- `GraphStore.addToMergePropertyIndex` iteration loop @ `src/graph_store.zig:1513-1523` — the per-label insert loop. The map itself must be exclusive (see Must-be-exclusive), but after Task 15 lands, a per-*key* mutex on the `std.StringHashMap(u64)` entries could reduce contention further. Mark as "future work" — not blocking for Phase 4.

---

## Task 15 dispatch note

**Yes, the read/write split outlined by plan Task 15 is safe** for the msft-graph MERGE + MATCH+CREATE edge shape. The MATCH phase (`findFirstMatchingNodeId`, `findExistingEdgeId`, `lookupMergeCandidate`, `getNodesByLabel`, `edges.getPtr`, `outgoing_edges.get`) is entirely in the Safe-during-reader category and can run under `mg.rwlock.lockShared`. Every store mutation listed in Must-be-exclusive happens *after* the read-phase lookups complete (in `executeMerge` after line 2162's `nodes.getPtr`; in `executeCreate` directly on `createNodeWithGraph`). The apply-phase can reacquire `mg.rwlock.lock` (exclusive) and re-run a cheap re-check (`lookupMergeCandidate` / `findExistingEdgeId`) to confirm the match is still valid — this handles the case where another writer inserted between the read release and write acquire.

**No must-be-exclusive mutation happens during MATCH in the current code.** The only caveat is `executeCreate`'s session/statement-txn open (`beginStatementTxn` at `src/execution/crud_operations.zig:1673`) currently runs *before* any MATCH — for Task 15 it should be moved to after the MATCH-resolve phase, inside the write-lock block, otherwise the engine txn is opened even when the MATCH fails.
