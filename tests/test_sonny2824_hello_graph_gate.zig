// SONNY-2824 regression: a HELLO never creates a graph for a principal
// without the schema permission on it.
//
// SONNY-2803 made CREATE GRAPH need `decide(schema, graph)` and `bind_graph`
// on the graph (`execution.session_graph.maySchema`). A HELLO that names a
// graph that does not exist still created it for any Admin or ReadWrite
// role, on QUIC and on gRPC alike: a ReadWrite user, which has no schema
// permission, created any graph it named at connect time.
//
// Now HELLO decides the graph it binds through the session-graph gate, in
// the order every other graph change takes: an internal graph is refused,
// then a graph the principal may not bind (whether or not it exists), then
// existence. A graph that does not exist is created only when the principal
// may change its schema; otherwise the HELLO is refused and nothing is
// created.
//
// End to end against a spawned server: there is no in-process QUIC harness,
// and the gRPC HELLO handler needs the transport.
//
// CANARY: REQ=REQ-SONNY-2824-HELLO-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2824_hello_graph_gate.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const rw_user = "rw2824";
const rw_pass = "ReadWrite2824!";

fn expectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// Does `graph` exist? The admin's USE GRAPH answers 3F000 for one that does
/// not (SONNY-2775), and the admin may bind every graph.
fn graphExists(admin: *util.QuicProtoClient, allocator: std.mem.Allocator, graph: []const u8) !bool {
    var buf: [128]u8 = undefined;
    const query = try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph});
    var r = try admin.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        if (std.mem.eql(u8, code, "3F000")) return false;
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    try expectOk(admin, allocator, "USE GRAPH default");
    return true;
}

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    data_dir_buf: [96]u8 = undefined,
    data_dir: []const u8 = "",

    fn start(self: *Server, allocator: std.mem.Allocator) !void {
        const quic_port = try util.getRandomPort();
        const grpc_port = try util.getRandomPort();
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        // A data directory: a graph HELLO creates needs the persistent
        // storage adapter (its UUID).
        self.data_dir = try std.fmt.bufPrint(&self.data_dir_buf, "/tmp/geode-sonny2824-{d}", .{quic_port});
        std.Io.Dir.cwd().createDirPath(io_fs, self.data_dir) catch {};
        self.quic_addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(self.quic_addr);
        self.grpc_addr = try util.formatAddr(allocator, grpc_port);
        errdefer allocator.free(self.grpc_addr);
        self.handle = try util.spawnServer(
            allocator,
            &.{ "./zig-out/bin/geode", "serve", "--listen", self.quic_addr, "--listen-grpc", self.grpc_addr, "--data-dir", self.data_dir },
            // The plaintext gRPC client (Debug builds of the server only).
            util.TestEnv.grpcPlaintext(),
        );
        errdefer self.handle.deinit();
        try util.waitForServerReady(allocator, self.quic_addr, 30000);
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io_fs, self.data_dir) catch {};
        allocator.free(self.quic_addr);
        allocator.free(self.grpc_addr);
    }
};

const Transport = enum { quic, grpc };

/// A HELLO over `transport` as `user`, naming `graph`: did it succeed as
/// `want`? A wrong outcome is printed, with the refusal's message, and
/// counted, so one run shows every transport's.
fn hello(allocator: std.mem.Allocator, server: *Server, transport: Transport, user: []const u8, pass: []const u8, graph: []const u8, want: bool, wrong: *usize) !void {
    var r = switch (transport) {
        .quic => blk: {
            var client = try util.QuicProtoClient.connect(allocator, server.quic_addr);
            defer client.deinit();
            break :blk try client.helloWithGraph(allocator, user, pass, graph);
        },
        .grpc => blk: {
            var client = try util.GrpcProtoClient.connect(allocator, server.grpc_addr);
            defer client.deinit();
            break :blk try client.helloWithGraph(allocator, user, pass, graph);
        },
    };
    defer r.deinit(allocator);
    if (r.success != want) {
        std.debug.print("{s} HELLO as {s} naming {s}: success={} (want {}) \"{s}\"\n", .{ @tagName(transport), user, graph, r.success, want, r.error_message });
        wrong.* += 1;
    }
}

/// Does `graph` exist, as `want`? A wrong answer is printed and counted.
fn expectGraph(admin: *util.QuicProtoClient, allocator: std.mem.Allocator, graph: []const u8, want: bool, wrong: *usize) !void {
    const got = try graphExists(admin, allocator, graph);
    if (got != want) {
        std.debug.print("graph {s} exists={} (want {})\n", .{ graph, got, want });
        wrong.* += 1;
    }
}

test "SONNY-2824: a HELLO over QUIC or gRPC creates a missing graph only for a principal with the schema permission on it" {
    const allocator = testing.allocator;
    var server: Server = undefined;
    try server.start(allocator);
    defer server.stop(allocator);

    var admin = try util.QuicProtoClient.connect(allocator, server.quic_addr);
    defer admin.deinit();
    var ah = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer ah.deinit(allocator);
    try testing.expect(ah.success);
    try expectOk(&admin, allocator, "CREATE GRAPH exists_2824");
    try expectOk(&admin, allocator, "CREATE USER " ++ rw_user ++ " SET PASSWORD '" ++ rw_pass ++ "' ROLE readwrite");
    // An allow policy FOR SCHEMA on one graph, for everyone (USING true).
    try expectOk(&admin, allocator, "CREATE POLICY schema_2824 ON GRAPH granted_2824 FOR SCHEMA");

    var wrong: usize = 0;
    for ([_]Transport{ .quic, .grpc }) |t| {
        // ReadWrite has no schema permission: the HELLO is refused, and the
        // graph it named is not created (it was, and bound).
        var buf: [64]u8 = undefined;
        const missing = try std.fmt.bufPrint(&buf, "missing_{s}_2824", .{@tagName(t)});
        try hello(allocator, &server, t, rw_user, rw_pass, missing, false, &wrong);
        try expectGraph(&admin, allocator, missing, false, &wrong);

        // A graph that exists, which ReadWrite may bind (single tenant).
        try hello(allocator, &server, t, rw_user, rw_pass, "exists_2824", true, &wrong);

        // The Admin holds schema on every graph: its HELLO creates one.
        var abuf: [64]u8 = undefined;
        const created = try std.fmt.bufPrint(&abuf, "admin_{s}_2824", .{@tagName(t)});
        try hello(allocator, &server, t, util.defaultUsername(), util.defaultPassword(), created, true, &wrong);
        try expectGraph(&admin, allocator, created, true, &wrong);
    }

    // A GPS policy FOR SCHEMA on granted_2824 gives the ReadWrite user schema
    // on that graph: its HELLO creates it.
    try expectGraph(&admin, allocator, "granted_2824", false, &wrong);
    try hello(allocator, &server, .quic, rw_user, rw_pass, "granted_2824", true, &wrong);
    try expectGraph(&admin, allocator, "granted_2824", true, &wrong);

    if (wrong > 0) return error.HelloGraphGateWrong;
}
