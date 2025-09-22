const std = @import("std");
const wal_mod = @import("wal");
const page_manager = @import("storage_page_manager");

// CANARY: REQ=REQ-GQL-022; FEATURE="Storage Redo"; ASPECT=RedoOptimizationDeltaVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_RedoOptimizationDeltaVarianceEnvelope; OWNER=storage; UPDATED=2025-09-22
// Benchmark target (S-016): Guard redo optimization delta stability
// Acceptance: speedup CV<=0.18, p95/mean<=1.35 across N samples; mean speedup >=1.00 (non-regression)

fn buildSyntheticWal(ally: std.mem.Allocator, base_path: []const u8, inserts: usize) !struct { wal_path: []u8 } {
    var w = wal_mod.Wal.init(ally);
    defer w.deinit();
    try w.openFile(base_path);
    var txn_id: u64 = 1;
    var i: usize = 0;
    while (i < inserts) : (i += 1) {
        const page_id: u32 = @intCast(i / 32);
        const slot: u16 = @intCast(i % 32);
        const payload_data = [_]u8{ 'R', 'E', 'D', 'O' };
        const enc = try wal_mod.Wal.encodeInsert(ally, page_id, slot, payload_data[0..]);
        defer ally.free(enc);
        _ = try w.append(txn_id, .Insert, enc, 0);
        if ((i % 32) == 31) { // commit every 32 inserts
            _ = try w.append(txn_id, .Commit, &.{}, 0);
            txn_id += 1;
        }
    }
    _ = try w.writeCheckpoint();
    try w.fsync();
    const wal_path = try std.fmt.allocPrint(ally, "{s}.wal.0", .{base_path});
    return .{ .wal_path = wal_path };
}

fn sampleDelta(ally: std.mem.Allocator, wal_path: []const u8, base_dir: []const u8) !struct { baseline: u64, optimized: u64 } {
    // Baseline recovery
    var w_base = wal_mod.Wal.init(ally);
    defer w_base.deinit();
    var pm_base = page_manager.PageManager.initPersistent(ally, 512, base_dir);
    defer pm_base.deinit();
    const t0 = std.time.nanoTimestamp();
    _ = try w_base.recover(&pm_base, wal_path);
    const t1 = std.time.nanoTimestamp();

    var w_opt = wal_mod.Wal.init(ally);
    defer w_opt.deinit();
    var pm_opt = page_manager.PageManager.initPersistent(ally, 512, base_dir);
    defer pm_opt.deinit();
    const t2 = std.time.nanoTimestamp();
    _ = try w_opt.recoverOptimized(&pm_opt, wal_path, true);
    const t3 = std.time.nanoTimestamp();

    return .{ .baseline = @intCast(t1 - t0), .optimized = @intCast(t3 - t2) };
}

fn varianceEnvelopeF(samples: []const f128) struct { mean: f128, cv: f128, p95_ratio: f128, p95: f128 } {
    var sum: f128 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const d = s - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    // Copy into temporary buffer for sorting to avoid mutating original samples (not strictly required here).
    var buf = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer buf.deinit();
    const a = buf.allocator();
    const tmp = a.alloc(f128, samples.len) catch @panic("OOM");
    @memcpy(tmp, samples);
    // Sort ascending by numeric value
    std.sort.pdq(f128, tmp, {}, comptime std.sort.asc(f128));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = if (mean == 0) 0 else p95 / mean;
    return .{ .mean = mean, .cv = cv, .p95_ratio = p95_ratio, .p95 = p95 };
}

pub fn runRedoOptimizationDeltaVarianceEnvelope() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(ally, ".");
    defer ally.free(base);
    const wal_base = try std.fmt.allocPrint(ally, "{s}/redo_delta_wal", .{base});
    defer ally.free(wal_base);
    const built = try buildSyntheticWal(ally, wal_base, 4096); // increase inserts to amplify recovery work
    defer ally.free(built.wal_path);

    // Warmup phase to stabilize filesystem cache and allocator behavior
    {
        var warm_w = wal_mod.Wal.init(ally);
        defer warm_w.deinit();
        var warm_pm = page_manager.PageManager.initPersistent(ally, 512, base);
        defer warm_pm.deinit();
        _ = try warm_w.recoverOptimized(&warm_pm, built.wal_path, true);
        _ = try warm_w.recover(&warm_pm, built.wal_path); // baseline warmup
    }

    const N: usize = 64;
    var speedups = try ally.alloc(f128, N);
    defer ally.free(speedups);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        // Take M inner repetitions to reduce timing noise
        const M: usize = 8; // more repetitions per sample to shrink variance tail
        var j: usize = 0;
        var base_acc: f128 = 0;
        var opt_acc: f128 = 0;
        while (j < M) : (j += 1) {
            const sample = try sampleDelta(ally, built.wal_path, base);
            if (sample.optimized == 0 or sample.baseline == 0) return error.UnexpectedZeroTiming;
            base_acc += @as(f128, @floatFromInt(sample.baseline));
            opt_acc += @as(f128, @floatFromInt(sample.optimized));
        }
        const base_mean = base_acc / @as(f128, @floatFromInt(M));
        const opt_mean = opt_acc / @as(f128, @floatFromInt(M));
        speedups[i] = base_mean / opt_mean;
    }
    const stats = varianceEnvelopeF(speedups);
    const cv_thresh: f128 = 0.18;
    const p95_thresh: f128 = 1.35;
    if (stats.cv > cv_thresh or stats.p95_ratio > p95_thresh or stats.mean < 1.0) {
        std.debug.print(
            "VARIANCE_FAIL RedoOptimizationDeltaVarianceEnvelope speedup_mean={d:.3} cv={d:.4} p95_ratio={d:.2} p95={d:.3}\n",
            .{ stats.mean, stats.cv, stats.p95_ratio, stats.p95 },
        );
        return error.VarianceEnvelopeBreached;
    }
    std.debug.print(
        "VARIANCE_OK RedoOptimizationDeltaVarianceEnvelope speedup_mean={d:.3} cv={d:.4} p95_ratio={d:.2} p95={d:.3}\n",
        .{ stats.mean, stats.cv, stats.p95_ratio, stats.p95 },
    );
}

test "BenchmarkCANARY_REQ_GQL_022_RedoOptimizationDeltaVarianceEnvelope" {
    try runRedoOptimizationDeltaVarianceEnvelope();
}

pub fn main() !void {
    try runRedoOptimizationDeltaVarianceEnvelope();
}
