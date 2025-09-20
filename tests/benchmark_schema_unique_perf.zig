const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// BenchmarkCANARY_REQ_GQL_032_UniquePerf
// Measures cost of inserting many unique integer properties.

test "BenchmarkCANARY_REQ_GQL_032_UniquePerf" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(ally);
    defer sc.deinit();

    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{
        .label = "Thing",
        .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{},
        .unique_properties = &[_][]const u8{"u"},
        .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{},
    };
    try sc.addNodeConstraint("Thing", node_constraints);

    var i: usize = 0;
    const total = 5000; // modest for CI
    while (i < total) : (i += 1) {
        var props = std.StringHashMap(protocol.Value).init(ally);
        defer props.deinit();
        try props.put("u", protocol.Value{ .integer = @as(i64, @intCast(i)) });
        const err = try sc.validateNode(i, "Thing", props);
        if (err) |e| {
            std.debug.panic("unexpected uniqueness violation: {s}", .{e.message});
        }
    }
}
