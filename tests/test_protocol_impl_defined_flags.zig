const std = @import("std");
const protocol = @import("protocol");
const impl_flagger = @import("server/flagger_impl_defined.zig");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedFlagsProtocolIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedFlagsProtocolIntegration; OWNER=wire; UPDATED=2025-09-21

// This test ensures that protocol schema frames include implementation-defined findings
// currently surfaced via flagger_impl_defined (e.g., ZeroLengthPathExcluded).
// We invoke computeBaseFlags indirectly by simulating a minimal query state.

fn hasSubstring(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "TestCANARY_REQ_GQL_024_ImplDefinedFlagsProtocolIntegration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect impl-defined findings directly and ensure codes appear when passed to schema builder.
    const findings = try impl_flagger.collect(allocator, .{ .zero_length_paths_excluded = true });
    defer allocator.free(findings);
    // Build slice of codes
    var codes = try allocator.alloc([]const u8, findings.len);
    defer allocator.free(codes);
    var i: usize = 0;
    while (i < findings.len) : (i += 1) codes[i] = findings[i].code;
    const line = try protocol.buildSchemaLine(allocator, &.{}, &.{}, codes);
    defer allocator.free(line);
    try std.testing.expect(hasSubstring(line, "ZeroLengthPathExcluded"));
    try std.testing.expect(hasSubstring(line, "CollationBinaryDefault"));
    try std.testing.expect(hasSubstring(line, "NullOrderPolicyDefault"));
}
