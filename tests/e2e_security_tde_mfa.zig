// End-to-end tests for the runtime-gated TDE (src/security/tde.zig) and MFA
// (src/security/mfa.zig) entry points: disabled, each refuses with
// error.FeatureDisabled; enabled, TDE encrypts and decrypts AES-256-GCM
// (and detects tampering) and MFA verifies RFC 6238 TOTP codes.
//
// SONNY-6378: this file was compiled by test-e2e but no step ran it, while
// REQ-GQL-TDE-001 cited it. It now runs as `zig build test-e2e-security-tde-mfa`
// (in the aggregate). The flags are set through the feature-flag test
// overrides, so the result does not depend on GEODE_ENABLE_TDE /
// GEODE_ENABLE_MFA in the caller's environment.
const std = @import("std");
const geode = @import("geode");
const tde = geode.tde_stub;
const mfa = geode.mfa_test_support;
// Imported under a non-`feature_*` name for the no-feature-flags governance
// check (see tests/test_gap0843_tenant_tde.zig).
const runtime_flags = geode.util_feature_flags;

const testing = std.testing;

// The key manager reads GEODE_TDE_KEY via std.c.getenv; std.posix.setenv was
// removed in Zig 0.16, so it is installed through libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const test_master_key_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; // gitleaks:allow

test "TDE disabled returns FeatureDisabled" {
    runtime_flags.global().tde.disableForTests();
    defer runtime_flags.global().tde.clearTestOverride();
    try testing.expectError(error.FeatureDisabled, tde.encrypt(testing.allocator, "abc", ""));
}

test "TDE enabled encrypts and decrypts AES-256-GCM and detects tampering" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", test_master_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.clearTestOverride();
    }
    const allocator = testing.allocator;
    const plaintext = "the quick brown fox";
    const aad = "page:42";

    const ct = try tde.encrypt(allocator, plaintext, aad);
    defer allocator.free(ct.data);
    try testing.expectEqual(plaintext.len, ct.data.len);
    try testing.expect(!std.mem.eql(u8, plaintext, ct.data));

    const back = try tde.decrypt(allocator, ct, aad);
    defer allocator.free(back);
    try testing.expectEqualStrings(plaintext, back);

    // Wrong AAD and a flipped ciphertext bit both fail authentication.
    try testing.expectError(error.AuthFailed, tde.decrypt(allocator, ct, "page:43"));
    ct.data[0] ^= 1;
    try testing.expectError(error.AuthFailed, tde.decrypt(allocator, ct, aad));
}

test "MFA disabled verify returns FeatureDisabled" {
    runtime_flags.global().mfa.disableForTests();
    defer runtime_flags.global().mfa.clearTestOverride();
    const res = mfa.verifyCode(testing.allocator, "ABCDEFGH", 0, 123456, 30, 6, 1);
    try testing.expectError(error.FeatureDisabled, res);
}

test "MFA enabled verifies the RFC 6238 SHA-1 test vector and refuses a wrong code" {
    runtime_flags.global().mfa.enableForTests();
    defer runtime_flags.global().mfa.clearTestOverride();
    const allocator = testing.allocator;
    // RFC 6238 appendix B: secret "12345678901234567890", T = 59 s, SHA-1,
    // 8-digit code 94287082 (6-digit: 287082).
    const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // gitleaks:allow
    try testing.expectEqual(@as(u32, 287082), try mfa.generateCodeFromBase32(allocator, secret, 59_000, 30, 6));
    try testing.expect(try mfa.verifyCode(allocator, secret, 59_000, 287082, 30, 6, 0));
    try testing.expect(!try mfa.verifyCode(allocator, secret, 59_000, 287083, 30, 6, 0));
    // One step later the code has changed and a zero window refuses the old one.
    try testing.expect(!try mfa.verifyCode(allocator, secret, 89_000, 287082, 30, 6, 0));
}
