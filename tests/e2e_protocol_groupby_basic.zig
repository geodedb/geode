const std = @import("std");
const testing = std.testing;

fn runOne(query: []const u8) ![]u8 {
    var gpa = std.heap.page_allocator;
    const exe_path = try std.fs.path.join(gpa, &.{ "zig-out", "bin", "geoded" });
    defer gpa.free(exe_path);
    var child = std.process.Child.init(&.{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const w = child.stdin.?.writer();
    const r = child.stdout.?.reader();
    // HELLO
    try w.writeAll("{\"type\":\"HELLO\"}\n");
    // RUN_GQL (no PROFILE)
    try w.print("{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}\n", .{query});
    // PULL all (large page)
    try w.writeAll("{\"type\":\"PULL\",\"page_size\":1024}\n");
    child.stdin.?.close();
    var buf: [8192]u8 = undefined;
    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();
    while (true) {
        const n = r.read(&buf) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => 0,
        };
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    const term = try child.wait();
    try testing.expect(term == .Exited and term.Exited == 0);
    return try out.toOwnedSlice();
}

// Simple aggregation query: RETURN a, COUNT(*) GROUP BY a ORDER BY a
// Expected: schema lists columns a, c (heuristic type INT); rows contain distinct a values with counts.

test "group by basic non-profile" {
    const out = try runOne("RETURN 1 AS a, COUNT(*) AS c GROUP BY a ORDER BY a LIMIT 10");
    defer std.heap.page_allocator.free(out);
    // Expect SCHEMA then BINDINGS
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"BINDINGS\"") != null);
    // Expect at least one row with {"a":1,"c":1} (ordering of keys within object stable in build)
    try testing.expect(std.mem.indexOf(u8, out, "{\"a\":1,\"c\":1}") != null or std.mem.indexOf(u8, out", "{\"c\":1,\"a\":1}") != null);
}
