const std = @import("std");
const wal = @import("wal");
const storage = @import("storage_page_manager");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL/Recovery"; ASPECT=RedoOptimizedVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_RedoOptimizedVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

// Benchmark comparing baseline recover() vs recoverOptimized(..., optimize=true) measuring elapsed ns.
// Enforces variance guard on optimized runs and ensures optimized mean <= 0.85 * baseline mean (simple speedup heuristic).

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

test "BenchmarkCANARY_REQ_GQL_028_RedoOptimizedVarianceEnvelope" {
    var tmp_dir_buf: [256]u8 = undefined;
    const cwd = std.fs.cwd();
    const dir_name = try std.fmt.bufPrint(&tmp_dir_buf, "wal_redo_bench_{d}", .{std.time.milliTimestamp()});
    var bench_dir = try cwd.makeOpenPath(dir_name, .{});
    defer bench_dir.close();

    // Build a WAL with inserts and periodic checkpoints to exercise skip logic.
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(dir_name ++ "/bench");
    w.setCompactionCadence(usize.max, usize.max); // disable compaction for deterministic layout

    // Populate log
    var txn: u64 = 1;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        // simple insert payload (page 0, slot varies) 4+2+2+len
        const payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, @intCast(i % 16), &[_]u8{ 1, 2, 3, 4 });
        defer std.testing.allocator.free(payload);
        _ = try w.append(txn, .Insert, payload, 0);
        if (i % 40 == 0 and i != 0) {
            _ = try w.writeCheckpoint();
        }
        if (i % 50 == 0 and i != 0) {
            _ = try w.append(txn, .Commit, &.{}, 0);
            txn += 1;
        }
    }
    try w.fsync();

    var pm_baseline = storage.PageManager.init(std.testing.allocator);
    defer pm_baseline.deinit();
    var pm_opt = storage.PageManager.init(std.testing.allocator);
    defer pm_opt.deinit();

    var base_stats = Stats(Runs){};
    var opt_stats = Stats(Runs){};

    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const t0 = std.time.nanoTimestamp();
        _ = try w.recover(&pm_baseline, dir_name ++ "/bench.wal.0");
        const t1 = std.time.nanoTimestamp();
        base_stats.add(t1 - t0);
        const t2 = std.time.nanoTimestamp();
        _ = try w.recoverOptimized(&pm_opt, dir_name ++ "/bench.wal.0", true);
        const t3 = std.time.nanoTimestamp();
        opt_stats.add(t3 - t2);
    }

    const base = base_stats.finalize();
    const opt = opt_stats.finalize();
    const base_mean_i = @as(i128, @intFromFloat(base.mean));
    const opt_mean_i = @as(i128, @intFromFloat(opt.mean));
    const speed_ratio = opt.mean / base.mean;
    const opt_p95_mean_ratio = @as(f128, @floatFromInt(opt.p95)) / opt.mean;
    if (!(opt.cv <= 0.22 and opt_p95_mean_ratio <= 2.55 and speed_ratio <= 0.85)) {
        std.debug.print("VARIANCE_FAIL RedoOptimized cv={:.4} p95={} mean_opt={} mean_base={} speed_ratio={:.3}\n", .{ opt.cv, opt.p95, opt_mean_i, base_mean_i, speed_ratio });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK RedoOptimized cv={:.4} p95={} mean_opt={} mean_base={} speed_ratio={:.3}\n", .{ opt.cv, opt.p95, opt_mean_i, base_mean_i, speed_ratio });
}
