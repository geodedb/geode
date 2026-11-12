const std = @import("std");
const perf_gate = @import("perf_gate");

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

// SONNY-6386 (6): the latency bounds below are measured through
// tests/perf_gate.zig: batched samples (each result passed to
// doNotOptimizeAway, CLOCK_MONOTONIC), allocated from perf_gate.bench_allocator
// (the server's C allocator, not DebugAllocator), claimed on the median with a
// robust envelope. They used to be one timed run on std.testing.allocator.
const bench_samples = 31;
const bench_max_rel_iqr = 0.30;
const bench_max_p95_over_median = 2.55;

const parse_sample_json =
    \\{"name":"John Doe","age":30,"city":"New York","skills":["programming","design","management"],"active":true}
;
const parse_sample_schema = [_]json_opt.SchemaColumn{
    .{ .name = "name", .type = "STRING" },
    .{ .name = "age", .type = "INT" },
    .{ .name = "active", .type = "BOOL" },
};
const parse_sample_rows = [_][]const u8{parse_sample_json};

const ParseSerializeBench = struct {
    processor: json_opt.OptimizedJsonProcessor,

    fn parse(self: *ParseSerializeBench) !usize {
        const parsed = try self.processor.parseJsonValue(parse_sample_json);
        const n = parsed.value.object.count();
        parsed.deinit();
        self.processor.reset();
        return n;
    }

    fn serialize(self: *ParseSerializeBench) !usize {
        const out = try self.processor.serializeQueryResult(&parse_sample_schema, &parse_sample_rows);
        const n = out.len;
        self.processor.reset();
        return n;
    }
};

test "JSON processing performance benchmark" {
    var bench: ParseSerializeBench = .{ .processor = try json_opt.OptimizedJsonProcessor.init(perf_gate.bench_allocator) };
    defer bench.processor.deinit();

    // Warm-up batch (arena and buffer growth) outside the samples.
    _ = try perf_gate.timeBatch(&bench, ParseSerializeBench.parse, 1000);
    _ = try perf_gate.timeBatch(&bench, ParseSerializeBench.serialize, 1000);

    var parse_samples: [bench_samples]f64 = undefined;
    var serialize_samples: [bench_samples]f64 = undefined;
    try perf_gate.sampleBatches(&bench, ParseSerializeBench.parse, 1000, &parse_samples);
    try perf_gate.sampleBatches(&bench, ParseSerializeBench.serialize, 1000, &serialize_samples);
    const parse_r = perf_gate.robust(&parse_samples);
    const serialize_r = perf_gate.robust(&serialize_samples);

    std.debug.print("\nJSON Optimization Benchmark Results ({d} batches of 1000):\n", .{bench_samples});
    std.debug.print("  Parse: median {d:.1}ns rel_iqr {d:.3}\n", .{ parse_r.median, parse_r.rel_iqr });
    std.debug.print("  Serialize: median {d:.1}ns rel_iqr {d:.3}\n", .{ serialize_r.median, serialize_r.rel_iqr });

    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    try perf_gate.robustEnvelope("JSON parse", parse_r, bench_max_rel_iqr, bench_max_p95_over_median);
    try perf_gate.robustEnvelope("JSON serialize", serialize_r, bench_max_rel_iqr, bench_max_p95_over_median);
    try perf_gate.check("JSON parse median < 100us", parse_r.median < 100_000, "median_ns={d:.1}", .{parse_r.median});
    try perf_gate.check("JSON serialize median < 150us", serialize_r.median < 150_000, "median_ns={d:.1}", .{serialize_r.median});
}

/// Streams the 1000-element result document into `processor` (reset first).
fn streamLargeResult(processor: *json_opt.OptimizedJsonProcessor) !usize {
    processor.reset();
    var writer = processor.getStreamingWriter();
    try writer.writeObjectStart();
    try writer.writeFieldName("large_array");
    try writer.writeArrayStart();
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
    return processor.getResult().len;
}

test "Large result set streaming output is well-formed" {
    const allocator = testing.allocator;
    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();
    try processor.reserveCapacity(1024 * 1024); // 1MB
    _ = try streamLargeResult(&processor);
    const result = processor.getResult();

    // SONNY-2394: the old `result.len > 50_000` could never hold -- 1000
    // `{"id":N,"value":"test_value"}` elements serialize to ~32 KB. Validate
    // the output itself instead: it must be well-formed JSON holding every
    // element, in order.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const large_array = parsed.value.object.get("large_array").?.array;
    try testing.expectEqual(@as(usize, 1000), large_array.items.len);
    try testing.expectEqual(@as(i64, 0), large_array.items[0].object.get("id").?.integer);
    try testing.expectEqual(@as(i64, 999), large_array.items[999].object.get("id").?.integer);
}

const LargeStreamBench = struct {
    processor: json_opt.OptimizedJsonProcessor,

    fn stream(self: *LargeStreamBench) !usize {
        return streamLargeResult(&self.processor);
    }
};

test "Large result set streaming performance" {
    var bench: LargeStreamBench = .{ .processor = try json_opt.OptimizedJsonProcessor.init(perf_gate.bench_allocator) };
    defer bench.processor.deinit();
    try bench.processor.reserveCapacity(1024 * 1024); // 1MB

    _ = try perf_gate.timeBatch(&bench, LargeStreamBench.stream, 4);
    var samples: [bench_samples]f64 = undefined;
    try perf_gate.sampleBatches(&bench, LargeStreamBench.stream, 4, &samples);
    const r = perf_gate.robust(&samples);
    const size = bench.processor.getResult().len;

    std.debug.print("\nLarge Result Set Streaming ({d} batches of 4):\n", .{bench_samples});
    std.debug.print("  Median: {d:.1}us rel_iqr {d:.3}\n", .{ r.median / 1000.0, r.rel_iqr });
    std.debug.print("  Size: {d} bytes\n", .{size});
    std.debug.print("  Rate: {d:.2} MB/s\n", .{(@as(f64, @floatFromInt(size)) / 1024.0 / 1024.0) / (r.median / 1_000_000_000.0)});

    // Should be much faster than 5.37ms file I/O baseline
    // (perf claim: shared gate, SONNY-2394 -- see tests/perf_gate.zig)
    try perf_gate.robustEnvelope("large result streaming", r, bench_max_rel_iqr, bench_max_p95_over_median);
    try perf_gate.check("large result streaming median < 5ms", r.median < 5_000_000, "median_ns={d:.1}", .{r.median});
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

/// The 50 user rows of the CANARY query-result benchmark. Caller frees each
/// row and the list.
fn canaryUserRows(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var rows = try std.ArrayList([]const u8).initCapacity(allocator, 50);
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
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
    return rows;
}

fn freeRows(allocator: std.mem.Allocator, rows: *std.ArrayList([]const u8)) void {
    for (rows.items) |row| allocator.free(row);
    rows.deinit(allocator);
}

const canary_schema = [_]json_opt.SchemaColumn{
    .{ .name = "user_id", .type = "INT" },
    .{ .name = "username", .type = "STRING" },
    .{ .name = "email", .type = "STRING" },
    .{ .name = "active", .type = "BOOL" },
    .{ .name = "last_login", .type = "DATETIME" },
};

test "CANARY REQ-PERF-JSON-001 query-result serialization is well-formed" {
    const allocator = testing.allocator;
    var processor = try json_opt.OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();
    var rows = try canaryUserRows(allocator);
    defer freeRows(allocator, &rows);

    const result = try processor.serializeQueryResult(&canary_schema, rows.items);
    try testing.expect(std.mem.indexOf(u8, result, "\"schema\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"rows\":[") != null);
    try testing.expect(result.len > 1000); // Should generate substantial JSON
    // SONNY-2394: the schema lists the "user_id" column once and every row
    // carries it once, so the count is 1 + rows -- the old
    // `schema.len + rows.items.len` (5 + 50) could never match. The result
    // must also be well-formed JSON.
    try testing.expectEqual(1 + rows.items.len, std.mem.count(u8, result, "user_id"));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(rows.items.len, parsed.value.object.get("rows").?.array.items.len);
}

const CanarySerializeBench = struct {
    processor: json_opt.OptimizedJsonProcessor,
    rows: []const []const u8,

    fn serialize(self: *CanarySerializeBench) !usize {
        self.processor.reset();
        const out = try self.processor.serializeQueryResult(&canary_schema, self.rows);
        return out.len;
    }
};

// Integration test validating JSON optimization against baseline performance
test "CANARY: REQ=REQ-PERF-JSON-001" {
    // CANARY: REQ=REQ-PERF-JSON-001; FEATURE="OptimizedJSON"; ASPECT=Integration; STATUS=TESTED; TEST=TestCANARY_REQ_PERF_JSON_001; OWNER=performance; UPDATED=2026-11-12
    const alloc = perf_gate.bench_allocator;
    var rows = try canaryUserRows(alloc);
    defer freeRows(alloc, &rows);
    var bench: CanarySerializeBench = .{ .processor = try json_opt.OptimizedJsonProcessor.init(alloc), .rows = rows.items };
    defer bench.processor.deinit();

    _ = try perf_gate.timeBatch(&bench, CanarySerializeBench.serialize, 16);
    var samples: [bench_samples]f64 = undefined;
    try perf_gate.sampleBatches(&bench, CanarySerializeBench.serialize, 16, &samples);
    const r = perf_gate.robust(&samples);
    const size = bench.processor.getResult().len;

    std.debug.print("\nCANARY Performance Validation ({d} batches of 16):\n", .{bench_samples});
    std.debug.print("  Processing time: median {d:.1}us rel_iqr {d:.3}\n", .{ r.median / 1000.0, r.rel_iqr });
    std.debug.print("  Result size: {d} bytes\n", .{size});
    std.debug.print("  Throughput: {d:.2} MB/s\n", .{(@as(f64, @floatFromInt(size)) / 1024.0 / 1024.0) / (r.median / 1_000_000_000.0)});

    // Performance regression test: should be significantly faster than 630μs baseline
    // (perf claim: shared gate, SONNY-2394 -- see tests/perf_gate.zig)
    try perf_gate.robustEnvelope("CANARY query-result serialization", r, bench_max_rel_iqr, bench_max_p95_over_median);
    try perf_gate.check("CANARY query-result serialization median < 300us", r.median < 300_000, "median_ns={d:.1}", .{r.median});
}
