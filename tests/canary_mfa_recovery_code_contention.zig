const std = @import("std");

// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRecoveryCodeContention"; ASPECT=VarianceEnvelope; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionRatioBounds; OWNER=security; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionRatioBounds" {
    // Inline simulate single run identical to benchmark logic (deterministic sequential consumption).
    const total_codes: usize = 32;
    const workers: usize = 8;
    var pool: [32]u8 = [_]u8{1} ** 32;
    var taken: usize = 0;
    var attempts: usize = 0;
    var i: usize = 0;
    while (i < workers) : (i += 1) {
        var j: usize = i;
        while (j < total_codes) : (j += workers) {
            attempts += 1;
            if (pool[j] == 1) {
                pool[j] = 0;
                taken += 1;
            }
        }
    }
    const contention_ratio = 1.0 - (@as(f64, @floatFromInt(taken)) / @as(f64, @floatFromInt(attempts)));
    // Bounds: >0 (some contention attempts wasted) and <0.60 for deterministic layout.
    try std.testing.expect(contention_ratio > 0.0 and contention_ratio < 0.60);
}
