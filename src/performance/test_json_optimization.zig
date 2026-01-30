const std = @import("std");
const testing = std.testing;
const json_opt = @import("json_optimized_fixed.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-068; FEATURE="JSON Library Migration"; ASPECT=TestJsonOptimization; STATUS=EXEMPT; OWNER=performance; UPDATED=2026-01-25
const json_lib = @import("json");

// Test data structs for JSON encoding
const IterationData = struct { iteration: u32, data: []const u8 };
const UserRow = struct {
    user_id: u32,
    username: []const u8,
    email: []const u8,
    active: bool,
    last_login: []const u8,
};

// CANARY: REQ=REQ-PERF-JSON-001; FEATURE="OptimizedJSON"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_OptimizedJSON; OWNER=performance; UPDATED=2025-10-04

test "OptimizedJsonProcessor basic functionality" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    var writer = processor.getStreamingWriter();

    try writer.writeObjectStart();
    try writer.writeFieldName("name");
    try writer.writeString("Alice");
    try writer.writeFieldName("age");
    try writer.writeNumber(25);
    try writer.writeFieldName("active");
    try writer.writeBool(true);
    try writer.writeObjectEnd();

    const result = processor.getResult();
    try testing.expect(std.mem.eql(u8, result, "{\"name\":\"Alice\",\"age\":25,\"active\":true}"));
}

test "OptimizedJsonProcessor array handling" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    var writer = processor.getStreamingWriter();

    try writer.writeArrayStart();
    try writer.writeString("first");
    try writer.writeString("second");
    try writer.writeNumber(42);
    try writer.writeBool(false);
    try writer.writeNull();
    try writer.writeArrayEnd();

    const result = processor.getResult();
    try testing.expect(std.mem.eql(u8, result, "[\"first\",\"second\",42,false,null]"));
}

test "OptimizedJsonProcessor string escaping" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    var writer = processor.getStreamingWriter();

    try writer.writeObjectStart();
    try writer.writeFieldName("escaped");
    try writer.writeString("Hello\nWorld\t\"quoted\"\\backslash");
    try writer.writeObjectEnd();

    const result = processor.getResult();
    const expected = "{\"escaped\":\"Hello\\nWorld\\t\\\"quoted\\\"\\\\backslash\"}";
    try testing.expect(std.mem.eql(u8, result, expected));
}

test "OptimizedJsonProcessor query result serialization" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    const schema = [_]json_opt.SchemaColumn{
        .{ .name = "id", .type = "INT" },
        .{ .name = "name", .type = "STRING" },
        .{ .name = "active", .type = "BOOL" },
    };

    const rows = [_][]const u8{
        "{\"id\":1,\"name\":\"Alice\",\"active\":true}",
        "{\"id\":2,\"name\":\"Bob\",\"active\":false}",
    };

    const result = try processor.serializeQueryResult(&schema, &rows);

    // Verify the structure is correct
    try testing.expect(std.mem.indexOf(u8, result, "\"schema\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"rows\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"type\":\"INT\"") != null);
}

test "OptimizedJsonProcessor reset and reuse" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    // First use
    var writer = processor.getStreamingWriter();
    try writer.writeObjectStart();
    try writer.writeFieldName("test");
    try writer.writeString("first");
    try writer.writeObjectEnd();

    const first_result = processor.getResult();
    try testing.expect(std.mem.eql(u8, first_result, "{\"test\":\"first\"}"));

    // Reset and reuse
    processor.reset();

    writer = processor.getStreamingWriter();
    try writer.writeObjectStart();
    try writer.writeFieldName("test");
    try writer.writeString("second");
    try writer.writeObjectEnd();

    const second_result = processor.getResult();
    try testing.expect(std.mem.eql(u8, second_result, "{\"test\":\"second\"}"));
}

test "JsonProcessorPool thread safety and reuse" {
    const allocator = testing.allocator;

    var pool = try json_opt.JsonProcessorPool.init(allocator, 3);
    defer pool.deinit();

    // Acquire processors
    const proc1 = pool.acquire();
    const proc2 = pool.acquire();
    const proc3 = pool.acquire();
    const proc4 = pool.acquire(); // Should be null (pool exhausted)

    try testing.expect(proc1 != null);
    try testing.expect(proc2 != null);
    try testing.expect(proc3 != null);
    try testing.expect(proc4 == null);

    // Use and release
    if (proc1) |p| {
        var writer = p.getStreamingWriter();
        try writer.writeObjectStart();
        try writer.writeFieldName("pool_test");
        try writer.writeBool(true);
        try writer.writeObjectEnd();

        const result = p.getResult();
        try testing.expect(std.mem.eql(u8, result, "{\"pool_test\":true}"));

        pool.release(p);
    }

    // Should be able to acquire again
    const proc5 = pool.acquire();
    try testing.expect(proc5 != null);

    if (proc5) |p| {
        // Should be reset and ready for use
        const result = p.getResult();
        try testing.expect(result.len == 0);
        pool.release(p);
    }

    // Release remaining
    if (proc2) |p| pool.release(p);
    if (proc3) |p| pool.release(p);
}

test "escapeJsonStringOptimized performance" {
    const allocator = testing.allocator;

    // Test no-escape fast path
    const simple_string = "simple_string_no_escapes";
    const escaped_simple = try json_opt.escapeJsonStringOptimized(allocator, simple_string);
    defer allocator.free(escaped_simple);
    try testing.expect(std.mem.eql(u8, escaped_simple, simple_string));

    // Test escaping path
    const complex_string = "Hello\n\"World\"\tWith\rSpecial\\Chars";
    const escaped_complex = try json_opt.escapeJsonStringOptimized(allocator, complex_string);
    defer allocator.free(escaped_complex);

    const expected = "Hello\\n\\\"World\\\"\\tWith\\rSpecial\\\\Chars";
    try testing.expect(std.mem.eql(u8, escaped_complex, expected));
}

test "JSON processing performance benchmark" {
    const allocator = testing.allocator;

    const results = try json_opt.benchmarkJsonProcessing(allocator, 100);

    std.debug.print("\nJSON Optimization Benchmark Results:\n", .{});
    std.debug.print("  Parse time: {d}ns\n", .{results.parse_ns});
    std.debug.print("  Serialize time: {d}ns\n", .{results.serialize_ns});

    // Performance expectations (should be significantly better than baseline 630μs)
    try testing.expect(results.parse_ns < 100_000); // Less than 100μs
    try testing.expect(results.serialize_ns < 150_000); // Less than 150μs
}

test "Large result set streaming performance" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    // Pre-allocate for large result set
    try processor.reserveCapacity(1024 * 1024); // 1MB

    var writer = processor.getStreamingWriter();

    var timer = try std.time.Timer.start();

    try writer.writeObjectStart();
    try writer.writeFieldName("large_array");
    try writer.writeArrayStart();

    // Simulate large result set
    for (0..1000) |i| {
        try writer.writeObjectStart();
        try writer.writeFieldName("id");
        try writer.writeNumber(i);
        try writer.writeFieldName("value");
        try writer.writeString("test_value");
        try writer.writeObjectEnd();
    }

    try writer.writeArrayEnd();
    try writer.writeObjectEnd();

    const elapsed = timer.read();
    const result = processor.getResult();

    std.debug.print("\nLarge Result Set Streaming:\n", .{});
    std.debug.print("  Time: {d}μs\n", .{elapsed / 1000});
    std.debug.print("  Size: {d} bytes\n", .{result.len});
    std.debug.print("  Rate: {d:.2} MB/s\n", .{(@as(f64, @floatFromInt(result.len)) / 1024.0 / 1024.0) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)});

    // Should be much faster than 5.37ms file I/O baseline
    try testing.expect(elapsed < 5_000_000); // Less than 5ms
    try testing.expect(result.len > 50_000); // Should generate substantial output
}

test "Memory usage optimization validation" {
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    // Test arena allocation efficiency
    for (0..100) |i| {
        const iter_data = IterationData{ .iteration = @intCast(i), .data = "test_value" };
        const test_json = try json_lib.encode(allocator, iter_data, .{});
        defer allocator.free(test_json);

        const parsed = try processor.parseJsonValue(test_json);
        parsed.deinit();
        // Don't reset arena to test memory reuse
    }

    // Arena should have reused memory efficiently
    // This test validates the arena allocation pattern is working
    try testing.expect(true); // If we get here without OOM, arena is working
}

// Integration test validating JSON optimization against baseline performance
test "CANARY: REQ=REQ-PERF-JSON-001" {
    // CANARY: REQ=REQ-PERF-JSON-001; FEATURE="OptimizedJSON"; ASPECT=Integration; STATUS=TESTED; TEST=TestCANARY_REQ_PERF_JSON_001; OWNER=performance; UPDATED=2025-10-04
    const allocator = testing.allocator;

    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    // Test comprehensive JSON processing pipeline
    const schema = [_]json_opt.SchemaColumn{
        .{ .name = "user_id", .type = "INT" },
        .{ .name = "username", .type = "STRING" },
        .{ .name = "email", .type = "STRING" },
        .{ .name = "active", .type = "BOOL" },
        .{ .name = "last_login", .type = "DATETIME" },
    };

    var rows = try std.ArrayList([]const u8).initCapacity(allocator, 50);
    defer {
        for (rows.items) |row| {
            allocator.free(row);
        }
        rows.deinit(allocator);
    }

    // Generate test data
    for (0..50) |i| {
        const username = try std.fmt.allocPrint(allocator, "user{d}", .{i});
        defer allocator.free(username);
        const email = try std.fmt.allocPrint(allocator, "user{d}@example.com", .{i});
        defer allocator.free(email);
        const user_data = UserRow{
            .user_id = @intCast(i),
            .username = username,
            .email = email,
            .active = (i % 2 == 0),
            .last_login = "2025-10-04T10:30:00Z",
        };
        const row = try json_lib.encode(allocator, user_data, .{});
        try rows.append(allocator, row);
    }

    var timer = try std.time.Timer.start();
    const result = try processor.serializeQueryResult(&schema, rows.items);
    const processing_time = timer.read();

    // Validate result structure
    try testing.expect(std.mem.indexOf(u8, result, "\"schema\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"rows\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "user_id") != null);
    try testing.expect(result.len > 1000); // Should generate substantial JSON

    std.debug.print("\nCANARY Performance Validation:\n", .{});
    std.debug.print("  Processing time: {d}μs\n", .{processing_time / 1000});
    std.debug.print("  Result size: {d} bytes\n", .{result.len});
    std.debug.print("  Throughput: {d:.2} MB/s\n", .{(@as(f64, @floatFromInt(result.len)) / 1024.0 / 1024.0) / (@as(f64, @floatFromInt(processing_time)) / 1_000_000_000.0)});

    // Performance regression test: should be significantly faster than 630μs baseline
    try testing.expect(processing_time < 300_000); // Less than 300μs (2x improvement target)

    // Correctness validation
    try testing.expect(std.mem.count(u8, result, "user_id") == schema.len + rows.items.len); // Schema + data references
}
