const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const parity = @import("transport_parity_util.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Order Metadata"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_OrderMetadata; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity order metadata (ordered + order_keys)" {

    const allocator = testing.allocator;
    const q = "RETURN 2 AS a, 1 AS b UNION RETURN 1 AS a, 2 AS b ORDER BY a, b LIMIT 2";
    const quic_addr = "127.0.0.1:17666";
    const grpc_addr = "127.0.0.1:17676";

    var parity_run = try parity.runParity(
        allocator,
        quic_addr,
        grpc_addr,
        q,
        util.emptyParams(),
        util.emptyParams(),
        100,
        &.{ "GEODE_QUIC_PASSIVE_TEARDOWN=1" },
    );
    defer parity_run.server.deinit();
    defer parity_run.result.quic.deinit(allocator);
    defer parity_run.result.grpc.deinit(allocator);

    try testing.expectEqual(parity_run.result.quic.ordered, parity_run.result.grpc.ordered);
    try testing.expectEqual(parity_run.result.quic.order_keys.len, parity_run.result.grpc.order_keys.len);
    for (parity_run.result.quic.order_keys, 0..) |key, i| {
        try testing.expect(std.mem.eql(u8, key, parity_run.result.grpc.order_keys[i]));
    }
}
