const std = @import("std");
const testing = std.testing;
const mfa = @import("src/security/mfa.zig");

test "MFA: enrollment deterministic secret length" {
    mfa.enableForTests();
    defer mfa.disableForTests();
    const allocator = testing.allocator;
    const enroll = try mfa.enroll(allocator, "alice");
    defer allocator.free(enroll.secret_base32);
    for (enroll.scratch_codes) |sc| allocator.free(sc);
    allocator.free(enroll.scratch_codes);
    try testing.expect(enroll.secret_base32.len % 8 == 0);
    try testing.expect(enroll.secret_base32.len >= 32); // 20 raw bytes -> 32 base32 chars
}

test "MFA: generate and verify current code" {
    mfa.enableForTests();
    defer mfa.disableForTests();
    const allocator = testing.allocator;
    const enroll = try mfa.enroll(allocator, "bob");
    defer allocator.free(enroll.secret_base32);
    for (enroll.scratch_codes) |sc| allocator.free(sc);
    allocator.free(enroll.scratch_codes);
    const now_ms: u64 = 1_000_000; // deterministic timestamp
    const code = try mfa.generateCodeFromBase32(allocator, enroll.secret_base32, now_ms, 30, 6);
    const ok = try mfa.verifyCode(allocator, enroll.secret_base32, now_ms, code, 30, 6, 1);
    try testing.expect(ok);
}

test "MFA: window tolerance +/- one step" {
    mfa.enableForTests();
    defer mfa.disableForTests();
    const allocator = testing.allocator;
    const enroll = try mfa.enroll(allocator, "carol");
    defer allocator.free(enroll.secret_base32);
    for (enroll.scratch_codes) |sc| allocator.free(sc);
    allocator.free(enroll.scratch_codes);
    const base_ms: u64 = 2_000_000;
    const code = try mfa.generateCodeFromBase32(allocator, enroll.secret_base32, base_ms, 30, 6);
    // Shift +30s
    const ok_future = try mfa.verifyCode(allocator, enroll.secret_base32, base_ms + 30 * 1000, code, 30, 6, 1);
    const ok_past = try mfa.verifyCode(allocator, enroll.secret_base32, base_ms - 30 * 1000, code, 30, 6, 1);
    try testing.expect(ok_future or ok_past);
}

test "MFA: disabled feature returns FeatureDisabled" {
    mfa.disableForTests();
    const allocator = testing.allocator;
    const enroll_res = mfa.enroll(allocator, "dave");
    try testing.expectError(error.FeatureDisabled, enroll_res);
}
