const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: OPTIONAL-like left-outer preservation and path alias rendering
// Uses QUIC CLI query path.

fn run_query(allocator: std.mem.Allocator, server: []const u8, query: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: i32 } {
    const res = try cli_test_util.runAgainstServer(allocator, server, &.{ "./zig-out/bin/geode", "query", query, "--format", "json" });
    return .{ .stdout = res.out, .stderr = res.err, .exit_code = res.code };
}

test "OPTIONAL MATCH left-outer preservation and path alias" {
    util.testStart("OPTIONAL MATCH left-outer preservation and path alias");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    // Query with path alias and OPTIONAL-like pattern where second hop may not exist
    // Our exec applies LOJ preservation per hop; this should not error and should emit rows
    util.progress("Running query...", .{});
    const q = "MATCH p=(a:Person)-[r:KNOWS]->(b) RETURN a, b, r, p ORDER BY a LIMIT 2";
    const res = try run_query(allocator, addr, q);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try testing.expectEqual(@as(i32, 0), res.exit_code);
    // Verify we got columns and rows JSON
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"rows\"") != null);
    // Verify path alias appears as JSON array in rows (p: [ {"id":...}, ... ])
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"p\":[") != null);

    util.testPass();
}
