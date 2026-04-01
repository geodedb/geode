const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

const RunResult = struct { code: i32, out: []u8, err: []u8 };

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !RunResult {
    const res = try cli_test_util.runAgainstServer(allocator, addr, args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics US001"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_US001; OWNER=engine; UPDATED=2025-09-24
test "protocol: transport parity diagnostics (US001) QUIC (gated)" {
    util.testStart("transport parity diagnostics (US001) QUIC");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    const q = "RETURN 1 LIMIT 10 OFFSET 5";

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running first query...", .{});
    const qres = try run(allocator, addr, &.{ exe, q, "--format", "json" });
    defer allocator.free(qres.out);
    defer allocator.free(qres.err);
    try std.testing.expectEqual(@as(i32, 2), qres.code);
    try std.testing.expect(contains(qres.err, "US001"));
    try std.testing.expect(contains(qres.err, "16.18"));

    util.progress("Running second query...", .{});
    const qres2 = try run(allocator, addr, &.{ exe, q, "--format", "json" });
    defer allocator.free(qres2.out);
    defer allocator.free(qres2.err);
    try std.testing.expectEqual(@as(i32, 2), qres2.code);
    try std.testing.expect(contains(qres2.err, "US001"));
    try std.testing.expect(contains(qres2.err, "16.18"));

    util.testPass();
}
