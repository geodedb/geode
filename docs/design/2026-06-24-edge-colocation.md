# Edge co-location: single-shard edge writes via source-shard in-adjacency

Date: 2026-06-24
Status: DESIGN (not implemented). Read-only investigation; the only file written is this doc.
Repos:

- geode: `/home/benji/wedge-debug/geode-edge-redesign` branch `feat/edge-engine-direct` HEAD `01444827`
- graph-storage: `/home/benji/wedge-debug/graph-storage` HEAD `ffeb379`
Extends the edge-engine-direct work (Phases 0–4). The earlier "engine-direct-adjacency" design doc
referenced in the brief is **not present** at this geode HEAD (`docs/design/` contains only
`TDE_PER_TENANT_KEYS_DEFERRED.md`); this doc therefore treats the on-disk structures themselves as
the de-facto spec to extend and cites them directly. The bounded adjacency/edge caches, de-hydrated
endpoint resolution, and the O(1) existence-index dedup it added are preserved (see §8).

---

## 0. TL;DR

Today a single edge `(src)-[R]->(dst)` writes **two** engine shards: out-adjacency + edge_index +
existence-index on `shard(src)`, and in-adjacency on `shard(dst)`. When `shard(src) != shard(dst)`
(~15/16 of real taxonomy edges) the write becomes a cross-shard 2PC inside the engine
(`graph-storage/src/sharded_engine.zig:351` `crossShardAddEdge`), which the measured ceiling pins at
~539 edges/sec vs ~4194/sec for co-located edges.

**The fix:** record `dst`'s in-adjacency on `shard(src)` too, in a new per-shard page-backed store
keyed by `dst` ("the in-index"). The existence index is *already* on `shard(src)`
(`sharded_engine.zig:468`), so the entire edge becomes a **single-shard, single-engine
transaction** — no 2PC. Reverse traversal `expandIn(dst)` becomes a bounded 16-shard scatter-gather;
forward traversal `expandOut(src)` is unchanged and stays local. Durability is inherited for free
because the engine's recovery is **physical page-image redo** keyed by `(file_id, page_id)`
(`graph-storage/src/recovery.zig:221-253`): the in-index's pages, logged via `logPage` inside the
edge's existing single-shard txn, are replayed exactly like out-adjacency.

This eliminates `crossShardAddEdge` for edges and the engine's cross-shard 2PC reconciliation for
edges (`graph-storage/src/sharded_recovery.zig:83`), and collapses geode's two-shard-lock dances to a
single source-shard lock. The coordinator already routes every edge op by `source_id`
(`geode/src/storage/group_commit.zig:583` + `:316-318`), so each worker's whole batch is already
single-source-shard; co-location makes it genuinely single-shard (no cross-worker dst contention).

---

## 1. Confirmed current-layout map (file:line)

### 1.1 The cross-shard edge WRITE (the thing being eliminated)

`ShardedGraphEngine.addEdge` dispatches by endpoint shards
(`graph-storage/src/sharded_engine.zig:525-530`):

```
const s_from = shard_count_mod.shardOfNode(from);   // :526
const s_to   = shard_count_mod.shardOfNode(to);     // :527
if (s_from == s_to) return self.shards[s_from].addEdge(from, to, rel_type);   // :528  same-shard
return self.crossShardAddEdge(from, to, rel_type, s_from, s_to);              // :529  CROSS-shard 2PC
```

`shardOfNode` is plain `id % SHARD_COUNT` (`graph-storage/src/shard_count.zig:28-30`); striped id
allocation guarantees `shardOfNode(allocated_id) == base_shard_index`
(`shard_count.zig:6-17`, allocation at `engine.zig:773-778` / `:927-932`). `SHARD_COUNT` is 16
(`shard_count.zig:24` → `sharded_store.SHARD_COUNT`).

`crossShardAddEdge` (`graph-storage/src/sharded_engine.zig:351-523`) does a full two-shard 2PC:

- allocate edge id on the **source** shard's stride (`:366-367`);
- **prepare** on both shards (`:387-446`) — in `deferred` WAL mode both prepares run inline
  (`inline_2pc = (src.config.sync_mode == .deferred)`, `:406`; rationale `:393-405`);
- **step 3 — source side, on `shard(src)`**: `src.adj_out.addEdge(...)` (`:456`),
  `src.node_store.putNode(from, ...)` (`:458`), `src.edge_index.put(...)` (`:459`), and
  **the existence index is already on `shard(src)`**: `src.edge_exist_index.put(from, rel_type, to, edge_id)`
  (`:468`, comment `:465-467`);
- **step 4 — target side, on `shard(dst)` (the ONLY reason for 2PC)**:

  ```
  // 4. Write target incoming adjacency.                                  // :471
  const in_entry = edge_mod.EdgeEntry{ .neighbor = from, .edge_id = edge_id, ... };  // :472
  var to_rec = try dst.getNode(to) orelse return error.NodeNotFound;      // :478
  const new_in_head = try dst.adj_in.addEdge(to_rec.in_head, in_entry);   // :479
  to_rec.in_head = new_in_head;                                           // :480
  try dst.node_store.putNode(to, to_rec);                                 // :481
  ```

- **commit** on both shards (`:483-519`).

The same-shard fast path is just `GraphEngine.addEdgeTxn`
(`graph-storage/src/engine.zig:925-989`), which writes out-adjacency (`:943`), in-adjacency
(`:955`), `edge_index` (`:970`), `edge_exist_index` (`:981`), and **logs all four dirty pages under
ONE txn**: `logPage(.adj_out)`, `logPage(.adj_in)`, `logPage(.nodes, from)`, `logPage(.nodes, to)`
(`:960-967`). This is the template the co-located write extends.

### 1.2 The two adjacency stores

Each `GraphEngine` owns two `AdjStore`s: `adj_out` and `adj_in`
(`graph-storage/src/engine.zig:101-102`), backed by `FileId.adj_out=1` and `FileId.adj_in=2`
(`graph-storage/src/types.zig:17-18`; files `adj_out.store` / `adj_in.store`,
`graph-storage/src/file_manager.zig:19-20`). An `AdjStore` is a chain of page blocks; each block is a
16-byte `EdgeBlockHeader` (`graph-storage/src/edge.zig:22-29`) + an array of 24-byte `EdgeEntry`
records (`edge.zig:10-15`: `neighbor:u64, edge_id:u64, rel_type:u32, prop_head:u32`).
`AdjStore.addEdge` is O(1) head-insert (`graph-storage/src/adj_store.zig:53-116`); `expand` returns a
zero-copy page-pinning iterator (`adj_store.zig:155-214`). The chain head is the node record's
`out_head` / `in_head` (`graph-storage/src/node.zig:16-18`, 48-byte `NodeRec`).

Crucially, `AdjStore` has **no snapshot/serialize logic of its own** — it is purely page-backed via
the buffer pool (`adj_store.zig:31-46`, the only `createFile` is the test fixture at `:330`). Its
durability is entirely inherited from WAL `logPage` + checkpoint `flushAll` (see §4). This is exactly
why it is the right shape for the new in-index.

### 1.3 expandIn (reverse traversal) today

- `GraphEngine.expandInIter` reads the node's own `in_head` chain
  (`graph-storage/src/engine.zig:894-897`: `self.adj_in.expand(rec.in_head, rel_type)`).
- `ShardedGraphEngine.expandInIter` routes to the **destination** node's shard
  (`graph-storage/src/sharded_engine.zig:283-287`):

  ```
  // expandIn is intra-shard by construction — incoming adjacency
  // for node v lives in v's shard (§Cross-shard operations.2).   // :284-285
  return self.shards[shard_count_mod.shardOfNode(id)].expandInIter(id, rel_type);  // :286
  ```

  The slice variant `expandIn` drains it (`sharded_engine.zig:688-695`). This is the routing
  assumption co-location breaks.
- Forward traversal `expandOutIter` routes to the source node's shard
  (`sharded_engine.zig:279-281`) and stays unchanged.
- `getEdge` already routes by `shardOfNode(edge_id) == source shard`
  (`sharded_engine.zig:273-277`), and edge-property addressing keys off `shardOfNode(from)`
  (`getEdgeProperty` `sharded_engine.zig:564-566`). So the edge **body** is already source-shard-local;
  co-location makes the whole edge (out-adj + in-adj + existence + body + props) source-shard-local.

### 1.4 geode consumers of the layout

- Reverse reads go through `GraphStore.getIncomingEdgeIds`
  (`geode/src/graph_store.zig:5342`) → `inAdjItems` (`:5332`) → the bounded `incoming_edges`
  `AdjCache` (`:1399`), hydrating on miss via `hydrateIncomingCb`
  (`:2128`) → `hydrateAdjFromEngine(.incoming)` (`:2132/:2139`) →
  `adapter.iterateIncomingEdges` (`:2151`) → `mg.storage().expandIn(node_id, null, allocator)`
  (`geode/src/storage/graph_storage_adapter.zig:3775`).
- The resident **incoming mirror is keyed by `to_id` today**
  (`graph_store.zig:6251-6252`, `appendAdj(&self.incoming_edges, to_id, ...)`), written by
  `addToAdjacencyIndex` (`:5950`) inside `createEdgeWithGraphAndTenant`.
- ~40 reverse-read call sites across the executor/algorithms (e.g.
  `geode/src/execution/match_operations.zig:3214,3274,4128,...`,
  `geode/src/execution/recursion_handler.zig:103,189,...`,
  `geode/src/execution/centrality_algorithms.zig:105,...`) **all go through the public
  `getIncomingEdgeIds`/vtable API** — none touch the engine directly. The scatter-gather change is
  therefore transparent above the adapter.
- The cross-shard write enters the engine from geode via `mg.engine.addEdge`
  (`graph_storage_adapter.zig:3698`, the `createEdge` cross-shard fallback) and, for bulk, via
  `GraphStore.createEdgeWithGraphAndTenant` → engine vtable `createEdgeFn`
  (`graph_store.zig:5879`). The adapter's own comment documents the split
  (`graph_storage_adapter.zig:1230-1237`, `:3682`, `:3710`).

### 1.5 Bonus: cross-shard removeEdge is currently UNSUPPORTED

`ShardedGraphEngine.removeEdge` returns `error.CrossShardEdgeUnsupported` when
`s_from != s_to` (`graph-storage/src/sharded_engine.zig:532-537`). Co-location makes cross-shard
removeEdge implementable (the in-adjacency becomes local to the source shard) — a free correctness
win, not just throughput.

---

## 2. The co-location design

### 2.1 Where dst's in-adjacency lives: a new per-shard, page-backed in-index keyed by dst

**Decision: add a new page-backed store `adj_in_remote` (FileId `in_idx`) on every shard, keyed by
dst node id, holding the in-edge entries of edges whose SOURCE hashes to this shard.** It mirrors the
existing `adj_in` `AdjStore` shape exactly. Justification (simplest correct option):

- **Durability is inherited with zero new transactional machinery.** Engine recovery is physical
  page-image redo: committed `page_update` records (`graph-storage/src/wal_record.zig:8-9`, carrying
  `file_id + page_id + page image`, struct `wal_record.zig:34-41`) are replayed by
  `pinNew(file_id, page_id)` + `@memcpy(page image)` (`graph-storage/src/recovery.zig:226-234,253`),
  which **recreates the page even if it never hit disk** (`recovery.zig:462` "Page might not exist on
  disk yet if flush didn't extend file"). A new FileId's pages logged via `logPage` are replayed
  identically — no new record type is needed because `page_update` already carries an arbitrary
  `file_id`.
- **It is crash-consistent with the out-adjacency write by construction**, because both become page
  images in the *same single-shard txn* (§2.2). Contrast the existence index, which is an in-memory
  hashmap (`graph-storage/src/edge_exist_index.zig:46-52`) durable only via a checkpoint **snapshot**
  - rebuild-from-out-adjacency (`engine_index.zig:118-168`, snapshot `engine_index.zig:318-360`); a
  light checkpoint deliberately skips that snapshot (`engine_persist.zig:284-291`,`:318-320`), so an
  in-memory in-index would be lost across a light checkpoint or crash unless ALSO rebuilt from a full
  adj scan on every recovery (extra code + couples correctness to a scan). The `btree.zig` store is
  likewise in-memory with its own snapshot file (`graph-storage/src/btree.zig:10-14,375,380,401`) —
  same drawback.
- **The reference pattern already exists**: `AdjStore` itself
  (`graph-storage/src/adj_store.zig:31-116`) and `PropStore`
  (`graph-storage/src/prop_store.zig`, page-backed via buffer pool, `pin/pinNew/allocPage`) are both
  pure page-backed stores with no snapshot of their own. The new in-index reuses the `AdjStore`
  struct verbatim.

**Why a second store, not "keep dst.in_head"?** With co-location, dst's in-edges are fragmented
across the shards of its various sources. The per-node `in_head` chain model (one chain rooted in the
node record) cannot represent that: the node record lives on `shard(dst)`, but its in-edges now live
on up to 16 different shards. So each shard needs its own "incoming-edges keyed by dst" structure.

**Keying — two viable layouts; pick A:**

- **Layout A (chosen): a per-shard `dst -> in_head` directory + an `adj_in_remote` AdjStore.** Add a
  small durable map `in_head_index: dst_node_id -> PageId` on each shard (the head page of that dst's
  local in-chain *for sources on this shard*), and store the chain bodies in the new
  `adj_in_remote` AdjStore (FileId `in_idx`). The directory can be the same paged-keyed shape as the
  edge-existence snapshot, OR — simplest — a second in-memory `AutoHashMap(dst_id, PageId)` rebuilt
  on recovery from the `adj_in_remote` pages (the chain entries record `neighbor = source_id`, so a
  scan reconstructs `dst -> head`). Because `adj_in_remote` bodies are the durable source of truth
  (page-image redo), the directory is a *derived* index exactly like `edge_index`, and is rebuilt the
  same way (§4.3). This keeps the hot write O(1) head-insert (`adj_store.zig:53-116`).

- **Layout B (rejected as more machinery): one combined `adj_in` chain per shard holding ALL
  in-edges whose source is on this shard, partitioned by dst via the existing `EdgeBlockHeader.kind`
  field** (`edge.zig:22-29` reserves `kind`). Rejected: traversal of one dst's in-edges would scan
  the whole shard's in-edges; the directory in A gives O(in-degree-on-shard) reads.

The on-disk entry is the existing 24-byte `EdgeEntry` (`edge.zig:10-15`): for an in-index entry,
`neighbor = source node id`, `edge_id`, `rel_type`, `prop_head` — identical to what `adj_in` stores
today (`sharded_engine.zig:472-477`), so `EdgeEntry`/`EdgeBlockHeader` are unchanged.

**Adding the FileId** (the entirety of the new-store registration surface):

1. `graph-storage/src/types.zig:15-26` — add `in_idx = 10` (this auto-grows `FILE_COUNT` and every
   `[FILE_COUNT]` array). Update the lockstep test `types.zig:45-56`.
2. `graph-storage/src/file_manager.zig:17-28` — add `"adj_in_remote.store"` at index 10. Update the
   lockstep test `file_manager.zig:351-363`. (`GraphDir.create` already creates a file per
   `FILE_NAMES` entry, so new graphs get the file automatically.)
3. Wire a `FreeSpaceManager` + `AdjStore` for it in `initSubsystems`
   (`graph-storage/src/engine_persist.zig:171-213`, mirroring `free_space_adj_in`/`adj_in`), and
   register the pager in create/open + recovery (`engine.zig` open steps; `recovery.zig:141-154`
   registers nodes/adj_out/adj_in/props/var/free — add `in_idx`).
4. Persist its free-space + page counts in the manifest exactly like `adj_in_pages`
   (`engine_persist.zig:305`).

### 2.2 The single-shard write path

Replace `crossShardAddEdge` (`sharded_engine.zig:351`) with a same-shard path. `ShardedGraphEngine.addEdge`
becomes:

```
const s_from = shardOfNode(from);
return self.shards[s_from].addEdgeColocated(from, to, rel_type);   // ALWAYS source shard, no s_to branch
```

`GraphEngine.addEdgeColocatedTxn(from, to, rel_type, txn)` (a modified `addEdgeTxn`,
`engine.zig:925`) does, **all on one engine, in one txn**:

1. allocate `edge_id` on this shard's stride (`engine.zig:927-932`, unchanged);
2. `adj_out.addEdge(from_rec.out_head, out_entry)` + `node_store.putNode(from, ...)`
   (`engine.zig:942-945`, unchanged) — note `from` is local because we are on `shard(from)`;
3. **NEW**: `adj_in_remote.addEdge(in_head_index.get(to), in_entry)` where
   `in_entry = {neighbor=from, edge_id, rel_type, prop_head=0}`, then update
   `in_head_index[to] = new_in_head`. (`to` is **not** resident on this shard, so we do NOT touch
   `to`'s NodeRec — the in-chain head is held in this shard's `in_head_index`, not in `dst.in_head`.)
4. `edge_index.put(edge_id, ...)` (`engine.zig:970`, unchanged) + `edge_index_dirty = true`;
5. `edge_exist_index.put(from, rel_type, to, edge_id)` (`engine.zig:981`, unchanged — already on this
   shard) + `edge_exist_index_dirty = true`;
6. **log every dirty page under the one txn** (extends `engine.zig:960-967`):
   `logPage(txn, .adj_out, new_out_head)`, `logPage(txn, .in_idx, new_in_head)`,
   `logPage(txn, .nodes, nodePageId(from))`, and a `logPage(txn, .in_idx, directory_page)` if the
   directory is page-backed. **We no longer log `to`'s node page** (it isn't modified) — one fewer
   page than today's same-shard path, and zero remote pages.
7. `manifest.edge_count += 1` (unchanged).

Result: every edge — same-shard or "cross-endpoint" — is a single `GraphEngine` transaction. No
`beginTxn`/`appendPrepare`/`appendDecision` on a second shard, no WaitGroup, no thread-pool ping-pong.
This is the path that hits the ~4194/s co-located rate the throughput test already measures for
same-shard edges (`geode/tests/test_edge_popular_parent_throughput.zig:432-463`).

`edge-property` writes also become single-shard: `setEdgeProperty` currently updates the prop_head in
BOTH the out-chain (source shard) and the in-chain (dst shard) via two engines
(`graph-storage/src/engine_edge_props.zig:42-44`) — which is actually *broken* for cross-shard edges
today (it only operates on one `GraphEngine`). With co-location both chains are on the source shard,
so the existing single-engine code becomes correct. Change line `:44` to update
`adj_in_remote` via the `in_head_index[to]` head instead of `dst.adj_in` via `to_rec.in_head`.

### 2.3 Scatter-gather expandIn (reverse traversal)

`expandIn(dst)` can no longer route to one shard. It becomes a bounded fan-in over all
`SHARD_COUNT` shards' `adj_in_remote`:

- **New concrete iterator on `ShardedGraphEngine`**: `FanInEdgeIterator`, modeled on the existing
  `FanOutNodeIterator` (`graph-storage/src/sharded_engine.zig:799-825`). It walks shard 0..15, for
  each shard opening `shard.adj_in_remote.expand(shard.in_head_index.get(dst), rel_type)` and
  draining it before advancing. `deinit` unpins the active shard's page (same discipline as
  `FanOutNodeIterator.deinit` `:819-824`, which mirrors `AdjEdgeIterator.deinit`
  `adj_store.zig:163-168`).
- `ShardedGraphEngine.expandInIter` (`sharded_engine.zig:283`) returns a `FanInEdgeIterator` instead
  of routing to `shards[shardOfNode(id)]`. `expandIn` (`:688`) drains it (unchanged drain logic).
- **No vtable signature change.** The vtable `expandInIterFn`
  (`graph-storage/src/interface.zig:377-381`) calls the impl's `expandInIter(self, id, rel_type)`
  and heap-wraps the concrete iterator via `wrapEdgeIterator`; it already supports an arbitrary
  concrete iterator type (that is how `FanOutNodeIterator` is wrapped). So `FanInEdgeIterator` drops
  in without touching `interface.zig`'s `expandIn`/`expandInIter` field types
  (`interface.zig:123,128,186-200`).
- **geode side**: `adapter.iterateIncomingEdges`
  (`geode/src/storage/graph_storage_adapter.zig:3764-3775`) is unchanged — it already calls
  `mg.storage().expandIn(node_id, null, allocator)` and now transparently gets the scatter-gather. The
  resident `incoming_edges` mirror keyed by `to_id` (`graph_store.zig:6251-6252`) is unchanged in
  shape; only its **hydrate source** changes (the engine now fans in), which is invisible to the ~40
  consumers because they all read through `getIncomingEdgeIds`. `getIncomingEdgeIds`/`reverseStep`
  callers (`graph_store.zig:5342`; consumers in §1.4) need **no change**.

**Cost of the scatter-gather**: a bounded 16-shard read. For a dst with in-degree `d`, the total work
is `d` entry reads (the same `d` as today, just split across ≤16 chains) + up to 16
`in_head_index.get(dst)` probes + up to 16 empty-chain checks. For the overwhelmingly common case
(dst with few in-edges) this is ≤16 hashmap probes + a handful of page reads — microseconds. There is
**no cross-shard 2PC, no fsync** on the read path.

**Forward traversal `expandOut(src)` is unchanged and stays LOCAL**
(`sharded_engine.zig:279-281` routes to `shards[shardOfNode(src)]`, which holds the out-adjacency we
never moved).

### 2.4 What about same-shard edges (1/16)?

For an edge where `shard(src) == shard(dst)`, the in-index entry still goes in
`shard(src).adj_in_remote` keyed by `dst` (not in `dst.in_head`). This keeps ONE in-edge code path
(no special case), and `expandIn(dst)`'s scatter-gather still finds it (it probes
`shard(dst).adj_in_remote` among the 16, and `shard(src)==shard(dst)` for these). The legacy
`adj_in`/`in_head` fields on `NodeRec` become **write-dead for new edges** (still read by migration —
§5). We keep the `NodeRec.in_head` field (removing it is a 48-byte layout change, out of scope) but
stop writing it for new edges.

---

## 3. Durability / recovery / checkpoint

### 3.1 Write durability (single-shard, crash-consistent)

The in-index pages are logged via `logPage(txn, .in_idx, page)` in the **same** txn as the
out-adjacency + node + edge_index/exist updates (§2.2 step 6). `logPage`
(`graph-storage/src/engine.zig:719-724`) appends a `page_update` WAL record (payload = full page
image, `engine.zig:723` → `txn.zig:175 logPageUpdate`). On commit the txn's records are durable
(under `deferred` mode, durability is deferred to checkpoint/clean-close exactly like every other
page — no special handling). Because all pages are in one txn, a crash either replays the whole edge
(out + in) or none of it: **crash-consistent by construction**, no 2PC needed.

### 3.2 Recovery

- **WAL replay** restores the `adj_in_remote` pages automatically: `Recovery.recover`
  (`graph-storage/src/recovery.zig:89`) replays committed `page_update` records by
  `pinNew(file_id, page_id)` + page-image memcpy (`recovery.zig:221-253`). Adding the `in_idx` pager
  to the registration list (`recovery.zig:141-154`) is the only recovery change for the bodies. The
  edge's out-adjacency and in-index pages share one txn id, so both replay together (or neither).
- **The directory `in_head_index` is a derived index**, rebuilt after WAL replay exactly like
  `edge_index`/`edge_exist_index`. Today `rebuildEdgeIndex`
  (`graph-storage/src/engine_index.zig:116-168`) scans live nodes' **out-adjacency**
  (`adj_out.expand(rec.out_head)`, `:139`) to rebuild `edge_index` + `edge_exist_index`. We add a
  parallel rebuild that scans this shard's `adj_in_remote` chains and sets
  `in_head_index[entry-dst] = chain head`. Because the chain entries carry `neighbor = source_id`
  and the dst is the chain key, the directory is a pure function of the durable `adj_in_remote`
  pages — so a crash can never leave it disagreeing (same argument as the existence index,
  `engine_index.zig:118-121`). If the directory is instead made page-backed + logged, it needs no
  rebuild at all (it's restored by page-image redo like the bodies); the in-memory-directory variant
  is rebuilt under the same `tryLoadDerivedIndexes`-fails-or-stale gate the other derived indexes use
  (`engine.zig:350-361`, gate `engine_index.zig:198-208`).
- **The cross-shard 2PC reconciliation goes away for edges.** `reconcilePendingPrepares`
  (`graph-storage/src/sharded_recovery.zig:83`) exists ONLY because an edge write currently spans two
  shards: it discovers dangling `cross_shard_prepare` records and resolves them by replaying
  source-side OUT-adjacency or target-side IN-adjacency (`sharded_recovery.zig:168-218`, target reapply
  at `:205-217`). Single-shard edge writes emit **no** `cross_shard_prepare/commit/abort` records, so
  this path finds nothing for edges. Keep the function (it is harmless and may serve future genuinely
  cross-shard ops) but its target-side `adj_in` reapply (`sharded_recovery.zig:213-214`) and the
  source/target split become dead for edges; the `addEdgeCrash*` 2PC test hooks
  (`sharded_engine.zig:697-791`) are deleted with the 2PC path.

### 3.3 Checkpoint

- A checkpoint flushes ALL dirty data pages and fsyncs dirty store files. `Checkpointer.doCheckpoint`
  (`graph-storage/src/checkpoint.zig:59-104`): record LSN (`:64`) → `buffer_pool.flushAll()` (`:67`,
  which flushes any dirty `.in_idx` page, no special-casing) → `file_manager.syncDirty(dirty_files)`
  (`:82`, iterates all FileIds incl. the new one) → bump `manifest.counter`/`last_checkpoint_lsn`
  (`:85-86`) → write manifest to alternate slot (`:88-97`) → `wal.truncate` (`:103-104`). The
  `in_idx` store's free-space + page count must be added to the manifest persist
  (`engine_persist.zig:305`) and to `maxPersistedPagesForStore` (`engine_persist.zig:114`).
- **Derived-index snapshots**: `doCheckpoint` does NOT write them; `engine_persist.checkpointEx`
  does (`engine_persist.zig:292-334`, full save at `:321`; light checkpoint skips it,
  `:284-291`,`:318-320`; `close()` saves unconditionally, `engine.zig:617`). If we make
  `in_head_index` an in-memory derived map, add it to `saveDerivedIndexesConditional`
  (`engine_index.zig:226-251`) with its own `in_head_index_dirty` flag and a snapshot magic (mirror
  `EDGE_EXIST_SNAPSHOT_MAGIC`, `engine_index.zig:28,318-360`) and to the load/staleness gate
  (`engine_index.zig:172-211`). **If we make the directory page-backed, none of that is needed** — it
  rides the page-image checkpoint + recovery like the bodies. (Page-backed directory is the
  lower-machinery choice and is recommended; see §9 risk note.)
- **Checkpoint cadence is preserved and unchanged.** There is no `GEODE_CHECKPOINT_OPS` in the Zig
  layer — the op-count cadence is driven by the caller (geode/Go driver); the Zig knobs are
  `Checkpointer.needsCheckpoint(byte_threshold)` (`checkpoint.zig:111`),
  `GraphEngine.checkpointLight` (`engine.zig`), and `ShardedGraphEngine.checkpointLight`
  (`sharded_engine.zig:644-655`). The in-index adds dirty `.in_idx` pages that the existing
  `flushAll`/`syncDirty` already cover; the cadence (and the bounded-RSS deferred-WAL behavior) is
  untouched.

---

## 4. Migration

Existing on-disk graphs have in-edges in `adj_in` on the **dst** shard (old layout) and an empty
`adj_in_remote`. Two options:

- **Option M1 (recommended): rebuild the co-located in-index on open.** On open, if the shard
  manifest's `layout_version` is pre-co-location, run a one-time conversion: scan every shard's
  **out-adjacency** (`adj_out.expand(rec.out_head)`, the existing `rebuildEdgeIndex` scan,
  `engine_index.zig:135-161`) and, for each out-edge `(from on this shard)->(to)`, insert the
  corresponding in-index entry into `shard(from).adj_in_remote` keyed by `to`. This is the *same scan
  already run to rebuild the existence index*, so it is a derived-index extension — no new traversal
  shape — and it is the source-of-truth-correct mapping (every edge appears once in out-adjacency).
  After conversion, bump the manifest `layout_version` and write it; the legacy `adj_in` store can be
  left in place (read-only, ignored by new `expandIn`) or compacted away later. Because conversion is
  a function of out-adjacency, it is crash-safe: if it dies mid-way, reopen re-runs it (idempotent —
  `AdjStore.addEdge` dedups nothing, so guard with an "in_idx empty / version unset" check before
  running, and run it inside checkpointed batches).

- **Option M2: manifest version flag selecting old-vs-new expandIn** (lazy). Add `layout_version` to
  the shard manifest (`graph-storage/src/shard_manifest.zig`); when it is the old value, `expandIn`
  routes the OLD way (`shards[shardOfNode(dst)].adj_in`); when new, scatter-gather. New edges always
  write `adj_in_remote`. Rejected as the primary path because it permanently forks the read path and
  leaves writes split between `dst.adj_in` (for any still-old code) and `adj_in_remote`; only useful
  as a fallback if a full rebuild-on-open is too slow for the largest graphs (14.27M taxa → the
  rebuild is one adj_out scan, the same cost as the existing index rebuild, so M1 is fine).

**Chosen: M1**, gated by a new `shard_manifest` `layout_version` (default = old for existing dirs,
new for freshly created dirs). `shard_manifest.zig` already versions the manifest
(`SHARD_MANIFEST_VERSION`, used at `sharded_engine.zig:101-108`), so adding a `layout_version` field
is a localized change.

---

## 5. geode-side changes

### 5.1 The two-lock dances collapse to one source-shard lock

geode takes endpoint shard locks `mg.shard_locks[...]` around edge applies. The cross-shard arms
disappear because the engine write is now single-shard on `shard(source)`:

- `bulkMergeEdgeWithIdsShardLockedForTenant` (`graph_storage_adapter.zig:2497`, sibling `:2479`):
  delete the `@min`/`@max` ascending two-lock branch (`:2539-2542`); keep only the single
  `mg.shard_locks[src_shard]` acquire (`:2534-2536`). `src_shard`/`dst_shard` computed at
  `:2510-2511` — only `src_shard` is needed.
- `bulkInsertEdgeWithIdsShardLockedForTenant` (`graph_storage_adapter.zig:2365`): same — drop the
  ascending acquire at `:2397-2410`, keep the source-shard lock.
- `bulkMergeEdgesBatchShardLocked` (`graph_storage_adapter.zig:2686`): **delete the entire per-edge
  dst-lock block** (`:2724-2756`, including the `tryLock`/drop-and-reacquire dance for `dst < src` at
  `:2735-2756` and the literal `mg.shard_locks[dst_shard].lockUncancelable(io)` at `:2751`). Keep the
  outer run that holds the **one** source-shard lock across a maximal same-source-shard run
  (`:2716-2722`). `applyOneMerge` (`:2768`) → `bulkMergeEdgeInnerShardLocked` is unchanged.
- `bulkMergeEdgeInnerShardLocked` (`graph_storage_adapter.zig:2551`): unchanged in logic — its O(1)
  dedup probe already runs on the **source** shard engine (`src_engine.probeEdge(from_slot,
  rel_label_id, to_slot, &probe_buf)`, `:2598`, comment "lives on the SOURCE shard — held EXCLUSIVE
  here" `:2570-2571`), and create goes through `store.createEdgeForRequestTenant` (`:2635-2638`). The
  only change is that the inner no longer needs the caller to have taken a dst lock.
- `createEdge` (`graph_storage_adapter.zig:3650`): the cross-shard fallback
  `mg.engine.addEdge(from_id, to_id, rel_type)` (`:3698`) now resolves to the single-shard
  `addEdgeColocated` (no behavior change at the call site; the cross-shard 2PC simply never runs).
  The same-shard fast path `addEdgeTxn` (`:3690`) is unchanged.

### 5.2 The reverse-read hydrate becomes scatter-gather (transparently)

`iterateIncomingEdges` (`graph_storage_adapter.zig:3764-3775`) calls
`mg.storage().expandIn(...)` (`:3775`) — unchanged, now backed by the engine's `FanInEdgeIterator`.
The incoming-mirror hydrate (`graph_store.zig:2128-2169`) and the ~40 consumers (§1.4) need **no
change**. The incoming mirror stays keyed by `to_id` (`graph_store.zig:6251-6252`); only the
engine-side source of truth changed.

### 5.3 Coordinator routing already yields single-shard batches

`group_commit.zig` routes every edge op by `source_id`:
`shardIndex(op.shardKey())` (`group_commit.zig:583`) with `shardKey()` returning `source_id` for all
edge variants (`:316-318`); the tuple-hash `edgeTupleShardKey` (`:331`) is explicitly **not used**
(`:324-330`). Each worker drains only its own shard's queue (`shardLoop` `:688`, `:693`,`:726`) and
applies via `applyShardBatch` → `bulkMergeEdgesBatchShardLocked` (`≈:812`). So every edge op in a
worker's batch already shares `shardIndex(source_id) == worker shard`. **The only thing breaking the
single-shard property today is the dst-side in-adjacency write; co-location removes it**, after which a
worker's whole batch touches exactly one engine shard, with no cross-worker destination contention.
No routing change is required.

---

## 6. Exact change list

### graph-storage

- `src/types.zig:15-26` — add `in_idx = 10` to `FileId`; update test `:45-56`.
- `src/file_manager.zig:17-28` — add `"adj_in_remote.store"`; update test `:351-363`.
- `src/engine.zig` — add `adj_in_remote: AdjStore` (next to `adj_in`, `:102`) and (if in-memory
  directory) `in_head_index: AutoHashMap(NodeId, PageId)` + `in_head_index_dirty: bool`; new
  `addEdgeColocatedTxn`/`addEdgeColocated` (modify `addEdgeTxn` `:925-989`: drop the `to`-node
  in-chain write `:947-957` and `to`-node logPage `:962-967`, add `adj_in_remote` write + directory
  update + `logPage(.in_idx, ...)`); update open/create to open+register the `in_idx` pager.
- `src/engine_persist.zig` — `initSubsystems` add `free_space_in_idx` + `adj_in_remote = AdjStore.init(..., .in_idx, ...)`
  (mirror `:171-180`, `:209-213`); persist its pages in manifest (`:305`) and
  `maxPersistedPagesForStore` (`:114`).
- `src/engine_index.zig` — add `rebuildInHeadIndex` (scan this shard's `adj_in_remote`, or — for M1
  — derive from the existing out-adjacency scan `:116-168`); if in-memory directory, add
  save/load/staleness + a snapshot magic (mirror `:28,:318-360,:172-211,:226-251`).
- `src/engine_edge_props.zig:42-44` — `setEdgeProperty` updates `adj_in_remote` via
  `in_head_index[to]` instead of `dst.adj_in` via `to_rec.in_head`.
- `src/sharded_engine.zig` —
  - `addEdge` (`:525-530`): always route to `shards[shardOfNode(from)].addEdgeColocated`; **delete
    `crossShardAddEdge` (`:351-523`)** and the `addEdgeCrash*` 2PC test hooks (`:697-791`).
  - `expandInIter` (`:283-287`): return a new `FanInEdgeIterator` fanning over all shards'
    `adj_in_remote` + `in_head_index`. Add `FanInEdgeIterator` (model on `FanOutNodeIterator`
    `:799-825`).
  - `removeEdge` (`:532-537`): drop `error.CrossShardEdgeUnsupported`; remove from
    `shard(from).adj_out` + `shard(from).adj_in_remote` (now single-shard) + existence index.
  - `getEdge` (`:273-277`), `expandOutIter` (`:279-281`): unchanged (already source-shard).
- `src/sharded_recovery.zig` — `replayAdjacencyIfNeeded` target-side reapply (`:205-217`) and the
  source/target split become dead for edges; can be simplified once the 2PC edge path is removed
  (keep `reconcilePendingPrepares` `:83` as a harmless no-op for edges or for future cross-shard ops).
- `src/shard_manifest.zig` — add a `layout_version` field (co-location vs legacy) for migration (§4).
- `src/recovery.zig:141-154` — register the `in_idx` pager.

**Deleted code (graph-storage):** `crossShardAddEdge` (`sharded_engine.zig:351-523`), the 2PC test
hooks (`sharded_engine.zig:697-791`), and the edge-relevance of the target-side 2PC reapply
(`sharded_recovery.zig:205-217`). The `sharded_engine_2pc.zig` prepare/decision encoders
(`sharded_engine_2pc.zig`) become unused for edges (keep only if a future cross-shard op needs them).

### geode

- `src/storage/graph_storage_adapter.zig` — delete the two-lock branches in
  `bulkMergeEdgeWithIdsShardLockedForTenant` (`:2539-2542`),
  `bulkInsertEdgeWithIdsShardLockedForTenant` (`:2397-2410`), and the per-edge dst-lock block in
  `bulkMergeEdgesBatchShardLocked` (`:2724-2756`); keep the single source-shard locks
  (`:2534-2536`, `:2716-2722`). `createEdge` (`:3650`), `bulkMergeEdgeInnerShardLocked` (`:2551`),
  `iterateIncomingEdges` (`:3764-3775`) unchanged in logic.
- `src/graph_store.zig` — no functional change (reverse reads transparently use the fan-in). Optional:
  update the layout doc comment at `:492-516` and the adapter design comment
  `graph_storage_adapter.zig:1230-1237` to describe co-location.
- `src/storage/group_commit.zig` — no change (source_id routing already correct, §5.3).

---

## 7. TDD validation plan (RED-first)

Each item: write the failing assertion first, then implement until green. Tests run under
`GEODE_WAL_SYNC=deferred` to match the cited baselines (the throughput harness already sets this,
`test_edge_popular_parent_throughput.zig:73`).

1. **Throughput unlock (the headline).** Extend
   `geode/tests/test_edge_popular_parent_throughput.zig`. RED: a new test that ingests the
   *natural-endpoint* (non-co-located) popular-parent / aggregate edge set and asserts
   `eps > 1200` (node-ingest order), which **fails today** because the natural-endpoint path is
   cross-shard-2PC-bound (~539/s; the existing `cross > 280` floor at `:456` and the co-located
   `colo > 1200` at `:460` document the gap). After co-location, the natural-endpoint number should
   converge on the co-located number (the `colo > cross * 2.0` gap at `:462` should collapse toward
   parity). Keep the existing same-shard diagnostic (`:178-206`) as the upper-bound reference.
2. **Reverse-traversal correctness after co-location (scatter).** RED: build edges whose sources are
   deliberately spread across all 16 shards into one hot dst, then assert `getIncomingEdgeIds(dst)`
   returns the EXACT in-edge set (count + membership + rel filter), with the dst's sources on ≥2
   distinct shards. Today this passes via `dst.adj_in`; after the change it must pass via the
   `FanInEdgeIterator`. Natural home: `geode/tests/test_graph_store_sharded_invariants.zig`
   (already pins the incoming-mirror invariant: `"createEdgeWithGraph populates outgoing + incoming
   shards"`) and `geode/tests/test_adj_engine_direct_bounded.zig` (already drives incoming
   evict/rehydrate at `:205`). Add an engine-level twin in
   `graph-storage/tests/integration_sharded.zig` next to the `expandInIter` usage (`:183`).
3. **Recovery (crash → in-index rebuilt, reverse traversal correct).** RED: ingest cross-endpoint
   edges, simulate crash (drop without clean close), reopen, assert `getIncomingEdgeIds(dst)` returns
   the exact set and `getOutgoingEdgeIds(src)` is intact. Natural home:
   `geode/tests/test_edge_durability_churn_repro.zig` (the "edge resolvable both directions after
   restart" shape already exists at `:84`/`:322`). Engine-level: a new test in
   `graph-storage/tests/cross_shard_recovery.zig` asserting the `adj_in_remote` pages + directory are
   restored by page-image redo (and, if directory is in-memory, rebuilt from `adj_in_remote`).
4. **Migration (old-layout graph opens + reverse traversal correct).** RED: construct a graph with
   the OLD layout (in-edges in `dst.adj_in`, empty `adj_in_remote`, legacy `layout_version`), reopen
   with the co-location build, assert the M1 conversion runs and `getIncomingEdgeIds(dst)` returns the
   exact set via scatter-gather. Then assert idempotent reopen (second open does not double-insert).
   Natural home: a new `graph-storage/tests/test_edge_colocation_migration.zig` plus a geode
   `tests/` reopen test mirroring `test_gap0900_reopen_remerge_dup.zig`.
5. **Phase 0–3 regressions stay green** (must NOT change behavior):
   - O(1) MERGE dedup + race + reader coexistence: `geode/tests/test_edge_merge_shard_locked.zig`
     (5 tests), and the coordinator idempotency
     `test_edge_popular_parent_throughput.zig:557` (`"concurrent same-tuple MERGE -> exactly one
     edge"`).
   - Bounded adjacency/edge caches: `geode/tests/test_adj_engine_direct_bounded.zig`,
     `geode/tests/test_edge_engine_direct_bounded.zig`.
   - SEGV-safe concurrent reads: the torn-read stress
     `test_edge_popular_parent_throughput.zig:619` and `geode/tests/test_edge_torn_read_stress.zig`.
   - Two-lock-path correctness tests (`geode/tests/bulk_ingest/test_two_phase_edge_lock.zig`) must be
     **updated** to the single-lock invariant (they currently assert the two-phase lock; after
     co-location the second phase is gone — change the assertion, keep the endpoint-error coverage
     like "TargetNodeNotFound").
   - Engine reverse-adjacency unit tests: `graph-storage/src/engine_test.zig:115` (single engine,
     unchanged) and `graph-storage/src/sharded_engine_test.zig:170` (sharded — update to fan-in).
   - Existence-index lifecycle: `graph-storage/tests/test_edge_existence_index.zig` (unchanged — the
     existence index did not move).
6. **2PC removal is safe**: delete `graph-storage/tests/cross_shard_recovery.zig`'s edge-specific 2PC
   crash tests (`:44`,`:75` reference `addEdgeCrashAfterPrepares`/`addEdgeCrashAfterSourceCommit`
   which are deleted) OR repoint them at the new single-shard crash semantics; keep the SEC-0041
   bad-checksum reconciler tests (`:111`,`:144`,`:188`) if `reconcilePendingPrepares` is retained.

---

## 8. Preserved invariants (Phases 0–3)

- **Bounded adjacency/edge caches**: `incoming_edges`/`outgoing_edges`/`edges`
  (`geode/src/graph_store.zig:1398-1399,1272`), default cap 1,000,000, env-overridable
  (`GEODE_ADJ_CACHE_ENTRIES`/`GEODE_EDGE_CACHE_ENTRIES`, `:547-554,629-636`). "Correctness never
  depends on residency" (`:492-516`) — preserved: reverse reads rehydrate from the engine fan-in on
  miss.
- **De-hydrated endpoint resolution**: the source-shard dedup probe + canonical-id property read
  (`graph_storage_adapter.zig:2590-2631`) is unchanged (existence index did not move).
- **O(1) existence-index dedup**: `edge_exist_index.probe` (`graph-storage/src/edge_exist_index.zig:186`,
  engine `engine.zig:841`) stays on `shard(src)` — unchanged.
- **Node ingest ~3300/s + bounded RSS**: untouched (this change is edge-only; node alloc/put paths
  `engine.zig:767-797` unchanged; deferred-WAL checkpoint cadence §3.3 unchanged).
- **Idempotency**: MERGE dedup is the existence-index probe + idempotent prop-upsert
  (`graph_storage_adapter.zig:2628`); `edge_exist_index.put` is idempotent per edge_id
  (`edge_exist_index.zig:110-135`). Unchanged.
- **SEGV-safe concurrent reads**: the `FanInEdgeIterator` uses the same per-page pin/unpin discipline
  as `AdjEdgeIterator` (`adj_store.zig:163-204`) and `FanOutNodeIterator`
  (`sharded_engine.zig:799-825`); reads still take the source-shard lock via the coordinator/graph
  read lock as today.
- **Checkpoint/WAL cadence**: unchanged (§3.3).

---

## 9. Where co-location could be WRONG or worse — decide with eyes open

1. **Reverse traversal becomes a 16-way fan-in.** If a workload is reverse-traversal-hot (many
   `expandIn` over high-in-degree nodes, e.g. `ACCEPTED_AS` synonyms→accepted), every reverse read
   now probes up to 16 shards instead of one. For a dst whose in-edges actually span many shards this
   is the *same* total entry-read work split 16 ways, but it adds ≤16 directory probes + ≤16
   empty-chain checks per call, and it touches 16 buffer pools' pages (worse cache locality than one
   shard's chain). **Mitigation/diagnostic:** the resident `incoming_edges` mirror
   (`graph_store.zig:1399`) absorbs repeated reads of the same dst, so the fan-in cost is paid on
   cache-miss only. **Risk to watch:** a Phase 0-3 traversal test that measures reverse-traversal
   latency could regress; validation item 2 must include a high-in-degree dst and compare against the
   pre-change number. If reverse traversal turns out to be the dominant production read, the fan-in
   is a real (bounded, 16×) cost — but it buys a ~8× write throughput unlock, and the writes are the
   measured bottleneck, not reads.
2. **The `in_head_index` directory is new mutable per-shard state on the hot write path.** If made
   in-memory, it re-introduces a derived-index dirty-flag + snapshot + rebuild-on-recovery (exactly
   the machinery the page-backed in-index avoids). **Strong recommendation: make the directory
   page-backed (or fold it into the `adj_in_remote` store as a small header/B-tree) so it rides
   page-image redo and needs no snapshot/rebuild** — otherwise the "least machinery" advantage of the
   page-backed bodies is partially lost on the directory. This is the single most important
   implementation choice in the design.
3. **Per-shard write amplification on a popular dst.** If one dst receives in-edges from sources on
   all 16 shards, its in-chain head is touched on all 16 shards (16 separate O(1) head-inserts on 16
   engines) — but those are *different* engines/locks, so they parallelize across coordinator workers
   (the whole point). No single lock is contended. This is strictly better than today's single
   `dst.adj_in` chain + dst-shard-lock contention (the `ACCEPTED_AS` worst case at
   `test_edge_popular_parent_throughput.zig:293-350`).
4. **`removeEdge` and edge-property fan-out semantics change.** Removing an edge now must touch
   `shard(src).adj_in_remote` (single-shard — good), but any code path that assumed in-edges live on
   `dst.adj_in` (migration code, `engine_edge_props.zig:44`, `sharded_recovery.zig:213`) must be
   updated together or reads will miss edges. Validation items 3-4 guard this.
5. **Migration cost on the largest graphs.** M1 re-scans out-adjacency on open for legacy graphs
   (one `adj_out` scan per shard — same cost as the existing index rebuild,
   `engine_index.zig:116-168`). For 14.27M taxa this is a full open-time scan; acceptable (it already
   happens for index rebuild when snapshots are stale) but it must run inside checkpointed batches
   under the deferred-WAL bounded-RSS discipline (see MEMORY: geode deferred checkpoint cadence) so
   the conversion itself does not OOM.

### Is there any structural blocker to single-shard cross-endpoint writes? No

The only cross-shard dependency in the edge write is the `dst.adj_in` write
(`sharded_engine.zig:471-481`); everything else (out-adjacency, edge body, edge_index, existence
index, edge properties) is already source-shard-local (`sharded_engine.zig:273-281,456-468,564-566`).
Relocating in-adjacency to a source-shard store removes the last cross-shard dependency, so the edge
write becomes a genuine single-engine transaction. Durability is not a blocker because recovery is
page-image redo keyed by `(file_id, page_id)` (`recovery.zig:221-253`) and the in-index pages are
logged in the same txn. Reverse traversal is not a blocker because the vtable already supports an
arbitrary concrete iterator (`interface.zig:377-381`), so the fan-in drops in without an API change.
**There is no structural reason co-location cannot make cross-shard edge writes single-shard.** The
only real cost is the bounded 16-way reverse-read fan-in (risk #1), which is a deliberate, measured
trade against the ~8× write-throughput unlock.

---

## 10. Risk-ranked, independently-validatable phasing (smallest first)

- **Phase A — single-shard write + per-shard in-index + scatter expandIn (the throughput unlock).**
  Add `FileId.in_idx` + `adj_in_remote` AdjStore + page-backed `in_head_index`; implement
  `addEdgeColocated` (single-shard write, logged in one txn); implement `FanInEdgeIterator` and
  repoint `ShardedGraphEngine.expandInIter`; geode adapter drops the dst locks. **Validate
  independently:** items 1 (throughput), 2 (reverse correctness), 5 (Phase 0-3 green). At this point
  `crossShardAddEdge` is still present but unreachable from `addEdge` — leave it until Phase C so this
  phase is reversible. Highest value, isolated.
- **Phase B — migration.** Add `shard_manifest.layout_version` + M1 rebuild-on-open for legacy
  graphs. **Validate independently:** item 4 (old-layout opens + reverse correct + idempotent reopen)
  and item 3 (recovery). Depends on A's read path; does not touch A's write path.
- **Phase C — cleanup of the dead 2PC edge path.** Delete `crossShardAddEdge`
  (`sharded_engine.zig:351-523`), the `addEdgeCrash*` hooks (`:697-791`), the edge-specific 2PC tests
  (`cross_shard_recovery.zig` edge crash tests), and simplify `sharded_recovery.zig` target reapply;
  enable single-shard cross-endpoint `removeEdge` (`sharded_engine.zig:532-537`). **Validate
  independently:** full suite green + the 2PC-removal item 6. Pure deletion; lowest risk, done last so
  earlier phases stay reversible.

Risk order (highest first): the reverse-read fan-in regression (#1, gate in Phase A item 2), the
directory durability choice (#2, decided in Phase A — page-backed), migration cost/idempotency on
large graphs (#5, Phase B), removeEdge/props fan-out correctness (#4, Phase C). The throughput win
itself is low-risk: it is the *removal* of a serialization point the harness already measures.
