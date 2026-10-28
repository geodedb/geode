// CANARY: REQ=REQ-ENG-USING-VECTOR-BUILDS-INDEX; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_using_vector_index.zig:1; OWNER=index; UPDATED=2026-08-25
//
// `CREATE INDEX … USING vector` (and `USING HNSW`) silently built NO index.
//
// The parser maps both of those spellings to `ast.IndexType.vector` and only
// `USING vector_f32` to `.vector_f32`. `toRuntimeAdvancedIndexType` returned
// null for `.vector`, so the DDL recorded a catalog row, SHOW INDEXES listed
// the index, and nothing was ever built. Nobody noticed because `vector_knn`
// falls back to a brute-force `scanVectorKnn` when no index is registered —
// results were right, the index was a fiction, and every query was O(n).
//
// Second defect on the same line: the build site hardcoded `.l2`, so the
// metric GAP-0918 validates (`WITH (metric = 'cosine')`) was accepted and then
// thrown away — the index was built and queried with Euclidean distance.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

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

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// The registered runtime HNSW index covering `property`, if any. This is what
/// `evalVectorKnn` consults before falling back to the brute-force scan, so it
/// is the honest "was an index actually built?" probe.
fn indexForProperty(property: []const u8) ?[]const u8 {
    const mgr = index_manager.getGlobalIndexManager() orelse return null;
    return mgr.findAdvancedVectorIndexForProperty(property);
}

test "USING vector / USING HNSW / USING vector_f32 all build a real runtime index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH uv");
    _ = try h.exec("USE GRAPH uv");

    // Nothing registered before the DDL.
    try testing.expect(indexForProperty("emb_v") == null);

    _ = try h.exec("CREATE INDEX uv_vector ON UV1 (emb_v) USING vector WITH (metric = 'l2')");
    const built_vector = indexForProperty("emb_v") orelse {
        // Before the fix this was the outcome: catalog row present, index absent.
        return error.UsingVectorBuiltNoIndex;
    };
    try testing.expectEqualStrings("uv_vector", built_vector);

    _ = try h.exec("CREATE INDEX uv_hnsw ON UV2 (emb_h) USING HNSW WITH (metric = 'l2')");
    const built_hnsw = indexForProperty("emb_h") orelse return error.UsingHnswBuiltNoIndex;
    try testing.expectEqualStrings("uv_hnsw", built_hnsw);

    // The spelling that already worked keeps working.
    _ = try h.exec("CREATE INDEX uv_f32 ON UV3 (emb_f) USING vector_f32 WITH (metric = 'l2')");
    const built_f32 = indexForProperty("emb_f") orelse return error.UsingVectorF32BuiltNoIndex;
    try testing.expectEqualStrings("uv_f32", built_f32);
}

test "a USING vector index is queryable: knn returns the nearest rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH uvq");
    _ = try h.exec("USE GRAPH uvq");
    _ = try h.exec("CREATE INDEX uvq_idx ON UVQ (emb_q) USING vector WITH (metric = 'l2')");

    _ = try h.exec("CREATE (:UVQ {id: 1, emb_q: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:UVQ {id: 2, emb_q: vectorf32('[0.0, 1.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:UVQ {id: 3, emb_q: vectorf32('[0.0, 0.0, 1.0, 0.0]')})");

    try testing.expect(indexForProperty("emb_q") != null);

    const res = try h.exec("RETURN knn('emb_q', vectorf32('[1.0, 0.0, 0.0, 0.0]'), 2, 'l2')");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .List => |items| {
            // The index is populated, so the query answers with neighbours
            // rather than an empty list.
            try testing.expect(items.len > 0);
            try testing.expect(items.len <= 2);
        },
        else => return error.ExpectedListFromKnn,
    }
}

test "the validated metric reaches the built index instead of the hardcoded l2" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH uvm");
    _ = try h.exec("USE GRAPH uvm");

    _ = try h.exec("CREATE INDEX uvm_cos ON UVM1 (emb_c) USING vector WITH (metric = 'cosine')");
    _ = try h.exec("CREATE INDEX uvm_dot ON UVM2 (emb_d) USING HNSW WITH (metric = 'dot_product')");
    _ = try h.exec("CREATE INDEX uvm_def ON UVM3 (emb_x) USING vector");

    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;

    // Before the fix every one of these was `.l2`: the metric was validated at
    // DDL and then discarded at the build site.
    const cos = mgr.advanced_vector_indexes.get("uvm_cos") orelse return error.MissingCosineIndex;
    try testing.expectEqual(@as(@TypeOf(cos.metric), .cosine), cos.metric);

    const dot = mgr.advanced_vector_indexes.get("uvm_dot") orelse return error.MissingDotIndex;
    try testing.expectEqual(@as(@TypeOf(dot.metric), .dot_product), dot.metric);

    // No WITH (metric = …) keeps the historical default.
    const def = mgr.advanced_vector_indexes.get("uvm_def") orelse return error.MissingDefaultIndex;
    try testing.expectEqual(@as(@TypeOf(def.metric), .l2), def.metric);
}

test "DROP INDEX releases the runtime index built for USING vector" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH uvd");
    _ = try h.exec("USE GRAPH uvd");
    _ = try h.exec("CREATE INDEX uvd_idx ON UVD (emb_z) USING vector WITH (metric = 'l2')");
    try testing.expect(indexForProperty("emb_z") != null);

    _ = try h.exec("DROP INDEX uvd_idx");
    // The catalog spelling is "vector"; the DROP path must map it to the same
    // runtime type it was built as, or the index would leak past its catalog row.
    try testing.expect(indexForProperty("emb_z") == null);
}
