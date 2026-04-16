const std = @import("std");
const implf = @import("../src/flagger_impl_defined.zig");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedZeroLengthPathPolicyOutput; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicyOutput; OWNER=engine; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicyOutput" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const f = try implf.collect(alloc, .{ .zero_length_paths_excluded = true });
    defer alloc.free(f);
    try std.testing.expect(f.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, f[0].detail, "Zero-length paths excluded") != null);
}
