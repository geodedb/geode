// CANARY: REQ=REQ-GAP-0914-GROUPBY-UNKNOWN-KEY; FEATURE="Aggregation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0914_0916_aggregation_semantics.zig:1; OWNER=execution; UPDATED=2026-07-10
//
// Regression tests for:
//
//   GAP-0914 — "GROUP BY on an unresolvable identifier collapses to one null
//   group". `RETURN n.cat AS s, count(*) AS c GROUP BY nosuch` silently
//   grouped every row under a single null key instead of erroring — a silent
//   wrong result. Expected: error.UnknownGroupKey (SQLSTATE 42703).
//
//   GAP-0916 — "`sum()` of a string column silently returns 0" while
//   `avg()` of the same column returns NULL — inconsistent, and neither
//   raises a type error. Expected: EvalError.TypeMismatch for non-null,
//   non-numeric aggregate inputs on both.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

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
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn seedCategories(h: *Harness) !void {
    _ = try h.exec("CREATE GRAPH gap0914");
    _ = try h.exec("USE GRAPH gap0914");
    _ = try h.exec("CREATE (:G14 {cat: 'a', v: 1})");
    _ = try h.exec("CREATE (:G14 {cat: 'a', v: 2})");
    _ = try h.exec("CREATE (:G14 {cat: 'b', v: 3})");
}

test "GAP-0914: GROUP BY on an unresolvable identifier errors instead of one null group" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedCategories(&h);

    try testing.expectError(
        error.UnknownGroupKey,
        h.exec("MATCH (n:G14) RETURN n.cat AS s, count(*) AS c GROUP BY nosuch"),
    );
}

test "GAP-0914: GROUP BY on a valid alias still groups correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedCategories(&h);

    const res = try h.exec("MATCH (n:G14) RETURN n.cat AS s, count(*) AS c GROUP BY s");
    try testing.expectEqual(@as(usize, 2), res.rows.len);
}

fn seedStrings(h: *Harness) !void {
    _ = try h.exec("CREATE GRAPH gap0916");
    _ = try h.exec("USE GRAPH gap0916");
    _ = try h.exec("CREATE (:G16 {s: 'alpha', v: 1})");
    _ = try h.exec("CREATE (:G16 {s: 'beta', v: 2})");
}

test "GAP-0916: sum() over a string column raises a type error, not 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedStrings(&h);

    try testing.expectError(error.TypeMismatch, h.exec("MATCH (n:G16) RETURN sum(n.s) AS total"));
}

test "GAP-0916: avg() over a string column raises the same type error" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedStrings(&h);

    try testing.expectError(error.TypeMismatch, h.exec("MATCH (n:G16) RETURN avg(n.s) AS mean"));
}

test "GAP-0916: numeric aggregation still works and ignores missing properties" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedStrings(&h);
    // Node without `v` must be ignored (NULL-skipping is standard semantics).
    _ = try h.exec("CREATE (:G16 {s: 'gamma'})");

    const res = try h.exec("MATCH (n:G16) RETURN sum(n.v) AS total");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 3), res.rows[0][0].Int);
}
