// SONNY-6511 item 4: MCP `validate` reports each recommendation at the
// token it is about.
//
// src/mcp/lsp.zig validateQuery reported every recommendation of the
// engine (src/gql/recommendations.zig) at line 0, column 0 (the engine set
// no position: the AST carries none), and dropped any error the engine
// returned, out-of-memory included, answering as if there were no
// recommendation. These drive a real GeodeMcpServer through
// `mcp.Server.processMessage` (`tools/call` -> `validate`) and check the
// 1-based line, column and end column (exclusive) of each recommendation,
// the convention of the parse-error diagnostics beside them.

const std = @import("std");
const mcp_server = @import("mcp_server");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6511-test","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    const inited =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    if (try server.server.processMessage(inited)) |r| allocator.free(r);
}

const Want = struct {
    /// A substring of the recommendation's message.
    message: []const u8,
    line: i64,
    column: i64,
    end_column: i64,
};

/// Calls `validate` on `query` and checks every `want` against the
/// diagnostics whose message contains `want.message`, in order.
fn expectPositions(server: *GeodeMcpServer, allocator: std.mem.Allocator, query: []const u8, wants: []const Want) !void {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.value(query, .{}, &escaped.writer);
    const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"validate\",\"arguments\":{{\"query\":{s}}}}}}}", .{escaped.written()});
    defer allocator.free(req);
    const resp = (try server.server.processMessage(req)) orelse return error.UnexpectedNullResponse;
    defer allocator.free(resp);

    const rpc = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer rpc.deinit();
    const result = rpc.value.object.get("result") orelse {
        std.debug.print("no result for {s}:\n{s}\n", .{ query, resp });
        return error.NoResult;
    };
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const body = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer body.deinit();
    const diags = body.value.object.get("diagnostics").?.array.items;

    var used: [16]bool = @splat(false);
    for (wants) |w| {
        var found = false;
        for (diags, 0..) |d, i| {
            if (used[i]) continue;
            const msg = d.object.get("message").?.string;
            if (std.mem.indexOf(u8, msg, w.message) == null) continue;
            used[i] = true;
            found = true;
            const line = d.object.get("line").?.integer;
            const column = d.object.get("column").?.integer;
            const end_line = d.object.get("endLine").?.integer;
            const end_column = d.object.get("endColumn").?.integer;
            if (line != w.line or column != w.column or end_line != w.line or end_column != w.end_column) {
                std.debug.print("{s}: \"{s}\" at {d}:{d}-{d}:{d}, expected {d}:{d}-{d}:{d}\n", .{ query, w.message, line, column, end_line, end_column, w.line, w.column, w.line, w.end_column });
                return error.WrongPosition;
            }
            break;
        }
        if (!found) {
            std.debug.print("{s}: no recommendation \"{s}\" in\n{s}\n", .{ query, w.message, text });
            return error.RecommendationMissing;
        }
    }
}

test "SONNY-6511: MCP validate places each recommendation on its token" {
    const allocator = std.testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server, allocator);

    // The property of a WHERE equality, on the second line.
    try expectPositions(server, allocator, "MATCH (n:Person)\nWHERE n.age = 30\nRETURN n", &.{
        .{ .message = "CREATE INDEX ON :Person(age)", .line = 2, .column = 9, .end_column = 12 },
    });
    // Two pattern properties on one line, each on its own name.
    try expectPositions(server, allocator, "CREATE (u:User {email: 'e', password: 'p'})", &.{
        .{ .message = "Property 'email'", .line = 1, .column = 17, .end_column = 22 },
        .{ .message = "Property 'password'", .line = 1, .column = 29, .end_column = 37 },
    });
    // The same property twice: WHERE first, then ORDER BY.
    try expectPositions(server, allocator, "MATCH (n:Person) WHERE n.age = 1 RETURN n ORDER BY n.age", &.{
        .{ .message = "faster lookups: CREATE INDEX ON :Person(age)", .line = 1, .column = 26, .end_column = 29 },
        .{ .message = "ORDER BY: CREATE INDEX ON :Person(age)", .line = 1, .column = 54, .end_column = 57 },
    });
    // A property named in a string literal earlier is not the anchor.
    try expectPositions(server, allocator, "MATCH (n:Person {nick: 'age'}) WHERE n.age = 3 RETURN n", &.{
        .{ .message = "CREATE INDEX ON :Person(age)", .line = 1, .column = 40, .end_column = 43 },
    });
    // count(...) and the * of a variable-length path.
    try expectPositions(server, allocator, "MATCH (n)-[r]->() RETURN n, count(r)", &.{
        .{ .message = "indegree()/outdegree()", .line = 1, .column = 29, .end_column = 34 },
    });
    try expectPositions(server, allocator, "MATCH (a)-[*1..5]->(b) RETURN a", &.{
        .{ .message = "Variable-length path detected", .line = 1, .column = 12, .end_column = 13 },
    });
}
