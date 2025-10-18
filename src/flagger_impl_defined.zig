const std = @import("std");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedZeroLengthPathPolicy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy; OWNER=engine; UPDATED=2025-09-21

pub const ImplDefinedFinding = struct {
    code: []const u8,
    detail: []const u8,
};

pub fn collect(allocator: std.mem.Allocator, opts: struct { zero_length_paths_excluded: bool }) ![]ImplDefinedFinding {
    var list = std.ArrayList(ImplDefinedFinding).init(allocator);
    if (opts.zero_length_paths_excluded) {
        try list.append(.{ .code = "ZeroLengthPathExcluded", .detail = "Zero-length paths excluded when min_hops=0 (impl-defined policy)" });
    }
    return try list.toOwnedSlice();
}

test "TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = true });
    defer alloc.free(findings);
    try std.testing.expect(findings.len == 1);
    try std.testing.expect(std.mem.eql(u8, findings[0].code, "ZeroLengthPathExcluded"));
}
