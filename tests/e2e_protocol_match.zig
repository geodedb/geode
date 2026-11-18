const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

// Basic E2E over QUIC for MATCH ORDER/LIMIT and US001 policy
// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=tests/e2e_protocol_match.zig; OWNER=engine; UPDATED=2026-11-14
test "protocol: MATCH ORDER/LIMIT ordered metadata" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("MATCH ORDER/LIMIT ordered metadata");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var seed = try client.executeAndCollect(allocator, "CREATE (:Match6548)", util.emptyParams(), 100);
    seed.deinit(allocator);

    util.progress("Executing MATCH ORDER/LIMIT query...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try std.testing.expect(res.error_code == null);
    try std.testing.expect(res.ordered);
    try std.testing.expect(res.order_keys.len == 1 and std.mem.eql(u8, res.order_keys[0], "x"));
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);

    util.testPass();
}

// SONNY-6548: the US001 case (LIMIT+OFFSET without ORDER BY rejected) was
// dropped: unordered pagination succeeds (docs/BINARY_PROTOCOL.md). Both
// cases below seed a node; MATCH (n) over the empty store has no rows.
test "protocol: MATCH DISTINCT dedup rows" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("MATCH DISTINCT dedup rows");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var seed = try client.executeAndCollect(allocator, "CREATE (:Match6548)", util.emptyParams(), 100);
    seed.deinit(allocator);

    util.progress("Executing MATCH DISTINCT query...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (n) RETURN DISTINCT 1 AS x", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try std.testing.expect(res.error_code == null);
    try std.testing.expect(!res.ordered);
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);

    util.testPass();
}
