# Code-first Performance Review of Geode and graph-storage

## Executive summary

**Versions reviewed (ground truth)**  
Geode pins `graph-storage` at commit `7adde34658692ffc651af4cfea72a86fc50d20b5` in `build.zig.zon`. citeturn2view0 Geode itself was reviewed at the current `main` head shown in the commit log (`9110d041`). citeturn3view0

(1) **Top 10 performance problems ranked by expected impact**

1. **Per-edge/per-candidate heap allocation in MATCH traversal**: `executeSingleHopEdgeTraversal` allocates `env_names` + `env_values` slices for *every* candidate edge, then allocates a row per surviving candidate (and often calls `eval.evalExpr` repeatedly). This is catastrophic on high-degree nodes and any “expand + filter” workload. citeturn37view0  
2. **Label candidate selection is algorithmically weak in Geode**: `GraphStore.getNodesByLabels` starts from the *first* label’s posting list, then for each candidate node scans `node.labels` to check other labels (no posting-list intersection, no “smallest label first”). Worst-case candidate explosion is driven by input label order, not selectivity. citeturn32view3turn31view1  
3. **Variable-length path MATCH materializes all paths**: `executeVariableLengthPathTraversal` calls `expandVariableLengthPaths`, then iterates `paths.items`, building extra allocations per path (edge lists, path node/edge arrays, env arrays). This can turn “find paths” into “allocate the universe.” citeturn36view4  
4. **Multi-hop GROUP BY duplicates and copies bindings aggressively**: `executeMultiHopGroupBy` repeatedly allocates and copies `env_names`/`env_values` per binding and per hop, and also allocates serialized group keys. This amplifies nested-loop costs and allocation churn as hop count and branching grow. citeturn37view2  
5. **MATCH still falls back to full node scans in multiple paths** (true brute-force): e.g., `executeMatchCallQuery` iterates `read_store.nodes.iterator()` and filters afterwards; other multi-chain paths also scan `store.nodes.iterator()` when labels are absent. citeturn16view1turn37view2  
6. **Geode runs MATCH on the writable global store with snapshot disabled** due to a use-after-free bug in the snapshot path. This forces “hold lock during MATCH,” limiting concurrency and making slow queries block everything. citeturn37view3turn35view0  
7. **Geode’s in-memory `GraphStore` is hash-map-heavy and pointer-chase-heavy**: nodes/edges in `AutoHashMap`, properties in `StringHashMap`, labels as `[][]const u8`. Traversal does hash lookup per edge (`store.edges.getPtr(edge_id)`), defeating locality even when adjacency IDs are contiguous. citeturn24view1turn37view0turn23view0  
8. **Label scans in the adapter are “linear but slow in reality”**: `StorageAdapter.getNodesByLabel` iterates label postings, and for each `nid` pins/unpins the node page to check deleted/empty flags. That turns an O(k) posting walk into O(k) pin/unpin operations, which is effectively random I/O/caching work at CPU speed. citeturn30view4turn30view2  
9. **graph-storage checkpoints rewrite full derived index snapshots** (labels/props/edges) on each checkpoint, scaling with total graph size rather than working set. `engine_persist.checkpoint` calls `engine_index.saveDerivedIndexes`. citeturn48view3turn41view0turn40view2turn45view0  
10. **Property decoding allocates for strings/ext types** and the vtable wrapper decodes during property iteration. Any workload that scans properties (or uses iterator-based property access) triggers allocator churn. citeturn44view0turn43view2  

(1) **Likely biggest cause of current MATCH slowness**  
MATCH execution frequently combines: (a) oversized candidate sets (weak/late pruning, occasional full scans), with (b) extreme allocation churn per candidate (especially `env_names`/`env_values` and row creation), plus (c) hash lookups per edge/node/property in `GraphStore`. The hot loop in `executeSingleHopEdgeTraversal` is the clearest embodiment of this pattern. citeturn37view0turn24view1

(1) **Likely biggest storage-layer bottleneck**  
`graph-storage`’s checkpoint path is not “working-set oriented” because it persists *full* derived index snapshots (`labels.idx`, `props.idx`, `edges.idx`) whenever `engine.persistence_dirty` is true. That means a small mutation rate can still trigger “rewrite an index the size of the graph.” citeturn48view3turn41view0

(1) **Top 3 “fix now” recommendations**

1. **Stop allocating `env_names/env_values` per candidate in MATCH traversal** (Geode): replace per-candidate heap allocations with fixed-size stack buffers for the common cases (≤3 bindings in single-hop; ≤4 in var-len with path var), and restructure evaluation to reuse an `Env` view. citeturn37view0turn36view4  
2. **Replace `getNodesByLabels` with posting-list intersection + smallest-label-first** (Geode): choose the most selective label first (smallest posting list) and intersect additional labels using two-pointer merge on sorted lists (or hash-set fallback). This prevents label order from becoming an accidental worst-case. citeturn32view3turn31view1  
3. **Eliminate per-node pin/unpin in label scans** (split): short-term fix in Geode’s adapter by caching the current pinned node page while iterating sorted node IDs; longer-term fix in `graph-storage` by adding a “live label iterator” that internally batches by page. citeturn30view4turn40view0  

## Hotspot ranking table

(2) **Hotspot ranking table**

| Rank | File | Function / path | Query or workload affected | Current behavior | Current complexity | Why it is slow in practice | Proposed fix | Fix belongs in | Expected impact | Risk | Validation benchmark |
|---:|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `src/execution/match_operations.zig` | `executeSingleHopEdgeTraversal` | Single-hop MATCH, undirected patterns, MATCH+WHERE, MATCH+SET | Allocates env arrays + rows per surviving candidate edge; repeated `eval.evalExpr` and hash lookups for each candidate | O(E_left × (filters + eval)) but with *allocator cost per edge* | Allocation churn, allocator contention, pointer chasing (`edges.getPtr`), repeated expression eval | Use fixed-size stack env buffers; reuse `Env`; delay/avoid row allocation; early prune (type/tenant/labels) before env creation | `geode` | Huge p50/p95 win on traversals | Medium (touches semantics of eval/with) | “high-degree expansion” + allocations/query stats citeturn37view0turn24view1 |
| 2 | `src/graph_store.zig` | `getNodesByLabels` | Label-filtered MATCH, planner candidate formation | Starts with first label posting list; per node scans `node.labels` for remaining labels; tenant filter applied per node | O(\|L0\| × avg_labels_per_node × (#labels-1)) | Input label order can make L0 huge; per-node label scanning is branchy + cache-missy | Pick smallest label posting list; intersect postings using sorted merge; integrate tenant/RLS checks during intersection | `geode` | Huge for multi-label filters | Low–Medium | “label-only selective MATCH” with 2–4 labels citeturn32view3turn31view1 |
| 3 | `src/execution/match_operations.zig` | `executeVariableLengthPathTraversal` | Variable-length paths `[*]`, path binding | Materializes all paths (`paths.items`), then allocates edge lists and Path values per path | Potentially exponential in paths; also O(#paths × allocations) | Explodes memory and GC/allocator time; builds lists even when LIMIT would cut | Stream paths (iterator/generator) and apply filters while exploring; push LIMIT into traversal | `geode` (and possibly `both` if storage helps) | Very large on var-len workloads | High | “var-len low-degree vs high-degree” p95 + peak RSS citeturn36view4 |
| 4 | `src/execution/match_operations.zig` | `executeMultiHopGroupBy` | Multi-hop patterns with GROUP BY | Copies bindings per hop; builds group keys as allocated strings; stores bindings in hash maps | O(product of branching per hop) with heavy copying | Nested loops plus “copy env arrays” = brutal allocation traffic | Represent bindings as indices into a binding arena; don’t copy name arrays; compute group keys incrementally; prune early | `geode` | Large on analytics-style queries | Medium–High | “multi-hop group by” + allocations/query citeturn37view2 |
| 5 | `src/execution/match_operations.zig` | `executeMatchCallQuery` and other full scans | MATCH+CALL, some chain fallbacks | Uses `read_store.nodes.iterator()` and filters afterward | O(N) per call/chain | Full scan of hash map entries; poor locality; blocks store lock | Require label-driven candidate formation; if no label, require LIMIT pushdown or refuse/unoptimized warning | `geode` | Large where it triggers | Low | “MATCH+CALL” with and without labels citeturn16view1 |
| 6 | `src/execution/match_operations.zig` | Snapshot disabled (`skip_snapshot = true`) | Concurrency and long MATCH queries | Runs on writable store; comment indicates snapshot causes UAF; lock held across query | N/A (locking) | Query latency becomes global stall; p95 suffers from convoying | Fix snapshot memory ownership or move to MVCC-style read view; meanwhile reduce hold time via streaming | `geode` | Big p95 under concurrency | High | “concurrent read/write” throughput + p95 citeturn37view3turn35view0 |
| 7 | `src/storage/graph_storage_adapter.zig` | `getNodesByLabel` | Label scans into engine | For each `nid`, checks allocation, pins node page, reads record, unpins | O(k) but with O(k) pins | Pin/unpin overhead dominates; repeated page touches; defeats sorted locality | Cache pinned node page while `page_id` unchanged; better: expose “live label iterator” in storage | `both` (short-term geode, long-term storage) | Big for label-heavy MATCH | Low–Medium | “label scan 1M ids” cycles + buffer pool pins citeturn30view4turn40view0 |
| 8 | `src/storage/graph_storage_adapter.zig` | `rebuildExactNodePropertyIndex` on open | Startup/open latency | Scans all nodes; for each reads labels and all properties; rebuilds in-memory exact index | O(total nodes + total properties) | Adds full-graph scan on open; duplicates indexing responsibility | Add real property-value index in `graph-storage` (or persist adapter index); or make build lazy/partial | `both` | High for large graphs on restart | Medium | “open latency” and “warm restart” citeturn29view1turn39view0 |
| 9 | `graph-storage/src/engine_persist.zig` + `engine_index.zig` | `checkpoint` → `saveDerivedIndexes` | Checkpoint latency; write amplification | Each checkpoint flushes pages and rewrites derived index snapshots and label dict | O(size of indexes) | Rewriting `labels.idx/props.idx/edges.idx` scales with total graph | Persist derived snapshots less frequently; incremental/delta snapshots; per-index dirty tracking | `graph-storage` (and `geode` should reduce checkpoint frequency) | Huge for mutation-heavy workloads | Medium–High | “checkpoint bytes written” + time citeturn48view3turn41view0 |
| 10 | `graph-storage/src/property.zig` + `interface.zig` | decode + `wrapPropIterator` | Property iteration; predicate evaluation via iterators | Decoding dupes strings/ext; wrapper decodes on each `next()` | O(m) but alloc-heavy | Allocation per property dominates; repeated copies break locality | Add “view” decoding (no dupe) tied to pinned page lifetime; or cache decoded interned strings | `graph-storage` | Medium (depends on property-scan usage) | Medium | “scan properties per node” allocations/op citeturn44view0turn43view2 |

## Detailed findings

(3) **High-confidence hotspot: per-candidate allocation in single-hop expansion**

**Files/functions**: `src/execution/match_operations.zig` → `executeSingleHopEdgeTraversal`. citeturn37view0  

**Call chain (observed)**: `executeMatchQueryImpl` dispatches into traversal helpers; single-hop relationships use `executeSingleHopEdgeTraversal`, which pulls edge IDs via `store.getOutgoingEdgeIds/getIncomingEdgeIds`, then for each `edge_id` does `store.edges.getPtr(edge_id)` and filters. citeturn37view0turn24view1  

**Current complexity**: roughly O(out_degree + in_degree) per left node for enumeration, but multiplied by *per-candidate heap allocations* plus repeated expression evaluation. citeturn37view0  

**Why it’s slow in practice (locality/allocations)**  
The inner loop allocates `env_names` and `env_values` every time it considers a candidate match (edge), even though the maximum number of bindings is tiny (left node + rel + right node). It then evaluates WHERE/FILTER, potentially SET clauses, and finally allocates a `row` slice. citeturn37view0 That does three “bad for CPU” things simultaneously:

* allocator traffic (often dominates wall time under load),
* hash map pointer chasing on every edge (`edges.getPtr`, `nodes.getPtr`),
* repeated evaluation paths that often materialize temporary values.

**Concrete recommendation**  
Do not allocate per candidate. Represent the match environment for single-hop as small fixed arrays on the stack and pass slices into `Env`. Only allocate a row when the candidate survives cheap filters and is actually needed for WITH/RETURN output.

**Docs vs code**: N/A (this is Geode logic).

**Fix belongs in**: `geode`.

---

(3) **High-confidence hotspot: Geode label matching is not posting-list-first**

**Files/functions**: `src/graph_store.zig` → `getNodesByLabel`, `getNodesByLabels`. citeturn31view1turn32view3  

**Call chain (observed)**: MATCH uses label constraints to form candidates through `store.getNodesByLabels(...)`; that function starts from candidates with `labels[0]`, then checks remaining labels by scanning each node’s `labels` slice. citeturn32view3  

**Current complexity**: O(|posting(first_label)| × avg_labels_per_node × (#labels−1)). citeturn32view3  

**Why it’s slow in practice**  
This is “looks reasonable on paper” but is selectivity-hostile: if the query writes labels in a bad order (or planner doesn’t reorder), you can start from the largest posting list and do tons of per-node label scanning. Label scanning is branchy and pointer-heavy because labels are separate heap strings. citeturn23view0turn32view3  

**Concrete recommendation**  
Maintain posting lists as sorted node IDs (you already effectively do by appending IDs into the label index lists), then intersect postings lists in increasing cardinality order. At minimum: choose smallest label first using `list.items.len`. Best: two-pointer intersection (linear in sum lengths) for sorted lists.

**Fix belongs in**: `geode`.

---

(3) **High-confidence hotspot: variable-length paths are pre-materialized**

**Files/functions**: `src/execution/match_operations.zig` → `executeVariableLengthPathTraversal`. citeturn36view4  

**Call chain (observed)**: it calls `expandVariableLengthPaths(...)` producing `paths`, then iterates `paths.items`. For each path it may allocate:  

* `env_names/env_values`,  
* `edge_values` list (when `rel_var` is present),  
* additional `Path` node/edge arrays for `chain_path_var`. citeturn36view4  

**Current behavior/complexity**  
Even if the underlying traversal is BFS, the API shape forces materialization of all discovered paths before filtering by right-node labels/properties, WHERE/FILTER, or LIMIT. That is worst-case exponential in path count and is routinely memory-bound. citeturn36view4  

**Concrete recommendation**  
Refactor variable-length traversal into a generator/iterator that yields paths incrementally and applies filters as early as possible. Push `max_len`, right-label checks, and `LIMIT` into the traversal loop so you can terminate early.

**Fix belongs in**: primarily `geode`, but a storage-level “bounded expansion iterator” can help if you later push traversal into `graph-storage`.

---

(3) **High-confidence hotspot: adapter label scans are dominated by pin/unpin**

**Files/functions**: `src/storage/graph_storage_adapter.zig` → `getNodesByLabel`. citeturn30view4  

**Call chain (observed)**: `getNodesByLabel` calls `mg.storage().scanLabelIter(label_id, allocator)`, then for each `nid` computes `page_id`, pins the node page, reads `NodeRec`, unpins, and filters deleted/empty nodes. citeturn30view4turn43view0  

**Root cause**  
`graph-storage`’s `GraphEngine.deleteNodeTxn` marks the node as deleted in `node_store` but does not remove `nid` from the in-memory `label_index`. citeturn42view0turn46view0 As a result, higher layers must re-check node liveness.  

**Why it’s slow in practice**  
`LabelIndex` maintains posting lists sorted by `NodeId` via binary-search insertion. citeturn40view0turn40view1 That sortedness means node IDs are naturally clustered by page — yet the adapter misses the win by pinning/unpinning per ID rather than per page.

**Concrete recommendation**  
Short-term: in the adapter, keep the current pinned node page frame and only repin when `page_id` changes. Long-term: fix this at the source by providing a storage-level iterator that yields only live nodes (or by updating label postings on delete).

**Fix belongs in**: `both` (fast patch in `geode`, proper fix in `graph-storage`). citeturn30view4turn40view0turn42view0  

---

(3) **High-confidence hotspot: checkpoint amplification scales with total graph size**

**Files/functions**:  

* `graph-storage/src/engine_persist.zig` → `checkpoint` citeturn48view3  
* `graph-storage/src/engine_index.zig` → `saveDerivedIndexes` citeturn41view0  
* `graph-storage/src/label_index.zig` → `saveToFile` (writes all postings) citeturn40view2  
* `graph-storage/src/property_chain_index.zig` → `saveToFile` (writes digests for all chains) citeturn45view0  
* `graph-storage/src/checkpoint.zig` → `Checkpointer.doCheckpoint` flushes and syncs citeturn47view0  

**Call chain (end-to-end)**  
Geode’s adapter runs `mg.engine.checkpoint()` during `checkpointAll` under a per-graph read lock. citeturn28view2 In the engine, `GraphEngine.checkpoint` calls `engine_persist.checkpoint`, which:  

1) flushes dirty pages + fsyncs store files via `checkpointer.doCheckpoint`, citeturn47view0turn48view3  
2) writes `free.store`,  
3) **rewrites derived index snapshot files**,  
4) writes `labels.dict`. citeturn48view3turn41view0  

**Why it’s slow**  
Even if only a handful of nodes changed, persisting derived indexes is proportional to the size of the in-memory structures (`label_index`, `property_index(chains)`, `edge_index`). The design is durable, but not working-set oriented. citeturn48view3turn41view0  

**Concrete recommendation**  
Introduce per-index dirty tracking and avoid rewriting snapshots every checkpoint. Options range from “only write snapshots periodically” to “delta snapshot segments.” If Geode is calling checkpoint frequently, first reduce that frequency (still safe because WAL commits are durable). citeturn47view0turn48view3  

**Fix belongs in**: `graph-storage` (core), and `geode` should avoid triggering global checkpoint work as a “save” surrogate.

---

(3) **High-confidence hotspot: adapter rebuilds an extra full-graph property index on open**

**Files/functions**: `src/storage/graph_storage_adapter.zig` → `openGraphLocked` calls `rebuildExactNodePropertyIndex`; the rebuild scans all nodes and reads labels and properties. citeturn29view1  

**Why it matters**  
`GraphEngine.open` already has to load or rebuild derived indexes (`tryLoadDerivedIndexes` else `rebuildDerivedIndexes`). citeturn39view0turn41view0 On top of that, the adapter always rebuilds its own exact property index. That creates a second startup scan that grows with total graph size.

**The deeper issue (docs vs code)**  
The `graph-storage` architecture doc describes a `PropertyChainIndex` mapping `(key_hash, value_hash)` to sorted `[]NodeId` posting lists. citeturn38view0 The actual `property_chain_index.zig` in the pinned commit is *not that*: it is a per-`prop_head` digest map that supports “does this chain have key K?”, not “which nodes have (K=V)”. citeturn45view0 That mismatch explains why Geode built a separate exact property index in the adapter.

**Concrete recommendation**  
Either implement the intended property-value posting index in `graph-storage` (so Geode can stop rebuilding its own), or persist the adapter’s index so it doesn’t require full rebuilds on open.

**Fix belongs in**: `both` (storage feature + Geode migration off adapter-only index). citeturn29view1turn45view0turn38view0  

## Fixes by layer

(4) **Fixes by layer**

### A. graph-storage fixes

1. **Add a “live label scan iterator” that batches by node page**  
Today, `LabelIndex.iterator` returns raw `NodeId`s with no liveness guarantee. citeturn40view0turn42view1 Because deletes only mark flags in `node_store` (`NODE_FLAG_DELETED`) and don’t update the label index, higher layers must check liveness. citeturn42view0turn46view0  
Design: a `scanLabelLiveIter(label_id)` iterator that internally:
   * reads sorted node IDs,  
   * pins the current node page once,  
   * yields only non-empty, non-deleted slots,  
   * repins only when page changes.

2. **Stop rewriting full derived index snapshots on every checkpoint**  
Checkpoint currently includes `engine_index.saveDerivedIndexes(engine)` every time the engine is dirty. citeturn48view3turn41view0  
At minimum: track dirty flags for `label_index`, `edge_index`, and `property_index` and only rewrite snapshots when those dirty flags are set (or when `manifest.counter % N == 0`). Better: write delta segments.

3. **Introduce a real exact-match property-value index (posting lists)**  
The present `PropertyChainIndex` is per-`prop_head` digests and doesn’t support fast `(key=value) → NodeId` retrieval. citeturn45view0 Implement a posting structure keyed by `(key_hash, value_hash)` (or `(label_id, key_hash, value_hash)`), with sorted `NodeId` lists. This directly replaces Geode’s adapter-level `exact_node_property_index`. citeturn29view1  

4. **Add a “property view” decode path to avoid string/ext allocation for scans**  
`PropertyValue.decode` duplicates string/ext bytes with the allocator. citeturn44view0 And the vtable wrapper decodes on iterator `next()`. citeturn43view2  
Provide an alternate iterator/value type that returns references tied to pinned page lifetime (or intern strings where safe).

### B. geode fixes

1. **Eliminate per-candidate `Env` allocation in MATCH loops**  
`executeSingleHopEdgeTraversal` allocates env arrays and row arrays inside the edge loops. citeturn37view0 Make the env representation stack-based for common cases; allocate row only after passing cheap filters.

2. **Replace `GraphStore.getNodesByLabels` with selectivity-driven posting intersection**  
Current implementation is label-order sensitive and per-node scans labels. citeturn32view3turn23view0  
Intersect postings (sorted arrays) and push tenant/RLS checks during intersection.

3. **Make variable-length path expansion streaming and LIMIT-aware**  
`executeVariableLengthPathTraversal` currently materializes paths and then filters. citeturn36view4  
Convert to iterator and short-circuit on LIMIT and filter failure.

4. **Stop holding the global writable-store lock for long MATCH**  
Snapshot is disabled due to a memory ownership bug (UAF). citeturn37view3 Fix snapshot semantics (own/copy strings or keep snapshot allocator alive until result consumption), or redesign to a read view that can outlive execution.

### C. split fixes

1. **Label scan liveness filtering**  
Short-term: cache page pins in `StorageAdapter.getNodesByLabel` so sorted IDs reuse a pinned page. citeturn30view4turn40view0  
Long-term: move this into `graph-storage` so `scanLabelLiveIter` yields only live nodes, and Geode removes the manual page-byte inspection.

2. **Exact-match label+property candidate lookup**  
Short-term: if Geode keeps its adapter-level exact property index, make `rebuildExactNodePropertyIndex` lazy and/or persist it so open doesn’t rescan. citeturn29view1  
Long-term: implement the posting index in `graph-storage` and migrate Geode to it, dropping the adapter index.

3. **Checkpoint strategy**  
`graph-storage` should reduce snapshot rewrite frequency (core). citeturn48view3turn41view0  
Geode should stop using full checkpoint as a “save completion” mechanism and instead call checkpoint only when WAL exceeds thresholds (while relying on WAL durability for commits).

## Zig pseudocode / patch sketches

(5) **Patch sketches for top issues**

### Patch sketch: remove per-edge env allocations in single-hop traversal

**Belongs in**: `geode` (`src/execution/match_operations.zig`) citeturn37view0  
**Why it helps**: turns “allocation per edge candidate” into “no allocation unless producing a result row,” reducing allocator overhead and improving cache behavior.

```zig
// geode: src/execution/match_operations.zig
fn executeSingleHopEdgeTraversalFast(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    left_node: *graph_store.Node,
    // ...same params...
) !void {
    // Precompute constant params once
    const outgoing = if (rel_direction == 'r' or rel_direction == 'u')
        (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{})
    else
        &[_]u64{};

    const incoming = if (rel_direction == 'l' or rel_direction == 'u')
        (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{})
    else
        &[_]u64{};

    // Stack env buffers: single-hop binds at most 3 values.
    var names_buf: [3][]const u8 = undefined;
    var values_buf: [3]Value = undefined;

    inline for ([_]struct { ids: []const u64, use_from: bool }{
        .{ .ids = outgoing, .use_from = false },
        .{ .ids = incoming, .use_from = true  },
    }) |set| {
        for (set.ids) |edge_id| {
            const edge = store.edges.getPtr(edge_id) orelse continue;

            // Cheap filters first (no env creation yet)
            if (rel_type) |rt| if (!std.mem.eql(u8, edge.label, rt)) continue;
            if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
            if (!matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

            const right_node_id = if (set.use_from) edge.from_id else edge.to_id;
            const right = store.nodes.getPtr(right_node_id) orelse continue;

            // Apply right-label/right-prop filters before env creation
            if (!rightNodePassesInlineFilters(right, right_labels, right_props, param_names, param_values, allocator))
                continue;

            // Now build Env as slices into stack buffers
            var n: usize = 0;
            if (left_node_var) |v| { names_buf[n] = v; values_buf[n] = .{ .Node = left_node }; n += 1; }
            if (rel_var) |v|      { names_buf[n] = v; values_buf[n] = .{ .Edge = edge };      n += 1; }
            if (right_node_var) |v|{ names_buf[n] = v; values_buf[n] = .{ .Node = right };    n += 1; }

            const env = Env{
                .names = names_buf[0..n],
                .values = values_buf[0..n],
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
                .owned = false, // critical: no frees needed
            };

            if (!passesWhereAndFilter(env, where_clause, filter_clause, allocator)) continue;

            // Only now allocate a row (if needed)
            const row = try buildRowFromEnvOrReturn(allocator, env, has_with, items);
            try rows.append(allocator, row);
        }
    }
}
```

**Benchmark expected to improve**: high-degree single-hop expansions; allocations/query and p95 latency. citeturn37view0  

---

### Patch sketch: posting-list intersection for multi-label candidate selection

**Belongs in**: `geode` (`src/graph_store.zig`) citeturn32view3turn31view1  
**Why it helps**: reduces candidate blowups from “scan many nodes” to “intersect small sorted lists.”

```zig
// geode: src/graph_store.zig
pub fn getNodesByLabelsFast(
    self: *const GraphStore,
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    labels: []const []const u8,
    tenant_id: ?[]const u8,
) !std.ArrayList(u64) {
    var out = std.ArrayList(u64).empty;
    if (labels.len == 0) return out;

    // Gather posting lists and pick smallest first
    var lists = try allocator.alloc([]const u64, labels.len);
    defer allocator.free(lists);

    var i: usize = 0;
    while (i < labels.len) : (i += 1) {
        lists[i] = self.getNodesByLabel(graph_name, labels[i]) orelse &[_]u64{};
    }

    // Sort list indexes by length (smallest-first)
    var idxs = try allocator.alloc(usize, labels.len);
    defer allocator.free(idxs);
    for (idxs, 0..) |*p, j| p.* = j;

    std.sort.pdq(usize, idxs, lists, struct {
        fn lessThan(ctx: []const []const u64, a: usize, b: usize) bool {
            return ctx[a].len < ctx[b].len;
        }
    }.lessThan);

    // Two-pointer intersect progressively (assumes lists are sorted by node_id)
    var current = lists[idxs[0]];
    var tmp = std.ArrayList(u64).empty;
    defer tmp.deinit(allocator);

    var k: usize = 1;
    while (k < idxs.len) : (k += 1) {
        tmp.clearRetainingCapacity();
        const next = lists[idxs[k]];
        var a: usize = 0;
        var b: usize = 0;
        while (a < current.len and b < next.len) {
            const va = current[a];
            const vb = next[b];
            if (va == vb) {
                // optional: tenant filter here to avoid later work
                if (tenant_id) |tid| {
                    if (self.nodes.get(va)) |node| {
                        if (!std.mem.eql(u8, node.tenant_id, tid)) { a += 1; b += 1; continue; }
                    } else { a += 1; b += 1; continue; }
                }
                try tmp.append(allocator, va);
                a += 1; b += 1;
            } else if (va < vb) a += 1 else b += 1;
        }
        current = tmp.items;
    }

    try out.ensureTotalCapacity(allocator, current.len);
    for (current) |nid| out.appendAssumeCapacity(nid);
    return out;
}
```

**Benchmark expected to improve**: multi-label selective MATCH, especially when a “big label” appears first in the query. citeturn32view3  

---

### Patch sketch: cache pinned node pages in adapter label scan

**Belongs in**: `geode` short-term (`src/storage/graph_storage_adapter.zig`) citeturn30view4  
**Why it helps**: reduces per-node pin/unpin to per-page pin/unpin for sorted node IDs.

```zig
// geode: src/storage/graph_storage_adapter.zig
pub fn getNodesByLabelFast(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
    const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return try allocator.alloc(u64, 0);
    const mg = ctx.mg;

    var iter = try mg.storage().scanLabelIter(ctx.label_id, allocator);
    defer iter.deinit();

    const npp = mg.engine.node_store.nodes_per_page;
    const hdr = gs.node.PAGE_HEADER_SIZE;

    var result = std.ArrayList(u64).empty;
    errdefer result.deinit(allocator);

    var pinned_page: ?u64 = null;
    var pinned_frame: ?gs.buffer_pool.PageFrame = null;

    defer {
        if (pinned_frame) |frame| {
            mg.engine.node_store.buffer_pool.unpin(mg.engine.node_store.buffer_pool.frameIndex(frame), false);
        }
    }

    while (try iter.next()) |nid| {
        const page_id = nid / npp;

        if (!mg.engine.node_store.free_space.isAllocated(page_id)) continue;

        // Repin only when page changes
        if (pinned_page == null or pinned_page.? != page_id) {
            if (pinned_frame) |frame| {
                mg.engine.node_store.buffer_pool.unpin(mg.engine.node_store.buffer_pool.frameIndex(frame), false);
            }
            pinned_frame = try mg.engine.node_store.buffer_pool.pin(.nodes, page_id);
            pinned_page = page_id;
        }

        const slot: u32 = @intCast(nid % npp);
        const off = hdr + slot * @sizeOf(gs.node.NodeRec);
        const data = pinned_frame.?.dataSlice();
        const rec = std.mem.bytesToValue(gs.node.NodeRec, data[off..][0..@sizeOf(gs.node.NodeRec)]);

        if (gs.node.isDeleted(&rec) or gs.node.isEmpty(&rec)) continue;
        try result.append(allocator, nid);
    }

    return try result.toOwnedSlice(allocator);
}
```

**Benchmark expected to improve**: label scans (large posting lists) and any MATCH that starts from label candidates. citeturn30view4turn40view0  

---

### Patch sketch: make derived index snapshot writes conditional and/or periodic

**Belongs in**: `graph-storage` (`src/engine_persist.zig`, `src/engine_index.zig`) citeturn48view3turn41view0  
**Why it helps**: reduces checkpoint cost from O(total index size) on every checkpoint to “only when needed.”

```zig
// graph-storage: src/engine.zig / engine_persist.zig
pub const GraphEngine = struct {
    // ...
    derived_indexes_dirty: bool = false,
    // set this true on addLabel/removeLabel/addEdge/removeEdge/property updates that change indexes
};

// graph-storage: src/engine_persist.zig
pub fn checkpoint(engine: *GraphEngine) !void {
    if (!engine.persistence_dirty) return;

    // ...existing manifest counters...
    try engine.checkpointer.doCheckpoint();
    try saveFreeStore(engine);

    // Only persist derived index snapshots if they changed or periodically
    if (engine.derived_indexes_dirty or (engine.manifest.counter % 64 == 0)) {
        try engine_index.saveDerivedIndexes(engine);
        engine.derived_indexes_dirty = false;
    }

    try saveLabelDictionary(engine);
    engine.persistence_dirty = false;
}
```

**Benchmark expected to improve**: checkpoint latency and bytes written per checkpoint under small mutations. citeturn48view3turn41view0  

---

### Patch sketch: add `scanLabelLiveIter` in graph-storage

**Belongs in**: `graph-storage` (`src/engine.zig`, `src/label_index.zig` or new module) citeturn42view1turn40view0  
**Why it helps**: pushes liveness filtering and page batching down into storage where it can be done efficiently and safely.

```zig
// graph-storage: src/engine.zig
pub fn scanLabelLiveIter(self: *GraphEngine, label: LabelId) !LiveNodeIter {
    // LiveNodeIter holds:
    // - underlying LabelIndex.Iterator (sorted node ids)
    // - cached pinned node page frame
    // - current page_id
    // This yields only live nodes by checking NodeRec flags.
}

// Then expose via GraphStorage VTable as an alternate method,
// or reuse scanLabelIter but guarantee it yields only live nodes.
```

**Benchmark expected to improve**: the Geode adapter’s label scan path becomes a simple drain of iterator without pin/unpin checks. citeturn30view4turn42view1  

## Benchmark and profiling plan

(6) **Benchmark and profiling plan**

### Coverage benchmarks (end-to-end)

1. **Selective MATCH by label only**  
Dataset: 10M nodes, label distribution skewed (one label with 5M). Query: `MATCH (n:BigLabel) RETURN count(n)`.  
Metrics: p50/p95 latency; CPU cycles; buffer pool pins (if storage-backed); allocations/query.  
This targets `getNodesByLabels` inefficiency and label scan overhead. citeturn32view3turn30view4  

2. **Selective MATCH by label + property**  
Query: `MATCH (n:User {email: $x}) RETURN n`.  
Before fixes: likely falls back to label candidates + property checks; after: should use exact-match posting index (or adapter fast path). citeturn29view1turn45view0  

3. **MATCH + CALL**  
Construct a CALL that is invoked per match row, and ensure you test both a selective label path and a no-label fallback. This validates removal of brute-force scans in call paths. citeturn16view1  

4. **Comma-separated MATCH / cartesian-product stress**  
Query: `MATCH (a:BigLabel),(b:BigLabel) RETURN ... LIMIT 100`.  
Measure whether LIMIT is pushed early and whether candidate ordering chooses the smallest set first. (Current code builds matches per chain, then combines; worst-case product is massive.) citeturn20view0turn16view1  

5. **Path expansion on low-degree vs high-degree nodes**  
Two graphs: (A) average degree 2–3, (B) hub nodes degree 100k+.  
Queries: single-hop and variable-length.  
Metrics: p95 latency and peak RSS; allocations/op. Targets `executeSingleHopEdgeTraversal` and var-len path materialization. citeturn37view0turn36view4  

6. **Bulk ingest / CREATE with batching**  
Track: mutations/sec, checkpoints triggered, bytes written per checkpoint. Checkpoint amplification should drop after reducing snapshot rewrites. citeturn48view3turn41view0  

7. **Startup/open latency**  
Measure: `GraphEngine.open()` plus adapter overhead per graph. Specifically isolate the cost of `rebuildExactNodePropertyIndex`. citeturn29view1turn39view0  

8. **Checkpoint latency**  
Measure: wall time for checkpoint, bytes written (store files + derived index files), and time in `buffer_pool.flushAll()` vs time in `saveDerivedIndexes`. citeturn47view0turn41view0  

9. **Recovery latency**  
Use crash simulation at different WAL sizes and verify recovery time vs checkpointing policy. (In code, recovery loads manifest and WAL; open loads/rebuilds indexes if mismatch.) citeturn39view0turn41view0  

### Microbenchmarks to add

* **Env-allocation microbench**: call `executeSingleHopEdgeTraversal`-style inner loop with synthetic edges and measure allocations/op before/after stack-env refactor. citeturn37view0  
* **Label scan microbench**: iterate 1M node IDs and validate pin/unpin counts before/after caching the pinned page. citeturn30view4turn40view0  
* **Index snapshot write microbench**: measure time and bytes for `label_index.saveToFile` and `saveEdgeIndex` as a function of index size. citeturn40view2turn41view0  

### Instrumentation/counters to add (if running profilers is hard)

* **Allocations per query**: wrap allocator in Geode execution with counters; report per query type.  
* **Buffer pool pin/unpin counters**: graph-storage already has buffer pool; add counters for pins by file_id and eviction counts; correlate with label scans. citeturn46view0turn47view0  
* **Checkpoint byte accounting**: count bytes written to each derived index snapshot. citeturn41view0turn40view2  

## Quick wins vs structural redesign

(7) **Quick wins vs structural redesign**

### Immediate wins (1–2 days)

* **Stack-env refactor for single-hop traversal** (Geode): cut allocator churn in the hottest loops. citeturn37view0  
* **Posting-list “smallest label first” in `getNodesByLabels`** (Geode): simple reorder + intersection avoids label-order worst-cases. citeturn32view3turn31view1  
* **Pinned-page caching in adapter label scans** (Geode): removes the most obvious pin/unpin abuse without touching storage. citeturn30view4turn40view0  

### Near-term refactors (1–2 weeks)

* **Streaming variable-length paths** (Geode): restructure traversal to yield incrementally and honor LIMIT early. citeturn36view4  
* **Reduce checkpoint amplification** (graph-storage + Geode policy): make derived snapshots conditional/periodic and stop coupling “mutation completion” to “rewrite full indexes.” citeturn48view3turn41view0  
* **Fix snapshot memory ownership** so MATCH can run on a read view without global lock (Geode). The current skip is justified by a UAF note, but it’s a major throughput limiter. citeturn37view3turn35view0  

### Structural redesigns (multi-week)

* **Move MATCH candidate formation and traversal onto graph-storage iterators directly** and stop relying on the hash-map-based `GraphStore` for reads. (Right now, Geode’s execution loops are dominated by hash lookups and heap-owned object graphs.) citeturn24view1turn37view0  
* **Implement true secondary indexes in graph-storage** (label+property postings; potentially adjacency-type postings) so Geode can do predicate pushdown rather than “filter after expand/scan.” citeturn45view0turn40view0  
* **Introduce “view-based” property decoding** (graph-storage) to avoid string dupes during scans, with safe lifetimes (pinned frames / copy-on-demand). citeturn44view0turn43view2  

## Do not do this

(8) **Seductive but low-value ideas to avoid**

* **Do not micro-optimize hash functions or tweak small branch conditions** in the MATCH loops while `executeSingleHopEdgeTraversal` still allocates per candidate. That’s polishing a bottleneck you haven’t removed. citeturn37view0  
* **Do not add more adapter-side caches that mirror full-graph state** unless they are persisted and bounded. The adapter already rebuilds a full exact property index on open; adding more of these increases startup cost and memory footprint. citeturn29view1turn39view0  
* **Do not “fix performance” by disabling correctness safeguards** (e.g., skipping deleted-node checks) without addressing the root cause (stale label postings). The current system requires liveness filtering because deletes don’t update the label index. citeturn42view0turn30view4  
* **Do not rely on more frequent checkpoints as a durability crutch**. In `graph-storage`, WAL commits are the durability boundary; checkpoint should be amortized and working-set-aware, not used as “rewrite indices every time.” citeturn47view0turn48view3  
* **Do not implement a “property index” in Geode’s in-memory `GraphStore` first** if the long-term direction is storage-first. That risks duplicating what should live in `graph-storage` and makes eventual migration harder. The current docs/code mismatch around property indexing is already a warning sign. citeturn38view0turn45view0
