const std = @import("std");
const graph_store = @import("geode").graph_store;
const pipeline_mod = @import("storage/snapshot_pipeline.zig");

// CANARY: REQ=REQ-GQL-083; FEATURE="SnapshotCompaction"; ASPECT=CompactionVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_083_SnapshotCompactionVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

test "BenchmarkCANARY_REQ_GQL_083_CompactionVarianceEnvelope" {
    const Runs = 28; // >=24 for stable p95
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    const allocator = std.testing.allocator;
    while (r < Runs) : (r += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        graph_store.setDataDirOverride(allocator, tmp.dir_path);
        defer graph_store.setDataDirOverride(allocator, null);

        var store = graph_store.GraphStore.init(allocator);
        defer store.deinit();
        var pipe = pipeline_mod.Pipeline.init(allocator, &store, .{
            .checkpoint_interval_override = 2,
            .compaction_interval = 2,
            .archival_window = 50,
        });
        // Populate store with some nodes and commit cycles.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            _ = try store.createNode(&.{ "bench" });
            pipe.recordCommit(1);
        }
        const start = std.time.nanoTimestamp();
        _ = try pipe.tick(); // may checkpoint/compact
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |v| {
        const dv = @as(f128, @floatFromInt(v)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;
    var sorted: [Runs]u64 = undefined;
    @memcpy(&sorted, &samples);
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];
    // Snapshot envelope: keep variance reasonable on local disk.
    try std.testing.expect(cv <= 0.50);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 3.00);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"snapshot_compaction_pipeline_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
