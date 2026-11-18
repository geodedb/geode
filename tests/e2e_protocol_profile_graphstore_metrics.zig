const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

// E2E: PROFILE should include GraphStore metrics.

test "protocol PROFILE graph_store metrics present" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("PROFILE graph_store metrics present");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr },
        util.TestEnv.standard(),
    );
    defer server.deinit();

    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Running PROFILE query...", .{});
    var child = std.process.Child.init(
        &.{
            geode_test_bin.geode_exe,
            "query",
            "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1",
            "--server",
            addr,
            "--insecure",
            "--user",
            util.defaultUsername(),
            "--password",
            util.defaultPassword(),
            "--format",
            "json",
        },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(out);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(err);
    _ = try child.wait();

    if (std.mem.indexOf(u8, out, "\"graph_store_nodes\":") == null or
        std.mem.indexOf(u8, out, "\"graph_store_dirty\":") == null)
    {
        std.debug.print("STDOUT=\n{s}\nSTDERR=\n{s}\n", .{ out, err });
        util.testFail();
        return error.MissingGraphStoreMetrics;
    }

    util.testPass();
}
