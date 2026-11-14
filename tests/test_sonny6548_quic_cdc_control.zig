//! SONNY-6548 reproduction (intentionally red until fixed; KNOWN_TEST_ISSUES).
//!
//! The QUIC CDC_CONTROL and CDC_DIAGNOSTICS frames read
//! `ServerState.cdc_engine` (src/server/quic_connection_handler.zig, the
//! `.cdc_diag` and `.cdc_ctrl` arms), a field nothing assigns
//! (src/server/server_state.zig declares it `= null`). CDC runs in
//! `storage_dispatch.global_cdc_engine`, which `CALL cdc.enable()` starts and
//! the gRPC CdcControl handler reads (src/transport/grpc_server.zig,
//! "parity with QUIC handler"). So over QUIC, with CDC running, CDC_CONTROL
//! answers NO_ENGINE and CDC_DIAGNOSTICS reports CDC disabled: the
//! RESET_GUARDRAILS action is unreachable and an unknown action is not
//! answered UNSUPPORTED.
//!
//! Replaces tests/e2e_protocol_cdc_control{,_unsupported,_malformed}.zig,
//! which set GEODE_CDC_ENABLE=1, a variable nothing reads.
const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn connectWithCdc(a: std.mem.Allocator, server: *util.ServerHandle) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(a, server.getAddr());
    errdefer client.deinit();
    var hello = try client.hello(a, util.defaultUsername(), util.defaultPassword());
    hello.deinit(a);
    var enable = try client.executeAndCollect(a, "CALL cdc.enable()", util.emptyParams(), 100);
    defer enable.deinit(a);
    try testing.expect(enable.error_code == null);
    return client;
}

test "SONNY-6548: QUIC CDC_CONTROL RESET_GUARDRAILS resets the running engine's guardrails (it answers NO_ENGINE)" {
    const a = testing.allocator;
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    var client = try connectWithCdc(a, &server);
    defer client.deinit();

    var diag1 = try client.cdcDiagnostics(a);
    defer diag1.deinit(a);
    var ctrl = try client.cdcControl(a, "RESET_GUARDRAILS");
    defer ctrl.deinit(a);
    if (!ctrl.success) std.debug.print("CDC running (CALL cdc.enable()); CDC_CONTROL RESET_GUARDRAILS answered '{s}'\n", .{ctrl.status});
    try testing.expectEqualStrings("OK", ctrl.status);
    try testing.expect(ctrl.success);

    var diag2 = try client.cdcDiagnostics(a);
    defer diag2.deinit(a);
    try testing.expectEqual(diag1.guardrail_epoch + 1, diag2.guardrail_epoch);
}

test "SONNY-6548: QUIC CDC_CONTROL answers UNSUPPORTED for an unknown or empty action while CDC runs (it answers NO_ENGINE)" {
    const a = testing.allocator;
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    var client = try connectWithCdc(a, &server);
    defer client.deinit();

    for ([_][]const u8{ "UNKNOWN_ACTION", "" }) |action| {
        var ctrl = try client.cdcControl(a, action);
        defer ctrl.deinit(a);
        if (!std.mem.eql(u8, ctrl.status, "UNSUPPORTED")) std.debug.print("CDC running; CDC_CONTROL '{s}' answered '{s}'\n", .{ action, ctrl.status });
        try testing.expect(!ctrl.success);
        try testing.expectEqualStrings("UNSUPPORTED", ctrl.status);
    }
}
