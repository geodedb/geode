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

test "protocol: PROFILE spills placeholders" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Some builds may treat PROFILE as still returning rows then profile: ensure profile frame present.
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    // Check spill placeholders object.
    try std.testing.expect(contains(res.out, "\"spills\""));
    try std.testing.expect(contains(res.out, "\"sort_spills\":0"));
    try std.testing.expect(contains(res.out, "\"distinct_spills\":0"));
    try std.testing.expect(contains(res.out, "\"union_spills\":0"));
}
