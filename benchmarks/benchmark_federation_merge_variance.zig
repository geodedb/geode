const std = @import("std");
const federation = @import("../src/distributed/federation.zig");
const protocol = @import("../src/protocol.zig");

// Federation ordered multi-key merge variance envelope benchmark.
// Measures stability of heap-based k-way merge across multiple contributors.
// Thresholds: CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMultiKeyDirMerge"; ASPECT=FederationMergeVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_052_FederationOrderedMultiKeyDirMergeVarianceEnvelope; OWNER=federation; UPDATED=2025-09-23

fn makeRow(values: []const protocol.BindingValue, allocator: std.mem.Allocator) protocol.BindingRow {
    _ = allocator; // values slice assumed static for bench lifetime
    return .{ .cols = values };
}

fn fabricateResults(k1: []const i64, k2: []const i64, allocator: std.mem.Allocator, order_keys: []const []const u8, order_dirs: []const bool) federation.QueryResults {
    var rows_buf = allocator.alloc(protocol.BindingRow, k1.len) catch unreachable;
    var i: usize = 0;
    while (i < k1.len) : (i += 1) {
        var vals = allocator.alloc(protocol.BindingValue, 2) catch unreachable;
        vals[0] = .{ .Int = k1[i] };
        vals[1] = .{ .Int = k2[i] };
        rows_buf[i] = .{ .cols = vals };
    }
    return federation.QueryResults{
        .rows = rows_buf,
        .schema = &.{},
        .execution_time_ms = 0,
        .ordered = true,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
    };
}

pub fn benchmarkFederationOrderedMultiKeyDirMergeVarianceEnvelope() !void {
    const iterations = 64;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);
    const order_keys = &[_][]const u8{ "k1", "k2" };
    const order_dirs = &[_]bool{ true, false };
    var fm: federation.FederationManager = undefined;

    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        // Fabricate three contributors with slight permutation each iteration
        const base: i64 = @intCast(it % 4);
        const local = fabricateResults(&[_]i64{ 1, 2, 3 }, &[_]i64{ 5 + base, 4 + base, 3 + base }, allocator, order_keys, order_dirs);
        const r1 = fabricateResults(&[_]i64{ 1, 2 }, &[_]i64{ 7 + base, 2 + base }, allocator, order_keys, order_dirs);
        const r2 = fabricateResults(&[_]i64{ 2, 3 }, &[_]i64{ 9 + base, 1 + base }, allocator, order_keys, order_dirs);
        var rem = [_]federation.QueryResults{ r1, r2 };
        const start = std.time.nanoTimestamp();
        const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, allocator);
        const end = std.time.nanoTimestamp();
        samples[it] = @intCast(end - start);
        // Free row buffers (values freed by allocator arena teardown at end)
        allocator.free(merged.rows);
        allocator.free(local.rows);
        allocator.free(r1.rows);
        allocator.free(r2.rows);
    }
    // compute stats
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff_sum: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff_sum += d * d;
    }
    const variance = diff_sum / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean_f;
    std.sort.sort(u64, samples, {}, comptime struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);
    const p95_index = (samples.len * 95) / 100;
    const p95 = samples[p95_index];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    if (cv > 0.22 or p95_mean_ratio > 2.55) {
        std.debug.print("Federation merge variance envelope breached: cv={d:.4} p95/mean={d:.4}\n", .{ cv, p95_mean_ratio });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_052_FederationOrderedMultiKeyDirMergeVarianceEnvelope" {
    try benchmarkFederationOrderedMultiKeyDirMergeVarianceEnvelope();
}
