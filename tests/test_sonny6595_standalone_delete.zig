// SONNY-6595 item 3: `executeDelete`'s branch for a DELETE without a MATCH
// clause deleted the nodes and edges named by `context.bindings`, with none
// of the derived-state hooks the MATCH path runs (`deleteElements`: the
// fulltext delete hook among them). It is unreachable, and was removed:
//
//   * `ExecutionContext.bindings` is set in one place,
//     `match_operations.zig` (the per-row context of `MATCH ... CALL`), and
//     handed only to `call_operations.executeCallStatement`;
//   * that runs a procedure or a CALL subquery, and a CALL subquery runs a
//     query, a CALL or a CREATE (`executeCallSubquery`); any other statement,
//     a DELETE among them, is refused;
//   * every other executor entry builds its context with `bindings` null.
//
// These tests pin the reachable behaviour, the same before and after the
// removal: a DELETE with no MATCH is refused before it runs (its variable is
// not in scope: `param_check`, run by the program and the statement
// executors), and a DELETE in a CALL subquery inside `MATCH ... CALL` is
// refused before it deletes anything.
// Real store, catalog, parser and executor.
//
// CANARY: REQ=REQ-SONNY-6595-STANDALONE-DELETE; FEATURE="DeleteStatement"; ASPECT=UnboundDeleteDeletesNothing; STATUS=TESTED; TEST=tests/test_sonny6595_standalone_delete.zig; OWNER=engine; UPDATED=2026-11-15

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
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Parses and runs every statement of `query` as a program.
    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeProgramWithContext(aa, &parsed.program, self.ctx);
    }

    /// Runs the first statement of `query` through the statement executor.
    fn execStatement(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn count(self: *Harness, label: []const u8) !usize {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN n", .{label});
        const r = try self.exec(q);
        return r.rows.len;
    }
};

test "SONNY-6595 item 3: a DELETE with no MATCH is refused, and so is a DELETE in a CALL subquery; nothing is deleted" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE (:Keep {k: 1})");
    _ = try h.exec("CREATE (:Keep {k: 2})-[:R]->(:Keep {k: 3})");
    try testing.expectEqual(@as(usize, 3), try h.count("Keep"));

    // No MATCH: `n` names nothing, so the statement is refused before it
    // runs (`param_check`: VariableNotInScope), as a program and through the
    // statement executor the transports also call.
    for ([_][]const u8{ "DELETE n", "DETACH DELETE n", "DELETE n RETURN n" }) |q| {
        try testing.expectError(error.VariableNotInScope, h.exec(q));
        try testing.expectError(error.VariableNotInScope, h.execStatement(q));
    }
    try testing.expectEqual(@as(usize, 3), try h.count("Keep"));

    // `MATCH ... CALL` is the one place a statement runs with
    // `context.bindings`; a DELETE in its CALL subquery is refused (by the
    // parser or by `executeCallSubquery`) before anything is deleted.
    const refused = if (h.exec("MATCH (n:Keep) CALL { DETACH DELETE n } RETURN n")) |_| false else |_| true;
    try testing.expect(refused);
    try testing.expectEqual(@as(usize, 3), try h.count("Keep"));
}
