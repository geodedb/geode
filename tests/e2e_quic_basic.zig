const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICBasicE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICBasicE2E; OWNER=wire; UPDATED=2025-09-22

fn run_quic(allocator: std.mem.Allocator, addr: []const u8) !cli_test_util.CliResult {
    return cli_test_util.runAgainstServer(allocator, addr, &.{ geode_test_bin.geode_exe, "query", "RETURN 1 AS x ORDER BY x LIMIT 1" });
}

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICProtocol; OWNER=wire; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_074_QUICProtocol" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("QUIC Protocol basic");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = try util.spawnServerRandom(allocator, util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Starting QUIC server on {s}...", .{addr});
    const r = try run_quic(allocator, addr);
    defer allocator.free(r.out);
    defer allocator.free(r.err);

    util.progress("Verifying response...", .{});
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);

    util.testPass();
}
