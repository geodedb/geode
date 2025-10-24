const std = @import("std");
// Synthetic OLTP-style benchmark approximating mixed read/write workload with and without simulated TDE cost.
// CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PERFORMANCE; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_OLTP_PERF_001; OWNER=perf; UPDATED=2025-09-26

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const txns: usize = 2000; // CI safe
    var rng = std.rand.DefaultPrng.init(0xDEADBEEF);
    const r = rng.random();

    var timer = try std.time.Timer.start();
    var plain_ns: u128 = 0;
    var enc_ns: u128 = 0;

    // Pre-allocate some buffers to simulate page / record access
    const record_size = 256;
    var plain_buf = try alloc.alloc(u8, record_size);
    defer alloc.free(plain_buf);
    var enc_buf = try alloc.alloc(u8, record_size);
    defer alloc.free(enc_buf);

    // Plain path (simulate hashing + lightweight mutation)
    var i: usize = 0;
    while (i < txns) : (i += 1) {
        timer.reset();
        // random write pattern
        const idx = r.intRangeAtMost(usize, 0, record_size - 1);
        plain_buf[idx] = @as(u8, @intCast(i & 0xFF));
        // hash to simulate checksum/logic
        var h = std.hash.Wyhash.init(i);
        h.update(plain_buf);
        _ = h.final();
        plain_ns += timer.read();
    }

    // Encrypted path (simulate extra AES-GCM like cost via more hash + faux tag)
    i = 0;
    while (i < txns) : (i += 1) {
        timer.reset();
        const idx = r.intRangeAtMost(usize, 0, record_size - 1);
        enc_buf[idx] = @as(u8, @intCast((i * 17) & 0xFF));
        var h1 = std.hash.Wyhash.init(i ^ 0xABCDEF);
        h1.update(enc_buf);
        const hv = h1.final();
        var h2 = std.hash.Wyhash.init(hv);
        h2.update(enc_buf);
        _ = h2.final();
        // Simulate auth tag derivation
        var tag: [16]u8 = undefined;
        std.mem.writeInt(u64, tag[0..8], hv, .little);
        std.mem.writeInt(u64, tag[8..16], hv ^ 0xFFFFFFFFFFFFFFFF, .little);
        enc_ns += timer.read();
    }

    const overhead_pct = if (plain_ns == 0) 0 else (@as(f64, @floatFromInt(enc_ns - plain_ns)) / @as(f64, @floatFromInt(plain_ns))) * 100.0;

    var stdout = std.io.getStdOut().writer();
    try stdout.print("TDE_OLTP_SIM iters={} plain_ns={} enc_ns={} overhead_pct={d:.2}\n", .{ txns, plain_ns, enc_ns, overhead_pct });
}
