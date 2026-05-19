// CANARY: REQ=REQ-PERF-QPS-0811; FEATURE="AggregateFastPath"; ASPECT=PropertyAggregate; STATUS=TESTED; TEST=tests/test_gap0811b_property_aggregate_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0811b regression test: `MATCH (p:Label) RETURN sum|avg|min|max(p.key)`
// must hit the property-only fast-path that iterates the label posting list
// and calls `getNodeProperty(node_id, key)` per slot — skipping the
// materializeNode/property-dupe/graph-name-dupe cost of the regular
// executor path.
//
// Mirrors the Task 2.1 harness in `test_gap0811_aggregation_fastpath.zig`.
// Real store, real parser, real executor — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat helper — mirror Task 2.1.
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "GAP-0811b: sum(p.age) label-index scan without materialize" {
    // Skip on CI runners — the assertion `elapsed_ns < 10_000_000`
    // (10 ms) is a fast-path latency check that fires falsely under
    // shared-runner / 4-way-shard contention even when the fast path
    // is in fact taking effect. Same quarantine pattern as
    // test_gap0814_union_parallelism, test_group_commit_coordinator,
    // and test_two_phase_edge_lock — local devs still run it; CI marks
    // SKIPPED.
    if (std.c.getenv("GITLAB_CI") != null or std.c.getenv("CI") != null) {
        return error.SkipZigTest;
    }
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed 1000 LT_Person. Chosen large enough that the materialize slow
    // path (observed ~18 µs/node after warmup ≈ ~18 ms for 1000) is well
    // above the fast-path budget, so the latency assertion actually
    // detects whether the fast path took effect. Even with high CI load
    // variance the fast path should remain <10ms.
    var i: usize = 0;
    var expected_sum: i64 = 0;
    while (i < 1000) : (i += 1) {
        const aa = h.arena.allocator();
        const age: i64 = @as(i64, @intCast(20 + i));
        expected_sum += age;
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}, age: {d}}})", .{ i, age });
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Warm up to amortize first-run caches.
    {
        var warm = try h.runQuery("MATCH (p:LT_Person) RETURN sum(p.age) AS s");
        warm.deinit(h.arena.allocator());
    }

    const t0 = compat_nanoTimestamp();
    var res = try h.runQuery("MATCH (p:LT_Person) RETURN sum(p.age) AS s");
    defer res.deinit(h.arena.allocator());
    const elapsed_ns = compat_nanoTimestamp() - t0;

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(expected_sum, res.rows[0][0].Int);
    // Slow path at 1000 nodes measured ~18 ms pre-fix. Fast path should
    // stay well under 10 ms even under CI load.
    std.debug.print("[GAP-0811b sum] elapsed_ns={d}\n", .{elapsed_ns});
    try testing.expect(elapsed_ns < 10_000_000);
}

test "GAP-0811b: avg(p.age) returns correct decimal" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const aa = h.arena.allocator();
        const age: i64 = @as(i64, @intCast(20 + i));
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{age: {d}}})", .{age});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var res = try h.runQuery("MATCH (p:LT_Person) RETURN avg(p.age) AS m");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    // sum(20..69)/50 = (20+69)*50/2/50 = 44.5 — the fast path returns Double
    // (not integer-truncated like the existing slow path in match_operations).
    const m = res.rows[0][0];
    const actual: f64 = switch (m) {
        .Double => |f| f,
        .Real => |f| @as(f64, f),
        .Int => |ii| @as(f64, @floatFromInt(ii)),
        else => return error.WrongType,
    };
    try testing.expect(@abs(actual - 44.5) < 0.01);
}

test "GAP-0811b: min/max on same property" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const ages = [_]i64{ 10, 20, 30, 40, 50 };
    for (ages) |age| {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{age: {d}}})", .{age});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    {
        var res = try h.runQuery("MATCH (p:LT_Person) RETURN min(p.age) AS v");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(i64, 10), res.rows[0][0].Int);
    }
    {
        var res = try h.runQuery("MATCH (p:LT_Person) RETURN max(p.age) AS v");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(i64, 50), res.rows[0][0].Int);
    }
}

test "GAP-0811b: WHERE p.age > K narrows the scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Ages 0..99.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{age: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // count of ages > 30: 69 (ages 31..99).
    // sum of ages > 30: (31+99)*69/2 = 4485.
    var res = try h.runQuery("MATCH (p:LT_Person) WHERE p.age > 30 RETURN sum(p.age) AS s");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, 4485), res.rows[0][0].Int);
}
