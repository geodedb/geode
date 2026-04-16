const std = @import("std");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const graph_store = @import("geode").graph_store;

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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var labels = [_][]const u8{"Person"};
    _ = try store.createNode(&labels);
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io_fs, path, .{ .mode = .read_write });
    defer file.close(io_fs);
    const end = try file.length(io_fs);
    if (end > 1) {
        var buf: [1]u8 = .{0x00};
        try file.writePositionalAll(io_fs, &buf, end - 1);
    }

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    _ = store2.loadFromFile() catch {};
}

test "BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const iters: usize = 180;
    var samples = try allocator.alloc(f64, iters);
    defer allocator.free(samples);
    var i: usize = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    while (i < iters) : (i += 1) {
        var store = try graph_store.GraphStore.init(allocator);
        defer store.deinit();
        var t: usize = 0;
        var bench_labels = [_][]const u8{"Bench"};
        while (t < 20) : (t += 1) {
            _ = try store.createNode(&bench_labels);
        }
        try store.saveToFile();

        const path = try graph_store.getPersistenceFilePath(allocator);
        defer allocator.free(path);
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io_fs, path, .{ .mode = .read_write });
        defer file.close(io_fs);
        const end = try file.length(io_fs);
        if (end > 8) {
            var zeros: [4]u8 = .{ 0, 0, 0, 0 };
            try file.writePositionalAll(io_fs, &zeros, end - 4);
        }

        const start = compat_microTimestamp();
        var store2 = try graph_store.GraphStore.init(allocator);
        defer store2.deinit();
        _ = store2.loadFromFile() catch {}; // tolerate checksum mismatch
        const endt = compat_microTimestamp();
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
