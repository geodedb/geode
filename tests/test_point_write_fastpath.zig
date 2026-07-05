// GAP (write-path OOM, 2026-07-04): engine-direct point writes + legacy
// write-executor working-set budget.
//
// Incident: ONE single-node `MATCH (n:Taxon) WHERE n.source_id='X' SET
// n.p='v'` on the 14.27M store ground 50+ min materializing O(graph) on the
// legacy write executor, RSS 82 -> 86.4 G, OOM killer took the server.
//
// This suite encodes the fix contract:
//   1. Covered point-write shapes (single node pattern, no hops, indexed
//      string-equality WHERE, literal SET / REMOVE) are served ENGINE-DIRECT:
//      exact-index seek -> durable store property write. The engine-direct
//      counter moves; the legacy write-scan counter does NOT. O(ms) wall.
//      Durable across a clean reopen.
//   2. Uncovered write-carrying shapes keep the legacy path but abort with
//      error.WriteQueryBudgetExceeded once the executor's materialization
//      working set crosses GEODE_WRITE_EXECUTOR_BUDGET_MB — cleanly, with the
//      server healthy afterward and no partial writes for the not-yet-matched
//      candidates (budget is polled BETWEEN candidates, before each node's
//      mutation: per-node atomicity; no statement-level rollback exists on
//      the legacy autocommit path — pre-existing semantics, unchanged).
//   3. Routing table: covered vs uncovered shapes hit the intended executor
//      (counter evidence).
//
// RED (pre-implementation): the point-write counter never moves (fast path
// stub declines), the legacy counter moves for the covered shape, and the
// budget abort never fires.

const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const write_budget = geode.write_budget;
const Value = geode.value_types.Value;

var suite_mutex: std.Io.Mutex = .init;

// Zig 0.16 compat: build an absolute tmp path by joining cwd with the tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16: std.time.Timer removed; read the monotonic clock directly.
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Harness = struct {
    allocator: std.mem.Allocator,
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
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

fn resetPathCounters() void {
    execution.resetPointWriteFastPathTotal();
    execution.resetLegacyWriteScanTotal();
}

fn expectSingleStr(result: *const execution.ExecutionResult, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.rows[0].len);
    switch (result.rows[0][0]) {
        .Str => |s| try std.testing.expectEqualStrings(expected, s),
        else => return error.UnexpectedValueTag,
    }
}

fn seedTaxa(allocator: std.mem.Allocator, label: []const u8, n: usize, with_tmp_flag: bool) !void {
    const store = graph_store.getGlobalStore(allocator);
    var labels_buf = [_][]const u8{label};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const id = try store.createNode(labels_buf[0..]);
        var sb: [48]u8 = undefined;
        const sid = std.fmt.bufPrint(&sb, "pw-{d}", .{i}) catch unreachable;
        try store.setNodeProperty(id, "source_id", .{ .String = sid });
        try store.setNodeProperty(id, "seq", .{ .Int = @intCast(i) });
        if (with_tmp_flag) {
            try store.setNodeProperty(id, "tmp_flag", .{ .String = "on" });
        }
    }
}

// ---------------------------------------------------------------------------
// 1. Engine-direct point SET / REMOVE: fires, O(ms), durable across reopen.
// ---------------------------------------------------------------------------

test "point-write: covered SET/REMOVE served engine-direct (counters + wall time + durability)" {
    suite_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer suite_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const N: usize = 50_000;
    try seedTaxa(allocator, "PwTaxon", N, true);

    // --- covered SET with RETURN ---
    resetPathCounters();
    const t0 = monoNanos();
    var set_result = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-42' SET n.updated_by = 'fastpath' RETURN n.source_id",
    );
    const set_elapsed_ns = monoNanos() - t0;
    defer set_result.deinit(allocator);

    try expectSingleStr(&set_result, "pw-42");
    // Engine-direct fired; the legacy materializing write scan did NOT run.
    try std.testing.expectEqual(@as(u64, 1), execution.getPointWriteFastPathTotal());
    try std.testing.expectEqual(@as(u64, 0), execution.getLegacyWriteScanTotal());
    // O(ms): generous CI bound; actual value recorded for the report.
    std.debug.print("\n[point-write] covered SET wall: {d} us\n", .{set_elapsed_ns / 1000});
    try std.testing.expect(set_elapsed_ns < 2_000_000_000);

    // Write visible.
    var read_back = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-42' RETURN n.updated_by",
    );
    defer read_back.deinit(allocator);
    try expectSingleStr(&read_back, "fastpath");

    // --- covered REMOVE (no RETURN): legacy result shape is one row binding n ---
    resetPathCounters();
    var rm_result = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-43' REMOVE n.tmp_flag",
    );
    defer rm_result.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), execution.getPointWriteFastPathTotal());
    try std.testing.expectEqual(@as(u64, 0), execution.getLegacyWriteScanTotal());
    try std.testing.expectEqual(@as(usize, 1), rm_result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), rm_result.columns.len);
    try std.testing.expectEqualStrings("n", rm_result.columns[0]);

    // Removed property no longer visible.
    var rm_read = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-43' RETURN n.tmp_flag",
    );
    defer rm_read.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rm_read.rows.len);
    try std.testing.expect(rm_read.rows[0][0] == .Null);

    // --- authoritative empty: indexed key, no such value -> zero rows, served
    // engine-direct (index completeness makes the miss authoritative) ---
    resetPathCounters();
    var miss_result = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'no-such-node' SET n.updated_by = 'x' RETURN n.source_id",
    );
    defer miss_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), miss_result.rows.len);
    try std.testing.expectEqual(@as(u64, 1), execution.getPointWriteFastPathTotal());
    try std.testing.expectEqual(@as(u64, 0), execution.getLegacyWriteScanTotal());

    // --- durability: clean checkpoint + reopen -> writes persisted ---
    {
        const store = graph_store.getGlobalStore(allocator);
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        _ = graph_store.getGlobalStore(allocator); // reopen from the same data dir
    }
    var re_set = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-42' RETURN n.updated_by",
    );
    defer re_set.deinit(allocator);
    try expectSingleStr(&re_set, "fastpath");

    var re_rm = try h.exec(
        "MATCH (n:PwTaxon) WHERE n.source_id = 'pw-43' RETURN n.tmp_flag",
    );
    defer re_rm.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), re_rm.rows.len);
    try std.testing.expect(re_rm.rows[0][0] == .Null);
}

// ---------------------------------------------------------------------------
// 2. Budget: uncovered write-carrying shape aborts cleanly at a tiny budget.
// ---------------------------------------------------------------------------

test "budget: uncovered write shape aborts with WriteQueryBudgetExceeded, no partial writes, server healthy" {
    suite_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer suite_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const N: usize = 20_000;
    try seedTaxa(allocator, "PwBudget", N, false);

    // Tiny test budget (256 KiB): the uncovered legacy scan's per-candidate
    // materialization (env arrays + eval scratch through the metered executor
    // allocator) crosses it well before the 20k-candidate scan completes.
    write_budget.setBudgetBytesForTest(256 * 1024);
    defer write_budget.setBudgetBytesForTest(0);

    // Uncovered: ordering predicate (not an indexed-equality seek shape) that
    // matches NOTHING -> the abort must leave ZERO writes behind.
    const uncovered =
        "MATCH (n:PwBudget) WHERE n.source_id > 'zzzz' SET n.hit = '1'";
    const failed = h.exec(uncovered);
    try std.testing.expectError(error.WriteQueryBudgetExceeded, failed);

    // No partial writes visible (predicate matched nothing; abort happened
    // before any candidate mutation).
    write_budget.setBudgetBytesForTest(0); // lift budget for verification reads
    var verify = try h.exec(
        "MATCH (n:PwBudget) WHERE n.hit = '1' RETURN count(n)",
    );
    defer verify.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), verify.rows.len);
    switch (verify.rows[0][0]) {
        .Int => |c| try std.testing.expectEqual(@as(i64, 0), c),
        else => return error.UnexpectedValueTag,
    }

    // Server healthy after the abort: subsequent queries (read + covered
    // write) succeed.
    var healthy_read = try h.exec(
        "MATCH (n:PwBudget) WHERE n.source_id = 'pw-7' RETURN n.source_id",
    );
    defer healthy_read.deinit(allocator);
    try expectSingleStr(&healthy_read, "pw-7");

    var healthy_write = try h.exec(
        "MATCH (n:PwBudget) WHERE n.source_id = 'pw-7' SET n.ok = 'yes' RETURN n.ok",
    );
    defer healthy_write.deinit(allocator);
    try expectSingleStr(&healthy_write, "yes");

    // A budget-aborted query under the restored (default) budget now succeeds:
    // the same uncovered shape completes when the working set fits.
    var unbounded_ok = try h.exec(uncovered);
    defer unbounded_ok.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), unbounded_ok.rows.len);
}

// ---------------------------------------------------------------------------
// 3. Routing table: covered vs uncovered shapes.
// ---------------------------------------------------------------------------

const RoutingCase = struct {
    name: []const u8,
    query: []const u8,
    engine_direct: bool,
};

test "routing table: covered shapes engine-direct; uncovered shapes legacy" {
    suite_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer suite_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const N: usize = 2_000;
    try seedTaxa(allocator, "PwRoute", N, true);
    // A few edges so the hop-shape case has structure to walk.
    {
        const store = graph_store.getGlobalStore(allocator);
        const posting = store.getNodesByLabel("default", "PwRoute") orelse return error.NoLabelIndex;
        try std.testing.expect(posting.len >= 4);
        _ = try store.createEdge(posting[0], posting[1], "PWREL");
        _ = try store.createEdge(posting[2], posting[3], "PWREL");
    }

    const cases = [_]RoutingCase{
        // -------- covered --------
        .{ .name = "covered: indexed string eq + literal SET", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-5' SET n.a = '1'", .engine_direct = true },
        .{ .name = "covered: indexed string eq + REMOVE", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-5' REMOVE n.tmp_flag", .engine_direct = true },
        .{ .name = "covered: multi literal SET + RETURN", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-6' SET n.a = '1', n.b = '2' RETURN n.a, n.b", .engine_direct = true },
        // -------- uncovered: fall through to the legacy executor --------
        .{ .name = "uncovered: multi-node pattern", .query = "MATCH (a:PwRoute), (b:PwRoute) WHERE a.source_id = 'pw-1' SET a.m = '1'", .engine_direct = false },
        .{ .name = "uncovered: hop pattern", .query = "MATCH (a:PwRoute)-[r:PWREL]->(b:PwRoute) WHERE a.source_id = 'pw-0' SET a.m = '2'", .engine_direct = false },
        .{ .name = "uncovered: ordering predicate", .query = "MATCH (n:PwRoute) WHERE n.source_id > 'pw-y' SET n.m = '3'", .engine_direct = false },
        .{ .name = "uncovered: numeric-literal predicate", .query = "MATCH (n:PwRoute) WHERE n.seq = 5 SET n.m = '4'", .engine_direct = false },
        .{ .name = "uncovered: numeric-looking string literal", .query = "MATCH (n:PwRoute) WHERE n.source_id = '42' SET n.m = '5'", .engine_direct = false },
        .{ .name = "uncovered: non-literal SET value", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-2' SET n.m = n.source_id", .engine_direct = false },
        .{ .name = "uncovered: SET label", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-2' SET n:PwExtra", .engine_direct = false },
        .{ .name = "uncovered: SET all-properties", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-3' SET n = {m: '9'}", .engine_direct = false },
        .{ .name = "uncovered: REMOVE label", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-3' REMOVE n:PwRoute", .engine_direct = false },
        .{ .name = "uncovered: ORDER BY tail", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-4' SET n.m = '6' RETURN n.m ORDER BY n.m", .engine_direct = false },
        .{ .name = "uncovered: AND conjunction", .query = "MATCH (n:PwRoute) WHERE n.source_id = 'pw-4' AND n.seq = 4 SET n.m = '7'", .engine_direct = false },
        .{ .name = "uncovered: unlabeled pattern", .query = "MATCH (n) WHERE n.source_id = 'pw-8' SET n.m = '8'", .engine_direct = false },
    };

    for (cases) |case| {
        resetPathCounters();
        var result = h.exec(case.query) catch |err| {
            std.debug.print("routing case '{s}' unexpectedly errored: {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        defer result.deinit(allocator);
        const ed = execution.getPointWriteFastPathTotal();
        const legacy = execution.getLegacyWriteScanTotal();
        if (case.engine_direct) {
            std.testing.expectEqual(@as(u64, 1), ed) catch |err| {
                std.debug.print("routing case '{s}': expected engine-direct, got ed={d} legacy={d}\n", .{ case.name, ed, legacy });
                return err;
            };
            std.testing.expectEqual(@as(u64, 0), legacy) catch |err| {
                std.debug.print("routing case '{s}': legacy scan ran unexpectedly\n", .{case.name});
                return err;
            };
        } else {
            std.testing.expectEqual(@as(u64, 0), ed) catch |err| {
                std.debug.print("routing case '{s}': engine-direct fired on an uncovered shape\n", .{case.name});
                return err;
            };
            std.testing.expect(legacy >= 1) catch |err| {
                std.debug.print("routing case '{s}': legacy write-scan counter did not move (ed={d} legacy={d})\n", .{ case.name, ed, legacy });
                return err;
            };
        }
    }

    // Effect spot-checks: the covered writes really landed.
    var eff1 = try h.exec("MATCH (n:PwRoute) WHERE n.source_id = 'pw-5' RETURN n.a");
    defer eff1.deinit(allocator);
    try expectSingleStr(&eff1, "1");
    var eff2 = try h.exec("MATCH (n:PwRoute) WHERE n.source_id = 'pw-6' RETURN n.b");
    defer eff2.deinit(allocator);
    try expectSingleStr(&eff2, "2");
    var eff3 = try h.exec("MATCH (n:PwRoute) WHERE n.source_id = 'pw-5' RETURN n.tmp_flag");
    defer eff3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), eff3.rows.len);
    try std.testing.expect(eff3.rows[0][0] == .Null);
    // And an uncovered (legacy-served) write landed too — routing changes the
    // executor, never the effect. (pw-2's last m-write was the legacy-served
    // `SET n.m = n.source_id`; the later '42'-literal case matched nothing.)
    var eff4 = try h.exec("MATCH (n:PwRoute) WHERE n.source_id = 'pw-2' RETURN n.m");
    defer eff4.deinit(allocator);
    try expectSingleStr(&eff4, "pw-2");
}

// ---------------------------------------------------------------------------
// 4. write_budget module surface (public API).
// ---------------------------------------------------------------------------

test "write_budget: scope + metered allocator public API" {
    var s = write_budget.Scope{ .budget_bytes = 1024 };
    write_budget.beginScope(&s);
    defer write_budget.endScope(&s);

    var metered = write_budget.MeteredAllocator{ .inner = std.testing.allocator };
    const a = metered.allocator();

    const b1 = try a.alloc(u8, 512);
    try std.testing.expect(!write_budget.exceeded());
    a.free(b1);

    const b2 = try a.alloc(u8, 2048); // crosses the 1 KiB budget
    try std.testing.expect(write_budget.exceeded());
    try std.testing.expectError(error.WriteQueryBudgetExceeded, write_budget.check());
    // Hard backstop: further allocations refused while tripped.
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(b2);
    // Sticky trip: freeing does not un-exceed.
    try std.testing.expect(write_budget.exceeded());
}
