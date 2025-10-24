const std = @import("std");
const risk = @import("security/mfa_risk.zig");

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

test "TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary" {
    const policy = risk.StepUpPolicy{ .threshold = 0.55, .hysteresis = 0.05 };
    var enforced = false;
    // Sequence of scores around threshold to test hysteresis behavior
    const scores = [_]f32{ 0.40, 0.54, 0.55, 0.56, 0.53, 0.49, 0.52, 0.50 };
    const expected = [_]bool{ false, false, true, true, true, true, true, true };
    for (scores, 0..) |s, i| {
        const req = policy.requiresStepUp(s, enforced);
        try std.testing.expect(req == expected[i]);
        enforced = req;
    }
}
