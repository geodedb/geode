// CANARY: REQ=REQ-GAP-0904-ORDER-BY-ORDINAL; FEATURE="OrderByOrdinal"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0904_order_by_ordinal.zig:1; OWNER=execution; UPDATED=2026-07-10
//
// Regression tests for GAP-0904: "`ORDER BY 0` (non-positive ordinal) panics
// via integer underflow".
//
// Root cause: `getValueForKey` in src/execution/return_and_sorting.zig did
// `@intCast(key.expr.Int - 1)` into usize without checking the ordinal is
// positive, so `ORDER BY 0` underflowed and killed the process once the sort
// comparator ran (requires >= 2 result rows).
//
// Expected behavior after the fix: a non-positive ordinal sorts as a NULL
// key (the same policy as the pre-existing out-of-range-high ordinal, e.g.
// `ORDER BY 99` over 1 column) — no panic, all rows returned.
//
// Note: a negative literal like `ORDER BY -5` parses as Unary(Neg, Int) and
// takes the (safe) expression-evaluation path, so `0` is the only literal
// ordinal that reached the underflow.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

// Zig 0.16 compat: build an absolute path by joining cwd with the tmp sub_path.
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
    // Query-lifetime allocations (row/node materialization) go into an arena,
    // mirroring the server's per-request arena; the executor intentionally
    // does not deep-free materialized entities.
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
        // Bind the session at its final address (init returns by value).
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        // parseGqlOptions with defaults mirrors the server wire path, where
        // order-keys-expr defaults ON (ordinal ORDER BY keys are accepted).
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn seedTwoNodes(h: *Harness) !void {
    _ = try h.exec("CREATE GRAPH gap0904");
    _ = try h.exec("USE GRAPH gap0904");
    _ = try h.exec("CREATE (:Gap0904 {v: 2})");
    _ = try h.exec("CREATE (:Gap0904 {v: 1})");
}

test "GAP-0904: ORDER BY 0 must not panic (sorts as NULL key, returns all rows)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoNodes(&h);

    // Before the fix this panicked (usize underflow) as soon as the sort
    // comparator ran over >= 2 rows.
    const res = try h.exec("MATCH (n:Gap0904) RETURN n.v ORDER BY 0");
    try testing.expectEqual(@as(usize, 2), res.rows.len);
}

test "GAP-0904: out-of-range-high ordinal stays safe (pre-existing policy)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoNodes(&h);

    const res = try h.exec("MATCH (n:Gap0904) RETURN n.v ORDER BY 99");
    try testing.expectEqual(@as(usize, 2), res.rows.len);
}

test "GAP-0904: valid ordinal still sorts correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoNodes(&h);

    const res = try h.exec("MATCH (n:Gap0904) RETURN n.v ORDER BY 1");
    try testing.expectEqual(@as(usize, 2), res.rows.len);

    try testing.expectEqual(@as(i64, 1), res.rows[0][0].Int);
    try testing.expectEqual(@as(i64, 2), res.rows[1][0].Int);
}
