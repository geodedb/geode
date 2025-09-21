const std = @import("std");
const flagger = @import("../src/gpu/flagger.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=GPUFlaggerUnsupported; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUFlaggerUnsupportedStandalone; OWNER=engine; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_051_GPUFlaggerUnsupportedStandalone" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try flagger.detect(alloc);
    defer alloc.free(findings);
    try std.testing.expect(findings.len > 0);
    try std.testing.expect(!flagger.anySupported(findings));
    try std.testing.expect(flagger.status() == .unsupported);
}
