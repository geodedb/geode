const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn execQuic(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 100);
}

fn execGrpc(client: *util.GrpcProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 100);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics IllegalOrderKey"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_IllegalOrderKey; OWNER=engine; UPDATED=2025-09-24

test "protocol: transport parity diagnostics (IllegalOrderKey) QUIC vs gRPC (gated)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const allocator = testing.allocator;
    const addr = "127.0.0.1:3191";
    const grpc_addr = "127.0.0.1:3192";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--listen-grpc", grpc_addr }, null);
    defer server.deinit();

    var quic = try util.QuicProtoClient.connect(allocator, addr);
    defer quic.deinit();
    var grpc = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer grpc.deinit();

    var hello_q = try quic.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_q.deinit(allocator);
    var hello_g = try grpc.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_g.deinit(allocator);

    const q = "RETURN a ORDER BY f(a)";
    var qres = try execQuic(&quic, allocator, q);
    defer qres.deinit(allocator);
    var gres = try execGrpc(&grpc, allocator, q);
    defer gres.deinit(allocator);

    try testing.expect(qres.error_code != null);
    try testing.expect(gres.error_code != null);
    try testing.expect(std.mem.indexOf(u8, qres.error_message orelse "", "IllegalOrderKey") != null);
    try testing.expect(std.mem.indexOf(u8, gres.error_message orelse "", "IllegalOrderKey") != null);
}
