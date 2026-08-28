# RAG Orchestrator Engine Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement every engine-actionable recommendation from `specs/geode-vectorization-and-reranking.md` (the hybrid-RAG/GraphRAG audit): FTS row-visibility authorization, knn metric-mismatch validation, `geode.fts.rebuild`, bulk-MERGE live FTS maintenance, per-request read-only enforcement, MCP read-only mode, truthful `SHOW CAPABILITIES`, and the production orchestrator prompt + integration-guide docs artifacts.

**Architecture:** Each recommendation lands as a small, independently testable change following the repo's existing dispatch/classification/CANARY conventions. Security changes are fail-closed. Prompt-level recommendations that the engine cannot enforce become documented contracts in two new docs under `docs/rag/`.

**Tech Stack:** Zig 0.16 (engine), YAML harness specs in `../geode-test-harness/geodetestlab-cli/specs/` (separate git repo — commit there separately), no new dependencies.

## Global Constraints

- Repo root: `/data/home/benji/src/devnw/codepros/geode/geode` (main branch, direct commits on main).
- Zig 0.16; format with `make fmt` (`zig fmt src/ tests/ build.zig`) before every commit.
- Every new implementation site gets a CANARY marker: `// CANARY: REQ=<id>; FEATURE="<quoted>"; ASPECT=<CamelCase>; STATUS=TESTED; TEST=<path>; OWNER=<team>; UPDATED=2026-08-28`. `TEST=` required for `STATUS=TESTED`. The pre-commit CANARY hook regenerates `docs/status.csv` — include it in the same commit when it changes.
- New `CALL geode.*` procedures follow the 4-step convention: router arm in `src/execution/procedure_registry.zig`, family dispatcher, `procedure_access.zig` classification (omit from `read_only_procedure_names` to stay `.mutating`, fail-closed), `cluster_mod.gateUnreplicatedWrite()` on every write handler.
- Harness specs: assert on `"status_class"` in `stdout_contains` / `stdout_not_contains`, never on `exit_code` (the `query` subcommand always exits 0). First and last tests are idempotent teardowns tagged `canary`.
- Known-red pre-commit hooks to ignore (pre-existing): markdownlint (`ENTERPRISE_GAPS.md` + `docs/bugs/*.md`), hadolint, goreleaser check, detect-diamond-deps. Known flaky parallel-shard tests (verify serially before blaming a change): `test_edge_popular_parent_throughput`, `test_match_set_label_scan_regression`, `test_where_scan_writer_progress`. `zig build test-gap0866` is broken on unmodified main (pre-existing, module wiring) — not a regression signal.
- Full-suite gate after all tasks: `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N` for N=0..3.
- Commit messages: conventional (`feat:`/`fix:`/`test:`/`docs:`), end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do NOT push — the orchestrator pushes at the end (geode pushes are slow and retry-prone).
- NO MOCKS, NO SIMULATION (repo rule): tests drive real executor/dispatch paths.
- Spec source of truth: `specs/geode-vectorization-and-reranking.md`. The spec's `vector_distance_cosine`/`vector_distance_l2`/`vector_distance_dot` names come from geodedb.com public docs and DO NOT exist in this engine — real names are `vector_l2`, `vector_cosine` (similarity), `vector_dot`, `distance(v1,v2[,metric])`, `similarity(...)`, `knn(prop,qvec,k,metric)`. Docs written in Task 8 MUST use the real names (the spec's own rule: never invent aliases).

---

### Task 1: FTS result row-visibility authorization (tenant + RLS)

The spec's data-boundary rule: "ACL/RLS/classification enforcement before evidence reaches reranker/LLM" and "over-fetch IDs, resolve under database-enforced authorization, discard unauthorized rows". Today `src/execution/fts_dispatch.zig:52` discards `ExecutionContext` (`_ = context;`) and returns raw `(node, score)` rows with no tenant or RLS filtering — a cross-tenant / RLS-bypass leak of node ids and relevance scores.

**Files:**
- Modify: `src/execution/match_operations.zig` (add one `pub` combinator near `passesRLSFilter`, ~line 296)
- Modify: `src/execution/fts_dispatch.zig` (thread context; filter hits in `handleFtsSearch`, `handleFtsPhrase`, `handleFtsProximity`)
- Test: `tests/test_fts_authorization.zig` (new), wired into `build.zig` as `test-fts-authorization`

**Interfaces:**
- Consumes: private `passesTenantFilter(node, ?[]const u8) bool` and `passesRLSFilter(*std.StringHashMap(rls.Value), node) bool` in `match_operations.zig`; `ExecutionContext.tenant_id`; `graph_store.getGlobalStore`; the shard-locked accessors `store.nodes.lockShardShared/unlockShardShared/getPtrUnlocked` (added by commit `448ac850`, `src/storage/node_cache.zig:572-584`).
- Produces: `pub fn passesRowVisibilityFilters(reusable_row: *std.StringHashMap(rls.Value), node: graph_store.Node, filter_tenant: ?[]const u8) bool` in `match_operations.zig` — Tasks 3/4 do not use it, but future engine-direct read paths should.

- [ ] **Step 1: Write the failing test**

Create `tests/test_fts_authorization.zig`. Model setup on `tests/test_fts_e2e.zig` (read it first for store/adapter/index bootstrap and teardown). Test bodies:

```zig
// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-001; FEATURE="FullText"; ASPECT=TenantFilteredResults; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-28
test "fts search drops rows from other tenants" {
    // Bootstrap global store + adapter exactly as test_fts_e2e.zig does.
    // 1. Create two nodes with label :FtsAuthDoc, string property `body`,
    //    one tagged tenant "tenant_a", one "tenant_b" (create via the same
    //    store API test_fts_e2e uses; set node.tenant_id per the pattern in
    //    tests/test_gap0509_tenant_isolation.zig).
    // 2. CREATE the fulltext index via fts_index_ops.createFulltextIndex.
    // 3. Build an ExecutionContext with .tenant_id = "tenant_a" and install it
    //    as the active context (execution.setActiveContext — see how
    //    tests/test_gap0509_tenant_isolation.zig installs a context).
    // 4. Call fts_dispatch.execute(alloc, "geode.fts.search", call_stmt, ctx)
    //    with a query matching BOTH docs.
    // 5. Assert exactly the tenant_a node id appears; tenant_b's id absent.
}

test "fts search with no tenant filter returns all rows" {
    // Same setup, ctx.tenant_id = null → both ids returned (admin/all-tenants).
}

test "fts search drops RLS-label-denied rows" {
    // Install the RLS filter engine deny for label :FtsAuthDoc for user "bob"
    // (mirror tests/test_rls_expr_engine_wiring.zig setup), ctx.user = "bob",
    // assert zero rows; then clear engine → rows return.
}
```

Write REAL code following those recipe comments — the comments describe intent, the test must actually perform each step with the concrete APIs found in the three referenced test files.

- [ ] **Step 2: Wire and run to verify it fails**

Wire in `build.zig`: copy the `test-scan-ingest-race` block (build.zig:7899-7905) verbatim, rename to `test-fts-authorization`, root `tests/test_fts_authorization.zig`, and `shardDep(..., 1, ...)` into the aggregate step.
Run: `zig build test-fts-authorization`
Expected: FAIL — tenant_b's node id IS present (leak reproduced), RLS-denied rows present.

- [ ] **Step 3: Add the pub combinator in match_operations.zig**

Insert directly above `fn passesRLSFilter` (~line 296):

```zig
// Spec geode-vectorization-and-reranking (FTS data boundary): engine-direct
// read paths that resolve candidate ids OUTSIDE the MATCH loop (e.g. fulltext
// search hits) must apply the same hierarchy-aware tenant filter and two-layer
// RLS filter as MATCH rows before results leave the engine.
// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-001; FEATURE="FullText"; ASPECT=RowVisibilityCombinator; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-28
pub fn passesRowVisibilityFilters(
    reusable_row: *std.StringHashMap(rls.Value),
    node: graph_store.Node,
    filter_tenant: ?[]const u8,
) bool {
    return passesTenantFilter(node, filter_tenant) and passesRLSFilter(reusable_row, node);
}
```

- [ ] **Step 4: Thread context through fts_dispatch and filter hits**

In `src/execution/fts_dispatch.zig`:
1. Delete `_ = context;` (line 52). Pass `context` to all three handlers; add `context: ExecutionContext` to each handler signature.
2. Add imports mirroring `match_operations.zig`'s `rls` import (check its top-of-file import block for the exact path) plus `const match_operations = @import("match_operations.zig");`.
3. In `handleFtsSearch` (and identically in `handleFtsPhrase`/`handleFtsProximity`), replace the row-construction loop: filter first, then build rows from the authorized subset:

```zig
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    var reusable_row = std.StringHashMap(rls.Value).init(allocator);
    defer reusable_row.deinit();

    // Spec: over-fetch → resolve under database-enforced authorization →
    // discard unauthorized rows BEFORE results leave the engine. The node is
    // read under its shard's SHARED map_lock so the property map cannot be
    // realloc-freed mid-read by a concurrent writer (same locking contract as
    // scanVectorKnn after ENG-3954).
    var authorized = try std.ArrayList(@TypeOf(hits[0])).initCapacity(allocator, hits.len);
    defer authorized.deinit(allocator);
    for (hits) |hit| {
        const visible = blk: {
            store.nodes.lockShardShared(hit.doc_id);
            defer store.nodes.unlockShardShared(hit.doc_id);
            const np = store.nodes.getPtrUnlocked(hit.doc_id) orelse break :blk false; // deleted since indexing
            break :blk match_operations.passesRowVisibilityFilters(&reusable_row, np.*, context.tenant_id);
        };
        if (visible) authorized.appendAssumeCapacity(hit);
    }
```

Then build `rows` from `authorized.items` instead of `hits` (row count = `authorized.items.len`). Add a CANARY (`ASPECT=SearchRowFilter` / `PhraseRowFilter` / `ProximityRowFilter`) at each of the three filter sites. NOTE: if `store.nodes.getPtrUnlocked` does not exist under that exact name, use whatever shard-locked pointer accessor commit `448ac850` added to `src/storage/node_cache.zig` (`git show 448ac850 -- src/storage/node_cache.zig`) — do NOT fall back to the unlocked `iterator()` or an unlocked `getPtr`.

- [ ] **Step 5: Run tests to verify pass**

Run: `zig build test-fts-authorization && zig build test-fts-e2e && zig build test-gap0509-tenant-isolation 2>/dev/null || zig build test-gap0509 2>/dev/null; true` — find the exact gap-0509 step name with `grep -n "gap0509" build.zig` and run it. All green. Also run `zig build test-rls-expr-engine-wiring` (find exact name via `grep -n "rls_expr" build.zig`).

- [ ] **Step 6: Commit**

```bash
git add tests/test_fts_authorization.zig src/execution/match_operations.zig src/execution/fts_dispatch.zig build.zig docs/status.csv
git commit -m "feat(fts): enforce tenant + RLS row visibility on geode.fts.* results

Spec geode-vectorization-and-reranking: candidates must pass database-enforced
authorization before leaving the engine; fts_dispatch previously discarded the
ExecutionContext and leaked node ids + scores across tenants and RLS policies.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: knn metric-mismatch validation + `inner_product` metric parity

The spec: "Use only documented vector functions… never invent an alias; capability-check undocumented functions" and "verify actual plans rather than assuming execution semantics". Two engine defects: (a) `searchWithMetric` (`src/index/advanced_types_index.zig:520-552`) ignores the caller's metric for neighbour selection — `knn('emb',$q,10,'cosine')` on an l2 index silently returns l2 neighbours relabeled as cosine scores; (b) `inner_product` is accepted by DDL metric validation (`src/execution.zig:1631`) but rejected by the query-side `parseVectorMetric` (`src/eval.zig:2135-2150`).

**Files:**
- Modify: `src/index/advanced_types_index.zig:520-552` (`searchWithMetric`)
- Modify: `src/eval.zig:2135-2150` (`parseVectorMetric`), plus the `evalVectorKnn` error surface (~`src/eval.zig:2445-2480`)
- Modify: `src/server/proto_util.zig` (~line 154 area, `mapError`) — add a mapping for the new error
- Test: `tests/test_knn_metric_mismatch.zig` (new), wired as `test-knn-metric-mismatch`
- Harness spec: `../geode-test-harness/geodetestlab-cli/specs/knn_metric_mismatch.yml` (new)

**Interfaces:**
- Consumes: `self.metric` on the advanced index wrapper (same enum type as the parsed query metric — verify with `grep -n "metric" src/index/advanced_types_index.zig | head`), `parseVectorMetric`, `proto_util.mapError`.
- Produces: `error.VectorMetricMismatch` surfaced with a distinct GQLSTATE (`42704`, same class the DDL metric validator uses) and message `"knn metric does not match the vector index metric; query with the index's metric or recreate the index"`.

- [ ] **Step 1: Write the failing test**

`tests/test_knn_metric_mismatch.zig` — model store/index bootstrap on `tests/test_using_vector_index.zig` (read it first; it builds a real HNSW runtime index):

```zig
test "knn with mismatched metric errors instead of silently relabeling" {
    // 1. Bootstrap store; create nodes with a 4-dim vector property.
    // 2. Create the advanced vector index WITH metric l2 (follow
    //    test_using_vector_index.zig's index-build path).
    // 3. Execute knn('<prop>', vectorf32('[1.0,0,0,0]'), 2, 'cosine') through
    //    the real executor (same query-execution entry test_using_vector_index
    //    uses).
    // 4. Assert the statement FAILS with the VectorMetricMismatch surface
    //    (not success, not empty rows).
}

test "knn with matching metric still works" {
    // Same setup; knn(..., 'l2') succeeds and returns k ids.
}

test "inner_product accepted as query-side metric synonym for dot" {
    // distance(vectorf32('[1,0]'), vectorf32('[0,1]'), 'inner_product')
    // evaluates without error and equals distance(..., 'dot_product').
}
```

- [ ] **Step 2: Wire + run to verify failure**

Wire `test-knn-metric-mismatch` in `build.zig` (same pattern as Task 1). Run: `zig build test-knn-metric-mismatch`.
Expected: test 1 FAILS (query succeeds with wrong-metric neighbours), test 3 FAILS (`InvalidArgs`), test 2 passes.

- [ ] **Step 3: Implement**

(a) `src/index/advanced_types_index.zig` — in `searchWithMetric`, after the dimension check (`:530`):

```zig
        // Spec geode-vectorization-and-reranking: the HNSW graph is built with
        // self.metric; a different query metric would silently return the
        // index-metric neighbour set relabeled with the caller's scores.
        // CANARY: REQ=REQ-VECTOR-KNN-METRIC-VALIDATE-001; FEATURE="VectorIndex"; ASPECT=QueryMetricMatchesIndex; STATUS=TESTED; TEST=tests/test_knn_metric_mismatch.zig; OWNER=index; UPDATED=2026-08-28
        if (metric != self.metric) return error.VectorMetricMismatch;
```

(b) `src/eval.zig` `parseVectorMetric` — extend the dot arm:

```zig
    if (eqlIgnoreCase(metric_text, "dot") or eqlIgnoreCase(metric_text, "dot_product") or eqlIgnoreCase(metric_text, "inner_product")) return .dot_product;
```

(c) `src/eval.zig` `evalVectorKnn` (~`:2460-2470`): make sure `error.VectorMetricMismatch` from `queryAdvancedVectorIndexWithMetric` is NOT swallowed into `error.InvalidArgs` — let it propagate (adjust the existing `catch`/error-mapping arm that maps dim errors at `:2463`).

(d) `src/server/proto_util.zig` `mapError`: add

```zig
        error.VectorMetricMismatch => .{ .code = "42704", .message = "knn metric does not match the vector index metric; query with the index's metric or recreate the index" },
```

(match the surrounding arm syntax exactly — read the neighbouring arms first).

- [ ] **Step 4: Run tests**

`zig build test-knn-metric-mismatch && zig build test-using-vector-index && zig build test-knn-scan-race` — all green (the scan fallback path takes no index so it is unaffected, but verify).

- [ ] **Step 5: Harness spec**

Create `../geode-test-harness/geodetestlab-cli/specs/knn_metric_mismatch.yml` following the exact shape of `vector_index_errors.yml` (version/name/description with CANARY line, `cli:` block copied verbatim, `invariants`, teardown-first/teardown-last tagged `canary`). Tests: create index `WITH (metric = 'l2')` on a small seeded label; `RETURN knn(...)` with `'cosine'` → `stdout_not_contains: ['"status_class":"00000"']` + `stdout_contains: ['42704']`; with `'l2'` → `stdout_contains: ['"status_class":"00000"']`; a `distance(..., 'inner_product')` success case. Run it: `cd ../geode-test-harness && make test-spec SPEC=geodetestlab-cli/specs/knn_metric_mismatch.yml` (needs `zig build` first so `./zig-out/bin/geode` exists; verify the managed server actually started — the runner false-greens otherwise). Commit the spec in the harness repo: `git -C ../geode-test-harness add geodetestlab-cli/specs/knn_metric_mismatch.yml && git -C ../geode-test-harness commit -m "test: knn metric-mismatch + inner_product parity specs"` (with trailer).

- [ ] **Step 6: Commit (engine repo)**

```bash
git add tests/test_knn_metric_mismatch.zig src/index/advanced_types_index.zig src/eval.zig src/server/proto_util.zig build.zig docs/status.csv
git commit -m "fix(vector): reject knn metric mismatched with index metric; accept inner_product query-side

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `CALL geode.fts.rebuild(index_name)` procedure

The spec's ingestion invariant: "On deployed versions where bulk-MERGE bypasses FTS maintenance, rebuild/backfill the affected index before marking ingestion ready." Today the only rebuild path is `DROP INDEX` + `CREATE INDEX`. Add a first-class mutating procedure that drops the engine, recreates it, and re-runs backfill — also re-arming the label registry after restart.

**Files:**
- Modify: `src/execution/fts_index_ops.zig` (new `pub fn rebuildFulltextIndex`)
- Modify: `src/execution/fts_dispatch.zig` (new arm `geode.fts.rebuild`)
- Modify: `src/execution/procedure_access.zig` (do NOT add to read-only list; add a comment documenting the deliberate omission, mirroring the `geode.ts.insert` comment at `:81-83`)
- Modify: `src/security/geode_auth_lib.zig:103` area (procedure allow-list — add `"geode.fts.rebuild"` alongside `"geode.fts.search"` if that list gates procedure names; read the list's semantics first)
- Test: `tests/test_fts_rebuild.zig` (new), wired as `test-fts-rebuild`

**Interfaces:**
- Consumes: `graph_store.getGlobalAdapter()`, `adapter.getOrCreateGraph`, `mg.fts_adapter`, `fa.dropIndex/createIndex/flush` (`src/storage/fts_storage_adapter.zig:266/174/369`), private `backfillExistingNodes` (same file as the new fn — callable directly), `mg.addFtsLabelIndex` (`src/storage/graph_storage_adapter.zig:1845`), the schema catalog `IndexInfo` (`src/schema/catalog.zig:30-43`; fulltext rows have `index_type` starting with `"fulltext"`, `table_name` = label, `columns` = properties — see how `src/execution.zig:1661-1667` writes it and how `statement_dispatcher.zig:139-193` iterates catalog indexes).
- Produces: `CALL geode.fts.rebuild('<index>')` → one row, columns `index` (String) and `nodes_indexed` (Int). Classified `.mutating` (fail-closed default). Cluster-gated.

- [ ] **Step 1: Write the failing test**

`tests/test_fts_rebuild.zig`:

```zig
test "geode.fts.rebuild reindexes nodes missed by out-of-band writes" {
    // 1. Bootstrap store + create fulltext index on :RebuildDoc(body) via
    //    fts_index_ops.createFulltextIndex (empty label at create time).
    // 2. Insert 3 nodes with label :RebuildDoc and string body WITHOUT going
    //    through the FTS maintenance hook (use adapter.bulkMergeNode* directly,
    //    the exact fast-path writer — signatures at
    //    src/storage/graph_storage_adapter.zig:4227/4379).
    // 3. fts_dispatch.execute("geode.fts.search", ...) → assert 0 rows
    //    (documents the pre-rebuild blind spot).
    // 4. fts_dispatch.execute("geode.fts.rebuild", ...) → assert 1 row,
    //    columns [index, nodes_indexed], nodes_indexed == 3.
    // 5. Search again → 3 rows.
}

test "geode.fts.rebuild on unknown index errors" {
    // expect error (Unsupported or IndexNotFound surface), not empty success.
}
```

- [ ] **Step 2: Wire + run to verify failure**

`zig build test-fts-rebuild` → FAIL with `UnknownProcedure` (the arm doesn't exist).

- [ ] **Step 3: Implement `rebuildFulltextIndex`**

In `src/execution/fts_index_ops.zig`, after `createFulltextIndex`:

```zig
/// Spec geode-vectorization-and-reranking: post-bulk-ingest invariant — rebuild
/// the fulltext engine for `index_name` from current store contents. Resolves
/// the (label, properties) spec from the schema catalog when available (works
/// after restart), falling back to the in-memory label registry. Drops the
/// engine (clearing append-only tombstones), recreates it, re-backfills, and
/// re-arms the label registry so live maintenance resumes.
/// CANARY: REQ=REQ-FTS-REBUILD-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildBackfill; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-28
pub fn rebuildFulltextIndex(
    allocator: std.mem.Allocator,
    catalog: *catalog_mod.Catalog,
    graph_name: []const u8,
    index_name: []const u8,
) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return Error.FulltextUnavailable;
    const mg = adapter.getOrCreateGraph(graph_name) catch return Error.FulltextUnavailable;
    const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;

    // Resolve label + properties: catalog first (survives restart), registry fallback.
    // (Look up the catalog IndexInfo whose .name == index_name and whose
    // index_type starts with "fulltext"; label = table_name, properties = columns.
    // Read src/execution.zig:1661-1667 + catalog.zig for the exact accessor —
    // use the same API statement_dispatcher.zig:139-193 uses to iterate indexes.)
    ...
    // If neither catalog nor registry knows the index: return Error.IndexNotFound.

    fa.dropIndex(index_name) catch |err| switch (err) {
        adapter_mod.Error.IndexNotFound => {}, // engine absent (e.g. post-restart) — fine
        else => return err,
    };
    try fa.createIndex(index_name);
    errdefer fa.dropIndex(index_name) catch {};
    try backfillExistingNodes(allocator, graph_name, index_name, label, properties, fa);
    try mg.addFtsLabelIndex(adapter.allocator, label, index_name, properties); // idempotent re-arm
    fa.flush(index_name) catch |err| {
        log.warn("fulltext rebuild flush failed for '{s}': {}", .{ index_name, err });
    };
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const ids = store.getNodesByLabel(graph_name, label) orelse return 0;
    return @intCast(ids.len);
}
```

The `...` block is the one discovery point: write the real catalog lookup using the accessor found in `statement_dispatcher.zig:139-193`. `catalog_mod` import: mirror how `execution.zig` imports the catalog. If `addFtsLabelIndex` is not idempotent for an existing (label,index) pair (check `graph_storage_adapter.zig:1845-1870` — it uses `getOrPut`), first check for an existing spec via `mg.coveringFtsIndexes(label)` and skip re-adding.

- [ ] **Step 4: Dispatch arm + classification comment + cluster gate**

`src/execution/fts_dispatch.zig` in `execute()`:

```zig
    if (std.mem.eql(u8, proc_name, "geode.fts.rebuild")) {
        return try handleFtsRebuild(allocator, call_stmt, context);
    }
```

`handleFtsRebuild`: parse 1 string-literal arg via the existing `literalString`; `try cluster_mod.gateUnreplicatedWrite();` (add the import mirroring `ts_dispatch.zig`); call `rebuildFulltextIndex(allocator, context.catalog, graph_store.DEFAULT_GRAPH_NAME, index_name)`; build a one-row result with columns `index`/`nodes_indexed` (mirror the two-column construction in `handleFtsSearch`); apply `filterYieldColumns` when `yield_items` set. CANARY `ASPECT=Dispatch` on the arm. In `procedure_access.zig` add next to the `geode.ts.*` comment block:

```zig
        // geode.fts.rebuild is deliberately NOT listed: it drops and rebuilds a
        // fulltext engine (a write) and must classify .mutating (fail-closed).
```

- [ ] **Step 5: Run tests**

`zig build test-fts-rebuild && zig build test-fts-e2e && zig build test-fts-storage-adapter 2>/dev/null; true` (find exact adapter test step name via `grep -n "fts" build.zig | grep test-`). Also `zig build test-cluster-replicable-mutations` (the gate must not break standalone mode — standalone is a no-op).

- [ ] **Step 6: Commit**

```bash
git add tests/test_fts_rebuild.zig src/execution/fts_index_ops.zig src/execution/fts_dispatch.zig src/execution/procedure_access.zig src/security/geode_auth_lib.zig build.zig docs/status.csv
git commit -m "feat(fts): add CALL geode.fts.rebuild(index) backfill procedure

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Bulk-MERGE live FTS maintenance on the connection thread

Close the "Open" known limitation the spec flags: `fts_index_ops.zig:267-271` promises "callers on worker threads … reindex post-bulk on the connection thread instead" but `quic_connection_handler.zig` contains zero FTS references. `executeBulkSimpleMerge` runs ON the connection thread; `maintainFulltextOnWrite` cheap-exits when no FTS index covers the label, so the fix is one call per merged node after apply.

**Files:**
- Modify: `src/server/quic_connection_handler.zig:1067-1330` (`executeBulkSimpleMerge`) and the per-statement batch sibling reached via `matchSimpleNodeMergeSpecStmt` (call site `:1352` — read forward from there to find its apply/executor body and treat it identically)
- Modify: `CLAUDE.md` (Known Limitations — rewrite the bulk-MERGE FTS entry) and `docs/FULLTEXT_SEARCH.md` (same)
- Test: `tests/test_fts_bulk_merge_maintenance.zig` (new), wired as `test-fts-bulk-merge-maintenance`
- Harness spec: `../geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` (new)

**Interfaces:**
- Consumes: `fts_index_ops.maintainFulltextOnWrite(scratch, graph_name, node_id, labels, .create)` (`src/execution/fts_index_ops.zig:283`; import path: check how `crud_operations.zig:1452` imports it and mirror); the node id produced by each apply branch (`node_id_res` in the two direct branches, the group-commit `op.result` struct — read `src/storage/group_commit.zig` `ApplyOp.bulk_merge_node.result` to learn the id field — and the phase-1 hit id).
- Produces: bulk-MERGE'd nodes are searchable via `geode.fts.search` immediately, when an FTS index covers the label.

- [ ] **Step 1: Write the failing test**

`tests/test_fts_bulk_merge_maintenance.zig` — this must drive the REAL fast path. The fast path lives in the QUIC handler, which is heavy to drive in a unit test; instead drive the same primitive sequence the handler runs and assert the CONTRACT at the adapter level, PLUS pin the end-to-end behavior in the harness spec (Step 5, which drives the real wire path):

```zig
test "bulk-merged nodes become searchable without rebuild (maintenance contract)" {
    // 1. Bootstrap store; createFulltextIndex on :BulkDoc(body) (empty label).
    // 2. Simulate the handler's post-apply hook: call adapter.bulkMergeNode
    //    with a reserved id (exactly as quic_connection_handler.zig:1249 does),
    //    then call fts_index_ops.maintainFulltextOnWrite(alloc, graph, id,
    //    &.{"BulkDoc"}, .create) — the call the fix adds.
    // 3. Search → the node is found.
    // 4. Negative control: a second bulkMergeNode WITHOUT the maintenance call
    //    stays invisible (pins that the primitive alone still skips FTS, so the
    //    handler hook is load-bearing).
}
```

- [ ] **Step 2: Wire + run**

`zig build test-fts-bulk-merge-maintenance` — this test PASSES already at the contract level (it calls the hook itself); its value is pinning the contract. The genuinely-failing artifact pre-fix is the harness spec (Step 5) — write it NOW, run it against the unfixed binary, and record the red result in the spec description (`stdout_contains` for the post-fix expectation will fail red). Keep the red evidence.

- [ ] **Step 3: Implement the handler hook**

In `executeBulkSimpleMerge`, capture the merged node id in every branch instead of discarding it (`_ = node_id_res` → `const merged_node_id = node_id_res catch |err| { ...existing error handling... };`; for the group-commit branch read the id out of `op` after `coord.submit` returns — the `.result` field; for the phase-1-hit branch use the already-known id). Then, after the apply succeeds and all locks are RELEASED (after `mut_sample.markLockReleased()` — `maintainFulltextOnWrite` reads the store and must not run under the graph write lock), add ONE call site at the function's post-apply join point:

```zig
    // Spec geode-vectorization-and-reranking + A4b §6: the bulk fast path runs
    // on the connection thread, so live FTS maintenance is safe here and keeps
    // bulk-MERGE'd nodes searchable without a rebuild. Cheap-exits when no
    // fulltext index covers the label. `.create` (not `.update`) mirrors the
    // SET chokepoint (property_mutation.zig:394): engine tombstones are
    // permanent per doc_id, so delete-then-reindex would hide the node.
    // Skipped for a phase-1 hit with no apply_on_match (no data changed).
    // CANARY: REQ=REQ-FTS-BULK-MERGE-LIVE-001; FEATURE="FullText"; ASPECT=BulkMergeConnectionThreadMaintenance; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml; OWNER=fts; UPDATED=2026-08-28
    if (fts_should_maintain) {
        geode.fts_index_ops.maintainFulltextOnWrite(
            eval_arena.allocator(),
            query_graph_name,
            merged_node_id,
            &[_][]const u8{spec.label},
            .create,
        ) catch |err| {
            log.warn("bulk-merge FTS maintenance failed", &.{
                Attr.string("label", spec.label),
                Attr.string("err", @errorName(err)),
            });
        };
    }
```

where `fts_should_maintain` is true for: fresh insert, or hit with `spec.apply_on_match`. Confirm the `geode.fts_index_ops` import path (the handler imports the geode module — `grep -n "const geode" src/server/quic_connection_handler.zig | head -3`; if `fts_index_ops` is not re-exported from the root module, add the re-export where sibling execution modules are re-exported). Apply the same treatment to the batch-mode per-statement sibling (from `:1352`). Error policy: WARN and continue — never fail a committed bulk write on FTS maintenance (matches the "missing graph is a clean no-op" stance), BUT log loudly since silent desync is the very bug being fixed.

- [ ] **Step 4: Run unit tests**

`zig build test-fts-bulk-merge-maintenance && zig build test-fts-e2e && zig build test-bulk-shard-concurrency && zig build test-scan-ingest-race` — all green.

- [ ] **Step 5: Harness spec (the real end-to-end red→green)**

`../geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` (model on `fts_storage_basic.yml`): create fulltext index on `:BulkVisDoc(body)`; run 5 `MERGE (n:BulkVisDoc {k: <i>}) ON CREATE SET n.body = 'searchable text <i>'` statements (this shape matches `matchSimpleNodeMergeSpec` → the fast path); `CALL geode.fts.search('<idx>', 'searchable')` → assert `row_count: 5` / `stdout_contains: ['"status_class":"00000"']`. Also one `geode.fts.rebuild` test (rebuild after the fact still reports `nodes_indexed`). Run: `make test-spec SPEC=geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` — verify the managed server started. Commit in harness repo (with trailer).

- [ ] **Step 6: Update docs + commit**

Rewrite the CLAUDE.md Known Limitations bulk-MERGE FTS entry and the `docs/FULLTEXT_SEARCH.md` "Known limitation" to: live maintenance now covers the bulk-MERGE fast path (connection-thread hook, 2026-08-28); `CALL geode.fts.rebuild(index)` exists for recovery/backfill and post-restart re-arm; note the canary-query ingestion invariant from the spec ("after bulk ingestion, verify FTS visibility with a canary query").

```bash
git add src/server/quic_connection_handler.zig tests/test_fts_bulk_merge_maintenance.zig build.zig CLAUDE.md docs/FULLTEXT_SEARCH.md docs/status.csv
git commit -m "feat(fts): live fulltext maintenance on the bulk-MERGE fast path

Closes the documented bulk-MERGE FTS blind spot (connection-thread hook per
A4b §6); bulk-ingested nodes are searchable without a rebuild.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Per-request read-only enforcement (`ExecuteRequest.read_only`)

The spec's highest-impact finding: "Authorization must be enforced below the LLM… `writes=read_only` does not itself make MCP read-only." The engine already enforces role-based write denial (`quic_connection_handler.zig:6492`, `grpc_server.zig:2173`), but a gateway/orchestrator needs a per-REQUEST hard floor independent of the principal's role. Add `read_only` to `ExecuteRequest` (field 6 — fields 4/5 are live in `schema.zig` even though `geode.proto` is stale) and reject mutating programs when set, in both transports, BEFORE the role gate (and regardless of auth being enabled).

**Files:**
- Modify: `src/proto/schema.zig:90-121` (`ExecuteRequest` + `_desc_table`)
- Modify: `src/proto/geode.proto:100-104` (sync fields 4, 5 AND add 6 — fix the staleness)
- Modify: `src/server/quic_connection_handler.zig` (~`:6492` region, where `program_is_mutating` is already computed at `:6247`)
- Modify: `src/transport/grpc_server.zig` (~`:2166` region)
- Test: `tests/test_read_only_execute.zig` (new), wired as `test-read-only-execute`

**Interfaces:**
- Consumes: `query_traits.isMutatingProgram` (already computed on both paths), `sendExecuteError(gpa, stream, code, message, ...)` (QUIC), the gRPC error-send used by the `42501` arm at `grpc_server.zig:2173-2185`.
- Produces: `ExecuteRequest.read_only: bool = false` at field 6; wire behavior: mutating program + `read_only=true` → GQLSTATE `42501`, message `"Read-only request: data modification rejected"`. Task 6 and the geode-ui follow-up consume this field.

- [ ] **Step 1: Write the failing test**

`tests/test_read_only_execute.zig`:

```zig
test "ExecuteRequest read_only round-trips through protobuf encode/decode" {
    // Build an ExecuteRequest{ .query = "CREATE (n:X)", .read_only = true },
    // encode + decode with the same protobuf API the transports use (find the
    // encode/decode helpers via grep -n "ExecuteRequest" src/proto/*.zig and
    // how tests/test_transport_parity.zig (or the grpc raw-io test) round-trips
    // messages), assert read_only survives and defaults to false when absent.
}

test "read-only classification refuses mutating programs" {
    // Parse "MERGE (n:X {k:1})" and "RETURN 1" with the real parser;
    // assert query_traits.isMutatingProgram says true/false respectively —
    // pins the exact classifier the gate uses (fail-open caveat for SHOW/FOR
    // is the classifier's documented scope; the gate inherits it).
}
```

- [ ] **Step 2: Wire + run to verify failure**

`zig build test-read-only-execute` → FAIL: `ExecuteRequest` has no field `read_only`.

- [ ] **Step 3: Implement**

(a) `src/proto/schema.zig` — add to `ExecuteRequest`:

```zig
    // Spec geode-vectorization-and-reranking: per-request hard read-only floor,
    // independent of the principal's role ("authorization below the LLM").
    // CANARY: REQ=REQ-EXEC-READ-ONLY-REQUEST-001; FEATURE="ReadOnlyExecute"; ASPECT=WireField; STATUS=TESTED; TEST=tests/test_read_only_execute.zig; OWNER=engine; UPDATED=2026-08-28
    read_only: bool = false,
```

and `.read_only = fd(6, .{ .scalar = .bool }),` in `_desc_table`.

(b) `src/proto/geode.proto` — replace the stale `ExecuteRequest` with the truthful contract:

```proto
message ExecuteRequest {
  string session_id = 1;
  string query = 2;
  repeated Param params = 3;
  bytes principal_envelope_bytes = 4; // GPS wire principal (federation-trusted only)
  string idempotency_key = 5;         // RC-3 write dedup
  bool read_only = 6;                 // reject mutating statements when set
}
```

(c) QUIC — in the region where `is_mutation` is computed (`:6492`), BEFORE the `state.authenticated_role` wrapper (so it applies even with auth disabled):

```zig
            // CANARY: REQ=REQ-EXEC-READ-ONLY-REQUEST-001; FEATURE="ReadOnlyExecute"; ASPECT=QuicGate; STATUS=TESTED; TEST=tests/test_read_only_execute.zig; OWNER=engine; UPDATED=2026-08-28
            if (exec_req.read_only and program_is_mutating) {
                try sendExecuteError(gpa, stream, "42501", "Read-only request: data modification rejected", &.{}, &.{});
                return;
            }
```

(d) gRPC — same two lines adapted to the local variable names/error-send at `grpc_server.zig:2166-2185` (read the surrounding code; the mutating flag there is `is_mutation`'s source expression at `:2166`).

- [ ] **Step 4: Run tests**

`zig build test-read-only-execute && zig build test-transport-parity && zig build test-grpc-raw-io` — green. If `test-transport-parity` asserts an exhaustive field list for `ExecuteRequest`, extend the parity expectation there (that is the test doing its job).

- [ ] **Step 5: CLI/E2E reach check (conditional)**

Check whether the in-repo CLI builds its own `ExecuteRequest` (`grep -rn "ExecuteRequest" src/cli/ src/client* 2>/dev/null | head`). If the CLI constructs it in-repo: add a `--read-only` flag to `geode query` that sets field 6, plus a harness spec `read_only_execute.yml` (mutating query with `--read-only` → `stdout_contains: ['42501']`; `RETURN 1` with `--read-only` → success), run it, commit in the harness repo. If the CLI goes through the external `geode-client-zig` package: skip the flag, and note in the commit body that client-side emission lands with the next `geode-client-zig` bump (the server decode is forward-compatible either way).

- [ ] **Step 6: Commit**

```bash
git add src/proto/schema.zig src/proto/geode.proto src/server/quic_connection_handler.zig src/transport/grpc_server.zig tests/test_read_only_execute.zig build.zig docs/status.csv
git commit -m "feat(transport): per-request read_only floor on ExecuteRequest (field 6)

Also syncs the stale geode.proto ExecuteRequest with live fields 4/5.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: MCP server read-only mode

The spec: with a single MCP `query` tool, "a malicious retrieved document… could cause a mutating GQL statement to be submitted". Geode's own MCP server (`src/mcp/server.zig`) has no read-only option; add one that classifies statements in-process (parser + `query_traits`) and refuses mutating programs before they reach the wire — defense-in-depth above the Task 5 engine floor.

**Files:**
- Modify: `src/mcp/server.zig:178-203` (`Options` — add `read_only: bool = false`; thread it to the tool layer the same way `geode_endpoint` is threaded)
- Modify: `src/mcp/tools.zig` (`executeQuery` — pre-flight classification when read-only)
- Test: extend the existing MCP test that drives `mcp.Server.processMessage` (`tests/test_gap0516_mcp_capabilities.zig` — `zig build test-gap0516`) with a new sibling test file `tests/test_mcp_read_only.zig` wired as `test-mcp-read-only`

**Interfaces:**
- Consumes: the in-process parser already used by the `validate` tool (find it: `grep -n "validateGql\|parse" src/mcp/tools.zig` and follow the import); `query_traits.isMutatingProgram` (`src/query/query_traits.zig:303`).
- Produces: `Options.read_only`; when set, a mutating `query` tool call returns an MCP tool result with `isError: true` and message `"read-only MCP server: data modification rejected"` (use the existing `formatErrorResponse`). Statements that fail to parse are REFUSED in read-only mode (fail-closed: unparseable ⇒ unclassifiable ⇒ reject).

- [ ] **Step 1: Write the failing test**

`tests/test_mcp_read_only.zig` (model message-driving on `test_gap0516_mcp_capabilities.zig`):

```zig
test "read-only MCP refuses mutating query tool calls before the wire" {
    // Server options .read_only = true, endpoint pointing NOWHERE ("127.0.0.1:1")
    // — proves refusal happens client-side, not via server error:
    // tools/call {name:"query", arguments:{query:"CREATE (n:X)"}}
    // → result carries isError:true + "read-only".
}
test "read-only MCP still allows reads to attempt the wire" {
    // Same options; RETURN 1 must NOT be refused by the read-only gate (it will
    // fail with a connection error against the dead endpoint — assert the error
    // is NOT the read-only message).
}
test "read-only MCP refuses unparseable statements (fail-closed)" { ... }
```

- [ ] **Step 2: Wire + run to verify failure**

`zig build test-mcp-read-only` → FAIL: `Options` has no `read_only` field.

- [ ] **Step 3: Implement**

Thread `read_only` from `Options` into the tool dispatch (same plumbing as `geode_endpoint` — follow it through `server.zig` → `tools.zig` call sites). In `executeQuery`, before `GeodeClient.init`:

```zig
    // Spec geode-vectorization-and-reranking: instruction boundary — retrieved
    // text must not be able to mutate through the single query tool. Fail
    // closed: unparseable input is unclassifiable and is rejected in
    // read-only mode. Engine-side ExecuteRequest.read_only (field 6) is the
    // hard floor once geode-client-zig emits it; this gate is the MCP-layer
    // belt over those suspenders.
    // CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=QueryToolGate; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
    if (read_only) {
        const verdict = classifyForReadOnly(allocator, query); // parse + isMutatingProgram
        if (verdict != .read_ok) {
            return try formatErrorResponse(allocator, "read-only MCP server: data modification rejected");
        }
    }
```

`classifyForReadOnly` is a small private helper in `tools.zig` using the same parser entry the `validate` tool uses; return `.read_ok` only when the parse succeeds AND `!isMutatingProgram`. Also document the fail-open caveat of the classifier (SHOW/admin statements classify read-only — acceptable here because the engine's own admin gates still apply server-side).

- [ ] **Step 4: Run tests**

`zig build test-mcp-read-only && zig build test-gap0516` — green.

- [ ] **Step 5: Commit**

```bash
git add src/mcp/server.zig src/mcp/tools.zig tests/test_mcp_read_only.zig build.zig docs/status.csv
git commit -m "feat(mcp): read-only server mode gating the query tool pre-wire

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Truthful, discovery-grade `SHOW CAPABILITIES`

The spec's capability-discovery requirement ("Determine the deployed version and available capabilities from trusted runtime metadata or supported discovery interfaces") needs a truthful surface. Today `executeShowCapabilities` (`src/execution/admin_ddl.zig:167-196`) is a hardcoded 9-row admin list, and `policy_ddl=false` is stale.

**Files:**
- Modify: `src/execution/admin_ddl.zig:167-196`
- Test: `tests/test_show_capabilities.zig` (new), wired as `test-show-capabilities`
- Harness spec: `../geode-test-harness/geodetestlab-cli/specs/show_capabilities_discovery.yml` (new)

**Interfaces:**
- Consumes: the existing `Feature` row shape (`name`, `supported`) — geode-ui consumes `admin_writable`; every existing row name MUST keep its name and only become MORE truthful.
- Produces: the 9 existing rows (with `policy_ddl` flipped to `true`) plus these new rows, all `true`: `vector_knn`, `vector_index_metrics`, `knn_metric_validation`, `fts_search`, `fts_phrase_proximity`, `fts_rebuild`, `fts_bulk_merge_live_maintenance`, `fts_row_visibility`, `ts_procedures`, `read_only_execute`, `mcp_read_only`, `explain`, `profile`, `explain_policy`.

- [ ] **Step 1: Write the failing test**

`tests/test_show_capabilities.zig`: execute `SHOW CAPABILITIES` through the real statement dispatch (mirror however an existing admin_ddl test drives it — `grep -rn "executeShowCapabilities\|SHOW CAPABILITIES" tests/ src/execution/*.zig`); assert (a) all 9 legacy row names still present, (b) `policy_ddl` row reports `true`, (c) each new row name present with `true`, (d) row count equals the expected total exactly (so stale rows can't silently linger).

- [ ] **Step 2: Wire + run to verify failure** — `zig build test-show-capabilities` → FAIL (missing rows).

- [ ] **Step 3: Implement** — extend the `features` array in `executeShowCapabilities`; flip `policy_ddl` to `true` with a comment citing GAP-0858 (durable policy DDL persistence landed; the residual is the manual GQL→bytecode expression path, noted in CLAUDE.md). Add a CANARY (`REQ=REQ-CAPABILITY-DISCOVERY-001; FEATURE="SHOW CAPABILITIES"; ASPECT=DiscoveryRows`). Keep it a static truthful snapshot — that is this surface's documented design.

- [ ] **Step 4: Run** — `zig build test-show-capabilities` green; also grep geode-ui expectations are unaffected: rows only added, none renamed.

- [ ] **Step 5: Harness spec** — `show_capabilities_discovery.yml`: one test running `SHOW CAPABILITIES` asserting `stdout_contains` for `fts_rebuild`, `read_only_execute`, `knn_metric_validation`, and `"status_class":"00000"`; one running `SHOW VERSION` asserting success (the spec's version-discovery pairing). Run + commit in harness repo.

- [ ] **Step 6: Commit**

```bash
git add src/execution/admin_ddl.zig tests/test_show_capabilities.zig build.zig docs/status.csv
git commit -m "feat(discovery): truthful SHOW CAPABILITIES rows for RAG capability discovery

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Docs artifacts — production orchestrator prompt + RAG integration guide

The remaining spec recommendations are orchestrator-level (budgets, RRF policy, query-scope classification, packed-evidence metrics, embedding_space_id, staged writeback, tenant-aware caching, telemetry classification, dependency closure, edge provenance, global-GraphRAG scoping). They are implemented as documented contracts: the spec's own "Recommended production prompt" v2, corrected to this engine's REAL surface, plus an integration guide.

**Files:**
- Create: `docs/rag/GEODE_RAG_ORCHESTRATOR_PROMPT.md`
- Create: `docs/rag/RAG_INTEGRATION_GUIDE.md`
- Modify: `specs/geode-vectorization-and-reranking.md` (append a short "Implementation status (2026-08-28)" footer table mapping each recommendation → task/commit/doc)
- Modify: `docs/FULLTEXT_SEARCH.md` (cross-link the guide; done partly in Task 4)

**Interfaces:**
- Consumes: the spec's §"Recommended production prompt" (lines 754-1092) verbatim as the base text; the real engine surface: `knn(prop, qvec, k, metric)` (arity-4 mandatory), `vector_l2`/`vector_cosine` (SIMILARITY, 1=identical)/`vector_dot` (Int-truncated)/`distance(v1,v2[,metric])`/`similarity(...)`, metrics `l2|euclidean|cosine|dot|dot_product|inner_product`, `CALL geode.fts.search|phrase|proximity|rebuild`, `SHOW CAPABILITIES|VERSION|FUNCTIONS|PROCEDURES|INDEXES`, `EXPLAIN` / `PROFILE` / `EXPLAIN POLICY FOR`, `ExecuteRequest.read_only`, roles `ReadOnly`/`User` (Read-only), MCP `read_only` option.
- Produces: two standalone docs an orchestrator team can deploy from.

- [ ] **Step 1: Write `GEODE_RAG_ORCHESTRATOR_PROMPT.md`**

Start from the spec's v2 prompt text and make ONLY these corrections/additions (a header table must list them as deltas against the spec):
1. Replace `vector_distance_cosine/l2/dot` references with the real function table above, including the similarity-vs-distance semantics of `vector_cosine` and the truncating `vector_dot`.
2. GEODE SEARCH → Vectors section: add "knn requires all four arguments; the query metric MUST equal the index metric (the engine rejects mismatches with GQLSTATE 42704); `inner_product` is a synonym of `dot_product`."
3. GEODE SEARCH → Full text: note results are tenant/RLS row-visibility filtered by the engine (Task 1), the bulk-MERGE live-maintenance guarantee + `CALL geode.fts.rebuild(index)` recovery invariant, and the canary-query check after bulk ingestion.
4. CAPABILITY DISCOVERY: name the concrete surfaces — `SHOW VERSION`, `SHOW CAPABILITIES`, `SHOW FUNCTIONS/PROCEDURES/INDEXES`, HELLO capabilities.
5. TRUST BOUNDARIES: "In read_only mode use a `ReadOnly`-role principal (engine-enforced 42501 write denial) and set `ExecuteRequest.read_only`; Geode's MCP server additionally supports a read_only option."
Everything else in the v2 text carries over unchanged (budgets-as-ceilings, RRF default, query_scope classification, follow-up rounds, reranking scoring, context packing, answer behavior, writeback, query safety, observability including the two zero-rate security SLOs, final output contract).

- [ ] **Step 2: Write `RAG_INTEGRATION_GUIDE.md`**

Sections (each distilled from the spec with the engine mapped in — cite spec section names):
1. **Security boundaries** — the four independent boundaries (identity/query/data/instruction); what the engine enforces (role gate, `read_only` field, FTS row visibility, procedure classification fail-closed) vs what the app must enforce (scope provenance re-checks at expansion/rerank/pack/cache/log, tool-invocation independence from retrieved prose).
2. **embedding_space_id** — the immutable identity formula (hash of model, model_version, dimensions, preprocessing_version, input_template_version, normalization_policy, modality); require `candidate.embedding_space_id == query.embedding_space_id`; engine reality: dimension is inferred from the first committed vector and enforced on write/search, metric persists on the index, model/normalization metadata is the APP's to store (recommend a `__embedding_space` node per space + a property on each embedded node).
3. **Staged idempotent writeback** — the spec's state machine verbatim (immutable version + deterministic facts + `embedding_state=pending` in one DB transaction → worker → attach → validate → `retrieval_state=ready`), with GQL sketches using MERGE + properties; explicitly "never one transaction across parse/embed/index/cache".
4. **Tenant-aware caching** — the cache-key contract list verbatim.
5. **Telemetry classification** — telemetry inherits request classification; the two security SLOs (unauthorized-evidence exposure = 0, unauthorized-write execution = 0).
6. **Retrieval budgets and scope classification** — ceilings-not-constants; `query_scope = exact|local|multi_hop|global`; global questions require a community/summary layer the app must build (the engine does not provide one — state the limitation, per the spec).
7. **Code-graph conventions** — dependency-closure mode, node types (`BuildTarget`, `ConfigKey`, `Endpoint`, `Schema`, `Migration`, `GeneratedArtifact` as plain labels), edge provenance fields (`edge.confidence`, `edge.provenance`, `edge.extraction_method`, `edge.observed_at_version`), static-over-inferred precedence for blast radius; commit-based immutable identity (repo+commit+path+symbol+content_hash).
8. **FTS + vector operational notes** — bulk-ingest canary query, `geode.fts.rebuild`, knn scan-fallback bounded-cache incompleteness caveat (`eval.zig` documents residency-limited scans), `EXPLAIN`/`PROFILE` verification habit.

- [ ] **Step 3: Append the implementation-status footer to the spec** — a table: recommendation → where implemented (task commit / doc section / "app-level, documented in guide §N" / "out of scope: global-GraphRAG community layer, per spec's own do-not-pay-cost guidance").

- [ ] **Step 4: Verify docs build cleanly** — run `make pre-commit` and fix any NEW markdownlint findings in the two new files (the known-red legacy files stay red; your new files must be clean).

- [ ] **Step 5: Commit**

```bash
git add docs/rag/GEODE_RAG_ORCHESTRATOR_PROMPT.md docs/rag/RAG_INTEGRATION_GUIDE.md specs/geode-vectorization-and-reranking.md docs/FULLTEXT_SEARCH.md
git commit -m "docs(rag): production orchestrator prompt v2 + RAG integration guide

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Full validation sweep

**Files:** none new.

- [ ] **Step 1:** `make fmt` — no residual diff.
- [ ] **Step 2:** All targeted steps green, run serially: `test-fts-authorization`, `test-knn-metric-mismatch`, `test-fts-rebuild`, `test-fts-bulk-merge-maintenance`, `test-read-only-execute`, `test-mcp-read-only`, `test-show-capabilities`, plus regression neighbours: `test-fts-e2e`, `test-using-vector-index`, `test-knn-scan-race`, `test-transport-parity`, `test-grpc-raw-io`, `test-gap0516`, `test-auth-rate-limiter`, `test-scan-ingest-race`, `test-cluster-replicable-mutations`.
- [ ] **Step 3:** Full suite, all four shards: `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N` for N=0..3 (known flakes → verify serially; `test-gap0866` pre-broken).
- [ ] **Step 4:** Harness: run the three new specs plus the FTS/vector neighbourhood: `fts_storage_basic.yml`, `fulltext_search_basic.yml`, `vector_index_errors.yml`, `vector_hnsw_comprehensive.yml`, `authn_rate_limiter.yml` — each via `make test-spec SPEC=...`, confirming the managed server starts each time.
- [ ] **Step 5:** `make pre-commit` — only the four known-red hooks red.
- [ ] **Step 6:** `git status` clean in BOTH repos; every commit made; report results. Do not push (orchestrator handles pushes).

---

## Out of scope (tracked, deliberate)

- **geode-ui adoption** (`QueryReq.read_only` → engine field 6 threading via geode-client-go; MCP-side discovery tool): separate plan in the geode-ui repo — the engine contract it consumes is produced by Task 5 and documented in Task 8.
- **`geode-client-zig` emission of ExecuteRequest fields 4/6**: external package bump; server decode is forward-compatible.
- **Global-GraphRAG community/summary layer**: the spec itself says add only when the deployment needs corpus-wide sensemaking; documented as a limitation in the guide.
- **knn bounded-cache scan completeness** (resident-only brute-force scan): pre-existing, documented caveat; separate ticket.
