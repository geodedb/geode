const std = @import("std");
const graph_store = @import("geode").graph_store;

// CANARY: REQ=REQ-GQL-022; FEATURE="GraphStore Snapshot Load"; ASPECT=LoadCorrectnessAndVariance; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_022_GraphStoreLoadCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

const NODE_COUNT: usize = 4096;

fn buildSnapshot(allocator: std.mem.Allocator) !void {
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.reserve(NODE_COUNT, 0);
    var labels = [_][]const u8{"Redo"};
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        const node_id = try store.createNode(&labels);
        try store.setNodeProperty(node_id, "seq", .{ .Int = @intCast(i) });
    }
    try store.saveToFile();
}

test "TestCANARY_REQ_GQL_022_GraphStoreLoadCorrectness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    graph_store.setDataDirOverride(allocator, base);
    defer graph_store.setDataDirOverride(allocator, null);

    try buildSnapshot(allocator);

    var loaded = try graph_store.GraphStore.init(allocator);
    defer loaded.deinit();
    try loaded.loadFromFile();

    try std.testing.expectEqual(NODE_COUNT, loaded.getNodeCount());
}

test "BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    graph_store.setDataDirOverride(allocator, base);
    defer graph_store.setDataDirOverride(allocator, null);

    try buildSnapshot(allocator);

    const sample_n: usize = 48;
    var samples = try allocator.alloc(u64, sample_n);
    defer allocator.free(samples);

    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        var store = try graph_store.GraphStore.init(allocator);
        defer store.deinit();
        const t0 = std.time.nanoTimestamp();
        try store.loadFromFile();
        const t1 = std.time.nanoTimestamp();
        samples[i] = @intCast(t1 - t0);
    }

    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(sample_n));
    var acc: f128 = 0;
    for (samples) |s| {
        const d = @as(f128, @floatFromInt(s)) - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(sample_n));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;

    const tmp = try allocator.dupe(u64, samples);
    defer allocator.free(tmp);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;

    if (cv > 0.18 or p95_ratio > 2.3) {
        std.debug.print("VARIANCE_FAIL GraphStoreLoadVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
        return error.VarianceEnvelopeBreached;
    }
    std.debug.print("VARIANCE_OK GraphStoreLoadVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
}
