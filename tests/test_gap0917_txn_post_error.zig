// CANARY: REQ=REQ-GAP-0917-TXN-POST-ERROR-REJECT; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0917_txn_post_error.zig:1; OWNER=engine; UPDATED=2026-07-10
//
// Regression tests for GAP-0917: "statement after a mid-transaction error is
// not rejected".
//
// Root cause: executeProgramWithContext caught a failing statement inside an
// active transaction and simply continued, so in
// `BEGIN; CREATE ...; <error>; CREATE ...; COMMIT` both CREATEs executed and
// COMMIT committed them. ISO/IEC 39075 requires post-error statements to be
// rejected until ROLLBACK.
//
// Expected behavior after the fix: the failure marks the transaction FAILED;
// subsequent statements are rejected (never executed); COMMIT performs an
// implicit rollback and the batch reports the original error (SQLSTATE
// 25P02 class on the wire); ROLLBACK closes the failed transaction and
// later statements run normally.

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

    /// Execute a semicolon-separated multi-statement program in one batch,
    /// exactly like the wire path does.
    pub fn execProgram(self: *Harness, program: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(program, aa, .{});
        defer parsed.deinit();
        return execution.executeProgramWithContext(aa, &parsed.program, self.ctx);
    }

    pub fn countLabel(self: *Harness, comptime label: []const u8) !i64 {
        const res = try self.execProgram("MATCH (n:" ++ label ++ ") RETURN count(n)");
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            else => error.ExpectedInt,
        };
    }
};

test "GAP-0917: statements after a mid-transaction error are rejected and COMMIT aborts" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.execProgram("CREATE GRAPH gap0917a");
    _ = try h.execProgram("USE GRAPH gap0917a");

    // The runtime error (division by zero) fails the transaction; the second
    // CREATE must be rejected and COMMIT must abort with the original error.
    try testing.expectError(
        error.DivisionByZero,
        h.execProgram("BEGIN; CREATE (:T {v: 1}); RETURN 1/0; CREATE (:T {v: 2}); COMMIT"),
    );

    // Nothing from the aborted transaction may be visible afterwards.
    try testing.expectEqual(@as(i64, 0), try h.countLabel("T"));
}

test "GAP-0917: ROLLBACK closes a failed transaction and later statements run" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.execProgram("CREATE GRAPH gap0917b");
    _ = try h.execProgram("USE GRAPH gap0917b");

    const res = try h.execProgram("BEGIN; RETURN 1/0; ROLLBACK; CREATE (:R {v: 1})");
    _ = res;

    try testing.expectEqual(@as(i64, 1), try h.countLabel("R"));
}

test "GAP-0917: a failed transaction left open at batch end aborts" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.execProgram("CREATE GRAPH gap0917c");
    _ = try h.execProgram("USE GRAPH gap0917c");

    try testing.expectError(
        error.DivisionByZero,
        h.execProgram("BEGIN; RETURN 1/0; CREATE (:E {v: 9})"),
    );
    try testing.expectEqual(@as(i64, 0), try h.countLabel("E"));
}

test "GAP-0917: a clean transaction still commits" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.execProgram("CREATE GRAPH gap0917d");
    _ = try h.execProgram("USE GRAPH gap0917d");

    const res = try h.execProgram("BEGIN; CREATE (:C {v: 1}); COMMIT");
    _ = res;
    try testing.expectEqual(@as(i64, 1), try h.countLabel("C"));
}
