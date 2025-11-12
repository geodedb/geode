/// CDC Sink Abstraction Module
///
/// This module provides sink abstractions for Change Data Capture (CDC) events,
/// separating sink implementations from core CDC logic to improve testability
/// and allow for dependency injection.
///
/// Extracted as part of Phase 1, M1.2 of the modularization effort.

const std = @import("std");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Sinks; STATUS=TESTED; TEST=cdc_tests; OWNER=streaming; UPDATED=2025-11-12

/// Import types from cdc_enhanced module
pub const ChangeEvent = @import("cdc_enhanced.zig").ChangeEvent;
pub const CDCSink = @import("cdc_enhanced.zig").CDCSink;

/// SinkInterface defines the interface for CDC event sinks
///
/// All sink implementations must provide these methods for sending
/// CDC events to their respective destinations.
pub const SinkInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Initialize the sink
        init: *const fn (ptr: *anyopaque) anyerror!void,

        /// Clean up sink resources
        deinit: *const fn (ptr: *anyopaque) void,

        /// Send a batch of change events
        send: *const fn (ptr: *anyopaque, events: []const ChangeEvent) anyerror!void,
    };

    pub fn init(self: SinkInterface) !void {
        return self.vtable.init(self.ptr);
    }

    pub fn deinit(self: SinkInterface) void {
        return self.vtable.deinit(self.ptr);
    }

    pub fn send(self: SinkInterface, events: []const ChangeEvent) !void {
        return self.vtable.send(self.ptr, events);
    }
};

/// SinkRegistry manages registered sink implementations
pub const SinkRegistry = struct {
    allocator: std.mem.Allocator,
    sinks: std.StringHashMap(SinkInterface),

    pub fn init(allocator: std.mem.Allocator) SinkRegistry {
        return SinkRegistry{
            .allocator = allocator,
            .sinks = std.StringHashMap(SinkInterface).init(allocator),
        };
    }

    pub fn deinit(self: *SinkRegistry) void {
        var iter = self.sinks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.sinks.deinit();
    }

    pub fn register(self: *SinkRegistry, name: []const u8, sink: SinkInterface) !void {
        try self.sinks.put(name, sink);
    }

    pub fn get(self: *SinkRegistry, name: []const u8) ?SinkInterface {
        return self.sinks.get(name);
    }

    pub fn remove(self: *SinkRegistry, name: []const u8) void {
        if (self.sinks.fetchRemove(name)) |entry| {
            entry.value.deinit();
        }
    }
};

/// MemorySink stores events in memory (for testing)
pub const MemorySink = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(ChangeEvent),

    pub fn init(allocator: std.mem.Allocator) MemorySink {
        return MemorySink{
            .allocator = allocator,
            .events = std.ArrayList(ChangeEvent){},
        };
    }

    pub fn deinit(self: *MemorySink) void {
        self.events.deinit(self.allocator);
    }

    pub fn send(self: *MemorySink, events: []const ChangeEvent) !void {
        for (events) |event| {
            try self.events.append(self.allocator, event);
        }
    }

    pub fn interface(self: *MemorySink) SinkInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .init = initWrapper,
                .deinit = deinitWrapper,
                .send = sendWrapper,
            },
        };
    }

    fn initWrapper(ptr: *anyopaque) !void {
        _ = ptr;
        // Memory sink doesn't need initialization
    }

    fn deinitWrapper(ptr: *anyopaque) void {
        const self: *MemorySink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendWrapper(ptr: *anyopaque, events: []const ChangeEvent) !void {
        const self: *MemorySink = @ptrCast(@alignCast(ptr));
        try self.send(events);
    }
};

/// FileSink writes events to a file
pub const FileSink = struct {
    allocator: std.mem.Allocator,
    file: ?std.fs.File,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileSink {
        return FileSink{
            .allocator = allocator,
            .file = null,
            .path = path,
        };
    }

    pub fn deinit(self: *FileSink) void {
        if (self.file) |f| {
            f.close();
        }
    }

    pub fn send(self: *FileSink, events: []const ChangeEvent) !void {
        // Lazy initialization
        if (self.file == null) {
            self.file = try std.fs.cwd().createFile(self.path, .{
                .truncate = false,
            });
            try self.file.?.seekFromEnd(0);
        }

        for (events) |event| {
            var buf: [1024]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"{s}\",\"entity\":\"{s}\",\"id\":{d}}}\n", .{
                event.sequence,
                @tagName(event.change_type),
                @tagName(event.entity_type),
                event.entity_id,
            });
            try self.file.?.writeAll(line);
        }
    }

    pub fn interface(self: *FileSink) SinkInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .init = initWrapper,
                .deinit = deinitWrapper,
                .send = sendWrapper,
            },
        };
    }

    fn initWrapper(ptr: *anyopaque) !void {
        _ = ptr;
        // File sink uses lazy initialization
    }

    fn deinitWrapper(ptr: *anyopaque) void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendWrapper(ptr: *anyopaque, events: []const ChangeEvent) !void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        try self.send(events);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MemorySink - stores events in memory" {
    const testing = std.testing;

    var sink = MemorySink.init(testing.allocator);
    defer sink.deinit();

    const events = [_]ChangeEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .insert,
            .entity_type = .node,
            .entity_id = 100,
            .before = null,
            .after = "{}",
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    try sink.send(&events);
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try testing.expectEqual(@as(u64, 1), sink.events.items[0].sequence);
}

test "FileSink - writes events to file" {
    const testing = std.testing;

    var sink = try FileSink.init(testing.allocator, "test_cdc_sink.log");
    defer sink.deinit();

    const events = [_]ChangeEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .insert,
            .entity_type = .node,
            .entity_id = 100,
            .before = null,
            .after = "{}",
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    try sink.send(&events);

    // Verify file exists
    const file = try std.fs.cwd().openFile("test_cdc_sink.log", .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expect(stat.size > 0);

    // Cleanup
    try std.fs.cwd().deleteFile("test_cdc_sink.log");
}

test "SinkRegistry - register and retrieve sinks" {
    const testing = std.testing;

    var registry = SinkRegistry.init(testing.allocator);
    defer registry.deinit();

    var mem_sink = MemorySink.init(testing.allocator);
    try registry.register("memory", mem_sink.interface());

    const retrieved = registry.get("memory");
    try testing.expect(retrieved != null);
}

test "SinkInterface - polymorphic sink access" {
    const testing = std.testing;

    var sink = MemorySink.init(testing.allocator);
    defer sink.deinit();

    var iface = sink.interface();
    try iface.init();

    const events = [_]ChangeEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .update,
            .entity_type = .edge,
            .entity_id = 200,
            .before = "{}",
            .after = "{\"updated\":true}",
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    try iface.send(&events);
    try testing.expectEqual(@as(usize, 1), sink.events.items.len);

    // Note: sink.deinit() is called by defer, don't call iface.deinit() which would double-free
}
