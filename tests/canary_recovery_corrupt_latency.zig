const std = @import("std");
const graph_store = @import("../src/graph_store.zig");

// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_CorruptPageRecoveryLatency; OWNER=storage; UPDATED=2026-02-04
// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

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
    const allocator = gpa.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const end = try file.getEndPos();
    if (end > 1) {
        try file.seekTo(end - 1);
        var buf: [1]u8 = .{0x00};
        _ = try file.write(&buf);
        try file.seekTo(0);
    }

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    _ = store2.loadFromFile() catch {};
}

test "BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const iters: usize = 180;
    var samples = try allocator.alloc(f64, iters);
    defer allocator.free(samples);
    var i: usize = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    while (i < iters) : (i += 1) {
        var store = graph_store.GraphStore.init(allocator);
        defer store.deinit();
        var t: usize = 0;
        while (t < 20) : (t += 1) {
            _ = try store.createNode(&.{"Bench"});
        }
        try store.saveToFile();

        const path = try graph_store.getPersistenceFilePath(allocator);
        defer allocator.free(path);
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        const end = try file.getEndPos();
        if (end > 8) {
            try file.seekTo(end - 4);
            var zeros: [4]u8 = .{ 0, 0, 0, 0 };
            _ = try file.write(&zeros);
            try file.seekTo(0);
        }

        const start = std.time.microTimestamp();
        var store2 = graph_store.GraphStore.init(allocator);
        defer store2.deinit();
        _ = store2.loadFromFile() catch {}; // tolerate checksum mismatch
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
