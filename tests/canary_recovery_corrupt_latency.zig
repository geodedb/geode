const std = @import("std");
const wal = @import("wal");
const storage_page_manager = @import("storage_page_manager");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_CorruptPageRecoveryLatency; OWNER=storage; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope; OWNER=storage; UPDATED=2025-09-22

fn mean(a: []const f64) f64 {
    var s: f64 = 0;
    for (a) |v| s += v;
    return s / @as(f64, @floatFromInt(a.len));
}
fn stddev(a: []const f64, m: f64) f64 {
    var s: f64 = 0;
    for (a) |v| s += (v - m) * (v - m);
    return @sqrt(s / @as(f64, @floatFromInt(a.len)));
}

test "TestCANARY_REQ_GQL_028_CorruptPageRecoveryLatency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var pm = storage_page_manager.PageManager.init(ally);
    defer pm.deinit();
    var w = wal.Wal.init(ally);
    // open a temp base path in mem FS (use random name)
    try w.openFile("/tmp/geode_corrupt_test");
    // append a few records
    const ins_payload = try wal.Wal.encodeInsert(ally, 1, 0, &.{ 1, 2, 3 });
    defer ally.free(ins_payload);
    _ = try w.append(1, .Insert, ins_payload, 0);
    _ = try w.append(1, .Commit, &.{}, 0);
    try w.fsync();
    // Corrupt last sentinel byte artificially
    if (w.file) |f| {
        var buf: [1]u8 = .{0x00};
        // seek near end minus 1 (best-effort)
        const end = try f.getEndPos();
        if (end > 1) try f.seekTo(end - 1);
        _ = try f.write(&buf);
        try f.seekTo(0);
    }
    // Run recovery; should stop gracefully without panic
    const seg_path = try std.fmt.allocPrint(ally, "{s}.wal.0", .{w.base_path});
    defer ally.free(seg_path);
    _ = try w.recover(&pm, seg_path);
}

test "BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const iters: usize = 180;
    var samples = try ally.alloc(f64, iters);
    defer ally.free(samples);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var pm = storage_page_manager.PageManager.init(ally);
        defer pm.deinit();
        var w = wal.Wal.init(ally);
        try w.openFile("/tmp/geode_corrupt_bench");
        // write several inserts to enlarge log
        var t: usize = 0;
        while (t < 20) : (t += 1) {
            const ip = try wal.Wal.encodeInsert(ally, 1, 0, &.{ 1, 2, 3, 4 });
            defer ally.free(ip);
            _ = try w.append(1, .Insert, ip, 0);
            _ = try w.append(1, .Commit, &.{}, 0);
        }
        try w.fsync();
        // corrupt a few trailing bytes
        if (w.file) |f| {
            const end = try f.getEndPos();
            if (end > 8) {
                try f.seekTo(end - 4);
                var zeros: [4]u8 = .{ 0, 0, 0, 0 };
                _ = try f.write(&zeros);
                try f.seekTo(0);
            }
        }
        const start = std.time.microTimestamp();
        const seg_path2 = try std.fmt.allocPrint(ally, "{s}.wal.0", .{w.base_path});
        defer ally.free(seg_path2);
        _ = w.recover(&pm, seg_path2) catch {}; // tolerate early stop
        const endt = std.time.microTimestamp();
        samples[i] = @as(f64, @floatFromInt(endt - start));
    }
    const m = mean(samples);
    const sd = stddev(samples, m);
    const cv = if (m == 0) 0 else sd / m;
    std.sort.block(f64, samples, {}, comptime std.sort.asc(f64));
    const p95 = samples[(iters * 95) / 100 - 1];
    const ratio = if (m == 0) 0 else p95 / m;
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(ratio <= 2.55);
    std.debug.print("CORRUPT_RECOVERY_LAT m={d:.2} cv={d:.4} p95/mean={d:.2}\n", .{ m, cv, ratio });
}
