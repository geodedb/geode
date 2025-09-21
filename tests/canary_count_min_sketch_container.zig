const std = @import("std");
const cms_mod = @import("../src/graph/containers/count_min_sketch.zig");

test "TestCANARY_REQ_GQL_069_CountMinSketch_AccuracyEnvelope" {
    var cms = try cms_mod.CountMinSketch.init(std.testing.allocator, 6, 2048, 42);
    defer cms.deinit();
    // Insert skewed distribution
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        cms.add("hot", 1);
        if (i % 5 == 0) cms.add("warm", 1);
        if (i % 25 == 0) cms.add("cold", 1);
    }
    const hot = cms.estimate("hot");
    const warm = cms.estimate("warm");
    const cold = cms.estimate("cold");
    // Expected true counts: hot=10000, warm=2000, cold=400
    try std.testing.expect(hot >= 10000 and hot < 10500);
    try std.testing.expect(warm >= 2000 and warm < 2300);
    try std.testing.expect(cold >= 400 and cold < 600);
}
