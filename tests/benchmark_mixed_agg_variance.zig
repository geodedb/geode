const std = @import("std");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=MixedAggregateVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_012_MixedAggregateVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21
// Variance envelope for mixed aggregation workload (COUNT DISTINCT + SUM + AVG + MIN + MAX) under moderate cardinality.

const Iterations = 40; // keep test time modest

fn Stats() type {
    return struct { mean: f64, p95: u64, cv: f64 };
}

fn computeStats(times: []u64) Stats() {
    // Make a copy to avoid mutating caller ordering
    var sorted_buf: [Iterations]u64 = undefined;
    var i: usize = 0;
    while (i < times.len) : (i += 1) sorted_buf[i] = times[i];
    const sorted = sorted_buf[0..times.len];
    std.sort.block(u64, sorted, {}, comptime std.sort.asc(u64));
    var sum: f128 = 0;
    for (sorted) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f = sum / @as(f128, sorted.len);
    var var_acc: f128 = 0;
    for (sorted) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f;
        var_acc += diff * diff;
    }
    const variance = if (sorted.len > 1) var_acc / @as(f128, (sorted.len - 1)) else 0;
    const stddev = std.math.sqrt(@as(f64, @floatCast(variance)));
    const mean64 = @as(f64, @floatCast(mean_f));
    const cv = if (mean64 == 0) 0 else stddev / mean64;
    const idx95 = (sorted.len * 95 + 99) / 100 - 1;
    return .{ .mean = mean64, .p95 = sorted[idx95], .cv = cv };
}

fn buildDataset(ally: std.mem.Allocator, groups: usize, rows_per_group: usize) ![]exec.BindingRow {
    var list = std.ArrayList(exec.BindingRow).init(ally);
    var g: usize = 0;
    while (g < groups) : (g += 1) {
        var r: usize = 0;
        while (r < rows_per_group) : (r += 1) {
            // group key as string g_#
            const name = try std.fmt.allocPrint(ally, "g_{d}", .{g});
            // value pattern: distinct distribution and negative injection every 5th row
            const base: i64 = @intCast((r % 7) + @as(usize, g % 11));
            const val: i64 = if ((r % 5) == 0) -@as(i64, base) else @as(i64, base);
            const w: i64 = @as(i64, @intCast((g % 13) * 10 + r));
            var cols = try ally.alloc(exec.BindingValue, 3);
            cols[0] = exec.BindingValue{ .Str = name };
            cols[1] = exec.BindingValue{ .Int = val };
            cols[2] = exec.BindingValue{ .Int = w };
            try list.append(.{ .cols = cols });
        }
    }
    return list.toOwnedSlice();
}

fn freeDataset(ally: std.mem.Allocator, rows: []exec.BindingRow) void {
    for (rows) |r| {
        // free group key string and cols
        if (r.cols[0] == .Str) ally.free(r.cols[0].Str);
        ally.free(r.cols);
    }
    ally.free(rows);
}

test "BenchmarkCANARY_REQ_GQL_012_MixedAggregateVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const dataset = try buildDataset(ally, 120, 6); // 720 rows
    defer freeDataset(ally, dataset);

    var build_times = try ally.alloc(u64, Iterations);
    var emit_times = try ally.alloc(u64, Iterations);
    defer {
        ally.free(build_times);
        ally.free(emit_times);
    }

    const agg_specs = [_]exec.Agg{ .CountDistinct, .Sum, .Avg, .Min, .Max };

    var it: usize = 0;
    while (it < Iterations) : (it += 1) {
        var agg = exec.HashAggregator.init(ally, 1 << 20);
        const t0 = std.time.nanoTimestamp();
        for (dataset) |row| {
            var key_vals = [_]exec.BindingValue{row.cols[0]};
            var inputs = [_]exec.BindingValue{ row.cols[1], row.cols[1], row.cols[1], row.cols[1], row.cols[2] };
            try agg.addRow(&key_vals, &inputs, &agg_specs);
        }
        const t1 = std.time.nanoTimestamp();
        _ = try agg.getResults();
        const t2 = std.time.nanoTimestamp();
        build_times[it] = @intCast(t1 - t0);
        emit_times[it] = @intCast(t2 - t1);
        agg.deinit();
    }

    const st_build = computeStats(&build_times);
    const st_emit = computeStats(&emit_times);

    // Envelope thresholds (Graph Analytics class reused): CV<=0.22; p95/mean<=2.55
    const build_ratio = @as(f64, @floatFromInt(st_build.p95)) / st_build.mean;
    const emit_ratio = @as(f64, @floatFromInt(st_emit.p95)) / st_emit.mean;
    if (!(st_build.cv <= 0.22 and st_emit.cv <= 0.22 and build_ratio <= 2.55 and emit_ratio <= 2.55)) {
        std.debug.print("VARIANCE_FAIL MixedAggregateVarianceEnvelope build_cv={:.4} emit_cv={:.4} build_p95={} build_mean={d} emit_p95={} emit_mean={d}\n", .{ st_build.cv, st_emit.cv, st_build.p95, @as(i128, @intFromFloat(st_build.mean)), st_emit.p95, @as(i128, @intFromFloat(st_emit.mean)) });
        return error.TestExpectedEqual;
    }
    std.debug.print("VARIANCE_OK MixedAggregateVarianceEnvelope build_cv={:.4} emit_cv={:.4} build_p95={} build_mean={d} emit_p95={} emit_mean={d}\n", .{ st_build.cv, st_emit.cv, st_build.p95, @as(i128, @intFromFloat(st_build.mean)), st_emit.p95, @as(i128, @intFromFloat(st_emit.mean)) });
}
