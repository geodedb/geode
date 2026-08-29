// CANARY: REQ=REQ-FTS-REBUILD-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildBackfill; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-28
//
// Spec geode-vectorization-and-reranking ingestion invariant: "On deployed
// versions where bulk-MERGE bypasses FTS maintenance, rebuild/backfill the
// affected index before marking ingestion ready." This test drives the real
// store + real adapter + real parser + real executor (no mocks), mirroring
// tests/test_fts_e2e.zig for the store/adapter/index bootstrap.
//
// 1. Bootstrap an empty-label fulltext index via fts_index_ops.createFulltextIndex.
// 2. Insert 3 nodes via the bulk-MERGE fast path (adapter.bulkMergeNodeWithReservedId)
//    directly — the documented blind spot: this write path does NOT run the
//    FTS maintenance hook (see CLAUDE.md "Full-text search bulk-MERGE
//    auto-indexing (Open)").
// 3. CALL geode.fts.search finds nothing — the pre-rebuild blind spot.
// 4. CALL geode.fts.rebuild reindexes from current store contents and reports
//    nodes_indexed == 3.
// 5. CALL geode.fts.search now finds all 3.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors tests/test_fts_e2e.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "geode.fts.rebuild reindexes nodes missed by out-of-band writes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Bootstrap the fulltext index on an empty label (no nodes exist yet).
    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "rebuild_doc_idx",
        "RebuildDoc",
        &.{"body"},
    );

    // 2. Insert 3 :RebuildDoc nodes via the bulk-MERGE fast-path writer,
    //    BYPASSING the FTS maintenance hook (adapter.bulkMergeNodeWithReservedId
    //    is the documented blind spot — see graph_storage_adapter.zig:4227).
    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const store = graph_store.getGlobalStore(h.allocator);
    const bodies = [_][]const u8{
        "widget alpha description",
        "widget beta notes",
        "widget gamma summary",
    };
    for (bodies, 0..) |body, i| {
        const reserved = store.reserveNodeId();
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = body } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            reserved,
            "RebuildDoc",
            "doc_key",
            .{ .Int = @intCast(i) },
            &props,
            false, // apply_on_match — irrelevant, each doc_key is unique
        );
    }

    // 3. Search BEFORE rebuild: the blind spot — 0 rows.
    {
        var res = try h.runQuery("CALL geode.fts.search('rebuild_doc_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // 4. Rebuild: one row, columns [index, nodes_indexed], nodes_indexed == 3.
    {
        var res = try h.runQuery("CALL geode.fts.rebuild('rebuild_doc_idx')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 2), res.columns.len);
        try testing.expectEqualStrings("index", res.columns[0]);
        try testing.expectEqualStrings("nodes_indexed", res.columns[1]);
        try testing.expect(res.rows[0][0] == .Str);
        try testing.expectEqualStrings("rebuild_doc_idx", res.rows[0][0].Str);
        try testing.expect(res.rows[0][1] == .Int);
        try testing.expectEqual(@as(i64, 3), res.rows[0][1].Int);
    }

    // 5. Search again: all 3 nodes are now indexed.
    {
        var res = try h.runQuery("CALL geode.fts.search('rebuild_doc_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 3), res.rows.len);
    }
}

test "geode.fts.rebuild on unknown index errors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const result = h.runQuery("CALL geode.fts.rebuild('nonexistent_idx')");
    try testing.expectError(error.IndexNotFound, result);
}

// CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=ConcurrentWriteQueued; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
test "write during rebuild window is queued, indexed exactly once" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Bootstrap :RbwDoc(body) with 2 existing nodes; verify both searchable.
    {
        var res = try h.runQuery("CREATE (:RbwDoc {body: 'alpha term document'})");
        defer res.deinit(aa);
    }
    {
        var res = try h.runQuery("CREATE (:RbwDoc {body: 'beta term document'})");
        defer res.deinit(aa);
    }
    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "rbw_idx",
        "RbwDoc",
        &.{"body"},
    );
    {
        var res = try h.runQuery("CALL geode.fts.search('rbw_idx', 'term')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
    }

    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const mg = try adapter.getOrCreateGraph(graph_store.DEFAULT_GRAPH_NAME);
    const fa = mg.fts_adapter orelse return error.TestUnexpectedResult;
    const store = graph_store.getGlobalStore(h.allocator);

    // 2. Simulate the window directly: begin, then run the SAME write hook a
    //    real CREATE would run for a NEW node id while the flag is armed.
    try fa.beginRebuild("rbw_idx");

    const new_id = store.reserveNodeId();
    {
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = "gamma zzzqueued unique term" } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            new_id,
            "RbwDoc",
            "doc_key",
            .{ .Int = 999 },
            &props,
            false,
        );
    }
    // Must NOT error even though the engine is still alive in this
    // simulation (we never dropped it) — the queue short-circuits BEFORE
    // the engine write is attempted.
    try execution.fts_index_ops.maintainFulltextOnWrite(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        new_id,
        &.{"RbwDoc"},
        .create,
    );

    // The engine did NOT receive it yet — its unique term finds 0 rows.
    // (The engine still exists pre-drop in this simulation; the honest
    // end-to-end proof across a REAL drop→create is part 4 below.)
    {
        var res = try h.runQuery("CALL geode.fts.search('rbw_idx', 'zzzqueued')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // 3. A concurrent geode.fts.rebuild on the SAME index must be refused —
    //    proves beginRebuild's concurrent-rebuild guard is wired end-to-end
    //    through the real rebuildFulltextIndex entry point.
    const rebuild_result = execution.fts_index_ops.rebuildFulltextIndex(
        h.allocator,
        h.ctx.catalog,
        graph_store.DEFAULT_GRAPH_NAME,
        "rbw_idx",
    );
    try testing.expectError(error.RebuildInProgress, rebuild_result);

    // Drain: the queued id comes back exactly, and the flag clears.
    const drained = try fa.endRebuild("rbw_idx", h.allocator);
    defer h.allocator.free(drained);
    try testing.expectEqual(@as(usize, 1), drained.len);
    try testing.expectEqual(new_id, drained[0]);

    // 4. Full-path test: a FRESH index, a real concurrent
    //    CALL geode.fts.rebuild racing a live write for a just-created node.
    //    Whichever of the three windows the racer's write lands in (before
    //    the rebuild starts, queued mid-rebuild, or after it completes),
    //    the node must end up indexed EXACTLY once — proven via BM25 score
    //    parity against a reference node with byte-identical text indexed
    //    exactly once (the double-append tell — see
    //    tests/test_fts_bulk_merge_maintenance.zig for the same pattern).
    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "rbw_full_idx",
        "RbwFull",
        &.{"body"},
    );

    // Filler nodes give the rebuild's backfill real (I/O-bound) work, widening
    // the window the racer's write has a chance to land inside — the
    // assertions below hold regardless of whether it actually does.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const rid = store.reserveNodeId();
        const body = try std.fmt.allocPrint(aa, "filler node number {d} padding text", .{i});
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = body } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            rid,
            "RbwFull",
            "doc_key",
            .{ .Int = @intCast(i) },
            &props,
            false,
        );
    }

    const canary_text = "canaryparity fixed reference text body";

    // Reference node: created and live-indexed BEFORE the race starts.
    const ref_id = store.reserveNodeId();
    {
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = canary_text } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            ref_id,
            "RbwFull",
            "doc_key",
            .{ .Int = 9001 },
            &props,
            false,
        );
    }
    try execution.fts_index_ops.maintainFulltextOnWrite(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        ref_id,
        &.{"RbwFull"},
        .create,
    );

    // Racer node: created in the store now, but its write-hook call (below)
    // races the rebuild thread.
    const racer_id = store.reserveNodeId();
    {
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = canary_text } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            racer_id,
            "RbwFull",
            "doc_key",
            .{ .Int = 9002 },
            &props,
            false,
        );
    }

    const CatalogPtr = @TypeOf(h.ctx.catalog);
    const RebuildCtx = struct {
        allocator: std.mem.Allocator,
        catalog: CatalogPtr,
        result: anyerror!u64 = 0,

        fn run(self: *@This()) void {
            self.result = execution.fts_index_ops.rebuildFulltextIndex(
                self.allocator,
                self.catalog,
                graph_store.DEFAULT_GRAPH_NAME,
                "rbw_full_idx",
            );
        }
    };
    var ctx = RebuildCtx{ .allocator = h.allocator, .catalog = h.ctx.catalog };
    {
        const thread = try std.Thread.spawn(.{}, RebuildCtx.run, .{&ctx});
        // `defer thread.join()` is scoped to THIS block (not the whole test
        // function): it fires the moment control reaches the closing brace
        // below, which is immediately after the racer write on the normal
        // path — so the join still happens synchronously before `ctx.result`
        // is read and the post-rebuild search assertions run. It ALSO fires
        // on any early return out of this block (e.g. if the racer write
        // below were ever changed back to a bare `try`), which is what keeps
        // `thread` from being orphaned reading (and possibly outliving) the
        // harness's torn-down global store on `h.deinit()` — a use-after-free
        // / SIGABRT, not a clean test failure. A bare `defer thread.join()`
        // at the OUTER function scope would only fire at function exit, i.e.
        // AFTER `ctx.result` and the search queries below already ran
        // concurrently with the still-in-flight rebuild thread — this was
        // caught empirically as a self-inflicted flake during this hardening
        // round (mid-rebuild search hit `IndexNotFound`/`FileNotFound` and
        // 0 rows) and is exactly why the join must be scoped tightly here.
        defer thread.join();

        // This IS the race under test: this write and the spawned rebuild
        // thread both touch `rbw_full_idx` concurrently. Under the
        // documented `noteWriteDuringRebuild` pre-check TOCTOU window
        // (beginRebuild + dropIndex racing this write's own pre-check),
        // `maintainFulltextOnWrite` can observe `Error.IndexNotFound` —
        // production now absorbs that internally (catch+log, review Finding
        // 1) and this call should not see it propagate, but mirror every
        // other write-hook call site's catch-and-tolerate posture here too
        // rather than a bare `try`: this is the one write in the test racing
        // another thread, so it must never be able to skip the join above on
        // any error.
        execution.fts_index_ops.maintainFulltextOnWrite(
            h.allocator,
            graph_store.DEFAULT_GRAPH_NAME,
            racer_id,
            &.{"RbwFull"},
            .create,
        ) catch {};
    }

    _ = try ctx.result; // propagate any rebuild failure as a test failure

    {
        var res = try h.runQuery("CALL geode.fts.search('rbw_full_idx', 'canaryparity', 10)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);

        var score_ref: ?f64 = null;
        var score_racer: ?f64 = null;
        for (res.rows) |row| {
            try testing.expect(row[0] == .Int);
            try testing.expect(row[1] == .Double);
            const nid = row[0].Int;
            const score = row[1].Double;
            if (nid == @as(i64, @intCast(ref_id))) score_ref = score;
            if (nid == @as(i64, @intCast(racer_id))) score_racer = score;
        }
        try testing.expect(score_ref != null);
        try testing.expect(score_racer != null);
        // The load-bearing assertion: identical text indexed exactly once
        // each MUST carry the identical BM25 score. A double-append (either
        // a missed queue, or a drain re-indexing an already-backfilled id)
        // would skew the racer's term frequency relative to the reference
        // and fail this equality.
        try testing.expectEqual(score_ref.?, score_racer.?);
    }
}

// CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildGuard; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
test "rebuild of index already being rebuilt errors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "rbw_guard_idx",
        "RbwGuardDoc",
        &.{"body"},
    );

    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const mg = try adapter.getOrCreateGraph(graph_store.DEFAULT_GRAPH_NAME);
    const fa = mg.fts_adapter orelse return error.TestUnexpectedResult;

    try fa.beginRebuild("rbw_guard_idx");
    defer {
        const leftover = fa.endRebuild("rbw_guard_idx", h.allocator) catch &[_]u64{};
        h.allocator.free(leftover);
    }

    const result = execution.fts_index_ops.rebuildFulltextIndex(
        h.allocator,
        h.ctx.catalog,
        graph_store.DEFAULT_GRAPH_NAME,
        "rbw_guard_idx",
    );
    try testing.expectError(error.RebuildInProgress, result);
}
