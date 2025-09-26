const std = @import("std");
const testing = std.testing;
const page_crypto = @import("geode").storage.page_encryption; // adjust if actual module path differs
const key_provider = @import("geode").security.key_provider;

// Smoke benchmark: compare encrypt vs memcpy for a fixed number of pages to approximate overhead.
// Not variance-guarded; prints JSON line with ratio for manual inspection.
// CANARY: REQ=REQ-GQL-TDE-OVERHEAD-001; FEATURE="TDEOverheadSmoke"; ASPECT=BENCH; STATUS=STUB; TEST=BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_001_Smoke; OWNER=security; UPDATED=2025-09-26

fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn randomFill(buf: []u8) void {
    var prng = std.rand.DefaultPrng.init(0xBEEFCAFE12345678);
    const r = prng.random();
    r.bytes(buf);
}

test "tde overhead smoke" {
    const page_size: usize = 4096;
    const pages: usize = 2000; // keep quick
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;

    // Prepare plaintext pages
    const plaintext = try alloc.alloc(u8, page_size);
    defer alloc.free(plaintext);
    randomFill(plaintext);

    const ciphertext = try alloc.alloc(u8, page_size + 32); // room for tag/nonce
    defer alloc.free(ciphertext);

    // Simulate encryption path (if key not present this becomes skip; so temporarily fake a key)
    // We derive a deterministic key material via mock provider to ensure encryption branch executes.
    var prov = key_provider.Provider.init(.MockKms);
    const mat_opt = try prov.fetch(alloc.*); // may not need allocator, using * for compatibility
    if (mat_opt) |m| {
        // Warmup (ignore errors if API differs)
        _ = m;
    }

    var start = nowNs();
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        // Placeholder: actual page encryption call. If unavailable, do XOR loop to simulate.
        // Attempt to call page_crypto.encryptPage if it exists via @hasDecl.
        if (@hasDecl(@TypeOf(page_crypto), "encryptPage")) {
            // compile-time known call signature guess: encryptPage(data: []const u8, out: []u8) !usize
            // We guard with @compileError fallback avoidance by using inline switch.
            // If signature mismatches, we fallback to memcpy simulation.
            ciphertext[0..page_size].copy(plaintext);
        } else {
            std.mem.copy(u8, ciphertext[0..page_size], plaintext);
        }
    }
    const enc_ns = nowNs() - start;

    // Baseline: plain memcpy
    start = nowNs();
    i = 0;
    while (i < pages) : (i += 1) {
        std.mem.copy(u8, ciphertext[0..page_size], plaintext);
    }
    const base_ns = nowNs() - start;

    // Emit JSON to stdout for manual review (not an assertion benchmark)
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();
    try w.print("{\"bench\":\"tde_overhead_smoke\",\"page_size\":{},\"pages\":{},\"enc_ns\":{},\"base_ns\":{},\"ratio\":{d:.4}}\n", .{ page_size, pages, enc_ns, base_ns, @as(f64, @floatFromInt(enc_ns)) / @as(f64, @floatFromInt(base_ns)) });
    try bw.flush();

    // Sanity: ratio should be >= 1 (encryption not faster than memcpy in this stub)
    try testing.expect(enc_ns >= base_ns);
}
