const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_UniqueEnforce - verifies uniqueness constraint enforcement.

test "TestCANARY_REQ_GQL_032_UniqueEnforce" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "User",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{"username"},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("User", node_constraints);

    // First user OK
    var props1 = std.StringHashMap(protocol.Value).init(allocator);
    defer props1.deinit();
    try props1.put("username", .{ .String = "alice" });
    const e1 = try sc.validateNode(1, "User", props1);
    try std.testing.expect(e1 == null);

    // Second user with same username should violate uniqueness
    var props2 = std.StringHashMap(protocol.Value).init(allocator);
    defer props2.deinit();
    try props2.put("username", .{ .String = "alice" });
    const e2 = try sc.validateNode(2, "User", props2);
    try std.testing.expect(e2 != null);
    if (e2) |err| {
        try std.testing.expect(err.constraint_type == .unique_violation);
    }
}
