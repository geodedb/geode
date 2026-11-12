// SONNY-2847 regression: MERGE's property index and two value-equal nodes.
//
// The ticket: MERGE's property index (graph_store.merge_prop_index) held ONE
// node per (graph, label, key, value). CREATE writes no uniqueness, so two
// nodes can hold one key (two CREATEd `{k: 7}`, or 7 and 7.0, which key
// alike since SONNY-2675 round 6). Deleting the node the index held, or
// moving it off the key with SET, dropped the entry; the next MERGE trusted
// the miss and created a third node instead of matching the one left.
//
// SONNY-2806 (rounds 7 and 8) made an entry name the LOWEST holder and carry
// a "shared" flag, so removing one holder of several leaves the entry
// unresolved and the next lookup finds the holders that remain. This test
// pins the ticket's own shapes on the paths the ticket names, so the fix
// cannot regress unnoticed: two identical CREATEd values (not only 1 and
// 1.0), the holder removed by DELETE and by SET, the lowest and the highest
// holder removed, a registered composite MERGE key, and the server's bulk
// MERGE helpers, on an in-memory and a persisted session.
//
// Real executor, store, adapter and catalog; no mocks.
//
// CANARY: REQ=REQ-SONNY-2847-MERGE-INDEX-MULTI-HOLDER; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2847_merge_index_multi_holder.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gsa = geode.graph_storage_adapter;
const PropKV = gsa.StorageAdapter.PropKV;
const G = graph_store.DEFAULT_GRAPH_NAME;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator, persisted: bool) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer if (tmp) |*t| t.cleanup();
        errdefer if (data_dir) |d| allocator.free(d);
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
        }

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
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
        if (self.data_dir) |d| self.allocator.free(d);
        self.arena.deinit();
        if (self.tmp) |*t| t.cleanup();
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The single cell `query` returns, rendered ('text', 12, null).
    fn cell(self: *Harness, query: []const u8) ![]const u8 {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1 or res.rows[0].len < 1) {
            std.debug.print("{s}: {d} rows\n", .{ query, res.rows.len });
            return error.UnexpectedRows;
        }
        const aa = self.arena.allocator();
        return switch (res.rows[0][0]) {
            .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
            .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
            .Null => "null",
            else => |v| try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
        };
    }

    fn expectCell(self: *Harness, query: []const u8, want: []const u8) !void {
        const got = try self.cell(query);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ query, want, got });
            return error.WrongAnswer;
        }
    }

    fn expectCount(self: *Harness, label: []const u8, want: []const u8) !void {
        const q = try std.fmt.allocPrint(self.arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
        try self.expectCell(q, want);
    }
};

/// The ticket's shapes on the executor: two CREATEd nodes holding one key,
/// one of them removed by DELETE or moved off the key by SET; MERGE must
/// match the node left and create nothing.
fn exerciseExecutor(h: *Harness) !void {
    // ---- two identical values; DELETE the newer (the node the old index kept) ----
    try h.run("CREATE (:A {k: 7, t: 'first'})");
    try h.run("CREATE (:A {k: 7, t: 'second'})");
    try h.run("MATCH (n:A {t: 'second'}) DELETE n");
    try h.expectCell("MERGE (n:A {k: 7}) RETURN n.t AS t", "'first'");
    try h.expectCount("A", "1");

    // ---- DELETE the older (the lowest holder, the entry's own node) ----
    try h.run("CREATE (:B {k: 7, t: 'first'})");
    try h.run("CREATE (:B {k: 7, t: 'second'})");
    try h.run("MATCH (n:B {t: 'first'}) DELETE n");
    try h.expectCell("MERGE (n:B {k: 7}) RETURN n.t AS t", "'second'");
    try h.expectCount("B", "1");

    // ---- SET moves the indexed holder off the key ----
    try h.run("CREATE (:C {k: 'x', t: 'first'})");
    try h.run("CREATE (:C {k: 'x', t: 'second'})");
    try h.run("MATCH (n:C {t: 'first'}) SET n.k = 'y'");
    try h.expectCell("MERGE (n:C {k: 'x'}) RETURN n.t AS t", "'second'");
    try h.run("MATCH (n:C {t: 'second'}) SET n.k = 'z'");
    try h.expectCell("MERGE (n:C {k: 'y'}) RETURN n.t AS t", "'first'");
    try h.expectCount("C", "2");

    // ---- REMOVE takes the property away from one of two holders ----
    try h.run("CREATE (:D {k: 3, t: 'first'})");
    try h.run("CREATE (:D {k: 3, t: 'second'})");
    try h.run("MATCH (n:D {t: 'first'}) REMOVE n.k");
    try h.expectCell("MERGE (n:D {k: 3}) RETURN n.t AS t", "'second'");
    try h.expectCount("D", "2");

    // ---- across representations: 7 and 7.0 key alike ----
    try h.run("CREATE (:E {k: 7, t: 'int'})");
    try h.run("CREATE (:E {k: 7.0, t: 'dec'})");
    try h.run("MATCH (n:E {t: 'int'}) DELETE n");
    try h.expectCell("MERGE (n:E {k: 7}) RETURN n.t AS t", "'dec'");
    try h.expectCount("E", "1");

    // ---- three holders, two removed one by one ----
    try h.run("CREATE (:F {k: 1, t: 'a'})");
    try h.run("CREATE (:F {k: 1, t: 'b'})");
    try h.run("CREATE (:F {k: 1, t: 'c'})");
    try h.run("MATCH (n:F {t: 'a'}) DELETE n");
    try h.run("MATCH (n:F {t: 'c'}) DELETE n");
    try h.expectCell("MERGE (n:F {k: 1}) RETURN n.t AS t", "'b'");
    try h.expectCount("F", "1");

    // ---- a registered composite MERGE key: same rules ----
    graph_store.registerCompositeMergeKey(&.{ "a", "b" });
    defer graph_store.clearCompositeMergeKeysForTest();
    try h.run("CREATE (:M {a: 1, b: 2, t: 'first'})");
    try h.run("CREATE (:M {a: 1, b: 2, t: 'second'})");
    try h.run("MATCH (n:M {t: 'first'}) DELETE n");
    try h.expectCell("MERGE (n:M {a: 1, b: 2}) RETURN n.t AS t", "'second'");
    try h.run("CREATE (:M {a: 5, b: 5, t: 'third'})");
    try h.run("CREATE (:M {a: 5, b: 5, t: 'fourth'})");
    try h.run("MATCH (n:M {t: 'fourth'}) DELETE n");
    try h.expectCell("MERGE (n:M {a: 5, b: 5}) RETURN n.t AS t", "'third'");
    try h.expectCount("M", "2");
}

test "SONNY-2847: MERGE finds the remaining holder after a DELETE, SET or REMOVE, in-memory" {
    const saved_env: ?[]u8 = if (std.c.getenv("GEODE_DATA_DIR")) |p| try testing.allocator.dupe(u8, std.mem.span(p)) else null;
    defer if (saved_env) |v| {
        const z = testing.allocator.dupeZ(u8, v) catch unreachable;
        defer testing.allocator.free(z);
        _ = setenv("GEODE_DATA_DIR", z, 1);
        testing.allocator.free(v);
    };
    _ = unsetenv("GEODE_DATA_DIR");

    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try exerciseExecutor(&h);
}

test "SONNY-2847: MERGE finds the remaining holder after a DELETE, SET or REMOVE, persisted" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try exerciseExecutor(&h);
}

fn tOf(id: u64) []const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const v = store.getNodeProperty(id, "t") orelse return "";
    return switch (v) {
        .String => |t| t,
        else => "?",
    };
}

test "SONNY-2847: the server's bulk MERGE helpers find the remaining holder" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    const prev = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const store = graph_store.getGlobalStore(testing.allocator);

    // Single-key bulk MERGE (adapter.bulkMergeNode / WithReservedId).
    try h.run("CREATE (:BK {k: 9, t: 'first'})");
    try h.run("CREATE (:BK {k: 9, t: 'second'})");
    try h.run("MATCH (n:BK {t: 'second'}) DELETE n");
    {
        const r = try adapter.bulkMergeNode(G, "BK", "k", .{ .Int = 9 }, &.{}, null, false);
        try testing.expect(!r.wrote);
        try testing.expectEqualStrings("first", tOf(r.id));
    }
    try h.run("CREATE (:BK {k: 9, t: 'third'})");
    try h.run("MATCH (n:BK {t: 'first'}) DELETE n");
    {
        const r = try adapter.bulkMergeNodeWithReservedId(G, store.reserveNodeId(), "BK", "k", .{ .Int = 9 }, &.{}, false);
        try testing.expect(!r.wrote);
        try testing.expectEqualStrings("third", tOf(r.id));
    }
    try h.expectCount("BK", "1");

    // Multi-property bulk MERGE over a registered composite key.
    graph_store.registerCompositeMergeKey(&.{ "a", "b" });
    defer graph_store.clearCompositeMergeKeysForTest();
    try h.run("CREATE (:BM {a: 1, b: 1, t: 'first'})");
    try h.run("CREATE (:BM {a: 1, b: 1, t: 'second'})");
    try h.run("MATCH (n:BM {t: 'first'}) DELETE n");
    const mp = [_]PropKV{ .{ .key = "a", .value = .{ .Int = 1 } }, .{ .key = "b", .value = .{ .Int = 1 } } };
    {
        const r = try adapter.bulkMergeNodeWithReservedIdMultiProp(G, store.reserveNodeId(), "BM", &mp, &.{}, false);
        try testing.expect(!r.wrote);
        try testing.expectEqualStrings("second", tOf(r.id));
    }
    try h.expectCount("BM", "1");
}
