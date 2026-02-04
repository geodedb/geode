const std = @import("std");
const testing = std.testing;

extern fn geode_server_start() void; // placeholder if needed

fn run_query(allocator: std.mem.Allocator, exe: []const u8, query: []const u8) ![]const u8 {
    var argv = [_][]const u8{ exe, query, "--insecure" };
    var child = std.ChildProcess.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    defer child.deinit();
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    return try allocator.dupe(u8, out.items);
}

fn run_server_and_query(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    // Start server in background
    var server = std.ChildProcess.init(&[_][]const u8{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:7567" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    try server.spawn();
    defer server.kill() catch {};

    // give server a moment
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Use CLI over TCP
    var argv = [_][]const u8{ "./zig-out/bin/geode", query", "--server", "127.0.0.1:7567", "--insecure" };
    var child = std.ChildProcess.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    defer child.deinit();
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    return try allocator.dupe(u8, out.items);
}

test "MATCH node scan returns nodes" {
    const allocator = testing.allocator;
    const res = try run_server_and_query(allocator, "RETURN 1"); // warm up server
    allocator.free(res);
    const out = try run_server_and_query(allocator, "MATCH (n) RETURN n");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\":[") != null);
}

test "MATCH edge traversal returns pairs" {
    const allocator = testing.allocator;
    const out = try run_server_and_query(allocator, "MATCH (n)-[r]->(m) RETURN n, m");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\":[") != null);
}

test "MATCH with label and property filter" {
    const allocator = testing.allocator;
    const out = try run_server_and_query(allocator, "MATCH (n:Person) WHERE n.age > 30 RETURN n.name");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
}

test "MATCH traversal with edge type filter" {
    const allocator = testing.allocator;
    const out = try run_server_and_query(allocator, "MATCH (n)-[r:KNOWS]->(m) RETURN n, r, m");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"SCHEMA\"") != null);
}
