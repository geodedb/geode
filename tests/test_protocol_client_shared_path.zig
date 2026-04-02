const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const proto = @import("proto_test_util.zig");

// CANARY: REQ=REQ-CLI-SHARED-QUERY-008; FEATURE="ClientTransportSharedPath"; ASPECT=ParameterBindingParity; STATUS=TESTED; TEST=../geode-test-harness/geodetestlab-cli/specs/gql_parameter_binding.yml; OWNER=cli; UPDATED=2026-04-02
// CANARY: REQ=REQ-CLI-SHARED-QUERY-009; FEATURE="ClientTransportSharedPath"; ASPECT=LargeOrderedParity; STATUS=TESTED; TEST=../geode-test-harness/geodetestlab-cli/specs/gap_0257_orderby_large_resultset.yml; OWNER=cli; UPDATED=2026-04-02
// CANARY: REQ=REQ-CLI-SHARED-QUERY-010; FEATURE="ClientTransportSharedPath"; ASPECT=TransportExecutionParity; STATUS=TESTED; TEST=../geode-test-harness/geodetestlab-cli/specs/geode_quic_transport.yml; OWNER=cli; UPDATED=2026-04-02
// CANARY: REQ=REQ-CLI-SHARED-QUERY-011; FEATURE="ClientTransportSharedPath"; ASPECT=ErrorPayloadParity; STATUS=TESTED; TEST=../geode-test-harness/geodetestlab-cli/specs/query_output_formats.yml; OWNER=cli; UPDATED=2026-04-02

const ProtocolPair = struct {
    allocator: std.mem.Allocator,
    server: proto.ServerHandle,
    quic_addr: []const u8,
    grpc_addr: []const u8,
    quic_client: proto.QuicProtoClient,
    grpc_client: proto.GrpcProtoClient,

    fn deinit(self: *ProtocolPair) void {
        self.quic_client.deinit();
        self.grpc_client.deinit();
        self.server.deinit();
        self.allocator.free(self.quic_addr);
        self.allocator.free(self.grpc_addr);
    }
};

fn startProtocolPair(allocator: std.mem.Allocator) !ProtocolPair {
    const quic_port = try proto.getRandomPort();
    const grpc_port = try proto.getRandomPort();

    const quic_addr = try proto.formatAddr(allocator, quic_port);
    errdefer allocator.free(quic_addr);
    const grpc_addr = try proto.formatAddr(allocator, grpc_port);
    errdefer allocator.free(grpc_addr);

    var server = try proto.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr },
        null,
    );
    errdefer server.deinit();

    try proto.waitForServerReady(allocator, quic_addr, 10000);

    var quic_client = try proto.QuicProtoClient.connect(allocator, quic_addr);
    errdefer quic_client.deinit();
    var grpc_client = try proto.GrpcProtoClient.connect(allocator, grpc_addr);
    errdefer grpc_client.deinit();

    var hello_q = try quic_client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello_q.deinit(allocator);
    var hello_g = try grpc_client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello_g.deinit(allocator);

    return .{
        .allocator = allocator,
        .server = server,
        .quic_addr = quic_addr,
        .grpc_addr = grpc_addr,
        .quic_client = quic_client,
        .grpc_client = grpc_client,
    };
}

fn buildCreateBatchQuery(allocator: std.mem.Allocator, label: []const u8, count: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "CREATE ");
    for (1..count + 1) |id| {
        if (id != 1) try out.appendSlice(allocator, ", ");
        try out.writer(allocator).print(
            "(:{s} {{id: {d}, value: {d}}})",
            .{ label, id, id * 10 },
        );
    }
    return try out.toOwnedSlice(allocator);
}

test "protocol clients share parameter binding query path over QUIC and gRPC" {
    const allocator = testing.allocator;

    var pair = try startProtocolPair(allocator);
    defer pair.deinit();

    var quic_params = std.ArrayList(schema.Param){};
    try quic_params.append(allocator, try proto.makeIntParam(allocator, "age", 30));
    try quic_params.append(allocator, try proto.makeStringParam(allocator, "name", "Taylor"));

    var grpc_params = std.ArrayList(schema.Param){};
    try grpc_params.append(allocator, try proto.makeIntParam(allocator, "age", 30));
    try grpc_params.append(allocator, try proto.makeStringParam(allocator, "name", "Taylor"));

    var quic_res = try pair.quic_client.executeAndCollect(
        allocator,
        "CREATE (n:ProtoParamBind {age: $age, name: $name}) RETURN n.age AS age, n.name AS name",
        quic_params,
        64,
    );
    defer quic_res.deinit(allocator);

    var grpc_res = try pair.grpc_client.executeAndCollect(
        allocator,
        "CREATE (n:ProtoParamBind {age: $age, name: $name}) RETURN n.age AS age, n.name AS name",
        grpc_params,
        64,
    );
    defer grpc_res.deinit(allocator);

    try testing.expect(proto.execResultsEqual(quic_res, grpc_res));
    try testing.expectEqualStrings("00000", quic_res.status_class);
    try testing.expectEqual(@as(usize, 1), quic_res.rows.len);
}

test "protocol clients share ordered large-result query path over QUIC and gRPC" {
    const allocator = testing.allocator;

    var pair = try startProtocolPair(allocator);
    defer pair.deinit();

    const seed_query = try buildCreateBatchQuery(allocator, "ProtoSharedOrder", 256);
    defer allocator.free(seed_query);

    var seed_res = try pair.quic_client.executeAndCollect(allocator, seed_query, proto.emptyParams(), 128);
    defer seed_res.deinit(allocator);

    var quic_res = try pair.quic_client.executeAndCollect(
        allocator,
        "MATCH (n:ProtoSharedOrder) RETURN n.id AS id, n.value AS value ORDER BY id",
        proto.emptyParams(),
        128,
    );
    defer quic_res.deinit(allocator);

    var grpc_res = try pair.grpc_client.executeAndCollect(
        allocator,
        "MATCH (n:ProtoSharedOrder) RETURN n.id AS id, n.value AS value ORDER BY id",
        proto.emptyParams(),
        128,
    );
    defer grpc_res.deinit(allocator);

    try testing.expect(proto.execResultsEqual(quic_res, grpc_res));
    try testing.expect(quic_res.ordered);
    try testing.expectEqual(@as(usize, 256), quic_res.rows.len);
    try testing.expectEqualStrings("id", quic_res.order_keys[0]);
}

test "protocol clients share error query path over QUIC and gRPC" {
    const allocator = testing.allocator;

    var pair = try startProtocolPair(allocator);
    defer pair.deinit();

    var quic_res = try pair.quic_client.executeAndCollect(
        allocator,
        "RETURN (",
        proto.emptyParams(),
        64,
    );
    defer quic_res.deinit(allocator);

    var grpc_res = try pair.grpc_client.executeAndCollect(
        allocator,
        "RETURN (",
        proto.emptyParams(),
        64,
    );
    defer grpc_res.deinit(allocator);

    try testing.expect(quic_res.error_code != null);
    try testing.expect(grpc_res.error_code != null);
    try testing.expectEqualStrings(quic_res.error_code.?, grpc_res.error_code.?);
    try testing.expectEqualStrings(quic_res.error_message.?, grpc_res.error_message.?);
}
