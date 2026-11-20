const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const execution = geode.execution;
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-QUALITY-401-002; FEATURE="MatchOpsBenchmarkCampaign"; ASPECT=RefactorBenchmark; STATUS=BENCHED; TEST=tests/benchmark_match_operations_campaign.zig; OWNER=execution; UPDATED=2026-02-16

const BenchmarkCase = struct {
    name: []const u8,
    query: []const u8,
};

const cases = [_]BenchmarkCase{
    .{ .name = "single_hop_match", .query = "MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b LIMIT 16" },
    .{ .name = "node_count_aggregation", .query = "MATCH (p:Person) RETURN count(*)" },
};

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

    pub fn exec(self: *Harness, query: []const u8) !void {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();

        var result = try execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
        defer result.deinit(self.allocator);
    }
};

fn seedBenchmarkGraph(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);
    const person_labels = @constCast(&[_][]const u8{"Person"});

    const node_ids = try allocator.alloc(u64, 4);
    defer allocator.free(node_ids);

    for (node_ids, 0..) |*id, i| {
        id.* = try store.createNode(person_labels);
        const age: i64 = 20 + @as(i64, @intCast(i));
        try store.setNodeProperty(id.*, "age", .{ .Int = age });
    }

    // Dense enough for meaningful traversal without making CI timing flaky.
    for (0..node_ids.len - 1) |i| {
        _ = try store.createEdge(node_ids[i], node_ids[i + 1], "KNOWS");
        if (i + 2 < node_ids.len) {
            _ = try store.createEdge(node_ids[i], node_ids[i + 2], "KNOWS");
        }
    }
}

test "match refactor benchmark campaign smoke" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const maybe_enabled = getEnvVarOwned(allocator, "GEODE_MATCH_BENCH_ENABLE") catch null;
    defer if (maybe_enabled) |v| allocator.free(v);
    if (maybe_enabled == null or !std.mem.eql(u8, maybe_enabled.?, "1")) return;

    const iterations: usize = 1;

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedBenchmarkGraph(allocator);

    var max_case_ns: u64 = 0;

    for (cases) |bench_case| {
        const case_start = nowNs();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try h.exec(bench_case.query);
        }

        const elapsed = nowNs() - case_start;
        if (elapsed > max_case_ns) max_case_ns = elapsed;

        const avg_ns = elapsed / iterations;
        std.debug.print(
            "MATCH_BENCH case={s} total_ns={d} avg_ns={d} iterations={d}\n",
            .{ bench_case.name, elapsed, avg_ns, iterations },
        );
    }

    // Guard against pathological regressions (seconds per tiny campaign) while
    // allowing broad runner variance.
    try std.testing.expect(max_case_ns < 10 * std.time.ns_per_s);
}
