const std = @import("std");
const wal_mod = @import("wal");
const storage_pm = @import("storage_page_manager");

// CANARY: REQ=REQ-GQL-022; FEATURE="Storage Redo"; ASPECT=PhysiologicalRedoOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

fn buildSyntheticWal(ally: std.mem.Allocator, base_path: []const u8, inserts: usize) !struct { path: []u8, applied: usize } {
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
        if ((i % 16) == 15) {
            _ = try w.append(txn_id, .Commit, &.{}, 0);
            txn_id += 1;
        }
    }
    _ = try w.writeCheckpoint();
    try w.fsync();
    const p = try std.fmt.allocPrint(ally, "{s}.wal.0", .{base_path});
    return .{ .path = p, .applied = inserts };
}

test "TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(ally, ".");
    defer ally.free(base);
    const wal_base = try std.fmt.allocPrint(ally, "{s}/redo_physiological", .{base});
    defer ally.free(wal_base);
    const built = try buildSyntheticWal(ally, wal_base, 256);
    defer ally.free(built.path);
    var w1 = wal_mod.Wal.init(ally);
    defer w1.deinit();
    var pm1 = storage_pm.PageManager.initPersistent(ally, 512, base);
    defer pm1.deinit();
    const applied1 = try w1.recover(&pm1, built.path);
    try std.testing.expect(applied1 > 0);
    var w2 = wal_mod.Wal.init(ally);
    defer w2.deinit();
    var pm2 = storage_pm.PageManager.initPersistent(ally, 512, base);
    defer pm2.deinit();
    const applied2 = try w2.recoverOptimized(&pm2, built.path, true);
    try std.testing.expectEqual(applied1, applied2);
}

test "BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try td.dir.realpathAlloc(ally, ".");
    defer ally.free(base);
    const wal_base = try std.fmt.allocPrint(ally, "{s}/redo_variance", .{base});
    defer ally.free(wal_base);
    const built = try buildSyntheticWal(ally, wal_base, 384);
    defer ally.free(built.path);
    const sample_n: usize = 48;
    var samples = try ally.alloc(u64, sample_n);
    defer ally.free(samples);
    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        var w = wal_mod.Wal.init(ally);
        defer w.deinit();
        var pm = storage_pm.PageManager.initPersistent(ally, 512, base);
        defer pm.deinit();
        const t0 = std.time.nanoTimestamp();
        const applied = try w.recoverOptimized(&pm, built.path, true);
        const t1 = std.time.nanoTimestamp();
        if (applied == 0) return error.UnexpectedZeroApplied;
        samples[i] = @intCast(t1 - t0);
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(sample_n));
    var acc: f128 = 0;
    for (samples) |s| {
        const d = @as(f128, @floatFromInt(s)) - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(sample_n));
    const stddev = @sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    const tmp = try ally.dupe(u64, samples);
    defer ally.free(tmp);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    if (cv > 0.18 or p95_ratio > 2.3) {
        std.debug.print("VARIANCE_FAIL PhysiologicalRedoVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
        return error.VarianceEnvelopeBreached;
    }
    std.debug.print("VARIANCE_OK PhysiologicalRedoVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
}
