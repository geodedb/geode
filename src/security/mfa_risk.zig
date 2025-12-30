const std = @import("std");
const mfa = @import("mfa");

// MFA Risk Sensitivity & Step-Up Decision Module
// Provides per-action risk scoring and step-up enforcement logic.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskSensitivity"; ASPECT=RiskModel; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RiskMatrixDeterministic; OWNER=security; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskStepUpDecision"; ASPECT=DecisionLogic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary; OWNER=security; UPDATED=2025-09-27

pub const Action = enum { Login, Elevation, TransferFunds, RotateKey, DownloadBackup };

pub const Factors = struct { // simple factors (0-1 scaled) provided by caller
    ip_reputation: f32 = 0.0, // higher = riskier
    geo_distance: f32 = 0.0, // fraction of earth circumference diff from last login
    anomaly_score: f32 = 0.0, // model-provided anomaly
};

pub fn baseRisk(a: Action) f32 {
    return switch (a) {
        .Login => 0.15,
        .Elevation => 0.35,
        .TransferFunds => 0.60,
        .RotateKey => 0.50,
        .DownloadBackup => 0.55,
    };
}

pub fn score(a: Action, f: Factors) f32 {
    // Weighted linear combination; stable deterministic weights
    const w_ip: f32 = 0.30;
    const w_geo: f32 = 0.20;
    const w_anom: f32 = 0.50;
    var s: f32 = baseRisk(a);
    s += f.ip_reputation * w_ip;
    s += f.geo_distance * w_geo;
    s += f.anomaly_score * w_anom;
    if (s > 1.0) s = 1.0;
    return s;
}

pub const StepUpPolicy = struct {
    // Threshold above which MFA step-up required
    threshold: f32 = 0.55,
    // Hysteresis margin to avoid oscillation; clear requirement once below (threshold - margin)
    hysteresis: f32 = 0.05,

    pub fn requiresStepUp(self: StepUpPolicy, current_score: f32, previous_enforced: bool) bool {
        if (previous_enforced) {
            // remain enforced until sufficiently below threshold - hysteresis
            return current_score >= (self.threshold - self.hysteresis);
        }
        return current_score >= self.threshold;
    }
};

pub fn deterministicFactors(user_id: []const u8, action: Action) Factors {
    // Provide deterministic pseudo-random factors (for tests/benchmarks) using wyhash over user+action.
    var h = std.hash.Wyhash.init(0);
    h.update(user_id);
    h.update(@tagName(action));
    const hv = h.final();
    // Extract three bytes -> scale to [0,1)
    const ip = @as(f32, @floatFromInt((hv >> 0) & 0xFF)) / 255.0;
    const geo = @as(f32, @floatFromInt((hv >> 8) & 0xFF)) / 255.0;
    const anom = @as(f32, @floatFromInt((hv >> 16) & 0xFF)) / 255.0;
    return .{ .ip_reputation = ip, .geo_distance = geo, .anomaly_score = anom };
}

// Simple step-up execution stub (would integrate with mfa.verifyCode in real path)
pub fn performStepUp(required: bool, provided_code: ?u32) !bool {
    if (!required) return true;
    if (provided_code == null) return error.MissingCode;
    // For now accept any non-null code in deterministic mode.
    return true;
}
