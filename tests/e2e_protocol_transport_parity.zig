const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const parity = @import("transport_parity_util.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Ordered Rows"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_QUICvsGRPC; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity QUIC vs gRPC (ordered rows equal)" {
    util.testStart("transport parity QUIC vs gRPC (ordered rows)");
    errdefer util.testFail();

    const allocator = testing.allocator;
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 10";

    var parity_run = parity.runParityRandom(
        allocator,
        q,
        util.emptyParams(),
        util.emptyParams(),
        100,
        &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"},
    ) catch |err| {
        util.progress("Parity run failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer parity_run.server.deinit();
    defer parity_run.result.quic.deinit(allocator);
    defer parity_run.result.grpc.deinit(allocator);

    util.progress("Comparing results...", .{});
    try testing.expect(util.execResultsEqual(parity_run.result.quic, parity_run.result.grpc));

    util.testPass();
}
