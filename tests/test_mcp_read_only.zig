// Task 6 (hybrid-RAG audit spec, "instruction boundary"): MCP-layer
// read-only gate above the Task 5 engine-side hard floor
// (ExecuteRequest.read_only, tests/test_read_only_execute.zig). With a
// single MCP `query` tool exposed to an LLM, a malicious retrieved
// document could try to smuggle a mutating GQL statement through the
// tool call. This pins that Geode's own MCP server, given
// `Options.read_only = true`, classifies the statement in-process
// (real parser + query_traits.isMutatingProgram, the same classifier
// the QUIC/gRPC transports use) and refuses mutating or unparseable
// programs BEFORE any network round-trip to the geode backend — proven
// by pointing the server at a dead endpoint ("127.0.0.1:1") so a
// non-refused call would surface as a connection error, not a success.
//
// Model: message-driving on tests/test_gap0516_mcp_capabilities.zig —
// this test drives the real mcp.Server.processMessage dispatch, not a
// direct handler call, so the JSON-RPC tools/call envelope, argument
// parsing, and response shaping are all exercised end-to-end. NO MOCKS.
//
// CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=Test; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-29

const std = @import("std");
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

/// Build a no-auth in-process server pointed at a dead endpoint. No live
/// geode backend is reachable — a query that is NOT refused by the
/// read-only gate will attempt (and fail) a real connection, which is
/// exactly the signal the "still allows reads to attempt the wire" test
/// depends on.
fn initTestServer(allocator: std.mem.Allocator, read_only: bool) !*GeodeMcpServer {
    return GeodeMcpServer.init(allocator, .{
        .auth_mode = .none,
        .geode_endpoint = "127.0.0.1:1",
        .read_only = read_only,
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
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-read-only-test","version":"1.0"}}}
    ;
    const init_resp = (try dispatch(server, allocator, init_req)) orelse
        return error.UnexpectedNullResponse;
    allocator.free(init_resp);

    const inited =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    if (try dispatch(server, allocator, inited)) |r| allocator.free(r);
}

/// Extract the "result" object's raw JSON text from a JSON-RPC response,
/// as a slice into the original response buffer.
fn callQueryTool(server: *GeodeMcpServer, allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"query","arguments":{{"query":{f}}}}}}}
    ,
        .{std.json.fmt(query, .{})},
    );
    defer allocator.free(req);

    return (try dispatch(server, allocator, req)) orelse return error.UnexpectedNullResponse;
}

// Task 6 (2026-08-29): these tests previously ran under
// std.heap.page_allocator (no leak accounting) to dodge a pre-existing
// ownership gap in the pinned `mcp` v0.1.11 dependency: its tools/call
// dispatch (mcp.zig handleMethod) hardcoded handler results `.owned =
// false`, so the dynamically-allocated JSON our callTool handler returns
// for the `query` tool (formatErrorResponse / formatToolResult, both
// heap-allocate via json_lib.encode) was never freed by the server. Fixed
// upstream in mcp v0.1.12 (commit 956b07d): tools/call results are now
// `.owned = true` and the server frees them. Since mcp v0.1.22
// (SONNY-6531) the server frees EVERY handler result (geode's handlers
// return allocator-owned bytes; tests/test_sonny6531_mcp_ownership.zig
// covers each method). Strict std.testing.allocator below — a regression of
// the leak, or a handler returning a literal (an invalid free), fails these
// tests, which is the whole point.
test "read-only MCP refuses mutating query tool calls before the wire" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator, true);
    defer server.deinit();

    try handshake(server, allocator);

    const resp = try callQueryTool(server, allocator, "CREATE (n:X)");
    defer allocator.free(resp);

    // Must carry isError:true and the read-only refusal message, NOT a
    // connection-failure error from attempting the dead endpoint.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only MCP server: data modification rejected") != null);
}

test "read-only MCP still allows reads to attempt the wire" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator, true);
    defer server.deinit();

    try handshake(server, allocator);

    const resp = try callQueryTool(server, allocator, "RETURN 1");
    defer allocator.free(resp);

    // RETURN 1 classifies as read-only, so the gate must NOT refuse it.
    // It still fails because the endpoint is dead — that failure must
    // NOT be the read-only refusal message.
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only MCP server: data modification rejected") == null);
}

test "read-only MCP refuses unparseable statements (fail-closed)" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator, true);
    defer server.deinit();

    try handshake(server, allocator);

    const resp = try callQueryTool(server, allocator, "THIS IS NOT VALID GQL @@@");
    defer allocator.free(resp);

    // Unparseable input is unclassifiable and MUST be refused in
    // read-only mode (fail closed), same message as a real mutation.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only MCP server: data modification rejected") != null);
}

// Finding 1 (whole-branch review, CRITICAL): MATCH...CALL was not checked
// by isQueryMutating, so a mutating procedure invoked through the
// MATCH...CALL shape bypassed the MCP read-only gate pre-wire (same
// classifier as tests/test_read_only_execute.zig, consumed transitively
// via query_traits.isMutatingProgram).
test "read-only MCP refuses MATCH...CALL geode.fts.rebuild before the wire" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator, true);
    defer server.deinit();

    try handshake(server, allocator);

    const resp = try callQueryTool(server, allocator, "MATCH (n:Doc) CALL geode.fts.rebuild('idx') YIELD indexed RETURN indexed");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only MCP server: data modification rejected") != null);
}

test "non-read-only MCP does not gate mutating query tool calls" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator, false);
    defer server.deinit();

    try handshake(server, allocator);

    const resp = try callQueryTool(server, allocator, "CREATE (n:X)");
    defer allocator.free(resp);

    // read_only = false (default posture): the MCP-layer gate must not
    // fire at all; any failure here comes from the dead endpoint, not
    // the read-only refusal message.
    try std.testing.expect(std.mem.indexOf(u8, resp, "read-only MCP server: data modification rejected") == null);
}
