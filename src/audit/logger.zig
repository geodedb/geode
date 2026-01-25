const std = @import("std");
const events = @import("events.zig");
const config = @import("config.zig");
const filters = @import("filters.zig");
const syslog = @import("syslog.zig");
const file_sink = @import("file_sink.zig");
const time = @import("time.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-001; FEATURE="External Library Migration"; ASPECT=StructuredLogging; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// External structured logging library - slog-style logging with multiple handlers
// Provides JSON output, secret redaction, network sinks, and metrics export
const slog = @import("slog");

/// Create a structured log attribute from an audit event field
pub fn auditAttr(name: []const u8, value: anytype) slog.Attr {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => slog.Attr.int(name, @intCast(value)),
        .pointer => |ptr| blk: {
            if (ptr.size == .Slice and ptr.child == u8) {
                break :blk slog.Attr.string(name, value);
            }
            break :blk slog.Attr.string(name, "unknown");
        },
        .optional => blk: {
            if (value) |v| {
                break :blk auditAttr(name, v);
            }
            break :blk slog.Attr.string(name, "null");
        },
        else => slog.Attr.string(name, "unknown"),
    };
}

pub const AuditLogger = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    clock: time.Clock,
    id_gen: time.IdGen,
    syslog_sender: ?*syslog.SyslogSender,
    file_sink: ?*file_sink.FileSink,

    pub fn init(
        allocator: std.mem.Allocator,
        audit_config: config.Config,
        clock: time.Clock,
        id_gen: time.IdGen,
    ) !*AuditLogger {
        const logger = try allocator.create(AuditLogger);
        errdefer allocator.destroy(logger);

        // Initialize syslog sender
        const syslog_sender = if (audit_config.sinks.syslog.enabled)
            try syslog.SyslogSender.init(
                allocator,
                audit_config.sinks.syslog,
                audit_config.service,
                audit_config.identity.cef,
                clock,
            )
        else
            null;
        errdefer if (syslog_sender) |sender| sender.deinit();

        // Initialize file sink
        const file_sink_inst = if (audit_config.sinks.file.enabled)
            try file_sink.FileSink.init(allocator, audit_config.sinks.file, clock)
        else
            null;
        errdefer if (file_sink_inst) |sink| sink.deinit();

        logger.* = AuditLogger{
            .allocator = allocator,
            .config = audit_config,
            .clock = clock,
            .id_gen = id_gen,
            .syslog_sender = syslog_sender,
            .file_sink = file_sink_inst,
        };

        return logger;
    }

    pub fn deinit(self: *AuditLogger) void {
        if (self.syslog_sender) |sender| {
            sender.deinit();
        }
        if (self.file_sink) |sink| {
            sink.deinit();
        }
        self.config.deinit();
        self.allocator.destroy(self);
    }

    pub fn audit(self: *AuditLogger, ev: *const events.AuditEvent) !void {
        // Clone the event so we can modify it
        var event = try ev.clone(self.allocator);
        defer event.freeCloned(self.allocator);

        // Fill in missing fields
        if (event.ts_unix_ms == 0) {
            event.ts_unix_ms = self.clock.nowMs();
        }

        if (event.trace_id == null) {
            var trace_buf: [32]u8 = undefined;
            self.id_gen.traceId(&trace_buf);
            event.trace_id = trace_buf;
        }

        if (event.span_id == null) {
            var span_buf: [16]u8 = undefined;
            self.id_gen.spanId(&span_buf);
            event.span_id = span_buf;
        }

        // Apply filtering and redaction
        const filtered_metadata = if (event.metadata) |metadata|
            try filters.filterAndRedactMetadata(self.allocator, metadata, &self.config.filters)
        else
            null;

        defer if (filtered_metadata) |*fm| {
            if (fm.* == .object) {
                var iter = fm.object.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    freeJsonValue(self.allocator, entry.value_ptr.*);
                }
                fm.object.deinit();
            }
        };

        // If filtering resulted in dropping the event, log error and return
        if (event.metadata != null and filtered_metadata == null) {
            if (self.file_sink) |sink| {
                try sink.writeError("Event dropped due to unredactable sensitive content");
            }
            return;
        }

        // Update event with filtered metadata
        if (event.metadata) |*original_metadata| {
            original_metadata.deinit(self.allocator);
        }
        if (filtered_metadata) |fm| {
            event.metadata = try self.cloneJsonValue(fm);
        } else {
            event.metadata = null;
        }
        defer if (event.metadata) |*metadata| metadata.deinit(self.allocator);

        // Check message size limit (8 KiB after redaction)
        const test_json = try self.serializeEventForSizeCheck(&event);
        defer self.allocator.free(test_json);

        if (test_json.len > 8192) {
            // Truncate and add suffix
            const truncated = try self.truncateEvent(&event);
            defer self.allocator.free(truncated);

            // Replace event metadata with truncation notice
            if (event.metadata) |*metadata| {
                metadata.deinit(self.allocator);
            }
            var truncation_obj = std.json.ObjectMap.init(self.allocator);
            try truncation_obj.put("_truncated", std.json.Value{ .bool = true });
            try truncation_obj.put("_original_size", std.json.Value{ .integer = @intCast(test_json.len) });
            event.metadata = std.json.Value{ .object = truncation_obj };
        }

        // Send to sinks
        if (self.syslog_sender) |sender| {
            try sender.send(&event);
        }

        if (self.file_sink) |sink| {
            try sink.write(&event, event.metadata);
        }
    }

    fn serializeEventForSizeCheck(self: *AuditLogger, event: *const events.AuditEvent) ![]const u8 {
        // Quick serialization to check size
        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();

        try obj.put("category", std.json.Value{ .string = event.category });
        try obj.put("action", std.json.Value{ .string = event.action });
        try obj.put("actor_id", std.json.Value{ .string = event.actor_id });

        if (event.metadata) |metadata| {
            try obj.put("metadata", metadata);
        }

        const value = std.json.Value{ .object = obj };
        return std.json.stringifyAlloc(self.allocator, value, .{});
    }

    fn truncateEvent(self: *AuditLogger, event: *const events.AuditEvent) ![]const u8 {
        // Create a truncated version with just essential fields
        return std.fmt.allocPrint(self.allocator, "{{\"category\":\"{s}\",\"action\":\"{s}\",\"actor_id\":\"{s}\",\"_msg\":\"...{s}\"}}", .{ event.category, event.action, event.actor_id, "[TRUNCATED]" });
    }

    fn cloneJsonValue(self: *AuditLogger, value: std.json.Value) !std.json.Value {
        return switch (value) {
            .null => .null,
            .bool => |b| std.json.Value{ .bool = b },
            .integer => |i| std.json.Value{ .integer = i },
            .float => |f| std.json.Value{ .float = f },
            .number_string => |ns| std.json.Value{ .number_string = try self.allocator.dupe(u8, ns) },
            .string => |s| std.json.Value{ .string = try self.allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var cloned_array = std.json.Array.init(self.allocator);
                for (arr.items) |item| {
                    try cloned_array.append(try self.cloneJsonValue(item));
                }
                break :blk std.json.Value{ .array = cloned_array };
            },
            .object => |obj| blk: {
                var cloned_map = std.json.ObjectMap.init(self.allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const cloned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const cloned_value = try self.cloneJsonValue(entry.value_ptr.*);
                    try cloned_map.put(cloned_key, cloned_value);
                }
                break :blk std.json.Value{ .object = cloned_map };
            },
        };
    }

    fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
        switch (value) {
            .number_string => |ns| allocator.free(ns),
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| {
                    freeJsonValue(allocator, item);
                }
                arr.deinit();
            },
            .object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

pub fn buildAuditLogger(allocator: std.mem.Allocator, cfg: *const config.Config) !*AuditLogger {
    var sys_clock = time.SystemClock{};
    var sys_id_gen = time.SystemIdGen.init();

    return AuditLogger.init(allocator, cfg.*, sys_clock.clock(), sys_id_gen.idGen());
}

test "audit logger basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_config = try config.loadTestConfig(allocator);
    defer test_config.deinit();

    var fixed_clock = time.FixedClock.init(time.TEST_TIMESTAMP_MS);
    var fixed_id_gen = time.FixedIdGen.init(time.TEST_TRACE_ID, time.TEST_SPAN_ID, time.TEST_REQUEST_ID);

    const logger = try AuditLogger.init(allocator, test_config, fixed_clock.clock(), fixed_id_gen.idGen());
    defer logger.deinit();

    const event = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .success,
        .ts_unix_ms = 0, // Will be filled by logger
        .severity = .INFO,
        .actor_id = "test-user",
        .subject_id = null,
        .request_id = null,
        .session_id = null,
        .source_ip = null,
        .trace_id = null, // Will be filled by logger
        .span_id = null, // Will be filled by logger
        .metadata = null,
    };

    try logger.audit(&event);
}
