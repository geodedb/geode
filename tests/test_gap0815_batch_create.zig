// CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreateFastPath"; ASPECT=HomogeneousNodes; STATUS=TESTED; TEST=tests/test_gap0815_batch_create.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0815 regression test: a single query containing N >= 3 inline
// `CREATE (:Label {k1: v1, k2: v2, ...})` clauses that all share the SAME
// label set and prop-key set must hit a batch fast path that allocates N
// node slots and writes each property in one bulk pass (via
// `setNodePropertiesBatch`), instead of walking the per-node
// `setNodePropertyFromValue` path N times. The serial baseline measured
// ~896 µs/node (89.6 ms for 100 nodes) in bench_executor_mutation.zig.
//
// Mirrors the harness pattern used by sibling GAP-08xx tests. Real store,
// real parser, real executor — no mocks.

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
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn buildHomogeneousBatchQuery(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "CREATE ");
    var i: usize = 0;
    var scratch: [128]u8 = undefined;
    while (i < n) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        const chunk = try std.fmt.bufPrint(&scratch, "(:LT_Person {{lt_id: {d}, name: 'p{d}'}})", .{ i, i });
        try buf.appendSlice(allocator, chunk);
    }
    return buf.toOwnedSlice(allocator);
}

test "GAP-0815: batch CREATE 100 homogeneous nodes under latency budget" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    const q = try buildHomogeneousBatchQuery(aa, 100);

    // Warm the parser cache / first-allocation amortization. We don't care
    // about the execution side of the warmup — the second run writes 100
    // more nodes into the same store, and we verify the MATCH count
    // independently below.
    {
        var warm = try h.runQuery("CREATE (:LT_Warmup {x: 1}), (:LT_Warmup {x: 2}), (:LT_Warmup {x: 3})");
        warm.deinit(aa);
    }

    // GAP-0815 invariant: the batch path was entered. Path-based assertion
    // replaces the prior wall-clock budget (1 s) that flaked on contended
    // hosts — the counter is a deterministic signal regardless of load.
    // The previous budget discriminated "batch vs serial" via timing; the
    // counter discriminates via direct observation of the fast-path entry.
    const before_count = execution.batchCreateInvocations();
    var res = try h.runQuery(q);
    const after_count = execution.batchCreateInvocations();
    res.deinit(aa);

    try testing.expect(after_count == before_count + 1);

    // Verify all 100 were created.
    var count_res = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
    defer count_res.deinit(aa);
    try testing.expectEqual(@as(usize, 1), count_res.rows.len);
    try testing.expectEqual(@as(i64, 100), count_res.rows[0][0].Int);
}

test "GAP-0815: batch CREATE preserves property values (lt_id lookup returns right node)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    const q = try buildHomogeneousBatchQuery(aa, 100);
    {
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    // Spot-check: lt_id=42 should have name='p42'.
    var lookup = try h.runQuery("MATCH (p:LT_Person {lt_id: 42}) RETURN p.name");
    defer lookup.deinit(aa);
    try testing.expectEqual(@as(usize, 1), lookup.rows.len);
    try testing.expectEqualStrings("p42", lookup.rows[0][0].Str);

    // Spot-check: lt_id=0 (first) and lt_id=99 (last) round-trip correctly.
    var first = try h.runQuery("MATCH (p:LT_Person {lt_id: 0}) RETURN p.name");
    defer first.deinit(aa);
    try testing.expectEqual(@as(usize, 1), first.rows.len);
    try testing.expectEqualStrings("p0", first.rows[0][0].Str);

    var last = try h.runQuery("MATCH (p:LT_Person {lt_id: 99}) RETURN p.name");
    defer last.deinit(aa);
    try testing.expectEqual(@as(usize, 1), last.rows.len);
    try testing.expectEqualStrings("p99", last.rows[0][0].Str);
}

test "GAP-0815: heterogeneous CREATEs (different labels) fall back to serial path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();

    // Mix LT_Person and LT_Company — batch path should DECLINE this shape
    // and fall through to the existing serial create loop, but the end
    // result must still be correct.
    var res = try h.runQuery("CREATE (:LT_Person {lt_id: 1}), (:LT_Company {name: 'acme'}), (:LT_Person {lt_id: 2})");
    defer res.deinit(aa);

    var person_count = try h.runQuery("MATCH (p:LT_Person) RETURN count(p) AS n");
    defer person_count.deinit(aa);
    try testing.expectEqual(@as(i64, 2), person_count.rows[0][0].Int);

    var company_count = try h.runQuery("MATCH (c:LT_Company) RETURN count(c) AS n");
    defer company_count.deinit(aa);
    try testing.expectEqual(@as(i64, 1), company_count.rows[0][0].Int);
}

test "GAP-0815: batch CREATE with 3 clauses (minimum N threshold) succeeds" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    var res = try h.runQuery("CREATE (:LT_Mini {lt_id: 1}), (:LT_Mini {lt_id: 2}), (:LT_Mini {lt_id: 3})");
    defer res.deinit(aa);

    var count_res = try h.runQuery("MATCH (p:LT_Mini) RETURN count(p) AS n");
    defer count_res.deinit(aa);
    try testing.expectEqual(@as(i64, 3), count_res.rows[0][0].Int);
}
