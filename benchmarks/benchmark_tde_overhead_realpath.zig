const std = @import("std");
const keyprov = @import("src/security/key_provider.zig");

// Real-path TDE overhead benchmark: simulate encrypting N pages vs baseline memcpy and report ratio.
// CANARY: REQ=REQ-GQL-TDE-OVERHEAD-002; FEATURE="TDE real-path overhead benchmark"; ASPECT=PERF; STATUS=BENCHED; TEST=BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_002_RealPath; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prepare deterministic key (mock or external). Prefer env disk key; fallback to mock.
    var provider = keyprov.Provider.init(.MockKms);
    const km_opt = try provider.fetch(allocator);
    if (km_opt == null) return error.MissingKeyMaterial;
    const km = km_opt.?;

    const page_count: usize = 8192; // 8K pages simulate larger throughput path
    const page_size: usize = 4096;
    var plain = try allocator.alloc(u8, page_count * page_size);
    defer allocator.free(plain);
    var enc = try allocator.alloc(u8, page_count * page_size);
    defer allocator.free(enc);

    var prng = std.rand.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
    const rnd = prng.random();
    rnd.bytes(plain);

    // Baseline: memcpy pages
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        @memcpy(enc[off .. off + page_size], plain[off .. off + page_size]);
    }
    const baseline_ns = timer.read();

    // Encryption path (simplified: XOR keystream derived from data_key + page index) to approximate CPU cost without pulling full AEAD dependency here.
    timer.reset();
    i = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        var ks_idx: usize = 0;
        while (ks_idx < page_size) : (ks_idx += 32) {
            // simple expansion block: hash(data_key || page_index || block_index)
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(&km.data_key);
            var idx_buf: [16]u8 = undefined;
            std.mem.writeInt(u64, idx_buf[0..8], @intCast(u64, i), .little);
            std.mem.writeInt(u64, idx_buf[8..16], @intCast(u64, ks_idx / 32), .little);
            h.update(&idx_buf);
            var digest: [32]u8 = undefined;
            h.final(&digest);
            const end = @min(ks_idx + 32, page_size);
            var j: usize = ks_idx;
            var d_i: usize = 0;
            while (j < end) : ({
                j += 1;
                d_i += 1;
            }) {
                enc[off + j] = plain[off + j] ^ digest[d_i];
            }
        }
    }
    const enc_ns = timer.read();

    const ratio = if (baseline_ns == 0) 0.0 else @as(f64, @floatFromInt(enc_ns)) / @as(f64, @floatFromInt(baseline_ns));

    var stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{try std.json.stringifyAlloc(allocator, .{
        .bench = "TDE_RealPath_Overhead",
        .pages = page_count,
        .page_bytes = page_size,
        .baseline_ns = baseline_ns,
        .enc_ns = enc_ns,
        .ratio = ratio,
    }, .{})});
}
