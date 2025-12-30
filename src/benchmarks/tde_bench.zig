const std = @import("std");
const tde = @import("../security/tde.zig");

pub fn benchmarkEncryption(allocator: std.mem.Allocator) !struct {
    throughput_mbps: f64,
    avg_latency_us: f64,
    operations_tested: u32,
    encryption_mode: []const u8,
} {
    // Enable TDE for testing
    tde.enableForTests();
    defer tde.disableForTests();

    const iterations: u32 = 1000;
    var total_bytes: u64 = 0;
    var total_time_us: u64 = 0;

    // Test with different data sizes
    const sizes = [_]usize{ 64, 256, 1024, 4096, 16384, 65536 };

    for (sizes) |size| {
        const test_data = try allocator.alloc(u8, size);
        defer allocator.free(test_data);

        // Fill with random data
        std.crypto.random.bytes(test_data);

        const start = std.time.microTimestamp();

        // Perform encryption operations
        var i: u32 = 0;
        while (i < iterations / sizes.len) : (i += 1) {
            const ciphertext = try tde.encrypt(allocator, test_data, "benchmark");
            defer allocator.free(ciphertext.data);

            const plaintext = try tde.decrypt(allocator, ciphertext, "benchmark");
            allocator.free(plaintext);

            total_bytes += size * 2; // Count both encrypt and decrypt
        }

        total_time_us += @intCast(std.time.microTimestamp() - start);
    }

    const throughput_mbps = @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time_us));
    const avg_latency_us = @as(f64, @floatFromInt(total_time_us)) / @as(f64, @floatFromInt(iterations));

    return .{
        .throughput_mbps = throughput_mbps,
        .avg_latency_us = avg_latency_us,
        .operations_tested = iterations,
        .encryption_mode = try allocator.dupe(u8, "AES-256-GCM"),
    };
}

pub fn simulateOLTPWorkload(allocator: std.mem.Allocator, duration_seconds: u32, concurrent_transactions: u32) !struct {
    avg_transaction_time_ms: f64,
    tps_with_encryption: i64,
    tps_without_encryption: i64,
    degradation_percentage: f64,
} {
    // Enable TDE for this test (uses REAL encrypt/decrypt functions)
    tde.enableForTests();
    defer tde.disableForTests();

    _ = concurrent_transactions;

    const test_data = try allocator.alloc(u8, 256);
    defer allocator.free(test_data);
    std.crypto.random.bytes(test_data);

    const iterations = duration_seconds * 10; // Simulate transactions

    // Without encryption
    const unencrypted_start = std.time.milliTimestamp();
    for (0..iterations) |_| {
        const copy = try allocator.alloc(u8, test_data.len);
        @memcpy(copy, test_data);
        allocator.free(copy);
    }
    const unencrypted_time = std.time.milliTimestamp() - unencrypted_start;

    // With encryption
    const encrypted_start = std.time.milliTimestamp();
    for (0..iterations) |_| {
        const enc = try tde.encrypt(allocator, test_data, "oltp_test");
        const dec = try tde.decrypt(allocator, enc, "oltp_test");
        allocator.free(enc.data);
        allocator.free(dec);
    }
    const encrypted_time = std.time.milliTimestamp() - encrypted_start;

    const tps_unencrypted = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(unencrypted_time))) * 1000.0;
    const tps_encrypted = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(encrypted_time))) * 1000.0;
    const avg_time = @as(f64, @floatFromInt(encrypted_time)) / @as(f64, @floatFromInt(iterations));
    const degradation = ((tps_unencrypted - tps_encrypted) / tps_unencrypted) * 100.0;

    return .{
        .avg_transaction_time_ms = avg_time,
        .tps_with_encryption = @intFromFloat(tps_encrypted),
        .tps_without_encryption = @intFromFloat(tps_unencrypted),
        .degradation_percentage = degradation,
    };
}
