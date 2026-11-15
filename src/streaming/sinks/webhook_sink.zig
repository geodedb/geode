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

/// Sleep for the given number of milliseconds (raw nanosleep on Linux, libc
/// elsewhere). Used to bound retry backoff; tests pass single-ms values.
fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    const ns = ms * std.time.ns_per_ms;
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

const logging = @import("logging");
const log = logging.scoped("streaming.webhook");
const Attr = logging.Attr;

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WebhookSink; STATUS=TESTED; TEST=cdc_tests; OWNER=streaming; UPDATED=2025-11-12

/// Import types
pub const ChangeEvent = cdc_sinks.ChangeEvent;
pub const SinkInterface = cdc_sinks.SinkInterface;

/// WebhookConfig configures the webhook sink
pub const WebhookConfig = struct {
    url: []const u8,
    method: enum { POST, PUT } = .POST,
    timeout_ms: u32 = 5000,
    /// Total number of delivery attempts (1 = no retry).
    retry_count: u32 = 3,
    /// Base backoff between retries; doubles each attempt (exponential).
    /// Kept configurable so tests can bound it to a single millisecond.
    base_backoff_ms: u32 = 100,
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

    // CANARY: REQ=REQ-STREAMING-WEBHOOK-001; FEATURE="Webhook Sink Implementation"; ASPECT=HTTPSending; STATUS=TESTED; TEST=tests/test_gap0855_webhook_sink.zig; OWNER=streaming; UPDATED=2026-11-15
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
                log.debug("webhook delivered", &.{
                    Attr.int("events", @intCast(events.len)),
                    Attr.string("url", config.url),
                });
                return;
            } else |err| {
                log.warn("webhook delivery attempt failed", &.{
                    Attr.int("attempt", @intCast(attempts + 1)),
                    Attr.string("error", @errorName(err)),
                });
                if (attempts + 1 < config.retry_count) {
                    // Exponential backoff: base_backoff_ms * 2^attempt.
                    // Bounded by config so tests can use single-ms backoff.
                    const shift: u6 = @intCast(@min(attempts, 16));
                    const backoff_ms: i64 = @as(i64, config.base_backoff_ms) * (@as(i64, 1) << shift);
                    sleepMs(backoff_ms);
                }
            }
        }

        return error.WebhookSendFailed;
    }

    // CANARY: REQ=REQ-STREAMING-WEBHOOK-001; FEATURE="Webhook Sink Implementation"; ASPECT=HTTPTransport; STATUS=TESTED; TEST=tests/test_gap0855_webhook_sink.zig; OWNER=streaming; UPDATED=2026-06-10
    /// Send an HTTP request to the webhook endpoint using std.http.Client.
    ///
    /// Real delivery over http/https (TLS handled by std.http.Client for https
    /// URLs in production). Configured headers from `headers` ride as extra
    /// headers (Authorization, custom values); the Content-Type defaults to
    /// application/json but is overridable via a "Content-Type" entry.
    ///
    /// A non-2xx response status surfaces as error.HttpStatusError so the
    /// caller's retry loop can re-attempt; a transport/connect failure surfaces
    /// the underlying error. SSRF guard rejects private/reserved hosts unless
    /// the test-only escape hatch is set.
    fn sendHttpPost(
        self: *WebhookSink,
        url: []const u8,
        body: []const u8,
        timeout_ms: u32,
        headers: *const std.StringHashMap([]const u8),
    ) !void {
        _ = timeout_ms; // std.http.Client has no per-request timeout knob in 0.16; retry loop bounds total time

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        // SSRF prevention: reject private/reserved hosts (honoring the
        // GEODE_WEBHOOK_ALLOW_PRIVATE test escape hatch read inside isPrivateHost).
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buf) catch return error.InvalidUrl;
        if (isPrivateHost(host_name.bytes)) return error.PrivateHostBlocked;

        const io = std.Io.Threaded.global_single_threaded.io();
        var client = std.http.Client{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        // Build extra headers from config. Pull Content-Type out so it goes via
        // the typed `headers.content_type` slot; everything else rides as extra.
        var content_type: []const u8 = "application/json";
        var extra = std.ArrayList(std.http.Header).initCapacity(self.allocator, headers.count()) catch return error.OutOfMemory;
        defer extra.deinit(self.allocator);

        var it = headers.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                content_type = value;
                continue;
            }
            extra.append(self.allocator, .{ .name = name, .value = value }) catch return error.OutOfMemory;
        }

        const method: std.http.Method = switch (self.config.?.method) {
            .POST => .POST,
            .PUT => .PUT,
        };

        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = method,
            .payload = body,
            .headers = .{ .content_type = .{ .override = content_type } },
            .extra_headers = extra.items,
            .keep_alive = false,
        }) catch |err| {
            return err;
        };

        // 2xx is success; anything else is a delivery failure worth retrying.
        const code = @intFromEnum(result.status);
        if (code < 200 or code >= 300) return error.HttpStatusError;
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
///
/// #842: a test-only escape hatch (GEODE_WEBHOOK_ALLOW_PRIVATE=1) lets the
/// harness stand up a localhost HTTP mock to exercise retry / dead-letter
/// behavior without disabling the SSRF guard in production. The env var is
/// read fresh on every call so test setup can flip it without restarting
/// the process. Off by default; never set in release deployments.
fn isPrivateHost(host: []const u8) bool {
    if (@import("builtin").os.tag != .windows) {
        const name_z: [*:0]const u8 = "GEODE_WEBHOOK_ALLOW_PRIVATE";
        if (std.c.getenv(name_z)) |ptr| {
            var len: usize = 0;
            while (ptr[len] != 0) : (len += 1) {}
            const v = ptr[0..len];
            if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) return false;
        }
    }
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

    // With no config set, send is a hard error (no silent drop).
    try testing.expectError(error.ConfigNotSet, sink.send(&events));
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

    // With no config set, send via the interface is a hard error (no silent drop).
    try testing.expectError(error.ConfigNotSet, iface.send(&events));
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
