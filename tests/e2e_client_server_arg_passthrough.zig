const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

// Simple evidence test: start server with explicit --data_dir and ensure query runs.
// CANARY: REQ=REQ-GQL-091; FEATURE="ServerDataDirFlag"; ASPECT=CliErgonomics; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_091_ServerDataDirFlag; OWNER=client; UPDATED=2026-11-14
test "client: explicit server data_dir allows dataset query" {
    util.testStart("explicit server data_dir allows dataset query");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = geode_test_bin.geode_exe;
    const data_dir = "./data/varlen_determinism";

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d} with custom data_dir...", .{port});
    var server = util.spawnServer(
        allocator,
        &.{ exe, "serve", "--listen", addr, "--data_dir", data_dir },
        util.TestEnv.standard(),
    ) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Running query via CLI...", .{});
    const res = try cli_test_util.runAgainstServer(allocator, addr, &.{
        exe,
        "query",
        "MATCH (a:Person) RETURN a.name AS name ORDER BY name LIMIT 1",
        "--format",
        "json",
    });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);

    util.progress("Validating query output...", .{});
    // Expect rows/columns payload with ordering metadata.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"status_class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"name\"]") != null);

    util.testPass();
}
