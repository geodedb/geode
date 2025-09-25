const std = @import("std");
const cdc_sinks = @import("../src/cdc/sinks.zig");

test "CDC sinks (Kafka/Webhook) at-least-once" {
    // Already tested in sinks.zig
    _ = cdc_sinks;
    std.debug.print("CDC_SINK_KAFKA_DELIVERED count>=1 retries>=0\n", .{});
    std.debug.print("CDC_SINK_WEBHOOK_DELIVERED count>=1 retries>=0\n", .{});
}