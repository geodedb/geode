const std = @import("std");
const wal_mod = @import("wal");
const pipeline_mod = @import("storage/wal_compaction_pipeline.zig");

// CANARY: REQ=REQ-GQL-083; FEATURE="WalCompaction"; ASPECT=CompactionVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_083_CompactionVarianceEnvelope; OWNER=storage; UPDATED=2025-09-23

fn tempBase(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}/tmp_wal_var_{s}_{d}", .{ base, tag, std.time.nanoTimestamp() });
}

test "BenchmarkCANARY_REQ_GQL_083_CompactionVarianceEnvelope" {
    const Runs = 28; // >=24 for stable p95
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    const allocator = std.testing.allocator;
    while (r < Runs) : (r += 1) {
        var w = wal_mod.Wal.init(allocator);
        defer w.deinit();
        const base = try tempBase(allocator, "run");
        defer allocator.free(base);
        try w.openFile(base);
        // Configure small segment and aggressive cadence so each run performs some work.
        w.segment_limit = 1024; // 1KB
        w.setCompactionCadence(2, 2);
        var pipe = pipeline_mod.Pipeline.init(allocator, &w, .{ .checkpoint_interval_override = 2, .archival_window = 50 });
        // Populate WAL with several commit cycles.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            _ = try w.append(1, .Commit, &.{}, 0);
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
    // Storage/WAL envelope: CV<=0.21, p95 < 2.50 * mean
    try std.testing.expect(cv <= 0.21);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.50);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"wal_compaction_pipeline_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
