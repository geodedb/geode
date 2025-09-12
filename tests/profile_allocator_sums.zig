const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = testing.allocator;
    var child = std.process.Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 16);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 16);
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

// Validate that profile_version bumped to 2 is present and memory block includes total_alloc_bytes key.
// Full summation of per-op bytes_alloc vs total_alloc_bytes would require JSON parsing; lightweight substring checks here.
// (Future: structured parse when JSON DOM helper exists.)

test "profile: memory block contains total_alloc_bytes (v2)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(contains(res.out, "\"profile_version\":2"));
    try testing.expect(contains(res.out, "total_alloc_bytes"));
}
