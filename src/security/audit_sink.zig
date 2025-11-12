/// Audit Sink Abstraction Module
///
/// This module provides I/O abstractions for audit event output, separating
/// the I/O concerns from core audit logic to improve testability and allow
/// for dependency injection.
///
/// Extracted as part of Phase 1, M1.1 of the modularization effort.

const std = @import("std");
const audit_formatter = @import("audit_formatter.zig");

// CANARY: REQ=REQ-GQL-031; FEATURE="Security Audit"; ASPECT=AuditSinks; STATUS=TESTED; TEST=audit_tests; OWNER=security; UPDATED=2025-11-12

/// Import types from audit module
pub const AuditEvent = @import("audit.zig").AuditEvent;

/// SinkInterface defines the interface for audit event sinks
///
/// Implementations of this interface can write formatted audit events
/// to various destinations (files, databases, remote services, etc.)
pub const SinkInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write a single formatted audit event
        write: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,

        /// Flush any buffered data
        flush: *const fn (ptr: *anyopaque) anyerror!void,

        /// Close the sink and release resources
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: SinkInterface, data: []const u8) !void {
        return self.vtable.write(self.ptr, data);
    }

    pub fn flush(self: SinkInterface) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn close(self: SinkInterface) void {
        return self.vtable.close(self.ptr);
    }
};

/// FileSink writes audit events to a file
pub const FileSink = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex,

    pub fn init(file_path: []const u8) !FileSink {
        const file = try std.fs.cwd().createFile(file_path, .{
            .truncate = false,
            .exclusive = false,
        });
        try file.seekFromEnd(0); // Append to end

        return FileSink{
            .file = file,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *FileSink) void {
        self.file.close();
    }

    pub fn interface(self: *FileSink) SinkInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .close = close,
            },
        };
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.file.writeAll(data);
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.file.sync();
    }

    fn close(ptr: *anyopaque) void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        self.file.close();
    }
};

/// Write events to Windows Event Log format file
///
/// This function writes audit events to a Windows Event Log XML file,
/// using the formatter module to format each event.
pub fn writeToWindowsEventLog(
    events: []const AuditEvent,
    allocator: std.mem.Allocator,
    output_path: []const u8,
) !u32 {
    var events_written: u32 = 0;

    // Create output file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    // Write XML header
    try file.writeAll("<?xml version='1.0' encoding='UTF-8'?>\n");
    try file.writeAll("<Events>\n");

    // Write each event
    for (events) |event| {
        const formatted = try audit_formatter.formatWindowsEventLog(event, allocator);
        defer allocator.free(formatted);
        try file.writeAll(formatted);
        events_written += 1;
    }

    // Write XML footer
    try file.writeAll("</Events>\n");

    std.debug.print("WINDOWS_EVENTLOG events_written={d} file={s}\n", .{ events_written, output_path });

    return events_written;
}

/// Write events to Syslog format file
///
/// This function writes audit events to a syslog format file,
/// using the formatter module to format each event.
pub fn writeToSyslog(
    events: []const AuditEvent,
    allocator: std.mem.Allocator,
    output_path: []const u8,
) !u32 {
    var events_sent: u32 = 0;

    // Create output file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    // Write each event
    for (events) |event| {
        const formatted = try audit_formatter.formatSyslog(event, allocator);
        defer allocator.free(formatted);
        try file.writeAll(formatted);
        try file.writeAll("\n");
        events_sent += 1;
    }

    std.debug.print("SYSLOG_OUTPUT events_sent={d} facility=local0 file={s}\n", .{ events_sent, output_path });

    return events_sent;
}

/// MultiSink writes to multiple sinks simultaneously
pub const MultiSink = struct {
    sinks: std.ArrayList(SinkInterface),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !MultiSink {
        return MultiSink{
            .sinks = try std.ArrayList(SinkInterface).initCapacity(allocator, 4),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiSink) void {
        // Note: We don't close the sinks here because they're owned by the caller
        // The caller is responsible for closing/deinit'ing the individual sinks
        self.sinks.deinit(self.allocator);
    }

    pub fn addSink(self: *MultiSink, sink: SinkInterface) !void {
        try self.sinks.append(self.allocator, sink); // append expects allocator first
    }

    pub fn interface(self: *MultiSink) SinkInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .close = close,
            },
        };
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *MultiSink = @ptrCast(@alignCast(ptr));
        for (self.sinks.items) |sink| {
            try sink.write(data);
        }
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *MultiSink = @ptrCast(@alignCast(ptr));
        for (self.sinks.items) |sink| {
            try sink.flush();
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *MultiSink = @ptrCast(@alignCast(ptr));
        for (self.sinks.items) |sink| {
            sink.close();
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FileSink - basic write" {
    const testing = std.testing;

    var sink = try FileSink.init("test_audit_sink.log");
    defer sink.deinit();

    var iface = sink.interface();
    try iface.write("Test audit event 1\n");
    try iface.write("Test audit event 2\n");
    try iface.flush();

    // Verify file was created
    const file = try std.fs.cwd().openFile("test_audit_sink.log", .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expect(stat.size > 0);

    // Cleanup
    try std.fs.cwd().deleteFile("test_audit_sink.log");
}

test "writeToWindowsEventLog - creates valid XML" {
    const testing = std.testing;

    const test_events = [_]AuditEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .access_granted,
            .user_id = 1001,
            .tenant_id = null,
            .resource = "database.users",
            .action = "SELECT",
            .policy_id = null,
            .reason = null,
            .ip_address = null,
            .session_id = "test-session",
            .query_hash = null,
            .additional_context = null,
        },
    };

    const events_written = try writeToWindowsEventLog(&test_events, testing.allocator, "test_windows.xml");
    try testing.expectEqual(@as(u32, 1), events_written);

    // Verify file exists and contains valid XML
    const file = try std.fs.cwd().openFile("test_windows.xml", .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 10000);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "<?xml version") != null);
    try testing.expect(std.mem.indexOf(u8, content, "<Events>") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</Events>") != null);

    // Cleanup
    try std.fs.cwd().deleteFile("test_windows.xml");
}

test "writeToSyslog - creates valid syslog entries" {
    const testing = std.testing;

    const test_events = [_]AuditEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .policy_violation,
            .user_id = 2001,
            .tenant_id = null,
            .resource = "sensitive_data",
            .action = "ACCESS",
            .policy_id = null,
            .reason = "Outside business hours",
            .ip_address = null,
            .session_id = null,
            .query_hash = null,
            .additional_context = null,
        },
    };

    const events_sent = try writeToSyslog(&test_events, testing.allocator, "test_syslog.log");
    try testing.expectEqual(@as(u32, 1), events_sent);

    // Verify file exists and contains syslog format
    const file = try std.fs.cwd().openFile("test_syslog.log", .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 10000);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "<") != null); // Priority
    try testing.expect(std.mem.indexOf(u8, content, "event_type=policy_violation") != null);

    // Cleanup
    try std.fs.cwd().deleteFile("test_syslog.log");
}

test "MultiSink - writes to multiple destinations" {
    const testing = std.testing;

    var sink1 = try FileSink.init("test_multi1.log");
    defer sink1.deinit();

    var sink2 = try FileSink.init("test_multi2.log");
    defer sink2.deinit();

    var multi = try MultiSink.init(testing.allocator);
    defer multi.deinit();

    try multi.addSink(sink1.interface());
    try multi.addSink(sink2.interface());

    var iface = multi.interface();
    try iface.write("Test event to multiple sinks\n");
    try iface.flush();

    // Verify both files exist and contain data
    const file1 = try std.fs.cwd().openFile("test_multi1.log", .{});
    defer file1.close();
    const stat1 = try file1.stat();
    try testing.expect(stat1.size > 0);

    const file2 = try std.fs.cwd().openFile("test_multi2.log", .{});
    defer file2.close();
    const stat2 = try file2.stat();
    try testing.expect(stat2.size > 0);

    // Cleanup
    try std.fs.cwd().deleteFile("test_multi1.log");
    try std.fs.cwd().deleteFile("test_multi2.log");
}
