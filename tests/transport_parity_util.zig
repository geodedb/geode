const std = @import("std");
const schema = @import("schema");
const util = @import("proto_test_util.zig");

pub const ParityResult = struct {
    quic: util.ExecResult,
    grpc: util.ExecResult,
};

pub const ParityServer = struct {
    server: util.ServerHandle,
    quic_addr: []const u8,
    grpc_addr: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParityServer) void {
        self.server.deinit();
        self.allocator.free(self.quic_addr);
        self.allocator.free(self.grpc_addr);
    }
};

/// Run parity test with random ports
pub fn runParityRandom(
    allocator: std.mem.Allocator,
    query: []const u8,
    quic_params: std.ArrayList(schema.Param),
    grpc_params: std.ArrayList(schema.Param),
    page_size: u32,
    env: ?[]const []const u8,
) !struct { server: ParityServer, result: ParityResult } {
    // Get two random ports
    const quic_port = try util.getRandomPort();
    const grpc_port = try util.getRandomPort();

    const quic_addr = try util.formatAddr(allocator, quic_port);
    errdefer allocator.free(quic_addr);
    const grpc_addr = try util.formatAddr(allocator, grpc_port);
    errdefer allocator.free(grpc_addr);

    util.progress("Starting parity server (QUIC: {d}, gRPC: {d})...", .{ quic_port, grpc_port });

    // Merge env with standard test env
    var merged_env: [8][]const u8 = undefined;
    var env_count: usize = 0;
    merged_env[env_count] = util.TestEnv.GEODE_ALLOW_NO_AUTH;
    env_count += 1;
    merged_env[env_count] = util.TestEnv.GEODE_DISABLE_AUDIT;
    env_count += 1;
    merged_env[env_count] = util.TestEnv.GEODE_TEST_MODE;
    env_count += 1;
    if (env) |e| {
        for (e) |v| {
            if (env_count < merged_env.len) {
                merged_env[env_count] = v;
                env_count += 1;
            }
        }
    }

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr },
        merged_env[0..env_count],
    );
    errdefer server.deinit();

    // Wait for server readiness
    try util.waitForServerReady(allocator, quic_addr, 10000);

    util.progress("Connecting QUIC client...", .{});
    var quic_client = try util.QuicProtoClient.connect(allocator, quic_addr);
    defer quic_client.deinit();
    var hello_q = try quic_client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_q.deinit(allocator);

    util.progress("Connecting gRPC client...", .{});
    var grpc_client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer grpc_client.deinit();
    var hello_g = try grpc_client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_g.deinit(allocator);

    util.progress("Executing query on both transports...", .{});
    const quic_res = try quic_client.executeAndCollect(allocator, query, quic_params, page_size);
    const grpc_res = try grpc_client.executeAndCollect(allocator, query, grpc_params, page_size);

    return .{
        .server = .{
            .server = server,
            .quic_addr = quic_addr,
            .grpc_addr = grpc_addr,
            .allocator = allocator,
        },
        .result = .{ .quic = quic_res, .grpc = grpc_res },
    };
}

/// Legacy function for backwards compatibility
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

    // Wait for server readiness
    util.waitForServerReady(allocator, quic_addr, 10000) catch {};

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
