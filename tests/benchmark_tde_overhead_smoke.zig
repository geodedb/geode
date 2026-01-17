const std = @import("std");
const testing = std.testing;
const page_encryption = @import("geode").storage.page_encryption;

// Smoke benchmark: compare TDE encrypt vs plain memcpy for a fixed number of pages to approximate overhead.
// Measures real AES-GCM encryption overhead when TDE is enabled.
// Not variance-guarded; prints JSON line with ratio for manual inspection.
// CANARY: REQ=REQ-GQL-TDE-OVERHEAD-001; FEATURE="TDEOverheadSmoke"; ASPECT=BENCH; STATUS=TESTED; TEST=BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_001_Smoke; OWNER=security; UPDATED=2026-01-16

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn randomFill(buf: []u8) void {
    var prng = std.Random.DefaultPrng.init(0xBEEFCAFE12345678);
    prng.random().bytes(buf);
}

test "BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_001_Smoke" {
    const page_size: usize = 4096;
    const pages: usize = 1000; // Enough to get stable timing
    const allocator = testing.allocator;

    // Prepare plaintext page
    const plaintext = try allocator.alloc(u8, page_size);
    defer allocator.free(plaintext);
    randomFill(plaintext);

    // Buffer for memcpy baseline
    const baseline_buf = try allocator.alloc(u8, page_size);
    defer allocator.free(baseline_buf);

    // Warmup - run a few iterations to warm up caches
    var warmup_i: usize = 0;
    while (warmup_i < 10) : (warmup_i += 1) {
        const encrypted = try page_encryption.encryptForWrite(allocator, warmup_i, plaintext);
        allocator.free(encrypted);
    }

    // Measure encryption path (real AES-GCM when TDE enabled, memcpy when disabled)
    const enc_start = nowNs();
    var enc_i: usize = 0;
    while (enc_i < pages) : (enc_i += 1) {
        const encrypted = try page_encryption.encryptForWrite(allocator, enc_i, plaintext);
        // Free immediately to avoid OOM
        allocator.free(encrypted);
    }
    const enc_ns: u64 = @intCast(nowNs() - enc_start);

    // Measure baseline: plain memcpy (no encryption)
    const base_start = nowNs();
    var base_i: usize = 0;
    while (base_i < pages) : (base_i += 1) {
        @memcpy(baseline_buf, plaintext);
        // Memory barrier to prevent optimizer from removing the copy
        std.atomic.fence(.seq_cst);
    }
    const base_ns: u64 = @intCast(nowNs() - base_start);

    // Calculate overhead ratio
    const ratio: f64 = if (base_ns > 0)
        @as(f64, @floatFromInt(enc_ns)) / @as(f64, @floatFromInt(base_ns))
    else
        1.0;

    // Check if TDE is enabled (encryption adds overhead)
    const tde_enabled = page_encryption.shouldEncrypt();

    // Emit JSON to stdout for benchmark tracking
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{{\"bench\":\"BenchmarkCANARY_REQ_GQL_TDE_OVERHEAD_001_Smoke\",\"page_size\":{d},\"pages\":{d},\"enc_ns\":{d},\"base_ns\":{d},\"ratio\":{d:.4},\"tde_enabled\":{}}}\n", .{
        page_size,
        pages,
        enc_ns,
        base_ns,
        ratio,
        tde_enabled,
    });

    // Performance assertions:
    // - When TDE is enabled, ratio should be < 10x (AES-GCM is fast with AES-NI)
    // - When TDE is disabled, ratio should be ~1.0 (just memcpy)
    if (tde_enabled) {
        // TDE enabled: encryption overhead should be reasonable (< 10x memcpy)
        try testing.expect(ratio < 10.0);
    } else {
        // TDE disabled: should be close to 1.0 (just memcpy + allocation overhead)
        try testing.expect(ratio < 5.0);
    }

    // Sanity check: encryption should complete in reasonable time
    // At 1000 pages * 4KB = 4MB, should complete in < 1 second
    try testing.expect(enc_ns < 1_000_000_000); // < 1 second
}

test "TDE overhead benchmark with encryption enabled simulation" {
    // This test verifies the encryption path works correctly
    const allocator = testing.allocator;
    const page_size: usize = 4096;

    // Create test page
    const plaintext = try allocator.alloc(u8, page_size);
    defer allocator.free(plaintext);
    randomFill(plaintext);

    // Encrypt the page
    const encrypted = try page_encryption.encryptForWrite(allocator, 42, plaintext);
    defer allocator.free(encrypted);

    // Verify output
    if (page_encryption.shouldEncrypt()) {
        // When TDE is enabled, output includes nonce + tag overhead
        try testing.expectEqual(page_size + page_encryption.Overhead, encrypted.len);
    } else {
        // When TDE is disabled, output is same size as input
        try testing.expectEqual(page_size, encrypted.len);
        // Content should be identical (memcpy)
        try testing.expectEqualSlices(u8, plaintext, encrypted);
    }
}

test "TDE overhead benchmark page sizes" {
    // Test various page sizes to ensure overhead calculation is correct
    const allocator = testing.allocator;
    const page_sizes = [_]usize{ 512, 1024, 4096, 8192, 16384 };

    for (page_sizes) |size| {
        const plaintext = try allocator.alloc(u8, size);
        defer allocator.free(plaintext);
        randomFill(plaintext);

        const encrypted = try page_encryption.encryptForWrite(allocator, 0, plaintext);
        defer allocator.free(encrypted);

        if (page_encryption.shouldEncrypt()) {
            try testing.expectEqual(size + page_encryption.Overhead, encrypted.len);
        } else {
            try testing.expectEqual(size, encrypted.len);
        }
    }
}
