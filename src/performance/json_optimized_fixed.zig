const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-PERF-JSON-001; FEATURE="OptimizedJSON"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_OptimizedJSON; OWNER=performance; UPDATED=2025-10-04
// CANARY: REQ=REQ-QUALITY-GAP-413-001; FEATURE="OrphanedTestFix"; ASPECT=API; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// Updated for Zig 0.15 ArrayList API - all methods now require allocator parameter

/// High-performance JSON serialization system with arena allocators and streaming support
/// Addresses 630μs JSON parsing bottleneck (31x slower than target) identified in performance analysis
pub const OptimizedJsonProcessor = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 256),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Reset for reuse (arena pattern for zero-allocation subsequent uses)
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Pre-allocate buffer for expected JSON size (eliminates reallocations)
    pub fn reserveCapacity(self: *Self, capacity: usize) !void {
        try self.buffer.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Streaming JSON writer for large result sets
    ///
    /// SONNY-2394: separator state is tracked per open container. The old
    /// writer had one `first_item` flag that writeFieldName cleared, so the
    /// value after a key got a leading comma (`{"name":,"Alice"}`), and object
    /// starts never reset it -- every object with a field produced invalid
    /// JSON. Now: `after_key` suppresses the separator for a member's value,
    /// and each container start saves the enclosing container's `first_item`
    /// (restored at its end).
    pub const StreamingWriter = struct {
        buffer: *std.ArrayList(u8),
        allocator: Allocator,
        arena_allocator: Allocator,
        /// True until the first element/member of the innermost open container
        /// (or the top-level value) has been written.
        first_item: bool = true,
        /// Set by writeFieldName: the next value belongs to that key.
        after_key: bool = false,
        /// Saved `first_item` of the enclosing containers.
        nesting: [max_depth]bool = undefined,
        depth: usize = 0,

        const max_depth = 64;

        /// Separator handling shared by every value (containers included).
        fn beginValue(self: *StreamingWriter) !void {
            if (self.after_key) {
                self.after_key = false;
                return;
            }
            if (!self.first_item) {
                try self.buffer.append(self.allocator, ',');
            }
            self.first_item = false;
        }

        fn openContainer(self: *StreamingWriter, open: u8) !void {
            try self.beginValue();
            if (self.depth == max_depth) return error.NestingTooDeep;
            self.nesting[self.depth] = self.first_item;
            self.depth += 1;
            try self.buffer.append(self.allocator, open);
            self.first_item = true;
        }

        fn closeContainer(self: *StreamingWriter, close: u8) !void {
            if (self.depth == 0 or self.after_key) return error.UnbalancedContainer;
            try self.buffer.append(self.allocator, close);
            self.depth -= 1;
            self.first_item = self.nesting[self.depth];
        }

        pub fn writeObjectStart(self: *StreamingWriter) !void {
            try self.openContainer('{');
        }

        pub fn writeObjectEnd(self: *StreamingWriter) !void {
            try self.closeContainer('}');
        }

        pub fn writeArrayStart(self: *StreamingWriter) !void {
            try self.openContainer('[');
        }

        pub fn writeArrayEnd(self: *StreamingWriter) !void {
            try self.closeContainer(']');
        }

        pub fn writeFieldName(self: *StreamingWriter, name: []const u8) !void {
            if (!self.first_item) {
                try self.buffer.append(self.allocator, ',');
            }
            self.first_item = false;
            try self.buffer.append(self.allocator, '"');
            try self.writeEscapedString(name);
            try self.buffer.appendSlice(self.allocator, "\":");
            self.after_key = true;
        }

        pub fn writeString(self: *StreamingWriter, value: []const u8) !void {
            try self.beginValue();
            try self.buffer.append(self.allocator, '"');
            try self.writeEscapedString(value);
            try self.buffer.append(self.allocator, '"');
        }

        pub fn writeNumber(self: *StreamingWriter, value: anytype) !void {
            try self.beginValue();
            const formatted = try std.fmt.allocPrint(self.arena_allocator, "{}", .{value});
            try self.buffer.appendSlice(self.allocator, formatted);
        }

        pub fn writeBool(self: *StreamingWriter, value: bool) !void {
            try self.beginValue();
            try self.buffer.appendSlice(self.allocator, if (value) "true" else "false");
        }

        pub fn writeNull(self: *StreamingWriter) !void {
            try self.beginValue();
            try self.buffer.appendSlice(self.allocator, "null");
        }

        fn writeEscapedString(self: *StreamingWriter, input: []const u8) !void {
            for (input) |c| {
                switch (c) {
                    '"' => try self.buffer.appendSlice(self.allocator, "\\\""),
                    '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                    '\n' => try self.buffer.appendSlice(self.allocator, "\\n"),
                    '\r' => try self.buffer.appendSlice(self.allocator, "\\r"),
                    '\t' => try self.buffer.appendSlice(self.allocator, "\\t"),
                    else => try self.buffer.append(self.allocator, c),
                }
            }
        }
    };

    /// Get streaming writer for incremental JSON building
    pub fn getStreamingWriter(self: *Self) StreamingWriter {
        return .{
            .buffer = &self.buffer,
            .allocator = self.allocator,
            .arena_allocator = self.arena.allocator(),
        };
    }

    /// Optimized JSON parsing with arena allocation (returns parsed wrapper)
    pub fn parseJsonValue(self: *Self, json_text: []const u8) !std.json.Parsed(std.json.Value) {
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
            .number_string => |s| try writer.writeString(s),
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
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    const Self = @This();

    pub fn init(allocator: Allocator, pool_size: usize) !Self {
        var processors = try std.ArrayList(*OptimizedJsonProcessor).initCapacity(allocator, pool_size);
        errdefer processors.deinit(allocator);

        for (0..pool_size) |_| {
            const processor = try allocator.create(OptimizedJsonProcessor);
            processor.* = try OptimizedJsonProcessor.init(allocator);
            try processors.append(allocator, processor);
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
        self.processors.deinit(self.allocator);
    }

    /// Get a processor from the pool (thread-safe)
    pub fn acquire(self: *Self) ?*OptimizedJsonProcessor {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.processors.items.len > 0) {
            const processor = self.processors.pop();
            if (processor) |p| {
                p.reset(); // Reset for reuse
                return p;
            }
        }
        return null;
    }

    /// Return processor to pool (thread-safe)
    pub fn release(self: *Self, processor: *OptimizedJsonProcessor) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        processor.reset(); // Clean state for next use
        self.processors.append(self.allocator, processor) catch {
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
            '"', '\\', '\n', '\r', '\t' => {
                needs_escape = true;
                break;
            },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
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
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len + (input.len / 4)); // Heuristic: 25% escape overhead
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var hex_buf: [6]u8 = undefined;
                const hex_slice = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch continue;
                try result.appendSlice(allocator, hex_slice);
            },
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}
