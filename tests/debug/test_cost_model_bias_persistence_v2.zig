const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistenceV2; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistenceV2; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistenceV2" {
    var reg = seed.AdaptiveBiasRegistry{};
    // Simulate adaptive updates to populate dynamic alpha and CV arrays
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        reg.updateAdaptive(.Scan, 1000, if (i % 3 == 0) 1200 else 900);
        reg.updateAdaptive(.Expand, 800, if (i % 7 == 0) 300 else 1600);
        reg.updateAdaptive(.Filter, 600, if (i % 5 == 0) 610 else 590);
    }
    const original_biases = reg.biases;
    const original_alpha = reg.dyn_alpha;
    const original_cv = reg.last_cv;
    const original_cv_class = reg.last_cv_class;

    // Serialize using v2 (current implementation emits version 2)
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&buf);
    try reg.serialize(fbs.writer());
    const written = fbs.pos;
    try std.testing.expect(written > 32);

    // Deserialize into a fresh registry
    var reg2 = seed.AdaptiveBiasRegistry{};
    fbs.seekTo(0) catch unreachable;
    try reg2.deserialize(fbs.reader());

    // Validate arrays restored
    inline for (@typeInfo(seed.LogicalOpKind).Enum.fields, 0..) |_, idx| {
        try std.testing.expect(std.math.fabs(original_biases[idx] - reg2.biases[idx]) < 1e-9);
        try std.testing.expect(std.math.fabs(original_alpha[idx] - reg2.dyn_alpha[idx]) < 1e-12);
        try std.testing.expect(std.math.fabs(original_cv[idx] - reg2.last_cv[idx]) < 1e-12);
        try std.testing.expect(original_cv_class[idx] == reg2.last_cv_class[idx]);
    }

    // Backward compatibility: craft a minimal v1 blob (biases only) then deserialize
    var v1buf: [512]u8 = undefined;
    var wstream = std.Io.fixedBufferStream(&v1buf);
    {
        const w = wstream.writer();
        try w.writeAll("ABIA");
        try w.writeInt(u16, 1, .little); // version 1
        const count: u16 = @intCast(reg.biases.len);
        try w.writeInt(u16, count, .little);
        // Use reg2 biases for deterministic input
        for (reg2.biases) |b| try w.writeInt(f64, b, .little);
    }
    wstream.seekTo(0) catch unreachable;
    var reg3 = seed.AdaptiveBiasRegistry{};
    try reg3.deserialize(wstream.reader());
    // Expect biases copied; dynamic fields remain defaults
    inline for (@typeInfo(seed.LogicalOpKind).Enum.fields, 0..) |_, idx| {
        try std.testing.expect(std.math.fabs(reg2.biases[idx] - reg3.biases[idx]) < 1e-9);
    }
}
