/// Webhook Sink Implementation
///
/// This module provides a webhook-based sink for CDC events, sending
/// change events to HTTP endpoints via webhooks.
///
/// Extracted as part of Phase 1, M1.2 of the modularization effort.
const std = @import("std");
const cdc_sinks = @import("../cdc_sinks.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WebhookSink; STATUS=TESTED; TEST=cdc_tests; OWNER=streaming; UPDATED=2025-11-12

/// Import types
pub const ChangeEvent = cdc_sinks.ChangeEvent;
pub const SinkInterface = cdc_sinks.SinkInterface;

/// WebhookConfig configures the webhook sink
pub const WebhookConfig = struct {
    url: []const u8,
    timeout_ms: u32 = 5000,
    retry_count: u32 = 3,
    headers: std.StringHashMap([]const u8),
};

/// WebhookSink sends CDC events to HTTP webhooks
pub const WebhookSink = struct {
    allocator: std.mem.Allocator,
    config: ?WebhookConfig,

    pub fn init(allocator: std.mem.Allocator) WebhookSink {
        return WebhookSink{
            .allocator = allocator,
            .config = null,
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: WebhookConfig) WebhookSink {
        return WebhookSink{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *WebhookSink) void {
        // Note: We don't deinit config.headers because the config is owned by the caller
        // The caller is responsible for deinit'ing any resources in the config
        _ = self;
    }

    // CANARY: REQ=REQ-STREAMING-WEBHOOK-001; FEATURE="Webhook Sink Implementation"; ASPECT=HTTPSending; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=streaming; UPDATED=2025-12-30
    /// Send events to webhook endpoint via HTTP POST with retry logic
    pub fn send(self: *WebhookSink, events: []const ChangeEvent) !void {
        if (events.len == 0) return;

        const config = self.config orelse return error.ConfigNotSet;

        // Build JSON payload for all events
        var payload = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "[");
        for (events, 0..) |event, i| {
            if (i > 0) try payload.appendSlice(self.allocator, ",");

            try std.fmt.format(payload.writer(self.allocator), "{{\"seq\":{d},\"txn\":{d},\"type\":\"{s}\",\"entity\":\"{s}\",\"id\":{d},\"ts\":{d}", .{
                event.sequence,
                event.transaction_id,
                @tagName(event.change_type),
                @tagName(event.entity_type),
                event.entity_id,
                event.timestamp,
            });

            if (event.before) |before| {
                try std.fmt.format(payload.writer(self.allocator), ",\"before\":{s}", .{before});
            }
            if (event.after) |after| {
                try std.fmt.format(payload.writer(self.allocator), ",\"after\":{s}", .{after});
            }
            try payload.appendSlice(self.allocator, "}");
        }
        try payload.appendSlice(self.allocator, "]");

        // Retry logic
        var attempts: u32 = 0;
        while (attempts < config.retry_count) : (attempts += 1) {
            if (self.sendHttpPost(config.url, payload.items, config.timeout_ms, &config.headers)) {
                std.debug.print("WEBHOOK_SINK events_sent={d} url={s}\n", .{ events.len, config.url });
                return;
            } else |err| {
                std.debug.print("WEBHOOK_SINK: Attempt {d} failed: {}\n", .{ attempts + 1, err });
                if (attempts + 1 < config.retry_count) {
                    // Exponential backoff
                    std.Thread.sleep(@as(u64, 100_000_000) * (@as(u64, 1) << @intCast(attempts)));
                }
            }
        }

        return error.WebhookSendFailed;
    }

    /// Send HTTP POST request to webhook endpoint
    fn sendHttpPost(
        self: *WebhookSink,
        url: []const u8,
        body: []const u8,
        timeout_ms: u32,
        headers: *const std.StringHashMap([]const u8),
    ) !void {
        _ = timeout_ms; // Would be used with proper HTTP client timeout

        // Parse URL to get host, port, and path using uri library
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        // Extract host from Component union
        const host_component = uri.host orelse return error.NoHost;
        const host: []const u8 = switch (host_component) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
        const scheme = uri.scheme;
        const port: u16 = uri.port orelse if (std.mem.eql(u8, scheme, "https")) @as(u16, 443) else @as(u16, 80);
        // Extract path from Component union
        const path_raw: []const u8 = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        const path = if (path_raw.len > 0) path_raw else "/";

        // Connect using tcpConnectToHost
        var stream = std.net.tcpConnectToHost(self.allocator, host, port) catch return error.CannotConnect;
        defer stream.close();

        // Build HTTP request
        var request_buffer = std.ArrayList(u8).initCapacity(self.allocator, 512) catch return error.OutOfMemory;
        defer request_buffer.deinit(self.allocator);

        // Request line
        try std.fmt.format(request_buffer.writer(self.allocator), "POST {s} HTTP/1.1\r\n", .{path});
        try std.fmt.format(request_buffer.writer(self.allocator), "Host: {s}\r\n", .{host});
        try std.fmt.format(request_buffer.writer(self.allocator), "Content-Type: application/json\r\n", .{});
        try std.fmt.format(request_buffer.writer(self.allocator), "Content-Length: {d}\r\n", .{body.len});
        try std.fmt.format(request_buffer.writer(self.allocator), "Connection: close\r\n", .{});
        try std.fmt.format(request_buffer.writer(self.allocator), "User-Agent: geode-cdc/1.0\r\n", .{});

        // Custom headers
        var header_iter = headers.iterator();
        while (header_iter.next()) |entry| {
            try std.fmt.format(request_buffer.writer(self.allocator), "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try request_buffer.appendSlice(self.allocator, "\r\n");
        try request_buffer.appendSlice(self.allocator, body);

        // Send request
        _ = try stream.write(request_buffer.items);

        // Read response
        var response_buffer: [4096]u8 = undefined;
        const bytes_read = stream.read(&response_buffer) catch return error.ReadFailed;
        if (bytes_read < 12) return error.InvalidResponse;

        // Parse HTTP response status
        const response = response_buffer[0..bytes_read];
        if (!std.mem.startsWith(u8, response, "HTTP/")) return error.InvalidResponse;

        // Find status code (after "HTTP/1.1 ")
        const status_start = std.mem.indexOf(u8, response, " ") orelse return error.InvalidResponse;
        const status_end = std.mem.indexOfPos(u8, response, status_start + 1, " ") orelse return error.InvalidResponse;
        const status_code = std.fmt.parseInt(u16, response[status_start + 1 .. status_end], 10) catch return error.InvalidResponse;

        // Check for success (2xx status codes)
        if (status_code < 200 or status_code >= 300) {
            std.debug.print("WEBHOOK_SINK: HTTP error {d}\n", .{status_code});
            return error.HttpError;
        }
    }

    pub fn interface(self: *WebhookSink) SinkInterface {
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
        // Webhook sink initialization handled in init()
    }

    fn deinitWrapper(ptr: *anyopaque) void {
        const self: *WebhookSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendWrapper(ptr: *anyopaque, events: []const ChangeEvent) !void {
        const self: *WebhookSink = @ptrCast(@alignCast(ptr));
        try self.send(events);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "WebhookSink - basic initialization" {
    const testing = std.testing;

    var sink = WebhookSink.init(testing.allocator);
    defer sink.deinit();

    try testing.expect(sink.config == null);
}

test "WebhookSink - init with config" {
    const testing = std.testing;

    var headers = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers.deinit();
    try headers.put("Authorization", "Bearer token");

    const config = WebhookConfig{
        .url = "https://example.com/webhook",
        .timeout_ms = 3000,
        .retry_count = 2,
        .headers = headers,
    };

    var sink = WebhookSink.initWithConfig(testing.allocator, config);
    defer sink.deinit();

    try testing.expect(sink.config != null);
    try testing.expectEqual(@as(u32, 3000), sink.config.?.timeout_ms);
}

test "WebhookSink - send events" {
    const testing = std.testing;

    var sink = WebhookSink.init(testing.allocator);
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

    // Should not error even though it's a placeholder implementation
    try sink.send(&events);
}

test "WebhookSink - interface implementation" {
    const testing = std.testing;

    var sink = WebhookSink.init(testing.allocator);
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
    iface.deinit();
}
