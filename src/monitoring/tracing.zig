const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        _ = std.c.getrandom(buf.ptr, buf.len, 0);
    }
}
const Allocator = std.mem.Allocator;

// Distributed tracing implementation (OpenTelemetry compatible)
pub const Tracer = struct {
    allocator: Allocator,
    spans: std.ArrayList(Span),
    active_span: ?*Span,
    service_name: []const u8,

    pub const SpanKind = enum {
        internal,
        server,
        client,
        producer,
        consumer,
    };

    pub const SpanStatus = enum {
        unset,
        ok,
        err,
    };

    pub const Span = struct {
        trace_id: [16]u8,
        span_id: [8]u8,
        parent_span_id: ?[8]u8,
        name: []const u8,
        kind: SpanKind,
        start_time: i64,
        end_time: ?i64,
        status: SpanStatus,
        attributes: std.StringHashMap(Attribute),
        events: std.ArrayList(Event),
        links: std.ArrayList(Link),
    };

    pub const Attribute = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,
        string_array: [][]const u8,
        int_array: []i64,
        float_array: []f64,
        bool_array: []bool,
    };

    pub const Event = struct {
        name: []const u8,
        timestamp: i64,
        attributes: std.StringHashMap(Attribute),
    };

    pub const Link = struct {
        trace_id: [16]u8,
        span_id: [8]u8,
        attributes: std.StringHashMap(Attribute),
    };

    pub fn init(allocator: Allocator, service_name: []const u8) Tracer {
        return .{
            .allocator = allocator,
            .spans = std.ArrayList(Span){},
            .active_span = null,
            .service_name = service_name,
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.spans.items) |*span| {
            span.attributes.deinit();
            span.events.deinit();
            span.links.deinit();
        }
        self.spans.deinit();
    }

    // Start a new span
    pub fn startSpan(self: *Tracer, name: []const u8, kind: SpanKind) !*Span {
        var trace_id: [16]u8 = undefined;
        var span_id: [8]u8 = undefined;

        // Generate IDs
        compat_fillRandom(&trace_id);
        compat_fillRandom(&span_id);

        // Get parent span ID if there's an active span
        const parent_span_id = if (self.active_span) |parent|
            parent.span_id
        else
            null;

        const span = Span{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span_id,
            .name = try self.allocator.dupe(u8, name),
            .kind = kind,
            .start_time = std.time.nanoTimestamp(),
            .end_time = null,
            .status = .unset,
            .attributes = std.StringHashMap(Attribute).init(self.allocator),
            .events = std.ArrayList(Event){},
            .links = std.ArrayList(Link){},
        };

        try self.spans.append(span);
        const span_ptr = &self.spans.items[self.spans.items.len - 1];
        self.active_span = span_ptr;

        return span_ptr;
    }

    // End a span
    pub fn endSpan(self: *Tracer, span: *Span) void {
        span.end_time = std.time.nanoTimestamp();

        // Clear active span if it's the one being ended
        if (self.active_span == span) {
            self.active_span = null;
        }
    }

    // Add attribute to span
    pub fn setAttribute(self: *Tracer, span: *Span, key: []const u8, value: Attribute) !void {
        _ = self;
        try span.attributes.put(key, value);
    }

    // Add event to span
    pub fn addEvent(self: *Tracer, span: *Span, name: []const u8, attributes: ?std.StringHashMap(Attribute)) !void {
        const event = Event{
            .name = try self.allocator.dupe(u8, name),
            .timestamp = std.time.nanoTimestamp(),
            .attributes = attributes orelse std.StringHashMap(Attribute).init(self.allocator),
        };

        try span.events.append(event);
    }

    // Set span status
    pub fn setStatus(self: *Tracer, span: *Span, status: SpanStatus, message: ?[]const u8) !void {
        span.status = status;
        if (message) |msg| {
            try self.setAttribute(span, "status.message", .{ .string = msg });
        }
    }

    // Export spans in JSON format (simplified OpenTelemetry format)
    pub fn exportJSON(self: *Tracer, writer: anytype) !void {
        try writer.writeAll("{\"resource_spans\":[{");
        try writer.print("\"resource\":{{\"attributes\":[{{\"key\":\"service.name\",\"value\":{{\"string_value\":\"{}\"}}}}]}},", .{self.service_name});
        try writer.writeAll("\"scope_spans\":[{\"spans\":[");

        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try writer.writeByte(',');

            try writer.writeByte('{');

            // Write trace and span IDs
            try writer.writeAll("\"trace_id\":\"");
            for (span.trace_id) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\"span_id\":\"");
            for (span.span_id) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("\"");

            // Write parent span ID if present
            if (span.parent_span_id) |parent_id| {
                try writer.writeAll(",\"parent_span_id\":\"");
                for (parent_id) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                try writer.writeAll("\"");
            }

            // Write basic fields
            try writer.print(",\"name\":\"{}\",\"kind\":{},\"start_time_unix_nano\":{},", .{
                span.name,
                @intFromEnum(span.kind),
                span.start_time,
            });

            if (span.end_time) |end_time| {
                try writer.print("\"end_time_unix_nano\":{},", .{end_time});
            }

            try writer.print("\"status\":{{\"code\":{}}}", .{@intFromEnum(span.status)});

            // Write attributes
            if (span.attributes.count() > 0) {
                try writer.writeAll(",\"attributes\":[");
                var attr_it = span.attributes.iterator();
                var first = true;
                while (attr_it.next()) |entry| {
                    if (!first) try writer.writeByte(',');
                    first = false;

                    try writer.print("{{\"key\":\"{}\",\"value\":{{", .{entry.key_ptr.*});

                    switch (entry.value_ptr.*) {
                        .string => |s| try writer.print("\"string_value\":\"{}\"", .{s}),
                        .int => |i| try writer.print("\"int_value\":{}", .{i}),
                        .float => |f| try writer.print("\"double_value\":{}", .{f}),
                        .bool => |b| try writer.print("\"bool_value\":{}", .{b}),
                        else => try writer.writeAll("\"string_value\":\"complex\""),
                    }

                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }

            // Write events
            if (span.events.items.len > 0) {
                try writer.writeAll(",\"events\":[");
                for (span.events.items, 0..) |event, j| {
                    if (j > 0) try writer.writeByte(',');
                    try writer.print("{{\"time_unix_nano\":{},\"name\":\"{}\"}}", .{
                        event.timestamp,
                        event.name,
                    });
                }
                try writer.writeByte(']');
            }

            try writer.writeByte('}');
        }

        try writer.writeAll("]}]}]}");
    }
};

// Trace context propagation
pub const TraceContext = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    trace_flags: u8,
    trace_state: ?[]const u8,

    // Parse W3C Trace Context header
    pub fn parseTraceparent(header: []const u8) !TraceContext {
        // Format: version-trace_id-span_id-trace_flags
        // Example: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01

        if (header.len != 55) return error.InvalidFormat;

        var context: TraceContext = undefined;
        context.trace_state = null;

        // Parse version (must be 00)
        if (!std.mem.eql(u8, header[0..2], "00")) return error.UnsupportedVersion;

        // Parse trace ID (32 hex chars)
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const hex = header[3 + i * 2 .. 5 + i * 2];
            context.trace_id[i] = try std.fmt.parseInt(u8, hex, 16);
        }

        // Parse span ID (16 hex chars)
        i = 0;
        while (i < 8) : (i += 1) {
            const hex = header[36 + i * 2 .. 38 + i * 2];
            context.span_id[i] = try std.fmt.parseInt(u8, hex, 16);
        }

        // Parse trace flags (2 hex chars)
        context.trace_flags = try std.fmt.parseInt(u8, header[53..55], 16);

        return context;
    }

    // Format as W3C Trace Context header
    pub fn formatTraceparent(self: TraceContext, writer: anytype) !void {
        try writer.writeAll("00-");
        for (self.trace_id) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeByte('-');
        for (self.span_id) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeByte('-');
        try writer.print("{x:0>2}", .{self.trace_flags});
    }
};
