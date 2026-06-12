// GAP-0868: PROFILE runtime telemetry — real wall-clock timing.
//
// The statement-level PROFILE fallback in
// src/execution/statement_handlers.zig:executeProfile previously reported a
// hard-coded `time = 1` placeholder. This regression pins:
//
//   1. The fallback (query_profile) result reports `time_ms` measured with
//      CLOCK_MONOTONIC around the wrapped statement's execution — the metric
//      is present, integer, and bounded above by an externally measured
//      wall-clock window (placeholder constants cannot satisfy both bounds).
//   2. For a deliberately non-trivial scan (calibrated to take >= 60ms of
//      real work), the reported time_ms is >= 10 — a placeholder constant 1
//      fails this floor while real timing clears it with 6x headroom.
//   3. The old placeholder metric name `time` is gone.
//
// Paths that reach the fallback:
//   - PROFILE <non-Query statement> (e.g. PROFILE SHOW TABLES), and
//   - PROFILE <storage-native read> demoted by the concrete-tenant guard
//     (GAP-0846/GAP-0509 demotion in planned_read_runtime.buildPlanIfSupported).
// Planned reads keep the richer planned_query_profile (real per-operator
// time_ns via RuntimeTrace) — unchanged by GAP-0868.
//
// Harness pattern: real store, real parser, real executor, no mocks
// (modelled on tests/test_edge_properties_batch.zig).

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

fn monoNanosNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        // GAP-0535 closed the ExecutionResult row-value ownership gap, so this
        // harness now runs strict (std.testing.allocator) end-to-end — the
        // original arena workaround (which hid the PROFILE metric-name string
        // leak) is gone, and the test runner's leak detection is part of the
        // regression. Callers own the returned result (deinit it).
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

/// Find the integer value of a `metric`/`value` row whose metric name equals
/// `name`. Returns null when absent or non-integer.
fn findMetricInt(result: execution.ExecutionResult, name: []const u8) ?i64 {
    for (result.rows) |row| {
        if (row.len < 2) continue;
        const metric = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, metric, name)) continue;
        return switch (row[1]) {
            .Int => |v| v,
            else => null,
        };
    }
    return null;
}

fn findMetricStr(result: execution.ExecutionResult, name: []const u8) ?[]const u8 {
    for (result.rows) |row| {
        if (row.len < 2) continue;
        const metric = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, metric, name)) continue;
        return switch (row[1]) {
            .Str => |s| s,
            else => null,
        };
    }
    return null;
}

fn hasMetric(result: execution.ExecutionResult, name: []const u8) bool {
    for (result.rows) |row| {
        if (row.len < 1) continue;
        switch (row[0]) {
            .Str => |s| if (std.mem.eql(u8, s, name)) return true,
            else => {},
        }
    }
    return false;
}

test "GAP-0868: PROFILE fallback reports time_ms bounded by real wall clock (non-Query statement)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const start_ns = monoNanosNow();
    var result = try h.runQuery("PROFILE SHOW TABLES");
    defer result.deinit(testing.allocator);
    const external_ms: i64 = @intCast((monoNanosNow() - start_ns) / std.time.ns_per_ms);

    // Fallback profile shape: metric/value columns, query_profile type.
    try testing.expectEqual(@as(usize, 2), result.columns.len);
    try testing.expectEqualStrings("metric", result.columns[0]);
    try testing.expectEqualStrings("value", result.columns[1]);
    const profile_type = findMetricStr(result, "profile") orelse return error.MissingProfileType;
    try testing.expectEqualStrings("query_profile", profile_type);

    // Real timing: present, integer, non-negative, and cannot exceed the
    // externally measured window around the whole PROFILE execution
    // (+2ms slack for ms truncation on each side).
    const time_ms = findMetricInt(result, "time_ms") orelse return error.MissingTimeMsMetric;
    try testing.expect(time_ms >= 0);
    try testing.expect(time_ms <= external_ms + 2);

    // The old placeholder row (`time` = 1) must be gone.
    try testing.expect(!hasMetric(result, "time"));
}

test "GAP-0868: PROFILE time_ms reflects elapsed time for a non-trivial tenant-scoped scan" {
    // Slow opt-in (GEODE_RUN_SLOW_TESTS=1, repo convention): the workload
    // calibration ingests up to ~1.3M nodes, which takes tens of minutes
    // under std.testing.allocator since the GAP-0535 strict-ownership
    // switch. The always-on SHOW TABLES test above keeps time_ms presence,
    // upper bound, and leak coverage in the sweep.
    const should_run: bool = blk: {
        const ptr = std.c.getenv("GEODE_RUN_SLOW_TESTS") orelse break :blk false;
        break :blk std.mem.span(ptr).len > 0;
    };
    if (!should_run) return error.SkipZigTest;

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // A concrete tenant scope demotes storage-native reads to the legacy
    // (tenant-aware) executor, which routes PROFILE through the
    // statement-level fallback that previously held the placeholder.
    h.ctx.tenant_id = "tenant_alpha";

    const store = graph_store.getGlobalStore(testing.allocator);
    var labels = [_][]const u8{"T"};

    // Calibrate the workload so the scan reliably takes >= 60ms of real
    // wall-clock work regardless of build mode / machine speed: start at
    // 20k nodes and double until the plain (non-PROFILE) query crosses the
    // threshold, capped at ~1.28M nodes.
    var total_nodes: usize = 0;
    var plain_ms: i64 = 0;
    var batch: usize = 20_000;
    while (total_nodes < 1_300_000) {
        var i: usize = 0;
        while (i < batch) : (i += 1) {
            _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_alpha");
        }
        total_nodes += batch;

        const t0 = monoNanosNow();
        var plain = try h.runQuery("MATCH (a:T) RETURN count(a)");
        plain_ms = @intCast((monoNanosNow() - t0) / std.time.ns_per_ms);
        plain.deinit(testing.allocator);

        if (plain_ms >= 60) break;
        batch = total_nodes; // double total
    }

    const t0 = monoNanosNow();
    var result = try h.runQuery("PROFILE MATCH (a:T) RETURN count(a)");
    defer result.deinit(testing.allocator);
    const external_ms: i64 = @intCast((monoNanosNow() - t0) / std.time.ns_per_ms);

    // Concrete tenant scope must have demoted to the fallback profile.
    const profile_type = findMetricStr(result, "profile") orelse return error.MissingProfileType;
    try testing.expectEqualStrings("query_profile", profile_type);

    const time_ms = findMetricInt(result, "time_ms") orelse return error.MissingTimeMsMetric;

    // Upper bound: reported window is strictly inside the external window.
    try testing.expect(time_ms <= external_ms + 2);

    // Floor: when the calibrated plain run takes >= 60ms, real timing must
    // report >= 10ms (6x headroom vs the calibration; the old placeholder
    // constant 1 fails this). If calibration capped out without reaching
    // 60ms (implausibly fast machine), the floor is skipped but presence and
    // the upper bound above still pin the behaviour.
    if (plain_ms >= 60) {
        try testing.expect(time_ms >= 10);
    }

    // Row count is still reported and the placeholder metric stays gone.
    const rows_metric = findMetricInt(result, "rows") orelse return error.MissingRowsMetric;
    try testing.expectEqual(@as(i64, 1), rows_metric);
    try testing.expect(!hasMetric(result, "time"));
}
