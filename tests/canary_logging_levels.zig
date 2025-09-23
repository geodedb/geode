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
    // Exercise that logging from 'client' and 'server' contexts produce same JSON key set and ordering.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var list_client = std.ArrayList(u8).init(gpa.allocator());
    defer list_client.deinit();
    var list_server = std.ArrayList(u8).init(gpa.allocator());
    defer list_server.deinit();

    // Capture a log line for a simulated client component
    logger.setBufferSink(&list_client);
    logger.setComponent("client");
    logger.setLevel(.trace);
    logger.info("client hello", .{.{ .key = "cid", .value = "123" }});
    logger.resetSinkToStderr();

    // Capture a log line for a simulated server component
    logger.setBufferSink(&list_server);
    logger.setComponent("server");
    logger.setLevel(.trace);
    logger.info("server hello", .{.{ .key = "sid", .value = "xyz" }});
    logger.resetSinkToStderr();

    const c_data = list_client.items;
    const s_data = list_server.items;
    try std.testing.expect(c_data.len > 0 and s_data.len > 0);
    // Extract keys between '{' and first '\n'
    const c_line = c_data[0 .. std.mem.indexOfScalar(u8, c_data, '\n') orelse c_data.len];
    const s_line = s_data[0 .. std.mem.indexOfScalar(u8, s_data, '\n') orelse s_data.len];

    // Helper to collect JSON top-level keys (naive scan for "key":)
    var keys_buf_client: [12][]const u8 = undefined; // expected small number of keys
    var keys_buf_server: [12][]const u8 = undefined;
    var kc: usize = 0;
    var ks: usize = 0;
    var i: usize = 0;
    while (i < c_line.len) : (i += 1) {
        if (c_line[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < c_line.len and c_line[j] != '"') : (j += 1) {}
            if (j < c_line.len and j + 2 < c_line.len and c_line[j + 1] == ':' and c_line[j + 2] == '"') {
                const key = c_line[start..j];
                if (kc < keys_buf_client.len) {
                    keys_buf_client[kc] = key;
                    kc += 1;
                } else break;
            }
            i = j;
        }
    }
    i = 0;
    while (i < s_line.len) : (i += 1) {
        if (s_line[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < s_line.len and s_line[j] != '"') : (j += 1) {}
            if (j < s_line.len and j + 2 < s_line.len and s_line[j + 1] == ':' and s_line[j + 2] == '"') {
                const key = s_line[start..j];
                if (ks < keys_buf_server.len) {
                    keys_buf_server[ks] = key;
                    ks += 1;
                } else break;
            }
            i = j;
        }
    }
    // Expect same number of keys
    try std.testing.expect(kc == ks);
    // Compare each key positionally except message-specific keys (msg component id differs but key names same)
    var idx: usize = 0;
    while (idx < kc) : (idx += 1) {
        const ck = keys_buf_client[idx];
        const sk = keys_buf_server[idx];
        try std.testing.expect(std.mem.eql(u8, ck, sk));
    }
}
