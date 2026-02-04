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
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    _ = try child.wait();
    return out;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: EXPLAIN emits explain payload" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3194";
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const out = try runQuery(allocator, addr, "EXPLAIN RETURN 1 AS x LIMIT 1");
    defer allocator.free(out);
    try testing.expect(contains(out, "\"explain\""));
}

test "protocol: PROFILE emits profile payload" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3195";
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const out = try runQuery(allocator, addr, "PROFILE RETURN 1 AS x LIMIT 1");
    defer allocator.free(out);
    try testing.expect(contains(out, "\"profile\""));
    try testing.expect(contains(out, "\"ops\""));
    try testing.expect(contains(out, "\"bytes_out\""));
    try testing.expect(contains(out, "\"bytes_alloc\""));
    try testing.expect(contains(out, "\"input_rows\""));
}
