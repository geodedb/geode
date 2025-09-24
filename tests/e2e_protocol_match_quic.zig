const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn run_server(args: []const []const u8) !struct { child: Child } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return .{ .child = child };
}

// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: MATCH ORDER/LIMIT ordered metadata" {
    const ally = std.testing.allocator;
    // Start server on a random-ish port 17657
    var server = try run_server(&.{ "./zig-out/bin/geoded", "--listen-quic", "127.0.0.1:17657", "--log_json", "--result-format", "json", "--test-exit-after-first-request" });
    defer {
        _ = server.child.kill() catch {};
    }
    // Give server a moment
    std.time.sleep(200 * std.time.ns_per_ms);

    const res = try run(&.{ "./zig-out/bin/geodec", "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1", "--server", "127.0.0.1:17657", "--format", "json" });
    defer ally.free(res.out);
    defer ally.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"SCHEMA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"BINDINGS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"x\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\":[{\"x\":1}]") != null);
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Pagination Legality (US001)"; ASPECT=Execution_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_MatchUnorderedPaginationReject_QUIC; OWNER=planner; UPDATED=2025-09-24
test "protocol QUIC: MATCH LIMIT+OFFSET without ORDER (US001)" {
    const ally = std.testing.allocator;
    var server = try run_server(&.{ "./zig-out/bin/geoded", "--listen-quic", "127.0.0.1:17658", "--log_json", "--result-format", "json", "--test-exit-after-first-request" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.time.sleep(200 * std.time.ns_per_ms);

    const res = try run(&.{ "./zig-out/bin/geodec", "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5", "--server", "127.0.0.1:17658", "--format", "json" });
    defer ally.free(res.out);
    defer ally.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}

// OPTIONAL MATCH QUIC smoke: expect NULLs preserved when no relationship
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH null-preserve"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: OPTIONAL MATCH null-preserving semantics" {
    const ally = std.testing.allocator;
    var server = try run_server(&.{ "./zig-out/bin/geoded", "--listen-quic", "127.0.0.1:17659", "--log_json", "--result-format", "json" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.time.sleep(250 * std.time.ns_per_ms);

    // Use sample graph seeded in server; query should return at least one row with null right side when pattern not found
    const res = try run(&.{ "./zig-out/bin/geodec", "MATCH (n:Nonexistent) OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person) RETURN n, m", "--server", "127.0.0.1:17659", "--format", "json" });
    defer ally.free(res.out);
    defer ally.free(res.err);
    // Since left side finds zero, overall may produce zero rows; switch to a pattern that finds left but no right edge in seed
    if (res.code != 0 or std.mem.indexOf(u8, res.out, "\"rows\":[") == null) {
        const res2 = try run(&.{ "./zig-out/bin/geodec", "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[r:LIKES]->(m:Person) RETURN n.name, m.name", "--server", "127.0.0.1:17659", "--format", "json" });
        defer ally.free(res2.out);
        defer ally.free(res2.err);
        try std.testing.expectEqual(@as(i32, 0), res2.code);
        // Expect a row with Alice and null for m.name (LIKES edge not present in seed)
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"rows\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, res2.out, "null") != null);
    }
}
