# A4b Change-Map — FTS Node Write-Maintenance Hook

**Task:** Keep fulltext indexes current as nodes are created / updated / deleted
via GQL. Today only `CREATE INDEX ... USING fulltext` backfills the index;
ordinary `CREATE` / `SET` / `DELETE` (and the bulk `MERGE` fast path) leave the
FTS engine stale. A4b adds the maintenance hook.

**Branch:** `feat/storage-lib-migration`
**Investigated (read-only):** 2026-05-31

### Verification status legend

All facts below were read directly from source and carry exact `file:line`.
A few residual line numbers in very large files (`graph_store.zig` ~9066 lines,
`graph_storage_adapter.zig` ~6061 lines) may drift by a few lines due to banner
comments — anchor on the verbatim signatures, not the exact integer. Where a
fact was confirmed by grep but the surrounding body was not fully re-read, it is
noted inline; nothing material is left unverified.

---

## 0. Executive summary

* FTS DDL lives in `src/execution/fts_index_ops.zig` — `createFulltextIndex`
  (line 49) and `dropFulltextIndex` (line 160). It is dispatched from the
  CREATE/DROP INDEX handler in **`src/execution.zig`** (NOT
  `statement_handlers.zig`, which only handles SHOW/FOR/VALUES/EXPLAIN/PROFILE).
  Verified: `grep -rln "createFulltextIndex" src/` returns exactly
  `src/execution.zig` and `src/execution/fts_index_ops.zig`. Grep
  `grep -n "createFulltextIndex\|dropFulltextIndex" src/execution.zig` for the
  exact dispatch lines.
* There is **NO** structure that answers "which fulltext indexes cover label L?".
  `createFulltextIndex` receives `(index_name, label, properties[])` but records
  no association — only the engine keyed by `index_name` inside the per-graph
  `FtsStorageAdapter`. `IndexManager.fulltext_indexes`
  (`src/index/index_manager.zig:67`) is keyed by **name** and stores no
  label/properties; SHOW INDEXES surfaces fulltext rows with EMPTY
  label/properties (`src/execution/meta_dispatch.zig:288-324`).
* **Recommendation:** add a per-`ManagedGraph`
  `fts_label_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(FtsIndexSpec))`
  (label → covering fulltext indexes), populated in `createFulltextIndex` and
  cleared in `dropFulltextIndex`, so the write hook does an O(1) label lookup and
  cheap-exits (the dominant case) when the label has no FTS index.
* CREATE node seam: `executeCreateQuery` (`crud_operations.zig:1151`) — node
  committed via `store.createNodeWithGraph(...)` (lines 1202/1210), props via
  `property_mutation.setNodePropertyFromValue(...)` (line 1225). Also
  `executeCreateForBatch`/`...WithTracking` (lines 628/790) for MATCH…CREATE, and
  `executeBatchCreateHomogeneous` (line 1041) for the GAP-0815 fast path. The
  property-write chokepoint shared by ALL paths is
  `property_mutation.setNodePropertyFromValue`.
* SET seam: the single property-write chokepoint is
  `property_mutation.setNodePropertyFromValue` (`property_mutation.zig:266`),
  called from **23 sites** — CREATE...SET, MATCH...SET (`match_operations.zig:5376,
  5381, 7106, 8134`), MERGE ON CREATE/MATCH, and the SET path in
  `crud_operations.zig` (lines 691, 864, 1225, 1281, 1297, 1452, 1794, 1840,
  1875, 2014, 2064, 2103, 2259, 2299, 2312). Whole-node replace is
  `property_mutation.replaceNodeProperties` (`crud_operations.zig:1498`); label
  add/remove is `store.addNodeLabel` (`crud_operations.zig:1458`) /
  `store.removeNodeLabel` (`crud_operations.zig:1518`, store fn at
  `graph_store.zig:3503`).
* DELETE seam: `executeDelete` (`crud_operations.zig:2545`). The MATCH...DELETE
  node loop reads `read_store.nodes.getPtr(node_id)` (line 2662) and the delete
  loop is at line 2717; the store delete is `store.deleteNode(node_id)`
  (`graph_store.zig:6397`). The hook MUST run BEFORE the delete, while
  `node.labels` are still readable (top of the delete loop, line 2717).
* **Thread-safety verdict (make-or-break):** the single-node executor paths
  (`executeCreate*`, MATCH…SET, `executeDelete`) run on the connection/executor
  thread — the SAME thread `CREATE INDEX` (and therefore the fts Engine) was
  created on — so hooking FTS maintenance inline there is safe against the
  fts-storage owning-thread assert. **BUT the bulk MERGE fast path
  (`adapter.bulkMergeNode`) is invoked from MULTIPLE worker threads** — proven by
  `tests/bulk_ingest/test_simple_merge_fastpath.zig:321-379`, where 16
  `std.Thread.spawn` workers (line 343) call `adapter.bulkMergeNode` (line 298),
  with the test comment (lines 286-290) stating this "mirrors what the QUIC
  handler does for the MERGE fast path". A per-row FTS call from inside/after
  `bulkMergeNode` would run on a worker thread and trip the owning-thread assert.
  A4b must therefore **only hook inline on the executor thread**, and for the bulk
  path either skip per-row maintenance and do ONE post-bulk reindex on the
  connection thread, or route maintenance through the connection thread.

---

## 1. `fts_index_ops.zig` — current shape (read in full, 187 lines)

### 1.1 Entry points (verbatim)

```zig
// src/execution/fts_index_ops.zig:49
pub fn createFulltextIndex(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    index_name: []const u8,
    label: []const u8,
    properties: []const []const u8,
) !void

// src/execution/fts_index_ops.zig:160
pub fn dropFulltextIndex(
    graph_name: []const u8,
    index_name: []const u8,
    if_exists: bool,
) !void

pub const Error = error{ FulltextIndexExists, FulltextUnavailable }; // line 28
```

Imports (lines 21-24): `graph_store = @import("../graph_store.zig")`,
`tokenizer = @import("../index/fts_tokenizer.zig")`,
`adapter_mod = @import("../storage/fts_storage_adapter.zig")`.

### 1.2 ManagedGraph + adapter resolution (the pattern A4b reuses)

`createFulltextIndex` (lines 56-62):

```zig
const adapter = graph_store.getGlobalAdapter() orelse return Error.FulltextUnavailable;
const mg = adapter.lookupManagedGraph(graph_name) catch return Error.FulltextUnavailable;
const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;
```

* `graph_store.getGlobalAdapter()` → `?*StorageAdapter`.
* `StorageAdapter.lookupManagedGraph(name) !*ManagedGraph` —
  `graph_storage_adapter.zig:4548` (brief `graph_handles_mutex`, no data rwlock).
* `mg.fts_adapter : ?*FtsStorageAdapter` — `graph_storage_adapter.zig:659`
  (null until first CREATE INDEX).
* `adapter.allocator` is the adapter's owning allocator (used at
  `fts_index_ops.zig:179` as `adapter.allocator`).

Then: `fa.createIndex(index_name)` (line 65), catching
`adapter_mod.Error.IndexExists` → idempotent return for IF NOT EXISTS (lines
65-72); `errdefer fa.dropIndex(index_name) catch {};` (line 73);
`backfillExistingNodes(...)` (line 75); `fa.flush(index_name)` (line 79, warn on
error).

`dropFulltextIndex` (lines 160-187): same resolve chain (165-176), with
`if_exists` returning `adapter_mod.Error.IndexNotFound` when absent; then
`mg.dropFulltextFacade(adapter.allocator, index_name);` (line 179) and
`fa.dropIndex(index_name) catch |err| switch ...` (line 181).

### 1.3 Backfill — the EXACT tokenize+indexNode contract A4b reuses

`backfillExistingNodes` (lines 85-151):

* `const store = graph_store.getGlobalStore(graph_store.global_allocator());` (line 93).
* `const node_ids = store.getNodesByLabel(graph_name, label) orelse return;` (line 96) — borrowed `[]const u64`.
* Per node, accumulate ONE document into
  `var doc_terms: std.ArrayListUnmanaged(tokenizer.TermPosting) = .empty;` (line 109).
* Per property (lines 118-143):
  * `const pv = store.getNodeProperty(node_id, prop) orelse continue;` (line 119).
  * `const text = switch (pv) { .String => |s| s, else => continue };` (lines 120-123) — only `.String` is indexable.
  * `if (text.len == 0) continue;` (line 124).
  * `const postings = tokenizer.tokenize(allocator, text, prop) catch ...;` (line 128) — property name passed as the `field` tag.
  * `if (postings.len == 0) continue;` (line 135) — all-stopword → static empty slice.
  * **Ownership move (copy exactly):** `doc_terms.appendSlice(allocator, postings)` (line 138; on error `tokenizer.freeTermPostings(allocator, postings)` then return — lines 139-141), then `allocator.free(postings);` (line 142, free slice header only — elements now owned by `doc_terms`).
  * `defer` (lines 110-116): free each `doc_terms.items[i].term` and `.positions` individually, then `doc_terms.deinit(allocator)`. **MUST NOT** call `freeTermPostings(doc_terms.items)` (double-free vs `deinit`).
* `if (doc_terms.items.len == 0) continue;` (line 145).
* `fa.indexNode(index_name, node_id, doc_terms.items) catch ...;` (line 147) — ONE call per node; the engine is APPEND-ONLY (a second `indexNode` for the same doc_id duplicates postings).

### 1.4 Name ↔ (label, properties) association

**None recorded.** The only persisted state linking the index is the engine keyed
by `index_name` in `FtsStorageAdapter.indexes`. There is no map from `label` (or
`property`) back to the covering index name(s). **A4b must add it (see §2).**

---

## 2. The "which FTS indexes cover label L?" lookup structure (NEW — A4b adds it)

### 2.1 What exists today

| Structure | Where | Keyed by | Holds label/props? |
|---|---|---|---|
| `IndexManager.fulltext_indexes : std.StringHashMap(fulltext.FullTextIndex)` | `index_manager.zig:67` | index **name** | **No** |
| `FtsStorageAdapter.indexes` (named engines) | `fts_storage_adapter.zig` | index **name** | No |
| `ManagedGraph.fts_facades : StringHashMapUnmanaged(*fulltext.FullTextIndex)` | `graph_storage_adapter.zig:674` | index **name** | No (search facades) |

`IndexManager.createFullTextIndex` (`index_manager.zig:497`) now returns
`error.FullTextIndexRequiresAdapter` (lines 508-516) — post-migration the live
FTS path is the per-graph adapter, not the IndexManager. `IndexType.fulltext`
exists (`index_manager.zig:87`). SHOW INDEXES (`meta_dispatch.zig:283`
`executeDbIndexes`) merges catalog indexes with FTS index **names** pulled from
`mgr.fulltext_indexes.keyIterator()` (lines 295-298) and emits type `"FULLTEXT"`
with EMPTY label/properties (the #844 comment at lines 288-291 documents this
gap).

**Conclusion: NO per-graph or label-keyed structure exists. A4b must add one.**

> **Note:** SHOW INDEXES (`meta_dispatch.zig:executeDbIndexes`) reads FTS index
> NAMES from `mgr.fulltext_indexes.keyIterator()` (line 296). Confirm whether the
> CREATE INDEX dispatch in `src/execution.zig` still registers the name into
> `IndexManager.fulltext_indexes` post-migration (`grep -n "fulltext_indexes.put\|getGlobalIndexManager" src/execution.zig`).
> Either way, A4b's new per-graph `fts_label_index` is ADDITIONAL (label→spec for
> the write hook), not a replacement for the name registry.

### 2.2 Recommended structure (per-ManagedGraph, label-keyed)

Add to `ManagedGraph` (`graph_storage_adapter.zig`, next to `fts_facades` at
line 674):

```zig
/// label → fulltext indexes that cover it. Populated on CREATE INDEX … USING
/// fulltext, cleared on DROP INDEX. Empty/absent ⇒ FTS write hook cheap-exits.
fts_label_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(FtsIndexSpec)) = .empty,

pub const FtsIndexSpec = struct {
    name: []const u8,               // index name (owned, dupe'd with adapter.allocator)
    properties: []const []const u8, // indexed props (owned, dupe'd)
};
```

* **Ownership:** dupe the label key and each `FtsIndexSpec.name`/`.properties`
  entry with the adapter allocator; free them in `ManagedGraph.deinit` (the deinit
  already tears down `fts_facades` at ~838-843 then `fts_adapter` at ~845-847 —
  add the `fts_label_index` teardown BEFORE `fts_adapter` is freed).
* **Helper methods on `ManagedGraph`** (place beside `dropFulltextFacade`,
  `graph_storage_adapter.zig:817`):
  * `addFtsLabelIndex(alloc, label, name, properties) !void` — append a spec to
    the label's list (create the list if absent).
  * `removeFtsLabelIndex(alloc, name) void` — scan all lists, drop+free specs
    whose `.name == name`; drop empty label entries.
  * `coveringFtsIndexes(label) ?[]const FtsIndexSpec` — borrowed list or null.
    The write hook calls this.

Why per-`ManagedGraph` (not `IndexManager`): the FTS engine, facades, and this
map are all per-graph; co-locating keeps the deinit story and the multi-tenant
graph boundary clean, mirroring A4a's placement of `fts_adapter`/`fts_facades`.

### 2.3 Where to populate / clear / read

* **Populate (CREATE):** in `fts_index_ops.createFulltextIndex`, after backfill
  (~line 75, under the existing `errdefer fa.dropIndex` at line 73), call
  `try mg.addFtsLabelIndex(adapter.allocator, label, index_name, properties);`.
  **Skip on the IF-NOT-EXISTS idempotent return (lines 65-72)** — the spec is
  already present.
* **Clear (DROP):** in `fts_index_ops.dropFulltextIndex`, beside
  `mg.dropFulltextFacade(...)` (line 179):
  `mg.removeFtsLabelIndex(adapter.allocator, index_name);`.
* **Read (write hook):** the new `maintainFulltextOnWrite` (§8) calls
  `mg.coveringFtsIndexes(label)` per label; `null` ⇒ return immediately (the
  dominant path — most graphs have no FTS index, so the hook is ~free).

(Bonus: this map lets a future change fill in real label/properties for fulltext
rows in `meta_dispatch.zig:executeDbIndexes` — out of A4b scope.)

---

## 3. Node CREATE seam

### 3.1 Functions that commit a new node (verbatim signatures)

```zig
// src/execution/crud_operations.zig:1151
pub fn executeCreateQuery( ... ) ...      // CREATE … (RETURN/SET/WITH) path

// src/execution/crud_operations.zig:1691
pub fn executeCreate(allocator: std.mem.Allocator, c: ast.CreateStatement,
                     current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult

// src/execution/crud_operations.zig:1041
fn executeBatchCreateHomogeneous( ... )   // GAP-0815 homogeneous batch fast path

// src/execution/crud_operations.zig:628 / 790
pub fn executeCreateForBatch(...) !i64
pub fn executeCreateForBatchWithTracking(...) !CreateBatchResult   // MATCH … CREATE
```

`executeCreate` (1691) first tries `homogeneousCreateStatementEligible(c)` (1696)
→ `executeBatchCreateHomogeneous` (1697); otherwise falls through to the serial
path. The serial single-node commit happens in `executeCreateQuery`:

* `const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);` (lines 1202, 1210).
* Props: `try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);` (line 1225).
* `ensureAutoIndexes(allocator, node_pattern.labels);` (line 1230) — the existing
  post-create maintenance hook A4b mirrors.

(MATCH…CREATE batch path: `store.createNodeWithGraph` at 663/676/713/721/736/744,
props at 691, `ensureAutoIndexes` at 696 in `executeCreateForBatch`.)

### 3.2 Insertion point

In `executeCreateQuery`, immediately AFTER the property loop at line 1225 and the
`ensureAutoIndexes` call at line 1230, while `node_id`, `node_pattern.labels`, and
the just-written props are in scope. At that point:

* node id → `node_id : u64` (bound at 1196-1211).
* labels → `node_pattern.labels : []const []const u8`.
* property name+value → iterate `node_pattern.props` (re-read string values from
  the store via `store.getNodeProperty(node_id, prop)` to match backfill exactly,
  rather than re-evaluating the AST expression).

> **Note:** because A4b reads indexed props back from the store, the single best
> place is a one-line call to the §8 helper, which itself reads
> `store.getNodeProperty` for each `spec.properties` entry. This keeps the hook
> independent of the CREATE path's expression-eval details and lets the SAME
> helper serve CREATE / SET. Mirror `ensureAutoIndexes`'s placement: one call per
> created node, AFTER all props are committed.

### 3.3 ManagedGraph / adapter access from the seam

`ExecutionContext` is defined in `src/execution.zig` (not a separate
`execution/execution.zig` — the parent module IS `src/execution.zig`; grep
`grep -n "pub const ExecutionContext = struct" src/execution.zig`). Fields
referenced by the CREATE/DELETE handlers: `context.catalog`,
`context.query_param_names`, `context.query_param_values`,
`context.transaction_state` (`executeCreate` 1700-1739), `context.tenant_id`,
`context.session_state`, `context.principal` (delete/show paths). There is no
`*ManagedGraph` on the context. Resolve `mg` the same way fts_index_ops does:
`graph_store.getGlobalAdapter()` (`graph_store.zig:6737`) →
`.lookupManagedGraph(graph_name)` (`graph_storage_adapter.zig:4548`) →
`mg.fts_adapter`. Tolerate `GraphNotFound`/null = skip (FTS-less graph). The §8
helper should take the resolved `*ManagedGraph` (or graph name) so each seam
resolves once.

`graph_name` at the seam = `target_graph` (the `current_graph orelse "default"`
already computed in these functions).

---

## 4. Node UPDATE / SET seam

### 4.1 The property-write chokepoint (verbatim)

```zig
// src/execution/property_mutation.zig:266
pub fn setNodePropertyFromValue(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    labels: []const []const u8,
    node_id: u64,
    key: []const u8,
    value: Value,
) !void
```

Argument order confirmed identical across all 23 call sites (e.g.
`crud_operations.zig:691, 1225, 1281, 1297, 1452`;
`match_operations.zig:5376, 5381, 7106, 8134`). The function passes `labels` so
it can drive advanced-index rebuilds (comment `property_mutation.zig:160`) — the
SAME `(labels, node_id, key)` A4b needs. `removeNodeProperty` store-side is
`graph_store.zig:3370` (`removeNodeProperty(node_id, key)`); the
`property_mutation.removeNodeProperty(store, node_ptr, key)` wrapper is used at
`crud_operations.zig:1511`.

Every SET-property write — in CREATE…SET, MATCH…SET, and MERGE ON CREATE/MATCH —
flows through `property_mutation.setNodePropertyFromValue`. This is the single
natural SET seam (hook its callers on the executor thread; see §6 for why NOT
inside the function unconditionally).

Related whole-node / label mutators (also SET/REMOVE seams):

* `property_mutation.replaceNodeProperties(allocator, store, node, props_value)` — `crud_operations.zig:1498` (SET n = {map}).
* `property_mutation.removeNodeProperty(store, node_ptr, prop.property)` — `crud_operations.zig:1511` (REMOVE n.prop).
* `store.addNodeLabel(node_id, label)` — `crud_operations.zig:1458` (SET n:Label) — changes the label set ⇒ may change covering indexes.
* `store.removeNodeLabel(node_id, label)` — `crud_operations.zig:1518` (REMOVE n:Label).

### 4.2 Standalone MATCH…SET handler

The MATCH…SET writes flow through `match_operations.zig` at lines 5376, 5381
(left/right node of an edge pattern), 7106, and 8134 — each a
`property_mutation.setNodePropertyFromValue(allocator, store, node.labels,
node.id, prop.target.property, value)`. These run on the executor thread (no
`Thread.spawn` in `match_operations.zig` write paths). Hook AFTER each write
(or, cleaner, factor a one-line helper call at each `setNodePropertyFromValue`
caller) with `op = .update`, reading the node's current labels from
`store.nodes.getPtr(node_id).?.labels`.

### 4.3 UPDATE = delete-then-index (mandatory)

The fts engine `indexDocument` is APPEND-ONLY: re-indexing without deleting
duplicates postings. So the SET hook must, per covering index:
`fa.deleteNode(spec.name, node_id)` THEN `fa.indexNode(spec.name, node_id, terms)`
rebuilt from the node's CURRENT indexed props. `fa.deleteNode` tombstones and is a
safe no-op if the node was never indexed (`fts_storage_adapter.zig:272-277`), so
the first-ever SET still works. Because the document is ONE concatenated posting
set across ALL of the index's `properties` (per §1.3), the rebuild reads ALL of
`spec.properties` from the store, not just the one changed prop.

To get the data at the seam: `node_id` is in scope; **`GraphStore` has NO public
`getNodeLabels`** (grep confirmed — only `addNodeLabel`/`removeNodeLabel`/
`removeNodeLabelNoSave` exist), so read labels via
`store.nodes.getPtr(node_id).?.labels` (the canonical pattern used across crud /
match / delete, e.g. `crud_operations.zig:1480, 2662`). Current string props via
`store.getNodeProperty(node_id, prop)` (`graph_store.zig:3309`) for each
`spec.properties`.

---

## 5. Node DELETE seam

### 5.1 The function (verbatim)

```zig
// src/execution/crud_operations.zig:2545
pub fn executeDelete(allocator: std.mem.Allocator, d: ast.DeleteStatement,
                     current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult
```

**Body (read & verified):** the MATCH…DELETE path collects candidate ids
(`collectCandidateNodeIds`, line 2651) into `nodes_to_delete` (line 2645), checks
edge constraints for non-DETACH (lines 2706-2714), then the delete loop at line
2717 (`for (nodes_to_delete.items) |node_id|`) — DETACH first deletes incident
edges (lines 2718-...), then the node is removed via `store.deleteNode(node_id)`
(`graph_store.zig:6397`). Each `node_id` is known throughout the loop and the
node still exists in `read_store.nodes` until the delete call.

### 5.2 Insertion point — MUST be BEFORE the store delete

Read the node's labels and call the §8 helper with `op = .delete` at the TOP of
the delete loop (line 2717, before any edge/node removal), because the
covering-index lookup is keyed by label and the node's labels are gone after
`store.deleteNode`. For DELETE the helper needs ONLY labels (no tokenize, no
property read): per covering index it calls `fa.deleteNode(spec.name, node_id)`.
Get labels via `read_store.nodes.getPtr(node_id).?.labels` (the node still
exists at that point).

---

## 6. Thread-safety reality check (CRITICAL — the make-or-break constraint)

### 6.1 The fts adapter write surface (verified)

All writes serialize per-engine under `ie.write_mu.lockUncancelable(self.io)`:

* `indexNode` (`fts_storage_adapter.zig:247-257`) → `ie.engine.indexDocument(node_id, terms)`.
* `indexNodeBatch` (260-269) → `ie.engine.indexDocumentBatch(docs)`.
* `deleteNode` (272-277) → `ie.engine.deleteDocument(node_id)`.
* `flush` (280-285) → `ie.engine.flush()`.
* `search` (294-325) → NO `write_mu` (concurrent reads allowed); drains+deinits
  the iterator before returning.
* `createIndex` (141), `openIndex` (150), `dropIndex` (213), `getIndex` (235,
  brief registry lock).

### 6.2 The owning-thread assert

The fts-storage `Engine` is constructed at `fts.Engine.init(self.io,
self.allocator, child)` — **`fts_storage_adapter.zig:180`**, inside
`openOrCreate` (the shared body of `createIndex` line 141 and `openIndex` line
150). The owning-thread is captured by that `Engine.init` (the assert lives in
the external `fts_storage_lib` Engine, per the task premise — the adapter itself
imports ONLY `std` + `fts_storage_lib`, see the module banner lines 8-13, and
adds only the per-engine `write_mu` at line 75 / 254 / 266 / 274 / 282). The
`write_mu` serializes writers but does NOT relax the engine's owning-thread
requirement.

So: the engine for an index is "owned" by whichever thread first ran
`CREATE INDEX`/`openIndex` for it (the connection/executor thread), and only that
thread may write (`indexDocument`/`indexDocumentBatch`/`deleteDocument`/`flush`).

### 6.3 Which thread runs what (evidence)

| Path | Thread | Evidence |
|---|---|---|
| `CREATE INDEX … USING fulltext` | connection/executor | dispatched from `src/execution.zig` on the statement-executing connection thread → `fts_index_ops.createFulltextIndex` → `fa.createIndex` → `Engine.init` (`fts_storage_adapter.zig:180`, captures owner) |
| `executeCreate*` (node CREATE) | connection/executor | same executor entry; no `Thread.spawn` in `crud_operations.zig` (grep returned zero) |
| MATCH…SET | connection/executor | same executor entry |
| `executeDelete` | connection/executor | same executor entry |
| **bulk MERGE fast path (`adapter.bulkMergeNode`)** | **WORKER threads** | `tests/bulk_ingest/test_simple_merge_fastpath.zig`: 16 × `std.Thread.spawn(.{}, concurrentMergeWorker, ...)` (line 343); each worker calls `ctx.adapter.bulkMergeNode("default","U","id",...)` (line 298) under `graph_store.acquireGraphWriteLockCancelable("default", deadline)` (line 292). Comment 286-290: *"this mirrors what the QUIC handler does for the MERGE fast path (Phase 2 of the two-phase split)."* |

`adapter.bulkMergeNode` is at **`graph_storage_adapter.zig:2456`** (siblings:
`bulkMergeNodeWithReservedId` 1992, `...MultiProp` 2096). Signature (from verified
test usage): `bulkMergeNode(graph_name, label, merge_key_prop,
merge_key_value: PropertyValue, on_create_props: []const {key, value}, ?,
apply_on_match: bool) !u64`. The production caller is the bulk-ingest fast path in
`src/server/quic_connection_handler.zig`, where `ensureAutoIndexes` is already
called post-bulk on the connection thread (`crud_operations.zig:420-424` comment:
*"the bulk fast paths in `src/server/quic_connection_handler.zig` … can call it
directly after a successful bulk insert"*) — that is the exact template for a
post-bulk FTS reindex on the connection thread.

### 6.4 Verdict

* Single-node executor paths (CREATE / SET / DELETE) and the EXECUTOR MERGE path
  run on the connection/executor thread = the engine's owning thread → **safe to
  hook FTS maintenance inline.**
* The **bulk MERGE fast path (`bulkMergeNode`) runs on worker threads** → a per-row
  FTS write from there WOULD trip the engine owning-thread assert.

### 6.5 How A4b stays safe (guard, not luck)

1. **Hook only on the executor thread** — the §3/§4/§5 single-node seams.
2. **Do NOT add the FTS hook inside `bulkMergeNode`** (it runs on workers).
   Instead, after the bulk ingest completes, do ONE post-bulk FTS reindex on the
   connection thread (same pattern as the post-bulk `ensureAutoIndexes` call in
   the QUIC handler), or route per-row maintenance back to the connection thread.
   Cheap-exit still applies (label map empty ⇒ skip).
3. **Defensive debug assert (recommended):** at the top of
   `maintainFulltextOnWrite`, `std.debug.assert` that the current thread matches
   the engine owner (capture/compare via the adapter), so any future
   worker-thread caller fails loudly in debug instead of deep in the engine.
4. **If a future path truly creates nodes off-thread,** skip per-row maintenance
   and do a single post-op reindex on the connection thread — do NOT change the
   engine's owning-thread model.

---

## 7. Allocator + tokenize ownership in the hook

* **tokenize:** `pub fn tokenize(allocator: std.mem.Allocator, text: []const u8,
  field: ?[]const u8) ![]fts.TermPosting` — `fts_tokenizer.zig:67`. Pass the
  property name as `field` (matches backfill line 128). Empty/all-stopword input
  → static empty slice (`&[_]fts.TermPosting{}`, line 120); `len == 0` ⇒ skip.
* **free:** `pub fn freeTermPostings(allocator: std.mem.Allocator, postings:
  []fts.TermPosting) void` — `fts_tokenizer.zig:160` (frees each `.term`,
  `.positions`, non-null `.field`, and the outer slice).
* **`indexNode` copies** the `terms` into the engine (terms borrowed), so the
  tokenize buffers do NOT need to outlive the `indexNode` call.
* **Recommended allocator:** the handler's `allocator` parameter (every
  `executeCreate*`/`executeDelete`/MATCH…SET handler takes `allocator:
  std.mem.Allocator` as its first arg — confirmed in all signatures above). The
  CREATE/SET paths already pass this same `allocator` into
  `setNodePropertyFromValue` and `eval.evalExpr`. There is no per-statement arena
  field on `ExecutionContext`; if a future arena is added, prefer it. With the
  handler `allocator`, mirror
  backfill's `ctx.allocator` + explicit move/free discipline EXACTLY (§1.3): move
  posting elements into the accumulator, `allocator.free(postings)` for the slice
  header, per-element `term`/`positions` free in `defer` — never
  `freeTermPostings(accumulator.items)` (double-free vs `deinit`).
* DELETE does NO tokenize (just `fa.deleteNode`).

---

## 8. Recommended A4b sub-steps (ordered, each independently testable)

### (i) Add the per-ManagedGraph label→index map + populate/clear

* **`src/storage/graph_storage_adapter.zig`:**
  * Add `FtsIndexSpec` + `fts_label_index` to `ManagedGraph` (next to
    `fts_facades`, line 674).
  * Add `addFtsLabelIndex` / `removeFtsLabelIndex` / `coveringFtsIndexes` methods
    (beside `dropFulltextFacade`, line 817).
  * Free the map + dup'd keys/specs in `ManagedGraph.deinit` (before the
    `fts_adapter` teardown at ~845).
* **`src/execution/fts_index_ops.zig`:**
  * `createFulltextIndex` after backfill (~line 75, under `errdefer` line 73):
    `try mg.addFtsLabelIndex(adapter.allocator, label, index_name, properties);`.
    Skip on the IF-NOT-EXISTS early return (lines 65-72).
  * `dropFulltextIndex` beside `dropFulltextFacade` (line 179):
    `mg.removeFtsLabelIndex(adapter.allocator, index_name);`.
* **Test:** CREATE two fulltext indexes on label `Doc`; assert
  `coveringFtsIndexes("Doc")` returns both; DROP one → returns one; DROP both →
  null.

### (ii) Add `maintainFulltextOnWrite` helper in `fts_index_ops.zig`

```zig
pub const FtsWriteOp = enum { create, update, delete };

/// Single entry point for node write-maintenance. Cheap-exits when no FTS
/// index covers any of `labels`. MUST be called on the executor (connection)
/// thread (A4b §6).
pub fn maintainFulltextOnWrite(
    scratch: std.mem.Allocator,                 // arena or ctx allocator
    mg: *adapter_mod /* ManagedGraph */ ,       // resolved by caller
    store: *graph_store.GraphStore,
    node_id: u64,
    labels: []const []const u8,
    op: FtsWriteOp,
) !void
```

Body:

1. `const fa = mg.fts_adapter orelse return;` (no FTS on graph → free exit).
2. For each `label`: `const specs = mg.coveringFtsIndexes(label) orelse continue;`.
3. For each `spec`, de-dup by `spec.name` across labels (a small arena set) so
   `.create` never double-appends:
   * `.delete`: `fa.deleteNode(spec.name, node_id) catch |e| log.warn(...);`.
   * `.update`: `fa.deleteNode(spec.name, node_id) catch ...;` THEN re-index.
   * `.create` (and the re-index tail of `.update`): rebuild ONE document from
     `spec.properties` EXACTLY as backfill §1.3 (`store.getNodeProperty`,
     `.String` only, `tokenize(scratch, text, prop)`, concat, single
     `fa.indexNode(spec.name, node_id, doc_terms.items)`).
   * Optionally `fa.flush(spec.name)` (or batch flush at end of statement).

* Make every fts call non-fatal (log + continue) so an FTS hiccup never aborts a
  committed write — mirror backfill's `log.warn` posture (lines 80, 129, 148).
* **Test:** drive the helper for create/update/delete against a store with a
  fulltext index; assert search results.

### (iii) Wire the helper into the seams (executor-thread only)

* **CREATE** — `executeCreateQuery` (`crud_operations.zig:1151`), after the prop
  loop (line 1225) / `ensureAutoIndexes` (1230): resolve `mg` via
  `getGlobalAdapter().lookupManagedGraph(target_graph)` (tolerate null/GraphNotFound
  = skip) and call the helper with `op = .create`. Repeat the same one-liner in
  the MATCH…CREATE batch paths (`executeCreateForBatch` after line 696) and in
  `executeBatchCreateHomogeneous` (single post-create call per node).
* **SET** — at each executor-thread caller of
  `property_mutation.setNodePropertyFromValue` / `replaceNodeProperties` /
  `store.addNodeLabel` (CREATE...SET in `executeCreateQuery` around 1498/1458, and
  the MATCH...SET writes in `match_operations.zig:5376, 5381, 7106, 8134`): read
  current labels via `store.nodes.getPtr(node_id).?.labels`, call with
  `op = .update`. For SET n:Label, call AFTER `addNodeLabel` so a newly-matching
  label triggers (re)index.
* **DELETE** — `executeDelete` (`crud_operations.zig:2545`), BEFORE the store
  delete: read labels via `store.nodes.getPtr(node_id).?.labels`, call with
  `op = .delete`.
* **Bulk MERGE** — do NOT hook inside `bulkMergeNode`. Add a post-bulk reindex on
  the connection thread (where `ensureAutoIndexes` is already called for the bulk
  path) iterating the just-ingested label's nodes through the helper, or skip if
  the label has no covering FTS index.
* **Test:** per-seam — CREATE node then search finds; SET then search reflects;
  DELETE then search drops.

### (iv) End-to-end test (`tests/test_fts_e2e.zig` companion or new)

1. `CREATE INDEX docs_ft FOR (n:Doc) ON (n.body) USING fulltext` on an empty graph.
2. `CREATE (:Doc {body:'hello world'})` AFTER the index → `fulltext_search('docs_ft','hello')` returns it (proves CREATE hook).
3. `SET n.body = 'goodbye moon'` → search `'hello'` empty, `'goodbye'` returns it (proves delete-then-index).
4. `DELETE n` → search `'goodbye'` empty (proves DELETE hook).
5. Control: a node on a label with NO fulltext index does NOT touch the engine (cheap-exit).
6. Regression: existing CREATE INDEX backfill test still passes (no double-index of pre-existing nodes).

---

## 9. File reference index

| Concern | File:line | Symbol |
|---|---|---|
| FTS DDL create | `src/execution/fts_index_ops.zig:49` | `createFulltextIndex` |
| FTS DDL drop | `src/execution/fts_index_ops.zig:160` | `dropFulltextIndex` |
| Backfill tokenize+indexNode pattern | `src/execution/fts_index_ops.zig:85-151` | `backfillExistingNodes` |
| FTS Error enum | `src/execution/fts_index_ops.zig:28` | `Error{FulltextIndexExists, FulltextUnavailable}` |
| CREATE/DROP INDEX dispatch | `src/execution.zig` (grep `createFulltextIndex`) | fulltext branch → `fts_index_ops.*` |
| ManagedGraph (add map here) | `src/storage/graph_storage_adapter.zig:639` | `ManagedGraph` |
| `fts_adapter` field | `src/storage/graph_storage_adapter.zig:659` | — |
| `fts_facades` field | `src/storage/graph_storage_adapter.zig:674` | — |
| `dropFulltextFacade` (sibling helper) | `src/storage/graph_storage_adapter.zig:817` | place add/remove/covering nearby |
| ManagedGraph deinit (fts teardown) | `src/storage/graph_storage_adapter.zig:838-847` | extend for `fts_label_index` |
| `lookupManagedGraph` | `src/storage/graph_storage_adapter.zig:4548` | `StorageAdapter.lookupManagedGraph` |
| `bulkMergeNode` (worker-thread path) | `src/storage/graph_storage_adapter.zig:2456` | `bulkMergeNode` |
| index catalog (name-keyed, FTS by name only) | `src/index/index_manager.zig:62-67` | `IndexManager.fulltext_indexes` |
| `IndexType.fulltext` | `src/index/index_manager.zig:87` | — |
| FTS now requires adapter | `src/index/index_manager.zig:497-516` | `createFullTextIndex` |
| SHOW INDEXES (FTS name-only) | `src/execution/meta_dispatch.zig:283-324` | `executeDbIndexes` |
| CREATE…(RETURN/SET) | `src/execution/crud_operations.zig:1151` | `executeCreateQuery` |
| CREATE statement entry + batch fast path | `src/execution/crud_operations.zig:1691` | `executeCreate` |
| homogeneous batch CREATE | `src/execution/crud_operations.zig:1041` | `executeBatchCreateHomogeneous` |
| MATCH…CREATE batch | `src/execution/crud_operations.zig:628 / 790` | `executeCreateForBatch[WithTracking]` |
| node create call | `src/execution/crud_operations.zig:1202 / 1210` | `store.createNodeWithGraph` |
| property write chokepoint (SET seam) | `src/execution/property_mutation.zig:266` (23 call sites) | `property_mutation.setNodePropertyFromValue` |
| whole-node replace (SET n={...}) | `src/execution/crud_operations.zig:1498` | `property_mutation.replaceNodeProperties` |
| remove prop (REMOVE n.p) | `src/execution/crud_operations.zig:1511` | `property_mutation.removeNodeProperty` |
| add label (SET n:L) | `src/execution/crud_operations.zig:1458` | `store.addNodeLabel` |
| remove label (REMOVE n:L) | `src/execution/crud_operations.zig:1518` | `store.removeNodeLabel` |
| auto-index hook (template) | `src/execution/crud_operations.zig:425` | `ensureAutoIndexes` |
| DELETE | `src/execution/crud_operations.zig:2545` | `executeDelete` (delete loop 2717; `store.deleteNode` 6397) |
| store delete node | `src/graph_store.zig:6397` (no-save 6284) | `deleteNode` / `deleteNodeNoSave` |
| labels read (no public getter) | `store.nodes.getPtr(node_id).?.labels` | e.g. `crud_operations.zig:1480, 2662` |
| store label lookup | `src/graph_store.zig:2806` | `getNodesByLabel` |
| store node property | `src/graph_store.zig:3309` | `getNodeProperty` |
| store remove prop/label | `src/graph_store.zig:3370 / 3503` | `removeNodeProperty` / `removeNodeLabel` |
| store global accessors | `src/graph_store.zig:7339 / 7807 / 6737` | `global_allocator` / `getGlobalStore` / `getGlobalAdapter` |
| adapter createIndex (captures owner) | `src/storage/fts_storage_adapter.zig:141` | `createIndex` |
| adapter indexNode (append-only, write_mu) | `src/storage/fts_storage_adapter.zig:247` | `indexNode` |
| adapter deleteNode (tombstone, no-op safe) | `src/storage/fts_storage_adapter.zig:272` | `deleteNode` |
| adapter flush | `src/storage/fts_storage_adapter.zig:280` | `flush` |
| adapter search (no write_mu) | `src/storage/fts_storage_adapter.zig:294` | `search` |
| tokenizer | `src/index/fts_tokenizer.zig:67` | `tokenize(allocator, text, field)` |
| free postings | `src/index/fts_tokenizer.zig:160` | `freeTermPostings` |
| TermPosting alias | `src/index/fts_tokenizer.zig:7` | `pub const TermPosting = fts.TermPosting` |
| MERGE fast path = MULTI-THREADED | `tests/bulk_ingest/test_simple_merge_fastpath.zig:321-379` | 16× spawn → `bulkMergeNode` |
| ExecutionContext | `src/execution.zig` (parent module; grep the struct) | `pub const ExecutionContext` |
| fts Engine.init (owner capture) | `src/storage/fts_storage_adapter.zig:180` | inside `openOrCreate` (createIndex 141 / openIndex 150) |
