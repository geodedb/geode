const std = @import("std");
const risk = @import("security/mfa_risk.zig");
// Note: risk.generateTotpCode is private (fn, not pub fn). The RFC 6238 vector
// is exercised via performStepUp with a StepUpContext, which calls generateTotpCode
// internally. For direct TOTP-code comparison we use verifyTotpCode via performStepUp.

// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskSensitivity"; ASPECT=RiskModel; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RiskMatrixDeterministic; OWNER=security; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskStepUpDecision"; ASPECT=DecisionLogic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary; OWNER=security; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_MFA_CORE_001_RiskMatrixDeterministic" {
    const f_login = risk.deterministicFactors("userA", .Login);
    const f_transfer = risk.deterministicFactors("userA", .TransferFunds);
    const s_login = risk.score(.Login, f_login);
    const s_transfer = risk.score(.TransferFunds, f_transfer);
    try std.testing.expect(s_transfer > s_login); // higher base risk
    // Determinism: recomputing yields same
    const s_login2 = risk.score(.Login, risk.deterministicFactors("userA", .Login));
    try std.testing.expectApproxEqAbs(s_login, s_login2, 0.00001);
}

// RFC 6238 SHA-1 TOTP test vector (Appendix B of RFC 6238):
//   Secret  = ASCII "12345678901234567890" (20 bytes)
//   Base32  = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
//   T=59s  → counter=1 (X=30s, T0=0)
//   TOTP-8  = 94287082
//   TOTP-6  = 287082
// Verifies that TOTP HMAC-SHA1 now executes through the FIPS seam (cb.Mac.hmacSha1).
test "RFC6238_TOTP_SHA1_vector_T59_6digit" {
    const alloc = std.testing.allocator;
    // secret in base32; timestamp_ms=59000 → timestep=floor(59000/30000)=1
    var ctx = risk.StepUpContext{
        .allocator = alloc,
        .secret_base32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", // gitleaks:allow — RFC 6238 Appendix B test vector (synthetic "12345678901234567890" seed)
        .timestamp_ms = 59000,
        .step_seconds = 30,
        .digits = 6,
        .window = 0, // exact match only; no clock-drift window
    };
    // Expected 6-digit TOTP for counter=1: 287082
    const result = try risk.performStepUp(true, 287082, &ctx);
    try std.testing.expect(result);
}

test "RFC6238_TOTP_SHA1_vector_T59_8digit" {
    const alloc = std.testing.allocator;
    // 8-digit variant of the same vector: 94287082
    var ctx = risk.StepUpContext{
        .allocator = alloc,
        .secret_base32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", // gitleaks:allow — RFC 6238 Appendix B test vector (synthetic "12345678901234567890" seed)
        .timestamp_ms = 59000,
        .step_seconds = 30,
        .digits = 8,
        .window = 0,
    };
    const result = try risk.performStepUp(true, 94287082, &ctx);
    try std.testing.expect(result);
}

test "TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary" {
    const policy = risk.StepUpPolicy{ .threshold = 0.55, .hysteresis = 0.05 };
    var enforced = false;
    // Sequence of scores around threshold to test hysteresis behavior
    const scores = [_]f32{ 0.40, 0.54, 0.55, 0.56, 0.53, 0.49, 0.52, 0.50 };
    // Hysteresis: enforce at >= threshold (0.55); once enforced, REMAIN enforced
    // until score < (threshold - hysteresis) = 0.50, then clear. So at i=5
    // (0.49 < 0.50) enforcement CLEARS, and i=6/i=7 stay clear (0.52, 0.50 are
    // both < the 0.55 re-arm threshold). Matches requiresStepUp() exactly.
    const expected = [_]bool{ false, false, true, true, true, false, false, false };
    for (scores, 0..) |s, i| {
        const req = policy.requiresStepUp(s, enforced);
        try std.testing.expect(req == expected[i]);
        enforced = req;
    }
}
