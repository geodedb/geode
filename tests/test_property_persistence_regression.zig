const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// REGRESSION TEST for property access and data persistence issues
// This test addresses the segfaults and memory corruption issues that occurred
// when properties with string values were not properly deep-copied, causing
// dangling pointers when AST memory was freed.

// CANARY: REQ=REQ-GQL-PROPERTY-001; FEATURE="PropertyPersistence"; ASPECT=MemoryManagement; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_PROPERTY_001_MemoryManagement; OWNER=engine; UPDATED=2025-10-04

test "Property storage with deep copy memory management" {
    const allocator = testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Simulate AST memory that will be freed
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ast_allocator = arena.allocator();

    // Create temporary strings in AST memory
    const temp_label = try ast_allocator.dupe(u8, "Person");
    const temp_key = try ast_allocator.dupe(u8, "name");
    const temp_value = try ast_allocator.dupe(u8, "Alice");

    // Add node with properties using AST strings
    const node_id = try graph.createNode(&.{temp_label});
    try graph.setNodeProperty(node_id, temp_key, .{ .String = temp_value });

    // Free AST memory to simulate AST being freed after parsing
    arena.deinit();
    arena = std.heap.ArenaAllocator.init(allocator);

    // Verify that properties are still accessible after AST memory is freed
    const retrieved_property = graph.getNodeProperty(node_id, "name") orelse return error.PropertyNotFound;

    try testing.expect(retrieved_property == .String);
    try testing.expectEqualStrings("Alice", retrieved_property.String);
}

test "UNION property access with persisted data simulation" {
    const allocator = testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    const alice_id = try graph.createNode(&.{"Person"});
    try graph.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(alice_id, "age", .{ .Int = 30 });

    const bob_id = try graph.createNode(&.{"Person"});
    try graph.setNodeProperty(bob_id, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(bob_id, "age", .{ .Int = 25 });

    const alice_name = graph.getNodeProperty(alice_id, "name") orelse return error.PropertyNotFound;
    const alice_age = graph.getNodeProperty(alice_id, "age") orelse return error.PropertyNotFound;

    const bob_name = graph.getNodeProperty(bob_id, "name") orelse return error.PropertyNotFound;
    const bob_age = graph.getNodeProperty(bob_id, "age") orelse return error.PropertyNotFound;

    try testing.expectEqualStrings("Alice", alice_name.String);
    try testing.expectEqual(@as(i64, 30), alice_age.Int);
    try testing.expectEqualStrings("Bob", bob_name.String);
    try testing.expectEqual(@as(i64, 25), bob_age.Int);
}

// Test that reproduces the exact segfault scenario that was fixed
// CANARY: REQ=REQ-GQL-PROPERTY-001; FEATURE="PropertyPersistence"; ASPECT=MemoryManagement; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_PROPERTY_001_MemoryManagement; OWNER=engine; UPDATED=2026-02-04

test "TestCANARY_REQ_GQL_PROPERTY_001_MemoryManagement" {
    const allocator = testing.allocator;

    var graph = geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    var node_id: u64 = 0;
    // Phase 1: Simulate CREATE statement execution with AST memory
    {
        var create_arena = std.heap.ArenaAllocator.init(allocator);
        defer create_arena.deinit();
        const create_allocator = create_arena.allocator();

        const ast_label = try create_allocator.dupe(u8, "Person");
        const ast_prop_key1 = try create_allocator.dupe(u8, "name");
        const ast_prop_value1 = try create_allocator.dupe(u8, "Alice");
        const ast_prop_key2 = try create_allocator.dupe(u8, "age");

        node_id = try graph.createNode(&.{ast_label});
        try graph.setNodeProperty(node_id, ast_prop_key1, .{ .String = ast_prop_value1 });
        try graph.setNodeProperty(node_id, ast_prop_key2, .{ .Int = 30 });
    }

    // Phase 2: Simulate MATCH query
    const name_prop = graph.getNodeProperty(node_id, "name") orelse return error.PropertyNotFound;
    const age_prop = graph.getNodeProperty(node_id, "age") orelse return error.PropertyNotFound;

    try testing.expectEqualStrings("Alice", name_prop.String);
    try testing.expectEqual(@as(i64, 30), age_prop.Int);

    // Phase 3: Simulate persistence path
    var save_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer save_buffer.deinit(allocator);

    try std.fmt.format(save_buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d}}}", .{ name_prop.String, age_prop.Int });

    const result = save_buffer.items;
    try testing.expect(std.mem.indexOf(u8, result, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, result, "30") != null);
}
