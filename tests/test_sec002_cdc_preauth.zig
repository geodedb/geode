// SEC-002: Unauthenticated CDC arm access regression (#849).
//
// Before the fix, a client that skips the HELLO handshake could send
// .cdc_ctrl or .cdc_diag directly and get a real response.  These tests
// reproduce that bug (RED pre-fix) and verify the per-arm guards close it
// (GREEN post-fix).
//
// Run via: zig build test-sec002-cdc-preauth

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn spawnCdcServer(allocator: std.mem.Allocator) !util.ServerHandle {
    // auth is enabled by default; GEODE_CDC_ENABLE=1 makes the cdc_engine present
    const env = &[_][]const u8{"GEODE_CDC_ENABLE=1"};
    return util.spawnServerRandom(allocator, env);
}

test "unauthenticated connection cannot invoke cdc_ctrl (SEC-002)" {
    const allocator = testing.allocator;
    var server = spawnCdcServer(allocator) catch {
        util.testSkip();
        return;
    };
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    // No hello/ensureHello — send cdc_ctrl as the very first message.
    try client.writeMessage(.{ .cdc_ctrl = .{ .action = "RESET_GUARDRAILS" } });
    var packet = try client.readPacket(allocator, 5000);
    defer packet.deinit(allocator);

    const msg = packet.quic orelse return error.NoResponse;
    // PRE-fix: server returns .cdc_ctrl{ success=true }. POST-fix: rejected
    // (either a .cdc_ctrl{ success=false } from the per-arm guard, or a
    // generic execute error from the systemic gate). Accept either rejection.
    switch (msg) {
        .cdc_ctrl => |r| try testing.expect(!r.success),
        else => {}, // a non-cdc_ctrl error reply is also a valid rejection
    }
}

test "unauthenticated connection cannot read cdc_diag (SEC-002)" {
    const allocator = testing.allocator;
    var server = spawnCdcServer(allocator) catch {
        util.testSkip();
        return;
    };
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    try client.writeMessage(.{ .cdc_diag = .{} });
    var packet = try client.readPacket(allocator, 5000);
    defer packet.deinit(allocator);

    const msg = packet.quic orelse return error.NoResponse;
    // PRE-fix: server returns a populated .cdc_diag payload. POST-fix: the
    // request is rejected before diagnostics are exported. A returned
    // .cdc_diag with engine.is_running data == leak; assert we do NOT get a
    // successful diagnostics export. Accept a generic error reply as rejection.
    switch (msg) {
        .cdc_diag => return error.DiagnosticsLeakedPreAuth, // any cdc_diag payload pre-auth is a leak
        else => {}, // error reply == rejected, good
    }
}

// NEW-9 (#867): connection-level default-deny gate — allow-list guard-rails.
// These tests verify that the gate does NOT over-block legitimate pre-auth
// traffic (.ping) and does NOT break authenticated paths.

test "unauthenticated ping is allowed (liveness allow-list)" {
    const allocator = testing.allocator;
    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch {
        util.testSkip();
        return;
    };
    defer server.deinit();
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();
    // ping is on the pre-auth allow-list — must still succeed without hello.
    try testing.expect(try client.ping(allocator));
}

test "authenticated admin CDC path reaches handler (gate positive control)" {
    const allocator = testing.allocator;
    const env = &[_][]const u8{"GEODE_CDC_ENABLE=1"};
    var server = util.spawnServerRandom(allocator, env) catch {
        util.testSkip();
        return;
    };
    defer server.deinit();
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);
    // cdcControl returns error.InvalidMessage if the gate blocks with an execute error.
    // A cdc_ctrl response (success or NO_ENGINE) proves the gate passed the request through.
    var ctrl = try client.cdcControl(allocator, "RESET_GUARDRAILS");
    defer ctrl.deinit(allocator);
    // Gate let it through — status must not be AUTH_REQUIRED (that would mean gate failed).
    try testing.expect(!std.mem.eql(u8, ctrl.status, "AUTH_REQUIRED"));
}
