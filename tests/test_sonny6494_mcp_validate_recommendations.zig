// SONNY-6494 (1): the MCP `validate` tool shows the recommendation engine's
// suggestions (src/gql/recommendations.zig) for every documented kind.
//
// The engine matched `n.prop` only as `.PropertyAccess`, but the parser
// writes it as `.Member` on an `.Ident`, so the WHERE / FILTER / ORDER BY
// recommendations (index, fulltext index, coalesce) never fired and MCP
// `validate` never showed them. These tests drive a real GeodeMcpServer
// through `mcp.Server.processMessage` (`tools/call` → `validate`) under the
// strict testing allocator and look for each suggestion in the response.

const std = @import("std");
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6494-test","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    const inited =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    if (try server.server.processMessage(inited)) |r| allocator.free(r);
}

/// Calls the `validate` tool with `query` (a JSON string body, already
/// escaped) and returns the owned JSON-RPC response.
fn validate(server: *GeodeMcpServer, allocator: std.mem.Allocator, query_json: []const u8) ![]const u8 {
    const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"validate\",\"arguments\":{{\"query\":\"{s}\"}}}}}}", .{query_json});
    defer allocator.free(req);
    return (try server.server.processMessage(req)) orelse error.UnexpectedNullResponse;
}

const Case = struct { query: []const u8, expect: []const u8 };

test "SONNY-6494: MCP validate shows every documented recommendation kind" {
    const allocator = std.testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server, allocator);

    const cases = [_]Case{
        // geode/suggest-index: WHERE equality on a property.
        .{ .query = "MATCH (n:Person) WHERE n.age = 30 RETURN n", .expect = "CREATE INDEX ON :Person(age)" },
        // geode/suggest-index: the same through an ISO FILTER statement.
        .{ .query = "MATCH (n:Person) FILTER n.age = 30 RETURN n", .expect = "CREATE INDEX ON :Person(age)" },
        // geode/suggest-index: ORDER BY a property.
        .{ .query = "MATCH (n:Person) RETURN n ORDER BY n.age", .expect = "btree index for ORDER BY: CREATE INDEX ON :Person(age)" },
        // geode/suggest-fulltext-index: CONTAINS and STARTS WITH.
        .{ .query = "MATCH (n:Article) WHERE n.body CONTAINS 'x' RETURN n", .expect = "CONTAINS on 'body' may benefit from a fulltext index" },
        .{ .query = "MATCH (n:Article) WHERE n.title STARTS WITH 'x' RETURN n", .expect = "STARTS WITH on 'title' may benefit from a fulltext index" },
        // geode/suggest-coalesce: IS NULL on a property.
        .{ .query = "MATCH (n:Person) WHERE n.nick IS NULL RETURN n", .expect = "coalesce(n.nick, default_value)" },
        // geode/suggest-encrypted / -searchable: sensitive pattern properties.
        .{ .query = "CREATE (u:User {password: 'x'})", .expect = "Consider using @encrypted annotation" },
        .{ .query = "INSERT (u:User {email: 'a@b.c'})", .expect = "Consider using @searchable annotation" },
        // geode/suggest-encrypted: a graph type field.
        .{ .query = "CREATE GRAPH TYPE T AS { ssn text }", .expect = "Field 'ssn' in graph type 'T' may contain sensitive data" },
        // geode/suggest-vector-index.
        .{ .query = "CREATE (d:Doc {embedding: [1.0]})", .expect = "CREATE VECTOR INDEX ON :Doc(embedding)" },
        // geode/suggest-path-mode.
        .{ .query = "MATCH (a)-[*1..5]->(b) RETURN a", .expect = "Variable-length path detected" },
        // geode/suggest-degree.
        .{ .query = "MATCH (n)-[r]->() RETURN n, count(r)", .expect = "indegree()/outdegree()" },
    };
    for (cases) |c| {
        const resp = try validate(server, allocator, c.query);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, c.expect) == null) {
            std.debug.print("query {s}: expected \"{s}\" in\n{s}\n", .{ c.query, c.expect, resp });
            return error.RecommendationMissing;
        }
    }
}

test "SONNY-6494: MCP validate shows no recommendation for a plain query" {
    const allocator = std.testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server, allocator);

    const resp = try validate(server, allocator, "CREATE (p:Product {price: 9})");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Consider") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
}
