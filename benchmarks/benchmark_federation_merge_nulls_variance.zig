const std = @import("std");
const federation = @import("../src/distributed/federation.zig");
const protocol = @import("../src/protocol.zig");

// Variance envelope benchmark: federation sorted merge with high NULL density.
// Ensures null ordering comparator path does not introduce unstable variance.
// Thresholds: CV <= 0.22, p95/mean <= 2.55
// CANARY: REQ=REQ-GQL-052; FEATURE="FederationNullsOrdering"; ASPECT=FederationNullMergeVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_052_FederationNullMergeVarianceEnvelope; OWNER=federation; UPDATED=2025-09-23

fn fabricate(allocator: std.mem.Allocator, count: usize, null_ratio_num: usize, null_ratio_den: usize, order_keys: []const []const u8) federation.QueryResults {
    var rows = allocator.alloc(protocol.BindingRow, count) catch unreachable;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var vals = allocator.alloc(protocol.BindingValue, order_keys.len) catch unreachable;
        const is_null = (@mod(i, null_ratio_den) < null_ratio_num);
        if (is_null) {
            vals[0] = .{ .Null = {} };
        } else {
            vals[0] = .{ .Int = @intCast(i) };
        }
        rows[i] = .{ .cols = vals };
    }
    return .{ .rows = rows, .schema = &.{}, .execution_time_ms = 0, .ordered = true, .order_keys = order_keys, .nulls_first = true };
}

pub fn benchmarkFederationNullMergeVarianceEnvelope() !void {
    const iterations = 48;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var samples = try ally.alloc(u64, iterations);
    defer ally.free(samples);
    const order_keys = &[_][]const u8{"k"};
    var fm: federation.FederationManager = undefined;
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        const local = fabricate(ally, 500 + (it % 7), 3, 4, order_keys); // 75% nulls
        const r1 = fabricate(ally, 400 + (it % 5), 2, 3, order_keys); // ~66% nulls
        var rem = [_]federation.QueryResults{r1};
        const start = std.time.nanoTimestamp();
        const merged = try fm.mergeResults(local, rem[0..], .merge_sorted, ally);
        const end = std.time.nanoTimestamp();
        samples[it] = @intCast(end - start);
        ally.free(merged.rows);
        ally.free(local.rows);
        ally.free(r1.rows);
    }
    // stats
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff += d * d;
    }
    const stddev = std.math.sqrt(diff / @as(f128, @floatFromInt(samples.len)));
    const cv = stddev / mean_f;
    std.sort.sort(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const p95 = samples[(samples.len * 95) / 100];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    if (cv > 0.22 or p95_ratio > 2.55) {
        std.debug.print("Federation NULL merge variance envelope breached: cv={d:.4} p95/mean={d:.4}\n", .{ cv, p95_ratio });
        return error.VarianceEnvelopeBreached;
    }
}

test "BenchmarkCANARY_REQ_GQL_052_FederationNullMergeVarianceEnvelope" {
    try benchmarkFederationNullMergeVarianceEnvelope();
}
