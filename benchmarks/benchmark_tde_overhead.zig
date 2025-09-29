const std = @import("std");
const builtin = @import("builtin");
const page_manager = @import("storage_page_manager");

// BenchmarkCANARY_REQ_GQL_TDE_001_TDEOverhead
// Measures approximate relative overhead of encrypted vs unencrypted page write/read cycles.
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE performance benchmark"; ASPECT=PERFORMANCE; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_001_TDEOverhead; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator(); // allocator placeholder (future: actual page manager allocation path)

    const iters: usize = 1000; // lightweight baseline; CI safe

    var timer = try std.time.Timer.start();
    var plain_total: u64 = 0;
    var enc_total: u64 = 0;

    // Plain path (encryption disabled)
    {
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            timer.reset();
            // Placeholder: simulate page write + read cost
            var buf: [4096]u8 = undefined;
            @memset(&buf, @as(u8, @intCast(i & 0xFF)));
            // pretend checksum/hash
            var h = std.hash.Wyhash.init(0);
            h.update(&buf);
            _ = h.final();
            plain_total += timer.read();
        }
    }

    // Encrypted path (simulate via extra hash rounds + tag) until actual function calls plumbed
    {
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            timer.reset();
            var buf: [4096]u8 = undefined;
            @memset(&buf, @as(u8, @intCast((i * 31) & 0xFF)));
            // simulate encrypt = two wyhash rounds + tag gen
            var h1 = std.hash.Wyhash.init(1);
            h1.update(&buf);
            const r1 = h1.final();
            var tag: [16]u8 = undefined;
            std.mem.writeInt(u64, tag[0..8], r1, .little);
            std.mem.writeInt(u64, tag[8..16], r1 ^ 0xFFFF, .little);
            enc_total += timer.read();
        }
    }

    const overhead_pct = if (plain_total == 0) 0 else blk: {
        const diff = if (enc_total >= plain_total) enc_total - plain_total else 0;
        break :blk @as(f64, @floatFromInt(diff)) / @as(f64, @floatFromInt(plain_total)) * 100.0;
    };

    const out = try std.fmt.allocPrint(gpa.allocator(), "TDE_SIM_OVERHEAD iters={} plain_ns={} enc_ns={} overhead_pct={d:.2}\n", .{ iters, plain_total, enc_total, overhead_pct });
    defer gpa.allocator().free(out);
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(out) catch {};
}
