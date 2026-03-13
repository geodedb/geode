const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test property value creation and storage
    const graph_exec = @import("src/server/graph/exec.zig");

    // Initialize graph storage
    var storage = try graph_exec.GraphStore.init(allocator);
    defer storage.deinit();

    // Add a test node with properties
    const labels = [_][]const u8{"Person"};
    const node_id: graph_exec.NodeId = try storage.createNode(&labels);

    // Set properties
    const name_prop = graph_exec.PropertyValue{ .String = "Alice" };
    const age_prop = graph_exec.PropertyValue{ .Int = 30 };

    try storage.setNodeProperty(node_id, "name", name_prop);
    try storage.setNodeProperty(node_id, "age", age_prop);

    // Now test retrieval
    if (storage.nodes.get(node_id)) |node| {
        std.debug.print("Node found with {} labels\n", .{node.labels.len});

        if (node.properties.get("name")) |name_val| {
            switch (name_val) {
                .String => |s| std.debug.print("Name property: {s}\n", .{s}),
                else => std.debug.print("Name property has wrong type\n", .{}),
            }
        } else {
            std.debug.print("Name property not found!\n", .{});
        }

        if (node.properties.get("age")) |age_val| {
            switch (age_val) {
                .Int => |i| std.debug.print("Age property: {}\n", .{i}),
                else => std.debug.print("Age property has wrong type\n", .{}),
            }
        } else {
            std.debug.print("Age property not found!\n", .{});
        }
    } else {
        std.debug.print("Node not found!\n", .{});
    }
}
