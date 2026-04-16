const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_CheckConstraint - validates simple check constraint expressions key=value and key!=value.

test "TestCANARY_REQ_GQL_032_CheckConstraint" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const check_ok = constraints_mod.SchemaConstraints.CheckConstraint{ .name = "country_us", .expression = "country=US", .error_message = "country must be US" };
    const check_fail = constraints_mod.SchemaConstraints.CheckConstraint{ .name = "not_admin", .expression = "role!=admin", .error_message = "role must not be admin" };

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "User",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{ check_ok, check_fail },
    };
    try sc.addNodeConstraint("User", node_constraints);

    var props = std.StringHashMap(protocol.Value).init(allocator);
    defer props.deinit();
    try props.put("country", .{ .String = "US" });
    try props.put("role", .{ .String = "admin" });

    const err = try sc.validateNode(1, "User", props);
    try std.testing.expect(err != null);
    if (err) |e| try std.testing.expect(e.constraint_type == .check_constraint);
}
