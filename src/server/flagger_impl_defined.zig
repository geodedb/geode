const std = @import("std");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedZeroLengthPathPolicy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy; OWNER=engine; UPDATED=2025-09-21

pub const ImplDefinedFinding = struct {
    code: []const u8,
    detail: []const u8,
};

pub fn collect(
    ally: std.mem.Allocator,
    opts: struct {
        zero_length_paths_excluded: bool,
        collation_binary_default: bool = true,
        null_order_policy_default: bool = true,
    },
) ![]ImplDefinedFinding {
    var list = std.ArrayList(ImplDefinedFinding).initCapacity(ally, 3) catch return error.OutOfMemory;
    errdefer list.deinit(ally);
    if (opts.zero_length_paths_excluded) {
        try list.append(ally, .{ .code = "ZeroLengthPathExcluded", .detail = "Zero-length paths excluded when min_hops=0 (impl-defined policy)" });
    }
    if (opts.collation_binary_default) {
        try list.append(ally, .{ .code = "CollationBinaryDefault", .detail = "Binary collation default (Unicode collation optional feature not enabled)" });
    }
    if (opts.null_order_policy_default) {
        try list.append(ally, .{ .code = "NullOrderPolicyDefault", .detail = "NULL ordering defaults to NULLS LAST unless ORDER BY specifies otherwise (impl-defined)" });
    }
    return try list.toOwnedSlice(ally);
}

test "TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = true });
    defer alloc.free(findings);
    // With defaults (collation, null order) we expect 3 findings
    try std.testing.expect(findings.len == 3);
    try std.testing.expect(std.mem.eql(u8, findings[0].code, "ZeroLengthPathExcluded"));
}

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedCollationAndNullOrdering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=engine; UPDATED=2025-09-21
test "TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = false });
    defer alloc.free(findings);
    // Expect exactly 2 (collation + null policy) when zero-length path exclusion disabled
    try std.testing.expect(findings.len == 2);
    var have_coll = false;
    var have_null = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "CollationBinaryDefault")) have_coll = true;
        if (std.mem.eql(u8, f.code, "NullOrderPolicyDefault")) have_null = true;
    }
    try std.testing.expect(have_coll and have_null);
}
