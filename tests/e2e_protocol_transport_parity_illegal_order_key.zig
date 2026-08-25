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

    // Two env requirements:
    //   * `util.GrpcProtoClient` speaks plaintext HTTP/2 while the gRPC
    //     listener is TLS-required and fail-closed, so this smoke must opt
    //     into the Debug-only plaintext fallback (grpc_server.zig:151) or the
    //     connection is refused before a single frame is exchanged.
    //   * The ORDER-key policy defaults to the standards-correct
    //     expression form (`server_flags.g_order_keys_expr = true`), under
    //     which `ORDER BY f(a)` is legal and returns rows. The IllegalOrderKey
    //     diagnostic only exists under the opt-in ident-only policy, so pin it
    //     with `GEODE_ORDER_KEYS_EXPR=0` (server_init.zig:233).
    var server = util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--listen-grpc", grpc_addr }, &.{
        "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1",
        "GEODE_QUIC_PASSIVE_TEARDOWN=1",
        "GEODE_ORDER_KEYS_EXPR=0",
    }) catch |err| {
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

    // Both transports must reject, with the SAME status class and the SAME
    // message — that identity is what "transport parity" means here. The
    // `IllegalOrderKey` code name (diagnostics.zig:22) is an internal
    // classification and is deliberately NOT part of the wire payload; the
    // wire contract is the GQL status class plus the parser message that
    // `diagnostics.mapParserMessage` classifies as IllegalOrderKey.
    const expected_message = "function calls in ORDER BY are disabled";

    try testing.expect(qres.error_code != null);
    try testing.expect(gres.error_code != null);
    try testing.expectEqualStrings("42000", qres.error_code.?);
    try testing.expectEqualStrings("42000", gres.error_code.?);
    try testing.expectEqualStrings(expected_message, qres.error_message orelse "");
    try testing.expectEqualStrings(expected_message, gres.error_message orelse "");
    try testing.expectEqualStrings(qres.status_class, gres.status_class);

    util.testPass();
}
