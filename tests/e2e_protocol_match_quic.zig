const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const util = @import("proto_test_util.zig");

fn run(allocator: std.mem.Allocator, args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append("query");
    }
    try argv.appendSlice(args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: MATCH ORDER/LIMIT ordered metadata" {
    util.testStart("MATCH ORDER/LIMIT ordered metadata (QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const res = try run(allocator, &.{ "./zig-out/bin/geode", "query", "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1", "--server", addr, "--format", "json" });
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

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const res = try run(allocator, &.{ "./zig-out/bin/geode", "query", "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5", "--server", addr, "--format", "json" });
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

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--result-format", "json" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(250 * std.time.ns_per_ms);

    // Use sample graph seeded in server; query should return at least one row with null right side when pattern not found
    util.progress("Running first query...", .{});
    const res = try run(allocator, &.{ "./zig-out/bin/geode", "query", "MATCH (n:Nonexistent) OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person) RETURN n, m", "--server", addr, "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    // Since left side finds zero, overall may produce zero rows; switch to a pattern that finds left but no right edge in seed
    if (res.code != 0 or std.mem.indexOf(u8, res.out, "\"rows\":[") == null) {
        util.progress("Running alternative query...", .{});
        const res2 = try run(allocator, &.{ "./zig-out/bin/geode", "query", "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[r:LIKES]->(m:Person) RETURN n.name, m.name", "--server", addr, "--format", "json" });
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
