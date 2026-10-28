// Spec geode-vectorization-and-reranking: "verify actual plans rather than
// assuming execution semantics". Two engine defects:
//
//   (a) `VectorIndexWrapper.searchWithMetric` (src/index/advanced_types_index.zig)
//       ignored the caller's metric entirely — the HNSW graph is always built
//       and searched with `self.metric`, so `knn('emb', $q, 10, 'cosine')`
//       against an l2 index silently returned the l2-index neighbour set,
//       relabeled with cosine-distance scores computed post hoc. Wrong
//       answers, no error.
//
//   (b) `inner_product` is accepted as a query-side metric synonym by the DDL
//       validator (src/execution.zig) and by the index-build metric mapper
//       (src/execution/statement_dispatcher.zig), but `parseVectorMetric`
//       (src/eval.zig) rejected it with InvalidArgs — so `CREATE INDEX ...
//       WITH (metric = 'inner_product')` succeeded, and the very
//       `distance(..., 'inner_product')` call a caller would use to score
//       against it failed.
//
// CANARY: REQ=REQ-VECTOR-KNN-METRIC-VALIDATE-001; FEATURE="VectorIndex"; ASPECT=QueryMetricMatchesIndex; STATUS=TESTED; TEST=tests/test_knn_metric_mismatch.zig; OWNER=index; UPDATED=2026-08-28

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

test "knn with mismatched metric errors instead of silently relabeling" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH kmm");
    _ = try h.exec("USE GRAPH kmm");
    _ = try h.exec("CREATE INDEX kmm_idx ON KMM (emb) USING vector WITH (metric = 'l2')");

    _ = try h.exec("CREATE (:KMM {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:KMM {id: 2, emb: vectorf32('[0.0, 1.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:KMM {id: 3, emb: vectorf32('[0.0, 0.0, 1.0, 0.0]')})");

    // The index was built with 'l2'; querying it with 'cosine' must fail
    // instead of silently returning the l2-index neighbour set relabeled with
    // cosine scores.
    try testing.expectError(
        error.VectorMetricMismatch,
        h.exec("RETURN knn('emb', vectorf32('[1.0, 0.0, 0.0, 0.0]'), 2, 'cosine')"),
    );
}

test "knn with matching metric still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH kmm2");
    _ = try h.exec("USE GRAPH kmm2");
    _ = try h.exec("CREATE INDEX kmm2_idx ON KMM2 (emb) USING vector WITH (metric = 'l2')");

    _ = try h.exec("CREATE (:KMM2 {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:KMM2 {id: 2, emb: vectorf32('[0.0, 1.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:KMM2 {id: 3, emb: vectorf32('[0.0, 0.0, 1.0, 0.0]')})");

    const res = try h.exec("RETURN knn('emb', vectorf32('[1.0, 0.0, 0.0, 0.0]'), 2, 'l2')");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .List => |items| {
            try testing.expect(items.len > 0);
            try testing.expect(items.len <= 2);
        },
        else => return error.ExpectedListFromKnn,
    }
}

test "inner_product accepted as query-side metric synonym for dot" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH kmm3");
    _ = try h.exec("USE GRAPH kmm3");

    const inner_res = try h.exec(
        "RETURN distance(vectorf32('[1.0, 0.0]'), vectorf32('[0.0, 1.0]'), 'inner_product')",
    );
    const dot_res = try h.exec(
        "RETURN distance(vectorf32('[1.0, 0.0]'), vectorf32('[0.0, 1.0]'), 'dot_product')",
    );

    try testing.expectEqual(@as(usize, 1), inner_res.rows.len);
    try testing.expectEqual(@as(usize, 1), dot_res.rows.len);
    switch (inner_res.rows[0][0]) {
        .Decimal => |inner_dec| switch (dot_res.rows[0][0]) {
            .Decimal => |dot_dec| {
                try testing.expectEqual(dot_dec.coeff, inner_dec.coeff);
                try testing.expectEqual(dot_dec.scale, inner_dec.scale);
            },
            else => return error.ExpectedDecimalFromDistance,
        },
        else => return error.ExpectedDecimalFromDistance,
    }
}
