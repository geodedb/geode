const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_ConstraintEnforce - ensures required property and type violation are detected.

test "TestCANARY_REQ_GQL_032_ConstraintEnforce" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    // Define a node constraint expecting property 'name' as string (non-nullable)
    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{ // CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_032_ConstraintEnforce; BENCH=""; OWNER=engine; UPDATED=2025-09-20
        .label = "Person",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{
            .{ .name = "name", .type = .string, .nullable = false, .default_value = null, .min_value = null, .max_value = null, .pattern = null },
        },
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };

    try sc.addNodeConstraint("Person", node_constraints);

    // Build properties map missing 'name'
    var props = std.StringHashMap(protocol.Value).init(allocator);
    defer props.deinit();

    const err1 = try sc.validateNode(1, "Person", props);
    try std.testing.expect(err1 != null);
    if (err1) |e| {
        try std.testing.expect(e.constraint_type == .required_property);
    }

    // Add wrong-typed 'name' (integer instead of string)
    try props.put("name", .{ .Int = 7 });
    const err2 = try sc.validateNode(2, "Person", props);
    try std.testing.expect(err2 != null);
    if (err2) |e| {
        try std.testing.expect(e.constraint_type == .type_mismatch);
    }

    // Fix type -> expect null error
    props.put("name", .{ .String = "alice" }) catch unreachable;
    const err3 = try sc.validateNode(3, "Person", props);
    try std.testing.expect(err3 == null);
}
