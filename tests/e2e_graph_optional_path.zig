const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: OPTIONAL-like left-outer preservation and path alias rendering
// Uses QUIC CLI query path.

fn run_query(allocator: std.mem.Allocator, server: []const u8, query: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: i32 } {
    const res = try cli_test_util.runAgainstServer(allocator, server, &.{ geode_test_bin.geode_exe, "query", query, "--format", "json" });
    return .{ .stdout = res.out, .stderr = res.err, .exit_code = res.code };
}

test "OPTIONAL MATCH left-outer preservation and path alias" {
    util.testStart("OPTIONAL MATCH left-outer preservation and path alias");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    // SONNY-6548: the test assumed a seeded Person graph (the server starts
    // empty) and the deleted client's path rendering (`"p":[...]`); a PATH
    // renders as `{"nodes":[...],"edges":[...]}` (query_result_accumulator).
    util.progress("Seeding...", .{});
    const seed = try run_query(allocator, addr, "CREATE (:OptPath6548 {name: 'A'})-[:KNOWS6548]->(:OptPath6548 {name: 'B'})");
    defer allocator.free(seed.stdout);
    defer allocator.free(seed.stderr);
    try testing.expectEqual(@as(i32, 0), seed.exit_code);

    util.progress("Running path query...", .{});
    const res = try run_query(allocator, addr, "MATCH p = (a:OptPath6548)-[r:KNOWS6548]->(b) RETURN a.name AS a, b.name AS b, p ORDER BY a LIMIT 2");
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try testing.expectEqual(@as(i32, 0), res.exit_code);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "{\"name\":\"p\",\"type\":\"PATH\"}") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"a\":\"A\",\"b\":\"B\",\"p\":{\"nodes\":[") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"edges\":[{") != null);

    // OPTIONAL MATCH preserves the row with no match (left outer join).
    util.progress("Running OPTIONAL MATCH query...", .{});
    const opt = try run_query(allocator, addr, "MATCH (a:OptPath6548) OPTIONAL MATCH (a)-[:KNOWS6548]->(b) RETURN a.name AS a, b.name AS b ORDER BY a");
    defer allocator.free(opt.stdout);
    defer allocator.free(opt.stderr);
    try testing.expectEqual(@as(i32, 0), opt.exit_code);
    try testing.expect(std.mem.indexOf(u8, opt.stdout, "\"rows\":[{\"a\":\"A\",\"b\":\"B\"},{\"a\":\"B\",\"b\":null}]") != null);

    util.testPass();
}
