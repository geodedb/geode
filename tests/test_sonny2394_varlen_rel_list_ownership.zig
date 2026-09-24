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
        // Create the catalog singleton on THIS allocator up front, so a query
        // run on another allocator (see `runOnPrivateAllocator`) reuses it.
        _ = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
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

/// Run `query` on a private DebugAllocator and release the result ONLY through
/// its owning API (`ExecutionResult.deinit`). The legacy result path does not
/// own a directly projected var-length list (`owns_value_memory` is false), so
/// those lists are the one allocation allowed to remain -- a pre-existing gap,
/// not something a test may free by hand: a manual free would become a double
/// free the day the owning API releases them. `inspect` reads every row (a list
/// the executor had already freed would read back as poisoned memory) and
/// returns the bytes the projected lists occupy; anything else still allocated
/// after the release is a leak.
fn runOnPrivateAllocator(env: *Env, query: []const u8, inspect: *const fn ([]const []geode.eval.Value) anyerror!usize) !void {
    var dbg: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer dbg.deinitWithoutLeakChecks();
    const allocator = dbg.allocator();

    var q = try env.run(allocator, query);
    const list_bytes = inspect(q.result.rows) catch |err| {
        q.deinit(allocator);
        return err;
    };
    q.deinit(allocator);

    const remaining = dbg.total_requested_bytes;
    if (remaining != 0 and remaining != list_bytes) {
        std.debug.print("after ExecutionResult.deinit: {d} bytes still allocated (projected lists: {d})\n", .{ remaining, list_bytes });
        return error.UnexpectedAllocationRemains;
    }
}

fn inspectDirectLists(rows: []const []geode.eval.Value) !usize {
    try testing.expectEqual(@as(usize, 2), rows.len);
    var bytes: usize = 0;
    for (rows) |row| {
        // Reading the list proves it was not freed (poisoned) by the executor.
        try testing.expect(row[0] == .List);
        try expectKnowsEdgeList(row[0].List);
        bytes += row[0].List.len * @sizeOf(geode.eval.Value);
    }
    return bytes;
}

fn inspectNestedLists(rows: []const []geode.eval.Value) !usize {
    try testing.expectEqual(@as(usize, 2), rows.len);
    var bytes: usize = 0;
    for (rows) |row| {
        try testing.expect(row[0] == .List);
        try testing.expectEqual(@as(usize, 1), row[0].List.len);
        const inner = row[0].List[0];
        try testing.expect(inner == .List);
        try expectKnowsEdgeList(inner.List);
        bytes += (row[0].List.len + inner.List.len) * @sizeOf(geode.eval.Value);
    }
    return bytes;
}

test "SONNY-2394: projecting the relationship variable keeps its list alive" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    try env.seedChain();
    try runOnPrivateAllocator(&env,
        \\MATCH (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN r AS rels
    , &inspectDirectLists);
}

test "SONNY-2394: a nested projection of the relationship variable keeps its list alive" {
    var env = try Env.init(testing.allocator);
    defer env.deinit();
    try env.seedChain();
    try runOnPrivateAllocator(&env,
        \\MATCH (a)-[r:KNOWS*1..2]->(b)
        \\WHERE a.name = 'Alice'
        \\RETURN [r] AS wrapped
    , &inspectNestedLists);
}

// SONNY-2394: `OwnedGraphEntities.deinit()` released the tracked entities but
// not the tracker itself, which `init()` heap-allocates. Every planned read
// that materializes no entity (no matching rows) -- and every planned read that
// FAILS mid-scan (found via tests/canary_recovery_corrupt_latency.zig) -- only
// called deinit(), leaking the tracker on the caller's allocator (gpa in
// production) once per query.
test "SONNY-2394: a planned read that matches nothing does not leak its entity tracker" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    try env.seedChain();

    var q = try env.run(allocator, "MATCH (n:Person) WHERE n.name = 'nobody' RETURN n.name AS name");
    defer q.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), q.result.rows.len);
}
