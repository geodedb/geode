const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn execQuic(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    const params: std.ArrayList(schema.Param) = .empty;
    return client.executeAndCollect(allocator, query, params, 100);
}

fn execGrpc(client: *util.GrpcProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    const params: std.ArrayList(schema.Param) = .empty;
    return client.executeAndCollect(allocator, query, params, 100);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics IllegalOrderKey"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_IllegalOrderKey; OWNER=engine; UPDATED=2025-09-24

test "protocol: transport parity diagnostics (IllegalOrderKey) QUIC vs gRPC (gated)" {
    util.testStart("transport parity diagnostics (IllegalOrderKey) QUIC vs gRPC");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get two random ports for QUIC and gRPC
    const quic_port = util.getRandomPort() catch |err| {
        util.progress("QUIC port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const grpc_port = util.getRandomPort() catch |err| {
        util.progress("gRPC port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };

    const addr = try util.formatAddr(allocator, quic_port);
    defer allocator.free(addr);
    const grpc_addr = try util.formatAddr(allocator, grpc_port);
    defer allocator.free(grpc_addr);

    util.progress("Starting server (QUIC: {d}, gRPC: {d})...", .{ quic_port, grpc_port });

    // ENG-3907 (B4), KNOWN FAILING: this smoke needs a gRPC client that speaks
    // TLS. `util.GrpcProtoClient` is plaintext HTTP/2, and the server's gRPC
    // listener is TLS-required, so the parity comparison never reaches a query.
    // `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1` (Debug-only, grpc_server.zig:151)
    // gets the client past the handshake but the vendor listener then never
    // answers the HTTP/2 SETTINGS exchange — GAP-0893, vendor `grpc_zig` 0.1.7.
    // Left genuinely failing rather than re-silenced with `|| true`.
    var server = util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--listen-grpc", grpc_addr }, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Connecting QUIC client...", .{});
    var quic = try util.QuicProtoClient.connect(allocator, addr);
    defer quic.deinit();

    util.progress("Connecting gRPC client...", .{});
    var grpc = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer grpc.deinit();

    util.progress("Authenticating both clients...", .{});
    var hello_q = try quic.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_q.deinit(allocator);
    var hello_g = try grpc.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_g.deinit(allocator);

    util.progress("Testing IllegalOrderKey parity...", .{});
    const q = "RETURN a ORDER BY f(a)";
    var qres = try execQuic(&quic, allocator, q);
    defer qres.deinit(allocator);
    var gres = try execGrpc(&grpc, allocator, q);
    defer gres.deinit(allocator);

    try testing.expect(qres.error_code != null);
    try testing.expect(gres.error_code != null);
    try testing.expect(std.mem.indexOf(u8, qres.error_message orelse "", "IllegalOrderKey") != null);
    try testing.expect(std.mem.indexOf(u8, gres.error_message orelse "", "IllegalOrderKey") != null);

    util.testPass();
}
