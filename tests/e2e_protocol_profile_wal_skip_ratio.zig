const std = @import("std");
const util = @import("proto_test_util.zig");

// E2E: PROFILE should include wal_skip_ratio when override is set.

test "protocol PROFILE wal_skip_ratio override" {
    const allocator = std.testing.allocator;
    const addr = "127.0.0.1:3193";
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_WAL_SKIP_RATIO_OVERRIDE=0.7500" },
    );
    defer server.deinit();

    std.Thread.sleep(200 * std.time.ns_per_ms);

    var child = std.process.Child.init(
        &.{
            "./zig-out/bin/geode",
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

    if (std.mem.indexOf(u8, out, "\"wal_skip_ratio\":0.7500") == null) {
        std.debug.print("STDOUT=\n{s}\nSTDERR=\n{s}\n", .{ out, err });
        return error.MissingWalSkipRatio;
    }
}
