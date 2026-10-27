// CANARY: REQ=REQ-GAP-0930-CREATE-ATOMICITY; FEATURE="Create"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0930_create_atomicity.zig:1; OWNER=engine; UPDATED=2026-07-10
//
// Regression tests for GAP-0930: "CREATE is non-atomic when a property-value
// expression errors mid-statement".
//
// Before the fix, `CREATE (n:T {id: 1, g: GeometryFromText('POINT(banana)')})`
// created the node FIRST and only THEN evaluated its property expressions, so
// a failing expression (surfaced by the GAP-0924 spatial-validation fix as
// error.TypeMismatch) left an ORPHAN node committed with the failed property
// defaulted to NULL — the statement reported an error yet a node persisted.
// The engine transaction / undo log does not rescue this: when the CREATE
// lazily creates its target graph, `beginStatementTxn` returns GraphNotFound
// and no engine txn wraps the sub-ops.
//
// The fix evaluates every property-value expression BEFORE the first store
// write in executeCreate / executeCreateQuery / executeInsert (node and
// relationship endpoints), so an eval error aborts the whole statement with
// nothing committed.
//
// Real store, real parser, real executor — no mocks (mirrors the GAP-08xx
// harness pattern).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

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
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn countLabel(self: *Harness, label: []const u8) !i64 {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
        var res = try self.runQuery(q);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return res.rows[0][0].Int;
    }
};

test "GAP-0930: a single-node CREATE with a bad property expression commits no orphan node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The bad-geometry expression must abort the whole CREATE.
    try testing.expectError(
        error.TypeMismatch,
        h.runQuery("CREATE (n:GAP0930T {id: 1, g: GeometryFromText('POINT(banana)')})"),
    );

    // No orphan node may survive the failed CREATE.
    try testing.expectEqual(@as(i64, 0), try h.countLabel("GAP0930T"));
}

test "GAP-0930: a valid single-node CREATE still commits exactly one node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    {
        var res = try h.runQuery("CREATE (n:GAP0930OK {id: 1, g: GeometryFromText('POINT(1 2)')})");
        res.deinit(h.arena.allocator());
    }
    try testing.expectEqual(@as(i64, 1), try h.countLabel("GAP0930OK"));
}

test "GAP-0930: a relationship CREATE with a bad endpoint property commits neither endpoint" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The right endpoint's property errors — both endpoints (and the edge)
    // must be aborted, leaving nothing behind.
    try testing.expectError(
        error.TypeMismatch,
        h.runQuery("CREATE (a:GAP0930R {ok: 1})-[:REL]->(b:GAP0930R {g: GeometryFromText('POINT(nope)')})"),
    );

    try testing.expectEqual(@as(i64, 0), try h.countLabel("GAP0930R"));
}

test "GAP-0930: a relationship CREATE with a bad edge property commits neither endpoint" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(
        error.TypeMismatch,
        h.runQuery("CREATE (a:GAP0930E {ok: 1})-[:REL {g: GeometryFromText('POINT(nope)')}]->(b:GAP0930E {ok: 2})"),
    );

    try testing.expectEqual(@as(i64, 0), try h.countLabel("GAP0930E"));
}
