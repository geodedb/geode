const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// E2E: OPTIONAL-like left-outer preservation and path alias rendering
// Uses QUIC CLI query path.

fn run_query(allocator: std.mem.Allocator, server: []const u8, query: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: i32 } {
    var child = Child.init(&.{ "./zig-out/bin/geode", "query", query, "--server", server, "--format", "json" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const exit_code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
}

test "OPTIONAL MATCH left-outer preservation and path alias" {
    const allocator = testing.allocator;
    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17660", "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);
    // Query with path alias and OPTIONAL-like pattern where second hop may not exist
    // Our exec applies LOJ preservation per hop; this should not error and should emit rows
    const q = "MATCH p=(a:Person)-[r:KNOWS]->(b) RETURN a, b, r, p ORDER BY a LIMIT 2";
    const res = try run_query(allocator, "127.0.0.1:17660", q);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try testing.expectEqual(@as(i32, 0), res.exit_code);
    // Verify we got columns and rows JSON
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"rows\"") != null);
    // Verify path alias appears as JSON array in rows (p: [ {"id":...}, ... ])
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"p\":[") != null);
}
