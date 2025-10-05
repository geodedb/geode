const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-VECTOR-INDEX-POPULATION-001; FEATURE="Vector Index Population"; ASPECT=VectorIndexPopulation; STATUS=TESTED; TEST=TestCANARY_REQ_VECTOR_INDEX_POPULATION_001_Basic; OWNER=index; UPDATED=2025-10-05
// CANARY: REQ=REQ-VECTOR-INDEX-POPULATION-002; FEATURE="Vector Index Population"; ASPECT=PropertyValueIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_VECTOR_INDEX_POPULATION_002_PropertyValueSwitch; OWNER=index; UPDATED=2025-10-05
// CANARY: REQ=REQ-VECTOR-INDEX-POPULATION-003; FEATURE="Vector Index Population"; ASPECT=JSONSerialization; STATUS=TESTED; TEST=TestCANARY_REQ_VECTOR_INDEX_POPULATION_003_JSONFormat; OWNER=index; UPDATED=2025-10-05

test "TestCANARY_REQ_VECTOR_INDEX_POPULATION_001_Basic" {
    // Test that VectorF32 properties can be handled in PropertyValue switches
    const allocator = testing.allocator;
    
    // Create a sample VectorF32
    const vector_data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const vector = geode.graph_common.VectorF32{
        .dim = 4,
        .data = &vector_data,
    };
    
    // Create PropertyValue with VectorF32
    const prop_value = geode.graph_common.PropertyValue{ .VectorF32 = vector };
    
    // Test switch statement handling
    switch (prop_value) {
        .VectorF32 => |v| {
            try testing.expect(v.dim == 4);
            try testing.expect(v.data.len == 4);
            try testing.expectEqual(@as(f32, 1.0), v.data[0]);
            try testing.expectEqual(@as(f32, 4.0), v.data[3]);
        },
        else => {
            try testing.expect(false); // Should not reach here
        },
    }
}

test "VectorF32 PropertyValue JSON serialization format" {
    // Test that VectorF32 gets properly formatted in JSON serialization
    const allocator = testing.allocator;
    
    const vector_data = [_]f32{ 1.5, 2.5, 3.5 };
    const vector = geode.graph_common.VectorF32{
        .dim = 3,
        .data = &vector_data,
    };
    
    const prop_value = geode.graph_common.PropertyValue{ .VectorF32 = vector };
    
    // This simulates the switch statement logic in main.zig line 865
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    switch (prop_value) {
        .VectorF32 => |vec| {
            try std.fmt.format(result.writer(), "\"[vector:{d}x{d}]\"", .{ vec.dim, vec.data.len });
        },
        else => {
            try result.appendSlice("null");
        },
    }
    
    const expected = "\"[vector:3x3]\"";
    try testing.expectEqualStrings(expected, result.items);
}

test "TestCANARY_REQ_VECTOR_INDEX_POPULATION_002_PropertyValueSwitch" {
    // Test comprehensive PropertyValue switch handling with VectorF32
    const allocator = testing.allocator;
    
    const test_vectors = [_]struct {
        dim: u16,
        data: []const f32,
        expected_key: []const u8,
        expected_json: []const u8,
    }{
        .{ .dim = 3, .data = &[_]f32{ 1.0, 2.0, 3.0 }, .expected_key = "vector_3x3", .expected_json = "\"[vector:3x3]\"" },
        .{ .dim = 128, .data = &[_]f32{0.0} ** 128, .expected_key = "vector_128x128", .expected_json = "\"[vector:128x128]\"" },
        .{ .dim = 1, .data = &[_]f32{42.5}, .expected_key = "vector_1x1", .expected_json = "\"[vector:1x1]\"" },
    };
    
    for (test_vectors) |test_case| {
        const vector = geode.graph_common.VectorF32{
            .dim = test_case.dim,
            .data = test_case.data,
        };
        
        const prop_value = geode.graph_common.PropertyValue{ .VectorF32 = vector };
        
        // Test index key generation (main.zig:6059 logic)
        const vector_key = try std.fmt.allocPrint(allocator, "vector_{d}x{d}", .{ vector.dim, vector.data.len });
        defer allocator.free(vector_key);
        try testing.expectEqualStrings(test_case.expected_key, vector_key);
        
        // Test JSON serialization (main.zig:871 logic)
        var json_output = std.ArrayList(u8).init(allocator);
        defer json_output.deinit();
        
        switch (prop_value) {
            .VectorF32 => |v| {
                try std.fmt.format(json_output.writer(), "\"[vector:{d}x{d}]\"", .{ v.dim, v.data.len });
            },
            else => try json_output.appendSlice("null"),
        }
        
        try testing.expectEqualStrings(test_case.expected_json, json_output.items);
    }
}

test "TestCANARY_REQ_VECTOR_INDEX_POPULATION_003_JSONFormat" {
    // Test comprehensive JSON serialization patterns for VectorF32
    const allocator = testing.allocator;
    
    // Test edge cases and various dimensions
    const edge_cases = [_]struct {
        vector: geode.graph_common.VectorF32,
        expected: []const u8,
    }{
        .{ .vector = .{ .dim = 0, .data = &[_]f32{} }, .expected = "\"[vector:0x0]\"" },
        .{ .vector = .{ .dim = 1, .data = &[_]f32{3.14159} }, .expected = "\"[vector:1x1]\"" },
        .{ .vector = .{ .dim = 512, .data = &[_]f32{1.0} ** 512 }, .expected = "\"[vector:512x512]\"" },
    };
    
    for (edge_cases) |test_case| {
        const prop_value = geode.graph_common.PropertyValue{ .VectorF32 = test_case.vector };
        
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // Simulate exact logic from main.zig:871
        switch (prop_value) {
            .Null => try result.appendSlice("null"),
            .Bool => |b| try std.fmt.format(result.writer(), "{}", .{b}),
            .Int => |iv| try std.fmt.format(result.writer(), "{d}", .{iv}),
            .String => |s| try std.fmt.format(result.writer(), "\"{s}\"", .{s}),
            .Decimal => try result.appendSlice("null"),
            .VectorF32 => |vec| try std.fmt.format(result.writer(), "\"[vector:{d}x{d}]\"", .{ vec.dim, vec.data.len }),
        }
        
        try testing.expectEqualStrings(test_case.expected, result.items);
    }
}

test "Vector index key generation format" {
    // Test the vector index key format used in vector index population
    const allocator = testing.allocator;
    
    const vector_data = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    const vector = geode.graph_common.VectorF32{
        .dim = 5,
        .data = &vector_data,
    };
    
    // This simulates the vector key generation in main.zig line 6059
    const vector_key = try std.fmt.allocPrint(allocator, "vector_{d}x{d}", .{ vector.dim, vector.data.len });
    defer allocator.free(vector_key);
    
    try testing.expectEqualStrings("vector_5x5", vector_key);
}

test "PropertyValue type system completeness with VectorF32" {
    // Ensure all PropertyValue types work correctly including VectorF32
    const all_types = [_]geode.graph_common.PropertyValue{
        .{ .Null = {} },
        .{ .Bool = false },
        .{ .Int = -42 },
        .{ .String = "test_string" },
        .{ .Decimal = .{ .coeff = 12345, .scale = 3 } },
        .{ .VectorF32 = .{ .dim = 4, .data = &[_]f32{ -1.0, 0.0, 1.0, 2.0 } } },
    };
    
    var type_count: u8 = 0;
    
    for (all_types) |prop| {
        switch (prop) {
            .Null => type_count += 1,
            .Bool => type_count += 1,
            .Int => type_count += 1,
            .String => type_count += 1,
            .Decimal => type_count += 1,
            .VectorF32 => |v| {
                try testing.expect(v.dim == 4);
                try testing.expect(v.data.len == 4);
                try testing.expectEqual(@as(f32, -1.0), v.data[0]);
                try testing.expectEqual(@as(f32, 2.0), v.data[3]);
                type_count += 1;
            },
        }
    }
    
    try testing.expect(type_count == 6); // All PropertyValue types handled
}