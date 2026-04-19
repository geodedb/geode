const std = @import("std");
const builtin = @import("builtin");
// File-level TDE encryption engine used by GraphStore
const tde = @import("tde_file_encryption");

// benchmark_tde_encrypt_pages.zig
// Real encryption benchmark invoking PageCrypto.encryptPage for a sequence of synthetic pages.
// Measures mean per-page encryption latency and approximate throughput.
// CANARY: REQ=REQ-GQL-SEC-TDE-OVERHEAD-001; FEATURE="TDEEncryptBenchmark"; ASPECT=PERFORMANCE; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_SEC_TDE_OVERHEAD_001; OWNER=security; UPDATED=2025-09-26

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const alloc: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    // Configuration (keep CI friendly); can be raised locally via env override later
    const page_count: usize = 10_000;
    const page_size: usize = 4096;

    // Deterministic key for reproducibility
    var key_bytes: [tde.KEY_BYTES]u8 = undefined;
    @memset(&key_bytes, 0x42);

    // Buffers: plaintext page
    var plaintext = try alloc.alloc(u8, page_size);
    defer alloc.free(plaintext);

    // Initialize page with pattern; mutate per-iteration to avoid constant folding
    @memset(plaintext, 0x5A);

    var total_encrypt_ns: u128 = 0;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        // Light mutation based on loop counter
        plaintext[0] = @as(u8, @intCast(i & 0xFF));
        const start = nowNs();
        const encrypted = try tde.encryptWithKey(alloc, plaintext, key_bytes);
        defer alloc.free(encrypted);
        const end = nowNs();
        total_encrypt_ns += @as(u128, @intCast(end - start));
    }

    const mean_encrypt_ns = @as(f64, @floatFromInt(total_encrypt_ns)) / @as(f64, @floatFromInt(page_count));
    const total_bytes: f64 = @floatFromInt(page_count * page_size);
    const seconds: f64 = (@as(f64, @floatFromInt(total_encrypt_ns)) / 1_000_000_000.0);
    const throughput_mb_s = if (seconds == 0) 0 else (total_bytes / (1024.0 * 1024.0)) / seconds;

    const out = try std.fmt.allocPrint(alloc,
        \\{{"bench":"BenchmarkCANARY_REQ_GQL_SEC_TDE_OVERHEAD_001","pages":{},"page_size":{},"mean_encrypt_ns":{d},"throughput_mb_s":{d}}}
        \\
    , .{ page_count, page_size, mean_encrypt_ns, throughput_mb_s });
    defer alloc.free(out);
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), out) catch {};
    _ = builtin;
}
