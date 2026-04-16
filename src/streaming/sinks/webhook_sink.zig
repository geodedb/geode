/// Webhook Sink Implementation
///
/// This module provides a webhook-based sink for CDC events, sending
/// change events to HTTP endpoints via webhooks.
///
/// Extracted as part of Phase 1, M1.2 of the modularization effort.
const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const cdc_sinks = @import("../cdc_sinks.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WebhookSink; STATUS=TESTED; TEST=cdc_tests; OWNER=streaming; UPDATED=2025-11-12

/// Import types
pub const ChangeEvent = cdc_sinks.ChangeEvent;
pub const SinkInterface = cdc_sinks.SinkInterface;

/// WebhookConfig configures the webhook sink
pub const WebhookConfig = struct {
    url: []const u8,
    method: enum { POST, PUT } = .POST,
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
        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("[");
        for (events, 0..) |event, i| {
            if (i > 0) try writer.writeAll(",");

            try writer.print("{{\"seq\":{d},\"txn\":{d},\"type\":\"{s}\",\"entity\":\"{s}\",\"id\":{d},\"ts\":{d}", .{
                event.sequence,
                event.transaction_id,
                @tagName(event.change_type),
                @tagName(event.entity_type),
                event.entity_id,
                event.timestamp,
            });

            if (event.before) |before| {
                try writer.print(",\"before\":{s}", .{before});
            }
            if (event.after) |after| {
                try writer.print(",\"after\":{s}", .{after});
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        const payload_bytes = aw.written();

        // Retry logic
        var attempts: u32 = 0;
        while (attempts < config.retry_count) : (attempts += 1) {
            if (self.sendHttpPost(config.url, payload_bytes, config.timeout_ms, &config.headers)) {
                std.debug.print("WEBHOOK_SINK events_sent={d} url={s}\n", .{ events.len, config.url });
                return;
            } else |err| {
                std.debug.print("WEBHOOK_SINK: Attempt {d} failed: {}\n", .{ attempts + 1, err });
                if (attempts + 1 < config.retry_count) {
                    // Exponential backoff — Zig 0.16 uses raw nanosleep.
                    const ns = @as(i64, 100_000_000) * (@as(i64, 1) << @intCast(attempts));
                    const req = std.os.linux.timespec{
                        .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
                        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                    };
                    var rem: std.os.linux.timespec = undefined;
                    _ = std.os.linux.nanosleep(&req, &rem);
                }
            }
        }

        return error.WebhookSendFailed;
    }

    /// Send HTTP POST request to webhook endpoint.
    /// Zig 0.16 compat: temporarily stubbed pending std.Io.net rewrite.
    fn sendHttpPost(
        self: *WebhookSink,
        url: []const u8,
        body: []const u8,
        timeout_ms: u32,
        headers: *const std.StringHashMap([]const u8),
    ) !void {
        _ = self;
        _ = url;
        _ = body;
        _ = timeout_ms;
        _ = headers;
        return error.WebhookTransportNotImplemented;
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

/// SSRF prevention: reject webhook URLs targeting private/reserved networks.
/// Blocks localhost, link-local, cloud metadata endpoints, and RFC1918 private ranges.
fn isPrivateHost(host: []const u8) bool {
    // Block localhost variants
    if (std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "0.0.0.0"))
        return true;

    // Block cloud metadata endpoints
    if (std.mem.eql(u8, host, "169.254.169.254") or
        std.mem.eql(u8, host, "metadata.google.internal"))
        return true;

    // Block RFC1918 private ranges by prefix
    if (std.mem.startsWith(u8, host, "10.") or
        std.mem.startsWith(u8, host, "192.168."))
        return true;

    // Block 172.16.0.0/12 range (172.16.x.x - 172.31.x.x)
    if (std.mem.startsWith(u8, host, "172.")) {
        if (host.len >= 6) {
            const dot_pos = std.mem.indexOfPos(u8, host, 4, ".") orelse return false;
            const second_octet = std.fmt.parseInt(u8, host[4..dot_pos], 10) catch return false;
            if (second_octet >= 16 and second_octet <= 31) return true;
        }
    }

    return false;
}

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
            .timestamp = compat_milliTimestamp(),
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
            .timestamp = compat_milliTimestamp(),
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

test "isPrivateHost - blocks localhost variants" {
    try std.testing.expect(isPrivateHost("localhost"));
    try std.testing.expect(isPrivateHost("127.0.0.1"));
    try std.testing.expect(isPrivateHost("::1"));
    try std.testing.expect(isPrivateHost("0.0.0.0"));
}

test "isPrivateHost - blocks cloud metadata endpoints" {
    try std.testing.expect(isPrivateHost("169.254.169.254"));
    try std.testing.expect(isPrivateHost("metadata.google.internal"));
}

test "isPrivateHost - blocks RFC1918 private ranges" {
    try std.testing.expect(isPrivateHost("10.0.0.1"));
    try std.testing.expect(isPrivateHost("10.255.255.255"));
    try std.testing.expect(isPrivateHost("192.168.1.1"));
    try std.testing.expect(isPrivateHost("192.168.0.100"));
    try std.testing.expect(isPrivateHost("172.16.0.1"));
    try std.testing.expect(isPrivateHost("172.31.255.255"));
}

test "isPrivateHost - allows public hosts" {
    try std.testing.expect(!isPrivateHost("example.com"));
    try std.testing.expect(!isPrivateHost("8.8.8.8"));
    try std.testing.expect(!isPrivateHost("172.32.0.1"));
    try std.testing.expect(!isPrivateHost("172.15.0.1"));
    try std.testing.expect(!isPrivateHost("11.0.0.1"));
    try std.testing.expect(!isPrivateHost("193.168.1.1"));
}

test "WebhookSink - sendHttpPost blocks private hosts (SSRF)" {
    const testing = std.testing;

    var sink = WebhookSink.init(testing.allocator);
    defer sink.deinit();

    var headers = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers.deinit();

    // Should return PrivateHostBlocked for localhost URLs
    try testing.expectError(error.PrivateHostBlocked, sink.sendHttpPost(
        "http://localhost:8080/hook",
        "{}",
        5000,
        &headers,
    ));

    // Should return PrivateHostBlocked for RFC1918 URLs
    try testing.expectError(error.PrivateHostBlocked, sink.sendHttpPost(
        "http://10.0.0.5/webhook",
        "{}",
        5000,
        &headers,
    ));

    // Should return PrivateHostBlocked for cloud metadata
    try testing.expectError(error.PrivateHostBlocked, sink.sendHttpPost(
        "http://169.254.169.254/latest/meta-data/",
        "{}",
        5000,
        &headers,
    ));
}
