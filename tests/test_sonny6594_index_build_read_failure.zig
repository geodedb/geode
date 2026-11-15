// SONNY-6594 (2): an index build that cannot read a body fails; it never
// registers an index that is missing that row.
//
// The advanced-index builds (`populateAdvancedIndex`, behind CREATE INDEX
// and every rebuild, and the vector index's non-blocking shadow build the
// QUIC and gRPC handlers run after CREATE INDEX) read each body with the
// hydrated getters and skipped a body that could not be read (`orelse
// continue`): the index was registered without the row and answered
// without it until the next rebuild.
//
// A real store with a data directory, the real executor in process and the
// real gRPC handlers in process (`sonny738_r12_grpc_fixture.zig`), and
// `BodyFault` (the caches' body rebuilds fail on demand;
// `sonny6594_body_fault.zig`). Half the indexed bodies are evicted (the
// rest stay resident), CREATE INDEX ... USING vector runs with the rebuilds
// failing, and afterwards (nothing
// failing) `knn` over the indexed property must answer every row: the CREATE
// INDEX failed, or no index was left registered (the next query builds it
// from the catalog), or the index holds every row. A registered index that
// lacks a row answers `knn` short: that is the defect. (An index left
// EMPTY is not served: `knn` scans then, which is why half stay resident.)
//
// CANARY: REQ=REQ-SONNY-6594-INDEX-BUILD-READ-FAILURE; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_index_build_read_failure.zig; OWNER=index; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;

const ROWS: usize = 6;
const KNN = "RETURN size(knn('emb6594', vectorf32('[1.0, 0.0, 0.0, 0.0]'), 6, 'l2')) AS n";

fn seedQuery(i: usize, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "CREATE (:V6594 {{id: {d}, emb6594: vectorf32('[{d}.0, 1.0, 0.0, 0.0]')}})", .{ i, i });
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// The executor in process (no transport: CREATE INDEX builds inline).
const World = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    st: *graph_store.GraphStore,

    fn init(self: *World) !void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        self.st = graph_store.getGlobalStore(testing.allocator);
        self.st.installNodeCacheHydrate();
        self.st.installEdgeCacheHydrate();
        _ = try index_manager.ensureGlobalIndexManager(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;
    }

    fn deinit(self: *World) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn run(self: *World, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], self.ctx);
    }

    fn knnRows(self: *World) !i64 {
        const res = try self.run(KNN);
        return res.rows[0][0].Int;
    }
};

test "SONNY-6594 (2): CREATE INDEX USING vector in process, a body unreadable: the build fails, never registers an index without the row" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var buf: [160]u8 = undefined;
    for (0..ROWS) |i| _ = try w.run(try seedQuery(i, &buf));

    var fault: BodyFault = undefined;
    fault.init(w.st);
    try testing.expect(fault.evictHalfOfLabel(graph_store.DEFAULT_GRAPH_NAME, "V6594") > 0);
    fault.on();
    const created = w.run("CREATE INDEX v6594 ON V6594 (emb6594) USING vector WITH (metric = 'l2')");
    const induced = fault.off();
    const answered = try w.knnRows();
    std.debug.print("SONNY-6594 (2) in process: CREATE INDEX {s}, body read failed: {}, knn answered {d} of {d}\n", .{ if (created) |_| "succeeded" else |e| @errorName(e), induced, answered, ROWS });
    try testing.expect(induced);
    try testing.expectEqual(@as(i64, ROWS), answered);
}

fn knnOverGrpc(ga: std.mem.Allocator, s: []const u8) !i64 {
    const resp = try fx.execute(ga, s, KNN);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("SONNY-6594 (2) knn: {s} {s}\n", .{ e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    const page = switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| p,
        else => return error.UnexpectedPayload,
    };
    const v = page.rows.items[0].values.items[0];
    return switch (v.kind orelse return error.UnexpectedValue) {
        .int_val => |x| x.value,
        else => error.UnexpectedValue,
    };
}

test "SONNY-6594 (2): CREATE INDEX USING vector over gRPC (the handler's shadow build), a body unreadable: no index is left without the row" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("i6594");
    var buf: [160]u8 = undefined;
    for (0..ROWS) |i| try fx.expectRuns(ga, s, try seedQuery(i, &buf));

    var fault: BodyFault = undefined;
    fault.init(f.st);
    try testing.expect(fault.evictHalfOfLabel(graph_store.DEFAULT_GRAPH_NAME, "V6594") > 0);
    fault.on();
    const code = try fx.outcome(ga, s, "CREATE INDEX v6594 ON V6594 (emb6594) USING vector WITH (metric = 'l2')");
    const induced = fault.off();
    const answered = try knnOverGrpc(ga, s);
    std.debug.print("SONNY-6594 (2) gRPC: CREATE INDEX {s}, body read failed: {}, knn answered {d} of {d}\n", .{ code orelse "succeeded", induced, answered, ROWS });
    try testing.expect(induced);
    try testing.expectEqual(@as(i64, ROWS), answered);
}
