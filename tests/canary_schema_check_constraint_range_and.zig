const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_CheckConstraintRangeAnd
// Validates extended operators (<, <=, >, >=, !=, =) and logical AND chaining.

test "TestCANARY_REQ_GQL_032_CheckConstraintRangeAnd" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const check = constraints_mod.SchemaConstraints.CheckConstraint{
        .name = "r1",
        .expression = "a>1&&a<10&&b=ok&&c!=bad",
        .error_message = "range/and failed",
    };

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Thing",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{check},
    };

    try sc.addNodeConstraint("Thing", node_constraints);

    // Build properties map
    var props = std.StringHashMap(protocol.Value).init(allocator);
    defer props.deinit();
    try props.put("a", protocol.Value{ .integer = 5 });
    try props.put("b", protocol.Value{ .string = "ok" });
    try props.put("c", protocol.Value{ .string = "good" });

    const err = try sc.validateNode(1, "Thing", props);
    try std.testing.expect(err == null);

    // Violation case (a not < 10)
    var props2 = std.StringHashMap(protocol.Value).init(allocator);
    defer props2.deinit();
    try props2.put("a", protocol.Value{ .integer = 15 });
    try props2.put("b", protocol.Value{ .string = "ok" });
    try props2.put("c", protocol.Value{ .string = "good" });
    const err2 = try sc.validateNode(2, "Thing", props2);
    try std.testing.expect(err2 != null);
}
