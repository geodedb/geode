const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_PatternRegex
// Validates extended regex subset: ., ?, character classes, ranges, anchors, *.

test "TestCANARY_REQ_GQL_032_PatternRegex" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(ally);
    defer sc.deinit();

    const prop_constraint = constraints_mod.SchemaConstraints.PropertyConstraint{
        .name = "p",
        .type = .string,
        .nullable = false,
        .default_value = null,
        .min_value = null,
        .max_value = null,
        .pattern = "^a.?b[c-e]d*$",
    };

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Thing2",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{prop_constraint},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Thing2", node_constraints);

    const matches = [_][]const u8{ "axbcd", "aZbdd", "a_bce", "abdd" };
    inline for (matches) |m| {
        var props = std.StringHashMap(protocol.Value).init(ally);
        defer props.deinit();
        try props.put("p", protocol.Value{ .string = m });
        try std.testing.expect((try sc.validateNode(1, "Thing2", props)) == null);
    }

    const fails = [_][]const u8{ "aXYbxd", "abf", "aab", "acbdxq" };
    inline for (fails) |f| {
        var props2 = std.StringHashMap(protocol.Value).init(ally);
        defer props2.deinit();
        try props2.put("p", protocol.Value{ .string = f });
        const err = try sc.validateNode(2, "Thing2", props2);
        try std.testing.expect(err != null);
    }
}
