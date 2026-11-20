// SONNY-6703 regression: the vector (HNSW) index is the graph's own.
//
// The runtime structure behind `CREATE INDEX ... USING HNSW` was one
// process-wide object per index NAME, and knn() consulted it only when its
// label was the sole carrier of the property in the session's graph and
// every other graph: a same-named vector property in ANOTHER graph revoked the
// index's authority and the query was answered by a plain scan that never
// checked the query metric against the index's. SONNY-1319 only refused a
// same-named index in a second graph. Now the runtime index is keyed by graph
// and name (`index_manager.runtimeKey`), so each graph builds, validates and
// uses its own index, two graphs can use one index name with different
// metrics and dimensions, a carrier in another graph does not matter, and a
// scan that answers in place of an index still checks the metric
// (42704, `VectorMetricMismatch`). ISO/IEC 39075:2024 has no vector index; this
// is a Geode extension whose contract is the existing metric check.
//
// Real executor, real persisted store, catalog and index manager; no mocks.
//
// CANARY: REQ=REQ-SONNY-6703-PER-GRAPH-VECTOR-INDEX; FEATURE="VectorIndex"; ASPECT=PerGraphIndex; STATUS=TESTED; TEST=tests/test_sonny6703_per_graph_vector_index.zig; OWNER=index; UPDATED=2026-11-17

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

    fn init(allocator: std.mem.Allocator) !Harness {
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

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Tear down; run `between` (if any) while nothing is loaded; come back up.
    fn restartWith(self: *Harness, between: ?*const fn ([]const u8) anyerror!void) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        if (between) |f| try f(self.data_dir);

        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The error `query` was refused with, by name (so the assertion is a
    /// runtime one, and compiles against an engine that has no such error).
    fn refusal(self: *Harness, query: []const u8) ![]const u8 {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return @errorName(err);
    }

    /// How many rows of `show` (SHOW INDEXES / SHOW CONSTRAINTS) name `name`
    /// in column 0, in the session's graph.
    fn listed(self: *Harness, show: []const u8, name: []const u8) !usize {
        const res = try self.exec(show);
        var n: usize = 0;
        for (res.rows) |row| {
            if (row.len == 0) continue;
            switch (row[0]) {
                .Str => |s| if (std.mem.eql(u8, s, name)) {
                    n += 1;
                },
                else => {},
            }
        }
        return n;
    }

    fn indexes(self: *Harness, name: []const u8) !usize {
        return self.listed("SHOW INDEXES", name);
    }

    fn constraints(self: *Harness, name: []const u8) !usize {
        return self.listed("SHOW CONSTRAINTS", name);
    }

    /// The refusal name of `query`, or "ok".
    fn outcome(self: *Harness, query: []const u8) []const u8 {
        _ = self.exec(query) catch |err| return @errorName(err);
        return "ok";
    }

    /// The integer in row 0, column 0 of `query` (`size(knn(...))`).
    fn listLen(self: *Harness, query: []const u8) !usize {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1 or res.rows[0].len != 1) return error.UnexpectedShape;
        return switch (res.rows[0][0]) {
            .Int => |n| @intCast(n),
            else => error.NotAnInteger,
        };
    }
};

const k_l2 = "RETURN size(knn('emb', vectorf32('[1.0, 0.0]'), 10, 'l2')) AS n";
const k_cos = "RETURN size(knn('emb', vectorf32('[1.0, 0.0]'), 10, 'cosine')) AS n";
const k_l2_3 = "RETURN size(knn('emb', vectorf32('[1.0, 0.0, 0.0]'), 10, 'l2')) AS n";
const k_cos_3 = "RETURN size(knn('emb', vectorf32('[1.0, 0.0, 0.0]'), 10, 'cosine')) AS n";

test "SONNY-6703: two graphs hold independent, validated vector indexes under one name" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");

    // g1: an l2 index of dimension 2. g2: a cosine index of dimension 3, same name.
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("CREATE (:V {id: 1, emb: vectorf32('[1.0, 0.0]')})");
    try h.run("CREATE (:V {id: 2, emb: vectorf32('[0.0, 1.0]')})");
    try h.run("USE GRAPH g2");
    try testing.expectEqualStrings("ok", h.outcome("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'cosine')"));
    try testing.expectEqualStrings("ok", h.outcome("CREATE (:V {id: 7, emb: vectorf32('[1.0, 0.0, 0.0]')})"));

    // Each graph answers from its own index, with its own metric check.
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 2), try h.listLen(k_l2));
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_cos_3));
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_l2_3));

    // SHOW lists each graph's own row.
    try testing.expectEqual(@as(usize, 1), try h.indexes("vec"));
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("vec"));
}

test "SONNY-6703: a same-named vector property in another graph, or on another label, does not unvalidate knn" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g3");
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("CREATE (:V {id: 1, emb: vectorf32('[1.0, 0.0]')})");
    try h.run("CREATE (:V {id: 2, emb: vectorf32('[0.0, 1.0]')})");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));

    // Another graph carries the property, with no index there.
    try h.run("USE GRAPH g3");
    try h.run("CREATE (:V {id: 9, emb: vectorf32('[1.0, 0.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_cos)); // g3 has no index: a scan
    try h.run("USE GRAPH g1");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    // g1 still answers from its index, and with its own rows only.
    try testing.expectEqual(@as(usize, 2), try h.listLen(k_l2));

    // A second label of g1 carries the property: the index no longer covers
    // every row knn() would scan, so a scan answers, and it checks the metric.
    try h.run("CREATE (:W {id: 5, emb: vectorf32('[1.0, 1.0]')})");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    try testing.expectEqual(@as(usize, 3), try h.listLen(k_l2));
}

test "SONNY-6703: DROP INDEX and DROP GRAPH take away one graph's index only" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");
    for ([_][]const u8{ "g1", "g2" }) |g| {
        const use = try std.fmt.allocPrint(h.arena.allocator(), "USE GRAPH {s}", .{g});
        try h.run(use);
        try h.run("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'l2')");
        try h.run("CREATE (:V {id: 1, emb: vectorf32('[1.0, 0.0]')})");
        try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    }
    try h.run("USE GRAPH g1");
    try h.run("DROP INDEX vec");
    // g1 has no index now: cosine is a plain scan. g2's index is intact.
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_cos));
    try h.run("USE GRAPH g2");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_l2));

    // DROP GRAPH tears the graph's runtime index down with its data: the
    // re-created graph of the same name (its catalog row is still there) is
    // rebuilt from the NEW graph's rows only, and g1 is untouched.
    try h.run("DROP GRAPH g2");
    try h.run("CREATE GRAPH g2");
    try h.run("USE GRAPH g2");
    try h.run("CREATE (:V {id: 3, emb: vectorf32('[1.0, 0.0]')})");
    try h.run("CREATE (:V {id: 4, emb: vectorf32('[0.0, 1.0]')})");
    try h.run("CREATE (:V {id: 5, emb: vectorf32('[1.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 3), try h.listLen(k_l2));
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_cos));
}

test "SONNY-6703: each graph's index is rebuilt from the catalog after a restart" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("CREATE (:V {id: 1, emb: vectorf32('[1.0, 0.0]')})");
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX vec ON V (emb) USING HNSW WITH (metric = 'cosine')");
    try h.run("CREATE (:V {id: 1, emb: vectorf32('[1.0, 0.0, 0.0]')})");
    try h.run("CREATE (:V {id: 2, emb: vectorf32('[0.0, 1.0, 0.0]')})");

    try h.restartWith(null);
    try h.run("USE GRAPH g1");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_cos));
    try testing.expectEqual(@as(usize, 1), try h.listLen(k_l2));
    try h.run("USE GRAPH g2");
    try testing.expectEqualStrings("VectorMetricMismatch", h.outcome(k_l2_3));
    try testing.expectEqual(@as(usize, 2), try h.listLen(k_cos_3));
}
