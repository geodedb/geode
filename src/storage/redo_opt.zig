const std = @import("std");
// Use build.zig registered modules (wal, storage_page_manager) when compiled via test harness.
const wal_mod = @import("wal");
const page_manager = @import("storage_page_manager");

// Physiological redo optimization harness: wraps wal.recoverOptimized with optimize=true.
// CANARY: REQ=REQ-GQL-022; FEATURE="Storage Redo"; ASPECT=PhysiologicalRedoOptimization; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

pub fn physiologicalRedoRecover(w: *wal_mod.Wal, pm: *page_manager.PageManager, wal_path: []const u8) !usize {
    return try w.recoverOptimized(pm, wal_path, true);
}

fn buildSyntheticWal(ally: std.mem.Allocator, base_path: []const u8, inserts: usize) !struct { wal_path: []u8 } {
    var w = wal_mod.Wal.init(ally);
    defer w.deinit();
    try w.openFile(base_path);
    // Generate simple records across multiple pages with grouped txn commits.
    var txn_id: u64 = 1;
    var i: usize = 0;
    while (i < inserts) : (i += 1) {
        const page_id: u32 = @intCast(i / 32);
        const slot: u16 = @intCast(i % 32);
        const payload_data = [_]u8{ 'A', 'B', 'C', 'D' };
        const enc = try wal_mod.Wal.encodeInsert(ally, page_id, slot, payload_data[0..]);
        defer ally.free(enc);
        _ = try w.append(txn_id, .Insert, enc, 0);
        if ((i % 16) == 15) { // commit every 16 inserts
            _ = try w.append(txn_id, .Commit, &.{}, 0);
            txn_id += 1;
        }
    }
    _ = try w.writeCheckpoint();
    try w.fsync();
    const wal_path = try std.fmt.allocPrint(ally, "{s}.wal.0", .{base_path});
    return .{ .wal_path = wal_path };
}

test "TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(ally, ".");
    defer ally.free(base);
    const wal_base = try std.fmt.allocPrint(ally, "{s}/redo_wal", .{base});
    defer ally.free(wal_base);
    const built = try buildSyntheticWal(ally, wal_base, 256);
    defer ally.free(built.wal_path);
    // Baseline recovery
    var w_baseline = wal_mod.Wal.init(ally);
    defer w_baseline.deinit();
    var pm_base = page_manager.PageManager.initPersistent(ally, 512, base);
    defer pm_base.deinit();
    const applied_baseline = try w_baseline.recover(&pm_base, built.wal_path);
    try std.testing.expect(applied_baseline > 0);
    // Optimized recovery
    var w_opt = wal_mod.Wal.init(ally);
    defer w_opt.deinit();
    var pm_opt = page_manager.PageManager.initPersistent(ally, 512, base);
    defer pm_opt.deinit();
    const applied_opt = try physiologicalRedoRecover(&w_opt, &pm_opt, built.wal_path);
    try std.testing.expectEqual(applied_baseline, applied_opt);
}

test "BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(ally, ".");
    defer ally.free(base);
    const wal_base = try std.fmt.allocPrint(ally, "{s}/redo_wal_bench", .{base});
    defer ally.free(wal_base);
    const built = try buildSyntheticWal(ally, wal_base, 384);
    defer ally.free(built.wal_path);
    const samples_count: usize = 48;
    var samples = try ally.alloc(u64, samples_count);
    defer ally.free(samples);
    var i: usize = 0;
    while (i < samples_count) : (i += 1) {
        var w = wal_mod.Wal.init(ally);
        defer w.deinit();
        var pm = page_manager.PageManager.initPersistent(ally, 512, base);
        defer pm.deinit();
        const t0 = std.time.nanoTimestamp();
        const applied = try physiologicalRedoRecover(&w, &pm, built.wal_path);
        const t1 = std.time.nanoTimestamp();
        if (applied == 0) return error.UnexpectedZeroApplied;
        samples[i] = @intCast(t1 - t0);
    }
    // Stats
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const d = @as(f128, @floatFromInt(s)) - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    const tmp = try ally.alloc(u64, samples.len);
    defer ally.free(tmp);
    std.mem.copy(u64, tmp, samples);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    // Tighter thresholds for sequential I/O predictability.
    if (cv > 0.18 or p95_ratio > 2.3) {
        std.debug.print("VARIANCE_FAIL PhysiologicalRedoVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
        return error.VarianceEnvelopeBreached;
    }
    std.debug.print("VARIANCE_OK PhysiologicalRedoVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
}
