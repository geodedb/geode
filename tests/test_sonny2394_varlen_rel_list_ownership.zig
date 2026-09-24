// SONNY-2394 regression: variable-length MATCH row ownership.
//
// `executeVariableLengthPathTraversal` (src/execution/match_operations.zig)
// binds per-path heap buffers into the row-evaluation env: the relationship
// variable of `-[r:T*1..2]->` becomes the LIST of the path's edges, and a path
// variable (`p = ...`) becomes a PATH with node/edge arrays. Rejected paths
// (WHERE/FILTER false) freed those buffers, but every ACCEPTED path leaked
// them on the caller's allocator -- `gpa` in production, once per result row.
// Found when tests/test_october_2025_features_integration.zig first actually
// executed (SONNY-2394 made the aggregate `zig build test` run it).
//
// The fix frees them after the row is projected UNLESS the row references
// them: `evalExpr(.Ident)` returns env values by shallow copy, so `RETURN r`
// (or a nested `RETURN [r]`) hands the buffer to the row. These tests pin both
// halves: no leak when the variable is not projected, and no premature free
// (use-after-free / double free under std.testing.allocator) when it is.
//
// The harness mirrors a production request: an isolated engine-backed store,
// a query scratch arena installed on the thread (as quic_connection_handler /
// grpc_server do), and the executor running on the caller's allocator.
//
// CANARY: REQ=REQ-SONNY-2394-VARLEN-ROW-OWNERSHIP; FEATURE="VariableLengthPathRowOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2394_varlen_rel_list_ownership.zig; OWNER=engine; UPDATED=2026-09-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_arena = geode.query_arena;

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Isolated store + catalog + query scratch arena; released on deinit.
const Env = struct {
    tmp: std.testing.TmpDir,
    store: *graph_store.GraphStore,
    scratch: *std.heap.ArenaAllocator,
    prev_scratch: ?std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Env {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(dir);
        const store = try graph_store.initGlobalStore(allocator, dir);
        errdefer graph_store.deinitGlobalStore();
        const scratch = try allocator.create(std.heap.ArenaAllocator);
        scratch.* = std.heap.ArenaAllocator.init(allocator);
        return .{
            .tmp = tmp,
            .store = store,
            .scratch = scratch,
            .prev_scratch = query_arena.pushScratchAllocator(scratch.allocator()),
        };
    }

    fn deinit(self: *Env) void {
        query_arena.popScratchAllocator(self.prev_scratch);
        self.scratch.deinit();
        testing.allocator.destroy(self.scratch);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(testing.allocator, null);
        self.tmp.cleanup();
    }

    /// Chain Alice -> Bob -> Carol -> Dave over KNOWS edges.
    fn seedChain(self: *Env) !void {
        const labels = [_][]const u8{"Person"};
        const names = [_][]const u8{ "Alice", "Bob", "Carol", "Dave" };
        var ids: [names.len]u64 = undefined;
        for (names, 0..) |name, i| {
            ids[i] = try self.store.createNode(&labels);
            try self.store.setNodeProperty(ids[i], "name", .{ .String = name });
        }
        for (0..names.len - 1) |i| {
            _ = try self.store.createEdge(ids[i], ids[i + 1], "KNOWS");
        }
    }

    fn run(self: *Env, allocator: std.mem.Allocator, query: []const u8) !Query {
        _ = self;
        var parsed = try geode.parseGql(query, allocator);
        errdefer parsed.deinit();
        const catalog = try execution.ensureCatalogInstance(allocator);
        const context = execution.ExecutionContext{ .catalog = catalog };
        const result = try execution.executeProgramWithContext(allocator, &parsed.program, context);
        return .{ .parsed = parsed, .result = result };
    }
};

/// A result plus the parse arena it may borrow from (kept alive until after
/// the result is released).
const Query = struct {
    parsed: geode.ParseResult,
    result: execution.ExecutionResult,

    fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.parsed.deinit();
    }
};

fn expectKnowsEdgeList(list: []const geode.eval.Value) !void {
    try testing.expect(list.len >= 1 and list.len <= 2);
    for (list) |item| {
        try testing.expect(item == .Edge);
        try testing.expectEqualStrings("KNOWS", item.Edge.label);
    }
}

test "SONNY-2394: accepted var-length rows do not leak the bound relationship list" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    try env.seedChain();

    // `r` is bound but not projected: every accepted path's edge list must be
    // released (std.testing.allocator reports it as a leak otherwise).
    var q = try env.run(allocator,
        \\MATCH (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN b.name AS name
    );
    defer q.deinit(allocator);
    const result = q.result;
    try testing.expectEqual(@as(usize, 2), result.rows.len);
}

test "SONNY-2394: accepted var-length rows do not leak the bound path arrays" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    try env.seedChain();

    var q = try env.run(allocator,
        \\MATCH p = (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN b.name AS name
    );
    defer q.deinit(allocator);
    const result = q.result;
    try testing.expectEqual(@as(usize, 2), result.rows.len);
}

test "SONNY-2394: projecting the relationship variable keeps its list alive" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    try env.seedChain();

    var q = try env.run(allocator,
        \\MATCH (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN r AS rels
    );
    defer q.deinit(allocator);
    const result = q.result;
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    for (result.rows) |row| {
        // Reading the list proves it was not freed (poisoned) by the executor.
        try testing.expect(row[0] == .List);
        try expectKnowsEdgeList(row[0].List);
        // The row owns the aliased buffer (a legacy result does not free its
        // values); releasing it here would be a DOUBLE FREE if the executor had
        // already freed it -- std.testing.allocator panics on that.
        allocator.free(row[0].List);
    }
}

test "SONNY-2394: a nested projection of the relationship variable keeps its list alive" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    try env.seedChain();

    var q = try env.run(allocator,
        \\MATCH (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN [r] AS wrapped
    );
    defer q.deinit(allocator);
    const result = q.result;
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    for (result.rows) |row| {
        try testing.expect(row[0] == .List);
        try testing.expectEqual(@as(usize, 1), row[0].List.len);
        const inner = row[0].List[0];
        try testing.expect(inner == .List);
        try expectKnowsEdgeList(inner.List);
        allocator.free(inner.List);
        allocator.free(row[0].List);
    }
}
