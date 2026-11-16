// CANARY: REQ=REQ-SONNY-6585-MCP-ERROR-DETAIL; FEATURE="MCPResultShapes"; ASPECT=ErrorMessageAndData; STATUS=TESTED; TEST=tests/test_sonny6585_mcp_error_detail.zig; OWNER=mcp; UPDATED=2026-11-15
//
// SONNY-6585 (geode side, mcp v0.1.23): a JSON-RPC error from geode's MCP
// server says what was wrong. The message was the Zig error's name
// ("InvalidParams", "ResourceNotFound") with no data, because the library
// had no way for a handler to give one. With `mcp.setErrorDetail`:
//
//   - an unknown tool:      -32602 "Unknown tool: <name>",   data {"name"}
//   - an unknown prompt:    -32602 "Unknown prompt: <name>", data {"name"}
//   - a bad prompt argument: -32602 naming the argument,     data {"name"}
//   - an unknown resource:  -32002 "Resource not found: <uri>", data {"uri"}
//     (escaped: a URI holding a quote or a backslash round-trips)
//   - a cursor on a list:   -32602 naming the cursor,        data {"cursor"}
//
// and a failing notification (no id) gets no reply (JSON-RPC 2.0 4.1).
// Every response is one line of valid JSON.
//
// The real mcp.Server.processMessage dispatch of a GeodeMcpServer.
const std = @import("std");
const testing = std.testing;
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const Value = std.json.Value;

fn fail(comptime fmt: []const u8, args: anytype) error{Sonny6585} {
    std.debug.print("SONNY-6585: " ++ fmt ++ "\n", args);
    return error.Sonny6585;
}

const ErrorWant = struct {
    code: i64,
    /// The exact message.
    message: []const u8,
    /// `data.<key>` must equal `value`.
    data_key: []const u8,
    data_value: []const u8,
};

fn expectError(server: *GeodeMcpServer, id: i64, msg: []const u8, want: ErrorWant) !void {
    const a = testing.allocator;
    const resp = (try server.server.processMessage(msg)) orelse return fail("no response to {s}", .{msg});
    defer a.free(resp);
    if (std.mem.indexOfScalar(u8, resp, '\n') != null) return fail("response spans lines: {s}", .{resp});
    const parsed = std.json.parseFromSlice(Value, a, resp, .{}) catch return fail("response is not JSON: {s}", .{resp});
    defer parsed.deinit();
    const root = parsed.value.object;
    const got_id = root.get("id") orelse return fail("no id: {s}", .{resp});
    if (got_id != .integer or got_id.integer != id) return fail("id: {s}", .{resp});
    const e = (root.get("error") orelse return fail("not an error: {s}", .{resp})).object;
    if (e.get("code").?.integer != want.code) return fail("code {d}, want {d}: {s}", .{ e.get("code").?.integer, want.code, resp });
    const message = e.get("message").?.string;
    if (!std.mem.eql(u8, message, want.message)) return fail("message '{s}', want '{s}'", .{ message, want.message });
    const data = e.get("data") orelse return fail("no data: {s}", .{resp});
    if (data != .object) return fail("data is not an object: {s}", .{resp});
    const v = data.object.get(want.data_key) orelse return fail("data has no '{s}': {s}", .{ want.data_key, resp });
    if (v != .string or !std.mem.eql(u8, v.string, want.data_value)) return fail("data.{s} is not '{s}': {s}", .{ want.data_key, want.data_value, resp });
}

fn handshake(server: *GeodeMcpServer) !void {
    const resp = (try server.server.processMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6585-test","version":"1.0"}}}
    )) orelse return fail("no initialize response", .{});
    testing.allocator.free(resp);
    try testing.expect((try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) == null);
}

test "SONNY-6585: MCP errors carry a message and data naming what was wrong" {
    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server);

    try expectError(server, 10,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
    , .{ .code = -32602, .message = "Unknown tool: no_such_tool", .data_key = "name", .data_value = "no_such_tool" });
    // The built-in "barrier" tool of mcp < v0.1.23 is gone: geode has none.
    try expectError(server, 11,
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"barrier","arguments":{"count":2}}}
    , .{ .code = -32602, .message = "Unknown tool: barrier", .data_key = "name", .data_value = "barrier" });

    try expectError(server, 20,
        \\{"jsonrpc":"2.0","id":20,"method":"prompts/get","params":{"name":"no_such_prompt"}}
    , .{ .code = -32602, .message = "Unknown prompt: no_such_prompt", .data_key = "name", .data_value = "no_such_prompt" });
    try expectError(server, 21,
        \\{"jsonrpc":"2.0","id":21,"method":"prompts/get","params":{"name":"find_nodes"}}
    , .{ .code = -32602, .message = "Prompt find_nodes: missing required argument 'label'", .data_key = "name", .data_value = "find_nodes" });
    try expectError(server, 22,
        \\{"jsonrpc":"2.0","id":22,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"A","x":"y"}}}
    , .{ .code = -32602, .message = "Prompt find_nodes: takes no argument 'x'", .data_key = "name", .data_value = "find_nodes" });
    try expectError(server, 23,
        \\{"jsonrpc":"2.0","id":23,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":1}}}
    , .{ .code = -32602, .message = "Prompt find_nodes: argument 'label' is not a string", .data_key = "name", .data_value = "find_nodes" });

    try expectError(server, 30,
        \\{"jsonrpc":"2.0","id":30,"method":"resources/read","params":{"uri":"geode://default/default/nothing"}}
    , .{ .code = -32002, .message = "Resource not found: geode://default/default/nothing", .data_key = "uri", .data_value = "geode://default/default/nothing" });
    try expectError(server, 31,
        \\{"jsonrpc":"2.0","id":31,"method":"resources/read","params":{"uri":"geode://a\"b\\c"}}
    , .{ .code = -32002, .message = "Resource not found: geode://a\"b\\c", .data_key = "uri", .data_value = "geode://a\"b\\c" });

    inline for (.{ "tools/list", "resources/list", "prompts/list" }, 0..) |method, i| {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"cursor\":\"c1\"}}}}", .{ 40 + i, method });
        try expectError(server, 40 + i, msg, .{
            .code = -32602,
            .message = "Invalid cursor: geode answers " ++ method ++ " in one page and issues no cursor",
            .data_key = "cursor",
            .data_value = "c1",
        });
    }

    // A failing notification gets no reply.
    try testing.expect((try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
    )) == null);
}
