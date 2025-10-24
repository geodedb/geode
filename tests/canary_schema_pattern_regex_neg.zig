const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_PatternRegexNegClass
// Validates negated character class and normal class interplay.

test "TestCANARY_REQ_GQL_032_PatternRegexNegClass" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const pc = constraints_mod.SchemaConstraints.PropertyConstraint{ .name = "p", .type = .string, .nullable = false, .default_value = null, .min_value = null, .max_value = null, .pattern = "^a[^0-9]z$" };
    const nc = constraints_mod.SchemaConstraints.NodeConstraints{ .label = "Neg", .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{pc}, .unique_properties = &[_][]const u8{}, .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{} };
    try sc.addNodeConstraint("Neg", nc);

    const should_match = [_][]const u8{ "aXz", "a_z", "a z" };
    inline for (should_match) |m| {
        var props = std.StringHashMap(protocol.Value).init(allocator);
        defer props.deinit();
        try props.put("p", protocol.Value{ .string = m });
        try std.testing.expect((try sc.validateNode(1, "Neg", props)) == null);
    }

    const should_fail = [_][]const u8{ "a1z", "a9z", "ab1z", "azzq" };
    inline for (should_fail) |f| {
        var props2 = std.StringHashMap(protocol.Value).init(allocator);
        defer props2.deinit();
        try props2.put("p", protocol.Value{ .string = f });
        const err = try sc.validateNode(2, "Neg", props2);
        try std.testing.expect(err != null);
    }
}
