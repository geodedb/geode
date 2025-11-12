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
        if (self.config) |*cfg| {
            cfg.headers.deinit();
        }
    }

    /// Send events to webhook endpoint
    pub fn send(self: *WebhookSink, events: []const ChangeEvent) !void {
        _ = self;

        // TODO: Implement HTTP webhook sending
        // This would use an HTTP client to POST events to the configured URL
        // For now, this is a placeholder implementation
        std.debug.print("WEBHOOK_SINK events_sent={d}\n", .{events.len});
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
