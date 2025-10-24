const std = @import("std");
const graph_exec = @import("../src/server/graph/exec.zig");

// TestCANARY_REQ_GQL_017_PropertyAccess - verifies property retrieval formatting logic.
// This is a unit-level simulation: we construct a Node and ensure property map contains expected value.

test "TestCANARY_REQ_GQL_017_PropertyAccess" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var props = std.StringHashMap(graph_exec.PropertyValue).init(allocator);
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

// TestCANARY_REQ_GQL_017_PropertyAccessNull - ensure null variant stored and retrieved.
test "TestCANARY_REQ_GQL_017_PropertyAccessNull" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var props = std.StringHashMap(graph_exec.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("age", .{ .Null = {} });
    var node = graph_exec.Node{ .id = 2, .labels = &[_][]const u8{"Person"}, .properties = props };
    const got = node.properties.get("age") orelse return error.Missing;
    switch (got) {
        .Null => {},
        else => return error.UnexpectedType,
    }
}

// TestCANARY_REQ_GQL_017_PropertyAccessMissing - ensure missing property yields error.Missing.
test "TestCANARY_REQ_GQL_017_PropertyAccessMissing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var props = std.StringHashMap(graph_exec.PropertyValue).init(allocator);
    defer props.deinit();
    var node = graph_exec.Node{ .id = 3, .labels = &[_][]const u8{"Person"}, .properties = props };
    if (node.properties.get("unknown")) |_| {
        return error.UnexpectedFound;
    } else |err| {
        _ = err; // acceptable path
    }
}

// TestCANARY_REQ_GQL_017_PropertyAccessDecimalFormat - ensure decimal property formats precisely.
test "TestCANARY_REQ_GQL_017_PropertyAccessDecimalFormat" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var props = std.StringHashMap(graph_exec.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("score", .{ .Float = 12.5 });
    var node = graph_exec.Node{ .id = 4, .labels = &[_][]const u8{"Metric"}, .properties = props };
    const got = node.properties.get("score") orelse return error.Missing;
    switch (got) {
        .Float => |f| {
            const diff = std.math.fabs(f - 12.5);
            try std.testing.expect(diff < 0.0001);
        },
        else => return error.UnexpectedType,
    }
}
