const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
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

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchGuardStatusWireMapping"; ASPECT=Wire; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchGuardStatusWireMappingThreshold2; OWNER=engine; UPDATED=2025-09-25
// This test sets max_results=2 and expects ExecutionGuardTrip advisory still surfaces (query produces >2 rows)

fn query() []const u8 {
    return "MATCH (a:Person)-[:KNOWS*1..3]->(b:Person) RETURN a, b ORDER BY a";
}

test "protocol: MATCH guard trip with --match-max-results 2 surfaces advisory" {
    const exe = "./zig-out/bin/geode";
    const server = "./zig-out/bin/geode";
    const q = query();
    const res = try run(&.{ exe, q, "--server", server", "--server-arg", "--match-max-results", "--server-arg", "2" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "ExecutionGuardTrip") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "additional_statuses") != null);
}
