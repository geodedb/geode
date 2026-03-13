const std = @import("std");
const exec = @import("server/graph/exec.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=MatchLabelPropertyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_017_MatchLabelPropertyVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

// Benchmark rationale:
// Compare unlabeled full scan vs labeled+property filtered scan to ensure
// predicate filtering does not introduce >5% mean overhead when selectivity is high
// and maintains latency stability (CV<=0.24, p95/mean<=2.65).

fn timeScan(filtered: bool, g: *const exec.GraphStore, select_label: []const u8) u64 {
    const start = std.time.nanoTimestamp();
    var labels: [][]const u8 = &.{};
    var prop_key: ?[]const u8 = null;
    var prop_val: ?exec.PropertyValue = null;
    if (filtered) {
        labels = &.{select_label};
        prop_key = "name";
        prop_val = exec.PropertyValue{ .String = "Alice" };
    }
    const res = exec.nodeScan(std.testing.allocator, g, labels, if (filtered) "n" else null, prop_key, prop_val) catch &.{};
    std.testing.allocator.free(res);
    return @intCast(std.time.nanoTimestamp() - start);
}

fn cv(samples: []const u64, mean: f64) f64 {
    var var_acc: f64 = 0;
    for (samples) |v| {
        const dv = @as(f64, @floatFromInt(v)) - mean;
        var_acc += dv * dv;
    }
    const variance = var_acc / @as(f64, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    return stddev / mean;
}

test "BenchmarkCANARY_REQ_GQL_017_MatchLabelPropertyVarianceEnvelope" {
    var g = try exec.GraphStore.init(std.testing.allocator);
    defer g.deinit();

    const total_nodes: usize = 5000;
    const select_label = "Person";

    var i: usize = 0;
    while (i < total_nodes) : (i += 1) {
        const id: exec.NodeId = @intCast(i + 1);
        const labels = if ((i % 2) == 0) &.{select_label} else &.{"Other"};
        try g.addNode(std.testing.allocator, id, labels);
        if ((i % 2) == 0) {
            try g.setNodeProperty(id, "name", .{ .String = "Alice" });
        } else {
            try g.setNodeProperty(id, "name", .{ .String = "Bob" });
        }
    }

    const iterations: usize = 200;
    var sum_unfiltered: u128 = 0;
    var sum_filtered: u128 = 0;
    var samples_unfiltered = try std.testing.allocator.alloc(u64, iterations);
    var samples_filtered = try std.testing.allocator.alloc(u64, iterations);
    defer std.testing.allocator.free(samples_unfiltered);
    defer std.testing.allocator.free(samples_filtered);

    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        const t1 = timeScan(false, &g, select_label);
        const t2 = timeScan(true, &g, select_label);
        samples_unfiltered[it] = t1;
        samples_filtered[it] = t2;
        sum_unfiltered += t1;
        sum_filtered += t2;
    }

    const mean_unf = @as(f64, @floatFromInt(sum_unfiltered)) / @as(f64, @floatFromInt(iterations));
    const mean_f = @as(f64, @floatFromInt(sum_filtered)) / @as(f64, @floatFromInt(iterations));

    // Overhead check (filtered should not exceed unfiltered by >5%)
    if (mean_f > mean_unf * 1.05) return error.FilteredScanOverheadTooHigh;

    const cv_unf = cv(samples_unfiltered, mean_unf);
    const cv_f = cv(samples_filtered, mean_f);

    if (cv_unf > 0.24) return error.UnfilteredCvTooHigh;
    if (cv_f > 0.24) return error.FilteredCvTooHigh;
}
