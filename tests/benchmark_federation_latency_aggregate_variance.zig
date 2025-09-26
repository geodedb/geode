const std = @import("std");
const agg = @import("distributed/federation_latency_aggregate.zig");

// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope; OWNER=federation; UPDATED=2025-09-26

// BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope
// Measures cycle finalize latency variance across repeated synthetic cycles.
// Acceptance thresholds (empirical, aligned with other variance envelopes):
//   CV <= 0.30, p95/mean <= 2.6
// These bounds ensure stable aggregate maintenance cost under jitter.
test "BenchmarkCANARY_REQ_GQL_024_FederationLatencyAggregateVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator(); // presently unused (no allocations expected beyond std)
    _ = alloc; // silence unused warning if Zig version complains

    const cycles: usize = 48;
    var samples = try std.heap.page_allocator.alloc(u64, cycles);
    defer std.heap.page_allocator.free(samples);

    var c: usize = 0;
    while (c < cycles) : (c += 1) {
        agg.resetAll();
        // Simulate a cycle with mixed mismatch / normal events
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const mismatch = (i % 7 == 0);
            // Latency ranges in two bands to exercise p95 logic
            const base: u64 = if ((i & 1) == 0) 120 else 850;
            agg.recordLatency(base + @as(u64, @intCast(i)), mismatch);
        }
        const start = std.time.nanoTimestamp();
        _ = agg.finalizeCycle();
        const end = std.time.nanoTimestamp();
        samples[c] = @as(u64, @intCast(end - start));
    }

    // Compute mean
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(cycles));
    // Variance (population)
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(cycles));
    const cv = std.math.sqrt(variance) / mean;

    // p95 selection (naive partial selection)
    var scratch = try std.heap.page_allocator.dupe(u64, samples);
    defer std.heap.page_allocator.free(scratch);
    const rank = (cycles * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < cycles) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;

    try std.testing.expect(cv <= 0.30);
    try std.testing.expect(p95_mean <= 2.6);
}
