const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const parity = @import("transport_parity_util.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Order Metadata"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_OrderMetadata; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity order metadata (ordered + order_keys)" {
    util.testStart("transport parity order metadata");
    errdefer util.testFail();

    const allocator = testing.allocator;
    const q = "RETURN 2 AS a, 1 AS b UNION RETURN 1 AS a, 2 AS b ORDER BY a, b LIMIT 2";

    var parity_run = parity.runParityRandom(
        allocator,
        q,
        util.emptyParams(),
        util.emptyParams(),
        100,
        // `util.GrpcProtoClient` speaks plaintext HTTP/2 while the gRPC
        // listener is TLS-required and fail-closed; without the Debug-only
        // plaintext opt-in the gRPC arm never connects and this smoke silently
        // downgrades to a skip.
        util.TestEnv.grpcPlaintext(),
    ) catch |err| {
        util.progress("Parity run failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer parity_run.server.deinit();
    defer parity_run.result.quic.deinit(allocator);
    defer parity_run.result.grpc.deinit(allocator);

    util.progress("Comparing order metadata...", .{});
    try testing.expectEqual(parity_run.result.quic.ordered, parity_run.result.grpc.ordered);
    try testing.expectEqual(parity_run.result.quic.order_keys.len, parity_run.result.grpc.order_keys.len);
    for (parity_run.result.quic.order_keys, 0..) |key, i| {
        try testing.expect(std.mem.eql(u8, key, parity_run.result.grpc.order_keys[i]));
    }

    util.testPass();
}
