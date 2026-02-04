const std = @import("std");
const impl_flagger = @import("server/flagger_impl_defined.zig");
const proto_util = @import("server/proto_util.zig");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedFlagsProtocolIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedFlagsProtocolIntegration; OWNER=wire; UPDATED=2025-09-21

// This test ensures that protocol schema frames include implementation-defined findings
// currently surfaced via flagger_impl_defined (e.g., ZeroLengthPathExcluded).
// We invoke computeBaseFlags indirectly by simulating a minimal query state.

fn hasFlag(list: std.ArrayList([]const u8), needle: []const u8) bool {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
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
    const status = try proto_util.buildStatus(allocator, "00000", codes);
    defer status.deinit(allocator);
    try std.testing.expect(hasFlag(status.flagger_findings, "ZeroLengthPathExcluded"));
    try std.testing.expect(hasFlag(status.flagger_findings, "CollationBinaryDefault"));
    try std.testing.expect(hasFlag(status.flagger_findings, "NullOrderPolicyDefault"));
}
