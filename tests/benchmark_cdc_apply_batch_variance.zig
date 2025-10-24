const std = @import("std");
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC"; ASPECT=CDCApplyBatchLatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_ApplyBatchLatencyVarianceEnvelope; OWNER=streaming; UPDATED=2025-09-21

// Measures stability of apply-batch latency under mixed record sizes.

fn simulateApply(engine: anytype, batch: usize) void {
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        if (@hasDecl(@TypeOf(engine), "notePendingEvent")) engine.notePendingEvent() catch {};
    }
    if (@hasDecl(@TypeOf(engine), "flushBatch")) {
        engine.flushBatch() catch {};
    } else if (@hasDecl(@TypeOf(engine), "tick")) {
        engine.tick() catch {};
    }
}

test "BenchmarkCANARY_REQ_GQL_042_CDC_ApplyBatchLatencyVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var engine = try cdc.CdcEngine.init(allocator, .{ .adaptive_backpressure = true, .pending_backpressure_watermark = 12_000 });
    defer engine.deinit();

    const Runs = 34;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const batch = if (r % 4 == 0) 15_000 else 4_000; // periodic burst
        const start = std.time.nanoTimestamp();
        simulateApply(engine, batch);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;

    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, i| sorted[i] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Thresholds: CDC apply can be bursty; allow CV < 0.22, p95 < 2.6x mean
    try std.testing.expect(cv < 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.6);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"cdc_apply_batch_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
