# Task #34 — Triage: bulk-edge ingest stalls on `edges_app_role_assignment.jsonl`

Status: triage only, no fix applied.
Method: static analysis of the coordinator → adapter → engine edge-write
path.  SIGQUIT dump from `post-task33-w16-validation.log` corroborates
the root cause (5 workers parked on server response, server at 203 % CPU
— throughput bottleneck, not a hang).

## TL;DR

The dominant cost is the **per-property edge write loop** in
`bulkInsertEdgeWithIds` (identical shape to the pre-Task-#33 node loop):
each of the N properties on an edge does an O(N) property-chain refresh,
two O(D) adjacency-chain linear scans to update `prop_head`, and a fresh
adapter-mutex acquire.  Aggregated over 400 edges × 3 properties, one
flusher thread, this serialises the whole file.

Of the three user hypotheses:

1. **`setEdgePropertiesBatch` — HIGH IMPACT, PRIMARY FIX.**  Mirrors the
   Task-#33 node path exactly.  Every cost below collapses from N×
   per-property to 1× per-edge.
2. **`merge_prop_index_lock` contention — NOT A FACTOR.**  The
   coordinator's `lookupNodeByMergeKey` path is lock-free (see §Hypothesis
   2 below); the `merge_prop_index_lock` field only guards the Phase-2
   shard-locked MERGE fast path, which the coordinator does not use.
3. **Adjacency-shard collisions — PARTIAL, second order.**  Adjacency
   updates happen inside (1)'s hot loop.  Batching properties
   eliminates 2×(N-1) of the 2×N adjacency updates per edge
   automatically.  No separate fix needed once (1) lands.

## Hypothesis 1 — `setEdgePropertiesBatch` (PRIMARY)

### Code evidence

`src/storage/graph_storage_adapter.zig:1549-1597` — `bulkInsertEdgeWithIds`:

```
const edge_id = try store.createEdgeWithGraph(source_id, target_id, rel_type, graph_name);
for (props) |kv| {
    try store.setEdgeProperty(edge_id, kv.key, kv.value);   // N separate calls
}
```

`store.setEdgeProperty` is at `src/graph_store.zig:3321-3409`.  Per call
it vtable-dispatches into the adapter's `setEdgeProperty`
(`graph_storage_adapter.zig:2272-2320`), which per property does:

| Step | Cost | Location |
|---|---|---|
| `self.mutex.lockUncancelable` (StorageAdapter mutex) | 1 lock acquire | adapter:2282 |
| `requireExistingGraphLocked` | StringHashMap get | adapter:2284 |
| `edge_index.get` | HashMap get | adapter:2293 |
| `node_store.getNode(from)` + `node_store.getNode(to)` | 2× page pins | adapter:2296 / 2304 |
| `putPropertyTxn` | 1× WAL record append to property store | adapter:2299 |
| `adj_out.updateEdgePropHead` — **linear scan** of from-node's outgoing adjacency chain | O(D_out) page pins + per-entry compare | `graph-storage/src/adj_store.zig:210-240`, called from adapter:2303 |
| `adj_in.updateEdgePropHead` — **linear scan** of to-node's incoming adjacency chain | O(D_in) page pins + per-entry compare | adj_store.zig:210-240, called from adapter:2305 |
| `property_index.removeChain` + `refreshPropertyChainIndex` | iterates **every** property already on the chain, `allocator.dupe(key)` per entry, Wyhash per value | `graph-storage/src/property_chain_index.zig:123-152` |

`refreshPropertyChainIndex` is the O(N²)/edge trap: after adding the
k-th property, the refresh walks k entries.  For a 3-property edge:
1 + 2 + 3 = 6 dupe+hash operations per edge instead of 3.

### Arithmetic vs. the observed stall

- `edges_app_role_assignment.jsonl` = 400 edges × 3 string properties.
- Total property set calls: **1,200**.
- Add 400× `createEdgeWithGraph` (2 adjacency inserts each = 800
  adjacency writes).
- Flusher is single-threaded per graph (`group_commit.zig:159-193` +
  the per-graph registry at `group_commit.zig:538-558`).  All 16
  client workers converge on one flusher.
- Empirical stall: 2 m 18 s (138 s) with server at 203 % CPU — i.e.
  flusher pinned + one helper thread.  That's ~**115 ms per edge**
  amortised, which is entirely consistent with the loop above under
  buffer-pool fault / WAL fsync domination.
- Contrast node-phase (post-Task-#33): `audit_event` = 2,414 nodes
  with ~5-15 props each in 104 s → ~43 ms/node.  Edges cost roughly
  **3× per record** even though they have fewer properties — consistent
  with adjacency chain scans + `refreshPropertyChainIndex` O(N²) amplification
  absent in the node batch path.
- The 5 blocked-in-ReceiveProto workers in the SIGQUIT dump are not
  stuck — they are correctly parked waiting for responses whose
  `Exec` work is still queued behind prior workers' edge-apply loops
  on the flusher.

### Fix scope (NOT to be applied in triage)

1. Add `GraphStore.setEdgePropertiesBatch` (mirror of
   `setNodePropertiesBatch` at `graph_store.zig:2058`) that runs all
   property puts under a single adapter-mutex acquisition and joins
   the statement txn.
2. Add `adapter.setEdgePropertiesBatch` (mirror of
   `adapter.setNodePropertiesBatch` at
   `graph_storage_adapter.zig:2031-2101`) that:
   - Acquires the adapter mutex once.
   - Opens / joins the statement txn once.
   - Calls `putPropertyTxn` N times.
   - Calls `adj_out.updateEdgePropHead` + `adj_in.updateEdgePropHead`
     **exactly twice** at the end (once for the terminal `prop_head`,
     not per property — the intermediate prop_heads are never read).
   - Calls `refreshPropertyChainIndex` **once** at the end.
   - Writes the edge record / edge_index entry once at the end.
3. Route `bulkInsertEdgeWithIds` (adapter:1590-1593) and
   `bulkInsertEdgeInnerShardLocked` (adapter:1308-1310) through the
   new batch helper.  Both loops are identical and share the same
   cost.
4. No changes to `group_commit.zig:437-491` required — the coordinator
   just keeps calling `bulkInsertEdgeWithIds`.

## Hypothesis 2 — `merge_prop_index_lock` contention (NOT A FACTOR)

`lookupNodeByMergeKey` at `graph_storage_adapter.zig:1511-1526` does
**no locking at all**:

```
pub fn lookupNodeByMergeKey(...) !u64 {
    _ = self;
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    ...
    switch (store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &id)) { ... }
}
```

`GraphStore.lookupMergeCandidate` (`graph_store.zig:1712-1724`) is a
plain `std.StringHashMap.get` + `nodes.get`.  Safe under the
coordinator's exclusive write lock — no other writer can be in this
field.  Two lookups per edge × 400 edges = 800 HashMap probes,
sub-microsecond each.  Not on the critical path.

The `merge_prop_index_lock` field exists at
`graph_storage_adapter.zig:500` but is referenced only by
`bulkMergeNodeWithReservedId` (adapter:1339, 1353), the Phase-2
shard-locked MERGE path.  The coordinator's
`bulk_match_create_edge` op does not touch it.

## Hypothesis 3 — Adjacency-shard collisions (SECOND-ORDER, auto-fixed by H1)

Under the coordinator model the flusher is single-threaded, so
per-shard collisions do not exist at the worker level.  What *does*
exist is that each property write calls
`updateEdgePropHead(adj_out)` **and** `updateEdgePropHead(adj_in)`
— two separate linear scans through adjacency chains on two
different nodes' shards.  For a batch of 25 edges × 3 props that is
150 adjacency-chain scans.

Fix H1 collapses this to 2 scans per edge (one outgoing, one
incoming, after the final `prop_head` is known), i.e. 50 scans
instead of 150 — a 3× reduction for free.  No separate fix required.

## Ranked root-cause candidates

| # | Candidate | Est. cost share | Fix |
|---|---|---|---|
| 1 | Per-property loop in `bulkInsertEdgeWithIds` | ~80-90 % | Add `setEdgePropertiesBatch`; route both edge-insert paths through it |
| 2 | Adapter-mutex re-acquire per property | ~5-10 % | Eliminated for free by #1 (one acquire per edge) |
| 3 | O(N²) `refreshPropertyChainIndex` amortised across the loop | ~5-10 % | Eliminated for free by #1 (one refresh per edge) |

Hypotheses 2 and 3 from the ticket are **not supported** by the code
(the merge-index path is lock-free under the coordinator; adjacency
shard collisions are a worker-level concern that the single-flusher
coordinator already eliminates).

## Fix order

**One fix.  Implement `setEdgePropertiesBatch` and route both edge
insert paths through it.**

No ordering issues — it is additive.  Keep the existing
`setEdgeProperty` for non-bulk callers.

## Classification

- **Type**: Logic bug — per-property loop, a verbatim carryover of the
  pre-Task-#33 node shape.  No race, no flakiness, no platform
  dependency, no config.
- **Security / data integrity**: none.  The batch path writes into the
  same statement txn the coordinator already owns; one WAL fsync per
  batch is preserved.
- **Blast radius**: two call sites
  (`bulkInsertEdgeWithIds`, `bulkInsertEdgeInnerShardLocked`) plus
  one new function each in `adapter` and `graph_store`.  Regression
  cover: existing bulk-ingest tests + the SIGQUIT-dump repro below.

## Reproducer (for the fixer)

Baseline (current `main @ 042b43ef`):

```
# From geode repo root
make build
# Terminal 1: server with authentication password fixed for the harness.
GEODE_ADMIN_PASSWORD=<pw> ./zig-out/bin/geode serve --listen 0.0.0.0:3141

# Terminal 2: seed nodes only, then seed *just* the stalling edge file.
cd ../geode-test-harness
GEODE_ADMIN_PASSWORD=<pw> \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<pw>" \
  make loadtest-go  # or harness-run with -phase nodes

# Isolate the edge file (bypasses the 6m55s node warm-up on each iteration):
cp /home/benji/eagleg-topology-data-15/edges_app_role_assignment.jsonl /tmp/task34-edges.jsonl

# Time the seed of just this file with 16 workers.  Pre-fix: stalls at
# >2 min, 5 of 16 workers blocked in ReceiveProto.  Post-fix target: <20 s.
time msft-graph seed --edges-only --workers 16 --file /tmp/task34-edges.jsonl
```

Success criteria for the fix:

- `edges_app_role_assignment.jsonl` completes in <20 s (matches
  proportional scaling from `audit_event.jsonl` node throughput).
- SIGQUIT mid-run shows workers cycling through ReceiveProto, not
  parked > 10 s on a single `Exec`.
- Load-test comparison (`make loadtest-compare`) shows no regression
  on query-side baselines.

## Blockers

None.  The fix is additive, Task #31 and Task #33 have already
de-risked both the lane-starvation hang and the statement-txn join.

## Artifacts referenced

- `src/storage/group_commit.zig:437-491` (coordinator op dispatch)
- `src/storage/graph_storage_adapter.zig:1549-1597` (per-property loop)
- `src/storage/graph_storage_adapter.zig:2272-2320` (adapter
  `setEdgeProperty` hot path)
- `src/storage/graph_storage_adapter.zig:2031-2101`
  (`setNodePropertiesBatch` reference pattern)
- `src/graph_store.zig:3321-3409` (`GraphStore.setEdgeProperty` +
  vtable dispatch)
- `/home/benji/src/devnw/zig/graph-storage/src/adj_store.zig:210-240`
  (`updateEdgePropHead` linear-chain scan)
- `/home/benji/src/devnw/zig/graph-storage/src/property_chain_index.zig:123-152`
  (`refreshFromIterator` O(N) per property)
- `docs/performance/2026-04-24-sharding/phase4.1-validation/post-task33-w16-validation.log:541-545`
  (empirical stall on file `edges_app_role_assignment.jsonl`)
