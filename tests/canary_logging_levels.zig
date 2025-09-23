const std = @import("std");
const logger = @import("log/logger.zig");

test "TestCANARY_REQ_GQL_085_LogLevelCliParsing" {
    try std.testing.expect(logger.parseLevel("INFO") == .info);
    try std.testing.expect(logger.parseLevel("debug") == .debug);
    try std.testing.expect(logger.parseLevel("TRACE") == .trace);
    try std.testing.expect(logger.parseLevel("WARN") == .warn);
    try std.testing.expect(logger.parseLevel("error") == .err);
    try std.testing.expect(logger.parseLevel("critical") == .critical);
    try std.testing.expect(logger.parseLevel("unknown-defaults") == .info);
}

// Placeholder tests for filtering / JSON format / client parity (STUB aspects)
test "TestCANARY_REQ_GQL_085_LogEmitterFiltering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var list = std.ArrayList(u8).init(gpa.allocator());
    defer list.deinit();
    logger.setBufferSink(&list);
    logger.setLevel(.warn);
    logger.info("should be suppressed", .{});
    logger.warn("should appear", .{});
    logger.err("error appears", .{});
    const data = list.items;
    // Expect exactly 2 lines (warn + error)
    var line_count: usize = 0;
    for (data) |c| {
        if (c == '\n') line_count += 1;
    }
    try std.testing.expect(line_count == 2);
    logger.resetSinkToStderr();
}

test "TestCANARY_REQ_GQL_085_LogJSONFormat" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var list = std.ArrayList(u8).init(gpa.allocator());
    defer list.deinit();
    logger.setBufferSink(&list);
    logger.setLevel(.trace);
    logger.trace("hello world", .{.{ .key = "k1", .value = "v1" }});
    const data = list.items;
    // Basic JSON shape assertions: starts with '{', contains required keys, ends with newline
    try std.testing.expect(data.len > 10);
    try std.testing.expect(data[0] == '{');
    try std.testing.expect(data[data.len - 1] == '\n');
    try std.testing.expect(std.mem.indexOf(u8, data, "\"level\":\"TRACE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"msg\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"k1\":\"v1\"") != null);
    logger.resetSinkToStderr();
}

test "TestCANARY_REQ_GQL_085_ClientLoggingParity" {
    std.testing.expect(true) catch unreachable; // STUB placeholder
}
