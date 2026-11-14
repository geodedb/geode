// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6544 item 3: `completion/complete` answers the MCP result shape.
//
// The pinned mcp library speaks protocol 2025-11-25, whose CompleteResult
// is `{"completion":{"values":[...],"total"?:n,"hasMore"?:b}}` (values: at
// most 100 strings). src/mcp/server.zig completeHandler returned `[]`, so
// a client got `"result":[]` and found no `completion` object. Driven
// through the real mcp.Server.processMessage dispatch, as
// tests/test_gap0516_mcp_capabilities.zig does.
//
// CANARY: REQ=REQ-SONNY-6544-MCP-COMPLETION; FEATURE="MCPCompletion"; ASPECT=CompleteResultShape; STATUS=TESTED; TEST=tests/test_sonny6544_mcp_completion.zig; OWNER=mcp; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6544-test","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    if (try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) |r| allocator.free(r);
}

/// The response's `result` must be a CompleteResult: an object holding a
/// `completion` object whose `values` is an array of at most 100 strings,
/// `total` (when present) an integer no smaller than the values, and
/// `hasMore` (when present) a bool.
fn expectCompleteResult(allocator: std.mem.Allocator, resp: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch |err| {
        std.debug.print("response is not JSON: {s}\n", .{resp});
        return err;
    };
    defer parsed.deinit();
    errdefer std.debug.print("response: {s}\n", .{resp});
    const root = parsed.value.object;
    try testing.expect(root.get("error") == null);
    const result = root.get("result") orelse return error.NoResult;
    try testing.expect(result == .object);
    const completion = result.object.get("completion") orelse return error.NoCompletion;
    try testing.expect(completion == .object);
    const values = completion.object.get("values") orelse return error.NoValues;
    try testing.expect(values == .array);
    try testing.expect(values.array.items.len <= 100);
    for (values.array.items) |v| try testing.expect(v == .string);
    if (completion.object.get("total")) |total| {
        try testing.expect(total == .integer);
        try testing.expect(total.integer >= @as(i64, @intCast(values.array.items.len)));
    }
    if (completion.object.get("hasMore")) |more| try testing.expect(more == .bool);
}

test "SONNY-6544: completion/complete without params answers a CompleteResult" {
    const allocator = testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server, allocator);

    const resp = (try server.server.processMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"completion/complete"}
    )) orelse return error.UnexpectedNullResponse;
    defer allocator.free(resp);
    try expectCompleteResult(allocator, resp);
}

test "SONNY-6544: completion/complete for a prompt argument answers a CompleteResult" {
    // The pinned mcp library (v0.1.21) stringifies `params` for this method
    // and never frees it (fixed in v0.1.22, SONNY-6531), so this server runs
    // on smp_allocator; the no-params test above runs leak-checked.
    const allocator = std.heap.smp_allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server, allocator);

    const requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":3,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"explore_graph"},"argument":{"name":"graph","value":"so"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"geode://graph/{name}"},"argument":{"name":"name","value":""},"context":{"arguments":{}}}}
        ,
    };
    for (requests) |req| {
        const resp = (try server.server.processMessage(req)) orelse return error.UnexpectedNullResponse;
        defer allocator.free(resp);
        try expectCompleteResult(testing.allocator, resp);
    }
}
