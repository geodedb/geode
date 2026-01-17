// Test suite for timing attack resistance
// CANARY: REQ=REQ-SECURITY-TIMING-001; FEATURE="TimingAttackResistance"; ASPECT=Core; STATUS=IMPL; OWNER=security; UPDATED=2026-01-17
//         ASPECT=TESTING; STATUS=IMPL; OWNER=security; UPDATED=2025-10-16

const std = @import("std");
const testing = std.testing;
const auth = @import("geode_auth");
const hash_mod = @import("../types/hash.zig");

test "Password verification - timing resistance with varying prefixes" {
    var security_mgr = try auth.SecurityManager.init(testing.allocator);
    defer security_mgr.deinit();

    const correct = "CorrectPassword123!";
    const password_hash = try security_mgr.hashPassword(correct);
    defer testing.allocator.free(password_hash);

    // Test passwords with varying levels of prefix match
    const test_cases = [_][]const u8{
        "WrongPassword123!", // No match at all
        "CorrectPassword456!", // Matches most of the prefix
        "CorrectPassword12!", // Almost full match (one char different)
        "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZPassword!", // Different prefix
    };

    // Measure timing for each wrong password (100 attempts each)
    var timings: [test_cases.len]i64 = undefined;

    for (test_cases, 0..) |wrong_password, i| {
        var total_ns: i64 = 0;
        var attempt: usize = 0;

        while (attempt < 100) : (attempt += 1) {
            const start = std.time.nanoTimestamp();
            _ = security_mgr.verifyPassword(wrong_password, password_hash) catch false;
            const end = std.time.nanoTimestamp();
            total_ns += (end - start);
        }

        timings[i] = @divTrunc(total_ns, 100);
    }

    // Calculate variance
    const min_time = std.mem.min(i64, &timings);
    const max_time = std.mem.max(i64, &timings);

    // With constant-time comparison, variance should be minimal (<10%)
    // Non-constant-time would show 50%+ variance based on prefix matches
    const variance = @as(f64, @floatFromInt(max_time - min_time)) / @as(f64, @floatFromInt(min_time));

    std.debug.print("\nTiming variance: {d:.2}% (target: <10%)\n", .{variance * 100.0});
    std.debug.print("Min time: {}ns, Max time: {}ns\n", .{ min_time, max_time });

    // Timing should be constant regardless of where comparison fails
    try testing.expect(variance < 0.15); // Allow 15% variance for test stability
}

test "Hash comparison - timing resistance" {
    const hash1 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xAA} ** 32,
    };

    const test_hashes = [_]hash_mod.Hash{
        .{ .alg = .SHA256, .digest = &[_]u8{0xBB} ** 32 }, // No match
        .{
            .alg = .SHA256,
            .digest = &([_]u8{0xAA} ** 16 ++ [_]u8{0xBB} ** 16),
        }, // Half match
        .{
            .alg = .SHA256,
            .digest = &([_]u8{0xAA} ** 31 ++ [_]u8{0xBB}),
        }, // Almost full match
    };

    var timings: [test_hashes.len]i64 = undefined;

    for (test_hashes, 0..) |hash2, i| {
        var total_ns: i64 = 0;
        var attempt: usize = 0;

        while (attempt < 1000) : (attempt += 1) {
            const start = std.time.nanoTimestamp();
            _ = hash1.equals(hash2);
            const end = std.time.nanoTimestamp();
            total_ns += (end - start);
        }

        timings[i] = @divTrunc(total_ns, 1000);
    }

    // Verify constant-time (within measurement noise)
    const min_time = std.mem.min(i64, &timings);
    const max_time = std.mem.max(i64, &timings);
    const variance = @as(f64, @floatFromInt(max_time - min_time)) / @as(f64, @floatFromInt(min_time));

    std.debug.print("\nHash comparison variance: {d:.2}% (target: <5%)\n", .{variance * 100.0});

    // Hash comparison should be constant-time
    try testing.expect(variance < 0.10); // Allow 10% variance
}

test "Password verification - correct password still works" {
    var security_mgr = try auth.SecurityManager.init(testing.allocator);
    defer security_mgr.deinit();

    const password = "MySecurePassword123!";
    const password_hash = try security_mgr.hashPassword(password);
    defer testing.allocator.free(password_hash);

    // Correct password should verify successfully
    const is_valid = try security_mgr.verifyPassword(password, password_hash);
    try testing.expect(is_valid);

    // Wrong password should fail
    const is_invalid = try security_mgr.verifyPassword("WrongPassword!", password_hash);
    try testing.expect(!is_invalid);
}

test "Hash equals - same hash returns true" {
    const hash1 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xAA} ** 32,
    };

    const hash2 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xAA} ** 32,
    };

    try testing.expect(hash1.equals(hash2));
}

test "Hash equals - different hash returns false" {
    const hash1 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xAA} ** 32,
    };

    const hash2 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xBB} ** 32,
    };

    try testing.expect(!hash1.equals(hash2));
}

test "Hash equals - different algorithm returns false" {
    const hash1 = hash_mod.Hash{
        .alg = .SHA256,
        .digest = &[_]u8{0xAA} ** 32,
    };

    const hash2 = hash_mod.Hash{
        .alg = .SHA512,
        .digest = &[_]u8{0xAA} ** 32,
    };

    try testing.expect(!hash1.equals(hash2));
}
