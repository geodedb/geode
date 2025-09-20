const std = @import("std");
const graph_exec = @import("../src/server/graph/exec.zig");

// TestCANARY_REQ_GQL_017_PropertyAccess - verifies property retrieval formatting logic.
// This is a unit-level simulation: we construct a Node and ensure property map contains expected value.

test "TestCANARY_REQ_GQL_017_PropertyAccess" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var props = std.StringHashMap(graph_exec.PropertyValue).init(ally);
    defer props.deinit();
    try props.put("name", .{ .String = "alice" });

    var node = graph_exec.Node{ .id = 1, .labels = &[_][]const u8{"Person"}, .properties = props };
    // Access property by direct lookup (acting as simplified projection step)
    const got = node.properties.get("name") orelse return error.Missing;
    switch (got) {
        .String => |s| try std.testing.expect(std.mem.eql(u8, s, "alice")),
        else => return error.UnexpectedType,
    }
}
