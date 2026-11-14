// GAP-0516: MCP resource-subscription contract + truthful capability reporting.
//
// The locked decision for GAP-0516 is the "document-the-subset" path:
// resource subscriptions stay unimplemented, and the contract Geode
// actually honours at runtime must be tested through the real MCP
// JSON-RPC dispatch path (mcp.Server.processMessage) — not just by
// poking the handler functions directly.
//
// These tests drive a real GeodeMcpServer (auth_mode = .none so no
// transport bearer-token check, and no QUIC endpoint needed because
// none of the exercised methods touch the geode backend) end-to-end:
//
//   1. initialize negotiates and returns serverInfo + capabilities.
//   2. resources/subscribe   -> JSON-RPC -32601 (MethodNotFound).
//   3. resources/unsubscribe -> JSON-RPC -32601 (MethodNotFound).
//   4. tools/list, resources/list, prompts/list, completion/complete,
//      logging/setLevel still work (the subset Geode DOES implement).
//   5. The known upstream advertisement caveat is pinned: the pinned
//      `mcp` library hardcodes resources.subscribe:true in its
//      initialize response and exposes no override. We assert that
//      caveat explicitly so that a future library version which drops
//      the stale advertisement trips this test and prompts a docs +
//      CANARY update (see docs/MCP_SERVER.md and src/mcp/server.zig).

const std = @import("std");
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

/// Build a no-auth in-process server suitable for driving processMessage
/// directly. No QUIC endpoint is configured; the subscription-contract and
/// listing methods under test never reach the geode backend.
fn initTestServer(allocator: std.mem.Allocator) !*GeodeMcpServer {
    return GeodeMcpServer.init(allocator, .{
        .auth_mode = .none,
    });
}

/// Drive one JSON-RPC message through the real MCP server dispatch and
/// return the owned response (caller frees). Returns null for
/// notifications that produce no response.
fn dispatch(server: *GeodeMcpServer, allocator: std.mem.Allocator, msg: []const u8) !?[]const u8 {
    _ = allocator;
    return server.server.processMessage(msg);
}

/// Complete the MCP handshake so post-init requests are not blocked by the
/// library's "not initialized" gate (GAP-004 in the mcp library).
fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"gap0516-test","version":"1.0"}}}
    ;
    const init_resp = (try dispatch(server, allocator, init_req)) orelse
        return error.UnexpectedNullResponse;
    allocator.free(init_resp);

    // notifications/initialized has no id => no response expected.
    const inited =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    if (try dispatch(server, allocator, inited)) |r| allocator.free(r);
}

test "GAP-0516: initialize returns serverInfo and a capabilities object" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();

    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"gap0516-test","version":"1.0"}}}
    ;
    const resp = (try dispatch(server, allocator, init_req)) orelse
        return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    // The handshake response must be a success envelope carrying the
    // server's advertised capabilities and identity.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"serverInfo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "geode-mcp") != null);
}

test "GAP-0516: resources/subscribe answers -32601 MethodNotFound over real dispatch" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);

    const sub_req =
        \\{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"geode://graph/default"}}
    ;
    const resp = (try dispatch(server, allocator, sub_req)) orelse
        return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    // Canonical "this server does not implement this method" signal.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    // The handler must NOT have returned a success {} body.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") == null);
}

test "GAP-0516: resources/unsubscribe answers -32601 MethodNotFound over real dispatch" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);

    const unsub_req =
        \\{"jsonrpc":"2.0","id":3,"method":"resources/unsubscribe","params":{"uri":"geode://graph/default"}}
    ;
    const resp = (try dispatch(server, allocator, unsub_req)) orelse
        return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") == null);
}

test "GAP-0516: implemented subset (tools/resources/prompts list) still works" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);

    const cases = [_][]const u8{
        \\{"jsonrpc":"2.0","id":10,"method":"tools/list"}
        ,
        \\{"jsonrpc":"2.0","id":11,"method":"resources/list"}
        ,
        \\{"jsonrpc":"2.0","id":12,"method":"resources/templates/list"}
        ,
        \\{"jsonrpc":"2.0","id":13,"method":"prompts/list"}
        ,
    };

    for (cases) |req| {
        const resp = (try dispatch(server, allocator, req)) orelse
            return error.UnexpectedNullResponse;
        defer allocator.free(resp);
        // Each implemented method must return a success envelope, never
        // a MethodNotFound error.
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") == null);
    }
}

// NOTE: `completion/complete` is intentionally NOT exercised through the full
// mcp.Server.processMessage path here. The pinned mcp library (v0.1.7) leaks
// the stringified `params` JSON on that dispatch branch (mcp.zig ~3004:
// `json.stringify(self.allocator, p)` with no matching free, unlike the
// callTool branch which has a `defer ... free`). Driving it under
// std.testing.allocator would fail the leak detector on an upstream bug
// rather than a Geode regression. The completion handler's own contract
// (an empty CompleteResult, SONNY-6544) is covered leak-free by
// tests/test_sonny6544_mcp_completion.zig (no-params request) and the inline test in
// src/mcp/server.zig.

test "GAP-0516: logging/setLevel is a tolerated success (spec §7.2)" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);

    const req =
        \\{"jsonrpc":"2.0","id":30,"method":"logging/setLevel","params":{"level":"debug"}}
    ;
    const resp = (try dispatch(server, allocator, req)) orelse
        return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    // Spec §7.2: a server that doesn't support dynamic levels MUST still
    // respond successfully. No -32601, no crash.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") == null);
}

test "GAP-0516: known upstream advertisement caveat is pinned" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();

    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"gap0516-test","version":"1.0"}}}
    ;
    const resp = (try dispatch(server, allocator, init_req)) orelse
        return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    // CAVEAT (documented in docs/MCP_SERVER.md and src/mcp/server.zig):
    // the pinned `mcp` library (v0.1.7) hardcodes
    // resources.subscribe:true in its initialize response and exposes
    // no ServerOptions field to override it. Geode's handler still
    // answers -32601 (asserted by the dispatch tests above), so the
    // RUNTIME contract is honest even though the advertised string is
    // not. We pin the stale advertisement here so that a future
    // library bump which drops it trips this assertion and forces a
    // docs/CANARY refresh.
    const advertises_subscribe =
        std.mem.indexOf(u8, resp, "\"subscribe\":true") != null;

    if (!advertises_subscribe) {
        std.debug.print(
            "\nGAP-0516 NOTICE: the mcp library no longer advertises " ++
                "resources.subscribe:true in its initialize response. " ++
                "The advertisement is now consistent with Geode's " ++
                "MethodNotFound handler. Update docs/MCP_SERVER.md and " ++
                "this test to drop the caveat.\n",
            .{},
        );
        return error.AdvertisementCaveatResolved;
    }

    // While the caveat holds, the authoritative truth is the handler,
    // which the resources/subscribe + resources/unsubscribe tests above
    // prove answers -32601.
    try std.testing.expect(advertises_subscribe);
}
