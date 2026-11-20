// SONNY-6747 — a write statement is never aborted by the READ-executor budget.
//
// With GEODE_READ_EXECUTOR_BUDGET_MB=1 and ~2 MiB of fat nodes, the cleanup
// `MATCH (n:L) DETACH DELETE n RETURN count(n) AS deleted` failed with SQLSTATE
// 53200 (ReadQueryBudgetExceeded) and deleted nothing. The read budget
// (src/read_budget.zig) applies only to non-write queries; a write runs under
// the GAP-ENT-0040 write budget instead.
//
// RED: the DETACH DELETE ... RETURN count(n) aborts with ReadQueryBudgetExceeded.
// GREEN: it deletes every node and returns the count, while a pure full-row
// read of the same nodes still aborts with ReadQueryBudgetExceeded.
//
// CANARY: REQ=REQ-SONNY-6747-WRITE-NOT-READ-BUDGETED; FEATURE="ReadExecutorBudget"; ASPECT=WriteExempt; STATUS=TESTED; TEST=tests/test_sonny6747_write_not_read_budgeted.zig; OWNER=execution; UPDATED=2026-11-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const read_budget = geode.read_budget;

const budget_bytes: u64 = 1024 * 1024; // GEODE_READ_EXECUTOR_BUDGET_MB=1
const node_count: usize = 1000;
const pad_len: usize = 2000; // ~2 MiB of pad: twice the budget

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

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// The harness spec's seed: `node_count` RG15_Big nodes, each with a
    /// `pad_len`-byte pad string.
    fn seedBig(self: *Harness) !void {
        const aa = self.arena.allocator();
        const pad = try aa.alloc(u8, pad_len);
        @memset(pad, 'x');
        var i: usize = 1;
        while (i <= node_count) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:RG15_Big {{k: {d}, pad: '{s}'}})", .{ i, pad });
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }

    fn countBig(self: *Harness) !i64 {
        var r = try self.runQuery("MATCH (n:RG15_Big) RETURN count(n) AS cnt");
        defer r.deinit(self.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        return switch (r.rows[0][0]) {
            .Int => |v| v,
            else => error.UnexpectedValue,
        };
    }
};

test "SONNY-6747: DETACH DELETE ... RETURN count(n) over more than the read budget deletes every node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedBig();

    read_budget.setBudgetBytesForTest(budget_bytes);
    defer read_budget.setBudgetBytesForTest(0);

    // RED: error.ReadQueryBudgetExceeded and nothing deleted.
    var r = try h.runQuery("MATCH (n:RG15_Big) DETACH DELETE n RETURN count(n) AS deleted");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, @intCast(node_count)), switch (r.rows[0][0]) {
        .Int => |v| v,
        else => return error.UnexpectedValue,
    });
    try testing.expectEqual(@as(i64, 0), try h.countBig());
}

test "SONNY-6747: a plain DETACH DELETE over more than the read budget deletes every node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedBig();

    read_budget.setBudgetBytesForTest(budget_bytes);
    defer read_budget.setBudgetBytesForTest(0);

    var r = try h.runQuery("MATCH (n:RG15_Big) DETACH DELETE n");
    r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, 0), try h.countBig());
}

test "SONNY-6747: a pure full-row read of the same nodes still aborts with ReadQueryBudgetExceeded" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedBig();

    read_budget.setBudgetBytesForTest(budget_bytes);
    defer read_budget.setBudgetBytesForTest(0);

    try testing.expectError(error.ReadQueryBudgetExceeded, h.runQuery("MATCH (n:RG15_Big) RETURN n.k, n.pad ORDER BY n.pad"));
    try testing.expectError(error.ReadQueryBudgetExceeded, h.runQuery("MATCH (n:RG15_Big) RETURN n"));
    // The aborted reads modified nothing.
    try testing.expectEqual(@as(i64, @intCast(node_count)), try h.countBig());
}
