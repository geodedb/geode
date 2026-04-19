const std = @import("std");
const keyprov = @import("src/security/key_provider.zig");

// Real-path TDE overhead benchmark: simulate encrypting N pages vs baseline memcpy and report ratio.
// CANARY: REQ=REQ-GQL-TDE-OVERHEAD-002; FEATURE="TDE real-path overhead benchmark"; ASPECT=PERF; STATUS=BENCHED; TEST=BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_002_RealPath; OWNER=security; UPDATED=2025-09-26

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    // ReleaseFast uses smp_allocator (no debug bookkeeping); Debug uses DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

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

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
    const rnd = prng.random();
    rnd.bytes(plain);

    // Baseline: memcpy pages
    const baseline_start_ns = nowNs();
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        @memcpy(enc[off .. off + page_size], plain[off .. off + page_size]);
    }
    const baseline_ns = nowNs() - baseline_start_ns;

    // Encryption path (simplified: XOR keystream derived from data_key + page index) to approximate CPU cost without pulling full AEAD dependency here.
    const enc_start_ns = nowNs();
    i = 0;
    while (i < page_count) : (i += 1) {
        const off = i * page_size;
        var ks_idx: usize = 0;
        while (ks_idx < page_size) : (ks_idx += 32) {
            // simple expansion block: hash(data_key || page_index || block_index)
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(&km.data_key);
            var idx_buf: [16]u8 = undefined;
            std.mem.writeInt(u64, idx_buf[0..8], @as(u64, @intCast(i)), .little);
            std.mem.writeInt(u64, idx_buf[8..16], @as(u64, @intCast(ks_idx / 32)), .little);
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
    const enc_ns = nowNs() - enc_start_ns;

    const ratio = if (baseline_ns == 0) 0.0 else @as(f64, @floatFromInt(enc_ns)) / @as(f64, @floatFromInt(baseline_ns));

    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .bench = "TDE_RealPath_Overhead",
        .pages = page_count,
        .page_bytes = page_size,
        .baseline_ns = baseline_ns,
        .enc_ns = enc_ns,
        .ratio = ratio,
    }, .{});
    defer allocator.free(json);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(proc_init.io, json);
    try stdout.writeStreamingAll(proc_init.io, "\n");
}
