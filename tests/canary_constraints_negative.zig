const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Negative"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_032_ConstraintUniqueViolation,TestCANARY_REQ_GQL_032_ConstraintTypeMismatch; OWNER=schema; UPDATED=2025-09-20

test "TestCANARY_REQ_GQL_032_ConstraintUniqueViolation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var sc = constraints_mod.SchemaConstraints.init(ally);
    defer sc.deinit();

    const nc = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Person",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{"email"},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Person", nc);

    var props1 = std.StringHashMap(protocol.Value).init(ally);
    defer props1.deinit();
    try props1.put("email", .{ .String = "a@b" });
    try std.testing.expect((try sc.validateNode(1, "Person", props1)) == null);

    var props2 = std.StringHashMap(protocol.Value).init(ally);
    defer props2.deinit();
    try props2.put("email", .{ .String = "a@b" });
    const err2 = try sc.validateNode(2, "Person", props2);
    try std.testing.expect(err2 != null);
    if (err2) |e| try std.testing.expect(e.constraint_type == .unique_property);
}

test "TestCANARY_REQ_GQL_032_ConstraintTypeMismatch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var sc = constraints_mod.SchemaConstraints.init(ally);
    defer sc.deinit();

    const nc = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Device",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{
            .{ .name = "version", .type = .string, .nullable = false, .default_value = null, .min_value = null, .max_value = null, .pattern = null },
        },
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Device", nc);

    var props = std.StringHashMap(protocol.Value).init(ally);
    defer props.deinit();
    try props.put("version", .{ .Int = 17 });
    const err1 = try sc.validateNode(1, "Device", props);
    try std.testing.expect(err1 != null);
    if (err1) |e| try std.testing.expect(e.constraint_type == .type_mismatch);
}
