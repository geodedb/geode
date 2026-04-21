// tests/test_gap0810_reproduce_regression.zig — GAP-0810 regression test
//
// CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="ParseCacheBenchAllocator"; ASPECT=RegressionTest; STATUS=TESTED; TEST=tests/test_gap0810_reproduce_regression.zig; OWNER=performance; UPDATED=2026-04-20
//
// ## What this pins
//
// The Phase-1 A/B gate for GAP-0810 (wiring `parseGqlCached` into the
// executor-match bench) surfaced a +37-117% execute-latency regression on
// medium / large datasets. Original hypothesis (plan
// `docs/superpowers/plans/2026-04-20-ingest-query-perf-closure.md` Phase 1)
// was that the SharedAstCache retained stale plan/compiled state across a
// `deinitGlobalStore` → `initGlobalStore` cycle.
//
// Investigation (GAP-0810-INVESTIGATE, 2026-04-20) showed the regression
// is NOT a correctness issue with the cache — it is a measurement
// artifact of the bench using `std.heap.DebugAllocator` while the cache
// retains live allocations across iterations. DebugAllocator's
// per-allocation bookkeeping + mutex has O(live_allocations) cost, so the
// extra live allocations held by the cache (heap ParseResult + arena +
// query_text_copy) slow every subsequent allocation/free inside
// `executeProgramWithContext`.
//
// Running the same workload with `std.heap.smp_allocator` (the
// production allocator — see `graph_store.global_allocator`,
// GAP-0754) eliminates the regression and surfaces the expected parse-
// cache win on the executor path.
//
// This test pins the correct shape: under `smp_allocator`, cached-reuse
// is at most a few % slower than fresh-parse execute (typically faster
// because the AST arena is hot in cache).

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn seedPersons(allocator: std.mem.Allocator, count: usize) !void {
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Person"};
    var name_buf: [64]u8 = undefined;
    for (0..count) |i| {
        const node_id = try store.createNodeWithGraph(labels, "default");
        try store.setNodeProperty(node_id, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "LT_Person_{d}", .{i});
        try store.setNodeProperty(node_id, "name", .{ .String = name });
        try store.setNodeProperty(node_id, "age", .{ .Int = 20 + @as(i64, @intCast(i % 50)) });
    }
}

fn medianU64(samples: []const u64, scratch: []u64) u64 {
    @memcpy(scratch, samples);
    std.mem.sort(u64, scratch, {}, std.sort.asc(u64));
    return scratch[scratch.len / 2];
}

test "GAP-0810: cached parse reuse across store reset does not regress execute" {
    // Use the production allocator — DebugAllocator's bookkeeping would
    // manufacture a regression that does not exist in the server path
    // (see test docblock).
    const allocator = std.heap.smp_allocator;

    var tmp_buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "/tmp/gap0810-repro-{d}", .{pid});
    const fs_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};

    _ = try graph_store.initGlobalStore(allocator, tmp_path);
    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();
    defer graph_store.deinitGlobalStore();

    try seedPersons(allocator, 500);

    var ast_cache = geode.SharedAstCache.init(allocator, 16);
    defer ast_cache.deinit();

    const query = "MATCH (p:LT_Person {lt_id: 42}) RETURN p.name, p.age";
    const ctx = geode.execution.ExecutionContext{ .catalog = catalog };

    const iterations: usize = 20;
    const warmup: usize = 3;

    const scratch = try allocator.alloc(u64, iterations);
    defer allocator.free(scratch);

    // Phase A: warm cache on small store (populates the SharedAstCache).
    for (0..warmup) |_| {
        const outcome = try geode.parseGqlCached(&ast_cache, query, .{});
        var h = switch (outcome) {
            .Ok => |handle| handle,
            .Err => return error.ParseFailed,
        };
        defer h.release();
        var r = try geode.execution.executeProgramWithContext(allocator, &h.parse_result.program, ctx);
        r.deinit(allocator);
    }

    // Reset store to medium size.
    graph_store.deinitGlobalStore();
    std.Io.Dir.cwd().deleteTree(fs_io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_io, tmp_path);
    _ = try graph_store.initGlobalStore(allocator, tmp_path);
    try seedPersons(allocator, 2000);

    // Phase B: reuse the cached ast.Program from Phase A.
    for (0..warmup) |_| {
        const outcome = try geode.parseGqlCached(&ast_cache, query, .{});
        var h = switch (outcome) {
            .Ok => |handle| handle,
            .Err => return error.ParseFailed,
        };
        defer h.release();
        var r = try geode.execution.executeProgramWithContext(allocator, &h.parse_result.program, ctx);
        r.deinit(allocator);
    }
    const b_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(b_samples);
    for (0..iterations) |i| {
        const outcome = try geode.parseGqlCached(&ast_cache, query, .{});
        var h = switch (outcome) {
            .Ok => |handle| handle,
            .Err => return error.ParseFailed,
        };
        defer h.release();
        const t0 = nowNs();
        var r = try geode.execution.executeProgramWithContext(allocator, &h.parse_result.program, ctx);
        const t1 = nowNs();
        b_samples[i] = t1 - t0;
        r.deinit(allocator);
    }
    const b_median = medianU64(b_samples, scratch);

    // Phase C: control — fresh parse every iter, same store as Phase B.
    for (0..warmup) |_| {
        var pr = try geode.parse(allocator, query, .{});
        defer pr.deinit();
        var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
        r.deinit(allocator);
    }
    const c_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(c_samples);
    for (0..iterations) |i| {
        var pr = try geode.parse(allocator, query, .{});
        defer pr.deinit();
        const t0 = nowNs();
        var r = try geode.execution.executeProgramWithContext(allocator, &pr.program, ctx);
        const t1 = nowNs();
        c_samples[i] = t1 - t0;
        r.deinit(allocator);
    }
    const c_median = medianU64(c_samples, scratch);

    std.debug.print(
        "\nGAP-0810 regression check: cached(B)={d} ns, fresh(C)={d} ns, B/C={d:.3}x\n",
        .{ b_median, c_median, @as(f64, @floatFromInt(b_median)) / @as(f64, @floatFromInt(c_median)) },
    );

    // Regression gate: cached reuse must not exceed fresh parse by more
    // than 25% (generous envelope for CI noise). The original +85% /
    // +117% spikes were exclusively a DebugAllocator bookkeeping
    // artifact.  Under smp_allocator, cached execute is typically at or
    // below fresh-parse execute because the cached arena is hot in the
    // CPU cache across iterations.
    const ratio_x1000 = (b_median * 1000) / c_median;
    try std.testing.expect(ratio_x1000 <= 1250);
}
