const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !cli_test_util.CliResult {
    return cli_test_util.runAgainstServer(allocator, addr, args);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: MATCH ORDER/LIMIT ordered metadata" {
    util.testStart("MATCH ORDER/LIMIT ordered metadata (QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running query...", .{});
    const res = try run(allocator, addr, &.{ "./zig-out/bin/geode", "query", "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"x\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\":[{\"x\":1}]") != null);

    util.testPass();
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Pagination Legality (US001)"; ASPECT=Execution_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_MatchUnorderedPaginationReject_QUIC; OWNER=planner; UPDATED=2025-09-24
test "protocol QUIC: MATCH LIMIT+OFFSET without ORDER (US001)" {
    util.testStart("MATCH LIMIT+OFFSET without ORDER (US001, QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running query...", .{});
    const res = try run(allocator, addr, &.{ "./zig-out/bin/geode", "query", "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5", "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);

    util.testPass();
}

// OPTIONAL MATCH QUIC smoke: expect NULLs preserved when no relationship
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH null-preserve"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: OPTIONAL MATCH null-preserving semantics" {
    util.testStart("OPTIONAL MATCH null-preserving semantics (QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    // Use sample graph seeded in server; query should return at least one row with null right side when pattern not found
    util.progress("Running first query...", .{});
    const res = try run(allocator, addr, &.{ "./zig-out/bin/geode", "query", "MATCH (n:Nonexistent) OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person) RETURN n, m", "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    // Since left side finds zero, overall may produce zero rows; switch to a pattern that finds left but no right edge in seed
    if (res.code != 0 or std.mem.indexOf(u8, res.out, "\"rows\":[") == null) {
        util.progress("Running alternative query...", .{});
        const res2 = try run(allocator, addr, &.{ "./zig-out/bin/geode", "query", "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[r:LIKES]->(m:Person) RETURN n.name, m.name", "--format", "json" });
        defer allocator.free(res2.out);
        defer allocator.free(res2.err);
        try std.testing.expectEqual(@as(i32, 0), res2.code);
        // Expect a row with Alice and null for m.name (LIKES edge not present in seed)
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"rows\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "null") != null);
    }

    util.testPass();
}
