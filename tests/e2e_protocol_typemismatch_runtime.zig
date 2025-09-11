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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// Trigger runtime TypeMismatch: attempt arithmetic across string & int via implicit projection
// Query: RETURN ("a" + 1) AS x  (our evaluator only supports Int+Int, so this yields TypeMismatch)

test "protocol: runtime TypeMismatch surfaced as error" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN (\"a\" + 1) AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Expect exit code 2 and stderr mentioning TypeMismatch
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "TypeMismatch"));
}
