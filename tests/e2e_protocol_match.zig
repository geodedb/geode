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

// Basic E2E over stdio for MATCH ORDER/LIMIT and US001 policy
// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit; OWNER=engine; UPDATED=2025-09-24
test "protocol: MATCH ORDER/LIMIT ordered metadata" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"SCHEMA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"BINDINGS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"x\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\":[{\"x\":1}]") != null);
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Pagination Legality (US001)"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_MatchUnorderedPaginationReject; OWNER=planner; UPDATED=2025-09-24
test "protocol: MATCH LIMIT+OFFSET without ORDER (US001)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}

test "protocol: MATCH DISTINCT dedup rows" {
    const exe = "./zig-out/bin/geodec";
    // Two identical rows under MATCH projection should dedup to a single row when DISTINCT present.
    const res = try run(&.{ exe, "MATCH (n) RETURN DISTINCT 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect ordered=false default and single row {"x":1}
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":false") != null);
    // Count number of rows
    var cnt: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "{\"x\":1}") != null) cnt += 1;
    }
    try std.testing.expect(cnt == 1);
}
