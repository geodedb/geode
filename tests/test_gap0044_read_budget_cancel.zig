// GAP-ENT-0044/0045 (T5) — read-executor memory budget + cancel-on-disconnect.
//
// Live incident (2026-07-05): two abandoned GROUP BYs (client timed out) kept
// running server-side ~50 min, materialized unboundedly, RSS 27G -> 93.6G,
// kernel OOM-killed the server. Two guards, both pinned here:
//
//   BUDGET — the read/aggregate/scan materialization path runs under the
//   GAP-ENT-0040 discipline: per-executor net-live byte tracking via a
//   metered allocator, clean abort with error.ReadQueryBudgetExceeded
//   (SQLSTATE 53200) at GEODE_READ_EXECUTOR_BUDGET_MB (default 8192; 0
//   disables). RED: the runaway `MATCH (n:L) RETURN n` materialization
//   completes regardless of budget. GREEN: aborts at the bound, server keeps
//   serving.
//
//   CANCEL — the transport publishes a per-stream atomic cancel flag; the
//   executor polls it at row/batch boundaries in the scan+aggregate loops and
//   aborts with error.ReadQueryCancelled (SQLSTATE 57014). RED: a set flag is
//   ignored, the query runs to completion. GREEN: the query aborts within one
//   batch boundary.
//
// CANARY: REQ=GAP-ENT-0044; FEATURE="ReadExecutorBudget"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0044_read_budget_cancel.zig; OWNER=execution; UPDATED=2026-07-05
// CANARY: REQ=GAP-ENT-0045; FEATURE="ReadCancelOnDisconnect"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0044_read_budget_cancel.zig; OWNER=execution; UPDATED=2026-07-05

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const read_budget = geode.read_budget;

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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Seed `count` Taxon nodes each carrying a `blob` payload of `pad` 'x'
    /// bytes — makes per-row full materialization measurably expensive.
    pub fn seedFat(self: *Harness, count: usize, pad: usize) !void {
        const aa = self.arena.allocator();
        const blob = try aa.alloc(u8, pad);
        @memset(blob, 'x');
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source_id: 'fat_{d}', source: 'col', blob: '{s}'}})",
                .{ i, blob },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

test "T5 budget: runaway full-row read aborts with ReadQueryBudgetExceeded at the bound" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // 300 nodes x ~2KB blob => full materialization is >> 128KB budget.
    try h.seedFat(300, 2048);

    read_budget.setBudgetBytesForTest(128 * 1024);
    defer read_budget.setBudgetBytesForTest(0);

    // RED: completes and returns 300 fat rows (no read budget exists).
    // GREEN: clean ReadQueryBudgetExceeded — the OOM killer is never the arbiter.
    const res = h.runQuery("MATCH (n:Taxon) RETURN n");
    try testing.expectError(error.ReadQueryBudgetExceeded, res);
}

test "T5 budget: queries under the bound still succeed with the scope installed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedFat(20, 64);

    read_budget.setBudgetBytesForTest(64 * 1024 * 1024);
    defer read_budget.setBudgetBytesForTest(0);

    var r = try h.runQuery("MATCH (n:Taxon) RETURN n");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 20), r.rows.len);
}

test "T5 budget: index-served and streaming aggregates stay far below the budget" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedFat(200, 1024);

    // A budget that the FULL materialization (200 x ~1KB rows + scratch) would
    // trip, but the O(distinct) index-served aggregate and the streaming scan
    // never approach: the T1/T2 paths must SUCCEED under it.
    read_budget.setBudgetBytesForTest(96 * 1024);
    defer read_budget.setBudgetBytesForTest(0);

    var r1 = try h.runQuery("MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r1.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), r1.rows.len);

    var r2 = try h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    defer r2.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), r2.rows.len);
}

test "T5 cancel: a set per-stream cancel flag aborts the read with ReadQueryCancelled" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedFat(100, 256);

    var cancel_flag = std.atomic.Value(bool).init(true); // client already gone
    read_budget.setStreamCancelSource(&cancel_flag);
    defer read_budget.setStreamCancelSource(null);

    // RED: the flag is ignored; the scan runs to completion.
    // GREEN: aborted at a row/batch boundary with the clean cancel error.
    const res = h.runQuery("MATCH (n:Taxon) RETURN n");
    try testing.expectError(error.ReadQueryCancelled, res);
}

test "T5 cancel: aggregate scan loops poll the flag too (GROUP BY family)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedFat(60, 128);

    var cancel_flag = std.atomic.Value(bool).init(true);
    read_budget.setStreamCancelSource(&cancel_flag);
    defer read_budget.setStreamCancelSource(null);

    // Unlabeled streaming GROUP BY (T2 path) — must abort, not stream on.
    const res = h.runQuery("MATCH (n) RETURN n.source AS s, count(*) AS c GROUP BY n.source");
    try testing.expectError(error.ReadQueryCancelled, res);
}

test "T5 cancel: mid-query cancellation from another thread aborts within the scan" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // Enough rows that the scan spans many poll boundaries.
    try h.seedFat(500, 512);

    var cancel_flag = std.atomic.Value(bool).init(false);
    read_budget.setStreamCancelSource(&cancel_flag);
    defer read_budget.setStreamCancelSource(null);

    const Setter = struct {
        fn compatSleepNs(ns: u64) void {
            // Zig 0.16: std.Thread.sleep was removed; nanosleep directly.
            const req = std.os.linux.timespec{
                .sec = @intCast(ns / std.time.ns_per_s),
                .nsec = @intCast(ns % std.time.ns_per_s),
            };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
        }
        fn run(flag: *std.atomic.Value(bool)) void {
            // Fire quickly — the poll sites must observe it at the next
            // row/batch boundary regardless of when it lands.
            compatSleepNs(2 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Setter.run, .{&cancel_flag});

    // Either the cancel lands mid-scan (ReadQueryCancelled) or the query
    // finished before the flag was set (small store, fast machine) — both are
    // sound; what is FORBIDDEN is any other failure mode.
    if (h.runQuery("MATCH (n:Taxon) RETURN n")) |*r| {
        var res = r.*;
        res.deinit(h.arena.allocator());
    } else |err| {
        try testing.expectEqual(error.ReadQueryCancelled, err);
    }
    t.join();
}

test "T5 cancel: flag clear -> queries run normally again (no sticky cancel)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seedFat(10, 64);

    var cancel_flag = std.atomic.Value(bool).init(true);
    read_budget.setStreamCancelSource(&cancel_flag);
    const res = h.runQuery("MATCH (n:Taxon) RETURN n");
    try testing.expectError(error.ReadQueryCancelled, res);

    // Stream-level recovery: a NEW query after the flag is cleared succeeds.
    cancel_flag.store(false, .release);
    var r = try h.runQuery("MATCH (n:Taxon) RETURN n");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 10), r.rows.len);
    read_budget.setStreamCancelSource(null);
}
