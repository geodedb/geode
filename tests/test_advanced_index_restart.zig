// ADVANCED-INDEX-RESTART — an HNSW index that exists only until the process exits.
//
// VERIFIED READ-ONLY AGAINST 1459b456 BEFORE THE FIX:
//
//   `CREATE INDEX … USING vector` builds a real advanced (HNSW) index through
//   `statement_dispatcher.ensureAdvancedRuntimeIndex`, and that is the ONLY
//   call site. Nothing rebuilds advanced indexes when the catalog is reloaded,
//   so after a restart:
//
//       SHOW INDEXES                              -> still lists the index
//       index_manager.findAdvancedVectorIndexForProperty("emb")  -> null
//       RETURN knn('emb', vectorf32([...]), 3, 'l2')             -> correct rows
//
//   Correct rows, because `evalVectorKnn` falls back to a brute-force
//   `scanVectorKnn` over every node when no index is registered. The result set
//   is therefore indistinguishable from the indexed one — the only observable
//   is that the index instance is gone and every query is O(n). That is what
//   makes this silent: the database advertises an index it is not using.
//
//   The metric had a second, worse edge. `IndexInfo` carried no metric at all,
//   so `WITH (metric = 'cosine')` was validated at DDL time, threaded into the
//   runtime wrapper, and then existed nowhere on disk. Any rebuild that guessed
//   would have rebuilt a cosine index with an L2 graph — WORSE recall than the
//   brute-force scan it replaced. The metric is now persisted so the rebuilt
//   index is the index the DDL asked for.
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   1. After a restart, the first knn()/vector_knn() query on an indexed
//      property leaves a REGISTERED advanced vector index behind — asserted on
//      index-manager state, not on rows, because the brute-force fallback
//      returns the same rows.
//   2. The rebuilt index carries the metric the DDL recorded, across the
//      restart, for l2 / cosine / dot_product.
//   3. The rebuilt index is POPULATED (its entry count matches the stored
//      vectors), so it is a real index and not an empty shell that quietly
//      falls back on every search.
//   4. The ENG-3912 dimension guard is armed by the rebuild, so a mixed-dimension
//      write is still refused after the restart.
//   5. A property with no catalog index does NOT acquire one (the guard against
//      "fix it by building an index for everything").
//
// CANARY: REQ=REQ-ADVANCED-INDEX-RESTART-REBUILD; FEATURE="VectorIndex"; ASPECT=LazyRebuildAfterRestart; STATUS=TESTED; TEST=tests/test_advanced_index_restart.zig; OWNER=index; UPDATED=2026-08-25
// CANARY: REQ=REQ-ADVANCED-INDEX-RESTART-REBUILD; FEATURE="SchemaCatalog"; ASPECT=VectorMetricPersistence; STATUS=TESTED; TEST=tests/test_advanced_index_restart.zig; OWNER=catalog; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Same store-level restart harness as tests/test_eng3912_dim_pinning.zig: tear
/// the process-global engine state down and bring it back up against the SAME
/// data dir, so the catalog really is reloaded from `geode_catalog.dat`.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
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
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// The observable: is an advanced vector index REGISTERED for this property?
/// A correct row set proves nothing here — `scanVectorKnn` produces the same
/// rows with no index at all.
fn indexNameForProperty(property: []const u8) ?[]const u8 {
    const mgr = index_manager.getGlobalIndexManager() orelse return null;
    return mgr.findAdvancedVectorIndexForProperty(property);
}

const VectorF32 = geode.types.vector.VectorF32;
const VectorIndexWrapper = geode.index.advanced_types_index.VectorIndexWrapper;

fn wrapperFor(index_name: []const u8) !*VectorIndexWrapper {
    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    return mgr.advanced_vector_indexes.get(index_name) orelse error.IndexNotBuilt;
}

/// How many entries the BUILT index actually answers with. `scanVectorKnn`
/// cannot reach this — it goes straight to the manager's index instance — so a
/// non-zero count here proves the rebuilt index was populated rather than
/// registered empty and silently falling back on every search.
fn indexedNeighbourCount(index_name: []const u8, query: []const f32, k: u32) !usize {
    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    const results = try mgr.queryAdvancedVectorIndexWithMetric(
        index_name,
        VectorF32.fromSlice(query),
        k,
        (try wrapperFor(index_name)).metric,
    );
    defer mgr.allocator.free(results);
    return results.len;
}

// One harness for the whole file: the hnsw library keeps a worker pool alive
// across index lifetimes, so per-test store re-init tears global state out from
// under parked pool threads (same reason as tests/test_eng3912_dim_pinning.zig).
test "ADVANCED-INDEX-RESTART: the HNSW index comes back after a restart, with its metric and contents" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH air_g");
    _ = try h.exec("USE GRAPH air_g");

    // Three indexes so the metric assertions cannot pass by defaulting.
    _ = try h.exec("CREATE (:AirL {emb_l: vectorf32([1.0,0.0,0.0])})");
    _ = try h.exec("CREATE (:AirL {emb_l: vectorf32([0.0,1.0,0.0])})");
    _ = try h.exec("CREATE (:AirL {emb_l: vectorf32([0.0,0.0,1.0])})");
    _ = try h.exec("CREATE (:AirC {emb_c: vectorf32([1.0,2.0])})");
    _ = try h.exec("CREATE (:AirD {emb_d: vectorf32([3.0,4.0])})");

    _ = try h.exec("CREATE INDEX air_l ON AirL (emb_l) USING vector WITH (metric = 'l2')");
    _ = try h.exec("CREATE INDEX air_c ON AirC (emb_c) USING vector WITH (metric = 'cosine')");
    _ = try h.exec("CREATE INDEX air_d ON AirD (emb_d) USING HNSW WITH (metric = 'dot_product')");

    // Baseline: the DDL really did build them in this process.
    try testing.expect(indexNameForProperty("emb_l") != null);
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.l2, (try wrapperFor("air_l")).metric);
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.cosine, (try wrapperFor("air_c")).metric);
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.dot_product, (try wrapperFor("air_d")).metric);

    const rows_before = (try h.exec("MATCH (n:AirL) RETURN knn('emb_l', vectorf32([1.0,0.0,0.0]), 3, 'l2')")).rows.len;
    try testing.expect(rows_before > 0);

    try h.restart();
    _ = try h.exec("USE GRAPH air_g");

    // The catalog survived — SHOW INDEXES still advertises all three.
    const shown = try h.exec("SHOW INDEXES");
    var seen: usize = 0;
    for (shown.rows) |row| {
        if (row.len == 0) continue;
        const name = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, "air_l") or std.mem.eql(u8, name, "air_c") or std.mem.eql(u8, name, "air_d")) seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // KEY ASSERTION (RED before the fix: null — nothing rebuilds advanced
    // indexes on catalog reload, so knn() silently brute-force scanned).
    const rows_after = (try h.exec("MATCH (n:AirL) RETURN knn('emb_l', vectorf32([1.0,0.0,0.0]), 3, 'l2')")).rows.len;
    try testing.expectEqual(rows_before, rows_after);

    const rebuilt = indexNameForProperty("emb_l") orelse {
        std.debug.print(
            "\n[ADVANCED-INDEX-RESTART] no advanced vector index registered for 'emb_l' after restart + knn(): the query brute-force scanned\n",
            .{},
        );
        return error.AdvancedIndexNotRebuilt;
    };
    try testing.expectEqualStrings("air_l", rebuilt);

    // The rebuilt index is POPULATED, not an empty shell that falls back on
    // every search.
    {
        // Dimension adopted from the stored vectors rather than left at 0 (an
        // index created but never populated keeps dimension 0 and a null hnsw
        // handle, and answers every search with an empty slice).
        const wrapper = try wrapperFor("air_l");
        try testing.expectEqual(@as(u16, 3), wrapper.dimension);
        try testing.expect(wrapper.hnsw_index != null);
        try testing.expectEqual(
            @as(usize, 3),
            try indexedNeighbourCount("air_l", &[_]f32{ 1.0, 0.0, 0.0 }, 3),
        );
    }

    // THE METRIC survives the restart. Before this fix `IndexInfo` had no
    // metric field at all, so a rebuild could only have guessed `.l2` — which
    // for the cosine index would have been WORSE than the brute-force scan it
    // replaced.
    _ = try h.exec("MATCH (n:AirC) RETURN knn('emb_c', vectorf32([1.0,2.0]), 1, 'cosine')");
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.cosine, (try wrapperFor("air_c")).metric);

    _ = try h.exec("MATCH (n:AirD) RETURN knn('emb_d', vectorf32([3.0,4.0]), 1, 'dot')");
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.dot_product, (try wrapperFor("air_d")).metric);

    // The rebuild is IDEMPOTENT: a second query does not drop and rebuild.
    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    const rebuilds_before = mgr.statistics.rebuild_count;
    _ = try h.exec("MATCH (n:AirL) RETURN knn('emb_l', vectorf32([1.0,0.0,0.0]), 3, 'l2')");
    _ = try h.exec("MATCH (n:AirL) RETURN knn('emb_l', vectorf32([0.0,1.0,0.0]), 3, 'l2')");
    try testing.expectEqual(rebuilds_before, mgr.statistics.rebuild_count);

    // The ENG-3912 dimension guard must be armed by the rebuild too — an index
    // that is back must enforce what it enforced before the restart.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:AirL {emb_l: vectorf32([1.0,2.0])})"),
    );

    // Guard against "fix it by building an index for everything": a property
    // with no catalog index acquires none.
    _ = try h.exec("CREATE (:AirNone {emb_n: vectorf32([1.0,2.0])})");
    _ = try h.exec("MATCH (n:AirNone) RETURN knn('emb_n', vectorf32([1.0,2.0]), 1, 'l2')");
    try testing.expect(indexNameForProperty("emb_n") == null);
}

test "ADVANCED-INDEX-RESTART: an index with no explicit metric keeps the documented l2 default across a restart" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH air_def_g");
    _ = try h.exec("USE GRAPH air_def_g");
    _ = try h.exec("CREATE (:AirDef {emb_x: vectorf32([1.0,2.0,3.0])})");
    _ = try h.exec("CREATE (:AirDef {emb_x: vectorf32([4.0,5.0,6.0])})");
    _ = try h.exec("CREATE INDEX air_def ON AirDef (emb_x) USING vector");

    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.l2, (try wrapperFor("air_def")).metric);

    try h.restart();
    _ = try h.exec("USE GRAPH air_def_g");

    _ = try h.exec("MATCH (n:AirDef) RETURN knn('emb_x', vectorf32([1.0,2.0,3.0]), 2, 'l2')");

    const name = indexNameForProperty("emb_x") orelse return error.AdvancedIndexNotRebuilt;
    try testing.expectEqualStrings("air_def", name);
    try testing.expectEqual(VectorIndexWrapper.DistanceMetric.l2, (try wrapperFor("air_def")).metric);
    try testing.expectEqual(
        @as(usize, 2),
        try indexedNeighbourCount("air_def", &[_]f32{ 1.0, 2.0, 3.0 }, 5),
    );
}
