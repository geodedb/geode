# Final-Review Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every follow-up item triaged by the 2026-08-28 RAG-orchestrator final whole-branch review — PROFILE-path RLS **and tenant** fail-open, the `geode.fts.rebuild` drop→create window, a newly discovered `dropIndex` UAF, the vendored `mcp` callTool leak (upstream fix + pin bump), `nodes_indexed` accuracy, the resident-only maintenance skip, status.csv duplicate-row ambiguity, and a harness capture/compare facility that finally pins BM25 score stability over the wire.

**Architecture:** Small, independently testable fixes following existing repo conventions (thread-local context choke point, brief `std.Io.Mutex` registry locks, CANARY governance). One fix is upstream (`devnw/zig/mcp` v0.1.12 + re-pin). Security fixes are fail-closed and land first.

**Tech Stack:** Zig 0.16 (engine), Python (tools/status_generate.py, harness runner), YAML harness specs in `../geode-test-harness` (separate git repo — commit there separately), upstream Zig lib clone at `~/src/gl/gitlab.com/devnw/zig/mcp` (relative to the sandbox home — verify with `ls`).

## Global Constraints

- Repo root: `/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode` (main branch, direct commits on main). Do NOT push — the orchestrator pushes at the end (geode pre-push hooks run a long validation; pushes are slow).
- Zig 0.16; `make fmt` before every commit. Regenerated `docs/status.csv` goes in the same commit when the pre-commit hook changes it.
- CANARY markers on every new implementation site: `// CANARY: REQ=<id>; FEATURE="<quoted>"; ASPECT=<CamelCase>; STATUS=TESTED; TEST=<path>; OWNER=<team>; UPDATED=2026-08-29`. `TEST=` required for `STATUS=TESTED`.
- NO MOCKS, NO SIMULATION: tests drive real store/adapter/executor/dispatch paths.
- Harness specs: assert on `"status_class"` in `stdout_contains`/`stdout_not_contains`, never on `exit_code`; teardown-first AND teardown-last tests tagged `canary` (defensive `DROP INDEX IF EXISTS` shape).
- Harness runs need `zig build` first so `./zig-out/bin/geode` exists; verify the managed server actually started (the runner can false-green).
- Commit messages: conventional (`fix:`/`feat:`/`test:`/`chore:`/`docs:`), ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Known-red pre-existing: `test-quic-condition-cadence` (6 QUIC-internal string-pin failures), markdownlint legacy files (ENTERPRISE_GAPS.md + docs/bugs/*.md), hadolint, goreleaser check, detect-diamond-deps. `test-gap0866` pre-broken (module wiring). Known flaky parallel-shard tests (verify serially before blaming): `test_edge_popular_parent_throughput`, `test_match_set_label_scan_regression`, `test_where_scan_writer_progress`.
- Full-suite gate: `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N` for N=0..3.
- Line numbers cited below were verified 2026-08-29 but may drift a few lines — anchor by symbol name, not raw number.

---

### Task 1: PROFILE-path RLS + tenant fail-open (security, highest priority)

`planned_read_runtime.executeProfiledIfSupported` (src/execution/planned_read_runtime.zig:434) is the single choke point for `PROFILE <Query>` on QUIC (quic_connection_handler.zig:7171), gRPC (grpc_server.zig:2366), and CLI (statement_handlers.zig:1138). It never pushes the thread-local active `ExecutionContext` that `passesRLSFilter`/`passesRLSExprFilter` AND `getSessionTenantFilter` (src/execution/match_operations.zig:173-176) read — so under PROFILE, RLS **and tenant isolation** both fail open (a null active context means "allow all tenants", match_operations.zig:222-227). Normal execution pushes it in `executeQueryWithContext` (src/execution/query_execution.zig:1556-1559). EXPLAIN never executes rows (verified: quic_connection_handler.zig:7136-7161 only builds plans) — no EXPLAIN-side change needed.

**Files:**
- Modify: `src/execution/planned_read_runtime.zig:434` (`executeProfiledIfSupported`)
- Test: `tests/test_profile_rls_tenant.zig` (new), wired into `build.zig` as `test-profile-rls-tenant`

**Interfaces:**
- Consumes: `execution.pushActiveContext`/`popActiveContext` (src/execution.zig:582-596; `execution` already imported in planned_read_runtime.zig line ~5); the test-harness patterns in `tests/test_fts_authorization.zig` (Harness struct, per-block push/pop, :58-104) and `tests/test_rls_expr_engine_wiring.zig` (:244-263, `rls_types.setGlobalRLSFilterEngine`).
- Produces: PROFILE row results identical to plain MATCH results under any tenant/RLS scope. No signature changes.

- [ ] **Step 1: Write the failing test**

Create `tests/test_profile_rls_tenant.zig`. Model store/context bootstrap on `tests/test_fts_authorization.zig`'s Harness (read it first). Three tests:

```zig
// CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=TenantScopedProfile; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
test "PROFILE respects tenant scope like plain MATCH" {
    // 1. Bootstrap global store; create two :ProfDoc nodes, one tenant_a, one
    //    tenant_b (same store API + tenant_id pattern as test_fts_authorization.zig).
    // 2. Build ExecutionContext with .tenant_id = "tenant_a". Do NOT
    //    pushActiveContext manually — the point is that the PROFILE path must
    //    push it itself.
    // 3. Execute "PROFILE MATCH (n:ProfDoc) RETURN id(n)" via
    //    execution.executeStatementWithContext (statement_handlers routes
    //    .profile → executeProfile → executeProfiledIfSupported — confirm the
    //    exact entry by reading statement_handlers.zig:1134-1153; if the CLI
    //    dispatcher entry differs, call planned_read_runtime.executeProfiledIfSupported
    //    directly with the parsed Query, which is the choke point under test).
    // 4. Assert exactly 1 data row (tenant_a's node only) — pre-fix this
    //    returns 2 rows (fail-open leak reproduced).
    // 5. Control: plain "MATCH (n:ProfDoc) RETURN id(n)" through
    //    executeStatementWithContext with the same ctx returns 1 row.
}

test "PROFILE respects RLS label deny like plain MATCH" {
    // Install the label-deny RLS engine for :ProfDoc for user "bob" exactly as
    // tests/test_rls_expr_engine_wiring.zig does (setGlobalRLSFilterEngine +
    // defer clear), ctx.user = "bob", no manual push. PROFILE MATCH → 0 data
    // rows. Clear engine → rows return.
}

test "PROFILE with null tenant still returns all rows (admin scope)" {
    // ctx.tenant_id = null → PROFILE returns both nodes (no over-blocking).
}
```

Write REAL code following those recipe comments with the concrete APIs from the two referenced test files. NOTE: PROFILE result rows may carry profiling metadata rows in addition to data rows — read how `tests/test_gap0868_profile_timing.zig` distinguishes data rows from timing rows and count data rows the same way.

- [ ] **Step 2: Wire and run to verify it fails**

Wire `test-profile-rls-tenant` in `build.zig`: copy the `test-fts-authorization` block, rename, root `tests/test_profile_rls_tenant.zig`, `shardDep(..., 1, ...)`. Run: `zig build test-profile-rls-tenant`. Expected: tests 1 and 2 FAIL (2 rows / non-zero rows — the leak), test 3 passes.

- [ ] **Step 3: Implement the two-line fix**

In `src/execution/planned_read_runtime.zig`, `executeProfiledIfSupported`, first statements of the body (before `buildPlanIfSupported`):

```zig
    // The profiled execution paths (storage-native fast path AND
    // executeLegacyProfiled) bypass executeQueryWithContext, which is the
    // choke point that normally installs the thread-local active context read
    // by passesRLSFilter/passesRLSExprFilter and getSessionTenantFilter.
    // Without this push, PROFILE fails open for both RLS and tenant scoping.
    // Nested push (normal path already pushed) is safe: save-prev/restore-prev.
    // CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=ActiveContextPush; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
    const prev_ctx = execution.pushActiveContext(&context);
    defer execution.popActiveContext(prev_ctx);
```

(`context` is a by-value parameter; taking its address is the same lifetime pattern as `executeQueryWithContext`. `defer` — not `errdefer` — because the pop must run on success too.)

- [ ] **Step 4: Run tests to verify pass**

`zig build test-profile-rls-tenant && zig build test-gap0868 2>/dev/null || true` — find the exact profile-timing step name via `grep -n "gap0868" build.zig` and run it; also `zig build test-rls-expr-engine-wiring` (exact name via `grep -n "rls_expr" build.zig`) and `zig build test-gap0509` (exact name via `grep -n "gap0509" build.zig`). All green.

- [ ] **Step 5: Commit**

```bash
git add tests/test_profile_rls_tenant.zig src/execution/planned_read_runtime.zig build.zig docs/status.csv
git commit -m "fix(security): push active context in PROFILE execution path

PROFILE of Query shapes (QUIC/gRPC/CLI all funnel through
planned_read_runtime.executeProfiledIfSupported) never installed the
thread-local ExecutionContext, so RLS label/expression filters AND the
session tenant filter both failed open under PROFILE. Two-line push/pop
mirroring executeQueryWithContext closes both holes at the choke point.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `fts_storage_adapter.dropIndex` UAF vs in-flight writers (new discovery)

`dropIndex` (src/storage/fts_storage_adapter.zig:266-287) removes the engine from the registry under `mu`, then calls `ie.engine.flush()`/`deinit()` WITHOUT acquiring `ie.write_mu` — racing a writer thread that already passed `requireIndex` and holds (or is about to hold) `write_mu` inside `indexNode`/`indexNodeBatch`/`deleteNode`/`flush` (:320-376). That is a use-after-free on the engine.

**Files:**
- Modify: `src/storage/fts_storage_adapter.zig` (`dropIndex`)
- Test: extend `tests/test_fts_storage_adapter.zig` (find its exact build step via `grep -n "fts_storage_adapter\|fts-storage-adapter" build.zig`)

**Interfaces:**
- Consumes: existing `IndexEngine.write_mu: std.Io.Mutex` (:93), `mu` registry mutex (:84).
- Produces: `dropIndex` drains in-flight writers before engine teardown. No signature change.

- [ ] **Step 1: Write the failing (racing) test**

Add to `tests/test_fts_storage_adapter.zig` a best-effort race regression modeled on the repo's existing thread-race tests (read `tests/test_scan_ingest_race.zig` for the spawn/join idiom):

```zig
// CANARY: REQ=REQ-FTS-DROP-WRITER-RACE-001; FEATURE="FullText"; ASPECT=DropDrainsWriters; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=fts; UPDATED=2026-08-29
test "dropIndex drains in-flight writers instead of freeing under them" {
    // 1. Create index; spawn a writer thread that loops indexNode(doc_i, text)
    //    for ~200 iterations (ignore Error.IndexNotFound once drop lands —
    //    that error is the CORRECT post-drop outcome).
    // 2. Main thread sleeps ~5ms then calls dropIndex.
    // 3. Join writer. Success criterion: no crash/UAF (the test binary
    //    surviving IS the assertion) and dropIndex returned success.
    // 4. Repeat the whole cycle 20x to widen the race window.
}
```

- [ ] **Step 2: Run to verify current behavior**

`zig build <adapter-test-step>` — pre-fix this may crash, hang, or pass by luck (races are probabilistic). Record what happened; a clean pass pre-fix does NOT invalidate the fix (the lock contract violation is proven by reading :266-287 vs :320-376). Do not spin the loop count higher than 20x cycles chasing a deterministic crash.

- [ ] **Step 3: Implement**

In `dropIndex`: after removing the entry from the map under `mu` (so no NEW writer can `requireIndex` it), acquire `ie.write_mu` before teardown:

```zig
        // Drain any in-flight writer before tearing the engine down: writers
        // acquire write_mu inside indexNode/indexNodeBatch/deleteNode/flush,
        // and requireIndex can no longer hand out this engine (removed from
        // the map above). Without this, deinit races a mid-write thread (UAF).
        // CANARY: REQ=REQ-FTS-DROP-WRITER-RACE-001; FEATURE="FullText"; ASPECT=DropDrainsWriters; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=fts; UPDATED=2026-08-29
        ie.write_mu.lock();
        ie.write_mu.unlock();
        ie.engine.flush() catch |err| { ... existing error handling ... };
        ie.engine.deinit();
```

Read the actual current teardown lines first and adapt (keep existing flush error handling verbatim). A writer that acquired `ie` from the map BEFORE removal but has not yet locked `write_mu` will lock it after we unlock — it then writes into a deinit'd engine. To close that tail: hold `write_mu` ACROSS flush+deinit (lock, flush, deinit, then unlock is unsafe if the mutex lives inside the freed struct — check where `IndexEngine` memory is destroyed; if `destroy(ie)` frees the mutex itself, instead add a `dropped: bool` flag set under `write_mu` and make each write path re-check `dropped` after acquiring `write_mu`, returning `Error.IndexNotFound`; destroy the struct only after the drain lock/unlock). Choose the variant the actual ownership allows and explain it in a comment — the invariant to deliver: **no thread can touch `ie.engine` after `deinit`, and no write path can UAF the mutex**. If `IndexEngine` destruction is deferred/arena-owned, say so in the commit body.

- [ ] **Step 4: Run tests**

`zig build <adapter-test-step> && zig build test-fts-e2e && zig build test-fts-rebuild && zig build test-fts-bulk-merge-maintenance` — all green; race test survives 20 cycles.

- [ ] **Step 5: Commit**

```bash
git add src/storage/fts_storage_adapter.zig tests/test_fts_storage_adapter.zig docs/status.csv
git commit -m "fix(fts): drain in-flight writers in dropIndex before engine teardown

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `geode.fts.rebuild` drop→create window — pending-queue rebuild

During `rebuildFulltextIndex` (src/execution/fts_index_ops.zig:192-206) the label registry stays armed the whole time, so concurrent live maintenance either (a) hits the missing engine during the drop→create gap → `Error.IndexNotFound` swallowed by every caller (silent index desync), or (b) lands after `createIndex` but before backfill's store snapshot → the backfill indexes the same node again (append-only engine → duplicate postings).

Design (fits the existing brief-mutex registry conventions): a per-index-name **rebuilding flag + pending node-id set** in the fts adapter that survives the engine's absence. Writers observing the flag queue the node id instead of writing; the rebuild drains `pending \ backfill-snapshot` with `.create` after backfill.

**Files:**
- Modify: `src/storage/fts_storage_adapter.zig` (rebuild-state registry + 3 pub fns)
- Modify: `src/execution/fts_index_ops.zig` (`maintainFulltextOnWrite` queue check; `rebuildFulltextIndex` orchestration)
- Test: extend `tests/test_fts_rebuild.zig`

**Interfaces:**
- Consumes: adapter `mu` mutex pattern (:84), `backfillExistingNodes` (fts_index_ops.zig:238-315), Task 4's count return if Task 4 landed first (rebase on it; otherwise keep `!void` and let Task 4 adjust).
- Produces (in `fts_storage_adapter.zig`):
  - `pub fn beginRebuild(self: *Adapter, index_name: []const u8) !void` — registers an empty pending set for the name (errors if already rebuilding: `Error.RebuildInProgress`, add to the adapter `Error` set).
  - `pub fn noteWriteDuringRebuild(self: *Adapter, index_name: []const u8, node_id: u64) bool` — if the name is rebuilding, append node_id to its pending set (dedup via hash set) and return `true` (caller must then SKIP the engine write); returns `false` when not rebuilding.
  - `pub fn endRebuild(self: *Adapter, index_name: []const u8, allocator: std.mem.Allocator) []u64` (or an owned slice/ArrayList — pick the idiomatic shape) — atomically clears the flag and returns the drained pending ids. After this returns, `noteWriteDuringRebuild` returns `false` again.
  All three take the registry `mu` briefly; the pending set is a `std.AutoHashMap(u64, void)` keyed by name in a `std.StringHashMap`.

- [ ] **Step 1: Write the failing test**

Extend `tests/test_fts_rebuild.zig`:

```zig
// CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=ConcurrentWriteQueued; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
test "write during rebuild window is queued, indexed exactly once" {
    // 1. Bootstrap index on :RbwDoc(body) with 2 existing nodes; verify both
    //    searchable.
    // 2. Simulate the window: call adapter.beginRebuild("<idx>") directly,
    //    then run maintainFulltextOnWrite for a NEW node id 3 (create it in
    //    the store first) — assert it does NOT error and the engine did not
    //    receive it yet (search for its unique term → 0 rows... note the
    //    engine still exists pre-drop in this simulation; to make the
    //    assertion honest, ALSO run the real rebuildFulltextIndex
    //    end-to-end in step 3 rather than only the simulated window).
    // 3. Now run the REAL CALL geode.fts.rebuild dispatch (as the existing
    //    tests do). During Task-3-fixed rebuild the begin/end pair is
    //    internal; to exercise the queue path deterministically, use the
    //    seam: after beginRebuild in step 2, call
    //    fts_index_ops.rebuildFulltextIndex — it must fail with
    //    Error.RebuildInProgress (concurrent rebuild guard) — then
    //    endRebuild to drain, and assert the drained ids == {3}.
    // 4. Full-path test: fresh index; run rebuildFulltextIndex on a thread
    //    while the main thread loops maintainFulltextOnWrite for a
    //    just-created node until rebuild completes; afterwards search:
    //    the node appears EXACTLY once and its BM25 score equals a
    //    reference node with identical text indexed once (reuse the
    //    score-parity assertion pattern from
    //    tests/test_fts_bulk_merge_maintenance.zig).
}

test "rebuild of index already being rebuilt errors" {
    // beginRebuild twice → second is Error.RebuildInProgress (via the
    // public rebuild path if reachable, else adapter-level).
}
```

- [ ] **Step 2: Run to verify failure** — `zig build test-fts-rebuild`: new tests FAIL (`beginRebuild` doesn't exist → compile error first; after stubs, behavioral asserts fail).

- [ ] **Step 3: Implement adapter rebuild-state registry** — the three pub fns above in `fts_storage_adapter.zig`, with a `rebuilds: std.StringHashMap(PendingSet)` guarded by `mu`. Key strings are duped with the adapter allocator on `beginRebuild` and freed on `endRebuild`.

- [ ] **Step 4: Implement the queue check + orchestration**

In `maintainFulltextOnWrite` (fts_index_ops.zig:381-431), for the `.create`/`.update` index leg, BEFORE calling `indexNodeDocument`:

```zig
        if (fa.noteWriteDuringRebuild(index_name, node_id)) {
            // Rebuild in progress: the id is queued; the rebuild's drain pass
            // indexes it from current store state after backfill. Skipping the
            // live write here prevents both the missing-engine error and the
            // double-append.
            continue; // (or the loop-appropriate skip for this index)
        }
```

In `rebuildFulltextIndex`, wrap the existing sequence:

```zig
    try fa.beginRebuild(index_name); // Error.RebuildInProgress if concurrent
    var drained = false;
    defer if (!drained) { _ = fa.endRebuild(index_name, allocator); } // clear flag on error paths
    // ... existing: dropIndex (tolerate IndexNotFound) → createIndex →
    //     errdefer dropIndex → SNAPSHOT the label ids ONCE (this is the
    //     backfill input — ensure backfillExistingNodes uses this snapshot,
    //     or capture the same getNodesByLabel slice it uses) → backfill ...
    const pending = fa.endRebuild(index_name, allocator);
    drained = true;
    defer allocator.free(pending);
    for (pending) |nid| {
        if (snapshot_contains(nid)) continue; // backfill already indexed current state
        indexNodeDocument(allocator, graph_name, index_name, nid, properties, fa) catch |err| {
            log.warn("rebuild drain reindex failed for node {}: {}", .{ nid, err });
        };
    }
    // re-arm registry + flush as today
```

`snapshot_contains`: build a `std.AutoHashMap(u64, void)` from the backfill snapshot ids. IMPORTANT semantics note to verify while implementing (read `backfillExistingNodes` :238-315 and the engine's delete semantics): the drain uses PLAIN `.create`-style `indexNodeDocument` for ids NOT in the snapshot only — never delete-then-reindex (the engine's tombstones are permanent per doc_id; delete-then-reindex would hide the node — same rationale as the SET chokepoint comment). A node IN the snapshot whose properties changed mid-backfill keeps backfill's read (current-store state at read time); residual staleness there is covered by the documented canary-query invariant — note it in the doc comment.

- [ ] **Step 5: Run tests** — `zig build test-fts-rebuild && zig build test-fts-e2e && zig build test-fts-bulk-merge-maintenance && zig build <adapter-test-step>` all green.

- [ ] **Step 6: Update docs + commit**

Update the rebuild paragraphs in `docs/FULLTEXT_SEARCH.md` (and the one-line mention in CLAUDE.md if it describes the window): rebuild now queues concurrent writes and drains them; concurrent rebuilds of the same index are refused.

```bash
git add src/storage/fts_storage_adapter.zig src/execution/fts_index_ops.zig tests/test_fts_rebuild.zig docs/FULLTEXT_SEARCH.md CLAUDE.md docs/status.csv
git commit -m "fix(fts): queue concurrent writes during geode.fts.rebuild and drain post-backfill

Closes the drop->create window where live maintenance either hit a missing
engine (silently logged+lost) or double-appended after the backfill snapshot.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `nodes_indexed` reports what was actually indexed

`rebuildFulltextIndex` returns `store.getNodesByLabel(...).len` (fts_index_ops.zig:204-206) — tenant-blind and counts nodes with no indexable text. `backfillExistingNodes` (:238-315) returns `!void` and only logs per-node failures.

**Files:**
- Modify: `src/execution/fts_index_ops.zig` (`backfillExistingNodes` → `!usize`; `rebuildFulltextIndex` return; also the `createFulltextIndex` call site of backfill — adjust to `_ = try ...` or use the count if it already reports one)
- Test: extend `tests/test_fts_rebuild.zig`

**Interfaces:**
- Consumes: Task 3's snapshot orchestration if landed (count = successful `fa.indexNode` calls during backfill + drained-and-indexed pending ids).
- Produces: `backfillExistingNodes(...) !usize` — count of nodes actually submitted to `fa.indexNode` successfully (skips no-text nodes at :309 and failed indexNode at :311-313). `rebuildFulltextIndex` returns backfill count + drain count.

- [ ] **Step 1: Write the failing test** — extend `tests/test_fts_rebuild.zig`:

```zig
test "nodes_indexed counts only actually-indexed nodes" {
    // 3 :CntDoc nodes with body text + 1 :CntDoc node with NO body property
    // + 1 :CntDoc node with an integer body. rebuild → nodes_indexed == 3
    // (current behavior returns 5 → RED).
}
```

- [ ] **Step 2: Run to verify failure** — `zig build test-fts-rebuild`: FAIL (5 != 3).
- [ ] **Step 3: Implement** — counter in `backfillExistingNodes` incremented only after successful `fa.indexNode` with non-empty `doc_terms`; return it; `rebuildFulltextIndex` returns `backfill_count + drain_count`.
- [ ] **Step 4: Run** — `zig build test-fts-rebuild && zig build test-fts-e2e` green. Also re-run the harness rebuild coverage: `zig build && cd ../geode-test-harness && make test-spec SPEC=geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` (it asserts a rebuild `nodes_indexed` value — update the spec's expected number in the harness repo if it pinned the old over-count, and commit that separately in the harness repo with the trailer).
- [ ] **Step 5: Commit**

```bash
git add src/execution/fts_index_ops.zig tests/test_fts_rebuild.zig docs/status.csv
git commit -m "fix(fts): geode.fts.rebuild nodes_indexed counts actually-indexed nodes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Hydrating fallback for non-resident nodes in FTS maintenance

`indexNodeDocument` (fts_index_ops.zig:500-517) reads via `lockShardShared` + `getPtrUnlocked` and silently skips (`orelse return`) a node evicted from the bounded cache — a bulk-written node evicted before the hook runs never gets indexed. `store.getNodePropertyValue` (src/graph_store.zig:6284-6292) is the existing hydrate-on-miss accessor that does NOT decrypt FLE (preserving the deliberate ciphertext-indexing posture) and is self-locking (uses `getOrHydratePtr`, node_cache.zig:259-293). Both maintenance call sites run after all graph locks are released, so a self-locking hydrating call is legal.

**Files:**
- Modify: `src/execution/fts_index_ops.zig` (`indexNodeDocument`)
- Test: extend `tests/test_fts_bulk_merge_maintenance.zig`

**Interfaces:**
- Consumes: `store.getNodePropertyValue(node_id, prop)` (graph_store.zig:6284) — verify exact signature/return (`error.PropertyNotFound`/`error.NodeNotFound` vs optional) before use.
- Produces: non-resident-but-durable nodes get indexed; truly-deleted nodes still skip.

- [ ] **Step 1: Write the failing test** — extend `tests/test_fts_bulk_merge_maintenance.zig`. Forcing real eviction is machinery-heavy; instead pin the fallback seam honestly: model on `tests/test_reopen_merge_hydration_dup.zig` (read it) — persist nodes, reopen the store so the cache starts COLD (nodes durable but non-resident), then call `fts_index_ops.maintainFulltextOnWrite` for a cold node id and assert it becomes searchable (pre-fix: `getPtrUnlocked` misses on the cold cache → silent skip → 0 rows → RED). Also a negative: maintenance for a nonexistent node id stays a clean no-op.

- [ ] **Step 2: Run to verify failure** — `zig build test-fts-bulk-merge-maintenance`: new test RED (0 rows).

- [ ] **Step 3: Implement** — in `indexNodeDocument`, restructure the property-read block:

```zig
        // Fast path: resident node — copy property text under the shard's
        // SHARED lock (realloc-safe). Fallback: hydrate-on-miss via
        // getNodePropertyValue (self-locking, NO FLE decrypt — ciphertext
        // indexing posture preserved), for nodes evicted from the bounded
        // cache between write-commit and this hook.
        // CANARY: REQ=REQ-FTS-MAINT-HYDRATE-001; FEATURE="FullText"; ASPECT=NonResidentFallback; STATUS=TESTED; TEST=tests/test_fts_bulk_merge_maintenance.zig; OWNER=fts; UPDATED=2026-08-29
```

Keep the existing locked fast path; on `getPtrUnlocked` miss, unlock the shard first, then per property call `store.getNodePropertyValue(node_id, prop)`, dupe `.String` payloads with the same ownership/defer pattern already used at :515, and map `error.NodeNotFound` to the existing skip. Never call the hydrating accessor while the shard lock is held (re-entrancy contract, node_cache.zig:547-550).

- [ ] **Step 4: Run** — `zig build test-fts-bulk-merge-maintenance && zig build test-fts-e2e && zig build test-reopen-merge-hydration-dup && zig build test-scan-ingest-race` green.
- [ ] **Step 5: Commit**

```bash
git add src/execution/fts_index_ops.zig tests/test_fts_bulk_merge_maintenance.zig docs/status.csv
git commit -m "fix(fts): hydrate-on-miss fallback in live maintenance for evicted nodes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Upstream mcp callTool leak — fix in `devnw/zig/mcp`, bump pin to v0.1.12

The vendored `mcp` (fetch-cache, not in-repo) hardcodes `.owned = false` for `tools/call` results (zig-pkg/mcp-0.1.11-*/src/mcp.zig:2999) while the free site (:2924-2947) only frees owned results — every dynamically-allocated tool response (all of Geode's) leaks for the life of the long-running `geode mcp` server. The `tasks/*` handlers in the same file already use `owned = true` (:3063-3077). Fix belongs upstream: `git+https://gitlab.com/devnw/zig/mcp.git` pinned at `#v0.1.11` in `build.zig.zon:286-289`. Local clone: `~/src/gl/gitlab.com/devnw/zig/mcp` (stale — fetch first).

**Files:**
- Modify (upstream repo): `src/mcp.zig` in the mcp clone
- Modify (geode): `build.zig.zon` (url tag + hash), `tests/test_mcp_read_only.zig` + `tests/test_gap0516_mcp_capabilities.zig` (revert the page_allocator leak workaround to the strict test allocator — the workaround's in-file comment marks it), `tests/test_gap0875_stubs_mcp.zig` if it carries the same workaround
- Docs: `docs/MCP_SERVER.md` (pin note), `CLAUDE.md` if it names the mcp version

**Interfaces:**
- Consumes: upstream `MethodResult { result: ?[]const u8, owned: bool }` (mcp.zig:2950-2954).
- Produces: mcp v0.1.12 where `callTool` results are `owned = true` (contract: tool handlers MUST return allocator-owned bytes — document it in the upstream doc comment); geode pin bumped; geode MCP tests leak-clean under the strict allocator.

- [ ] **Step 1: Upstream fix (in the mcp clone)**

```bash
cd ~/src/gl/gitlab.com/devnw/zig/mcp   # resolve the real path; fetch first
git fetch origin --tags && git checkout v0.1.11 -b fix/calltool-owned
```

Read `src/mcp.zig` around the `callTool` dispatch (find `callTool` — line ~2999 at v0.1.11): change `.owned = false` → `.owned = true` for the `tools/call` result ONLY, add a doc comment on the handler interface stating the ownership contract ("callTool implementations must return bytes allocated with the allocator the server frees with"), and AUDIT the other hardcoded `false` sites (:2979 tools/list, :3002-3008 resources) — leave any that can return static strings as `false`; if `tools/list` etc. are also always-allocated in this lib's own handlers, note it but do NOT widen the change beyond `callTool` (YAGNI; the leak Geode hits is callTool). Run the upstream repo's own tests (`zig build test` — read its Makefile/CI for the canonical command). Follow upstream repo conventions for CHANGELOG/version bump files if present.

- [ ] **Step 2: Tag + push upstream**

```bash
git commit -am "fix: mark tools/call results owned so the server frees them

callTool handler results were hardcoded owned=false while the dispatch free
site only frees owned results — every dynamically allocated tool response
leaked for the server lifetime. tasks/* handlers already used owned=true.
Contract: callTool implementations return allocator-owned bytes.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git checkout main && git merge --ff-only fix/calltool-owned || git merge fix/calltool-owned
git tag -a v0.1.12 -m "v0.1.12: tools/call results owned by server"
git push origin main v0.1.12
```

(If upstream main has diverged from v0.1.11, rebase the fix onto main first and confirm its tests pass there; the tag goes on main per devnw convention — check `git log v0.1.11..origin/main` before merging.)

- [ ] **Step 3: Bump the geode pin**

In geode `build.zig.zon:286-289`: url → `#v0.1.12`; refresh the hash with `zig fetch --save=mcp "git+https://gitlab.com/devnw/zig/mcp.git#v0.1.12"` (or edit + `zig build` to learn the expected hash — use the repo's established bump procedure, see the dated bump comments on sibling deps).

- [ ] **Step 4: Revert the test workarounds (this is the leak's regression test)**

In `tests/test_mcp_read_only.zig` (and `test_gap0516_mcp_capabilities.zig`/`test_gap0875_stubs_mcp.zig` if they carry it): replace the documented `std.heap.page_allocator` workaround with the strict testing allocator so a leak FAILS the test. Run `zig build test-mcp-read-only && zig build test-gap0516 && zig build test-gap0875 2>/dev/null; true` (exact step names via grep) — green AND leak-clean proves the upstream fix. (RED evidence: before the pin bump, flipping one test to the strict allocator must fail with a leak report — capture that first.)

- [ ] **Step 5: Commit (geode)**

```bash
git add build.zig.zon build.zig.zon2 2>/dev/null; git add build.zig.zon tests/test_mcp_read_only.zig tests/test_gap0516_mcp_capabilities.zig docs/MCP_SERVER.md CLAUDE.md docs/status.csv
git commit -m "chore(deps): bump mcp to v0.1.12 — tools/call results freed by server

Reverts the page_allocator leak workarounds in MCP tests to the strict
allocator; leak-clean runs are the regression proof.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: status.csv duplicate-marker disambiguation — `Line` column

Two textually-identical CANARY markers in one file emit byte-identical rows (58 duplicate `(REQ,Feature,Aspect,File)` keys live today, e.g. src/security/rls_core.zig:916 vs :1435). Add a `Line` column: rows become unique by construction; marker COUNTS are unchanged (5,094 stays 5,094 — badge/metric scripts count rows by substring and are layout-agnostic: scripts/generate_badges.zig:71-90 and scripts/variance_envelope_guard.zig:130-163 use `indexOf(",TESTED,")`; tools/req_doc_report.py uses DictReader). Cost: status.csv rows shift when line numbers shift — acceptable; the pre-commit hook regenerates it automatically in the same commit.

**Files:**
- Modify: `tools/status_generate.py` (capture line number in `find_canary_markers` :39-91; add `Line` to `fieldnames` + sort key in `generate_status_csv` :128-149)
- Modify: `tools/test_status_generate.py` (golden fixture `EXPECTED_ROWS` :199-208 gains line numbers; hand-built marker dicts in `TestStrictStatusFilter` :81-125 gain `"line"` keys)
- Regenerate: `docs/status.csv`

**Interfaces:**
- Produces: 10-column CSV `REQ,Feature,Aspect,Status,Test,Bench,Owner,Updated,File,Line`; sort key extended to `(req, feature, aspect, file, line)`. Consumers verified layout-agnostic (above). The Go `tools/canaryscan` CLI emits its own artifacts — out of scope; note the schema delta in its README only if it documents the python CSV.

- [ ] **Step 1: Write the failing test** — in `tools/test_status_generate.py`, extend the golden fixture with a file containing the SAME marker text twice on known lines; assert two rows distinguished by the `Line` value. Run `make status-generate-test` → RED (KeyError/row mismatch).
- [ ] **Step 2: Implement** — in `find_canary_markers`, compute `marker["line"] = content.count("\n", 0, match.start()) + 1`; add the column + sort key. Update the two test classes' fixtures.
- [ ] **Step 3: Run** — `make status-generate-test` (all assertions green) then `make status-generate` and `git diff --stat docs/status.csv` (expect every row to gain a line number; row count unchanged at the pre-task total). Sanity: `python3 tools/req_doc_report.py --help >/dev/null` style smoke if it has a quick invocation; `zig build` for the badge scripts if they compile as part of a step (`grep -n generate_badges build.zig Makefile`), else note not-run.
- [ ] **Step 4: Commit**

```bash
git add tools/status_generate.py tools/test_status_generate.py docs/status.csv
git commit -m "feat(governance): add Line column to status.csv — duplicate markers now distinguishable

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Harness capture/compare assertions + wire-level BM25 score-stability pin

The harness has no cross-step comparison (confirmed: checks.py:211-248, spec.py:180-197; the fts_bulk_merge_visibility.yml spec itself documents the gap at :32-36). Add a minimal capture facility to the sequential `gql` runner, then use it to pin over the wire that idempotent re-MERGE does not inflate BM25 scores — the last untested link (handler-side gating) of the Task-4 fix chain.

**Files (all in `../geode-test-harness` — separate repo, commit there):**
- Modify: `geodetestlab-cli/<runner pkg>/spec.py` (`TestStep` :139-155 gains `capture_regex: str | None` and `capture_as: str | None`; `gql_expected` schema gains `equals_capture: str`)
- Modify: `geodetestlab-cli/<runner pkg>/executor.py` (`_run_sequential_test` gql branch :1214-1293: `captures: dict[str,str]` local; store regex group 1 of stdout under `capture_as`; `equals_capture` check compares the current step's `capture_regex` extraction against the named capture)
- Modify: `geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` (new sequential test)
- Harness unit tests: wherever executor/spec parsing is unit-tested (`grep -rn "gql_expected" geodetestlab-cli --include=test_*.py` to find the test module; extend it)

**Interfaces:**
- Produces spec syntax:

```yaml
  - name: capture-reference-score
    steps:
      - gql: "CALL geode.fts.search('bmv_idx', 'uniqueterm')"
        capture_regex: '"score":([0-9.]+)'
        capture_as: ref_score
        gql_expected: { status_class: "00000" }
      - gql: "MERGE (n:BulkVisDoc {k: 1}) ON CREATE SET n.body = '...'"   # idempotent re-merge
        gql_expected: { status_class: "00000" }
      - gql: "CALL geode.fts.search('bmv_idx', 'uniqueterm')"
        capture_regex: '"score":([0-9.]+)'
        gql_expected: { status_class: "00000", equals_capture: ref_score }
```

- [ ] **Step 1: Write the failing harness unit test** — spec parsing accepts the three new fields; executor compare path passes on equal extractions and fails with a clear message on mismatch (drive `_run_sequential_test` the way its existing unit tests do — if none exist for the gql branch, add a minimal one following the module's test conventions; if the harness has NO executor unit tests at all, the spec run in Step 3 is the test — say so in the report).
- [ ] **Step 2: Implement** per the interface above. Validation errors (unknown capture name, regex without group, capture_as without regex) fail the step with a spec-error message, not a crash.
- [ ] **Step 3: Extend the spec + run it** — add the score-stability sequential test to `fts_bulk_merge_visibility.yml` (re-MERGE the same key 3x between captures; scores must be equal — if the fix chain regressed, duplicate postings change the BM25 score and the compare fails). `cd geode` && `zig build`, then `make test-spec SPEC=geodetestlab-cli/specs/fts_bulk_merge_visibility.yml` — all tests green, managed server verified started.
- [ ] **Step 4: Commit (harness repo)**

```bash
git -C ../geode-test-harness add -A geodetestlab-cli
git -C ../geode-test-harness commit -m "feat(runner): capture_regex/capture_as/equals_capture step assertions + BM25 score-stability pin

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Note the closure** — in geode, update the "no row_count/score assertion facility" comments in the spec-adjacent docs if any engine-side doc references the gap (grep `docs/rag/RAG_INTEGRATION_GUIDE.md` and `.superpowers` ledger is enough — if nothing in tracked docs mentions it, skip; no empty-churn commits).

---

### Task 9: Full validation sweep

**Files:** none new.

- [ ] **Step 1:** `make fmt` — no residual diff.
- [ ] **Step 2:** Targeted steps serially: `test-profile-rls-tenant`, `<adapter-test-step>`, `test-fts-rebuild`, `test-fts-bulk-merge-maintenance`, `test-fts-e2e`, `test-mcp-read-only`, `test-gap0516`, `test-read-only-execute`, `test-rls-expr-engine-wiring` (exact name via grep), `test-gap0509` (exact name via grep), `test-gap0868` (exact name via grep), `test-scan-ingest-race`, `test-reopen-merge-hydration-dup`, `test-cluster-replicable-mutations`, `test-show-capabilities`, `test-transport-parity`.
- [ ] **Step 3:** Full suite: `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N` for N=0..3 (known flakes serially; `test-gap0866` + `test-quic-condition-cadence` pre-broken).
- [ ] **Step 4:** Harness: `make test-spec` for `fts_bulk_merge_visibility.yml`, `fts_storage_basic.yml`, `fulltext_search_basic.yml`, `read_only_execute.yml`, `show_capabilities_discovery.yml`, `knn_metric_mismatch.yml` — servers verified started.
- [ ] **Step 5:** `make status-generate-test` and `make pre-commit` — only the documented known-red hooks red.
- [ ] **Step 6:** `git status` clean in geode, harness, AND the mcp clone; every commit made; report per-repo commit lists. Do not push (orchestrator pushes all three repos at the end).

---

## Out of scope (deliberate)

- **`geode.fts.*` default-graph-only**: documented limitation (guide §8 + FULLTEXT_SEARCH.md); making the procedures graph-aware is a feature request, not a review follow-up.
- **FLE-ciphertext indexing posture**: deliberate (narrower exposure); Task 5 preserves it via `getNodePropertyValue`.
- **tools/canaryscan Go CLI schema parity**: emits its own artifacts; align only if/when its output is consumed interchangeably.
- **In-snapshot mid-backfill staleness** (Task 3 residual): covered by the documented canary-query ingestion invariant; noted in code comment.
