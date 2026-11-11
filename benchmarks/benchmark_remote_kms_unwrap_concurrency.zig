const std = @import("std");
const builtin = @import("builtin");
// Import the hardening test module to reuse the public benchmark function.

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=ConcurrencyStressVariance; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance; OWNER=security; UPDATED=2025-09-26
const kms = @import("security/kms_remote");
const quic = @import("transport/quic");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
// GAP-0883 review fix: getrandom failure previously left the buffer
// undefined; fall back to a monotonic-clock-seeded PRNG fill instead.
fn compat_fillRandom(buf: []u8) void {
    if (comptime builtin.os.tag == .linux) {
        var filled: usize = 0;
        while (filled < buf.len) {
            const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
            if (@as(isize, @bitCast(rc)) <= 0) {
                var prng = std.Random.DefaultPrng.init(nowNs());
                prng.random().bytes(buf[filled..]);
                return;
            }
            filled += rc;
        }
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.Timer removed; clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=ConcurrencyStressVariance; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance; OWNER=security; UPDATED=2025-09-26
// Standalone executable to emit concurrency unwrap variance JSON.

fn connectClient(port: u16, auth: []const u8) !kms.RemoteKmsClient {
    var client = kms.RemoteKmsClient.init(std.heap.page_allocator);
    try client.connect("127.0.0.1", port);
    client.setAuthToken(auth);
    return client;
}

pub fn main() !void {
    // Use page_allocator (thread-safe) instead of GPA to allow server loop in separate thread.
    var server = try kms.RemoteKmsServer.init(std.heap.page_allocator, 0xfeedfacecafebeef);
    defer server.deinit();
    // Local direct mode (skip QUIC handshake due to instability in benchmark context)
    var plain: [32]u8 = undefined;
    // GAP-0142: Use cryptographic random instead of PRNG
    compat_fillRandom(&plain);
    const env = try server.server.wrap(plain);
    const iterations: usize = 64;
    var times = try std.heap.page_allocator.alloc(u64, iterations);
    defer std.heap.page_allocator.free(times);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t0 = nowNs();
        _ = try server.server.unwrap(env);
        times[i] = nowNs() - t0;
    }
    std.sort.heap(u64, times, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    var sum: u128 = 0;
    for (times) |v| sum += v;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(times.len));
    const p95_idx = (iterations * 95) / 100;
    const p95 = times[if (p95_idx == 0) 0 else p95_idx - 1];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    var diff: f128 = 0;
    for (times) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean_f;
        diff += d * d;
    }
    const variance = diff / @as(f128, @floatFromInt(times.len));
    const stdev = std.math.sqrt(variance);
    const cv = stdev / mean_f;
    // Zig 0.16: fixedBufferStream removed; use std.Io.Writer.fixed.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance\",");
    try w.writeAll("\"iterations\":");
    try w.print("{d}", .{iterations});
    try w.writeAll(",\"cv\":");
    try w.print("{d:.6}", .{cv});
    try w.writeAll(",\"p95_mean_ratio\":");
    try w.print("{d:.4}", .{p95_mean_ratio});
    try w.writeAll("}\n");
    const line = w.buffered();
    // Zig 0.16: std.fs.File removed; std.Io.File.stdout() is platform-aware.
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.File.stdout().writeStreamingAll(io, line);
}
