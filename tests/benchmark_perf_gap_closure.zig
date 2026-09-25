const std = @import("std");
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const execution = geode.execution;
const graph_store = geode.graph_store;

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// CANARY: REQ=REQ-PERF-GAP-0525; FEATURE="PerfGapBenchmarks"; ASPECT=MicroBenchmarks; STATUS=BENCHED; BENCH=tests/benchmark_perf_gap_closure.zig; OWNER=engine; UPDATED=2026-04-10
//
// Targeted micro-benchmarks for the performance gaps closed in the 2026-04-09
// perf review audit (GAP-0519 through GAP-0525). Gate behind env var to avoid
// CI flakiness from wall-clock measurements.

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

fn isEnabled(allocator: std.mem.Allocator) bool {
    _ = allocator;
    // Zig 0.16 compat: std.process.getEnvVarOwned removed; use std.c.getenv (no allocation).
    const ptr = std.c.getenv("GEODE_PERF_GAP_BENCH_ENABLE") orelse return false;
    const v = std.mem.span(ptr);
    return std.mem.eql(u8, v, "1");
}

// --- GAP-0519: Multi-label posting-list intersection benchmark ---

test "GAP-0519 bench: multi-label intersection on 1K node graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (!isEnabled(allocator)) return;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // Create 1000 nodes with 4 labels each
    for (0..1000) |_| {
        var labels = [_][]const u8{ "Person", "Employee", "Active", "Verified" };
        _ = try store.createNodeWithGraph(&labels, "default");
    }
    // Create 200 nodes with only 2 of the 4 labels (should not match 4-label intersection)
    for (0..200) |_| {
        var labels = [_][]const u8{ "Person", "Employee" };
        _ = try store.createNodeWithGraph(&labels, "default");
    }

    const timer_start_ns = nowNs();

    const iterations: usize = 100;
    for (0..iterations) |_| {
        const labels = [_][]const u8{ "Person", "Employee", "Active", "Verified" };
        var result = try store.getNodesByLabels(allocator, "default", &labels, null);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1000), result.items.len);
    }

    const elapsed_ns = nowNs() - timer_start_ns;
    const avg_us = elapsed_ns / iterations / 1000;
    std.debug.print("\n[GAP-0519] 4-label intersection on 1200-node graph: {d}us avg ({d} iterations)\n", .{ avg_us, iterations });
}

// --- GAP-0520: PathIterator streaming benchmark ---

test "GAP-0520 bench: PathIterator streaming with LIMIT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (!isEnabled(allocator)) return;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // Create a chain graph: n0 -> n1 -> n2 -> ... -> n99
    var node_ids: [100]u64 = undefined;
    for (&node_ids) |*id| {
        var labels = [_][]const u8{"Node"};
        id.* = try store.createNodeWithGraph(&labels, "default");
    }
    for (0..99) |i| {
        _ = try store.createEdge(node_ids[i], node_ids[i + 1], "NEXT");
    }

    const timer_start_ns = nowNs();

    const iterations: usize = 50;
    for (0..iterations) |_| {
        var iter = try execution.PathIterator.init(allocator, store, node_ids[0], 1, 10, "NEXT", 'r', .acyclic, null);
        defer iter.deinit();

        var path_count: usize = 0;
        while (try iter.next()) |raw_path| {
            var path = raw_path;
            defer path.deinit(allocator);
            path_count += 1;
            if (path_count >= 5) break; // LIMIT 5 early termination
        }
        try std.testing.expect(path_count == 5);
    }

    const elapsed_ns = nowNs() - timer_start_ns;
    const avg_us = elapsed_ns / iterations / 1000;
    std.debug.print("\n[GAP-0520] PathIterator LIMIT 5 on 100-node chain: {d}us avg ({d} iterations)\n", .{ avg_us, iterations });
}

// --- GAP-0523: ReadView snapshot benchmark ---

test "GAP-0523 bench: ReadView epoch-check fast path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (!isEnabled(allocator)) return;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getWritableGlobalStore(allocator);

    // Seed some data
    for (0..100) |_| {
        var labels = [_][]const u8{"Person"};
        _ = try store.createNodeWithGraph(&labels, "default");
    }

    // Benchmark: ReadView creation + getReadStore (no-mutation fast path)
    const timer_start_ns = nowNs();

    const iterations: usize = 10000;
    for (0..iterations) |_| {
        var view = graph_store.ReadView.init(allocator, store);
        defer view.deinit();
        const read_store = view.getReadStore();
        try std.testing.expect(read_store == store); // Same epoch, should return base
    }

    const elapsed_ns = nowNs() - timer_start_ns;
    const avg_ns = elapsed_ns / iterations;
    std.debug.print("\n[GAP-0523] ReadView fast path (no mutation): {d}ns avg ({d} iterations)\n", .{ avg_ns, iterations });

    // Benchmark: ReadView with epoch change (snapshot creation)
    graph_store.incrementMutationEpoch();

    const timer2_start_ns = nowNs();

    const snapshot_iterations: usize = 10;
    for (0..snapshot_iterations) |_| {
        var view = graph_store.ReadView.init(allocator, store);
        defer view.deinit();
        const read_store = view.getReadStore();
        try std.testing.expect(read_store != store); // Epoch changed, should create snapshot
    }

    const elapsed_ns2 = nowNs() - timer2_start_ns;
    const avg_us2 = elapsed_ns2 / snapshot_iterations / 1000;
    std.debug.print("[GAP-0523] ReadView snapshot creation (100 nodes): {d}us avg ({d} iterations)\n", .{ avg_us2, snapshot_iterations });
}

// --- GAP-0522: Full-scan with LIMIT pushdown ---

test "GAP-0522 bench: MATCH with LIMIT pushdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    if (!isEnabled(allocator)) return;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // Create 10K nodes to make scan expensive without LIMIT
    for (0..10000) |_| {
        var labels = [_][]const u8{"Widget"};
        _ = try store.createNodeWithGraph(&labels, "default");
    }

    const timer_start_ns = nowNs();

    const iterations: usize = 20;
    for (0..iterations) |_| {
        // LIMIT 10 should terminate early via scan_cap
        var result = try h.exec("MATCH (n:Widget) RETURN n LIMIT 10");
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 10), result.rows.len);
    }

    const elapsed_ns = nowNs() - timer_start_ns;
    const avg_us = elapsed_ns / iterations / 1000;
    std.debug.print("\n[GAP-0522] MATCH (n:Widget) LIMIT 10 on 10K nodes: {d}us avg ({d} iterations)\n", .{ avg_us, iterations });
}
