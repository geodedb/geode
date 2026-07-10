// CANARY: REQ=REQ-GAP-0918-VECTOR-INDEX-VALIDATION; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0918_vector_validation.zig:1; OWNER=index; UPDATED=2026-07-10
//
// Regression tests for GAP-0918: "wrong-dimension vector silently accepted
// into an HNSW index" plus its two sibling silent-accepts:
//
//   (a) inserting a dim-3 vector into a dim-4 HNSW-indexed property was
//       silently accepted (data-integrity risk: mixed-dimension vectors
//       under one index) — now rejected with error.VectorDimensionMismatch
//       (SQLSTATE 22000) at the single property-write chokepoint.
//   (b) CREATE INDEX ... USING HNSW WITH (metric = 'banana') was silently
//       accepted (the WITH options were parsed and discarded) — the metric
//       is now captured and validated (error.InvalidIndexMetric, 42704).
//   (c) a malformed vector literal (vectorf32('[1.0, bad, 2.0]')) silently
//       resolved to NULL — the constructor's InvalidFormat now surfaces as
//       EvalError.TypeMismatch.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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

test "GAP-0918: vector validation (dimension write-check, DDL metric, malformed literal)" {
    // Single harness for all three phases: the hnsw library keeps a worker
    // pool alive across index lifetimes, so per-test store re-init (which a
    // real server never does) would tear global state out from under parked
    // pool threads.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // ---- (a) dimension-mismatched insert is rejected ----
    _ = try h.exec("CREATE GRAPH gap0918");
    _ = try h.exec("USE GRAPH gap0918");
    _ = try h.exec("CREATE INDEX p18_vec_idx ON P18Vec (emb) USING HNSW WITH (metric = 'cosine', ef_construction = 200, M = 16)");

    // Valid dim-4 inserts establish the index dimension.
    _ = try h.exec("CREATE (:P18Vec {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:P18Vec {id: 2, emb: vectorf32('[0.0, 1.0, 0.0, 0.0]')})");

    // The dim-3 insert must be rejected, not silently stored.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P18Vec {id: 4, emb: vectorf32('[1.0, 2.0, 3.0]')})"),
    );

    // Unindexed labels are unaffected.
    _ = try h.exec("CREATE (:P18Free {id: 9, emb: vectorf32('[1.0, 2.0, 3.0]')})");

    // ---- (b) invalid distance metric rejected at CREATE INDEX ----
    try testing.expectError(
        error.InvalidIndexMetric,
        h.exec("CREATE INDEX p18_bad_metric ON P18Bad (emb) USING HNSW WITH (metric = 'banana', ef_construction = 200, M = 16)"),
    );

    // All supported spellings are accepted.
    _ = try h.exec("CREATE INDEX p18_m1 ON P18M1 (emb) USING HNSW WITH (metric = 'l2')");
    _ = try h.exec("CREATE INDEX p18_m2 ON P18M2 (emb) USING HNSW WITH (metric = 'euclidean')");
    _ = try h.exec("CREATE INDEX p18_m3 ON P18M3 (emb) USING HNSW WITH (metric = 'cosine')");
    _ = try h.exec("CREATE INDEX p18_m4 ON P18M4 (emb) USING HNSW WITH (metric = 'dot_product')");

    // ---- (c) malformed vector literal raises a type error, not NULL ----
    try testing.expectError(error.TypeMismatch, h.exec("RETURN vectorf32('[1.0, bad, 2.0]')"));

    // Valid literals still construct.
    const res = try h.exec("RETURN vectorf32('[1.0, 2.0]')");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .Null => return error.UnexpectedNull,
        else => {},
    }
}
