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

// OPTIONAL MATCH with varlen should null-preserve when no path exists
// Use Alice with no LIKES path of length 1..2
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH + VarLen NullPreserve"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalVarLenNull_STDIO; OWNER=engine; UPDATED=2025-09-24
test "protocol: OPTIONAL MATCH varlen null-preserving (stdio)" {
    const exe = "./zig-out/bin/geodec";
    const q = "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[:LIKES*1..2]->(m:Person) RETURN n.name AS a, m.name AS b ORDER BY a, b";
    const res = try run(&.{ exe, q, "--format", "json" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Must have ordered=true and at least one row with null for b
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "null") != null);
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

// QUIC variant
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH + VarLen NullPreserve"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalVarLenNull_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: OPTIONAL MATCH varlen null-preserving" {
    var server = try run_server(&.{ "./zig-out/bin/geoded", "--listen-quic", "127.0.0.1:17661", "--log_json", "--result-format", "json", "--test-exit-after-first-request" });
    defer {
        _ = server.child.kill() catch {};
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const res = try run(&.{ "./zig-out/bin/geodec", "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[:LIKES*1..2]->(m:Person) RETURN n.name AS a, m.name AS b ORDER BY a, b", "--server", "127.0.0.1:17661", "--format", "json" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "null") != null);
}
