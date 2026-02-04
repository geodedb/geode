const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runQuery(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{
            "./zig-out/bin/geode",
            "query",
            query,
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
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 14);
    _ = try child.wait();
    return out;
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Golden-ish schema test: ensure stable leading field ordering for first op and totals presence.
// We assert substrings in expected relative order to avoid brittle full-line goldens while freezing key fields.

test "protocol: PROFILE golden simple query" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3196";
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const out = try runQuery(allocator, addr, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1");
    defer allocator.free(out);

    const req = [_][]const u8{
        "\"profile_version\":1",
        "\"ops\":[",
        "\"op\":\"Project\"",
        "\"phase\":\"PROJECT\"",
        "\"id\":0",
        "\"op_index\":0",
        "\"rows\":1",
        "\"totals\":{",
        "\"time_ns\":",
        "\"peak_bytes\":",
    };
    var last_pos: usize = 0;
    for (req) |needle| {
        const p = std.mem.indexOfPos(u8, out, last_pos, needle) orelse return error.MissingSubstring;
        last_pos = p + needle.len;
    }
    try testing.expect(contains(out, "\"profile\""));
}
