//! SONNY-6596 item 7: the test helper's gRPC client runs several queries on
//! one HTTP/2 connection.
//!
//! `tests/proto_test_util.zig` `GrpcProtoClient` sent every RPC on one
//! stream id (the SONNY-6567 item 1 defect, in the test helper), so a second
//! query on a connection failed with IncompleteResponse and the tests opened
//! a connection per query. SONNY-6567 gave the client a `StreamIds`
//! allocator (`stream_ids.take()` per RPC). This drives HELLO and then
//! several queries, a parameterized one included, over one connection
//! against a real `geode serve`.
//!
//! CANARY: REQ=REQ-SONNY-6596-GRPC-HELPER-STREAMS; FEATURE="TestInfrastructure"; ASPECT=GrpcClientStreamReuse; STATUS=TESTED; TEST=tests/test_sonny6596_grpc_client_reuse.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

test "SONNY-6596: GrpcProtoClient runs several queries on one connection" {
    // SONNY-6782: plaintext gRPC is served in Debug only.
    if (!util.grpc_plaintext_served) return error.SkipZigTest;
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const quic_port = try util.getRandomPort();
    var grpc_port = try util.getRandomTcpPort();
    while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
    const quic_addr = try util.formatAddr(a, quic_port);
    defer a.free(quic_addr);
    const grpc_addr = try util.formatAddr(a, grpc_port);
    defer a.free(grpc_addr);

    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
    defer handle.deinit();
    try util.waitForServerReady(a, quic_addr, 10000);

    var grpc = try util.GrpcProtoClient.connect(a, grpc_addr);
    defer grpc.deinit();
    var hello = try grpc.hello(a, util.defaultUsername(), util.defaultPassword());
    hello.deinit(a);

    var i: i64 = 1;
    while (i <= 4) : (i += 1) {
        // The query takes the parameters (test_protocol_client_shared_path.zig).
        var params = util.emptyParams();
        try params.append(a, try util.makeIntParam(a, "i", i));
        var r = try grpc.executeAndCollect(a, "RETURN $i * 10 AS x", params, 100);
        defer r.deinit(a);
        try testing.expect(r.error_code == null);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expectEqual(@as(i64, i * 10), r.rows[0][0].int);
    }
}
