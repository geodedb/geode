const std = @import("std");
const graph_store = @import("geode").graph_store;

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot/Recovery"; ASPECT=LoadOptimizedVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotLoadOptimizedVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

// Benchmark comparing baseline loadFromFile vs warmed-cache loadFromFile measuring elapsed ns.
// Enforces variance guard on optimized runs and expects optimized mean <= baseline mean.

const Runs = 12;

fn Stats(comptime N: usize) type {
    return struct {
        samples: [N]i128 = [_]i128{0} ** N,
        idx: usize = 0,
        pub fn add(self: *@This(), v: i128) void {
            self.samples[self.idx] = v;
            self.idx += 1;
        }
        pub fn finalize(self: *@This()) struct { mean: f128, cv: f128, p95: i128 } {
            var sum: f128 = 0;
            var i: usize = 0;
            while (i < self.idx) : (i += 1) sum += @as(f128, @floatFromInt(self.samples[i]));
            const mean = sum / @as(f128, @floatFromInt(self.idx));
            var var_acc: f128 = 0;
            i = 0;
            while (i < self.idx) : (i += 1) {
                const d = @as(f128, @floatFromInt(self.samples[i])) - mean;
                var_acc += d * d;
            }
            const variance = if (self.idx > 1) var_acc / @as(f128, @floatFromInt(self.idx - 1)) else 0;
            const stddev = @sqrt(variance);
            var tmp = self.samples;
            std.sort.block(i128, &tmp, {}, struct {
                fn less(_: void, a: i128, b: i128) bool {
                    return a < b;
                }
            }.less);
            const p95 = tmp[@min(self.idx - 1, (self.idx * 95) / 100)];
            const cv: f128 = if (mean == 0) 0 else stddev / mean;
            return .{ .mean = mean, .cv = cv, .p95 = p95 };
        }
    };
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotLoadOptimizedVarianceEnvelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    graph_store.setDataDirOverride(std.testing.allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(std.testing.allocator, null);

    var store = try graph_store.GraphStore.init(std.testing.allocator);
    defer store.deinit();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        _ = try store.createNode(&.{ "redo" });
    }
    try store.saveToFile();

    const file_path = try graph_store.getPersistenceFilePath(std.testing.allocator);
    defer std.testing.allocator.free(file_path);

    var base_stats = Stats(Runs){};
    var opt_stats = Stats(Runs){};

    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var baseline = try graph_store.GraphStore.init(std.testing.allocator);
        defer baseline.deinit();
        const t0 = std.time.nanoTimestamp();
        try baseline.loadFromFile();
        const t1 = std.time.nanoTimestamp();
        base_stats.add(t1 - t0);

        // Warm cache by reading snapshot bytes, then load again.
        const warm = try std.fs.cwd().readFileAlloc(std.testing.allocator, file_path, 8 * 1024 * 1024);
        std.testing.allocator.free(warm);
        var optimized = try graph_store.GraphStore.init(std.testing.allocator);
        defer optimized.deinit();
        const t2 = std.time.nanoTimestamp();
        try optimized.loadFromFile();
        const t3 = std.time.nanoTimestamp();
        opt_stats.add(t3 - t2);
    }

    const base = base_stats.finalize();
    const opt = opt_stats.finalize();
    const base_mean_i = @as(i128, @intFromFloat(base.mean));
    const opt_mean_i = @as(i128, @intFromFloat(opt.mean));
    const speed_ratio = opt.mean / base.mean;
    const opt_p95_mean_ratio = @as(f128, @floatFromInt(opt.p95)) / opt.mean;
    if (!(opt.cv <= 0.40 and opt_p95_mean_ratio <= 3.00 and speed_ratio <= 1.00)) {
        std.debug.print("VARIANCE_FAIL SnapshotLoadOptimized cv={:.4} p95={} mean_opt={} mean_base={} speed_ratio={:.3}\n", .{ opt.cv, opt.p95, opt_mean_i, base_mean_i, speed_ratio });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK SnapshotLoadOptimized cv={:.4} p95={} mean_opt={} mean_base={} speed_ratio={:.3}\n", .{ opt.cv, opt.p95, opt_mean_i, base_mean_i, speed_ratio });
}
