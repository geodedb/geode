// SONNY-2751, the MCP read-only mode: Geode's MCP server with
// `Options.read_only = true` classifies each `query` tool call in process
// before it sends anything to the engine. It used the same classifier as the
// transports' read-only floor, which counted the security DDL (CREATE USER,
// GRANT, CREATE POLICY, ...) as a read, so a retrieved document could make
// the LLM create a user or grant itself access through a read-only server.
//
// Driven through the real `mcp.Server.processMessage` dispatch, as
// tests/test_mcp_read_only.zig, against a dead endpoint: a call the gate does
// not refuse fails to connect instead.
//
// CANARY: REQ=REQ-SONNY-2751-READ-ONLY-SECURITY-DDL; FEATURE="MCPReadOnly"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2751_readonly_security_ddl_mcp.zig; OWNER=mcp; UPDATED=2026-11-11

const std = @import("std");
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const refusal = "read-only MCP server: data modification rejected";

fn initTestServer(allocator: std.mem.Allocator) !*GeodeMcpServer {
    return GeodeMcpServer.init(allocator, .{
        .auth_mode = .none,
        .geode_endpoint = "127.0.0.1:1",
        .read_only = true,
    });
}

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny2751","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    if (try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) |r| allocator.free(r);
}

fn callQueryTool(server: *GeodeMcpServer, allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"query","arguments":{{"query":{f}}}}}}}
    ,
        .{std.json.fmt(query, .{})},
    );
    defer allocator.free(req);
    return (try server.server.processMessage(req)) orelse return error.UnexpectedNullResponse;
}

test "SONNY-2751: the read-only MCP server refuses the security DDL before the wire" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);
    const statements = [_][]const u8{
        "CREATE USER mallory SET PASSWORD 'Ro-Passw0rd-1' ROLE admin",
        "ALTER USER alice SET ROLE admin",
        "DROP USER alice",
        "CREATE ROLE r",
        "DROP ROLE r",
        "GRANT ALL ON GRAPH g1 TO mallory",
        "GRANT ROLE admin TO mallory",
        "REVOKE READ ON GRAPH g1 FROM alice",
        "CREATE POLICY p ON GRAPH * FOR READ",
        "ALTER POLICY p RENAME TO q",
        "DROP POLICY p",
    };
    for (statements) |q| {
        const resp = try callQueryTool(server, allocator, q);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, refusal) == null) {
            std.debug.print("read-only MCP did not refuse `{s}`: {s}\n", .{ q, resp });
            return error.NotRefused;
        }
    }
}

test "SONNY-2751: the read-only MCP server still lets the auth reads through to the engine" {
    const allocator = std.testing.allocator;
    const server = try initTestServer(allocator);
    defer server.deinit();
    try handshake(server, allocator);
    const statements = [_][]const u8{
        "SHOW USERS",
        "SHOW GRANTS",
        "SHOW POLICIES",
        "CALL geode.auth.grant_list('alice')",
        "CALL geode.auth.policy_list()",
    };
    for (statements) |q| {
        const resp = try callQueryTool(server, allocator, q);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, refusal) != null) {
            std.debug.print("read-only MCP refused the read `{s}`\n", .{q});
            return error.ReadRefused;
        }
    }
}
