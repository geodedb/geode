const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 4096);
    const err = try child.stderr.?.readToEndAlloc(testing.allocator, 4096);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Expect TypeMismatch diagnostic (division by zero) with anchor possibly empty.

test "protocol: division by zero TypeMismatch" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1/0 AS x" });
    // Error expected
    try testing.expect(res.code == 2);
    try testing.expect(contains(res.err, "TypeMismatch"));
}
