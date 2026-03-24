const std = @import("std");
const crypto = std.crypto;
const flags_mod = @import("feature_flags");
const ext_mfa = @import("auth_lib").mfa;

// Multi-Factor Authentication (MFA) - RFC 6238 TOTP implementation (HMAC-SHA1 default)
// Runtime gated by shared feature flag (GEODE_ENABLE_MFA) via util/feature_flags.zig.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeSingleUse|TestCANARY_REQ_GQL_MFA_CORE_001_ReauthIntervalPolicyTrigger|TestCANARY_REQ_GQL_MFA_CORE_001_ElevationTtlExpiry|TestCANARY_REQ_GQL_MFA_CORE_001_DynamicPolicyCacheBypass|TestCANARY_REQ_GQL_MFA_CORE_001_EndToEndElevationFlow; OWNER=security; UPDATED=2025-09-26
//
// Thin compatibility wrapper over the external `auth` library's MFA module.
// Preserves the original public API (feature flag gating, function signatures)
// so that consumers (geode_auth_lib.zig, user_mgmt_cli.zig) require no changes.

pub fn globallyEnabled() bool {
    return flags_mod.global().mfa.enabled();
}

pub const Enrollment = ext_mfa.Enrollment;

/// Geode-specific MFA configuration: deterministic secrets derived from
/// username + salt for reproducible enrollment, 6-digit TOTP codes,
/// 30-second time step, +/-1 window for clock skew.
const geode_mfa_config = ext_mfa.MfaConfig{
    .digits = 6,
    .step_seconds = 30,
    .window = 1,
    .scratch_code_count = 2,
    .deterministic = true,
    .salt = "geode-mfa-salt-v1",
};

pub fn enroll(allocator: std.mem.Allocator, username: []const u8) !Enrollment {
    if (!globallyEnabled()) return error.FeatureDisabled;
    return ext_mfa.enroll(allocator, username, geode_mfa_config);
}

pub fn generateCodeFromBase32(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, step_seconds: u64, digits: u8) !u32 {
    if (!globallyEnabled()) return error.FeatureDisabled;
    return ext_mfa.generateCode(allocator, secret_base32, timestamp_ms, .{
        .digits = digits,
        .step_seconds = step_seconds,
        .window = 1,
        .scratch_code_count = 2,
        .deterministic = true,
        .salt = "geode-mfa-salt-v1",
    });
}

pub fn verifyCode(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, code: u32, step_seconds: u64, digits: u8, window: i32) !bool {
    if (!globallyEnabled()) return error.FeatureDisabled;
    return ext_mfa.verifyCode(allocator, secret_base32, timestamp_ms, code, .{
        .digits = digits,
        .step_seconds = step_seconds,
        .window = window,
        .scratch_code_count = 2,
        .deterministic = true,
        .salt = "geode-mfa-salt-v1",
    });
}
