// SONNY-6720 regression: DROP GRAPH removes the graph's catalog rows.
//
// DROP GRAPH dropped the graph's data and its graph record, and left every
// index and constraint row scoped to it in the catalog (and in
// `geode_catalog.dat`): a graph re-created under the name inherited them, SHOW
// INDEXES / SHOW CONSTRAINTS listed definitions nobody created, a UNIQUE
// constraint of the old graph enforced against the new one, and the name of a
// name-keyed advanced index stayed taken in every other graph (42P07). Now
// DROP GRAPH removes, with one save, every index row of every type and every
// constraint row whose graph is the dropped one, lowers the unique fence the
// constraints held, and drops what ran for them; rows of other graphs and
// engine-wide rows stay. FLE field metadata is not graph-scoped (its catalog
// keys by label and field), so there is none to remove.
//
// Real executor, real persisted store and catalog, real restarts; no mocks.
//
// CANARY: REQ=REQ-SONNY-6720-DROP-GRAPH-CATALOG; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6720_drop_graph_catalog.zig; OWNER=catalog; UPDATED=2026-11-17

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

fn define(h: *Harness, graph: []const u8) !void {
    const aa = h.arena.allocator();
    try h.run(try std.fmt.allocPrint(aa, "USE GRAPH {s}", .{graph}));
    try h.run("CREATE INDEX bt_6720 FOR (n:P) ON (n.k)");
    try h.run("CREATE INDEX vec_6720 ON V (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("CREATE INDEX net_6720 ON N (addr) USING network_cidr");
    try h.run("CREATE CONSTRAINT uq_6720 FOR (n:P) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE CONSTRAINT nn_6720 FOR (n:P) REQUIRE n.name IS NOT NULL");
}

fn expectNoRows(h: *Harness) !void {
    for ([_][]const u8{ "bt_6720", "vec_6720", "net_6720" }) |n| try testing.expectEqual(@as(usize, 0), try h.indexes(n));
    for ([_][]const u8{ "uq_6720", "nn_6720" }) |n| try testing.expectEqual(@as(usize, 0), try h.constraints(n));
}

test "SONNY-6720: DROP GRAPH removes its index and constraint rows; a re-created graph starts empty" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");
    try h.run("USE GRAPH g1");
    // g2 has its own btree and constraint under other names, and must keep them.
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX keep_idx FOR (n:K) ON (n.k)");
    try h.run("CREATE CONSTRAINT keep_u FOR (n:K) REQUIRE n.id IS UNIQUE");
    try define(&h, "g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("net_6720"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("uq_6720"));

    try h.run("DROP GRAPH g1");
    try h.run("CREATE GRAPH g1");
    try h.run("USE GRAPH g1");
    try expectNoRows(&h);
    // The old UNIQUE no longer enforces against the new graph.
    try h.run("CREATE (:P {id: 1, name: 'a'})");
    try h.run("CREATE (:P {id: 1})");
    // Nothing is left to refuse the definitions a second time.
    try h.run("MATCH (n:P) DETACH DELETE n");
    try define(&h, "g1");

    // g2 kept its own rows, and the name-keyed index of g1 no longer holds its name there.
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.indexes("keep_idx"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("keep_u"));
    try h.run("USE GRAPH g1");
    try h.run("DROP GRAPH g1");
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX net_6720 ON N (addr) USING network_cidr");
}

test "SONNY-6720: the removal is saved: a restart does not bring the rows back" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX keep_idx FOR (n:K) ON (n.k)");
    try define(&h, "g1");
    try h.run("DROP GRAPH g1");

    try h.restartWith(null);
    try h.run("CREATE GRAPH g1");
    try h.run("USE GRAPH g1");
    try expectNoRows(&h);
    try h.run("CREATE (:P {id: 1})");
    try h.run("CREATE (:P {id: 1})");
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.indexes("keep_idx"));
}
