const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_PatternMatch
// Validates pattern matching: anchors, wildcards, and failure.

test "TestCANARY_REQ_GQL_032_PatternMatch" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const prop_constraint = constraints_mod.SchemaConstraints.PropertyConstraint{
        .name = "p",
        .type = .string,
        .nullable = false,
        .default_value = null,
        .min_value = null,
        .max_value = null,
        .pattern = "^ab*cd$",
    };

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Thing",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{prop_constraint},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Thing", node_constraints);

    // Match case
    var props1 = std.StringHashMap(protocol.Value).init(allocator);
    defer props1.deinit();
    try props1.put("p", protocol.Value{ .string = "abbbcd" });
    try std.testing.expect((try sc.validateNode(1, "Thing", props1)) == null);

    // Fail case
    var props2 = std.StringHashMap(protocol.Value).init(allocator);
    defer props2.deinit();
    try props2.put("p", protocol.Value{ .string = "xabcd" });
    const err2 = try sc.validateNode(2, "Thing", props2);
    try std.testing.expect(err2 != null);
}
