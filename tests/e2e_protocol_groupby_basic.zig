const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn runOne(allocator: std.mem.Allocator, server: []const u8, query: []const u8) ![]u8 {
    var child = Child.init(&.{ "./zig-out/bin/geode", "query", query, "--server", server, "--format", "json" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    try testing.expect(term == .Exited and term.Exited == 0);
    return stdout;
}

// Simple aggregation query: RETURN a, COUNT(*) GROUP BY a ORDER BY a
// Expected: schema lists columns a, c (heuristic type INT); rows contain distinct a values with counts.

test "group by basic non-profile" {
    const allocator = testing.allocator;
    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17674", "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const out = try runOne(allocator, "127.0.0.1:17674", "RETURN 1 AS a, COUNT(*) AS c GROUP BY a ORDER BY a LIMIT 10");
    defer allocator.free(out);
    // Expect columns and rows
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\"") != null);
    // Expect at least one row with {"a":1,"c":1} (ordering of keys within object stable in build)
    try testing.expect(std.mem.indexOf(u8, out, "{\"a\":1,\"c\":1}") != null or std.mem.indexOf(u8, out", "{\"c\":1,\"a\":1}") != null);
}
