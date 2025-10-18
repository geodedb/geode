const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// TestCANARY_REQ_GQL_032_CompositeUnique - validates composite uniqueness enforcement.

test "TestCANARY_REQ_GQL_032_CompositeUnique" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Account",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Account", node_constraints);
    // Register composite unique index (org_id, account_name)
    try sc.addUniqueIndex("Account", &[_][]const u8{ "org_id", "account_name" });

    var props1 = std.StringHashMap(protocol.Value).init(allocator);
    defer props1.deinit();
    try props1.put("org_id", .{ .Int = 7 });
    try props1.put("account_name", .{ .String = "ops" });
    try std.testing.expect((try sc.validateNode(1, "Account", props1)) == null);

    var props2 = std.StringHashMap(protocol.Value).init(allocator);
    defer props2.deinit();
    try props2.put("org_id", .{ .Int = 7 });
    try props2.put("account_name", .{ .String = "ops" });
    const e = try sc.validateNode(2, "Account", props2);
    try std.testing.expect(e != null);
    if (e) |err| try std.testing.expect(err.constraint_type == .unique_violation);
}
