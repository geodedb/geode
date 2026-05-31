# A4 Change-Map — Wire Geode Full-Text Search End-to-End Through the fts-storage Adapter

**Scope:** READ-ONLY analysis. No code edited, no `zig build` run. Findings taken from md5-verified
`/tmp` copies and cross-checked across multiple reads (the session's output channel intermittently
appended prose after structured output; all such trailing prose was discarded). Treat line numbers as
"anchor near here", not byte-exact. A few items the channel never let me re-confirm are flagged
`[VERIFY]`.

**Repo:** `/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode`
**Branch (actual):** `feat/storage-lib-migration` (confirmed).

---

## 0. KEY CORRECTIONS vs the A4 brief's assumptions (read first)

The actual code differs from the brief in load-bearing ways:

1. **`getFulltextIndex` is a method on `StorageAdapter`, NOT `ManagedGraph`, and its parameter is the
   GRAPH name, not an index name.** `src/storage/graph_storage_adapter.zig:1287`:

   ```zig
   pub fn getFulltextIndex(self: *StorageAdapter, name: []const u8) ?*fulltext.FullTextIndex {
       self.mutex.lockUncancelable(...);
       const mg = self.engines.get(name);   // <-- `name` is the GRAPH name
       self.mutex.unlock(...);
       return if (mg) |m| m.fts_index else null;
   }
   ```

   There is currently NO index-name dimension at this entry point. It returns the graph's single
   `fts_index` facade (bound to the adapter's `"default"` named engine).

2. **`IndexManager.fulltext_indexes` stores `FullTextIndex` BY VALUE, not a metadata record, and has
   no writer.** `src/index/index_manager.zig:67`: `fulltext_indexes: std.StringHashMap(fulltext.
   FullTextIndex)`, keyed by index name. No `FulltextIndexRecord{name,label,properties}` type exists;
   a full-repo grep found `fulltext_indexes.put` / `addFulltextIndex` NOWHERE. Initialized empty
   (index_manager.zig:207), only iterated for deinit (268-272) and for SHOW (meta_dispatch.zig:296).
   It is effectively dead.

3. **CREATE INDEX never touches any FTS engine.** The handler writes only to `context.catalog`
   (a `Catalog`, `src/schema/catalog.zig`) and calls `statement_dispatcher.ensureAdvancedRuntimeIndex`
   (CONFIRMED at `src/execution/statement_dispatcher.zig:36`). For `.fulltext` the catalog stores the
   type string `"fulltext"` and nothing else happens — no `Engine` is created.

4. **SHOW INDEXES reads the Catalog AND the GLOBAL IndexManager (not context-scoped) for fulltext.**
   CONFIRMED `executeDbIndexes` in `src/execution/meta_dispatch.zig` (the `db.indexes()` /
   SHOW INDEXES backend): it does `context.catalog.listAllIndexes` for the btree/hash/etc rows, THEN
   (the #844 patch) `index_manager.getGlobalIndexManager().fulltext_indexes.keyIterator()` to append a
   FULLTEXT row per name with EMPTY label + EMPTY properties columns. So today FTS shows up ONLY if
   the global `IndexManager.fulltext_indexes` is populated (it isn't), AND with blank label/props even
   then. The catalog's `"fulltext"`-typed row from CREATE also appears (it has label+props). Net: a
   `CREATE INDEX ... fulltext` today yields one catalog row with no backing engine; the #844 path adds
   nothing.

Design implication (see §7): the cleanest reconciliation is to keep **Catalog authoritative for SHOW**
(it already gets a fulltext row with label+columns at CREATE), and add a **named-index registry on
`ManagedGraph`** (label+properties metadata + the real engines via `fts_adapter`, which already
supports arbitrarily many named indexes). Then optionally drop the dead #844 global-IndexManager
fulltext read.

---

## 1. CreateIndex execution handler — insertion point + how it reaches the adapter

**Location:** `src/execution.zig`, dispatch `switch` arm **`.CreateIndex => |ci|` at line 1405** (an
arm of the big statement switch in `executeStatementWithContext`, NOT a `handleCreateIndex` fn).
Verbatim shape (lines 1405-1485):

```zig
.CreateIndex => |ci| {
    const cat = context.catalog;
    const index_name = ci.name orelse blk: {            // auto-name "idx_<label>_<prop>..."
        var parts = try std.ArrayList(u8).initCapacity(allocator, 64);
        try parts.appendSlice(allocator, "idx_");
        try parts.appendSlice(allocator, ci.label);
        for (ci.properties) |prop| { try parts.append(allocator, '_'); try parts.appendSlice(allocator, prop); }
        break :blk try parts.toOwnedSlice(allocator);
    };
    if (ci.if_not_exists) {
        const existing = cat.getIndex(ci.label, index_name) catch null;
        if (existing != null) { return /* empty success */; }
    }
    if (ci.index_type == .vector or ci.index_type == .vector_f32) { /* text-vs-vector field guard */ }
    const index_info = IndexInfo{
        .name = index_name,
        .index_type = switch (ci.index_type) { .btree=>"btree", .hash=>"hash", .fulltext=>"fulltext", ... }, // 1449-1462
        .table_name = ci.label,
        .columns = @as([][]const u8, @constCast(ci.properties)),
    };
    cat.addIndex(index_info) catch |err| {              // line 1467
        if (err == error.DuplicateIndex and ci.if_not_exists) { return /* empty success */; }
        return err;
    };
    try statement_dispatcher.ensureAdvancedRuntimeIndex(allocator, index_name, ci.label, ci.properties, ci.index_type); // 1478
    return /* empty success */;
},
```

**There is NO dedicated fulltext branch** — `.fulltext` is only a label string (line 1452). A4a adds
one.

**`ast.CreateIndexStatement` (src/gql/ast.zig:518):** `name: ?[]const u8`, `label: []const u8`
(REQUIRED, not optional — unlike the brief's `?`), `properties: [][]const u8`,
`index_type: IndexType = .btree` (line 521; default `.btree`, NOT optional), `if_not_exists: bool`.
`IndexType` enum at ast.zig:582 with `fulltext` at line 585.
`[VERIFY: whether the struct also carries`using`/`unique`/`fulltext_options`— re-read ast.zig:518-541.]`

**`Catalog.addIndex`** is `src/schema/catalog.zig:759` `pub fn addIndex(self: *Catalog, info:
IndexInfo) !void`. This is the SHOW source of truth and IS already written for fulltext today.

**How the handler reaches the adapter/graph.** The handler runs as `executeStatementWithContext(
allocator, stmt, context: ExecutionContext)`. In scope: `allocator`, `ci`, `context` (has `.catalog`;
`[VERIFY field names for current graph + tenant — likely`.current_graph`/`.tenant_id`]`). The
StorageAdapter/GraphStore are reached via the `graph_store` module globals: the CreateGraph arm uses
`graph_store.getGlobalStore(allocator)` (execution.zig:1650); `graph_store.getGlobalAdapter()` is the
StorageAdapter accessor (it owns `engines: StringHashMap(*ManagedGraph)` and `getFulltextIndex`).
`[VERIFY the exact accessor that returns the`*ManagedGraph` holding `fts_adapter` for the current
graph — confirm against the working `fulltext_search`call site (§6).]`

**EXACT insertion point for A4a:** immediately AFTER `cat.addIndex(index_info)` succeeds
(execution.zig:1476), gated on `if (ci.index_type == .fulltext)`:

1. resolve the StorageAdapter + the current graph's `ManagedGraph` (holder of `fts_adapter`);
2. `try mg.fts_adapter.?.createIndex(index_name)` (idempotent per fts_storage_adapter.zig:141);
3. backfill existing label nodes (§2);
4. register the named index in the new ManagedGraph registry with its label+properties (§7).
   Honor `ci.if_not_exists` (the `cat.getIndex` pre-check at 1419 already short-circuits the common
   duplicate case).

---

## 2. Backfill — label scan + property text read (all CONFIRMED)

`GraphStore` APIs (`src/graph_store.zig`):

- **Single-label node-id scan (best for backfill):** `getNodesByLabel(self: *const GraphStore,
  graph_name: []const u8, label: []const u8) ?[]const u64` at **2806**. Takes `graph_name`; returns a
  BORROWED `?[]const u64` (no allocation, no free). Internally keys `"{graph_name}:{label}"` into
  `self.label_index` and returns `posting.list.items`.
- **Multi-label scan:** `getNodesByLabels(self: *const GraphStore, allocator, graph_name: []const u8,
  labels: []const []const u8, tenant_id: ?[]const u8) !std.ArrayList(u64)` at **2857**. Returns an
  **`std.ArrayList(u64)`** (caller `.deinit()`s it), NOT a raw `[]u64`.
- **Property read:** `getNodeProperty(self: *GraphStore, node_id: u64, key: []const u8)
  ?PropertyValue` at **3309** (prefer this — optional, no error). Also `getNodePropertyValue` at 3363
  returning `!PropertyValue`.
- **All-tenant fallback:** `getAllNodesForTenant(self, allocator, tenant: ?[]const u8) ![]u64` at 3584.

**`PropertyValue`** is `union(enum)` at `src/graph_store.zig:204` — CONFIRMED variants:

```zig
pub const PropertyValue = union(enum) {
    String: []const u8,   // <-- the text variant, CAPITALIZED .String
    Int: i64, Float: f64, Bool: bool, Null,
    ExtValue: @import("eval_extended.zig").ExtValue,
    Decimal: struct { coeff: i128, scale: u8 },
};
```

Map to text:

```zig
const text = switch (store.getNodeProperty(id, prop) orelse continue) {
    .String => |s| s,
    else => continue,   // non-string props skipped for FTS
};
```

**Backfill loop:** resolve the `*GraphStore` for the current graph; `getNodesByLabel(graph_name,
ci.label)`; for each node id, read each `ci.properties[]` value as `.String`, concatenate the
per-property strings into ONE document buffer per node (one document = one node_id — see §4: a second
`indexNode` for the same node would ADD duplicate postings, so concatenate; do NOT call per-property),
then `try mg.fts_adapter.?.indexNode(index_name, id, text)` (adapter tokenizes internally per A1-A3).
`[VERIFY how to get a`*GraphStore` for a named graph from the ManagedGraph: ManagedGraph.engine is a
`*ShardedGraphEngine`, not a bare GraphStore. The simplest correct path is the global
`graph_store.getGlobalStore(allocator)` (single-store in this tree) with `graph_name`; confirm that is
the same store the CRUD writes land in.]`

---

## 3. Node write path — the maintenance hook (hot/sensitive)

**Hook at the execution CRUD layer, AFTER the store write commits** — NOT inside
`GraphStore.createNode/deleteNode`. Those run under the store lock; the fts `Engine` is
single-threaded with its own `rw_lock` (engine.zig:123) and asserts owning-thread, so calling it while
holding `store_mutex` invites the lock-ordering hazards CLAUDE.md warns about. Relevant functions in
`src/execution/crud_operations.zig` (line numbers confirmed):

- **CREATE:** `executeCreate(allocator, c: ast.CreateStatement, current_graph, context)` at **1691**;
  `executeCreateQuery(...)` at **1151**; batch `executeCreateForBatch` at **628** /
  `executeCreateForBatchWithTracking` at **790**. `[VERIFY the exact post-`store.createNode...` line
  in each where `node_id`+ props are in hand — re-read 1691-1990 and 628-900.]`
- **UPDATE (SET):** there is no `executeSet`; node-property SET flows through
  `property_mutation.setNodePropertyFromValue` (the edge sibling `setEdgePropertyFromValue` is called
  at crud_operations.zig:110). `[VERIFY exact node-SET fn name in`property_mutation`— that is the
  update-hook seam.]`
- **DELETE:** `executeDelete(allocator, d: ast.DeleteStatement, current_graph, context)` at **2545**.
  Capture the node's labels BEFORE `store.deleteNode(node_id)` (GraphStore:6397), then
  `mg.fts_adapter.?.deleteNode(index_name, node_id)` for each covering index.

**Per-seam logic:** for the node's labels, find any fulltext index covering (label, property); if so:
CREATE → `indexNode(name, id, full_doc)`; SET → delete-then-index the FULL doc (§4);
DELETE → `deleteNode(name, id)`.

**Cheap no-FTS early-out (CRITICAL).** Today there is NO fast registry keyed by label
(`IndexManager.fulltext_indexes` is unpopulated; `Catalog` is keyed by name). A4a must add a
**per-ManagedGraph fulltext registry** (recommended `StringHashMap` keyed by index name → `{label,
properties}` + a `count()`). The hook short-circuits on `mg.fts_indexes.count() == 0` (one integer
load in the common zero-FTS case) and otherwise iterates the small set matching label+property. This
registry doubles as the §7 reconciliation target.

---

## 4. fts-storage re-index semantics — update hook MUST delete-then-index (CONFIRMED from engine body)

Read of `fts-storage/src/engine.zig`: `indexDocumentExcluding` at 686, **`indexDocument` at 703**,
`deleteDocument` at 935 (`self.all_tombstones.put(self.allocator, doc_id, {})` at 946). The engine
keeps an aggregated tombstone set `all_tombstones` (decl line 80) built at init from every segment's +
the memtable's tombstones (366-378); `TermIterator` skips tombstoned docs.

**`indexDocument` body (703-816) — DEFINITIVE:** it validates terms, WAL-brackets BEGIN/payload/COMMIT

- `sync()`, then does `for (terms) |t| try self.memtable.addPosting(t.term, doc_id, t.positions);`
(line 804-806). **It does NOT tombstone the doc_id and does NOT remove any prior postings for that
doc.** So calling `indexDocument` again for an existing doc_id simply **ADDS more postings** (the old
terms remain live in the memtable/segments). There is NO replace/dedup.

**Conclusion (definitive):** the UPDATE hook MUST do `fa.deleteNode(name, id)` (→
`Engine.deleteDocument` → tombstone the doc) **then** `fa.indexNode(name, id, new_full_text)`. A bare
re-index would leave the old document's terms searchable AND duplicate the unchanged ones. The CREATE
path may use a plain `indexNode` (new doc, nothing stale).

---

## 5. DROP INDEX handler

**Location:** `src/execution.zig`, dispatch arm **`.DropIndex => |di|` at line 1551**. Verbatim shape
(1551-1589):

```zig
.DropIndex => |di| {
    const cat = context.catalog;
    const index_name = di.name;
    var found_key: ?[]const u8 = null;
    var iter = cat.indexes.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*.name, index_name)) { found_key = entry.key_ptr.*; break; }
    }
    if (found_key) |key| {
        if (cat.indexes.fetchRemove(key)) |removed| {
            if (statement_dispatcher.runtimeAdvancedIndexTypeFromCatalog(removed.value.index_type)) |kind| {
                if (index_manager.getGlobalIndexManager()) |manager| {
                    _ = manager.dropAdvancedIndex(removed.value.name, kind) catch false;
                }
            }
            cat.allocator.free(removed.key); cat.allocator.free(removed.value.name);
            cat.allocator.free(removed.value.table_name);
            for (removed.value.columns) |col| cat.allocator.free(col);
            cat.allocator.free(removed.value.columns);
        }
    } else if (!di.if_exists) { return error.IndexNotFound; }
    return /* empty success */;
},
```

`DropIndexStatement` at ast.zig:542; `name` + `if_exists` confirmed in use here.

**A4a addition:** inside the `fetchRemove` block, when `removed.value.index_type` equals `"fulltext"`:
resolve the current graph's `ManagedGraph`, `try mg.fts_adapter.?.dropIndex(index_name)` (engine
flush+deinit + on-disk tree delete, fts_storage_adapter.zig:213), and remove the entry from the new
per-graph fulltext registry (§7), freeing owned key/strings. `di.if_exists` is already handled for the
not-found case.

---

## 6. getFulltextIndex — named resolution

**Current:** `StorageAdapter.getFulltextIndex(self, name)` at gsa:1287 treats `name` as the GRAPH name
and returns that graph's single `mg.fts_index` facade. `ManagedGraph` (gsa:639) holds:
`fts_index: ?*fulltext.FullTextIndex` (654), `fts_adapter: ?*FtsStorageAdapter` (659),
`fts_base_dir: ?std.Io.Dir` (663), `fts_dir: ?[]const u8` (665). The facade is built in the FTS-init
helper (gsa 3894-3973: `default_fts_index_name = "default"`, `adapter.openIndex`-then-`createIndex`,
`FullTextIndex.initBacked(allocator, adapter, "default")`), assigned at createGraphLocked
(gsa:4021-4022) and openGraphLocked (gsa:4106-4107). deinit frees the four fields (gsa:782-797).

The facade `src/index/fulltext.zig:21 FullTextIndex` is a thin wrapper keyed by `index_name`:
`initBacked` at 50; `indexDocument`(tokenize→`adapter.indexNode(self.index_name,...)`) at 73;
`search`(per-term `adapter.search(self.index_name,...)` merged OR, sorted desc) at 92;
`removeDocument`→`adapter.deleteNode` at 144; `flush`→`adapter.flush` at 151. The routing key into the
named engine IS the facade's `index_name`.

**Recommended change (preferred):** add a named-facade map to `ManagedGraph`:
`fts_facades: std.StringHashMap(*fulltext.FullTextIndex)` keyed by index name, plus
`getFulltextIndexNamed(self: *ManagedGraph, index_name) ?*FullTextIndex` that returns a cached facade
or lazily builds one via `FullTextIndex.initBacked(self.allocator, self.fts_adapter.?, dupe(name))`
**only if `self.fts_adapter.?.getIndex(name) != null`** (fts_storage_adapter.zig:235 — so an unknown
name returns null, not a fabricated empty index). Either keep `fts_index` as the lazy `"default"`
facade or fold `"default"` into the map. deinit must iterate+free all facades (+ keys). Add a sibling
`StorageAdapter.getFulltextIndexNamed(graph_name, index_name)` delegating to the ManagedGraph method.

**Update the query entry point** (`fulltext_search(indexName, query[, max])`) to call the NAMED
resolver with the current graph + `indexName`, instead of passing `indexName` to `getFulltextIndex`
(which interprets it as a graph name).
`[VERIFY the executeFulltextSearchCall site (brief says ~execution.zig:1640): confirm it currently
calls getFulltextIndex(indexName) — i.e. treats the index name as a graph name (a latent bug) — and
redirect it to getFulltextIndexNamed(current_graph, indexName).]`

---

## 7. Registry reconciliation — single source of truth

**Current disagreement:**

- `Catalog` (context.catalog): written for fulltext at CREATE (execution.zig:1467) with name+label+
  columns; read by SHOW (`executeDbIndexes` → `catalog.listAllIndexes`). **Already carries the row.**
- Global `IndexManager.fulltext_indexes`: ALSO read by SHOW (#844, with EMPTY label/props) but NEVER
  written → contributes nothing.
- `ManagedGraph.fts_adapter`: owns the real engines, but CREATE never calls it.

**Recommended single source of truth:**

- **SHOW / catalog of FTS indexes → keep `Catalog` authoritative** (it already gets a labelled row at
  CREATE and frees it at DROP). Optionally remove the dead `IndexManager.fulltext_indexes` read from
  `executeDbIndexes` (#844) to avoid the duplicate, blank-columned row. `[VERIFY`catalog.
  listAllIndexes`already returns name+type+label+columns so the #844 read can be dropped with no
  column loss.]`
- **Engines + label/property metadata for the DML hook → the new per-ManagedGraph fulltext registry**
  (§3/§6: `StringHashMap` keyed by index name → `{label, properties, *FullTextIndex}`).
- **At CREATE, write THREE things in one place:** `cat.addIndex` (SHOW), `fa.createIndex` (engine),
  `mg.fts_indexes.put` (hook metadata + named facade). **At DROP, remove all three.** All reachable
  from the `.CreateIndex`/`.DropIndex` arms via `context.catalog` and the resolved `ManagedGraph`.

---

## 8. e2e test seam

**Pattern confirmed** — `tests/test_gap0811_aggregation_fastpath.zig` `Harness` (line 47):
`init` (54) calls `execution.cleanupCatalogInstance()`, `graph_store.deinitGlobalStore()`, makes a
tmpDir, `graph_store.setDataDirOverride(allocator, data_dir)`, `graph_store.getGlobalStore(allocator)`,
`execution.ensureCatalogInstance(allocator)`, stores `ctx = ExecutionContext{ .catalog = catalog }`.
`runQuery` (86) does `geode.parseGql(query, aa)` then
`execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx)`. This drives full
CREATE + MATCH end-to-end in-process against the global store/adapter — so A4c can drive
`CREATE (:Doc {body:"the quick brown fox"})` → `CREATE INDEX ... USING fulltext` (backfill) →
`RETURN fulltext_search("docidx","fox")`.
`[VERIFY: confirm a default ManagedGraph with`fts_adapter != null` exists after Harness.init (the FTS
adapter is built in createGraphLocked/openGraphLocked). If `getGlobalStore`alone does not materialize
the default graph's FTS adapter, the test must first issue a CREATE GRAPH or a write that does.]`

**Explicit flush NOT required.** `fts-storage/src/search.zig` `TermIterator` (line 29) iterates the
**memtable first, then sealed segments** (`mem_postings` field 35 + `seg_iters` 38; `next()` loop
"First exhaust memtable" then "Then segments", 233-254), skipping tombstoned docs. Since `indexNode`
writes to the memtable synchronously (engine.zig:804-806) and the e2e test, the backfill/maintenance
writes, and `fulltext_search` all run in ONE process against the same global adapter → same
`FtsStorageAdapter` → same `Engine`, a `search` sees the just-indexed docs WITHOUT any `flush()`. (A
restart-and-reopen test WOULD need flush; out of A4c scope.)

---

## 9. Recommended A4 sub-task breakdown

### A4a — DDL: CREATE (named + backfill), DROP, named resolution, registry reconciliation

- `src/execution.zig` `.CreateIndex` arm (1405-1485): after `cat.addIndex`, add `if (ci.index_type ==
  .fulltext)` → resolve ManagedGraph, `fts_adapter.createIndex(index_name)`, backfill (§2),
  `mg.fts_indexes.put(...)`. Honor `if_not_exists`.
- `src/execution.zig` `.DropIndex` arm (1551-1589): in the fulltext case of the fetchRemove block →
  `fts_adapter.dropIndex(name)` + `mg.fts_indexes` remove. Honor `if_exists`.
- `src/storage/graph_storage_adapter.zig`: add `ManagedGraph.fts_indexes: StringHashMap({label,
  properties, *FullTextIndex})` + `getFulltextIndexNamed`; add `StorageAdapter.getFulltextIndexNamed(
  graph, index_name)`; update deinit (782-797) to free the new map + facades.
- `src/execution.zig` `fulltext_search` call site (`[VERIFY ~1640]`): route `indexName` to the NAMED
  resolver with the current graph (fixes the graph-name-vs-index-name conflation, §6).
- SHOW: keep on `Catalog` (`executeDbIndexes`); optionally drop the dead #844
  `IndexManager.fulltext_indexes` read.

### A4b — DML: write-maintenance hook

- `src/execution/crud_operations.zig`: `executeCreate` (1691), `executeCreateQuery` (1151), batch
  paths (628/790) → after node create, `indexNode` covered docs. Node-SET seam in `property_mutation`
  (`setNodeProperty*`, `[VERIFY exact fn]`) → delete-then-index the FULL doc (§4). `executeDelete`
  (2545) → `deleteNode`. All guarded by `mg.fts_indexes.count() == 0` O(1) early-out.

### A4c — e2e test

- New `tests/test_gap08XX_fts_e2e.zig` mirroring the gap0811 Harness (line 47). Cases: CREATE node →
  CREATE INDEX fulltext (backfill) → search returns it; CREATE INDEX → CREATE node (hook path) →
  search returns it; SET edit → old term stops matching / new term matches (proves §4 delete-then-
  index); DELETE → search drops it; SHOW INDEXES lists the fulltext index (proves §7). No flush.

### Highest-risk edit

**A4b's SET (update) hook** — it must reconstruct the FULL document (ALL of the index's properties,
not just the changed one) and do delete-then-index per §4, while staying O(1) when no FTS index
exists. Getting it wrong silently leaves stale/duplicate terms searchable (the §4 trap). The
lock-ordering constraint (never call the single-threaded fts `Engine` while holding `store_mutex`) is
tightest here. **Second-riskiest:** the `getFulltextIndex` graph-name-vs-index-name correction (§6) —
the public entry point's parameter semantics change, so `fulltext_search` (and any other caller) must
be re-pointed in lockstep or search breaks. **Third:** the ManagedGraph struct/deinit changes (facade
map ownership → leak risk).

---

## OUTSTANDING [VERIFY] ITEMS (re-confirm with a fresh read before implementing)

1. `ast.CreateIndexStatement` full field set (using/unique/fulltext_options) — ast.zig:518-541.
2. `ExecutionContext` field names for current graph + tenant, and the exact accessor chain from
   `context`/`graph_store` to the `*ManagedGraph` owning `fts_adapter` for the active graph.
3. How to obtain a `*GraphStore` for a named graph (global `getGlobalStore` vs via ManagedGraph.engine).
4. The `fulltext_search` call site (~execution.zig:1640): confirm it passes `indexName` to
   `getFulltextIndex` as a graph name, and the redirect to `getFulltextIndexNamed`.
5. Node-SET mutation fn name in `property_mutation` for the update hook.
6. Whether the gap0811 Harness yields a default ManagedGraph with `fts_adapter != null` post-init.
7. `catalog.listAllIndexes` column set, to safely drop the #844 SHOW read.

---

## CONFIRMED FACTS (no re-verification needed)

- PropertyValue text variant = `.String: []const u8` (graph_store.zig:205).
- `getNodesByLabel(graph_name, label) ?[]const u64` @2806 (borrowed); `getNodesByLabels(...) !ArrayList(u64)` @2857.
- `getNodeProperty(node_id, key) ?PropertyValue` @3309.
- `ensureAdvancedRuntimeIndex` @ statement_dispatcher.zig:36 (CREATE calls it; fulltext is a no-op there for engines).
- `.CreateIndex` arm @1405; `.DropIndex` arm @1551; `cat.addIndex` @1467.
- `indexDocument` @engine.zig:703 APPENDS to memtable, no tombstone/replace → update needs delete-first.
- `deleteDocument` @engine.zig:935 tombstones; `TermIterator` reads memtable then segments (search sees unflushed writes).
- SHOW path = `executeDbIndexes` reading `catalog.listAllIndexes` + (#844) global `IndexManager.fulltext_indexes` (empty cols).
- `getFulltextIndex` is on `StorageAdapter` @gsa:1287, parameter = graph name.
- `IndexManager.fulltext_indexes` = `StringHashMap(FullTextIndex)` by value @im:67, never written.
