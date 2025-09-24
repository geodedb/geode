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

// Bounded variable-length path determinism over stdio
// Graph: rely on server's sample graph (Alice->Bob KNOWS, Bob->Charlie KNOWS)
// Expect deterministic rows and order metadata when ORDER applied.
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_STDIO; OWNER=engine; UPDATED=2025-09-24
test "protocol: MATCH varlen 1..2 determinism (stdio)" {
    const exe = "./zig-out/bin/geodec";
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b";
    const res = try run(&.{ exe, q, "--format", "json" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Ordered true with keys ["a","b"]
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"a\",\"b\"]") != null);
    // Expect subset rows including Alice->Bob and Alice->Charlie, Bob->Charlie (names)
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Bob\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Charlie\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Bob\",\"b\":\"Charlie\"}") != null);
}
