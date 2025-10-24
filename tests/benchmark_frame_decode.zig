const std = @import("std");

// CANARY: REQ=REQ-GQL-005; FEATURE="Frame Decode"; ASPECT=Wire; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_005_FrameDecode; OWNER=wire; UPDATED=2025-09-20

fn decodeFrame(buf: []const u8) !void {
    // synthetic frame: [u32 len][u8 type][payload len bytes]
    if (buf.len < 5) return error.FrameTooSmall;
    const len = std.mem.readIntLittle(u32, buf[0..4]);
    if (len + 4 != buf.len) return error.LengthMismatch;
    _ = buf[4]; // frame type byte
    // simulate payload parse cost by scanning
    var i: usize = 5;
    var checksum: u64 = 0;
    while (i < buf.len) : (i += 1) checksum +%= buf[i];
    if (checksum == 0xFFFF_FFFF_FFFF_FFFF) std.debug.print("", .{}); // prevent optimize-out
}

test "BenchmarkCANARY_REQ_GQL_005_FrameDecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // build synthetic frames
    var frames = std.ArrayList([]u8).init(allocator);
    defer frames.deinit();
    const payload_sizes = [_]usize{ 16, 64, 256, 1024 };
    for (payload_sizes) |ps| {
        const total = 4 + 1 + ps;
        var f = try allocator.alloc(u8, total);
        std.mem.writeIntLittle(u32, f[0..4], @intCast(ps + 1));
        f[4] = 0x01; // type
        var j: usize = 5;
        while (j < total) : (j += 1) f[j] = @intCast(j & 0xFF);
        try frames.append(f);
    }

    var timer = try std.time.Timer.start();
    var iterations: usize = 0;
    while (iterations < 200_000) : (iterations += 1) {
        for (frames.items) |fr| {
            decodeFrame(fr) catch {}; // ignore errors
        }
    }
    const elapsed = timer.read();
    const bytes: usize = 200_000 * (16 + 64 + 256 + 1024 + 4 * 4 + 1 * 4); // approximate
    const throughput = (bytes * 1_000_000_000) / @max(elapsed, 1);
    std.debug.print("FrameDecode bytes_per_sec={} elapsed_ns={}\n", .{ throughput, elapsed });
}
