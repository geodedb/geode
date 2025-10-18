const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// BenchmarkCANARY_REQ_GQL_032_ConstraintPerf
// Evaluates performance of check constraint evaluation with chained AND clauses.

test "BenchmarkCANARY_REQ_GQL_032_ConstraintPerf" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(allocator);
    defer sc.deinit();

    const check = constraints_mod.SchemaConstraints.CheckConstraint{
        .name = "c1",
        .expression = "a>0&&a<1000000&&b=ok&&c!=bad", // mixed operations
        .error_message = "failed",
    };

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Thing",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{check},
    };
    try sc.addNodeConstraint("Thing", node_constraints);

    var i: usize = 0;
    const total = 8000;
    while (i < total) : (i += 1) {
        var props = std.StringHashMap(protocol.Value).init(allocator);
        defer props.deinit();
        try props.put("a", protocol.Value{ .integer = @as(i64, @intCast(i % 999999)) });
        try props.put("b", protocol.Value{ .string = "ok" });
        try props.put("c", protocol.Value{ .string = if (i % 1000 == 0) "bad" else "good" });
        _ = try sc.validateNode(i, "Thing", props);
    }
}
