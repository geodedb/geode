// SONNY-2776 (review P39): the QUIC handler's own choices of graph, end to end
// against a spawned server (there is no in-process QUIC harness).
//
// QUIC's label-deny post-filter read `state.current_graph`, a copy of the
// session's graph synced only after a request succeeds. So after
// `USE GRAPH g2; ...` in a request, it applied the graph from BEFORE the
// request: g2's deny policies were not applied to rows g2 produced. The
// executor filters the rows its MATCH reads itself; the transport filter is
// what stands for the rows it does not, such as graph-algorithm results. And
// a transaction could change one graph and then another.
//
// CANARY: REQ=REQ-SONNY-2776-TXN-ONE-GRAPH; FEATURE="StatementAuthorization"; ASPECT=QuicE2E; STATUS=TESTED; TEST=tests/test_sonny2776_quic_graph_uses.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    return client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
}

fn expectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try run(client, allocator, query);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// The node ids in column `nodeId` of `query`'s rows.
fn nodeIds(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !std.ArrayList(i64) {
    var r = try run(client, allocator, query);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    var col: ?usize = null;
    for (r.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, "nodeId")) col = i;
    }
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    const idx = col orelse return ids;
    for (r.rows) |row| switch (row[idx]) {
        .int => |v| try ids.append(allocator, v),
        else => {},
    };
    return ids;
}

const Server = struct {
    server: util.ServerHandle,
    addr: []u8,
    data_dir_buf: [96]u8 = undefined,
    data_dir: []const u8 = "",

    fn start(self: *Server, allocator: std.mem.Allocator, tag: []const u8) !void {
        const port = try util.getRandomPort();
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        self.data_dir = try std.fmt.bufPrint(&self.data_dir_buf, "/tmp/geode-sonny2776-{s}-{d}", .{ tag, port });
        std.Io.Dir.cwd().createDirPath(io_fs, self.data_dir) catch {};
        self.addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(self.addr);
        self.server = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", self.addr, "--data-dir", self.data_dir },
            util.TestEnv.standard(),
        );
        try util.waitForServerReady(allocator, self.addr, 30000);
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.server.deinit();
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io_fs, self.data_dir) catch {};
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator, user: []const u8, password: []const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, user, password);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("HELLO {s}: {s}\n", .{ user, h.error_message });
            return error.HelloFailed;
        }
        return client;
    }
};

test "SONNY-2776: over QUIC the label-deny post-filter applies the policies of the graph a graph-switching read ran on" {
    const allocator = testing.allocator;
    var s: Server = .{ .server = undefined, .addr = undefined };
    try s.start(allocator, "rls");
    defer s.stop(allocator);

    var admin = try s.connect(allocator, util.defaultUsername(), util.defaultPassword());
    defer admin.deinit();
    try expectOk(&admin, allocator, "CREATE GRAPH g2");
    try expectOk(&admin, allocator, "USE GRAPH g2; CREATE (a:Secret {v: 1}), (b:Open {v: 2}), (a)-[:R]->(b)");
    try expectOk(&admin, allocator, "CREATE USER alice SET PASSWORD 'Alice Graph Uses Passphrase' ROLE readwrite");
    try expectOk(&admin, allocator, "CALL geode.rls.add_deny_policy('g2', 'Secret', 'alice')");
    try expectOk(&admin, allocator, "USE GRAPH default");

    var secret_id: i64 = -1;
    {
        var r = try run(&admin, allocator, "USE GRAPH g2; MATCH (n:Secret) RETURN id(n) AS id");
        defer r.deinit(allocator);
        if (r.rows.len != 1) return error.SecretNotSeeded;
        secret_id = switch (r.rows[0][0]) {
            .int => |v| v,
            else => return error.UnexpectedValue,
        };
    }
    // The policy names alice only: the admin's algorithm result has the node.
    {
        var ids = try nodeIds(&admin, allocator, "USE GRAPH g2; CALL algo.degree.stream() YIELD nodeId, degree");
        defer ids.deinit(allocator);
        try testing.expect(std.mem.indexOfScalar(i64, ids.items, secret_id) != null);
    }

    var alice = try s.connect(allocator, "alice", "Alice Graph Uses Passphrase");
    defer alice.deinit();
    // alice's session starts on `default`; the request moves it to g2.
    {
        var ids = try nodeIds(&alice, allocator, "USE GRAPH g2; CALL algo.degree.stream() YIELD nodeId, degree");
        defer ids.deinit(allocator);
        if (std.mem.indexOfScalar(i64, ids.items, secret_id) != null) {
            std.debug.print("alice got g2's Secret node {d} through the algorithm post-filter\n", .{secret_id});
            return error.DeniedNodeReturned;
        }
    }
    {
        var r = try run(&alice, allocator, "USE GRAPH g2; MATCH (n:Secret) RETURN n.v AS v");
        defer r.deinit(allocator);
        try testing.expect(r.error_code == null);
        try testing.expectEqual(@as(usize, 0), r.rows.len);
    }
}

test "SONNY-2776: over QUIC a transaction changes one graph" {
    const allocator = testing.allocator;
    var s: Server = .{ .server = undefined, .addr = undefined };
    try s.start(allocator, "txn");
    defer s.stop(allocator);

    var admin = try s.connect(allocator, util.defaultUsername(), util.defaultPassword());
    defer admin.deinit();
    try expectOk(&admin, allocator, "CREATE GRAPH g2");
    try expectOk(&admin, allocator, "CREATE GRAPH g3");

    var b = try admin.begin(allocator);
    b.deinit(allocator);
    try expectOk(&admin, allocator, "USE GRAPH g2; CREATE (:T {v: 1})");
    {
        var r = try run(&admin, allocator, "USE GRAPH g3; CREATE (:T {v: 2})");
        defer r.deinit(allocator);
        try testing.expectEqualStrings("0A000", r.error_code orelse return error.ExpectedRefusal);
    }
    // Reading another graph is fine; g2 again is fine.
    try expectOk(&admin, allocator, "USE GRAPH g3; MATCH (n) RETURN count(n) AS c");
    try expectOk(&admin, allocator, "USE GRAPH g2; CREATE (:T {v: 3})");
    try testing.expect(try admin.commit(allocator));

    {
        var r = try run(&admin, allocator, "USE GRAPH g3; MATCH (n:T) RETURN count(n) AS c");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(i64, 0), switch (r.rows[0][0]) {
            .int => |v| v,
            else => return error.UnexpectedValue,
        });
    }
    {
        var r = try run(&admin, allocator, "USE GRAPH g2; MATCH (n:T) RETURN count(n) AS c");
        defer r.deinit(allocator);
        try testing.expectEqual(@as(i64, 2), switch (r.rows[0][0]) {
            .int => |v| v,
            else => return error.UnexpectedValue,
        });
    }
    // The next transaction may change g3.
    var b2 = try admin.begin(allocator);
    b2.deinit(allocator);
    try expectOk(&admin, allocator, "USE GRAPH g3; CREATE (:T {v: 4})");
    try testing.expect(try admin.commit(allocator));
}
