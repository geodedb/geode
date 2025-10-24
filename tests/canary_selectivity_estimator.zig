const std = @import("std");
const estimator_mod = @import("optimizer/selectivity_estimator.zig");

// TestCANARY_REQ_GQL_084_FrequencySampler
test "TestCANARY_REQ_GQL_084_FrequencySampler" {
    const allocator = std.testing.allocator;
    var fs = estimator_mod.FrequencySampler.init(allocator, 16);
    defer fs.deinit();
    try fs.record("alpha");
    try fs.record("alpha");
    try fs.record("beta");
    const est_alpha = fs.estimate("alpha");
    const est_beta = fs.estimate("beta");
    try std.testing.expect(est_alpha > est_beta);
    try std.testing.expect(est_alpha > 0.4 and est_alpha < 0.9);
}

// TestCANARY_REQ_GQL_084_EstimatorApi
test "TestCANARY_REQ_GQL_084_EstimatorApi" {
    const allocator = std.testing.allocator;
    var ae = estimator_mod.AdaptiveEstimator.init(allocator, 32);
    defer ae.deinit();
    var api = estimator_mod.Api{ .estimator = &ae };
    // Observe distribution: 5x gamma, 1x delta
    var i: usize = 0;
    while (i < 5) : (i += 1) try ae.observe("gamma");
    try ae.observe("delta");
    const before = api.get("gamma");
    try std.testing.expect(before > 0.3);
    try std.testing.expect(api.get("delta") < before);
}

// TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook
test "TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook" {
    const allocator = std.testing.allocator;
    var ae = estimator_mod.AdaptiveEstimator.init(allocator, 64);
    defer ae.deinit();
    var api = estimator_mod.Api{ .estimator = &ae };
    // Build skewed observations for key "zeta"
    var i: usize = 0;
    while (i < 20) : (i += 1) try ae.observe("zeta");
    while (i < 40) : (i += 1) try ae.observe("omega");
    const pred = api.get("zeta");
    // Provide feedback indicating actual selectivity lower than predicted (e.g., predicate more selective than sample suggested)
    api.feedback("zeta", pred * 0.25);
    const pred2 = api.get("zeta");
    // Expect correction applied reducing prediction
    try std.testing.expect(pred2 < pred);
}

// Additional edge test: unseen value fallback and feedback overshoot stability
test "TestCANARY_REQ_GQL_084_UnseenAndOvershoot" {
    const allocator = std.testing.allocator;
    var ae = estimator_mod.AdaptiveEstimator.init(allocator, 8);
    defer ae.deinit();
    // Observe a skewed distribution for key X
    var i: usize = 0;
    while (i < 50) : (i += 1) try ae.observe("X");
    // Unseen key Y selectivity should be small but >0
    const unseen = ae.estimate("Y");
    try std.testing.expect(unseen > 0 and unseen < 0.05);
    const pred = ae.estimate("X");
    // Apply feedback that drastically lowers selectivity (simulate strong predicate)
    ae.feedback("X", pred * 0.01);
    const adj = ae.estimate("X");
    try std.testing.expect(adj < pred);
    // Second overshoot shouldn't drive correction negative or zero
    ae.feedback("X", pred * 0.0001);
    const adj2 = ae.estimate("X");
    try std.testing.expect(adj2 > 0 and adj2 <= adj);
}
