const std = @import("std");
const util = @import("proto_test_util.zig");

// Forces a HashAgg spill by setting GEODE_SPILL_THRESHOLD_BYTES very low and running a GROUP query.
// Asserts PROFILE totals include hashagg_spills and hashagg_spill_reason.

pub fn main() !void {
    util.testStart("HashAgg spill forced");
    errdefer util.testFail();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get random port with spill threshold override
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    const env = &[_][]const u8{
        util.TestEnv.GEODE_ALLOW_NO_AUTH,
        util.TestEnv.GEODE_DISABLE_AUDIT,
        util.TestEnv.GEODE_TEST_MODE,
        "GEODE_SPILL_THRESHOLD_BYTES=1",
    };

    util.progress("Starting server on port {d} with low spill threshold...", .{port});
    var server = util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, env) catch |err| {
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

    util.progress("Connecting to server...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Executing PROFILE GROUP BY query to force spill...", .{});
    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x, 2 AS y GROUP BY x");
    defer allocator.free(profile_json);

    util.progress("Verifying spill metrics in profile...", .{});
    if (std.mem.indexOf(u8, profile_json, "\"hashagg_spills\":") == null) return error.ExpectedSpillMetric;
    if (std.mem.indexOf(u8, profile_json, "\"hashagg_spill_reason\"") == null) return error.ExpectedSpillReason;

    util.testPass();
}
