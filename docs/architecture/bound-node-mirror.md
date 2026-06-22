# Bounded node mirror (GAP-0900 Layer-3 follow-up)

## Problem

`GraphStore.nodes: ShardedStore(u64, Node)` (src/graph_store.zig) is the legacy
in-memory **mirror** of the disk-backed engine. It holds a full `Node`
(`labels`, `properties` as `CompactPropertyMap`, `graph_name`, `tenant_id`)
resident for **every** node, forever — never evicted. Measured footprint on
this branch's baseline benchmark (`zig build bench-gap0900-node-mirror`):

| nodes   | RSS delta | bytes/node |
|---------|-----------|------------|
| 100,000 | 890 MB    | 8,901      |
| 200,000 | 1,718 MB  | 8,593      |
| 300,000 | 2,431 MB  | 8,105      |

RSS grows **linearly** at ~8 KB/node. A full 14.27M-node ingest needs
~114 GB resident → OOM on any reasonable box. geode is DISK-BACKED by design;
the resident mirror is the blocker.

## Engine is the durable store of record (write-through invariant)

Every write updates BOTH the engine (disk-backed, bounded buffer pool) AND the
mirror (dual-write / write-through):

- bulk path: engine `graph_storage_adapter.zig` (`putNodeTxn`/`putPropertyTxn`)
  - mirror `createNodeWithReservedIdAndSlotGraphAndTenant` / `setNodePropertiesBatchInMemoryOnly`.
- point path: `setNodeProperty`, `setNodePropertiesBatch`, `addNodeLabel`, etc.
  call the adapter vtable AND mutate the mirror.

Therefore the engine is **never stale**. This is the key invariant that makes a
bounded, evict-freely cache SAFE: any node dropped from the mirror can be
rebuilt from the engine bit-for-bit.

The engine can serve all `Node` fields by id:

- labels: `adapter.getNodeLabels(graph, id)` (engine `getNode` + `label_store.getLabels` + `label_dict.getString`)
- all properties: `adapter.getAllNodeProperties(graph, id)`
- graph_name: the adapter graph the node lives in
- tenant_id: internal property `__geode_tenant_id` (absent ⇒ DEFAULT_TENANT_ID)

`src/server/node_scan_stream.zig:materializeNode` already rebuilds a full
`*Node` from the engine by slot — the template for hydrate-on-miss.

## The fix: bounded node cache with hydrate-on-miss + write-through

`GraphStore.nodes` becomes a `BoundedNodeCache` (src/storage/node_cache.zig):
a wrapper over the same `ShardedStore(u64, Node)` plus a CLOCK eviction index
and a resident-entry cap (`GEODE_NODE_CACHE_ENTRIES`, default 1_000_000).

1. **Bound**: on insert beyond the cap, evict cold entries. The engine has the
   durable copy.
2. **Hydrate-on-miss**: a lookup miss fetches the node from the engine via a
   read vtable hook (`hydrateNodeFn`, analogous to the existing write
   `global_vtable`), inserts it into the cache (evicting if needed), and returns
   it. The ~31 `nodes.get`/`getPtr` read sites stay transparent.
3. **Bulk path is self-bounding**: the bulk insert filling the cache hits the
   cap and evicts → ingest RSS is bounded by the cache size, not the node count.
4. **Iterate-all paths stream from the engine** (snapshot/clone, recovery) —
   they must not assume full residence.
5. **Write-through stays intact**: the engine remains authoritative; deletes and
   label/property changes update or invalidate the cache entry.

## Pointer-lifetime safety — THE critical invariant

`getPtr(id)` returns `*const Node` that callers **store and use across an
extended span** — e.g. `graph_algorithms.zig` appends `node_ptr` into a
`Value{.Path}` result that is serialized much later, all under the query's
enclosing lock. `getNodeProperty` returns a `PropertyValue` whose `.String`
borrows the entry's property storage, used after the call returns. So a returned
pointer / borrowed slice must stay valid **for the duration of the
lock-holding critical section the caller runs in** — exactly the lifetime model
the current never-evicting mirror already relies on.

### Locking reality (verified)

- Reads hold a per-graph read lock that takes the global `g_store_rwlock`
  SHARED for the whole query (`acquireGraphReadLockTagged`).
- Per-graph **writes** ALSO take `g_store_rwlock` SHARED (R6 change) and rely on
  the per-graph `mg.rwlock` for the exclusive-writer guarantee. So
  `g_store_rwlock` is held SHARED by readers AND writers concurrently; it goes
  EXCLUSIVE only for whole-graph ops (legacy fallback, persistence/checkpoint
  snapshot, deinit).
- The bulk-ingest path that needs eviction holds `g_store_rwlock` SHARED, not
  EXCLUSIVE.

Consequence: free-running eviction that **frees** an entry's heap at an
arbitrary time is NOT safe — a concurrent reader may hold a `*Node` into that
entry, and the evictor cannot take a lock that excludes all in-flight pointer
users without also blocking the bulk writers (they share SHARED).

### Resolution: unlink-now, free-at-grace (epoch reclamation)

Eviction is split into two phases:

1. **Unlink** (cheap, frequent): remove the entry from the cache map under the
   cache's own per-shard lock. Future lookups miss → hydrate-on-miss. The
   `Node`'s heap is NOT freed yet; it is pushed onto a per-cache **retire list**
   tagged with the current **reclaim epoch**.
2. **Reclaim** (at a grace boundary): free retired nodes only when no reader
   that could hold a pointer to them remains — i.e. when the **global
   `g_store_rwlock` is held EXCLUSIVE**. That exclusive window already happens at
   every checkpoint (`checkpointAll*` acquires whole-graph/global exclusive) and
   at `deinit`. Taking `g_store_rwlock` EXCLUSIVE drains all SHARED holders
   (readers and per-graph writers), so any pointer handed out before the window
   is provably dead after it. We bump the reclaim epoch on entering the window
   and free every retired node whose tag is < the new epoch.

**INVARIANT (pointer safety):**
> A `Node`'s heap (labels, property keys/values, graph_name, tenant_id) is freed
> only inside a `g_store_rwlock` EXCLUSIVE window, after which no
> previously-handed-out `*Node`/borrowed slice into it can be live, because every
> reader and per-graph writer holds `g_store_rwlock` at least SHARED for the
> whole span it uses such a pointer, and EXCLUSIVE excludes all SHARED holders.
> Between windows, evicted entries are only *unlinked* (removed from lookup),
> never freed, so outstanding pointers remain valid.

This bounds RSS to `cap + retire_backlog`. The retire backlog is bounded by the
checkpoint cadence (`GEODE_CHECKPOINT_OPS`, ~50K–200K nodes), not the total node
count — so RSS plateaus.

During a pure bulk ingest the evicted ids are write-only (not being read), so
hydrate-on-miss churn is ~zero and checkpoints fire on the existing cadence,
draining the retire list regularly.

## Config

- `GEODE_NODE_CACHE_ENTRIES` — resident node cap (default 1_000_000). `0`
  disables bounding (legacy unbounded mirror, for A/B and safety fallback).
