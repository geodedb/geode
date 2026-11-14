const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: ensure spill_reason appears when memory threshold exceeded

test "protocol PROFILE sort_spill" {
    util.testStart("PROFILE sort_spill");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port with spill threshold override
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    const env = &[_][]const u8{
        "GEODE_SPILL_THRESHOLD_BYTES=1",
    };

    util.progress("Starting server on port {d} with low spill threshold...", .{port});
    var server = util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, env) catch |err| {
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

    util.progress("Executing PROFILE ORDER BY query...", .{});
    const json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x");
    defer allocator.free(json);

    util.progress("Verifying spill_reason in profile...", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const spills = root.object.get("spills") orelse return error.MissingSpills;
    const reason = spills.object.get("spill_reason") orelse return error.MissingSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);

    util.testPass();
}
