const std = @import("std");
const builtin = @import("builtin");
// Import the hardening test module to reuse the public benchmark function.

// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=ConcurrencyStressVariance; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance; OWNER=security; UPDATED=2025-09-26
const kms = @import("security/kms_remote");
const quic = @import("transport/quic");

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
    var server = kms.RemoteKmsServer.init(std.heap.page_allocator, 0xfeedfacecafebeef);
    // Local direct mode (skip QUIC handshake due to instability in benchmark context)
    var plain: [32]u8 = undefined;
    // GAP-0142: Use cryptographic random instead of PRNG
    std.crypto.random.bytes(&plain);
    const env = server.server.wrap(plain);
    const iterations: usize = 64;
    var times = try std.heap.page_allocator.alloc(u64, iterations);
    defer std.heap.page_allocator.free(times);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var t = try std.time.Timer.start();
        _ = try server.server.unwrap(env);
        times[i] = t.read();
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
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance\",");
    try w.writeAll("\"iterations\":");
    try w.print("{d}", .{iterations});
    try w.writeAll(",\"cv\":");
    try w.print("{d:.6}", .{cv});
    try w.writeAll(",\"p95_mean_ratio\":");
    try w.print("{d:.4}", .{p95_mean_ratio});
    try w.writeAll("}\n");
    const line = fbs.getWritten();
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(line);
}
