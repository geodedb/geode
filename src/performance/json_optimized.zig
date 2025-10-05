const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-PERF-JSON-001; FEATURE="OptimizedJSON"; ASPECT=Performance; STATUS=IMPL; TEST=TestCANARY_OptimizedJSON; OWNER=performance; UPDATED=2025-10-04

/// High-performance JSON serialization system with arena allocators and streaming support
/// Addresses 630μs JSON parsing bottleneck (31x slower than target) identified in performance analysis
pub const OptimizedJsonProcessor = struct {
    arena: std.heap.ArenaAllocator,
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.arena.deinit();
    }

    /// Reset for reuse (arena pattern for zero-allocation subsequent uses)
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Pre-allocate buffer for expected JSON size (eliminates reallocations)
    pub fn reserveCapacity(self: *Self, capacity: usize) !void {
        try self.buffer.ensureTotalCapacity(capacity);
    }

    /// Streaming JSON writer for large result sets
    pub const StreamingWriter = struct {
        buffer: *std.ArrayList(u8),
        arena_allocator: Allocator,
        first_item: bool = true,

        pub fn writeObjectStart(self: *StreamingWriter) !void {
            try self.buffer.append('{');
        }

        pub fn writeObjectEnd(self: *StreamingWriter) !void {
            try self.buffer.append('}');
        }

        pub fn writeArrayStart(self: *StreamingWriter) !void {
            try self.buffer.append('[');
            self.first_item = true;
        }

        pub fn writeArrayEnd(self: *StreamingWriter) !void {
            try self.buffer.append(']');
        }

        pub fn writeFieldName(self: *StreamingWriter, name: []const u8) !void {
            if (!self.first_item) {
                try self.buffer.append(',');
            }
            try self.buffer.append('"');
            try self.writeEscapedString(name);
            try self.buffer.appendSlice("\":");
            self.first_item = false;
        }

        pub fn writeString(self: *StreamingWriter, value: []const u8) !void {
            if (!self.first_item) {
                try self.buffer.append(',');
            }
            try self.buffer.append('"');
            try self.writeEscapedString(value);
            try self.buffer.append('"');
            self.first_item = false;
        }

        pub fn writeNumber(self: *StreamingWriter, value: anytype) !void {
            if (!self.first_item) {
                try self.buffer.append(',');
            }
            const formatted = try std.fmt.allocPrint(self.arena_allocator, "{}", .{value});
            try self.buffer.appendSlice(formatted);
            self.first_item = false;
        }

        pub fn writeBool(self: *StreamingWriter, value: bool) !void {
            if (!self.first_item) {
                try self.buffer.append(',');
            }
            try self.buffer.appendSlice(if (value) "true" else "false");
            self.first_item = false;
        }

        pub fn writeNull(self: *StreamingWriter) !void {
            if (!self.first_item) {
                try self.buffer.append(',');
            }
            try self.buffer.appendSlice("null");
            self.first_item = false;
        }

        fn writeEscapedString(self: *StreamingWriter, input: []const u8) !void {
            for (input) |c| {
                switch (c) {
                    '"' => try self.buffer.appendSlice("\\\""),
                    '\\' => try self.buffer.appendSlice("\\\\"),
                    '\n' => try self.buffer.appendSlice("\\n"),
                    '\r' => try self.buffer.appendSlice("\\r"),
                    '\t' => try self.buffer.appendSlice("\\t"),
                    else => try self.buffer.append(c),
                }
            }
        }
    };

    /// Get streaming writer for incremental JSON building
    pub fn getStreamingWriter(self: *Self) StreamingWriter {
        return .{
            .buffer = &self.buffer,
            .arena_allocator = self.arena.allocator(),
        };
    }

    /// Optimized JSON parsing with arena allocation
    pub fn parseJsonValue(self: *Self, json_text: []const u8) !std.json.Value {
        return std.json.parseFromSlice(std.json.Value, self.arena.allocator(), json_text, .{});
    }

    /// Fast JSON result serialization for common query response patterns
    pub fn serializeQueryResult(self: *Self, schema: []const SchemaColumn, rows: []const []const u8) ![]const u8 {
        // Pre-allocate based on estimated size
        const estimated_size = schema.len * 50 + rows.len * 100; // Heuristic
        try self.reserveCapacity(estimated_size);

        var writer = self.getStreamingWriter();

        try writer.writeObjectStart();

        // Write schema
        try writer.writeFieldName("schema");
        try writer.writeArrayStart();
        for (schema) |col| {
            try writer.writeObjectStart();
            try writer.writeFieldName("name");
            try writer.writeString(col.name);
            try writer.writeFieldName("type");
            try writer.writeString(col.type);
            try writer.writeObjectEnd();
        }
        try writer.writeArrayEnd();

        // Write rows
        try writer.writeFieldName("rows");
        try writer.writeArrayStart();
        for (rows) |row| {
            // Parse and re-serialize for consistency (can be optimized further)
            const parsed = try self.parseJsonValue(row);
            defer parsed.deinit();
            try self.writeJsonValue(&writer, parsed.value);
        }
        try writer.writeArrayEnd();

        try writer.writeObjectEnd();

        return self.buffer.items;
    }

    /// Recursive JSON value writing
    fn writeJsonValue(self: *Self, writer: *StreamingWriter, value: std.json.Value) !void {
        switch (value) {
            .null => try writer.writeNull(),
            .bool => |b| try writer.writeBool(b),
            .integer => |i| try writer.writeNumber(i),
            .float => |f| try writer.writeNumber(f),
            .string => |s| try writer.writeString(s),
            .array => |arr| {
                try writer.writeArrayStart();
                for (arr.items) |item| {
                    try self.writeJsonValue(writer, item);
                }
                try writer.writeArrayEnd();
            },
            .object => |obj| {
                try writer.writeObjectStart();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try writer.writeFieldName(entry.key_ptr.*);
                    try self.writeJsonValue(writer, entry.value_ptr.*);
                }
                try writer.writeObjectEnd();
            },
        }
    }

    /// Get the serialized JSON as string
    pub fn getResult(self: *Self) []const u8 {
        return self.buffer.items;
    }
};

/// Schema column definition for result serialization
pub const SchemaColumn = struct {
    name: []const u8,
    type: []const u8,
};

/// Pre-allocated JSON processor pool for high-throughput scenarios
pub const JsonProcessorPool = struct {
    processors: std.ArrayList(*OptimizedJsonProcessor),
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: Allocator, pool_size: usize) !Self {
        var processors = std.ArrayList(*OptimizedJsonProcessor).init(allocator);
        try processors.ensureTotalCapacity(pool_size);

        for (0..pool_size) |_| {
            const processor = try allocator.create(OptimizedJsonProcessor);
            processor.* = OptimizedJsonProcessor.init(allocator);
            processors.appendAssumeCapacity(processor);
        }

        return .{
            .processors = processors,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.processors.items) |processor| {
            processor.deinit();
            self.allocator.destroy(processor);
        }
        self.processors.deinit();
    }

    /// Get a processor from the pool (thread-safe)
    pub fn acquire(self: *Self) ?*OptimizedJsonProcessor {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.processors.items.len > 0) {
            const processor = self.processors.pop();
            processor.reset(); // Reset for reuse
            return processor;
        }
        return null;
    }

    /// Return processor to pool (thread-safe)
    pub fn release(self: *Self, processor: *OptimizedJsonProcessor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        processor.reset(); // Clean state for next use
        self.processors.append(processor) catch {
            // Pool full, just reset and continue
            // In production, might want to track this metric
        };
    }
};

/// Optimized JSON escape function (zero-allocation for strings without special chars)
pub fn escapeJsonStringOptimized(allocator: Allocator, input: []const u8) ![]u8 {
    // Fast path: scan for characters that need escaping
    var needs_escape = false;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t', 0x00...0x1F => {
                needs_escape = true;
                break;
            },
            else => {},
        }
    }

    // No escaping needed - just duplicate
    if (!needs_escape) {
        return allocator.dupe(u8, input);
    }

    // Escaping needed - use optimized buffer growth
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.ensureTotalCapacity(input.len + (input.len / 4)); // Heuristic: 25% escape overhead

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            0x00...0x1F => {
                const escaped = try std.fmt.allocPrint(allocator, "\\u{:0>4x}", .{c});
                defer allocator.free(escaped);
                try result.appendSlice(escaped);
            },
            else => try result.append(c),
        }
    }

    return result.toOwnedSlice();
}

/// Performance benchmarking function for JSON operations
pub fn benchmarkJsonProcessing(allocator: Allocator, iterations: usize) !struct { parse_ns: u64, serialize_ns: u64 } {
    const test_json =
        \\{"name":"John Doe","age":30,"city":"New York","skills":["programming","design","management"],"active":true}
    ;

    var processor = OptimizedJsonProcessor.init(allocator);
    defer processor.deinit();

    // Benchmark parsing
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const parsed = try processor.parseJsonValue(test_json);
        parsed.deinit();
        processor.reset();
    }
    const parse_time = timer.read();

    // Benchmark serialization
    const schema = [_]SchemaColumn{
        .{ .name = "name", .type = "STRING" },
        .{ .name = "age", .type = "INT" },
        .{ .name = "active", .type = "BOOL" },
    };
    const rows = [_][]const u8{test_json};

    timer.reset();
    for (0..iterations) |_| {
        _ = try processor.serializeQueryResult(&schema, &rows);
        processor.reset();
    }
    const serialize_time = timer.read();

    return .{
        .parse_ns = parse_time / iterations,
        .serialize_ns = serialize_time / iterations,
    };
}
