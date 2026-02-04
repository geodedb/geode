const std = @import("std");
const schema = @import("schema");
const util = @import("proto_test_util.zig");

pub const ParityResult = struct {
    quic: util.ExecResult,
    grpc: util.ExecResult,
};

pub fn runParity(
    allocator: std.mem.Allocator,
    quic_addr: []const u8,
    grpc_addr: []const u8,
    query: []const u8,
    quic_params: std.ArrayList(schema.Param),
    grpc_params: std.ArrayList(schema.Param),
    page_size: u32,
    env: ?[]const []const u8,
) !struct { server: util.ServerHandle, result: ParityResult } {
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr },
        env,
    );

    var quic_client = try util.QuicProtoClient.connect(allocator, quic_addr);
    defer quic_client.deinit();
    var hello_q = try quic_client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_q.deinit(allocator);

    var grpc_client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer grpc_client.deinit();
    var hello_g = try grpc_client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_g.deinit(allocator);

    const quic_res = try quic_client.executeAndCollect(allocator, query, quic_params, page_size);
    const grpc_res = try grpc_client.executeAndCollect(allocator, query, grpc_params, page_size);

    return .{
        .server = server,
        .result = .{ .quic = quic_res, .grpc = grpc_res },
    };
}
