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

// CANARY: REQ=REQ-GQL-010; FEATURE="US001 Unordered Pagination (varlen)"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_VarLenUnorderedPaginationReject; OWNER=planner; UPDATED=2025-09-24
test "protocol: MATCH varlen LIMIT+OFFSET without ORDER (US001)" {
    const exe = "./zig-out/bin/geodec";
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b LIMIT 10 OFFSET 2";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}
