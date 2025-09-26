const std = @import("std");
// Import real page encryption engine (AES-256-GCM with per-page DEK derivation)
const storage_crypto = @import("../src/storage/crypto.zig");

// benchmark_tde_encrypt_pages.zig
// Real encryption benchmark invoking PageCrypto.encryptPage for a sequence of synthetic pages.
// Measures mean per-page encryption latency and approximate throughput.
// CANARY: REQ=REQ-GQL-SEC-TDE-OVERHEAD-001; FEATURE="TDEEncryptBenchmark"; ASPECT=PERFORMANCE; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_SEC_TDE_OVERHEAD_001; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;

    // Configuration (keep CI friendly); can be raised locally via env override later
    const page_count: usize = 10_000;
    const page_size: usize = 4096;

    // Prepare crypto engine with deterministic master key for reproducibility
    var master_key_bytes: [32]u8 = undefined;
    @memset(&master_key_bytes, 0x42);
    const master_key = storage_crypto.EncryptionKey{
        .data = master_key_bytes,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .local_file,
            .key_id = "bench-master-key",
            .created_at = 0,
            .rotated_at = null,
            .version = 1,
        },
    };

    var crypto_engine = try storage_crypto.PageCrypto.init(alloc.*, master_key, null);
    defer crypto_engine.deinit();

    // Buffers: plaintext page and ciphertext (nonce + page + tag = +28 bytes)
    var plaintext = try alloc.alloc(u8, page_size);
    defer alloc.free(plaintext);
    const ciphertext = try alloc.alloc(u8, page_size + 28);
    defer alloc.free(ciphertext);

    // Initialize page with pattern; mutate per-iteration to avoid constant folding
    std.mem.set(u8, plaintext, 0x5A);

    var total_encrypt_ns: u128 = 0;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        // Light mutation based on loop counter
        plaintext[0] = @as(u8, @intCast(i & 0xFF));
        const start = std.time.nanoTimestamp();
        try crypto_engine.encryptPage(@intCast(i), plaintext, ciphertext, &[_]u8{});
        const end = std.time.nanoTimestamp();
        total_encrypt_ns += @as(u128, @intCast(end - start));
    }

    const mean_encrypt_ns = @as(f64, @floatFromInt(total_encrypt_ns)) / @as(f64, @floatFromInt(page_count));
    const total_bytes: f64 = @floatFromInt(page_count * page_size);
    const seconds: f64 = (@as(f64, @floatFromInt(total_encrypt_ns)) / 1_000_000_000.0);
    const throughput_mb_s = if (seconds == 0) 0 else (total_bytes / (1024.0 * 1024.0)) / seconds;

    var stdout = std.io.getStdOut().writer();
    const out_obj = .{
        .bench = "BenchmarkCANARY_REQ_GQL_SEC_TDE_OVERHEAD_001",
        .pages = page_count,
        .page_size = page_size,
        .mean_encrypt_ns = mean_encrypt_ns,
        .throughput_mb_s = throughput_mb_s,
    };
    try stdout.print("{s}\n", .{try std.json.stringifyAlloc(alloc, out_obj, .{})});
}
