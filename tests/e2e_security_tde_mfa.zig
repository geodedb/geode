const std = @import("std");
const tde = @import("geode").tde_stub;
const mfa = @import("geode").mfa_test_support;

// Basic end-to-end style tests for TDE + MFA stubs (non-cryptographic).
// Ensures feature flags gate functionality.
// Expected: when env vars absent, functions return FeatureDisabled or false.

pub fn main() !void {}

test "TDE disabled returns FeatureDisabled" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    try std.testing.expectError(error.FeatureDisabled, tde.encrypt(gpa.allocator(), "abc", ""));
}

test "MFA disabled verify returns FeatureDisabled" {
    const allocator = std.testing.allocator;
    // Attempt to verify should error due to disabled feature
    const res = mfa.verifyCode(allocator, "ABCDEFGH", 0, 123456, 30, 6, 1);
    try std.testing.expectError(error.FeatureDisabled, res);
}

// Zig 0.15 environment mutation portability differences: skip enabled-path enrollment test for now.
