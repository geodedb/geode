const std = @import("std");
const perf_gate = @import("perf_gate");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const graph_store = @import("geode").graph_store;

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-GQL-022; FEATURE="GraphStore Snapshot Load"; ASPECT=LoadCorrectnessAndVariance; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_022_GraphStoreLoadCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

const NODE_COUNT: usize = 4096;

// SONNY-2394: GraphStore persistence goes through the storage adapter. A bare
// `GraphStore.init()` store has no adapter, so `saveToFile()` wrote nothing and
// `loadFromFile()` "starts empty" (documented test mode) -- this CANARY had
// silently stopped persisting anything and loaded 0 nodes. Build the snapshot
// on the real engine-backed global store and shut it down cleanly (full
// checkpoint + IdMap/hydration snapshots): exactly the state a restart loads.
fn buildSnapshot(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();

    try store.reserve(NODE_COUNT, 0);
    var labels = [_][]const u8{"Redo"};
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        const node_id = try store.createNode(&labels);
        try store.setNodeProperty(node_id, "seq", .{ .Int = @intCast(i) });
    }
    try store.saveToFile();
}

test "TestCANARY_REQ_GQL_022_GraphStoreLoadCorrectness" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &td.sub_path);
    defer allocator.free(base);

    defer graph_store.setDataDirOverride(allocator, null);

    try buildSnapshot(allocator, base);

    // Restart: reopen the same data dir and load what was persisted.
    const loaded = try graph_store.initGlobalStore(allocator, base);
    defer graph_store.deinitGlobalStore();
    try loaded.loadFromFile();

    try std.testing.expectEqual(NODE_COUNT, loaded.getNodeCount());
}

test "BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &td.sub_path);
    defer allocator.free(base);

    defer graph_store.setDataDirOverride(allocator, null);

    try buildSnapshot(allocator, base);

    const sample_n: usize = 48;
    var samples = try allocator.alloc(u64, sample_n);
    defer allocator.free(samples);

    // Each sample reopens the persisted store and times the load (previously
    // this timed loadFromFile() on an adapter-less store: a no-op).
    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        const store = try graph_store.initGlobalStore(allocator, base);
        defer graph_store.deinitGlobalStore();
        const t0 = compat_nanoTimestamp();
        try store.loadFromFile();
        const t1 = compat_nanoTimestamp();
        samples[i] = @intCast(t1 - t0);
        try std.testing.expectEqual(NODE_COUNT, store.getNodeCount());
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

    const tmp = try allocator.dupe(u64, samples);
    defer allocator.free(tmp);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;

    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    std.debug.print("GraphStoreLoadVarianceEnvelope cv={d:.4} p95_ratio={d:.2} mean={d:.2}\n", .{ cv, p95_ratio, mean });
    try perf_gate.envelope("GraphStore reopen+load", cv, p95_ratio, 0.18, 2.3);
}
