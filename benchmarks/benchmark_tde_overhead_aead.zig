const std = @import("std");
const crypto = std.crypto;
const keyprov = @import("src/security/key_provider.zig");

// benchmark_tde_overhead_aead.zig
// Measures real AES-256-GCM encryption cost per page vs memcpy baseline.
// Deterministic seed for reproducibility; non-deterministic nonces per page.
// CANARY: REQ=REQ-GQL-TDE-OVERHEAD-003; FEATURE="TDE real AEAD overhead benchmark"; ASPECT=PERF; STATUS=BENCHED; TEST=BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_003_AEAD; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Acquire key material
    var provider = keyprov.Provider.init(.MockKms);
    const km_opt = try provider.fetch(allocator);
    if (km_opt == null) return error.MissingKeyMaterial;
    const data_key = km_opt.?.data_key;

    const page_count: usize = 4096; // fewer pages than synthetic to keep runtime modest
    const page_size: usize = 4096;
    var plain = try allocator.alloc(u8, page_count * page_size);
    defer allocator.free(plain);
    var enc = try allocator.alloc(u8, page_count * page_size);
    defer allocator.free(enc);

    var prng = std.rand.DefaultPrng.init(0xA0B1_C2D3_E4F5_1234);
    prng.random().bytes(plain);

    // Baseline memcpy
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        @memcpy(enc[off .. off + page_size], plain[off .. off + page_size]);
    }
    const baseline_ns = timer.read();

    // AEAD encrypt each page in-place to enc buffer
    timer.reset();
    i = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        const src = plain[off .. off + page_size];
        const dst = enc[off .. off + page_size];
        var nonce: [12]u8 = undefined;
        // Random per page nonce
        prng.random().bytes(&nonce);
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(dst, &tag, src, &.{}, nonce, data_key);
        // Mix tag into first bytes so compiler cannot eliminate work
        const mix_len = @min(tag.len, dst.len);
        var j: usize = 0;
        while (j < mix_len) : (j += 1) dst[j] ^= tag[j];
    }
    const enc_ns = timer.read();

    const ratio = if (baseline_ns == 0) 0.0 else @as(f64, @floatFromInt(enc_ns)) / @as(f64, @floatFromInt(baseline_ns));

    var stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{try std.json.stringifyAlloc(allocator, .{
        .bench = "TDE_AEAD_Overhead",
        .pages = page_count,
        .page_bytes = page_size,
        .baseline_ns = baseline_ns,
        .enc_ns = enc_ns,
        .ratio = ratio,
    }, .{})});
}
