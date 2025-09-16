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

// PROFILE test for NodeIndexScan metadata inline
test "protocol: PROFILE NodeIndexScan metadata" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x WHERE 1 = 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Should include PROFILE frame
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"PROFILE\"") != null);
    // Should include NodeIndexScan op name and metadata fields
    try std.testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"index_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"selectivity_est\"") != null);
    // Ensure no stale IndexMeta stub
    try std.testing.expect(std.mem.indexOf(u8, res.out, "IndexMeta") == null);
}
